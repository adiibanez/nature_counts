defmodule NaturecountsWeb.DetectionChannel do
  use NaturecountsWeb, :channel

  alias Naturecounts.Detection.DetectionEvent

  @impl true
  def join("detections:" <> cam_id, _params, socket) do
    # cam_id is already the full ID string, e.g. "0" from "detections:0"
    Phoenix.PubSub.subscribe(Naturecounts.PubSub, "detections:#{cam_id}")
    {:ok, assign(socket, :cam_id, cam_id)}
  end

  @impl true
  def handle_info({:detections, %DetectionEvent{} = event}, socket) do
    push(socket, "detection_update", DetectionEvent.to_map(event))
    {:noreply, socket}
  end
end
