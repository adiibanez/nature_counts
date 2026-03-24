defmodule Naturecounts.Offline.FishialClassifier do
  @moduledoc """
  Local fish species classification using Fishial's BEiT v2 model.
  Runs on GPU via Pythonx — no API calls needed.
  """

  alias Naturecounts.Offline.PythonBridge

  require Logger

  @doc """
  Classify tracks using the Fishial model. Returns tracks with species data merged in.
  Tracks without crops or below min_bbox_area are returned unchanged.
  """
  def classify_tracks(tracks, profile, _video \\ %{}, opts \\ []) do
    on_track_done = Keyword.get(opts, :on_track_done, fn -> :ok end)

    qualifying =
      tracks
      |> Enum.filter(fn t ->
        t["crop_b64"] != nil and t["best_bbox_area"] >= profile.min_bbox_area
      end)

    Logger.info(
      "[FishialClassifier] #{length(qualifying)}/#{length(tracks)} tracks qualify " <>
        "(min_bbox_area=#{profile.min_bbox_area})"
    )

    if Enum.empty?(qualifying) do
      tracks
    else
      crops =
        Enum.map(qualifying, fn t ->
          %{"track_id" => t["track_id"], "crop_b64" => t["crop_b64"]}
        end)

      case PythonBridge.classify_fishial(crops) do
        {:ok, results} ->
          classified = build_classified_map(results, profile)

          Enum.each(qualifying, fn _t -> on_track_done.() end)

          Enum.map(tracks, fn track ->
            case Map.get(classified, track["track_id"]) do
              nil -> track
              result -> Map.merge(track, result)
            end
          end)

        {:error, reason} ->
          Logger.error("[FishialClassifier] Classification failed: #{reason}")
          tracks
      end
    end
  end

  @doc """
  Returns true if a Fishial-classified track needs VLM fallback.
  """
  def needs_vlm_fallback?(track, threshold \\ 0.5) do
    case track do
      %{"fishial_confidence" => conf} when is_number(conf) -> conf < threshold
      _ -> true
    end
  end

  defp build_classified_map(results, _profile) do
    results
    |> Enum.map(fn r ->
      confidence = r["confidence"]
      confidence_label = confidence_bucket(confidence)

      {r["track_id"],
       %{
         "species" => r["species"],
         "scientific_name" => r["species"],
         "species_confidence" => confidence_label,
         "fishial_confidence" => confidence,
         "vlm_reasoning" => "Fishial BEiT v2 (#{Float.round(confidence * 100, 1)}%)",
         "vlm_classified" => true,
         "classifier_source" => "fishial"
       }}
    end)
    |> Map.new()
  end

  defp confidence_bucket(c) when c >= 0.7, do: "high"
  defp confidence_bucket(c) when c >= 0.4, do: "medium"
  defp confidence_bucket(_), do: "low"
end
