defmodule Naturecounts.Offline.ProcessVideoWorker do
  use Oban.Worker, queue: :video_processing, max_attempts: 3

  alias Naturecounts.Repo
  alias Naturecounts.Offline.{Video, Track, Profiles, PythonBridge, Classifier}

  import Ecto.Query

  require Logger

  # Detection uses 0-59%, VLM classification 60-89%, persist 90-100%
  @detection_pct_range {0, 59}
  @vlm_pct_start 60
  @persist_pct_start 90

  @impl true
  def perform(%Oban.Job{args: %{"video_id" => video_id}}) do
    video = Repo.get!(Video, video_id)
    profile = Profiles.get(video.processing_profile)
    profile = if video.min_bbox_area, do: %{profile | min_bbox_area: video.min_bbox_area}, else: profile
    profile = if video.vlm_sample_pct, do: Map.put(profile, :vlm_sample_pct, video.vlm_sample_pct), else: profile

    Logger.info("[ProcessVideo] Starting #{video.filename} (profile=#{video.processing_profile})")
    update_video(video, "processing", 0, "Initializing...")

    try do
      # Stage 1: Detection + tracking (0-59%)
      update_video(video, "processing", 0, "Loading YOLO model...")

      progress_callback = fn %{"pct" => pct, "frame" => frame, "total_frames" => total, "tracks" => tracks, "detections" => dets} ->
        {range_start, range_end} = @detection_pct_range
        scaled_pct = range_start + div(pct * (range_end - range_start), 100)
        msg = "Detecting: frame #{frame}/#{total} — #{tracks} tracks, #{dets} detections"
        update_video(video, "processing", scaled_pct, msg)
      end

      case PythonBridge.run(video.path, profile, progress_callback: progress_callback) do
        {:ok, tracks} ->
          Logger.info("[ProcessVideo] Detection complete: #{length(tracks)} tracks")

          # Stage 2: VLM classification (60-89%)
          qualifying = Enum.count(tracks, fn t -> t["crop_b64"] != nil and t["best_bbox_area"] >= profile.min_bbox_area end)
          update_video(video, "processing", @vlm_pct_start, "Classifying: 0/#{qualifying} tracks sent to VLM...")
          Logger.info("[ProcessVideo] VLM classification: #{qualifying}/#{length(tracks)} tracks qualify (model=#{profile.vlm_model})")

          # Save VLM stats early
          video
          |> Ecto.Changeset.change(%{
            total_tracks: length(tracks),
            vlm_qualified: qualifying,
            min_bbox_area: profile.min_bbox_area
          })
          |> Repo.update!()

          classified_ref = make_ref()
          classified_count = :counters.new(1, [:atomics])

          vlm_progress_callback = fn ->
            done = :counters.get(classified_count, 1)
            pct = @vlm_pct_start + div(done * (@persist_pct_start - @vlm_pct_start), max(qualifying, 1))
            update_video(video, "processing", pct, "Classifying: #{done}/#{qualifying} tracks identified")
          end

          classified_tracks =
            Classifier.classify_tracks(tracks, profile, video,
              on_track_done: fn ->
                :counters.add(classified_count, 1, 1)
                vlm_progress_callback.()
              end
            )

          vlm_count = Enum.count(classified_tracks, & &1["vlm_classified"])
          Logger.info("[ProcessVideo] VLM complete: #{vlm_count}/#{length(classified_tracks)} classified")

          # Stage 3: Persist (90-100%)
          update_video(video, "processing", @persist_pct_start, "Saving #{length(classified_tracks)} tracks to database...")
          Logger.info("[ProcessVideo] Persisting #{length(classified_tracks)} tracks")
          persist_tracks(video, classified_tracks)

          video
          |> Ecto.Changeset.change(%{vlm_classified_count: vlm_count})
          |> Repo.update!()

          update_video(video, "completed", 100, "Done: #{length(classified_tracks)} tracks, #{vlm_count} identified")
          Logger.info("[ProcessVideo] Finished #{video.filename}: #{length(classified_tracks)} tracks, #{vlm_count} VLM-classified")
          :ok

        {:error, reason} ->
          Logger.error("[ProcessVideo] Detection failed for #{video.filename}: #{reason}")
          update_video(video, "failed", 0, nil, reason)
          {:error, reason}
      end
    rescue
      e ->
        msg = Exception.message(e)
        Logger.error("[ProcessVideo] Crashed processing #{video.filename}: #{msg}\n#{Exception.format_stacktrace(__STACKTRACE__)}")
        update_video(video, "failed", 0, nil, msg)
        {:error, msg}
    end
  end

  defp persist_tracks(video, tracks) do
    now = NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)
    ttl_days = Application.get_env(:naturecounts, :classification_ttl_days, 30)
    expires_at = NaiveDateTime.add(now, ttl_days * 86400, :second)

    entries =
      Enum.map(tracks, fn t ->
        vlm = t["vlm_classified"] || false
        %{
          video_id: video.id,
          track_id: t["track_id"],
          species: t["species"],
          scientific_name: t["scientific_name"],
          species_confidence: t["species_confidence"],
          vlm_reasoning: t["vlm_reasoning"],
          best_confidence: t["best_confidence"],
          best_bbox_area: t["best_bbox_area"],
          first_frame: t["first_frame"],
          last_frame: t["last_frame"],
          frame_count: t["frame_count"],
          thumbnail: decode_thumbnail(t["crop_b64"]),
          vlm_classified: vlm,
          review_status: "pending",
          expires_at: if(vlm, do: expires_at),
          inserted_at: now,
          updated_at: now
        }
      end)

    # Batch insert in chunks of 100
    entries
    |> Enum.chunk_every(100)
    |> Enum.each(fn chunk ->
      Repo.insert_all(Track, chunk, on_conflict: :nothing)
    end)
  end

  defp decode_thumbnail(nil), do: nil
  defp decode_thumbnail(b64), do: Base.decode64!(b64)

  defp update_video(video, status, pct, status_message, error \\ nil) do
    video
    |> Ecto.Changeset.change(%{
      status: status,
      progress_pct: pct,
      status_message: status_message,
      error_message: error
    })
    |> Repo.update!()

    Phoenix.PubSub.broadcast(
      Naturecounts.PubSub,
      "video:#{video.id}",
      {:video_progress, %{id: video.id, status: status, progress_pct: pct, status_message: status_message}}
    )
  end
end
