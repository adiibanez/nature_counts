defmodule NaturecountsWeb.IngestionChannel do
  use NaturecountsWeb, :channel

  alias Naturecounts.Detection.DetectionEvent
  alias Naturecounts.Detection.TrackerState
  alias Naturecounts.CameraSettings

  require Logger

  @impl true
  def join("ingestion:lobby", _params, socket) do
    Logger.info("DeepStream pipeline joined ingestion:lobby")
    Phoenix.PubSub.subscribe(Naturecounts.PubSub, "pipeline:control")
    Phoenix.PubSub.broadcast(Naturecounts.PubSub, "deepstream:connection", {:deepstream_connected, true})

    # Re-apply persisted tracker config and crop filters on reconnect
    send(self(), :restore_config)

    {:ok, socket}
  end

  @impl true
  def terminate(_reason, _socket) do
    Logger.info("DeepStream pipeline left ingestion:lobby")
    Phoenix.PubSub.broadcast(Naturecounts.PubSub, "deepstream:connection", {:deepstream_connected, false})
    :ok
  end

  @impl true
  def handle_info(:restore_config, socket) do
    # Restore tracker config from persisted camera settings (use cam1 as source of truth)
    saved = CameraSettings.get("cam1")

    if saved["tracker_params"] do
      config = %{
        preset: saved["tracker_preset"] || "nvdcf_accuracy",
        overrides: saved["tracker_params"]
      }

      Logger.info("[IngestionChannel] Restoring tracker config: #{config.preset}")
      push(socket, "set_tracker_config", config)
    end

    # Restore crop filters
    push(socket, "set_crop_filters", %{
      min_crop_area: saved["min_crop_area"] || 2500,
      min_sharpness: saved["min_sharpness"] || 0.0
    })

    # Restore detector model config
    if saved["detector_model"] do
      detector_models = %{
        "rfdetr_nano" => "config_infer_primary_cfd_rfdetr_nano.txt",
        "yolov12x" => "config_infer_primary_cfd_yolov12_ds64.txt"
      }

      if config_file = Map.get(detector_models, saved["detector_model"]) do
        Logger.info("[IngestionChannel] Restoring detector model: #{saved["detector_model"]}")
        push(socket, "set_infer_config", %{config_path: config_file})
      end
    end

    # Restore thumbnail setting
    push(socket, "set_thumbnails", %{enabled: saved["show_fish_list"] || false})

    {:noreply, socket}
  end

  @impl true
  def handle_info({:set_thumbnails, enabled}, socket) do
    push(socket, "set_thumbnails", %{enabled: enabled})
    {:noreply, socket}
  end

  @impl true
  def handle_info({:set_tracker_config, config_map}, socket) do
    push(socket, "set_tracker_config", config_map)
    {:noreply, socket}
  end

  @impl true
  def handle_info({:set_crop_filters, filters}, socket) do
    push(socket, "set_crop_filters", filters)
    {:noreply, socket}
  end

  @impl true
  def handle_info({:set_infer_config, config_map}, socket) do
    push(socket, "set_infer_config", config_map)
    {:noreply, socket}
  end

  @impl true
  def handle_in("detection_batch", %{"cam_id" => cam_id} = payload, socket) do
    event = DetectionEvent.from_map(payload)

    # Broadcast using plain cam_id (integer from DeepStream, e.g. 0)
    topic = "detections:#{cam_id}"
    Phoenix.PubSub.broadcast(Naturecounts.PubSub, topic, {:detections, event})

    TrackerState.update(event)

    {:noreply, socket}
  end
end
