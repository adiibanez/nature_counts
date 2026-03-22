defmodule NaturecountsWeb.CameraLive do
  use NaturecountsWeb, :live_view

  alias Naturecounts.Detection.TrackerState
  alias Naturecounts.Pipeline.PipelineManager
  alias Membrane.WebRTC.Live.Player

  @stats_interval 1000
  @retry_interval 5_000
  @max_retries 12

  @tracker_presets %{
    "iou" => %{label: "IOU (fastest)", has_visual: false, defaults: %{
      "minDetectorConfidence" => 0.0, "probationAge" => 4,
      "maxShadowTrackingAge" => 38, "minTrackerConfidence" => 0.0,
      "associationMatcherType" => 0
    }},
    "nvdcf_accuracy" => %{label: "NvDCF Accuracy (most stable)", has_visual: true, defaults: %{
      "minDetectorConfidence" => 0.3, "probationAge" => 3,
      "maxShadowTrackingAge" => 150, "minTrackerConfidence" => 0.1,
      "associationMatcherType" => 1,
      "filterLr" => 0.03, "processNoiseVar4Vel" => 0.1,
      "featureImgSizeLevel" => 3
    }},
    "nvdcf_perf" => %{label: "NvDCF Performance (balanced)", has_visual: true, defaults: %{
      "minDetectorConfidence" => 0.0, "probationAge" => 3,
      "maxShadowTrackingAge" => 30, "minTrackerConfidence" => 0.2,
      "associationMatcherType" => 0,
      "filterLr" => 0.075, "processNoiseVar4Vel" => 0.1,
      "featureImgSizeLevel" => 2
    }},
    "nvdcf_max_perf" => %{label: "NvDCF Max Performance (real-time)", has_visual: true, defaults: %{
      "minDetectorConfidence" => 0.0, "probationAge" => 3,
      "maxShadowTrackingAge" => 10, "minTrackerConfidence" => 0.2,
      "associationMatcherType" => 0,
      "filterLr" => 0.075, "processNoiseVar4Vel" => 0.1,
      "featureImgSizeLevel" => 1
    }}
  }

  @impl true
  def mount(%{"id" => cam_id_str}, _session, socket) do
    cam_id = String.to_integer(cam_id_str)
    camera_key = "cam#{cam_id + 1}"

    if connected?(socket) do
      schedule_stats_update()
    end

    mediamtx_host = Application.get_env(:naturecounts, :mediamtx_host, "localhost:8889")
    has_membrane = match?({:ok, _}, PipelineManager.get_source(camera_key))

    socket =
      socket
      |> assign(
        cam_id: cam_id,
        camera_key: camera_key,
        mediamtx_host: mediamtx_host,
        show_inference: true,
        show_fish_list: false,
        active_tracks: 0,
        total_tracks: 0,
        fish_cols: 1,
        video_pct: 65,
        page_title: "Camera #{cam_id}",
        use_membrane: has_membrane,
        membrane_error: nil,
        pipeline_pid: nil,
        retry_count: 0,
        player_generation: 0,
        tracker_panel_open: false,
        tracker_preset: "nvdcf_accuracy",
        tracker_params: @tracker_presets["nvdcf_accuracy"].defaults,
        tracker_has_visual: true,
        tracker_presets: @tracker_presets,
        pipeline_restarting: false
      )

    socket =
      if has_membrane and connected?(socket) do
        try_start_pipeline(socket)
      else
        socket
      end

    {:ok, socket}
  end

  defp try_start_pipeline(socket) do
    camera_key = socket.assigns.camera_key
    gen = socket.assigns.player_generation
    signaling = Membrane.WebRTC.Signaling.new()
    player_id = "membrane-player-#{camera_key}-#{gen}"

    case PipelineManager.start_viewer_pipeline(camera_key, signaling) do
      {:ok, _supervisor, pipeline} ->
        Process.monitor(pipeline)

        socket
        |> Player.attach(id: player_id, signaling: signaling)
        |> assign(pipeline_pid: pipeline, membrane_error: nil)

      {:error, reason} ->
        assign(socket,
          membrane_error: "Pipeline error: #{inspect(reason)}",
          use_membrane: false
        )
    end
  end

  # Pipeline crashed — retry with backoff
  @impl true
  def handle_info({:DOWN, _ref, :process, pid, _reason}, socket) do
    if pid == socket.assigns[:pipeline_pid] do
      retry_count = socket.assigns.retry_count + 1

      if retry_count <= @max_retries do
        Process.send_after(self(), :retry_membrane, @retry_interval)

        {:noreply,
         assign(socket,
           pipeline_pid: nil,
           retry_count: retry_count,
           membrane_error: "Stream disconnected, retrying (#{retry_count}/#{@max_retries})..."
         )}
      else
        {:noreply,
         assign(socket,
           pipeline_pid: nil,
           membrane_error: "Stream unavailable, using fallback",
           use_membrane: false
         )}
      end
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_info(:retry_membrane, socket) do
    # Bump generation so the Player component gets a fresh ID and re-mounts
    socket = assign(socket, player_generation: socket.assigns.player_generation + 1)
    {:noreply, try_start_pipeline(socket)}
  end

  @impl true
  def handle_info(:update_stats, socket) do
    cam_id = socket.assigns.cam_id
    stats = TrackerState.camera_stats(cam_id)
    schedule_stats_update()

    # Clear restarting flag once detections resume
    restarting =
      if socket.assigns.pipeline_restarting and stats.active_tracks > 0,
        do: false,
        else: socket.assigns.pipeline_restarting

    {:noreply,
     assign(socket,
       active_tracks: stats.active_tracks,
       total_tracks: stats.total_tracks,
       pipeline_restarting: restarting
     )}
  end

  @impl true
  def handle_event("toggle_inference", _params, socket) do
    {:noreply, assign(socket, show_inference: !socket.assigns.show_inference)}
  end

  def handle_event("toggle_fish_list", _params, socket) do
    new_val = !socket.assigns.show_fish_list
    Phoenix.PubSub.broadcast(Naturecounts.PubSub, "pipeline:control", {:set_thumbnails, new_val})
    {:noreply, assign(socket, show_fish_list: new_val)}
  end

  def handle_event("set_fish_cols", %{"cols" => cols}, socket) do
    {:noreply, assign(socket, fish_cols: String.to_integer(cols))}
  end

  def handle_event("set_video_pct", %{"pct" => pct}, socket) do
    {:noreply, assign(socket, video_pct: String.to_integer(pct))}
  end

  def handle_event("toggle_tracker_panel", _params, socket) do
    {:noreply, assign(socket, tracker_panel_open: !socket.assigns.tracker_panel_open)}
  end

  def handle_event("select_tracker_preset", %{"preset" => preset}, socket) do
    case Map.get(@tracker_presets, preset) do
      nil ->
        {:noreply, socket}

      info ->
        {:noreply,
         assign(socket,
           tracker_preset: preset,
           tracker_params: info.defaults,
           tracker_has_visual: info.has_visual
         )}
    end
  end

  def handle_event("update_tracker_param", %{"param" => key, "value" => value}, socket) do
    parsed =
      case Float.parse(value) do
        {f, ""} -> f
        _ ->
          case Integer.parse(value) do
            {i, ""} -> i
            _ -> value
          end
      end

    params = Map.put(socket.assigns.tracker_params, key, parsed)
    {:noreply, assign(socket, tracker_params: params)}
  end

  def handle_event("apply_tracker_config", _params, socket) do
    config = %{
      preset: socket.assigns.tracker_preset,
      overrides: socket.assigns.tracker_params
    }

    Phoenix.PubSub.broadcast(
      Naturecounts.PubSub,
      "pipeline:control",
      {:set_tracker_config, config}
    )

    {:noreply, assign(socket, pipeline_restarting: true)}
  end

  defp schedule_stats_update do
    Process.send_after(self(), :update_stats, @stats_interval)
  end

  attr :label, :string, required: true
  attr :param, :string, required: true
  attr :value, :any, required: true
  attr :min, :string, required: true
  attr :max, :string, required: true
  attr :step, :string, required: true

  defp tracker_slider(assigns) do
    ~H"""
    <div class="form-control">
      <label class="label py-0"><span class="label-text text-xs">{@label}</span></label>
      <div class="flex items-center gap-1">
        <input
          type="range"
          class="range range-xs range-primary w-24"
          min={@min} max={@max} step={@step}
          value={@value}
          phx-change="update_tracker_param"
          phx-value-param={@param}
          name="value"
        />
        <span class="text-xs font-mono w-10">{@value}</span>
      </div>
    </div>
    """
  end

  attr :label, :string, required: true
  attr :param, :string, required: true
  attr :value, :any, required: true
  attr :min, :string, required: true
  attr :max, :string, required: true

  defp tracker_number(assigns) do
    ~H"""
    <div class="form-control">
      <label class="label py-0"><span class="label-text text-xs">{@label}</span></label>
      <input
        type="number"
        class="input input-bordered input-xs w-20"
        min={@min} max={@max}
        value={@value}
        phx-change="update_tracker_param"
        phx-value-param={@param}
        name="value"
      />
    </div>
    """
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="flex flex-col h-[calc(100vh-4rem)]">
      <%!-- Header bar --%>
      <div class="flex items-center justify-between px-2 py-2 shrink-0">
        <div class="flex items-center gap-4">
          <h1 class="text-xl font-bold">Camera {@cam_id}</h1>
          <div class="stats stats-horizontal shadow-sm">
            <div class="stat py-1 px-3">
              <div class="stat-title text-xs">Active</div>
              <div class="stat-value text-primary text-lg">{@active_tracks}</div>
            </div>
            <div class="stat py-1 px-3">
              <div class="stat-title text-xs">Total</div>
              <div class="stat-value text-secondary text-lg">{@total_tracks}</div>
            </div>
          </div>
          <%= if @use_membrane do %>
            <span class="badge badge-success badge-sm">Membrane</span>
          <% else %>
            <span class="badge badge-warning badge-sm">MediaMTX</span>
          <% end %>
        </div>
        <div class="flex items-center gap-4">
          <form phx-change="set_video_pct" class="flex items-center gap-2">
            <span class="text-xs text-base-content/60">Video</span>
            <input
              type="range"
              min="30"
              max="90"
              value={@video_pct}
              class="range range-xs range-primary w-24"
              name="pct"
            />
            <span class="text-xs font-mono w-8">{@video_pct}%</span>
          </form>
          <div class="flex items-center gap-1">
            <span class="text-xs text-base-content/60">Cols</span>
            <div class="join">
              <button
                :for={n <- 1..4}
                class={"join-item btn btn-xs #{if @fish_cols == n, do: "btn-primary", else: "btn-ghost"}"}
                phx-click="set_fish_cols"
                phx-value-cols={n}
              >
                {n}
              </button>
            </div>
          </div>
          <label class="label cursor-pointer gap-2">
            <span class="label-text text-sm">Fish List</span>
            <input
              type="checkbox"
              class="toggle toggle-secondary toggle-sm"
              checked={@show_fish_list}
              phx-click="toggle_fish_list"
            />
          </label>
          <label class="label cursor-pointer gap-2">
            <span class="label-text text-sm">Inference</span>
            <input
              type="checkbox"
              class="toggle toggle-primary toggle-sm"
              checked={@show_inference}
              phx-click="toggle_inference"
            />
          </label>
          <.link navigate={~p"/"} class="btn btn-ghost btn-sm">Back</.link>
        </div>
      </div>

      <%!-- Tracker settings panel --%>
      <div class="px-2 shrink-0">
        <button
          class="btn btn-ghost btn-xs gap-1"
          phx-click="toggle_tracker_panel"
        >
          <svg xmlns="http://www.w3.org/2000/svg" class={"w-4 h-4 transition-transform #{if @tracker_panel_open, do: "rotate-90"}"} viewBox="0 0 20 20" fill="currentColor">
            <path fill-rule="evenodd" d="M7.21 14.77a.75.75 0 01.02-1.06L11.168 10 7.23 6.29a.75.75 0 111.04-1.08l4.5 4.25a.75.75 0 010 1.08l-4.5 4.25a.75.75 0 01-1.06-.02z" clip-rule="evenodd" />
          </svg>
          Tracker Settings
          <span class="badge badge-xs badge-neutral">{@tracker_presets[@tracker_preset].label}</span>
        </button>

        <%= if @tracker_panel_open do %>
          <div class="card card-compact bg-base-200 mt-1 mb-2">
            <div class="card-body p-3">
              <div class="flex flex-wrap items-end gap-4">
                <%!-- Preset selector --%>
                <div class="form-control">
                  <label class="label py-0"><span class="label-text text-xs">Preset</span></label>
                  <select
                    class="select select-bordered select-xs w-56"
                    phx-change="select_tracker_preset"
                    name="preset"
                  >
                    <option
                      :for={{key, info} <- @tracker_presets}
                      value={key}
                      selected={key == @tracker_preset}
                    >
                      {info.label}
                    </option>
                  </select>
                </div>

                <%!-- Common parameters --%>
                <.tracker_slider
                  label="Min Detector Confidence"
                  param="minDetectorConfidence"
                  value={@tracker_params["minDetectorConfidence"]}
                  min="0" max="1" step="0.05"
                />
                <.tracker_number
                  label="Probation Age"
                  param="probationAge"
                  value={@tracker_params["probationAge"]}
                  min="1" max="10"
                />
                <.tracker_number
                  label="Shadow Tracking Age"
                  param="maxShadowTrackingAge"
                  value={@tracker_params["maxShadowTrackingAge"]}
                  min="5" max="500"
                />
                <.tracker_slider
                  label="Min Tracker Confidence"
                  param="minTrackerConfidence"
                  value={@tracker_params["minTrackerConfidence"]}
                  min="0" max="1" step="0.05"
                />
                <div class="form-control">
                  <label class="label py-0"><span class="label-text text-xs">Matcher</span></label>
                  <select
                    class="select select-bordered select-xs w-28"
                    phx-change="update_tracker_param"
                    name="value"
                    data-param="associationMatcherType"
                    phx-value-param="associationMatcherType"
                  >
                    <option value="0" selected={@tracker_params["associationMatcherType"] == 0}>Greedy</option>
                    <option value="1" selected={@tracker_params["associationMatcherType"] == 1}>Global</option>
                  </select>
                </div>

                <%!-- NvDCF-only parameters --%>
                <%= if @tracker_has_visual do %>
                  <.tracker_slider
                    label="Filter LR"
                    param="filterLr"
                    value={@tracker_params["filterLr"]}
                    min="0.01" max="0.2" step="0.005"
                  />
                  <.tracker_slider
                    label="Velocity Noise"
                    param="processNoiseVar4Vel"
                    value={@tracker_params["processNoiseVar4Vel"]}
                    min="0.01" max="1.0" step="0.01"
                  />
                  <div class="form-control">
                    <label class="label py-0"><span class="label-text text-xs">Feature Size</span></label>
                    <select
                      class="select select-bordered select-xs w-20"
                      phx-change="update_tracker_param"
                      name="value"
                      phx-value-param="featureImgSizeLevel"
                    >
                      <option :for={n <- 1..5} value={n} selected={@tracker_params["featureImgSizeLevel"] == n}>
                        {n}
                      </option>
                    </select>
                  </div>
                <% end %>

                <%!-- Apply button --%>
                <button
                  class={"btn btn-primary btn-xs #{if @pipeline_restarting, do: "btn-disabled loading"}"}
                  phx-click="apply_tracker_config"
                  disabled={@pipeline_restarting}
                >
                  <%= if @pipeline_restarting do %>
                    Restarting...
                  <% else %>
                    Apply
                  <% end %>
                </button>
              </div>
            </div>
          </div>
        <% end %>
      </div>

      <%!-- Main content: video left, fish panel right --%>
      <div class="flex gap-3 px-2 min-h-0 flex-1">
        <%!-- Video stream --%>
        <div style={"width: #{@video_pct}%"} class="shrink-0 min-w-0">
          <%= if @use_membrane do %>
            <div class="w-full bg-black rounded-lg overflow-hidden">
              <%= if @pipeline_pid do %>
                <Player.live_render
                  socket={@socket}
                  player_id={"membrane-player-#{@camera_key}-#{@player_generation}"}
                  class="w-full h-auto"
                />
              <% else %>
                <div class="flex items-center justify-center aspect-video text-white/60">
                  <span class="loading loading-spinner loading-lg"></span>
                </div>
              <% end %>
            </div>
          <% else %>
            <div
              id={"video-player-cam#{@cam_id}"}
              phx-hook="VideoOverlay"
              data-cam-id={@cam_id}
              data-fish-cols={@fish_cols}
              data-webrtc-url={
                if @show_inference,
                  do: "http://#{@mediamtx_host}/cam#{@cam_id + 1}/whep",
                  else: "http://#{@mediamtx_host}/raw-cam#{@cam_id + 1}/whep"
              }
              class="relative w-full bg-black rounded-lg overflow-hidden"
            >
              <video
                id={"video-cam#{@cam_id}"}
                autoplay
                muted
                playsinline
                class="w-full h-auto"
              >
              </video>
            </div>
          <% end %>
          <%= if @membrane_error do %>
            <div class="alert alert-warning mt-2 text-sm">{@membrane_error}</div>
          <% end %>
        </div>

        <%!-- Fish panel --%>
        <div
          id={"fish-panel-cam#{@cam_id}"}
          class={"flex-1 flex flex-col min-h-0 min-w-0 #{unless @show_fish_list, do: "hidden"}"}
        >
          <h2 class="text-sm font-semibold mb-2 shrink-0">
            Fish (<span id={"fish-count-cam#{@cam_id}"}>0</span>)
          </h2>
          <div id={"fish-empty-cam#{@cam_id}"} class="text-base-content/50 italic text-sm">
            No fish currently detected.
          </div>
          <div
            id={"fish-grid-cam#{@cam_id}"}
            phx-update="ignore"
            class="grid gap-2 overflow-y-auto pr-1"
            style="grid-template-columns: repeat(1, minmax(0, 1fr));"
          >
          </div>
        </div>
      </div>
    </div>
    """
  end
end
