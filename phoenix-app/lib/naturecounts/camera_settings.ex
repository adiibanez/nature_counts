defmodule Naturecounts.CameraSettings do
  @moduledoc false

  @path Application.compile_env(:naturecounts, :camera_settings_path, "/data/camera_settings.json")

  @defaults %{
    "settings_panel_open" => false,
    "show_inference" => true,
    "show_fish_list" => false,
    "fish_cols" => 1,
    "video_pct" => 65,
    "tracker_preset" => "nvdcf_accuracy",
    "min_crop_area" => 2500,
    "min_sharpness" => 0.0
  }

  def get(camera_key) do
    all = read_all()
    settings = Map.get(all, camera_key, %{})
    Map.merge(@defaults, settings)
  end

  def put(camera_key, updates) when is_map(updates) do
    all = read_all()
    current = Map.get(all, camera_key, %{})
    updated = Map.merge(current, updates)
    write_all(Map.put(all, camera_key, updated))
    updated
  end

  defp read_all do
    case File.read(@path) do
      {:ok, data} ->
        case Jason.decode(data) do
          {:ok, map} when is_map(map) -> map
          _ -> %{}
        end

      _ ->
        %{}
    end
  end

  defp write_all(data) do
    dir = Path.dirname(@path)
    File.mkdir_p!(dir)
    File.write!(@path, Jason.encode!(data, pretty: true))
  end
end
