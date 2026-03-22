defmodule Naturecounts.Offline.Profiles do
  @default_model "claude-sonnet-4-6"

  @profiles %{
    "light" => %{
      label: "Light",
      description: "Fast scan, VLM only for large clear fish",
      fps: 1,
      imgsz: 640,
      detection_threshold: 0.25,
      min_bbox_area: 200 * 200,
      vlm_crops_per_track: 1,
      vlm_concurrency: 3
    },
    "standard" => %{
      label: "Standard",
      description: "Balanced accuracy and cost",
      fps: 3,
      imgsz: 640,
      detection_threshold: 0.15,
      min_bbox_area: 150 * 150,
      vlm_crops_per_track: 3,
      vlm_concurrency: 5
    },
    "deep" => %{
      label: "Deep",
      description: "Maximum accuracy, higher cost",
      fps: 5,
      imgsz: 1280,
      detection_threshold: 0.10,
      min_bbox_area: 100 * 100,
      vlm_crops_per_track: :all,
      vlm_concurrency: 5
    }
  }

  def get(name) do
    case Map.get(@profiles, name, @profiles["standard"]) do
      profile -> Map.put(profile, :vlm_model, vlm_model())
    end
  end

  def all, do: @profiles
  def names, do: Map.keys(@profiles)

  defp vlm_model do
    System.get_env("VLM_MODEL") || @default_model
  end
end
