defmodule Naturecounts.Offline.ProcessVideoWorker do
  use Oban.Worker, queue: :video_processing, max_attempts: 3

  alias Naturecounts.Repo
  alias Naturecounts.Offline.{Video, Track, Profiles, PythonBridge, Classifier, FishialClassifier}

  import Ecto.Query

  require Logger

  # Detection uses 0-59%, Fishial 60-79%, VLM fallback 80-89%, persist 90-100%
  @detection_pct_range {0, 59}
  @fishial_pct_start 60
  @vlm_pct_start 80
  @persist_pct_start 90

  @impl true
  def perform(%Oban.Job{args: %{"video_id" => video_id}}) do
    video = Repo.get!(Video, video_id)
    profile = Profiles.get(video.processing_profile)
    profile = if video.min_bbox_area, do: %{profile | min_bbox_area: video.min_bbox_area}, else: profile
    profile = if video.vlm_sample_pct, do: Map.put(profile, :vlm_sample_pct, video.vlm_sample_pct), else: profile
    profile = if is_boolean(video.fishial_enabled), do: Map.put(profile, :fishial_enabled, video.fishial_enabled), else: profile
    profile = if is_boolean(video.vlm_enabled), do: Map.put(profile, :vlm_enabled, video.vlm_enabled), else: profile

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

          # Stage 2: Classification (60-89%)
          qualifying = Enum.count(tracks, fn t -> t["crop_b64"] != nil and t["best_bbox_area"] >= profile.min_bbox_area end)

          # Save stats early
          video
          |> Ecto.Changeset.change(%{
            total_tracks: length(tracks),
            vlm_qualified: qualifying,
            min_bbox_area: profile.min_bbox_area
          })
          |> Repo.update!()

          fishial? = Map.get(profile, :fishial_enabled, false)
          vlm? = Map.get(profile, :vlm_enabled, true)

          classified_tracks =
            cond do
              fishial? ->
                # Stage 2a: Fishial batch classification (60-79%)
                update_video(video, "processing", @fishial_pct_start, "Fishial: classifying #{qualifying} tracks...")
                Logger.info("[ProcessVideo] Fishial classification: #{qualifying}/#{length(tracks)} tracks qualify")

                fishial_tracks = FishialClassifier.classify_tracks(tracks, profile, video)

                fishial_count = Enum.count(fishial_tracks, & &1["classifier_source"] == "fishial")
                Logger.info("[ProcessVideo] Fishial complete: #{fishial_count}/#{length(fishial_tracks)} classified")

                # Stage 2b: VLM fallback for low-confidence Fishial results (80-89%)
                if vlm? do
                  threshold = Map.get(profile, :fishial_confidence_threshold, 0.5)

                  needs_vlm =
                    fishial_tracks
                    |> Enum.filter(fn t ->
                      t["crop_b64"] != nil and
                        t["best_bbox_area"] >= profile.min_bbox_area and
                        FishialClassifier.needs_vlm_fallback?(t, threshold)
                    end)

                  if length(needs_vlm) > 0 do
                    vlm_qualifying = length(needs_vlm)
                    update_video(video, "processing", @vlm_pct_start, "VLM fallback: 0/#{vlm_qualifying} low-confidence tracks...")
                    Logger.info("[ProcessVideo] VLM fallback: #{vlm_qualifying} tracks below threshold #{threshold}")

                    vlm_count = :counters.new(1, [:atomics])

                    vlm_progress_callback = fn ->
                      done = :counters.get(vlm_count, 1)
                      pct = @vlm_pct_start + div(done * (@persist_pct_start - @vlm_pct_start), max(vlm_qualifying, 1))
                      update_video(video, "processing", pct, "VLM fallback: #{done}/#{vlm_qualifying} tracks identified")
                    end

                    vlm_results =
                      Classifier.classify_tracks(needs_vlm, profile, video,
                        on_track_done: fn ->
                          :counters.add(vlm_count, 1, 1)
                          vlm_progress_callback.()
                        end
                      )

                    vlm_map =
                      vlm_results
                      |> Enum.filter(& &1["vlm_classified"])
                      |> Enum.map(fn t -> {t["track_id"], Map.put(t, "classifier_source", "vlm")} end)
                      |> Map.new()

                    Enum.map(fishial_tracks, fn t ->
                      case Map.get(vlm_map, t["track_id"]) do
                        nil -> t
                        vlm_t -> Map.merge(t, vlm_t)
                      end
                    end)
                  else
                    update_video(video, "processing", @vlm_pct_start, "Fishial classified all #{fishial_count} tracks (no VLM needed)")
                    fishial_tracks
                  end
                else
                  update_video(video, "processing", @vlm_pct_start, "Fishial only: #{fishial_count} classified (VLM disabled)")
                  fishial_tracks
                end

              vlm? ->
                # VLM only
                update_video(video, "processing", @fishial_pct_start, "Classifying: 0/#{qualifying} tracks sent to VLM...")
                Logger.info("[ProcessVideo] VLM classification: #{qualifying}/#{length(tracks)} tracks qualify (model=#{profile.vlm_model})")

                vlm_count = :counters.new(1, [:atomics])

                vlm_progress_callback = fn ->
                  done = :counters.get(vlm_count, 1)
                  pct = @fishial_pct_start + div(done * (@persist_pct_start - @fishial_pct_start), max(qualifying, 1))
                  update_video(video, "processing", pct, "Classifying: #{done}/#{qualifying} tracks identified")
                end

                Classifier.classify_tracks(tracks, profile, video,
                  on_track_done: fn ->
                    :counters.add(vlm_count, 1, 1)
                    vlm_progress_callback.()
                  end
                )

              true ->
                # No classification — detection only
                update_video(video, "processing", @vlm_pct_start, "Detection only (no classifiers enabled)")
                Logger.info("[ProcessVideo] Skipping classification (both Fishial and VLM disabled)")
                tracks
            end

          vlm_count = Enum.count(classified_tracks, & &1["vlm_classified"])
          fishial_count = Enum.count(classified_tracks, & &1["classifier_source"] == "fishial")
          Logger.info("[ProcessVideo] Classification complete: #{fishial_count} Fishial, #{vlm_count - fishial_count} VLM")

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
          classifier_source: t["classifier_source"],
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

    Naturecounts.Cache.invalidate_all()

    Phoenix.PubSub.broadcast(
      Naturecounts.PubSub,
      "video:#{video.id}",
      {:video_progress, %{id: video.id, status: status, progress_pct: pct, status_message: status_message}}
    )
  end
end
