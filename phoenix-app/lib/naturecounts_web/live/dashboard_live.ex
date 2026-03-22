defmodule NaturecountsWeb.DashboardLive do
  use NaturecountsWeb, :live_view

  alias Naturecounts.Detection.TrackerState

  @stats_interval 1000

  @impl true
  def mount(_params, _session, socket) do
    num_cameras = Application.get_env(:naturecounts, :num_cameras, 1)
    cameras = for i <- 0..(num_cameras - 1), do: %{id: i, active: 0, total: 0}

    if connected?(socket) do
      schedule_stats_update()
    end

    mediamtx_host = Application.get_env(:naturecounts, :mediamtx_host, "localhost:8889")

    {:ok,
     assign(socket,
       cameras: cameras,
       mediamtx_host: mediamtx_host,
       show_inference: true,
       page_title: "Dashboard"
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
  def handle_event("detection_stats", _params, socket) do
    {:noreply, socket}
  end

  @impl true
  def handle_event("toggle_inference", _params, socket) do
    {:noreply, assign(socket, show_inference: !socket.assigns.show_inference)}
  end

  defp schedule_stats_update do
    Process.send_after(self(), :update_stats, @stats_interval)
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="space-y-6">
      <div class="flex items-center justify-between">
        <h1 class="text-3xl font-bold">NatureCounts Dashboard</h1>
        <div class="flex items-center gap-2">
          <.link navigate={~p"/videos"} class="btn btn-outline btn-sm">Videos</.link>
          <.link navigate={~p"/inventory"} class="btn btn-outline btn-sm">Inventory</.link>
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
