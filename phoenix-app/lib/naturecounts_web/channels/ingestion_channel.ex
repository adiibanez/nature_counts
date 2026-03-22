defmodule NaturecountsWeb.IngestionChannel do
  use NaturecountsWeb, :channel

  alias Naturecounts.Detection.DetectionEvent
  alias Naturecounts.Detection.TrackerState

  require Logger

  @impl true
  def join("ingestion:lobby", _params, socket) do
    Logger.info("DeepStream pipeline joined ingestion:lobby")
    Phoenix.PubSub.subscribe(Naturecounts.PubSub, "pipeline:control")
    {:ok, socket}
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
  def handle_in("detection_batch", %{"cam_id" => cam_id} = payload, socket) do
    event = DetectionEvent.from_map(payload)

    # Broadcast using plain cam_id (integer from DeepStream, e.g. 0)
    topic = "detections:#{cam_id}"
    Phoenix.PubSub.broadcast(Naturecounts.PubSub, topic, {:detections, event})

    TrackerState.update(event)

    {:noreply, socket}
  end
end
