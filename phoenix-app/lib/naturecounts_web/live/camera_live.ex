defmodule NaturecountsWeb.CameraLive do
  use NaturecountsWeb, :live_view

  alias Naturecounts.Detection.TrackerState
  alias Naturecounts.Pipeline.PipelineManager
  alias Naturecounts.CameraSettings
  alias Membrane.WebRTC.Live.Player

  @stats_interval 1000
  @retry_interval 5_000
  @max_retries 12

  @detector_models %{
    "rfdetr_nano" => %{
      label: "RF-DETR Nano (fast)",
      config_file: "config_infer_primary_cfd_rfdetr_nano.txt"
    },
    "yolov12x" => %{
      label: "YOLOv12x (accurate)",
      config_file: "config_infer_primary_cfd_yolov12_ds64.txt"
    }
  }

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

    saved = CameraSettings.get(camera_key)
    preset_key = saved["tracker_preset"] || "nvdcf_accuracy"
    preset_info = Map.get(@tracker_presets, preset_key, @tracker_presets["nvdcf_accuracy"])

    # Merge saved param overrides on top of preset defaults
    tracker_params =
      case saved["tracker_params"] do
        overrides when is_map(overrides) -> Map.merge(preset_info.defaults, overrides)
        _ -> preset_info.defaults
      end

    socket =
      socket
      |> assign(
        cam_id: cam_id,
        camera_key: camera_key,
        mediamtx_host: mediamtx_host,
        show_inference: saved["show_inference"],
        show_fish_list: saved["show_fish_list"],
        active_tracks: 0,
        total_tracks: 0,
        fish_cols: saved["fish_cols"],
        video_pct: saved["video_pct"],
        page_title: "Camera #{cam_id}",
        use_membrane: has_membrane,
        membrane_error: nil,
        pipeline_pid: nil,
        retry_count: 0,
        player_generation: 0,
        settings_panel_open: saved["settings_panel_open"],
        tracker_preset: preset_key,
        tracker_params: tracker_params,
        tracker_has_visual: preset_info.has_visual,
        tracker_presets: @tracker_presets,
        pipeline_restarting: false,
        min_crop_area: saved["min_crop_area"],
        min_sharpness: saved["min_sharpness"],
        detector_model: saved["detector_model"] || "rfdetr_nano",
        detector_models: @detector_models
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
    val = !socket.assigns.show_inference
    save_setting(socket, %{"show_inference" => val})
    {:noreply, assign(socket, show_inference: val)}
  end

  def handle_event("toggle_fish_list", _params, socket) do
    val = !socket.assigns.show_fish_list
    Phoenix.PubSub.broadcast(Naturecounts.PubSub, "pipeline:control", {:set_thumbnails, val})
    save_setting(socket, %{"show_fish_list" => val})
    {:noreply, assign(socket, show_fish_list: val)}
  end

  def handle_event("set_fish_cols", %{"cols" => cols}, socket) do
    val = String.to_integer(cols)
    save_setting(socket, %{"fish_cols" => val})
    {:noreply, assign(socket, fish_cols: val)}
  end

  def handle_event("set_video_pct", %{"pct" => pct}, socket) do
    val = String.to_integer(pct)
    save_setting(socket, %{"video_pct" => val})
    {:noreply, assign(socket, video_pct: val)}
  end

  def handle_event("toggle_settings_panel", _params, socket) do
    val = !socket.assigns.settings_panel_open
    save_setting(socket, %{"settings_panel_open" => val})
    {:noreply, assign(socket, settings_panel_open: val)}
  end

  def handle_event("select_tracker_preset", %{"preset" => preset}, socket) do
    case Map.get(@tracker_presets, preset) do
      nil ->
        {:noreply, socket}

      info ->
        save_setting(socket, %{
          "tracker_preset" => preset,
          "tracker_params" => info.defaults
        })

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
    save_setting(socket, %{"tracker_params" => params})
    {:noreply, assign(socket, tracker_params: params)}
  end

  def handle_event("set_min_crop_area", %{"value" => val_str}, socket) do
    val = String.to_integer(val_str)
    save_setting(socket, %{"min_crop_area" => val})
    broadcast_crop_filters(val, socket.assigns.min_sharpness)
    {:noreply, assign(socket, min_crop_area: val)}
  end

  def handle_event("set_min_sharpness", %{"value" => val_str}, socket) do
    {val, _} = Float.parse(val_str)
    save_setting(socket, %{"min_sharpness" => val})
    broadcast_crop_filters(socket.assigns.min_crop_area, val)
    {:noreply, assign(socket, min_sharpness: val)}
  end

  def handle_event("set_detector_model", %{"model" => model_key}, socket) do
    case Map.get(@detector_models, model_key) do
      nil ->
        {:noreply, socket}

      model_info ->
        save_setting(socket, %{"detector_model" => model_key})

        Phoenix.PubSub.broadcast(
          Naturecounts.PubSub,
          "pipeline:control",
          {:set_infer_config, %{config_path: model_info.config_file}}
        )

        {:noreply, assign(socket, detector_model: model_key, pipeline_restarting: true)}
    end
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

  defp save_setting(socket, updates) do
    CameraSettings.put(socket.assigns.camera_key, updates)
  end

  defp broadcast_crop_filters(min_crop_area, min_sharpness) do
    Phoenix.PubSub.broadcast(
      Naturecounts.PubSub,
      "pipeline:control",
      {:set_crop_filters, %{min_crop_area: min_crop_area, min_sharpness: min_sharpness}}
    )
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
    <div class="flex flex-col h-full">
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
        </div>
        <button
          class="btn btn-ghost btn-xs gap-1"
          phx-click="toggle_settings_panel"
        >
          <svg xmlns="http://www.w3.org/2000/svg" class="w-4 h-4" viewBox="0 0 20 20" fill="currentColor">
            <path fill-rule="evenodd" d="M11.49 3.17c-.38-1.56-2.6-1.56-2.98 0a1.532 1.532 0 01-2.286.948c-1.372-.836-2.942.734-2.106 2.106.54.886.061 2.042-.947 2.287-1.561.379-1.561 2.6 0 2.978a1.532 1.532 0 01.947 2.287c-.836 1.372.734 2.942 2.106 2.106a1.532 1.532 0 012.287.947c.379 1.561 2.6 1.561 2.978 0a1.533 1.533 0 012.287-.947c1.372.836 2.942-.734 2.106-2.106a1.533 1.533 0 01.947-2.287c1.561-.379 1.561-2.6 0-2.978a1.532 1.532 0 01-.947-2.287c.836-1.372-.734-2.942-2.106-2.106a1.532 1.532 0 01-2.287-.947zM10 13a3 3 0 100-6 3 3 0 000 6z" clip-rule="evenodd" />
          </svg>
          Settings
        </button>
      </div>

      <%!-- Settings tile (camera + tracker settings) --%>
      <%= if @settings_panel_open do %>
        <div class="px-2 shrink-0 mb-2">
          <div class="card card-compact bg-base-200">
            <div class="card-body p-3 space-y-3">
              <%!-- Camera settings --%>
              <div class="flex flex-wrap items-end gap-4">
                <label class="label cursor-pointer gap-2">
                  <span class="label-text text-sm">Inference</span>
                  <input
                    type="checkbox"
                    class="toggle toggle-primary toggle-sm"
                    checked={@show_inference}
                    phx-click="toggle_inference"
                  />
                </label>
                <label class="label cursor-pointer gap-2">
                  <span class="label-text text-sm">Fish List</span>
                  <input
                    type="checkbox"
                    class="toggle toggle-secondary toggle-sm"
                    checked={@show_fish_list}
                    phx-click="toggle_fish_list"
                  />
                </label>
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
              </div>

              <%!-- Crop quality filters --%>
              <div class="divider my-0 text-xs">Crop Quality</div>
              <div class="flex flex-wrap items-end gap-4">
                <form phx-change="set_min_crop_area" class="form-control">
                  <label class="label py-0"><span class="label-text text-xs">Min crop area (px)</span></label>
                  <div class="flex items-center gap-1">
                    <input
                      type="range"
                      class="range range-xs range-accent w-28"
                      min="500" max="50000" step="500"
                      value={@min_crop_area}
                      name="value"
                    />
                    <span class="text-xs font-mono w-14">{@min_crop_area}</span>
                  </div>
                  <label class="label py-0">
                    <span class="label-text-alt text-base-content/40">
                      ~{round(:math.sqrt(@min_crop_area))}x{round(:math.sqrt(@min_crop_area))} px
                    </span>
                  </label>
                </form>
                <form phx-change="set_min_sharpness" class="form-control">
                  <label class="label py-0"><span class="label-text text-xs">Min sharpness</span></label>
                  <div class="flex items-center gap-1">
                    <input
                      type="range"
                      class="range range-xs range-accent w-28"
                      min="0" max="500" step="10"
                      value={@min_sharpness}
                      name="value"
                    />
                    <span class="text-xs font-mono w-10">{@min_sharpness}</span>
                  </div>
                  <label class="label py-0">
                    <span class="label-text-alt text-base-content/40">
                      0 = off, ~100 = moderate, ~300 = sharp only
                    </span>
                  </label>
                </form>
              </div>

              <%!-- Detector model --%>
              <div class="divider my-0 text-xs">Detector
                <span class="badge badge-xs badge-neutral">{@detector_models[@detector_model].label}</span>
              </div>
              <div class="flex flex-wrap items-end gap-4">
                <form class="form-control" phx-change="set_detector_model">
                  <label class="label py-0"><span class="label-text text-xs">Model</span></label>
                  <select
                    class="select select-bordered select-xs w-56"
                    name="model"
                  >
                    <option
                      :for={{key, info} <- @detector_models}
                      value={key}
                      selected={key == @detector_model}
                    >
                      {info.label}
                    </option>
                  </select>
                </form>
              </div>

              <%!-- Tracker settings --%>
              <div class="divider my-0 text-xs">Tracker
                <span class="badge badge-xs badge-neutral">{@tracker_presets[@tracker_preset].label}</span>
              </div>
              <div class="flex flex-wrap items-end gap-4">
                <form class="form-control" phx-change="select_tracker_preset">
                  <label class="label py-0"><span class="label-text text-xs">Preset</span></label>
                  <select
                    class="select select-bordered select-xs w-56"
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
                </form>

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
                <form class="form-control" phx-change="update_tracker_param">
                  <label class="label py-0"><span class="label-text text-xs">Matcher</span></label>
                  <input type="hidden" name="param" value="associationMatcherType" />
                  <select
                    class="select select-bordered select-xs w-28"
                    name="value"
                  >
                    <option value="0" selected={@tracker_params["associationMatcherType"] == 0}>Greedy</option>
                    <option value="1" selected={@tracker_params["associationMatcherType"] == 1}>Global</option>
                  </select>
                </form>

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
                  <form class="form-control" phx-change="update_tracker_param">
                    <label class="label py-0"><span class="label-text text-xs">Feature Size</span></label>
                    <input type="hidden" name="param" value="featureImgSizeLevel" />
                    <select
                      class="select select-bordered select-xs w-20"
                      name="value"
                    >
                      <option :for={n <- 1..5} value={n} selected={@tracker_params["featureImgSizeLevel"] == n}>
                        {n}
                      </option>
                    </select>
                  </form>
                <% end %>

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
        </div>
      <% end %>

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
          phx-hook="FishList"
          data-cam-id={@cam_id}
          data-fish-cols={@fish_cols}
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
