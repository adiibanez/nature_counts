defmodule NaturecountsWeb.DashboardLive do
  use NaturecountsWeb, :live_view

  alias Naturecounts.Detection.TrackerState
  alias Naturecounts.Pipeline.DeepstreamControl

  require Logger

  @stats_interval 1000

  # In Docker, mediamtx.yml is bind-mounted at /mediamtx.yml (shared with MediaMTX container).
  # In local dev, fall back to the project root.
  @mediamtx_config_path "/mediamtx.yml"

  @scenarios [
    %{
      id: "live",
      name: "Live",
      description: "Default camera streams",
      clips: [
        %{name: "Camera 0", file: "rtsp-ready/P5_2025-03-07_420.mp4"},
        %{name: "Camera 1", file: "rtsp-ready/cam_1.mp4"},
        %{name: "Camera 2", file: "rtsp-ready/cam_2.mp4"}
      ]
    },
    %{
      id: "fulhadoo_top3",
      name: "Fulhadoo Top 3",
      description: "Most engaging clips (by detection density + motion)",
      clips: [
        %{name: "cam3 Jan 23 02:20", file: "fulhadoo/2023-01-23_02-20-02_cam3.mp4"},
        %{name: "cam3 Jan 28 02:00", file: "fulhadoo/2023-01-28_02-00-01_cam3.mp4"},
        %{name: "cam3 Feb 08 01:20", file: "fulhadoo/2023-02-08_01-20-01_cam3.mp4"}
      ]
    }
  ]

  @impl true
  def mount(_params, _session, socket) do
    pipeline = DeepstreamControl.status()

    if connected?(socket) do
      schedule_stats_update()
      Phoenix.PubSub.subscribe(Naturecounts.PubSub, "pipeline:status")
    end

    mediamtx_host = Application.get_env(:naturecounts, :mediamtx_host, "localhost:8889")
    scenario = active_scenario("live")
    cameras = build_cameras(scenario)

    {:ok,
     assign(socket,
       cameras: cameras,
       mediamtx_host: mediamtx_host,
       show_inference: true,
       page_title: "Video streams",
       pipeline_status: pipeline.container,
       ws_connected: pipeline.ws_connected,
       scenarios: @scenarios,
       active_scenario: "live",
       scenario: scenario,
       applying: false
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
    {:noreply,
     assign(socket,
       pipeline_status: status.container,
       ws_connected: status.ws_connected,
       applying: if(status.container == :running and status.ws_connected, do: false, else: socket.assigns.applying)
     )}
  end

  @impl true
  def handle_info(:apply_done, socket) do
    {:noreply, assign(socket, applying: false)}
  end

  @impl true
  def handle_event("detection_stats", _params, socket) do
    {:noreply, socket}
  end

  @impl true
  def handle_event("toggle_inference", _params, socket) do
    {:noreply, assign(socket, show_inference: !socket.assigns.show_inference)}
  end

  @impl true
  def handle_event("select_scenario", %{"scenario" => scenario_id}, socket) do
    scenario = active_scenario(scenario_id)
    {:noreply, assign(socket, active_scenario: scenario_id, scenario: scenario)}
  end

  @impl true
  def handle_event("apply_scenario", _params, socket) do
    scenario = socket.assigns.scenario
    socket = assign(socket, applying: true)

    Task.start(fn ->
      apply_scenario(scenario)
      send(socket.root_pid, :apply_done)
    end)

    {:noreply, socket}
  end

  def handle_event("start_pipeline", _params, socket) do
    DeepstreamControl.start_pipeline()
    {:noreply, assign(socket, pipeline_status: :starting)}
  end

  def handle_event("stop_pipeline", _params, socket) do
    DeepstreamControl.stop_pipeline()
    {:noreply, assign(socket, pipeline_status: :stopping)}
  end

  # --- Scenario logic ---

  defp active_scenario(id) do
    Enum.find(@scenarios, List.first(@scenarios), &(&1.id == id))
  end

  defp build_cameras(scenario) do
    for {clip, i} <- Enum.with_index(scenario.clips) do
      %{id: i, name: clip.name, active: 0, total: 0}
    end
  end

  defp apply_scenario(scenario) do
    Logger.info("[DashboardLive] Applying scenario: #{scenario.id}")

    # 1. Write mediamtx.yml with the scenario's video files
    write_mediamtx_config(scenario.clips)

    # 2. Stop DeepStream first (so it doesn't crash when MediaMTX restarts)
    DeepstreamControl.stop_pipeline()
    Process.sleep(2_000)

    # 3. Restart MediaMTX to pick up new config
    DeepstreamControl.restart_mediamtx()
    Process.sleep(3_000)

    # 4. Start DeepStream again
    DeepstreamControl.start_pipeline()
    Logger.info("[DashboardLive] Scenario applied: #{scenario.id}")
  end

  defp write_mediamtx_config(clips) do
    num = length(clips)

    raw_paths =
      clips
      |> Enum.with_index(1)
      |> Enum.map(fn {clip, i} ->
        """
          raw-cam#{i}:
            runOnInit: >
              ffmpeg -re -stream_loop -1
              -i /videos/#{clip.file}
              -an -c:v copy
              -f rtsp rtsp://localhost:$RTSP_PORT/$MTX_PATH
            runOnInitRestart: yes
        """
      end)
      |> Enum.join("\n")

    cam_paths =
      1..num
      |> Enum.map(fn i -> "  cam#{i}:" end)
      |> Enum.join("\n")

    config = """
    ###############################################
    # MediaMTX — RTSP hub + WebRTC/HLS output
    ###############################################

    rtspTransports: [udp, tcp]

    # WebRTC for low-latency browser playback
    webrtc: yes
    webrtcAddress: :8889
    webrtcLocalUDPAddress: ""
    webrtcLocalTCPAddress: :8189
    webrtcIPsFromInterfaces: yes
    webrtcAdditionalHosts: []

    # HLS as fallback
    hlsAlwaysRemux: yes
    hlsVariant: lowLatency
    hlsSegmentCount: 7
    hlsSegmentDuration: 500ms

    paths:
      # --- RAW camera inputs ---
    #{raw_paths}
      # --- Processed output from DeepStream ---
    #{cam_paths}

      # Wildcard: accepts any RTSP publisher on any path
      all_others:
    """

    # Resolve config path: try project root first, then compile-time default
    config_path = resolve_mediamtx_path()
    File.write!(config_path, config)
    Logger.info("[DashboardLive] Wrote mediamtx.yml with #{num} cameras to #{config_path}")
  end

  defp resolve_mediamtx_path do
    if File.exists?(@mediamtx_config_path) do
      @mediamtx_config_path
    else
      # Local dev fallback: project root
      Path.join(Application.app_dir(:naturecounts, ".."), "../../mediamtx.yml")
    end
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

  defp needs_apply?(scenarios, active_id, cameras) do
    scenario = Enum.find(scenarios, &(&1.id == active_id))
    scenario && length(scenario.clips) != length(cameras)
  end

  @impl true
  def render(assigns) do
    assigns =
      assign(assigns, :scenario_changed, needs_apply?(assigns.scenarios, assigns.active_scenario, assigns.cameras))

    ~H"""
    <div class="p-4 space-y-6">
      <div class="flex items-center justify-between flex-wrap gap-4">
        <div class="flex items-center gap-4">
          <h1 class="text-3xl font-bold">Video streams</h1>

          <%!-- Scenario selector --%>
          <form phx-change="select_scenario">
            <select class="select select-bordered select-sm" name="scenario">
              <option :for={s <- @scenarios} value={s.id} selected={s.id == @active_scenario}>
                {s.name}
              </option>
            </select>
          </form>

          <button
            phx-click="apply_scenario"
            class={"btn btn-sm btn-primary #{if @applying, do: "loading btn-disabled"}"}
            disabled={@applying}
          >
            <%= if @applying do %>
              Applying...
            <% else %>
              Apply
            <% end %>
          </button>

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

        <div class="flex items-center gap-4">
          <span class="text-sm opacity-60">{@scenario.description}</span>
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
      </div>

      <div class={"grid grid-cols-1 md:grid-cols-2 lg:grid-cols-3 gap-4"}>
        <div :for={cam <- @cameras} class="card bg-base-200 shadow-xl">
          <div class="card-body p-4">
            <h2 class="card-title text-lg">{cam.name}</h2>

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
