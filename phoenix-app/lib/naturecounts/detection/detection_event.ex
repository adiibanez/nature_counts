defmodule Naturecounts.Detection.DetectionEvent do
  @moduledoc """
  Structs representing detection data from the DeepStream pipeline.
  """

  defmodule BBox do
    @derive Jason.Encoder
    defstruct [:left, :top, :width, :height]

    def from_map(%{"left" => l, "top" => t, "width" => w, "height" => h}) do
      %__MODULE__{left: l, top: t, width: w, height: h}
    end
  end

  defmodule DetectedObject do
    @derive Jason.Encoder
    defstruct [:track_id, :class_id, :label, :confidence, :bbox, :thumbnail]

    def from_map(%{"track_id" => tid, "class_id" => cid, "label" => label, "confidence" => conf, "bbox" => bbox} = map) do
      %__MODULE__{
        track_id: tid,
        class_id: cid,
        label: label,
        confidence: conf,
        bbox: BBox.from_map(bbox),
        thumbnail: Map.get(map, "thumbnail")
      }
    end
  end

  @derive Jason.Encoder
  defstruct [:cam_id, :ts, :pts, :resolution, :objects]

  def from_map(%{"cam_id" => cam_id, "ts" => ts, "resolution" => res, "objects" => objects} = map) do
    %__MODULE__{
      cam_id: cam_id,
      ts: ts,
      pts: Map.get(map, "pts"),
      resolution: res,
      objects: Enum.map(objects, &DetectedObject.from_map/1)
    }
  end

  def to_map(%__MODULE__{} = event) do
    %{
      cam_id: event.cam_id,
      ts: event.ts,
      pts: event.pts,
      resolution: event.resolution,
      objects:
        Enum.map(event.objects, fn obj ->
          map = %{
            track_id: obj.track_id,
            class_id: obj.class_id,
            label: obj.label,
            confidence: obj.confidence,
            bbox: %{
              left: obj.bbox.left,
              top: obj.bbox.top,
              width: obj.bbox.width,
              height: obj.bbox.height
            }
          }

          if obj.thumbnail, do: Map.put(map, :thumbnail, obj.thumbnail), else: map
        end)
    }
  end
end
