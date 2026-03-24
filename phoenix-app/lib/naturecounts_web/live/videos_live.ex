defmodule NaturecountsWeb.VideosLive do
  use NaturecountsWeb, :live_view

  alias Naturecounts.Repo
  alias Naturecounts.Offline.{Video, Profiles, ProcessVideoWorker, ScanMetricsWorker, VlmContexts}

  import Ecto.Query

  @refresh_interval 2000
  @videos_root "/videos"
  @video_extensions ~w(.mp4 .avi .mkv .mov .ts)

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      schedule_refresh()
      Phoenix.PubSub.subscribe(Naturecounts.PubSub, "scan:progress")
    end

    jobs = list_jobs()
    processed_files = load_processed_files()
    entries = list_dir(@videos_root, processed_files)

    default_profile = Profiles.get("standard")

    {:ok,
     assign(socket,
       page_title: "Video Processing",
       current_dir: @videos_root,
       breadcrumbs: [],
       entries: entries,
       processed_files: processed_files,
       jobs: jobs,
       selected_file: nil,
       preview_url: nil,
       selected_files: MapSet.new(),
       selected_profile: "standard",
       profiles: Profiles.all(),
       min_bbox_area: default_profile.min_bbox_area,
       vlm_sample_pct: default_profile.vlm_sample_pct,
       fishial_enabled: default_profile.fishial_enabled,
       vlm_enabled: default_profile.vlm_enabled,
       fishial_ready: Naturecounts.Offline.FishialSetup.ready?(),
       classification_ttl_days: Application.get_env(:naturecounts, :classification_ttl_days, 30),
       vlm_contexts: VlmContexts.list(),
       selected_context_id: List.first(VlmContexts.list())["id"],
       vlm_context_prompt: List.first(VlmContexts.list())["prompt"],
       editing_context: false,
       context_name: "",
       scanning: scan_running?(),
       scan_progress: nil,
       sort_by: "name",
       sort_dir: "asc"
     )}
  end

  @impl true
  def handle_info({:scan_progress, _directory, progress}, socket) do
    {:noreply, assign(socket, scanning: true, scan_progress: progress)}
  end

  def handle_info({:scan_complete, _directory}, socket) do
    processed_files = load_processed_files()
    entries =
      list_dir(socket.assigns.current_dir, processed_files)
      |> sort_entries(socket.assigns.sort_by, socket.assigns.sort_dir)

    {:noreply,
     socket
     |> assign(scanning: false, scan_progress: nil, entries: entries, processed_files: processed_files)
     |> put_flash(:info, "Metrics scan complete")}
  end

  @impl true
  def handle_info(:refresh, socket) do
    schedule_refresh()
    was_scanning = socket.assigns.scanning
    scanning = if was_scanning, do: scan_running?(), else: false

    socket = assign(socket, jobs: list_jobs(), scanning: scanning)

    cond do
      # Scan just finished — reload entries to pick up new metrics
      was_scanning and not scanning ->
        processed_files = load_processed_files()
        entries =
          list_dir(socket.assigns.current_dir, processed_files)
          |> sort_entries(socket.assigns.sort_by, socket.assigns.sort_dir)

        {:noreply, assign(socket, entries: entries, processed_files: processed_files, scan_progress: nil)}

      # Scan running — read progress from any progress file
      scanning ->
        progress = read_scan_progress()
        {:noreply, assign(socket, scan_progress: progress)}

      true ->
        {:noreply, socket}
    end
  end

  # --- Navigation events ---

  @impl true
  def handle_event("navigate_dir", %{"path" => path}, socket) do
    safe_path = safe_resolve(path)
    entries =
      list_dir(safe_path, socket.assigns.processed_files)
      |> sort_entries(socket.assigns.sort_by, socket.assigns.sort_dir)
    breadcrumbs = build_breadcrumbs(safe_path)

    {:noreply,
     socket
     |> assign(
       current_dir: safe_path,
       breadcrumbs: breadcrumbs,
       entries: entries,
       selected_file: nil,
       preview_url: nil,
       selected_files: MapSet.new()
     )
     |> push_event("preview", %{url: nil, filename: nil})}
  end

  def handle_event("select_file", %{"file" => file}, socket) do
    relative = Path.relative_to(file, @videos_root)
    preview_url = "/serve/videos/#{relative}"

    {:noreply,
     socket
     |> assign(selected_file: file, preview_url: preview_url)
     |> push_event("preview", %{url: preview_url, filename: Path.basename(file)})}
  end

  def handle_event("toggle_select", %{"file" => file}, socket) do
    selected = socket.assigns.selected_files

    selected =
      if MapSet.member?(selected, file),
        do: MapSet.delete(selected, file),
        else: MapSet.put(selected, file)

    {:noreply, assign(socket, selected_files: selected)}
  end

  def handle_event("delete_selected", _params, socket) do
    selected = socket.assigns.selected_files
    count = MapSet.size(selected)

    Enum.each(selected, fn path ->
      safe = safe_resolve(path)
      if File.regular?(safe), do: File.rm(safe)
    end)

    processed_files = load_processed_files()
    entries =
      list_dir(socket.assigns.current_dir, processed_files)
      |> sort_entries(socket.assigns.sort_by, socket.assigns.sort_dir)

    preview_url =
      if MapSet.member?(selected, socket.assigns.selected_file || ""),
        do: nil,
        else: socket.assigns.preview_url

    selected_file =
      if MapSet.member?(selected, socket.assigns.selected_file || ""),
        do: nil,
        else: socket.assigns.selected_file

    {:noreply,
     socket
     |> assign(
       entries: entries,
       processed_files: processed_files,
       selected_files: MapSet.new(),
       selected_file: selected_file,
       preview_url: preview_url
     )
     |> put_flash(:info, "Deleted #{count} file(s)")}
  end

  def handle_event("clear_selection", _params, socket) do
    {:noreply, assign(socket, selected_files: MapSet.new())}
  end

  def handle_event("select_black_videos", _params, socket) do
    black_files =
      socket.assigns.entries
      |> Enum.filter(fn entry ->
        entry.type == :file and
          entry.metrics != nil and
          entry.metrics["avg_detections_per_frame"] == 0.0
      end)
      |> Enum.map(& &1.path)
      |> MapSet.new()

    if MapSet.size(black_files) > 0 do
      {:noreply,
       socket
       |> assign(selected_files: black_files)
       |> put_flash(:info, "Selected #{MapSet.size(black_files)} empty video(s) (0 detections)")}
    else
      {:noreply, put_flash(socket, :info, "No empty videos found (run Scan first)")}
    end
  end

  def handle_event("delete_file", %{"file" => file}, socket) do
    safe = safe_resolve(file)

    if File.regular?(safe) do
      File.rm(safe)

      processed_files = load_processed_files()
      entries =
        list_dir(socket.assigns.current_dir, processed_files)
        |> sort_entries(socket.assigns.sort_by, socket.assigns.sort_dir)

      {selected_file, preview_url} =
        if socket.assigns.selected_file == file,
          do: {nil, nil},
          else: {socket.assigns.selected_file, socket.assigns.preview_url}

      {:noreply,
       socket
       |> assign(
         entries: entries,
         processed_files: processed_files,
         selected_files: MapSet.delete(socket.assigns.selected_files, file),
         selected_file: selected_file,
         preview_url: preview_url
       )
       |> put_flash(:info, "Deleted #{Path.basename(file)}")}
    else
      {:noreply, put_flash(socket, :error, "File not found")}
    end
  end

  def handle_event("select_profile", %{"profile" => profile}, socket) do
    p = Profiles.get(profile)
    {:noreply, assign(socket, selected_profile: profile, min_bbox_area: p.min_bbox_area, vlm_sample_pct: p.vlm_sample_pct, fishial_enabled: p.fishial_enabled, vlm_enabled: p.vlm_enabled)}
  end

  def handle_event("set_min_bbox_area", %{"area" => area_str}, socket) do
    area = String.to_integer(area_str)
    {:noreply, assign(socket, min_bbox_area: area)}
  end

  def handle_event("sort_files", %{"col" => col}, socket) do
    {sort_by, sort_dir} =
      if socket.assigns.sort_by == col do
        {col, if(socket.assigns.sort_dir == "asc", do: "desc", else: "asc")}
      else
        {col, "asc"}
      end

    entries = sort_entries(socket.assigns.entries, sort_by, sort_dir)
    {:noreply, assign(socket, sort_by: sort_by, sort_dir: sort_dir, entries: entries)}
  end

  def handle_event("scan_metrics", _params, socket) do
    %{"directory" => socket.assigns.current_dir}
    |> ScanMetricsWorker.new()
    |> Oban.insert!()

    {:noreply, assign(socket, scanning: true)}
  end

  def handle_event("cancel_scan", _params, socket) do
    import Ecto.Query

    # Signal cancellation via file
    File.write!(Path.join(System.tmp_dir!(), "scan_cancel"), "")

    # Cancel Oban jobs
    Oban.Job
    |> where([j], j.worker == "Naturecounts.Offline.ScanMetricsWorker")
    |> where([j], j.state in ["available", "executing", "scheduled"])
    |> Repo.all()
    |> Enum.each(&Oban.cancel_job(&1.id))

    # Reload entries to show whatever was scanned so far
    processed_files = load_processed_files()
    entries =
      list_dir(socket.assigns.current_dir, processed_files)
      |> sort_entries(socket.assigns.sort_by, socket.assigns.sort_dir)

    {:noreply,
     socket
     |> assign(scanning: false, scan_progress: nil, entries: entries, processed_files: processed_files)
     |> put_flash(:info, "Scan cancelled")}
  end

  def handle_event("set_vlm_sample_pct", %{"pct" => pct_str}, socket) do
    {:noreply, assign(socket, vlm_sample_pct: String.to_integer(pct_str))}
  end

  def handle_event("set_ttl_days", %{"days" => days_str}, socket) do
    days = String.to_integer(days_str)
    {:noreply, assign(socket, classification_ttl_days: days)}
  end

  def handle_event("toggle_fishial", _params, socket) do
    {:noreply, assign(socket, fishial_enabled: !socket.assigns.fishial_enabled)}
  end

  def handle_event("toggle_vlm", _params, socket) do
    {:noreply, assign(socket, vlm_enabled: !socket.assigns.vlm_enabled)}
  end

  def handle_event("select_context", %{"id" => ""}, socket), do: {:noreply, socket}

  def handle_event("select_context", %{"id" => id}, socket) do
    case VlmContexts.get(id) do
      nil ->
        {:noreply, socket}

      ctx ->
        {:noreply,
         assign(socket,
           selected_context_id: id,
           vlm_context_prompt: ctx["prompt"],
           editing_context: false
         )}
    end
  end

  def handle_event("edit_context_prompt", %{"prompt" => prompt}, socket) do
    {:noreply, assign(socket, vlm_context_prompt: prompt)}
  end

  def handle_event("new_context", _params, socket) do
    {:noreply, assign(socket, editing_context: true, context_name: "", selected_context_id: nil, vlm_context_prompt: "")}
  end

  def handle_event("set_context_name", %{"name" => name}, socket) do
    {:noreply, assign(socket, context_name: name)}
  end

  def handle_event("save_context", _params, socket) do
    name = String.trim(socket.assigns.context_name)
    prompt = String.trim(socket.assigns.vlm_context_prompt)

    if name == "" or prompt == "" do
      {:noreply, put_flash(socket, :error, "Context name and prompt are required")}
    else
      id =
        case socket.assigns.selected_context_id do
          nil -> VlmContexts.add(name, prompt)
          existing_id -> VlmContexts.update(existing_id, name, prompt)
        end

      {:noreply,
       assign(socket,
         vlm_contexts: VlmContexts.list(),
         selected_context_id: id,
         editing_context: false
       )}
    end
  end

  def handle_event("edit_context", _params, socket) do
    ctx = VlmContexts.get(socket.assigns.selected_context_id)
    name = if ctx, do: ctx["name"], else: ""
    {:noreply, assign(socket, editing_context: true, context_name: name)}
  end

  def handle_event("cancel_edit_context", _params, socket) do
    # Restore prompt from saved context
    ctx = VlmContexts.get(socket.assigns.selected_context_id)
    prompt = if ctx, do: ctx["prompt"], else: socket.assigns.vlm_context_prompt
    {:noreply, assign(socket, editing_context: false, vlm_context_prompt: prompt)}
  end

  def handle_event("delete_context", _params, socket) do
    if socket.assigns.selected_context_id do
      VlmContexts.delete(socket.assigns.selected_context_id)
      contexts = VlmContexts.list()
      first = List.first(contexts)

      {:noreply,
       assign(socket,
         vlm_contexts: contexts,
         selected_context_id: first && first["id"],
         vlm_context_prompt: (first && first["prompt"]) || "",
         editing_context: false
       )}
    else
      {:noreply, socket}
    end
  end

  def handle_event("start_processing", _params, socket) do
    file = socket.assigns.selected_file
    profile = socket.assigns.selected_profile

    if file do
      video =
        %Video{}
        |> Video.changeset(%{
          filename: Path.basename(file),
          path: file,
          processing_profile: profile,
          min_bbox_area: socket.assigns.min_bbox_area,
          vlm_sample_pct: socket.assigns.vlm_sample_pct,
          fishial_enabled: socket.assigns.fishial_enabled,
          vlm_enabled: socket.assigns.vlm_enabled,
          location: socket.assigns.vlm_context_prompt
        })
        |> Repo.insert!()

      %{video_id: video.id}
      |> ProcessVideoWorker.new()
      |> Oban.insert!()

      {:noreply,
       socket
       |> assign(selected_file: nil, preview_url: nil, jobs: list_jobs())
       |> put_flash(:info, "Processing started for #{Path.basename(file)}")}
    else
      {:noreply, put_flash(socket, :error, "No file selected")}
    end
  end

  def handle_event("cancel_job", %{"id" => id}, socket) do
    video = Repo.get!(Video, id)

    Oban.Job
    |> where([j], j.args == ^%{"video_id" => video.id})
    |> where([j], j.state in ["available", "executing", "scheduled", "retryable"])
    |> Repo.all()
    |> Enum.each(&Oban.cancel_job(&1.id))

    video
    |> Ecto.Changeset.change(%{status: "failed", progress_pct: 0, error_message: "Cancelled by user"})
    |> Repo.update!()

    {:noreply, assign(socket, jobs: list_jobs())}
  end

  def handle_event("retry_job", %{"id" => id}, socket) do
    video = Repo.get!(Video, id)

    video
    |> Ecto.Changeset.change(%{status: "pending", progress_pct: 0, error_message: nil})
    |> Repo.update!()

    %{video_id: video.id}
    |> ProcessVideoWorker.new()
    |> Oban.insert!()

    {:noreply, assign(socket, jobs: list_jobs())}
  end

  def handle_event("delete_job", %{"id" => id}, socket) do
    video = Repo.get!(Video, id)

    Oban.Job
    |> where([j], j.args == ^%{"video_id" => video.id})
    |> where([j], j.state in ["available", "executing", "scheduled", "retryable"])
    |> Repo.all()
    |> Enum.each(&Oban.cancel_job(&1.id))

    Repo.delete!(video)
    {:noreply, assign(socket, jobs: list_jobs())}
  end

  # --- Helpers ---

  defp safe_resolve(path) do
    expanded = Path.expand(path)

    if String.starts_with?(expanded, @videos_root) do
      expanded
    else
      @videos_root
    end
  end

  defp build_breadcrumbs(current_dir) do
    relative = Path.relative_to(current_dir, @videos_root)

    if relative == current_dir or relative == "." do
      []
    else
      relative
      |> Path.split()
      |> Enum.scan([], fn segment, acc -> acc ++ [segment] end)
      |> Enum.map(fn segments ->
        %{name: List.last(segments), path: Path.join([@videos_root | segments])}
      end)
    end
  end

  defp read_scan_progress do
    progress_file = Path.join(System.tmp_dir!(), "scan_progress.json")

    case File.read(progress_file) do
      {:ok, data} ->
        case Jason.decode(data) do
          {:ok, progress} -> progress
          _ -> nil
        end

      _ ->
        nil
    end
  end

  defp scan_running? do
    import Ecto.Query

    Oban.Job
    |> where([j], j.worker == "Naturecounts.Offline.ScanMetricsWorker")
    |> where([j], j.state in ["available", "executing", "scheduled"])
    |> Repo.exists?()
  end

  defp load_metrics_index(dir) do
    index_path = Path.join(dir, ".metrics.json")

    case File.read(index_path) do
      {:ok, data} ->
        case Jason.decode(data) do
          {:ok, index} -> index
          _ -> %{}
        end

      _ ->
        %{}
    end
  end

  defp load_processed_files do
    Video
    |> where([v], v.status in ["completed", "processing", "pending"])
    |> select([v], {v.path, %{status: v.status, profile: v.processing_profile}})
    |> Repo.all()
    |> Map.new()
  end

  defp list_dir(dir, processed_files) do
    metrics = load_metrics_index(dir)

    case File.ls(dir) do
      {:ok, names} ->
        names
        |> Enum.filter(&is_binary/1)
        |> Enum.filter(&String.valid?/1)
        |> Enum.sort()
        |> Enum.reduce({[], []}, fn name, {dirs, files} ->
          path = Path.join(dir, name)

          cond do
            File.dir?(path) and not String.starts_with?(name, ".") ->
              {dirs ++ [%{type: :dir, name: name, path: path}], files}

            video_file?(name) ->
              stat = File.stat!(path)
              size_mb = Float.round(stat.size / 1_048_576, 1)
              proc = Map.get(processed_files, path)
              m = Map.get(metrics, name)
              {dirs, files ++ [%{type: :file, name: name, path: path, size_mb: size_mb, processed: proc, metrics: m}]}

            true ->
              {dirs, files}
          end
        end)
        |> then(fn {dirs, files} -> dirs ++ files end)

      _ ->
        []
    end
  end

  defp video_file?(name) do
    ext = name |> Path.extname() |> String.downcase()
    ext in @video_extensions
  end

  defp sort_indicator(current, dir, col) do
    if current == col do
      if dir == "asc", do: "▲", else: "▼"
    else
      ""
    end
  end

  defp sort_entries(entries, sort_by, sort_dir) do
    {dirs, files} = Enum.split_with(entries, &(&1.type == :dir))

    sorted_files =
      case sort_by do
        "name" ->
          Enum.sort_by(files, & &1.name)

        "size" ->
          Enum.sort_by(files, & &1.size_mb)

        "det" ->
          Enum.sort_by(files, fn f ->
            case f.metrics do
              %{"avg_detections_per_frame" => v} when is_number(v) -> v
              _ -> -1
            end
          end)

        _ ->
          files
      end

    sorted_files = if sort_dir == "desc", do: Enum.reverse(sorted_files), else: sorted_files

    dirs ++ sorted_files
  end

  defp profile_bg("light"), do: "bg-success/10"
  defp profile_bg("standard"), do: "bg-warning/10"
  defp profile_bg("deep"), do: "bg-error/10"
  defp profile_bg(_), do: "bg-base-300/20"

  defp profile_dot("light"), do: "bg-success"
  defp profile_dot("standard"), do: "bg-warning"
  defp profile_dot("deep"), do: "bg-error"
  defp profile_dot(_), do: "bg-base-content/30"

  defp list_jobs do
    Video
    |> order_by(desc: :inserted_at)
    |> limit(20)
    |> Repo.all()
  end

  defp schedule_refresh do
    Process.send_after(self(), :refresh, @refresh_interval)
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="p-4">
      <h1 class="text-2xl font-bold mb-6">Video Processing</h1>

      <div class="grid grid-cols-1 lg:grid-cols-3 gap-6">
        <%!-- File browser --%>
        <div class="card bg-base-200">
          <div class="card-body">
            <h2 class="card-title text-lg">Browse Files</h2>

            <%!-- Breadcrumbs + Scan --%>
            <div class="flex items-center justify-between">
              <div class="text-sm breadcrumbs py-0">
                <ul>
                  <li>
                    <a class="link link-hover" phx-click="navigate_dir" phx-value-path="/videos">
                      /videos
                    </a>
                  </li>
                  <li :for={crumb <- @breadcrumbs}>
                    <a class="link link-hover" phx-click="navigate_dir" phx-value-path={crumb.path}>
                      {crumb.name}
                    </a>
                  </li>
              </ul>
              </div>
              <div class="flex items-center gap-1">
                <%= if @scanning do %>
                  <button
                    class="btn btn-error btn-xs gap-1"
                    phx-click="cancel_scan"
                  >
                    <span class="loading loading-spinner loading-xs"></span>
                    Cancel
                  </button>
                <% else %>
                  <button class="btn btn-ghost btn-xs" phx-click="scan_metrics">Scan</button>
                  <button
                    class="btn btn-ghost btn-xs"
                    phx-click="select_black_videos"
                    title="Select videos with avg brightness < 15 (night recordings)"
                  >
                    Select dark
                  </button>
                <% end %>
              </div>
            </div>

            <%= if @scanning and @scan_progress do %>
              <div class="flex items-center gap-2 text-xs text-base-content/60">
                <progress
                  class="progress progress-primary flex-1"
                  value={@scan_progress["done"] || 0}
                  max={@scan_progress["total"] || 1}
                />
                <span class="whitespace-nowrap">
                  {@scan_progress["done"]}/{@scan_progress["total"]}
                </span>
                <span class="truncate max-w-[120px] font-mono" title={@scan_progress["current"]}>
                  {@scan_progress["current"]}
                </span>
              </div>
            <% end %>

            <%!-- Delete bar --%>
            <%= if MapSet.size(@selected_files) > 0 do %>
              <div class="flex items-center gap-2 py-1">
                <span class="text-xs text-base-content/60">{MapSet.size(@selected_files)} selected</span>
                <button
                  class="btn btn-error btn-xs"
                  phx-click="delete_selected"
                  data-confirm={"Delete #{MapSet.size(@selected_files)} file(s)? This cannot be undone."}
                >
                  Delete selected
                </button>
                <button
                  class="btn btn-ghost btn-xs"
                  phx-click="clear_selection"
                >
                  Clear
                </button>
              </div>
            <% end %>

            <%!-- File listing --%>
            <div class="overflow-y-auto max-h-80">
              <%= if Enum.empty?(@entries) do %>
                <p class="text-base-content/50 italic text-sm">No video files in this directory.</p>
              <% else %>
                <table class="table table-sm">
                  <thead>
                    <tr>
                      <th class="w-8"></th>
                      <th class="cursor-pointer select-none" phx-click="sort_files" phx-value-col="name">
                        Name {sort_indicator(@sort_by, @sort_dir, "name")}
                      </th>
                      <th class="cursor-pointer select-none" phx-click="sort_files" phx-value-col="size">
                        Size {sort_indicator(@sort_by, @sort_dir, "size")}
                      </th>
                      <th class="cursor-pointer select-none" phx-click="sort_files" phx-value-col="det" title="Avg detections per sampled frame">
                        Det {sort_indicator(@sort_by, @sort_dir, "det")}
                      </th>
                    </tr>
                  </thead>
                  <tbody>
                    <%= for entry <- @entries do %>
                      <%= if entry.type == :dir do %>
                        <tr
                          class="hover cursor-pointer"
                          phx-click="navigate_dir"
                          phx-value-path={entry.path}
                        >
                          <td></td>
                          <td class="font-mono text-sm">
                            <span class="text-primary">📁</span> {entry.name}/
                          </td>
                          <td></td>
                          <td></td>
                        </tr>
                      <% else %>
                        <tr class={[
                            "hover",
                            @selected_file == entry.path && "bg-primary/20",
                            MapSet.member?(@selected_files, entry.path) && "bg-error/10",
                            entry.processed && entry.processed.status == "completed" && profile_bg(entry.processed.profile),
                            entry.processed && entry.processed.status == "processing" && "bg-info/10",
                            entry.processed && entry.processed.status == "pending" && "bg-base-300/50"
                          ]}
                        >
                          <td>
                            <input
                              type="checkbox"
                              class="checkbox checkbox-xs checkbox-error"
                              checked={MapSet.member?(@selected_files, entry.path)}
                              phx-click="toggle_select"
                              phx-value-file={entry.path}
                            />
                          </td>
                          <td
                            class="font-mono text-sm truncate max-w-[200px] cursor-pointer"
                            title={entry.name}
                            phx-click="select_file"
                            phx-value-file={entry.path}
                          >
                            <span class="flex items-center gap-1">
                              <%= if entry.processed do %>
                                <span class={[
                                  "w-2 h-2 rounded-full shrink-0",
                                  entry.processed.status == "completed" && profile_dot(entry.processed.profile),
                                  entry.processed.status == "processing" && "bg-info animate-pulse",
                                  entry.processed.status == "pending" && "bg-base-content/30"
                                ]} title={"#{entry.processed.status} (#{entry.processed.profile})"} />
                              <% end %>
                              {entry.name}
                            </span>
                          </td>
                          <td class="text-sm text-base-content/60 whitespace-nowrap">{entry.size_mb} MB</td>
                          <td class="text-xs font-mono text-base-content/50">
                            <%= if entry.metrics && !entry.metrics["error"] do %>
                              <span class="flex items-center gap-1" title={"brightness: #{entry.metrics["avg_brightness"] || "?"}/255, #{entry.metrics["bbox_areas"]["count"]} bboxes, #{entry.metrics["duration_s"]}s"}>
                                <%= if is_number(entry.metrics["avg_brightness"]) and entry.metrics["avg_brightness"] < 15 do %>
                                  <span class="w-2 h-2 rounded-full bg-black border border-base-content/20 shrink-0" title="Dark video" />
                                <% end %>
                                {entry.metrics["avg_detections_per_frame"]}
                              </span>
                            <% end %>
                          </td>
                        </tr>
                      <% end %>
                    <% end %>
                  </tbody>
                </table>
              <% end %>
            </div>

            <%!-- Profile selector + start --%>
            <div class="form-control mt-4">
              <label class="label"><span class="label-text">Processing Profile</span></label>
              <div class="join">
                <button
                  :for={{key, profile} <- @profiles}
                  class={"join-item btn btn-sm #{if @selected_profile == key, do: "btn-primary", else: "btn-ghost"}"}
                  phx-click="select_profile"
                  phx-value-profile={key}
                >
                  {profile.label}
                </button>
              </div>
              <label class="label">
                <span class="label-text-alt text-base-content/50">
                  {(@profiles[@selected_profile] || %{}).description}
                </span>
              </label>
            </div>

            <div class="flex gap-4 mt-2">
              <form phx-change="set_min_bbox_area" class="form-control flex-1">
                <label class="label py-0"><span class="label-text text-xs">Min detection area (px)</span></label>
                <div class="flex items-center gap-2">
                  <input
                    type="range"
                    min="1000"
                    max="100000"
                    step="1000"
                    value={@min_bbox_area}
                    class="range range-xs range-primary flex-1"
                    name="area"
                  />
                  <span class="text-xs font-mono w-16">{@min_bbox_area}</span>
                </div>
                <label class="label py-0">
                  <span class="label-text-alt text-base-content/40">
                    ~{round(:math.sqrt(@min_bbox_area))}x{round(:math.sqrt(@min_bbox_area))} px
                  </span>
                </label>
              </form>
              <form phx-change="set_vlm_sample_pct" class="form-control flex-1">
                <label class="label py-0"><span class="label-text text-xs">VLM sample %</span></label>
                <div class="flex items-center gap-2">
                  <input
                    type="range"
                    min="5"
                    max="100"
                    step="5"
                    value={@vlm_sample_pct}
                    class="range range-xs range-secondary flex-1"
                    name="pct"
                  />
                  <span class="text-xs font-mono w-10">{@vlm_sample_pct}%</span>
                </div>
              </form>
              <form phx-change="set_ttl_days" class="form-control">
                <label class="label py-0"><span class="label-text text-xs">TTL (days)</span></label>
                <input
                  type="number"
                  min="1"
                  max="365"
                  value={@classification_ttl_days}
                  class="input input-bordered input-sm w-20"
                  name="days"
                />
              </form>
            </div>

            <div class="flex items-center gap-4 mt-2">
              <label class="label cursor-pointer gap-2 p-0">
                <span class="label-text text-xs">Fishial</span>
                <input
                  type="checkbox"
                  class="toggle toggle-sm toggle-info"
                  checked={@fishial_enabled}
                  phx-click="toggle_fishial"
                  disabled={not @fishial_ready}
                />
              </label>
              <label class="label cursor-pointer gap-2 p-0">
                <span class="label-text text-xs">VLM</span>
                <input
                  type="checkbox"
                  class="toggle toggle-sm toggle-secondary"
                  checked={@vlm_enabled}
                  phx-click="toggle_vlm"
                />
              </label>
              <span class="text-xs text-base-content/40">
                <%= cond do %>
                  <% not @fishial_ready and @fishial_enabled -> %>
                    <span class="text-warning">Fishial model not downloaded</span>
                  <% @fishial_enabled and @vlm_enabled -> %>
                    Fishial first, VLM fallback
                  <% @fishial_enabled -> %>
                    Fishial only
                  <% @vlm_enabled -> %>
                    VLM only
                  <% true -> %>
                    Detection only (no classification)
                <% end %>
              </span>
            </div>

            <%!-- VLM Context --%>
            <div class="mt-3">
              <label class="label py-0"><span class="label-text text-xs">VLM Context</span></label>
              <div class="flex items-center gap-1 mt-1">
                <select
                  class="select select-bordered select-sm flex-1"
                  phx-change="select_context"
                  name="id"
                >
                  <option
                    :for={ctx <- @vlm_contexts}
                    value={ctx["id"]}
                    selected={ctx["id"] == @selected_context_id}
                  >
                    {ctx["name"]}
                  </option>
                </select>
                <button class="btn btn-ghost btn-xs" phx-click="edit_context" title="Edit">Edit</button>
                <button class="btn btn-ghost btn-xs" phx-click="new_context" title="New">+</button>
              </div>

              <%= if @editing_context do %>
                <div class="mt-1 space-y-1">
                  <input
                    type="text"
                    class="input input-bordered input-sm w-full"
                    placeholder="Context name"
                    value={@context_name}
                    phx-blur="set_context_name"
                    phx-keyup="set_context_name"
                    phx-value-name=""
                    name="name"
                    phx-change="set_context_name"
                  />
                  <textarea
                    class="textarea textarea-bordered textarea-sm w-full"
                    rows="3"
                    placeholder="Location and species context for VLM identification..."
                    phx-blur="edit_context_prompt"
                    name="prompt"
                    phx-change="edit_context_prompt"
                  >{@vlm_context_prompt}</textarea>
                  <div class="flex gap-1">
                    <button class="btn btn-primary btn-xs" phx-click="save_context">Save</button>
                    <button class="btn btn-ghost btn-xs" phx-click="cancel_edit_context">Cancel</button>
                    <%= if @selected_context_id do %>
                      <button
                        class="btn btn-error btn-xs btn-outline ml-auto"
                        phx-click="delete_context"
                        data-confirm="Delete this context?"
                      >Delete</button>
                    <% end %>
                  </div>
                </div>
              <% else %>
                <p class="text-xs text-base-content/50 mt-1 line-clamp-2">{@vlm_context_prompt}</p>
              <% end %>
            </div>

            <button
              class="btn btn-primary mt-2"
              phx-click="start_processing"
              disabled={@selected_file == nil}
            >
              Start Processing
            </button>
          </div>
        </div>

        <%!-- Video player --%>
        <div class="card bg-base-200">
          <div class="card-body">
            <h2 class="card-title text-lg">Preview</h2>
            <div
              id="video-preview-hook"
              phx-hook="VideoPreview"
              phx-update="ignore"
            >
              <div class="flex items-center justify-center aspect-video bg-base-300 rounded-lg">
                <p class="text-base-content/40 text-sm">Select a video to preview</p>
              </div>
            </div>
          </div>
        </div>

        <%!-- Job queue --%>
        <div class="card bg-base-200">
          <div class="card-body">
            <h2 class="card-title text-lg">Processing Queue</h2>
            <div class="overflow-y-auto max-h-96">
              <%= if Enum.empty?(@jobs) do %>
                <p class="text-base-content/50 italic">No videos processed yet.</p>
              <% else %>
                <div class="space-y-2">
                  <div :for={job <- @jobs} class="card card-compact bg-base-100">
                    <div class="card-body p-3">
                      <div class="flex items-center justify-between">
                        <span class="font-mono text-sm font-bold">{job.filename}</span>
                        <div class="flex items-center gap-2">
                          <span class={[
                            "badge badge-sm",
                            job.status == "completed" && "badge-success",
                            job.status == "processing" && "badge-info",
                            job.status == "pending" && "badge-ghost",
                            job.status == "failed" && "badge-error"
                          ]}>
                            {job.status}
                          </span>
                          <%= if job.status in ["processing", "pending"] do %>
                            <button
                              class="btn btn-ghost btn-xs text-warning"
                              phx-click="cancel_job"
                              phx-value-id={job.id}
                            >
                              Cancel
                            </button>
                          <% end %>
                          <%= if job.status == "failed" do %>
                            <button
                              class="btn btn-ghost btn-xs text-info"
                              phx-click="retry_job"
                              phx-value-id={job.id}
                            >
                              Retry
                            </button>
                          <% end %>
                          <%= if job.status in ["completed", "failed"] do %>
                            <button
                              class="btn btn-ghost btn-xs text-error"
                              phx-click="delete_job"
                              phx-value-id={job.id}
                              data-confirm="Remove this job?"
                            >
                              Delete
                            </button>
                          <% end %>
                        </div>
                      </div>
                      <%= if job.status == "processing" do %>
                        <progress
                          class="progress progress-info w-full"
                          value={job.progress_pct}
                          max="100"
                        />
                        <span class="text-xs text-base-content/50">
                          {job.status_message || "#{job.progress_pct}%"}
                        </span>
                      <% end %>
                      <%= if job.status == "completed" and job.status_message do %>
                        <span class="text-xs text-success">{job.status_message}</span>
                      <% end %>
                      <%= if job.status == "failed" and job.error_message do %>
                        <p class="text-xs text-error">{job.error_message}</p>
                      <% end %>
                      <div class="text-xs text-base-content/40 flex flex-wrap gap-x-3">
                        <span>Profile: {job.processing_profile}</span>
                        <%= if job.min_bbox_area do %>
                          <span>Min area: {job.min_bbox_area}px</span>
                        <% end %>
                        <%= if job.total_tracks do %>
                          <span>
                            VLM: {job.vlm_classified_count || 0}/{job.vlm_qualified || 0} classified
                            ({job.total_tracks} tracks)
                          </span>
                        <% end %>
                        <%= if job.fishial_enabled do %>
                          <span class="badge badge-info badge-xs">Fishial</span>
                        <% end %>
                        <%= if Map.get(job, :vlm_enabled, true) do %>
                          <span class="badge badge-secondary badge-xs">VLM</span>
                        <% end %>
                        <%= if job.location do %>
                          <span class="truncate max-w-[150px]" title={job.location}>{job.location}</span>
                        <% end %>
                      </div>
                    </div>
                  </div>
                </div>
              <% end %>
            </div>
          </div>
        </div>
      </div>
    </div>
    """
  end
end
