defmodule Naturecounts.Offline.Classifier do
  @moduledoc """
  Claude VLM species classification with bbox size gating.
  Only sends crops above a minimum area threshold to the API.
  """

  require Logger

  def should_classify?(bbox_area, profile) do
    bbox_area >= profile.min_bbox_area
  end

  def classify_tracks(tracks, profile, video \\ %{}, opts \\ []) do
    on_track_done = Keyword.get(opts, :on_track_done, fn -> :ok end)

    qualifying =
      tracks
      |> Enum.filter(fn t ->
        t["crop_b64"] != nil and should_classify?(t["best_bbox_area"], profile)
      end)

    Logger.info(
      "[Classifier] #{length(qualifying)}/#{length(tracks)} tracks qualify for VLM " <>
        "(min_bbox_area=#{profile.min_bbox_area})"
    )

    classified =
      qualifying
      |> select_crops(profile)
      |> Task.async_stream(
        fn track ->
          result = classify_crop(track, profile, video)
          on_track_done.()
          result
        end,
        max_concurrency: profile.vlm_concurrency,
        timeout: 30_000
      )
      |> Enum.reduce(%{}, fn
        {:ok, {track_id, result}}, acc -> Map.put(acc, track_id, result)
        {:exit, reason}, acc ->
          Logger.warning("[Classifier] VLM task failed: #{inspect(reason)}")
          on_track_done.()
          acc
      end)

    # Merge VLM results back into tracks
    Enum.map(tracks, fn track ->
      case Map.get(classified, track["track_id"]) do
        nil -> track
        result -> Map.merge(track, result)
      end
    end)
  end

  defp select_crops(tracks, profile) do
    # First apply percentage sampling
    sampled = apply_sample_pct(tracks, Map.get(profile, :vlm_sample_pct, 100))

    case profile.vlm_crops_per_track do
      :all ->
        sampled

      n when is_integer(n) ->
        sampled
        |> Enum.sort_by(fn t -> -(t["best_confidence"] * t["best_bbox_area"]) end)
        |> Enum.take(n)
    end
  end

  defp apply_sample_pct(tracks, pct) when pct >= 100, do: tracks
  defp apply_sample_pct(_tracks, pct) when pct <= 0, do: []
  defp apply_sample_pct(tracks, pct) do
    # Take top pct% ranked by quality (confidence * area)
    count = max(1, round(length(tracks) * pct / 100))

    tracks
    |> Enum.sort_by(fn t -> -(t["best_confidence"] * t["best_bbox_area"]) end)
    |> Enum.take(count)
  end

  def classify_crop(track, profile, video) do
    crop_b64 = track["crop_b64"]
    location = Map.get(video, :location, "underwater reef camera")
    track_id = track["track_id"]
    area = track["best_bbox_area"]

    # Save crop to disk for debugging
    debug_dir = "/videos/vlm_crops"
    File.mkdir_p(debug_dir)
    video_name = if is_map(video), do: Map.get(video, :filename, "unknown"), else: "unknown"
    crop_path = Path.join(debug_dir, "#{video_name}_track#{track_id}.jpg")
    File.write(crop_path, Base.decode64!(crop_b64))
    crop_bytes = byte_size(crop_b64) |> div(4) |> Kernel.*(3)
    sharp = track["best_sharpness"] || 0
    Logger.info("[Classifier] Track #{track_id}: sending crop to VLM (area=#{area}px, sharpness=#{sharp}, ~#{div(crop_bytes, 1024)}KB, saved to #{crop_path})")

    body = %{
      model: profile.vlm_model,
      max_tokens: 300,
      messages: [
        %{
          role: "user",
          content: [
            %{
              type: "image",
              source: %{type: "base64", media_type: "image/jpeg", data: crop_b64}
            },
            %{type: "text", text: prompt(location)}
          ]
        }
      ]
    }

    case Req.post("https://api.anthropic.com/v1/messages",
           headers: [
             {"x-api-key", api_key()},
             {"anthropic-version", "2023-06-01"},
             {"content-type", "application/json"}
           ],
           json: body,
           receive_timeout: 25_000
         ) do
      {:ok, %{status: 200, body: resp_body}} ->
        parse_vlm_response(track["track_id"], resp_body)

      {:ok, %{status: status, body: resp_body}} ->
        Logger.warning("[Classifier] Claude API returned #{status}: #{inspect(resp_body)}")
        {track["track_id"], %{}}

      {:error, reason} ->
        Logger.warning("[Classifier] Claude API error: #{inspect(reason)}")
        {track["track_id"], %{}}
    end
  end

  defp parse_vlm_response(track_id, resp_body) do
    text =
      resp_body
      |> Map.get("content", [])
      |> Enum.find(%{}, &(&1["type"] == "text"))
      |> Map.get("text", "")

    json_text = extract_json(text)

    case Jason.decode(json_text) do
      {:ok, parsed} ->
        Logger.info("[Classifier] Track #{track_id}: #{parsed["species"]} (#{parsed["confidence"]}) — #{parsed["reasoning"]}")
        {track_id, %{
          "species" => parsed["species"],
          "scientific_name" => parsed["scientific_name"],
          "species_confidence" => parsed["confidence"],
          "vlm_reasoning" => parsed["reasoning"],
          "vlm_classified" => true
        }}

      _ ->
        Logger.warning("[Classifier] Track #{track_id}: failed to parse VLM response: #{text}")
        {track_id, %{
          "species" => "unidentified",
          "species_confidence" => "low",
          "vlm_reasoning" => text,
          "vlm_classified" => true
        }}
    end
  end

  # Strip markdown code fences and extract JSON
  defp extract_json(text) do
    text
    |> String.trim()
    |> then(fn t ->
      case Regex.run(~r/```(?:json)?\s*\n?(.*?)\n?\s*```/s, t) do
        [_, json] -> json
        _ -> t
      end
    end)
    |> String.trim()
  end

  defp prompt(location) do
    """
    Identify the fish species in this image from an underwater camera.
    Location: #{location}.

    Respond ONLY with this JSON (no other text):
    {"species": "common name", "scientific_name": "Genus species", "confidence": "high|medium|low", "reasoning": "brief explanation"}

    If the image is too blurry or unclear to identify:
    {"species": "unidentified", "scientific_name": null, "confidence": "low", "reasoning": "explanation"}
    """
  end

  defp api_key do
    Application.get_env(:naturecounts, :anthropic_api_key) ||
      raise "ANTHROPIC_API_KEY not configured"
  end
end
