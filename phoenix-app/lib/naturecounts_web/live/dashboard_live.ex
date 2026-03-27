defmodule NaturecountsWeb.DashboardLive do
  use NaturecountsWeb, :live_view

  alias Naturecounts.Detection.TrackerState
  alias Naturecounts.Pipeline.DeepstreamControl

  @stats_interval 1000

  @impl true
  def mount(_params, _session, socket) do
    num_cameras = Application.get_env(:naturecounts, :num_cameras, 1)
    cameras = for i <- 0..(num_cameras - 1), do: %{id: i, active: 0, total: 0}

    pipeline = DeepstreamControl.status()

    if connected?(socket) do
      schedule_stats_update()
      Phoenix.PubSub.subscribe(Naturecounts.PubSub, "pipeline:status")
    end

    mediamtx_host = Application.get_env(:naturecounts, :mediamtx_host, "localhost:8889")

    {:ok,
     assign(socket,
       cameras: cameras,
       mediamtx_host: mediamtx_host,
       show_inference: true,
       page_title: "Dashboard",
       pipeline_status: pipeline.container,
       ws_connected: pipeline.ws_connected
     )}
  end

  @impl true
  def handle_info(:update_stats, socket) do
    cameras =
      for cam <- socket.assigns.cameras do
        stats = TrackerState.camera_stats(cam.id)
        %{cam | active: stats.active_tracks, total: stats.total_tracks}
      end

    schedule_stats_update()
    {:noreply, assign(socket, cameras: cameras)}
  end

  @impl true
  def handle_info({:pipeline_status, status}, socket) do
    {:noreply, assign(socket, pipeline_status: status.container, ws_connected: status.ws_connected)}
  end

  @impl true
  def handle_event("detection_stats", _params, socket) do
    {:noreply, socket}
  end

  @impl true
  def handle_event("toggle_inference", _params, socket) do
    {:noreply, assign(socket, show_inference: !socket.assigns.show_inference)}
  end

  def handle_event("start_pipeline", _params, socket) do
    DeepstreamControl.start_pipeline()
    {:noreply, assign(socket, pipeline_status: :starting)}
  end

  def handle_event("stop_pipeline", _params, socket) do
    DeepstreamControl.stop_pipeline()
    {:noreply, assign(socket, pipeline_status: :stopping)}
  end

  defp schedule_stats_update do
    Process.send_after(self(), :update_stats, @stats_interval)
  end

  defp pipeline_status_text(:running, true), do: "Pipeline Running"
  defp pipeline_status_text(:running, false), do: "Connecting..."
  defp pipeline_status_text(:stopped, _), do: "Pipeline Stopped"
  defp pipeline_status_text(:starting, _), do: "Starting..."
  defp pipeline_status_text(:stopping, _), do: "Stopping..."
  defp pipeline_status_text(_, _), do: "Unknown"

  defp pipeline_dot_class(:running, true), do: "bg-success"
  defp pipeline_dot_class(:running, false), do: "bg-warning animate-pulse"
  defp pipeline_dot_class(:stopped, _), do: "bg-error"
  defp pipeline_dot_class(:starting, _), do: "bg-warning animate-pulse"
  defp pipeline_dot_class(:stopping, _), do: "bg-warning animate-pulse"
  defp pipeline_dot_class(_, _), do: "bg-base-300"

  @impl true
  def render(assigns) do
    ~H"""
    <div class="p-4 space-y-6">
      <div class="flex items-center justify-between">
        <div class="flex items-center gap-4">
          <h1 class="text-3xl font-bold">Dashboard</h1>
          <div class="flex items-center gap-2">
            <span class={[
              "w-2.5 h-2.5 rounded-full",
              pipeline_dot_class(@pipeline_status, @ws_connected)
            ]} />
            <span class="text-sm font-medium">
              {pipeline_status_text(@pipeline_status, @ws_connected)}
            </span>
          </div>
          <%= if @pipeline_status in [:running, :starting] do %>
            <button
              phx-click="stop_pipeline"
              class={"btn btn-sm btn-outline btn-error #{if @pipeline_status == :stopping, do: "btn-disabled loading"}"}
              disabled={@pipeline_status == :stopping}
            >
              Stop Pipeline
            </button>
          <% end %>
          <%= if @pipeline_status in [:stopped, :stopping, :unknown] do %>
            <button
              phx-click="start_pipeline"
              class={"btn btn-sm btn-outline btn-success #{if @pipeline_status == :starting, do: "btn-disabled loading"}"}
              disabled={@pipeline_status == :starting}
            >
              Start Pipeline
            </button>
          <% end %>
        </div>
        <label class="label cursor-pointer gap-2">
          <span class="label-text">Inference overlay</span>
          <input
            type="checkbox"
            class="toggle toggle-primary"
            checked={@show_inference}
            phx-click="toggle_inference"
          />
        </label>
      </div>

      <div class="grid grid-cols-1 md:grid-cols-2 lg:grid-cols-3 gap-4">
        <div :for={cam <- @cameras} class="card bg-base-200 shadow-xl">
          <div class="card-body p-4">
            <h2 class="card-title text-lg">Camera {cam.id}</h2>

            <%= if @pipeline_status == :running do %>
              <div
                id={"video-player-cam#{cam.id}-#{@show_inference}"}
                phx-hook="VideoOverlay"
                data-cam-id={cam.id}
                data-webrtc-url={
                  if @show_inference,
                    do: "http://#{@mediamtx_host}/cam#{cam.id + 1}/whep",
                    else: "http://#{@mediamtx_host}/raw-cam#{cam.id + 1}/whep"
                }
                class="relative w-full bg-black rounded-lg overflow-hidden aspect-video"
              >
                <video
                  id={"video-cam#{cam.id}"}
                  autoplay
                  muted
                  playsinline
                  class="w-full h-full object-contain"
                >
                </video>
              </div>
            <% else %>
              <div class="flex items-center justify-center aspect-video bg-base-300 rounded-lg">
                <div class="text-center text-base-content/40">
                  <svg xmlns="http://www.w3.org/2000/svg" class="w-10 h-10 mx-auto mb-2" fill="none" viewBox="0 0 24 24" stroke="currentColor">
                    <path stroke-linecap="round" stroke-linejoin="round" stroke-width="1.5" d="m15.75 10.5 4.72-4.72a.75.75 0 0 1 1.28.53v11.38a.75.75 0 0 1-1.28.53l-4.72-4.72M4.5 18.75h9a2.25 2.25 0 0 0 2.25-2.25v-9a2.25 2.25 0 0 0-2.25-2.25h-9A2.25 2.25 0 0 0 2.25 7.5v9a2.25 2.25 0 0 0 2.25 2.25Z" />
                  </svg>
                  <p class="text-sm">Pipeline offline</p>
                </div>
              </div>
            <% end %>

            <div class="flex justify-between mt-2 text-sm">
              <span class="badge badge-primary">Active: {cam.active}</span>
              <span class="badge badge-secondary">Total: {cam.total}</span>
            </div>

            <div class="card-actions justify-end mt-2">
              <.link navigate={~p"/camera/#{cam.id}"} class="btn btn-sm btn-outline">
                View Details
              </.link>
            </div>
          </div>
        </div>
      </div>
    </div>
    """
  end
end
