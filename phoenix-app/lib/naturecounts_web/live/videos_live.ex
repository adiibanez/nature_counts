defmodule NaturecountsWeb.VideosLive do
  use NaturecountsWeb, :live_view

  alias Naturecounts.Repo
  alias Naturecounts.CameraSettings
  alias Naturecounts.Clips
  alias Naturecounts.Offline.{Video, Annotation, Profiles, ProcessVideoWorker, ScanMetricsWorker, FixTimestampsWorker, ThumbnailWorker, VlmContexts}
  alias Naturecounts.Storage.{GCS, GCSBuckets}

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

    default_profile = Profiles.get("standard")

    saved_ui = CameraSettings.get("videos_ui")

    {:ok,
     assign(socket,
       page_title: "Video Processing",
       current_dir: @videos_root,
       breadcrumbs: [],
       entries: :loading,
       processed_files: %{},
       jobs: jobs,
       selected_file: nil,
       preview_url: nil,
       annotations: [],
       all_annotations: [],
       annotation_thumbs: %{},
       annotation_search: "",
       annotation_suggestions: [],
       editing_annotation: nil,
       pending_seek: nil,
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
       scan_last_reload: 0,
       scan_force: false,
       sort_by: "name",
       sort_dir: "asc",
       metric_filters: %{},
       active_tab: "files",
       metrics_view: "heatmap",
       scatter_x: "brightness",
       scatter_y: "det",
       scatter_color: "motion",
       temporal_y: "det",
       metrics_limit: 50,
       source: "local",
       gcs_buckets: GCSBuckets.list_safe(),
       selected_bucket: nil,
       gcs_prefix: "",
       adding_bucket: false,
       editing_bucket: nil,
       new_bucket_name: "",
       new_bucket_id: "",
       new_bucket_prefix: "",
       new_bucket_creds: "",
       bucket_test_result: nil,
       preview_floating: saved_ui["preview_floating"] || false,
       show_thumbs: saved_ui["show_thumbs"] || false,
       projects: Clips.list_projects(),
       active_project: load_active_project(saved_ui["active_project_id"]),
       project_segments_by_file: %{}
     )
     |> reload_project_segments()
     |> then(fn s -> if saved_ui["preview_floating"], do: push_event(s, "set_preview_floating", %{floating: true}), else: s end)
     |> recompute_metrics()}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    tab = params["tab"] || "files"
    sort_by = params["sort"] || "name"
    sort_dir = params["dir"] || "asc"
    source = params["source"] || "local"
    view = params["view"] || "heatmap"
    path = params["path"] || ""

    # Resolve directory
    {dir, gcs_prefix} =
      case source do
        "gcs" -> {socket.assigns.current_dir, if(path != "", do: path, else: socket.assigns.gcs_prefix)}
        _ -> {if(path != "", do: safe_resolve(path), else: @videos_root), socket.assigns.gcs_prefix}
      end

    # Check if directory changed
    dir_changed = case source do
      "gcs" -> gcs_prefix != socket.assigns.gcs_prefix or source != socket.assigns.source
      _ -> dir != socket.assigns.current_dir or source != socket.assigns.source
    end

    # Check if sort changed
    sort_changed = sort_by != socket.assigns.sort_by or sort_dir != socket.assigns.sort_dir

    socket = assign(socket,
      active_tab: tab,
      sort_by: sort_by,
      sort_dir: sort_dir,
      source: source,
      metrics_view: view
    )

    # Load annotations tab data if needed
    socket = if tab == "annotations" and socket.assigns.all_annotations == [] do
      anns = load_all_annotations()
      assign(socket, all_annotations: anns, annotation_thumbs: load_annotation_thumbs(anns, dir), annotation_search: "", annotation_suggestions: [])
    else
      socket
    end

    # Load directory if changed or first load
    socket =
      cond do
        dir_changed ->
          case source do
            "gcs" ->
              send(self(), {:load_gcs, socket.assigns.selected_bucket, gcs_prefix})
              assign(socket, gcs_prefix: gcs_prefix, entries: :loading, selected_file: nil, preview_url: nil, selected_files: MapSet.new())

            _ ->
              send(self(), {:load_dir, dir})
              assign(socket,
                current_dir: dir,
                breadcrumbs: build_breadcrumbs(dir),
                entries: :loading,
                selected_file: nil,
                preview_url: nil,
                selected_files: MapSet.new()
              )
          end
          |> recompute_metrics()

        socket.assigns.entries == :loading ->
          send(self(), {:load_dir, dir})
          assign(socket, current_dir: dir, breadcrumbs: build_breadcrumbs(dir))

        sort_changed ->
          entries = sort_entries(socket.assigns.entries, sort_by, sort_dir)
          assign(socket, entries: entries) |> recompute_metrics()

        true ->
          socket
      end

    # Restore selected file from URL
    file_param = params["file"]
    socket =
      if file_param && file_param != "" && Path.basename(socket.assigns.selected_file || "") != file_param do
        file_path = resolve_video_path(file_param, socket.assigns.current_dir)
        relative = Path.relative_to(file_path, @videos_root)
        preview_url = "/serve/videos/#{relative}"

        socket
        |> assign(selected_file: file_path, preview_url: preview_url, annotations: list_annotations(file_path))
        |> push_event("preview", %{url: preview_url, filename: file_param})
      else
        socket
      end

    # Handle pending seek from seek_annotation
    socket =
      case Map.get(socket.assigns, :pending_seek) do
        nil -> socket
        seconds ->
          socket
          |> assign(pending_seek: nil)
          |> push_event("seek", %{seconds: seconds})
      end

    {:noreply, socket}
  end

  @impl true
  def handle_info({:load_dir, dir}, socket) do
    processed_files = load_processed_files()

    entries =
      case socket.assigns.source do
        "gcs" -> list_dir_gcs(socket.assigns.selected_bucket, socket.assigns.gcs_prefix, processed_files)
        _ -> list_dir(dir, processed_files)
      end
      |> sort_entries(socket.assigns.sort_by, socket.assigns.sort_dir)

    {:noreply, assign(socket, entries: entries, processed_files: processed_files) |> recompute_metrics()}
  end

  def handle_info({:load_gcs, bucket_id, prefix}, socket) do
    processed_files = load_processed_files()

    entries =
      list_dir_gcs(bucket_id, prefix, processed_files)
      |> sort_entries(socket.assigns.sort_by, socket.assigns.sort_dir)

    {:noreply, assign(socket, entries: entries, processed_files: processed_files) |> recompute_metrics()}
  end

  def handle_info({:scan_progress, _directory, progress}, socket) do
    {:noreply, assign(socket, scanning: true, scan_progress: progress)}
  end

  def handle_info({:scan_batch_complete, _directory, _batch_id, _result}, socket) do
    # Throttle entry reloads to at most every 5 seconds
    now = System.monotonic_time(:second)

    if now - socket.assigns.scan_last_reload >= 5 do
      Naturecounts.Cache.invalidate_group(:file_browser)
      processed_files = load_processed_files()
      entries =
        list_dir(socket.assigns.current_dir, processed_files)
        |> sort_entries(socket.assigns.sort_by, socket.assigns.sort_dir)

      {:noreply,
       socket
       |> assign(entries: entries, processed_files: processed_files, scan_last_reload: now)
       |> recompute_metrics()}
    else
      {:noreply, socket}
    end
  end

  def handle_info({:scan_complete, _directory}, socket) do
    Naturecounts.Cache.invalidate_group(:file_browser)
    processed_files = load_processed_files()
    entries =
      list_dir(socket.assigns.current_dir, processed_files)
      |> sort_entries(socket.assigns.sort_by, socket.assigns.sort_dir)

    {:noreply,
     socket
     |> assign(scanning: false, scan_progress: nil, entries: entries, processed_files: processed_files)
     |> recompute_metrics()
     |> put_flash(:info, "Metrics scan complete")}
  end

  @impl true
  def handle_info(:refresh, socket) do
    schedule_refresh()
    was_scanning = socket.assigns.scanning
    scanning = scan_running?()

    cond do
      # Scan just finished — final reload
      was_scanning and not scanning ->
        Naturecounts.Cache.invalidate_group(:file_browser)
        processed_files = load_processed_files()
        entries =
          list_dir(socket.assigns.current_dir, processed_files)
          |> sort_entries(socket.assigns.sort_by, socket.assigns.sort_dir)

        {:noreply,
         socket
         |> assign(jobs: list_jobs(), scanning: false, entries: entries, processed_files: processed_files, scan_progress: nil)
         |> recompute_metrics()}

      # Scan running — poll Oban job counts for progress
      scanning ->
        progress = poll_scan_progress()
        {:noreply, assign(socket, jobs: list_jobs(), scanning: true, scan_progress: progress)}

      # Idle — only refresh jobs if there are active ones visible
      true ->
        jobs = list_jobs()
        has_active = Enum.any?(jobs, &(&1.status in ["processing", "pending"]))

        if has_active do
          {:noreply, assign(socket, jobs: jobs, scanning: false)}
        else
          {:noreply, socket}
        end
    end
  end

  # --- Navigation events ---

  @impl true
  def handle_event("navigate_dir", %{"path" => path}, socket) do
    url_path = case socket.assigns.source do
      "gcs" -> path
      _ -> Path.relative_to(safe_resolve(path), @videos_root)
    end

    {:noreply,
     socket
     |> push_event("preview", %{url: nil, filename: nil})
     |> push_patch(to: videos_url(socket, %{path: url_path}))}
  end

  def handle_event("switch_source", %{"source" => "gcs"}, socket) do
    buckets = GCSBuckets.list_safe()
    first = List.first(buckets)

    if first do
      send(self(), {:load_gcs, first["id"], first["prefix"] || ""})

      {:noreply,
       assign(socket,
         source: "gcs",
         selected_bucket: first["id"],
         gcs_prefix: first["prefix"] || "",
         entries: :loading,
         selected_file: nil,
         preview_url: nil,
         selected_files: MapSet.new(),
         gcs_buckets: buckets
       )
       |> recompute_metrics()}
    else
      {:noreply, assign(socket, source: "gcs", adding_bucket: true, gcs_buckets: buckets)}
    end
  end

  def handle_event("switch_source", %{"source" => "local"}, socket) do
    send(self(), {:load_dir, @videos_root})

    {:noreply,
     assign(socket,
       source: "local",
       current_dir: @videos_root,
       breadcrumbs: [],
       entries: :loading,
       selected_file: nil,
       preview_url: nil,
       selected_files: MapSet.new()
     )
     |> recompute_metrics()}
  end

  def handle_event("select_bucket", %{"id" => id}, socket) do
    case GCSBuckets.get(id) do
      nil ->
        {:noreply, socket}

      bucket ->
        prefix = bucket["prefix"] || ""
        send(self(), {:load_gcs, id, prefix})

        {:noreply,
         assign(socket,
           selected_bucket: id,
           gcs_prefix: prefix,
           entries: :loading,
           selected_file: nil,
           preview_url: nil,
           selected_files: MapSet.new()
         )
         |> recompute_metrics()}
    end
  end

  def handle_event("toggle_add_bucket", _params, socket) do
    {:noreply,
     assign(socket,
       adding_bucket: !socket.assigns.adding_bucket,
       editing_bucket: nil,
       new_bucket_name: "",
       new_bucket_id: "",
       new_bucket_prefix: "",
       new_bucket_creds: "",
       bucket_test_result: nil
     )}
  end

  def handle_event("edit_bucket", %{"id" => id}, socket) do
    case GCSBuckets.get_safe(id) do
      nil ->
        {:noreply, socket}

      b ->
        {:noreply,
         assign(socket,
           adding_bucket: true,
           editing_bucket: id,
           new_bucket_name: b["name"],
           new_bucket_id: b["bucket"],
           new_bucket_prefix: b["prefix"] || "",
           new_bucket_creds: "",
           bucket_test_result: nil
         )}
    end
  end


  def handle_event("save_bucket", %{"action" => "test"} = params, socket) do
    bucket = params["bucket"] || ""
    creds_json = params["credentials"] || ""

    cond do
      bucket == "" ->
        {:noreply, assign(socket, bucket_test_result: {:error, "Bucket ID is required"})}

      creds_json == "" and socket.assigns.editing_bucket != nil ->
        bucket_config = GCSBuckets.get(socket.assigns.editing_bucket)

        if bucket_config do
          test_config = Map.put(bucket_config, "bucket", bucket)
          result = GCS.test_connection(test_config)
          {:noreply, assign(socket, bucket_test_result: result)}
        else
          {:noreply, assign(socket, bucket_test_result: {:error, "No existing credentials"})}
        end

      creds_json == "" ->
        {:noreply, assign(socket, bucket_test_result: {:error, "Paste service account JSON first"})}

      true ->
        case Jason.decode(creds_json) do
          {:ok, creds} ->
            test_config = %{"bucket" => bucket, "credentials" => creds}
            result = GCS.test_connection(test_config)
            {:noreply, assign(socket, bucket_test_result: result)}

          {:error, _} ->
            {:noreply, assign(socket, bucket_test_result: {:error, "Invalid JSON"})}
        end
    end
  end

  def handle_event("save_bucket", params, socket) do
    name = params["name"] || ""
    bucket = params["bucket"] || ""
    prefix = params["prefix"] || ""
    creds_json = params["credentials"] || ""

    if name != "" and bucket != "" do
      case socket.assigns.editing_bucket do
        nil ->
          if creds_json == "" do
            {:noreply, put_flash(socket, :error, "Service account JSON is required")}
          else
            GCSBuckets.add(name, bucket, prefix, creds_json)
            buckets = GCSBuckets.list_safe()
            added = List.last(buckets)

            send(self(), {:load_gcs, added["id"], added["prefix"] || ""})

            {:noreply,
             assign(socket,
               gcs_buckets: buckets,
               selected_bucket: added["id"],
               gcs_prefix: added["prefix"] || "",
               adding_bucket: false,
               entries: :loading,
               new_bucket_name: "",
               new_bucket_id: "",
               new_bucket_prefix: "",
               new_bucket_creds: "",
               bucket_test_result: nil
             )
             |> recompute_metrics()}
          end

        id ->
          GCSBuckets.update(id, %{
            "name" => name,
            "bucket" => bucket,
            "prefix" => prefix,
            "credentials_json" => creds_json
          })

          buckets = GCSBuckets.list_safe()

          {:noreply,
           assign(socket,
             gcs_buckets: buckets,
             editing_bucket: nil,
             adding_bucket: false,
             new_bucket_name: "",
             new_bucket_id: "",
             new_bucket_prefix: "",
             new_bucket_creds: "",
             bucket_test_result: nil
           )}
      end
    else
      {:noreply, put_flash(socket, :error, "Name and bucket ID are required")}
    end
  end

  def handle_event("delete_bucket", %{"id" => id}, socket) do
    GCSBuckets.delete(id)
    buckets = GCSBuckets.list_safe()
    first = List.first(buckets)

    socket = assign(socket, gcs_buckets: buckets)

    if first do
      send(self(), {:load_gcs, first["id"], first["prefix"] || ""})
      {:noreply, assign(socket, selected_bucket: first["id"], gcs_prefix: first["prefix"] || "", entries: :loading) |> recompute_metrics()}
    else
      {:noreply, assign(socket, selected_bucket: nil, entries: [], source: "gcs") |> recompute_metrics()}
    end
  end

  def handle_event("select_file", %{"file" => file}, socket) do
    case socket.assigns.source do
      "gcs" ->
        bucket_config = GCSBuckets.get(socket.assigns.selected_bucket)

        if bucket_config do
          case GCS.signed_url(bucket_config, file) do
            {:ok, url} ->
              {:noreply,
               socket
               |> assign(selected_file: file, preview_url: url, annotations: list_annotations(file))
               |> push_event("preview", %{url: url, filename: Path.basename(file)})}

            {:error, reason} ->
              {:noreply, put_flash(socket, :error, "GCS signed URL error: #{reason}")}
          end
        else
          {:noreply, put_flash(socket, :error, "No bucket selected")}
        end

      _ ->
        {:noreply, push_patch(socket, to: videos_url(socket, %{file: file}))}
    end
  end

  def handle_event("toggle_select", %{"file" => file}, socket) do
    selected = socket.assigns.selected_files

    # Check if this is a directory entry
    entry = Enum.find(visible_entries(socket.assigns), &(&1.path == file))

    selected =
      case entry do
        %{type: :dir, path: dir_path} ->
          # Collect all video files recursively under this directory
          dir_files = collect_video_files_recursive(dir_path)
          all_selected? = Enum.all?(dir_files, &MapSet.member?(selected, &1))

          if all_selected? do
            Enum.reduce(dir_files, selected, &MapSet.delete(&2, &1))
          else
            Enum.reduce(dir_files, selected, &MapSet.put(&2, &1))
          end

        _ ->
          if MapSet.member?(selected, file),
            do: MapSet.delete(selected, file),
            else: MapSet.put(selected, file)
      end

    {:noreply, assign(socket, selected_files: selected)}
  end

  def handle_event("select_all", _params, socket) do
    all_files =
      (socket.assigns.visible || [])
      |> Enum.filter(&(&1.type == :file))
      |> Enum.map(& &1.path)
      |> MapSet.new()

    {:noreply, assign(socket, selected_files: all_files)}
  end

  def handle_event("select_none", _params, socket) do
    {:noreply, assign(socket, selected_files: MapSet.new())}
  end

  def handle_event("delete_selected", _params, socket) do
    selected = socket.assigns.selected_files
    count = MapSet.size(selected)

    Enum.each(selected, fn path ->
      safe = safe_resolve(path)
      if File.regular?(safe), do: File.rm(safe)
      delete_video_by_path(safe)
    end)

    Naturecounts.Cache.invalidate_all()

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
       preview_url: preview_url,
       jobs: list_jobs()
     )
     |> recompute_metrics()
     |> put_flash(:info, "Deleted #{count} file(s) and associated data")}
  end

  def handle_event("clear_selection", _params, socket) do
    {:noreply, assign(socket, selected_files: MapSet.new())}
  end

  def handle_event("select_black_videos", _params, %{assigns: %{entries: :loading}} = socket) do
    {:noreply, socket}
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
    end

    delete_video_by_path(safe)
    Naturecounts.Cache.invalidate_all()

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
       preview_url: preview_url,
       jobs: list_jobs()
     )
     |> recompute_metrics()
     |> put_flash(:info, "Deleted #{Path.basename(file)}")}
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
    new_dir =
      if socket.assigns.sort_by == col do
        if socket.assigns.sort_dir == "desc", do: "asc", else: "desc"
      else
        "desc"
      end

    {:noreply, push_patch(socket, to: videos_url(socket, %{sort: col, dir: new_dir}))}
  end

  def handle_event("scan_metrics", _params, socket) do
    %{
      "mode" => "dispatch",
      "directory" => socket.assigns.current_dir,
      "force" => socket.assigns.scan_force,
      "sample_frames" => 60
    }
    |> ScanMetricsWorker.new(priority: 1)
    |> Oban.insert!()

    {:noreply, assign(socket, scanning: true)}
  end

  def handle_event("fix_timestamps", _params, socket) do
    %{"mode" => "dispatch", "directory" => socket.assigns.current_dir}
    |> FixTimestampsWorker.new(priority: 1)
    |> Oban.insert!()

    {:noreply,
     socket
     |> assign(scanning: true)
     |> put_flash(:info, "Fixing timestamps for videos in #{Path.basename(socket.assigns.current_dir)}...")}
  end

  def handle_event("generate_thumbnails", _params, socket) do
    %{
      "mode" => "dispatch",
      "directory" => socket.assigns.current_dir,
      "count" => 8,
      "force" => socket.assigns.scan_force
    }
    |> ThumbnailWorker.new(priority: 1)
    |> Oban.insert!()

    {:noreply,
     socket
     |> assign(scanning: true)
     |> put_flash(:info, "Generating thumbnails for videos in #{Path.basename(socket.assigns.current_dir)}...")}
  end

  def handle_event("toggle_scan_force", _params, socket) do
    {:noreply, assign(socket, scan_force: !socket.assigns.scan_force)}
  end

  def handle_event("toggle_thumbs", _params, socket) do
    val = !socket.assigns.show_thumbs
    CameraSettings.put("videos_ui", %{"show_thumbs" => val})
    {:noreply, assign(socket, show_thumbs: val)}
  end

  def handle_event("cancel_scan", _params, socket) do
    import Ecto.Query

    # Signal cancellation via file
    File.write!(Path.join(System.tmp_dir!(), "scan_cancel"), "")

    # Cancel Oban jobs
    Oban.Job
    |> where([j], j.worker in [
      "Naturecounts.Offline.ScanMetricsWorker",
      "Naturecounts.Offline.FixTimestampsWorker"
    ])
    |> where([j], j.state in ["available", "executing", "scheduled"])
    |> Repo.all()
    |> Enum.each(&Oban.cancel_job(&1.id))

    # Reload entries to show whatever was scanned so far
    Naturecounts.Cache.invalidate_group(:file_browser)
    processed_files = load_processed_files()
    entries =
      list_dir(socket.assigns.current_dir, processed_files)
      |> sort_entries(socket.assigns.sort_by, socket.assigns.sort_dir)

    {:noreply,
     socket
     |> assign(scanning: false, scan_progress: nil, entries: entries, processed_files: processed_files)
     |> recompute_metrics()
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

  def handle_event("toggle_preview_floating", _params, socket) do
    floating = !socket.assigns.preview_floating
    CameraSettings.put("videos_ui", %{"preview_floating" => floating})

    {:noreply,
     socket
     |> assign(preview_floating: floating)
     |> push_event("set_preview_floating", %{floating: floating})}
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
    selected = socket.assigns.selected_files
    single_file = socket.assigns.selected_file
    profile = socket.assigns.selected_profile

    # Determine the list of files to process: selected files take priority, fallback to single file
    files_to_process =
      if MapSet.size(selected) > 0 do
        MapSet.to_list(selected)
      else
        if single_file, do: [single_file], else: []
      end

    if files_to_process == [] do
      {:noreply, put_flash(socket, :error, "No file selected")}
    else
      gcs_attrs =
        case socket.assigns.source do
          "gcs" ->
            %{storage_backend: "gcs", gcs_bucket: socket.assigns.selected_bucket}

          _ ->
            %{storage_backend: "local"}
        end

      Enum.each(files_to_process, fn file ->
        video =
          %Video{}
          |> Video.changeset(
            Map.merge(gcs_attrs, %{
              filename: Path.basename(file),
              path: file,
              processing_profile: profile,
              min_bbox_area: socket.assigns.min_bbox_area,
              vlm_sample_pct: socket.assigns.vlm_sample_pct,
              fishial_enabled: socket.assigns.fishial_enabled,
              vlm_enabled: socket.assigns.vlm_enabled,
              location: socket.assigns.vlm_context_prompt
            })
          )
          |> Repo.insert!()

        %{video_id: video.id}
        |> ProcessVideoWorker.new()
        |> Oban.insert!()
      end)

      count = length(files_to_process)

      {:noreply,
       socket
       |> assign(selected_file: nil, preview_url: nil, selected_files: MapSet.new(), jobs: list_jobs())
       |> put_flash(:info, "Processing started for #{count} file(s)")}
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

    # Optionally delete the file from disk too
    if video.path && File.exists?(video.path), do: File.rm(video.path)

    Repo.delete!(video)
    Naturecounts.Cache.invalidate_all()

    processed_files = load_processed_files()
    entries =
      list_dir(socket.assigns.current_dir, processed_files)
      |> sort_entries(socket.assigns.sort_by, socket.assigns.sort_dir)

    {:noreply, assign(socket, jobs: list_jobs(), entries: entries, processed_files: processed_files) |> recompute_metrics()}
  end

  def handle_event("clean_orphans", _params, socket) do
    orphans =
      Video
      |> Repo.all()
      |> Enum.filter(fn v -> not File.exists?(v.path) end)

    Enum.each(orphans, &Repo.delete/1)
    Naturecounts.Cache.invalidate_all()

    processed_files = load_processed_files()
    entries =
      list_dir(socket.assigns.current_dir, processed_files)
      |> sort_entries(socket.assigns.sort_by, socket.assigns.sort_dir)

    {:noreply,
     socket
     |> assign(jobs: list_jobs(), entries: entries, processed_files: processed_files)
     |> recompute_metrics()
     |> put_flash(:info, "Removed #{length(orphans)} orphaned record(s)")}
  end

  def handle_event("switch_tab", %{"tab" => tab}, socket) do
    {:noreply, push_patch(socket, to: videos_url(socket, %{tab: tab}))}
  end

  def handle_event("add_annotation", %{"annotation" => params}, socket) do
    file = socket.assigns.selected_file

    if file do
      ts = parse_timestamp(params["timestamp"] || "0:00")
      end_ts = if (params["end_timestamp"] || "") != "", do: parse_timestamp(params["end_timestamp"]), else: nil

      %Annotation{}
      |> Annotation.changeset(%{filename: Path.basename(file), timestamp_seconds: ts, end_seconds: end_ts, text: params["text"]})
      |> Repo.insert!()

      invalidate_annotations_cache()
      socket = assign(socket, annotations: list_annotations(file)) |> recompute_metrics()
      {:noreply, socket}
    else
      {:noreply, socket}
    end
  end

  def handle_event("delete_annotation", %{"id" => id}, socket) do
    Annotation |> Repo.get!(id) |> Repo.delete!()

    invalidate_annotations_cache()
    socket = assign(socket, annotations: list_annotations(socket.assigns.selected_file)) |> recompute_metrics()
    socket = if socket.assigns.active_tab == "annotations" do
      anns = load_all_annotations(socket.assigns.annotation_search)
      assign(socket, all_annotations: anns, annotation_thumbs: load_annotation_thumbs(anns, socket.assigns.current_dir))
    else
      socket
    end
    {:noreply, socket}
  end

  def handle_event("edit_annotation", %{"id" => id}, socket) do
    {:noreply, assign(socket, editing_annotation: String.to_integer(id))}
  end

  def handle_event("cancel_edit_annotation", _params, socket) do
    {:noreply, assign(socket, editing_annotation: nil)}
  end

  def handle_event("set_active_project", %{"id" => id}, socket) do
    project_id =
      case id do
        "" -> nil
        id -> String.to_integer(id)
      end

    CameraSettings.put("videos_ui", %{"active_project_id" => project_id})

    {:noreply,
     socket
     |> assign(active_project: load_active_project(project_id))
     |> reload_project_segments()}
  end

  def handle_event("create_project_inline", %{"name" => name}, socket) do
    name = String.trim(name)

    if name == "" do
      {:noreply, socket}
    else
      case Clips.create_project(%{"name" => name}) do
        {:ok, project} ->
          CameraSettings.put("videos_ui", %{"active_project_id" => project.id})

          {:noreply,
           socket
           |> assign(projects: Clips.list_projects(), active_project: load_active_project(project.id))
           |> reload_project_segments()
           |> put_flash(:info, "Project '#{project.name}' created and activated")}

        {:error, _} ->
          {:noreply, put_flash(socket, :error, "could not create project")}
      end
    end
  end

  def handle_event("add_annotation_to_project", %{"id" => ann_id}, socket) do
    case socket.assigns.active_project do
      nil ->
        {:noreply, put_flash(socket, :error, "Select an active project first")}

      project ->
        ann = Repo.get!(Annotation, String.to_integer(ann_id))
        file_path = resolve_annotation_file_path(ann.filename, socket.assigns.current_dir)

        end_s = ann.end_seconds || ann.timestamp_seconds + 5.0

        attrs = %{
          "file_path" => file_path,
          "start_seconds" => ann.timestamp_seconds,
          "end_seconds" => end_s,
          "label" => ann.text,
          "source_annotation_id" => ann.id
        }

        case Clips.add_segment(project, attrs) do
          {:ok, _seg} ->
            {:noreply,
             socket
             |> reload_project_segments()
             |> put_flash(:info, "Added segment to '#{project.name}'")}

          {:error, _cs} ->
            {:noreply, put_flash(socket, :error, "could not add segment")}
        end
    end
  end

  def handle_event("add_segment_from_drag", %{"file" => file, "start" => start_s, "end" => end_s}, socket) do
    case socket.assigns.active_project do
      nil ->
        {:noreply, put_flash(socket, :error, "Select an active project first")}

      project ->
        attrs = %{
          "file_path" => file,
          "start_seconds" => to_float(start_s),
          "end_seconds" => to_float(end_s)
        }

        case Clips.add_segment(project, attrs) do
          {:ok, _} ->
            {:noreply,
             socket
             |> reload_project_segments()
             |> put_flash(:info, "Segment added")}

          {:error, _} ->
            {:noreply, put_flash(socket, :error, "could not add segment")}
        end
    end
  end

  def handle_event("save_annotation", %{"id" => id, "annotation" => params}, socket) do
    ann = Repo.get!(Annotation, id)
    ts = parse_timestamp(params["timestamp"] || "0:00")
    end_ts = if (params["end_timestamp"] || "") != "", do: parse_timestamp(params["end_timestamp"]), else: nil

    ann
    |> Annotation.changeset(%{timestamp_seconds: ts, end_seconds: end_ts, text: params["text"]})
    |> Repo.update!()

    invalidate_annotations_cache()
    socket = assign(socket, editing_annotation: nil, annotations: list_annotations(socket.assigns.selected_file)) |> recompute_metrics()
    socket = if socket.assigns.active_tab == "annotations" do
      anns = load_all_annotations(socket.assigns.annotation_search)
      assign(socket, all_annotations: anns, annotation_thumbs: load_annotation_thumbs(anns, socket.assigns.current_dir))
    else
      socket
    end
    {:noreply, socket}
  end

  def handle_event("seek_annotation", params, socket) do
    seconds = params["seconds"]
    filename = params["filename"]

    if filename && Path.basename(socket.assigns.selected_file || "") != filename do
      path = resolve_video_path(filename, socket.assigns.current_dir)
      # Store pending seek, select file via URL
      {:noreply,
       socket
       |> assign(pending_seek: seconds)
       |> push_patch(to: videos_url(socket, %{file: path}))}
    else
      {:noreply, push_event(socket, "seek", %{seconds: seconds})}
    end
  end

  def handle_event("search_annotations", %{"query" => query}, socket) do
    anns = load_all_annotations(query)
    {:noreply, assign(socket,
      annotation_search: query,
      all_annotations: anns,
      annotation_thumbs: load_annotation_thumbs(anns, socket.assigns.current_dir),
      annotation_suggestions: if(query != "", do: annotation_suggestions(query), else: [])
    )}
  end

  def handle_event("select_annotation_file", %{"filename" => filename}, socket) do
    path = resolve_video_path(filename, socket.assigns.current_dir)
    {:noreply, push_patch(socket, to: videos_url(socket, %{file: path}))}
  end

  def handle_event("pick_annotation_suggestion", %{"value" => value}, socket) do
    anns = load_all_annotations(value)
    {:noreply, assign(socket,
      annotation_search: value,
      all_annotations: anns,
      annotation_thumbs: load_annotation_thumbs(anns, socket.assigns.current_dir),
      annotation_suggestions: []
    )}
  end

  def handle_event("set_metrics_view", %{"view" => view}, socket) do
    {:noreply, push_patch(assign(socket, metrics_limit: 50), to: videos_url(socket, %{view: view}))}
  end

  def handle_event("set_scatter_axis", %{"axis" => axis, "value" => value}, socket) do
    case axis do
      "x" -> {:noreply, assign(socket, scatter_x: value)}
      "y" -> {:noreply, assign(socket, scatter_y: value)}
      "color" -> {:noreply, assign(socket, scatter_color: value)}
      _ -> {:noreply, socket}
    end
  end

  def handle_event("set_temporal_y", %{"value" => value}, socket) do
    {:noreply, assign(socket, temporal_y: value)}
  end

  def handle_event("seek_sample", %{"file" => file, "time" => time_str}, socket) do
    time =
      case Float.parse(time_str) do
        {f, _} -> f
        :error -> 0.0
      end

    url =
      case socket.assigns.source do
        "gcs" ->
          bucket_config = GCSBuckets.get(socket.assigns.selected_bucket)
          case GCS.signed_url(bucket_config, file) do
            {:ok, signed} -> signed
            _ -> nil
          end

        _ ->
          "/serve/videos/#{Path.relative_to(file, @videos_root)}"
      end

    if url do
      {:noreply,
       socket
       |> assign(selected_file: file, preview_url: url)
       |> push_event("preview", %{url: url, filename: Path.basename(file)})
       |> push_event("seek", %{time: time})}
    else
      {:noreply, socket}
    end
  end

  def handle_event("load_more_metrics", _params, socket) do
    {:noreply, assign(socket, metrics_limit: socket.assigns.metrics_limit + 50) |> recompute_metrics()}
  end

  def handle_event("load_all_metrics", _params, socket) do
    {:noreply, assign(socket, metrics_limit: 999_999) |> recompute_metrics()}
  end

  def handle_event("set_metric_filter", %{"field" => field, "min" => min_str, "max" => max_str}, socket) do
    filters = socket.assigns.metric_filters
    ranges = socket.assigns.ranges

    min_val = parse_number(min_str)
    max_val = parse_number(max_str)

    # If both sliders are at the data bounds, clear the filter
    range = ranges[field]

    filters =
      cond do
        min_val == nil and max_val == nil ->
          Map.delete(filters, field)

        range != nil and min_val != nil and max_val != nil and
          min_val <= range.min and max_val >= range.max ->
          Map.delete(filters, field)

        true ->
          Map.put(filters, field, {min_val, max_val})
      end

    {:noreply, assign(socket, metric_filters: filters, metrics_limit: 50) |> recompute_metrics()}
  end

  def handle_event("quick_filter", %{"preset" => preset}, socket) do
    filters =
      case preset do
        "clear" -> %{}
        "has_detections" -> %{"avg_detections_per_frame" => {0.1, nil}}
        "no_detections" -> %{"avg_detections_per_frame" => {nil, 0.0}}
        "dark" -> %{"avg_brightness" => {nil, 15.0}}
        "short" -> %{"duration_s" => {nil, 30.0}}
        "high_motion" -> %{"motion_score" => {5.0, nil}}
        "large_bbox" -> %{"bbox_mean" => {20000, nil}}
        _ -> socket.assigns.metric_filters
      end

    socket = assign(socket, metric_filters: filters, metrics_limit: 50) |> recompute_metrics()
    socket = if filters == %{}, do: push_event(socket, "reset_filters", %{}), else: socket
    {:noreply, socket}
  end

  defp parse_number(""), do: nil
  defp parse_number(str) do
    case Float.parse(str) do
      {val, _} -> val
      :error -> nil
    end
  end

  # --- Helpers ---

  defp delete_video_by_path(path) do
    Video
    |> where([v], v.path == ^path)
    |> Repo.all()
    |> Enum.each(&Repo.delete/1)
  end

  defp safe_resolve(path) do
    # If already absolute and under videos_root, use directly
    # Otherwise treat as relative to videos_root
    expanded =
      if String.starts_with?(path, @videos_root) do
        Path.expand(path)
      else
        Path.expand(path, @videos_root)
      end

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

  defp poll_scan_progress do
    import Ecto.Query

    workers = [
      "Naturecounts.Offline.ScanMetricsWorker",
      "Naturecounts.Offline.FixTimestampsWorker",
      "Naturecounts.Offline.ThumbnailWorker"
    ]

    try do
      # Only count active + recently finished jobs (last 2 hours)
      cutoff = DateTime.add(DateTime.utc_now(), -2, :hour)

      counts =
        Oban.Job
        |> where([j], j.worker in ^workers)
        |> where([j], j.state in ["available", "executing", "completed", "discarded", "retryable"])
        |> where([j], j.inserted_at >= ^cutoff)
        |> group_by([j], j.state)
        |> select([j], {j.state, count(j.id)})
        |> Repo.all()
        |> Map.new()

      executing = Map.get(counts, "executing", 0)
      available = Map.get(counts, "available", 0)
      completed = Map.get(counts, "completed", 0)
      failed = Map.get(counts, "discarded", 0) + Map.get(counts, "retryable", 0)

      total = executing + available + completed + failed

      if total > 0 do
        %{
          "done" => completed,
          "total" => total,
          "executing" => executing,
          "pending" => available,
          "failed" => failed
        }
      else
        nil
      end
    rescue
      _ -> nil
    end
  end

  defp scan_running? do
    import Ecto.Query

    Naturecounts.Cache.get_or_compute(:scan_running, fn ->
      try do
        Oban.Job
        |> where([j], j.worker in [
          "Naturecounts.Offline.ScanMetricsWorker",
          "Naturecounts.Offline.FixTimestampsWorker",
          "Naturecounts.Offline.ThumbnailWorker"
        ])
        |> where([j], j.state in ["available", "executing", "scheduled"])
        |> Repo.exists?()
      rescue
        _ -> false
      end
    end, ttl: 2_000, group: :videos)
  end


  defp load_metrics_index(dir) do
    Naturecounts.Cache.get_or_compute({:metrics_index, dir}, fn ->
      Naturecounts.Offline.MetricsStore.read_dir(dir)
    end, ttl: 30_000, group: :file_browser)
  end

  defp load_processed_files do
    Naturecounts.Cache.get_or_compute(:processed_files, fn ->
      Video
      |> where([v], v.status in ["completed", "processing", "pending"])
      |> select([v], {v.path, %{status: v.status, profile: v.processing_profile}})
      |> Repo.all()
      |> Map.new()
    end, ttl: 10_000, group: :videos)
  end

  defp list_dir(dir, processed_files) do
    base =
      Naturecounts.Cache.get_or_compute({:file_browser, dir}, fn ->
        list_dir_from_fs(dir)
      end, ttl: 30_000, group: :file_browser)

    Enum.map(base, fn
      %{type: :file, path: path} = entry ->
        %{entry | processed: Map.get(processed_files, path)}

      dir_entry ->
        dir_entry
    end)
  end

  defp list_dir_from_fs(dir) do
    metrics = load_metrics_index(dir)

    # Pre-load thumb listings in one File.ls call on the .thumbs dir
    thumbs_dir = Path.join(dir, ".thumbs")
    thumb_index = case File.ls(thumbs_dir) do
      {:ok, video_names} ->
        Map.new(video_names, fn vname ->
          vdir = Path.join(thumbs_dir, vname)
          jpgs = case File.ls(vdir) do
            {:ok, fs} -> fs |> Enum.filter(&String.ends_with?(&1, ".jpg")) |> Enum.sort() |> Enum.map(&Path.join(vdir, &1))
            _ -> []
          end
          {vname, jpgs}
        end)
      _ -> %{}
    end

    case File.ls(dir) do
      {:ok, names} ->
        names
        |> Enum.filter(&is_binary/1)
        |> Enum.filter(&String.valid?/1)
        |> Enum.sort()
        |> Enum.reduce({[], []}, fn name, {dirs, files} ->
          path = Path.join(dir, name)

          cond do
            not String.starts_with?(name, ".") and File.dir?(path) ->
              {dirs ++ [%{type: :dir, name: name, path: path}], files}

            video_file?(name) ->
              size_mb = case File.stat(path) do
                {:ok, stat} -> Float.round(stat.size / 1_048_576, 1)
                _ -> 0.0
              end
              m = Map.get(metrics, name)
              thumbs = Map.get(thumb_index, name, [])

              {dirs,
               files ++
                 [%{type: :file, name: name, path: path, size_mb: size_mb, processed: nil, metrics: m, thumbs: thumbs}]}

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

  defp collect_video_files_recursive(dir) do
    case File.ls(dir) do
      {:ok, names} ->
        Enum.flat_map(names, fn name ->
          path = Path.join(dir, name)

          cond do
            File.dir?(path) and not String.starts_with?(name, ".") ->
              collect_video_files_recursive(path)

            video_file?(name) ->
              [path]

            true ->
              []
          end
        end)

      _ ->
        []
    end
  end

  defp visible_entries(assigns) do
    case assigns.entries do
      :loading -> []
      entries -> entries
    end
  end

  defp list_dir_gcs(bucket_id, prefix, processed_files) do
    case GCSBuckets.get(bucket_id) do
      nil ->
        []

      bucket_config ->
        full_prefix = case {bucket_config["prefix"], prefix} do
          {"", p} -> p
          {nil, p} -> p
          {base, ""} -> base
          {base, p} -> if String.starts_with?(p, base), do: p, else: base <> p
        end

        case GCS.list_objects(bucket_config, full_prefix) do
          {:ok, entries} ->
            Enum.map(entries, fn
              %{type: :file, path: path} = entry ->
                %{entry | processed: Map.get(processed_files, path)}
              dir_entry ->
                dir_entry
            end)

          {:error, reason} ->
            require Logger
            Logger.error("[VideosLive] GCS list error: #{reason}")
            []
        end
    end
  end

  defp gcs_breadcrumbs(prefix, bucket_prefix) do
    relative = if bucket_prefix && bucket_prefix != "" do
      String.trim_leading(prefix, bucket_prefix)
    else
      prefix
    end
    |> String.trim_leading("/")
    |> String.trim_trailing("/")

    if relative == "" do
      []
    else
      relative
      |> String.split("/")
      |> Enum.scan([], fn segment, acc -> acc ++ [segment] end)
      |> Enum.map(fn segments ->
        path = case bucket_prefix do
          nil -> Enum.join(segments, "/") <> "/"
          "" -> Enum.join(segments, "/") <> "/"
          bp -> bp <> Enum.join(segments, "/") <> "/"
        end
        %{name: List.last(segments), path: path}
      end)
    end
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
        "name" -> Enum.sort_by(files, & &1.name)
        "size" -> Enum.sort_by(files, & &1.size_mb)
        col -> Enum.sort_by(files, &metric_val(&1, col))
      end

    sorted_files = if sort_dir == "desc", do: Enum.reverse(sorted_files), else: sorted_files

    dirs ++ sorted_files
  end

  defp metric_val(%{metrics: nil}, _col), do: -1
  defp metric_val(%{metrics: m}, "det"), do: m["avg_detections_per_frame"] || -1
  defp metric_val(%{metrics: m}, "duration"), do: m["duration_s"] || -1
  defp metric_val(%{metrics: m}, "brightness"), do: m["avg_brightness"] || -1
  defp metric_val(%{metrics: m}, "contrast"), do: m["contrast"] || -1
  defp metric_val(%{metrics: m}, "motion"), do: m["motion_score"] || -1
  defp metric_val(%{metrics: m}, "total_detections"), do: m["total_detections"] || -1
  defp metric_val(%{metrics: m}, "bbox_count"), do: get_in(m, ["bbox_areas", "count"]) || -1
  defp metric_val(%{metrics: m}, "bbox_mean"), do: get_in(m, ["bbox_areas", "mean"]) || -1
  defp metric_val(%{metrics: m}, "fps"), do: m["fps"] || -1
  defp metric_val(_, _), do: -1

  defp recompute_metrics(socket) do
    assigns = socket.assigns

    case assigns.entries do
      :loading ->
        assign(socket,
          visible: [],
          metrics_page: [],
          total_visible: 0,
          has_more_metrics: false,
          summary: nil,
          maxes: %{det: 0, brightness: 255, contrast: 0, motion: 0, bbox_mean: 0, duration: 0},
          ranges: %{},
          scanned_only: [],
          annotations_by_file: %{},
          loading_entries: true
        )

      entries ->
        visible = filtered_entries(entries, assigns.metric_filters)
        summary = compute_metrics_summary(visible)

        all_scanned = Enum.filter(entries, &(&1.type == :file and &1.metrics != nil and !&1.metrics["error"]))
        scanned_files = Enum.filter(visible, &(&1.type == :file and &1.metrics != nil and !&1.metrics["error"]))

        # Single-pass maxes
        maxes = Enum.reduce(scanned_files, %{det: 0, total_det: 0, brightness: 255, contrast: 0, motion: 0, bbox_count: 0, bbox_mean: 0, duration: 0}, fn f, acc ->
          m = f.metrics
          %{acc |
            det: max(acc.det, m["avg_detections_per_frame"] || 0),
            total_det: max(acc.total_det, m["total_detections"] || 0),
            contrast: max(acc.contrast, m["contrast"] || 0),
            motion: max(acc.motion, m["motion_score"] || 0),
            bbox_count: max(acc.bbox_count, get_in(m, ["bbox_areas", "count"]) || 0),
            bbox_mean: max(acc.bbox_mean, get_in(m, ["bbox_areas", "mean"]) || 0),
            duration: max(acc.duration, m["duration_s"] || 0)
          }
        end)

        ranges = compute_metric_ranges(all_scanned)

        visible_files = Enum.filter(visible, &(&1.type == :file))
        total_visible = length(visible_files)
        metrics_page = Enum.take(visible, assigns.metrics_limit)
        has_more = total_visible > assigns.metrics_limit

        annotations_by_file = cached_annotations_by_file()

        assign(socket,
          visible: visible,
          metrics_page: metrics_page,
          total_visible: total_visible,
          has_more_metrics: has_more,
          summary: summary,
          maxes: maxes,
          scanned_only: Enum.take(scanned_files, assigns.metrics_limit),
          ranges: ranges,
          annotations_by_file: annotations_by_file,
          loading_entries: false
        )
    end
  end

  defp filtered_entries(entries, metric_filters) when map_size(metric_filters) == 0, do: entries
  defp filtered_entries(entries, metric_filters) do
    Enum.filter(entries, fn entry ->
      entry.type == :dir or passes_filters?(entry, metric_filters)
    end)
  end

  defp passes_filters?(%{metrics: nil}, _filters), do: false
  defp passes_filters?(%{metrics: m}, filters) do
    Enum.all?(filters, fn {field, {min_val, max_val}} ->
      val = case field do
        "bbox_mean" -> get_in(m, ["bbox_areas", "mean"])
        "bbox_count" -> get_in(m, ["bbox_areas", "count"])
        key -> m[key]
      end

      val = val || 0
      (min_val == nil or val >= min_val) and (max_val == nil or val <= max_val)
    end)
  end

  defp compute_metric_ranges(scanned_files) do
    if scanned_files == [] do
      %{}
    else
      fields = [
        {"avg_detections_per_frame", 0.1},
        {"total_detections", 1},
        {"avg_brightness", 1},
        {"duration_s", 1},
        {"contrast", 0.1},
        {"motion_score", 0.1},
        {"bbox_count", 1},
        {"bbox_mean", 100}
      ]

      for {field, step} <- fields, into: %{} do
        values =
          scanned_files
          |> Enum.map(fn f ->
            case field do
              "bbox_mean" -> get_in(f.metrics, ["bbox_areas", "mean"]) || 0
              "bbox_count" -> get_in(f.metrics, ["bbox_areas", "count"]) || 0
              key -> f.metrics[key] || 0
            end
          end)
          |> Enum.sort()

        count = length(values)
        data_min = List.first(values, 0)
        data_max = List.last(values, 0)
        # Percentiles for context (p10, p25, median, p75, p90)
        p10 = Enum.at(values, div(count, 10), data_min)
        p25 = Enum.at(values, div(count, 4), data_min)
        median = Enum.at(values, div(count, 2), data_min)
        p75 = Enum.at(values, div(count * 3, 4), data_max)
        p90 = Enum.at(values, div(count * 9, 10), data_max)

        # Histogram: 20 bins
        num_bins = 20
        bin_width = if data_max > data_min, do: (data_max - data_min) / num_bins, else: 1
        histogram =
          if data_max > data_min do
            bins = List.duplicate(0, num_bins)
            Enum.reduce(values, bins, fn val, bins ->
              idx = min(trunc((val - data_min) / bin_width), num_bins - 1)
              List.update_at(bins, idx, &(&1 + 1))
            end)
          else
            [count]
          end

        {field, %{
          min: data_min,
          max: data_max,
          step: step,
          p10: p10,
          p25: p25,
          median: median,
          p75: p75,
          p90: p90,
          histogram: histogram
        }}
      end
    end
  end

  defp compute_metrics_summary(entries) do
    scanned = Enum.filter(entries, &(&1.type == :file and &1.metrics != nil and !&1.metrics["error"]))
    count = length(scanned)

    if count == 0 do
      nil
    else
      totals = Enum.reduce(scanned, %{dur: 0, det: 0, bright: 0, contrast: 0, motion: 0, bbox: 0}, fn f, acc ->
        m = f.metrics
        %{acc |
          dur: acc.dur + (m["duration_s"] || 0),
          det: acc.det + (m["avg_detections_per_frame"] || 0),
          bright: acc.bright + (m["avg_brightness"] || 0),
          contrast: acc.contrast + (m["contrast"] || 0),
          motion: acc.motion + (m["motion_score"] || 0),
          bbox: acc.bbox + (get_in(m, ["bbox_areas", "count"]) || 0)
        }
      end)

      %{
        count: count,
        total_duration: Float.round(totals.dur, 1),
        avg_det: Float.round(totals.det / count, 1),
        avg_brightness: Float.round(totals.bright / count, 1),
        avg_contrast: Float.round(totals.contrast / count, 1),
        avg_motion: Float.round(totals.motion / count, 2),
        total_bbox: totals.bbox
      }
    end
  end

  attr :field, :string, required: true
  attr :label, :string, required: true
  attr :filters, :map, required: true
  attr :ranges, :map, required: true

  defp metric_filter(assigns) do
    range = assigns.ranges[assigns.field]
    filter = assigns.filters[assigns.field]
    {filter_min, filter_max} = filter || {nil, nil}

    has_range = range != nil and range.max > range.min

    assigns =
      assigns
      |> assign(
        filter_min: filter_min,
        filter_max: filter_max,
        has_range: has_range,
        active: filter != nil,
        range: range,
        histogram: if(range, do: Jason.encode!(range.histogram), else: "[]")
      )

    ~H"""
    <div>
      <div class="flex items-center justify-between mb-0.5">
        <span class={"text-xs #{if @active, do: "text-primary font-semibold", else: "opacity-70"}"}>{@label}</span>
        <span :if={@has_range} class="text-[10px] font-mono opacity-40">
          {format_metric_val(@range.min)}–{format_metric_val(@range.max)}
        </span>
      </div>
      <div
        :if={@has_range}
        id={"range-slider-#{@field}"}
        phx-hook="RangeSlider"
        phx-update="ignore"
        data-field={@field}
        data-min={@range.min}
        data-max={@range.max}
        data-step={@range.step}
        data-cur-min={@filter_min || @range.min}
        data-cur-max={@filter_max || @range.max}
        data-histogram={@histogram}
        class="rounded"
      />
    </div>
    """
  end

  defp format_metric_val(val) when is_float(val) do
    if val == Float.round(val, 0), do: "#{round(val)}", else: "#{Float.round(val, 1)}"
  end
  defp format_metric_val(val) when is_integer(val), do: "#{val}"
  defp format_metric_val(nil), do: ""
  defp format_metric_val(val), do: "#{val}"


  # Heatmap: returns an rgba background color string for a value in [0, max]
  defp heatmap_bg(_val, max, _hue) when max == 0 or max == nil, do: "background: transparent"
  defp heatmap_bg(nil, _max, _hue), do: "background: transparent"
  defp heatmap_bg(val, max, hue) do
    intensity = min(val / max, 1.0)
    alpha = Float.round(intensity * 0.6 + 0.05, 2)
    "background: hsla(#{hue}, 70%, 50%, #{alpha})"
  end


  defp safe_bbox_mean(%{metrics: nil}), do: 0
  defp safe_bbox_mean(%{metrics: m}), do: get_in(m, ["bbox_areas", "mean"]) || 0
  defp safe_bbox_mean(_), do: 0

  # Scatter: get normalized value for a metric key
  defp scatter_val(entry, key) do
    case key do
      "det" -> metric_val(entry, "det")
      "total_det" -> metric_val(entry, "total_detections")
      "brightness" -> metric_val(entry, "brightness")
      "contrast" -> metric_val(entry, "contrast")
      "motion" -> metric_val(entry, "motion")
      "duration" -> metric_val(entry, "duration")
      "bbox_count" -> metric_val(entry, "bbox_count")
      "bbox_mean" -> safe_bbox_mean(entry)
      "size" -> entry.size_mb
      _ -> 0
    end
  end

  defp scatter_max(files, key) do
    Enum.reduce(files, 0.001, fn f, acc -> max(acc, scatter_val(f, key)) end)
  end

  defp scatter_label(key) do
    case key do
      "det" -> "Det/frame"
      "total_det" -> "Total detections"
      "brightness" -> "Brightness"
      "contrast" -> "Contrast"
      "motion" -> "Motion"
      "duration" -> "Duration (s)"
      "bbox_count" -> "Bbox count"
      "bbox_mean" -> "Bbox mean area"
      "size" -> "File size (MB)"
      _ -> key
    end
  end

  # Distribution strip: compute percentiles for a column
  # Temporal helpers: get samples from entry, with fallback for old data
  defp get_samples(%{metrics: %{"samples" => samples}}) when is_list(samples), do: samples
  defp get_samples(_), do: []

  defp has_samples?(entry), do: get_samples(entry) != []

  # Generate SVG sparkline path for a metric within samples
  defp sparkline_path(samples, key, width, height, max_val, duration \\ nil) do
    n = length(samples)
    if n < 2 or max_val == 0 do
      ""
    else
      dur = duration || 1

      samples
      |> Enum.with_index()
      |> Enum.map(fn {s, i} ->
        x =
          if dur > 0 do
            Float.round((s["t"] || 0) / dur * width, 1)
          else
            Float.round(i / max(n - 1, 1) * width, 1)
          end

        val = Map.get(s, key, 0) || 0
        y = Float.round(height - val / max_val * height, 1)
        cmd = if i == 0, do: "M", else: "L"
        "#{cmd}#{x},#{y}"
      end)
      |> Enum.join(" ")
    end
  end

  # Estimate the timestamp for a thumbnail based on its index and the video duration.
  # Thumbnails are extracted at evenly-spaced positions across the middle 90%.
  defp thumb_time(thumb_path, entry) do
    index_str = thumb_path |> Path.basename(".jpg")
    index = String.to_integer(index_str) - 1
    duration = (entry.metrics && entry.metrics["duration_s"]) || 1
    count = length(Map.get(entry, :thumbs, []))
    start_t = duration * 0.05
    span = duration * 0.9
    t = start_t + index * span / max(count - 1, 1)
    Float.to_string(Float.round(t, 1))
  end

  # Max value for a sample key across all files' samples
  defp samples_max(files, key) do
    files
    |> Enum.flat_map(&get_samples/1)
    |> Enum.reduce(0.001, fn s, acc -> max(acc, Map.get(s, key, 0) || 0) end)
  end

  # Generate a deterministic color for a file index
  defp file_color(index) do
    hues = [0, 142, 200, 45, 280, 30, 320, 100, 170, 60]
    hue = Enum.at(hues, rem(index, length(hues)))
    "hsl(#{hue}, 70%, 55%)"
  end

  defp videos_url(socket, overrides) do
    assigns = socket.assigns
    selected = Map.get(overrides, :file, assigns.selected_file)
    file_param = if selected, do: Path.basename(selected), else: nil

    params =
      %{
        "tab" => Map.get(overrides, :tab, assigns.active_tab),
        "sort" => Map.get(overrides, :sort, assigns.sort_by),
        "dir" => Map.get(overrides, :dir, assigns.sort_dir),
        "source" => Map.get(overrides, :source, assigns.source),
        "view" => Map.get(overrides, :view, assigns.metrics_view),
        "path" => Map.get(overrides, :path, if(assigns.source == "gcs", do: assigns.gcs_prefix, else: Path.relative_to(assigns.current_dir, @videos_root))),
        "file" => file_param
      }
      |> Enum.reject(fn {k, v} -> v == nil or v == "" or (k == "tab" and v == "files") or (k == "sort" and v == "name") or (k == "dir" and v == "asc") or (k == "source" and v == "local") or (k == "view" and v == "heatmap") or (k == "path" and v in ["", "."]) end)
      |> Map.new()

    query = URI.encode_query(params)
    if query == "", do: "/videos", else: "/videos?" <> query
  end

  defp resolve_video_path(filename, current_dir) do
    # 1. Check Video table
    case Repo.one(from v in Video, where: v.filename == ^filename, select: v.path, limit: 1) do
      nil ->
        # 2. Check current directory
        direct = Path.join(current_dir, filename)

        if File.exists?(direct) do
          direct
        else
          # 3. Search under /videos recursively
          case Path.wildcard(Path.join(@videos_root, "**/#{filename}")) do
            [found | _] -> found
            [] -> direct
          end
        end

      path ->
        path
    end
  end

  defp cached_annotations_by_file do
    Naturecounts.Cache.get_or_compute(:annotations_by_file, fn ->
      Annotation
      |> order_by([a], a.timestamp_seconds)
      |> Repo.all()
      |> Enum.group_by(& &1.filename)
    end, ttl: 30_000, group: :annotations)
  end

  defp list_annotations(file) when is_binary(file) do
    basename = Path.basename(file)
    Map.get(cached_annotations_by_file(), basename, [])
  end

  defp list_annotations(_), do: []

  defp invalidate_annotations_cache do
    Naturecounts.Cache.invalidate_group(:annotations)
  end

  defp load_all_annotations(search \\ "") do
    query = Annotation |> order_by([a], [asc: a.filename, asc: a.timestamp_seconds])

    query =
      if search != "" do
        pattern = "%#{search}%"
        where(query, [a], ilike(a.filename, ^pattern) or ilike(a.text, ^pattern))
      else
        query
      end

    Repo.all(query)
  end

  defp load_annotation_thumbs(annotations, current_dir) do
    filenames = annotations |> Enum.map(& &1.filename) |> Enum.uniq()

    Naturecounts.Cache.get_or_compute({:annotation_thumbs, current_dir, filenames}, fn ->
      Enum.reduce(filenames, %{}, fn filename, acc ->
        path = resolve_video_path(filename, current_dir)
        thumbs = ThumbnailWorker.list_thumbs(path)
        metrics = Naturecounts.Offline.MetricsStore.read_one(path)
        duration = (metrics && metrics["duration_s"]) || nil

        if thumbs != [] and duration do
          Map.put(acc, filename, %{thumbs: thumbs, duration: duration})
        else
          acc
        end
      end)
    end, ttl: 60_000, group: :file_browser)
  end

  defp nearest_thumb_url(_filename, nil, _annotation_thumbs), do: nil
  defp nearest_thumb_url(filename, timestamp, annotation_thumbs) do
    case Map.get(annotation_thumbs, filename) do
      %{thumbs: [_ | _] = thumbs, duration: duration} ->
        count = length(thumbs)
        start_t = duration * 0.05
        span = duration * 0.9

        # Find the thumbnail closest to the given timestamp
        {best_path, _} =
          thumbs
          |> Enum.with_index()
          |> Enum.min_by(fn {_path, i} ->
            t = start_t + i * span / max(count - 1, 1)
            abs(t - (timestamp || 0))
          end)

        relative = Path.relative_to(best_path, "/videos")
        "/serve/videos/#{relative}"

      _ ->
        nil
    end
  end

  defp annotation_suggestions(query) do
    pattern = "%#{query}%"

    filenames =
      Annotation
      |> where([a], ilike(a.filename, ^pattern))
      |> select([a], a.filename)
      |> distinct(true)
      |> limit(5)
      |> Repo.all()
      |> Enum.map(&%{type: "file", value: &1})

    texts =
      Annotation
      |> where([a], ilike(a.text, ^pattern))
      |> select([a], a.text)
      |> distinct(true)
      |> limit(5)
      |> Repo.all()
      |> Enum.map(&%{type: "text", value: &1})

    (filenames ++ texts) |> Enum.take(8)
  end

  defp parse_timestamp(str) do
    parts = String.split(str, ":") |> Enum.map(&String.to_integer/1)

    case parts do
      [h, m, s] -> h * 3600 + m * 60 + s
      [m, s] -> m * 60 + s
      [s] -> s
      _ -> 0
    end
  end

  defp format_timestamp(seconds) do
    seconds = trunc(seconds)
    m = div(seconds, 60)
    s = rem(seconds, 60)
    "#{m}:#{String.pad_leading(Integer.to_string(s), 2, "0")}"
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
    Naturecounts.Cache.get_or_compute(:video_jobs, fn ->
      Video
      |> order_by(desc: :inserted_at)
      |> limit(20)
      |> Repo.all()
    end, ttl: 5_000, group: :videos)
  end

  defp schedule_refresh do
    Process.send_after(self(), :refresh, @refresh_interval)
  end

  defp load_active_project(nil), do: nil
  defp load_active_project(id) when is_integer(id), do: Clips.get_project(id)
  defp load_active_project(id) when is_binary(id) do
    case Integer.parse(id) do
      {n, _} -> Clips.get_project(n)
      :error -> nil
    end
  end

  defp reload_project_segments(socket) do
    case socket.assigns[:active_project] do
      nil ->
        assign(socket, project_segments_by_file: %{})

      project ->
        by_file = Enum.group_by(project.segments, & &1.file_path)
        # Reload project to pick up any new segments
        fresh = Clips.get_project(project.id)
        assign(socket, active_project: fresh, project_segments_by_file: by_file_from(fresh))
    end
  end

  defp by_file_from(nil), do: %{}
  defp by_file_from(project), do: Enum.group_by(project.segments, & &1.file_path)

  # Annotations store only the basename; resolve to a full file_path using the
  # current directory or by searching the file browser tree.
  defp resolve_annotation_file_path(filename, current_dir) do
    candidate = Path.join(current_dir, filename)
    if File.exists?(candidate), do: candidate, else: filename
  end

  defp to_float(v) when is_number(v), do: v / 1
  defp to_float(v) when is_binary(v) do
    case Float.parse(v) do
      {f, _} -> f
      :error -> 0.0
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="p-4 space-y-4">
      <div class="flex items-center justify-between gap-4">
        <h1 class="text-2xl font-bold">Video Processing</h1>

        <div class="flex items-center gap-2 text-xs">
          <span class="text-base-content/60">Active project:</span>
          <form phx-change="set_active_project" class="m-0">
            <select name="id" class="select select-xs select-bordered min-w-[180px]">
              <option value="">— none —</option>
              <%= for p <- @projects do %>
                <option value={p.id} selected={@active_project && @active_project.id == p.id}>
                  {p.name} ({length(p.segments)})
                </option>
              <% end %>
            </select>
          </form>
          <%= if @active_project do %>
            <.link navigate={~p"/projects/#{@active_project.id}"} class="btn btn-xs btn-ghost">
              Open
            </.link>
          <% end %>
          <form phx-submit="create_project_inline" class="flex gap-1 m-0">
            <input
              name="name"
              placeholder="New project…"
              class="input input-xs input-bordered w-32"
            />
          </form>
        </div>
      </div>

      <%!-- Tab bar --%>
      <div class="flex items-center gap-2">
        <div class="tabs tabs-boxed bg-base-200 p-1">
          <button class={"tab gap-1.5 #{if @active_tab == "files", do: "tab-active !bg-primary !text-primary-content font-semibold"}"} phx-click="switch_tab" phx-value-tab="files">
            <.icon name="hero-folder" class="size-4" /> Files
          </button>
          <button class={"tab gap-1.5 #{if @active_tab == "metrics", do: "tab-active !bg-primary !text-primary-content font-semibold"}"} phx-click="switch_tab" phx-value-tab="metrics">
            <.icon name="hero-chart-bar" class="size-4" /> Metrics
          </button>
          <button class={"tab gap-1.5 #{if @active_tab == "annotations", do: "tab-active !bg-primary !text-primary-content font-semibold"}"} phx-click="switch_tab" phx-value-tab="annotations">
            <.icon name="hero-tag" class="size-4" /> Annotations
          </button>
        </div>
        <%= if @active_tab == "metrics" do %>
          <div class="flex items-center gap-2">
            <div class="tabs tabs-boxed tabs-xs bg-base-200 p-0.5">
              <button :for={v <- [{"heatmap", "Heatmap", "hero-table-cells"}, {"scatter", "Scatter", "hero-chart-bar-square"}]}
                class={"tab gap-1 #{if @metrics_view == elem(v, 0), do: "tab-active !bg-primary !text-primary-content font-semibold"}"}
                phx-click="set_metrics_view" phx-value-view={elem(v, 0)}
              >
                <.icon name={elem(v, 2)} class="size-3.5" /> {elem(v, 1)}
              </button>
            </div>
            <div class="tabs tabs-boxed tabs-xs bg-base-200 p-0.5">
              <button :for={v <- [{"timeline", "Timeline", "hero-clock"}, {"temporal_scatter", "T-Scatter", "hero-chart-bar-square"}, {"temporal_heatmap", "T-Heatmap", "hero-table-cells"}]}
                class={"tab gap-1 #{if @metrics_view == elem(v, 0), do: "tab-active !bg-primary !text-primary-content font-semibold"}"}
                phx-click="set_metrics_view" phx-value-view={elem(v, 0)}
              >
                <.icon name={elem(v, 2)} class="size-3.5" /> {elem(v, 1)}
              </button>
            </div>
          </div>
        <% end %>
      </div>

      <%!-- Metrics tab --%>
      <%= if @active_tab == "metrics" do %>
        <div class="card bg-base-200">
          <div class="card-body p-4">
            <%!-- Summary stats --%>
            <%= if @summary do %>
              <div class="stats stats-horizontal shadow-sm mb-3 text-sm">
                <div class="stat py-2 px-4">
                  <div class="stat-title text-xs">Scanned</div>
                  <div class="stat-value text-lg">{@summary.count}</div>
                </div>
                <div class="stat py-2 px-4">
                  <div class="stat-title text-xs">Total Duration</div>
                  <div class="stat-value text-lg">{Float.round(@summary.total_duration / 60, 1)}m</div>
                </div>
                <div class="stat py-2 px-4">
                  <div class="stat-title text-xs">Avg Det/frame</div>
                  <div class="stat-value text-lg">{@summary.avg_det}</div>
                </div>
                <div class="stat py-2 px-4">
                  <div class="stat-title text-xs">Avg Brightness</div>
                  <div class="stat-value text-lg">{@summary.avg_brightness}</div>
                </div>
                <div class="stat py-2 px-4">
                  <div class="stat-title text-xs">Avg Contrast</div>
                  <div class="stat-value text-lg">{@summary.avg_contrast}</div>
                </div>
                <div class="stat py-2 px-4">
                  <div class="stat-title text-xs">Avg Motion</div>
                  <div class="stat-value text-lg">{@summary.avg_motion}</div>
                </div>
                <div class="stat py-2 px-4">
                  <div class="stat-title text-xs">Total Bboxes</div>
                  <div class="stat-value text-lg">{@summary.total_bbox}</div>
                </div>
              </div>
            <% end %>

            <%!-- Quick filters --%>
            <div class="flex flex-wrap items-center gap-1 mb-3">
              <span class="text-xs font-semibold text-base-content/60 mr-1">Quick:</span>
              <button class={"btn btn-xs #{if map_size(@metric_filters) == 0, do: "btn-active"}"} phx-click="quick_filter" phx-value-preset="clear">All</button>
              <button class={"btn btn-xs #{if @metric_filters["avg_detections_per_frame"] == {0.1, nil}, do: "btn-success"}"} phx-click="quick_filter" phx-value-preset="has_detections">Has detections</button>
              <button class={"btn btn-xs #{if @metric_filters["avg_detections_per_frame"] == {nil, 0.0}, do: "btn-warning"}"} phx-click="quick_filter" phx-value-preset="no_detections">No detections</button>
              <button class={"btn btn-xs #{if @metric_filters["avg_brightness"] == {nil, 15.0}, do: "btn-neutral"}"} phx-click="quick_filter" phx-value-preset="dark">Dark</button>
              <button class={"btn btn-xs #{if @metric_filters["duration_s"] == {nil, 30.0}, do: "btn-info"}"} phx-click="quick_filter" phx-value-preset="short">Short (&lt;30s)</button>
              <button class={"btn btn-xs #{if @metric_filters["motion_score"] == {5.0, nil}, do: "btn-secondary"}"} phx-click="quick_filter" phx-value-preset="high_motion">High motion</button>
              <button class={"btn btn-xs #{if @metric_filters["bbox_mean"] == {20000, nil}, do: "btn-accent"}"} phx-click="quick_filter" phx-value-preset="large_bbox">Large bbox</button>

              <%= if map_size(@metric_filters) > 0 and @entries != :loading do %>
                <span class="text-xs text-base-content/50 ml-2">
                  {@total_visible} / {length(Enum.filter(@entries, &(&1.type == :file)))} files
                </span>
                <button class="btn btn-xs btn-outline btn-error gap-1 ml-1" phx-click="quick_filter" phx-value-preset="clear">
                  <.icon name="hero-x-mark" class="size-3" /> Reset filters
                </button>
              <% end %>
            </div>

            <%!-- Range filters --%>
            <div class="grid grid-cols-2 md:grid-cols-4 lg:grid-cols-8 gap-x-3 gap-y-1 mb-3">
              <.metric_filter field="avg_detections_per_frame" label="Det/frame" filters={@metric_filters} ranges={@ranges} />
              <.metric_filter field="total_detections" label="Total det" filters={@metric_filters} ranges={@ranges} />
              <.metric_filter field="avg_brightness" label="Brightness" filters={@metric_filters} ranges={@ranges} />
              <.metric_filter field="duration_s" label="Duration (s)" filters={@metric_filters} ranges={@ranges} />
              <.metric_filter field="contrast" label="Contrast" filters={@metric_filters} ranges={@ranges} />
              <.metric_filter field="motion_score" label="Motion" filters={@metric_filters} ranges={@ranges} />
              <.metric_filter field="bbox_count" label="Bbox count" filters={@metric_filters} ranges={@ranges} />
              <.metric_filter field="bbox_mean" label="Bbox area" filters={@metric_filters} ranges={@ranges} />
            </div>

            <%!-- ═══════════════════════════════════════ --%>
            <%!-- VIEW 1: HEATMAP TABLE                  --%>
            <%!-- ═══════════════════════════════════════ --%>
            <%= if @metrics_view == "heatmap" do %>
              <div class="overflow-x-auto">
                <table class="table table-xs">
                  <thead>
                    <tr class="text-xs">
                      <th class="w-6"></th>
                      <th class="cursor-pointer select-none" phx-click="sort_files" phx-value-col="name">File {sort_indicator(@sort_by, @sort_dir, "name")}</th>
                      <th class="cursor-pointer select-none" phx-click="sort_files" phx-value-col="size">Size {sort_indicator(@sort_by, @sort_dir, "size")}</th>
                      <th class="cursor-pointer select-none" phx-click="sort_files" phx-value-col="duration">Dur {sort_indicator(@sort_by, @sort_dir, "duration")}</th>
                      <th class="cursor-pointer select-none" phx-click="sort_files" phx-value-col="det">Det/f {sort_indicator(@sort_by, @sort_dir, "det")}</th>
                      <th class="cursor-pointer select-none" phx-click="sort_files" phx-value-col="total_detections">Total det {sort_indicator(@sort_by, @sort_dir, "total_detections")}</th>
                      <th class="cursor-pointer select-none" phx-click="sort_files" phx-value-col="brightness">Bright {sort_indicator(@sort_by, @sort_dir, "brightness")}</th>
                      <th class="cursor-pointer select-none" phx-click="sort_files" phx-value-col="contrast">Contrast {sort_indicator(@sort_by, @sort_dir, "contrast")}</th>
                      <th class="cursor-pointer select-none" phx-click="sort_files" phx-value-col="motion">Motion {sort_indicator(@sort_by, @sort_dir, "motion")}</th>
                      <th class="cursor-pointer select-none" phx-click="sort_files" phx-value-col="bbox_count">Bboxes {sort_indicator(@sort_by, @sort_dir, "bbox_count")}</th>
                      <th class="cursor-pointer select-none" phx-click="sort_files" phx-value-col="bbox_mean">Bbox avg {sort_indicator(@sort_by, @sort_dir, "bbox_mean")}</th>
                    </tr>
                  </thead>
                  <tbody>
                    <%= for entry <- @metrics_page, entry.type == :file do %>
                      <tr
                        class={["hover cursor-pointer",
                          @selected_file == entry.path && "ring-1 ring-primary",
                          MapSet.member?(@selected_files, entry.path) && "bg-error/10"]}
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
                        <td class="font-mono text-xs truncate max-w-[180px]" title={entry.name} phx-click="select_file" phx-value-file={entry.path}>
                          <span class="flex items-center gap-1">
                            <%= if entry.processed do %>
                              <span class={["w-2 h-2 rounded-full shrink-0",
                                entry.processed.status == "completed" && profile_dot(entry.processed.profile),
                                entry.processed.status == "processing" && "bg-info animate-pulse",
                                entry.processed.status == "pending" && "bg-base-content/30"
                              ]} />
                            <% end %>
                            {entry.name}
                          </span>
                        </td>
                        <td class="text-xs text-base-content/60" phx-click="select_file" phx-value-file={entry.path}>{entry.size_mb}MB</td>
                        <%= if entry.metrics && !entry.metrics["error"] do %>
                          <td class="text-xs font-mono">{entry.metrics["duration_s"]}s</td>
                          <td class="text-xs font-mono text-center rounded" style={heatmap_bg(entry.metrics["avg_detections_per_frame"], @maxes.det, 142)}>
                            {entry.metrics["avg_detections_per_frame"]}
                          </td>
                          <td class="text-xs font-mono text-center rounded" style={heatmap_bg(entry.metrics["total_detections"], @maxes.total_det, 160)}>
                            {entry.metrics["total_detections"] || 0}
                          </td>
                          <td class="text-xs font-mono text-center rounded" style={heatmap_bg(entry.metrics["avg_brightness"], 255, 45)}>
                            {entry.metrics["avg_brightness"] || "-"}
                          </td>
                          <td class="text-xs font-mono text-center rounded" style={heatmap_bg(entry.metrics["contrast"], @maxes.contrast, 200)}>
                            {entry.metrics["contrast"] || "-"}
                          </td>
                          <td class="text-xs font-mono text-center rounded" style={heatmap_bg(entry.metrics["motion_score"], @maxes.motion, 280)}>
                            {entry.metrics["motion_score"] || "-"}
                          </td>
                          <td class="text-xs font-mono text-center">{get_in(entry.metrics, ["bbox_areas", "count"]) || 0}</td>
                          <td class="text-xs font-mono text-center rounded" style={heatmap_bg(get_in(entry.metrics, ["bbox_areas", "mean"]), @maxes.bbox_mean, 30)}>
                            {get_in(entry.metrics, ["bbox_areas", "mean"]) || 0}
                          </td>
                        <% else %>
                          <td colspan="8" class="text-xs text-base-content/30 italic">Not scanned</td>
                        <% end %>
                      </tr>
                    <% end %>
                  </tbody>
                </table>
              </div>
            <% end %>

            <%!-- ═══════════════════════════════════════ --%>
            <%!-- VIEW 3: SCATTER PLOT                   --%>
            <%!-- ═══════════════════════════════════════ --%>
            <%= if @metrics_view == "scatter" do %>
              <div>
                <div class="flex items-center gap-4 mb-2">
                  <form class="flex items-center gap-1" phx-change="set_scatter_axis">
                    <span class="text-xs text-base-content/60">X:</span>
                    <input type="hidden" name="axis" value="x" />
                    <select class="select select-bordered select-xs" name="value">
                      <option :for={k <- ["brightness", "det", "total_det", "contrast", "motion", "duration", "bbox_count", "bbox_mean", "size"]}
                        value={k} selected={@scatter_x == k}>{scatter_label(k)}</option>
                    </select>
                  </form>
                  <form class="flex items-center gap-1" phx-change="set_scatter_axis">
                    <span class="text-xs text-base-content/60">Y:</span>
                    <input type="hidden" name="axis" value="y" />
                    <select class="select select-bordered select-xs" name="value">
                      <option :for={k <- ["det", "brightness", "contrast", "motion", "duration", "bbox_mean", "size"]}
                        value={k} selected={@scatter_y == k}>{scatter_label(k)}</option>
                    </select>
                  </form>
                  <form class="flex items-center gap-1" phx-change="set_scatter_axis">
                    <span class="text-xs text-base-content/60">Color:</span>
                    <input type="hidden" name="axis" value="color" />
                    <select class="select select-bordered select-xs" name="value">
                      <option :for={k <- ["motion", "brightness", "det", "contrast", "duration", "bbox_mean", "size"]}
                        value={k} selected={@scatter_color == k}>{scatter_label(k)}</option>
                    </select>
                  </form>
                </div>
                <div class="bg-base-100 rounded-lg p-4">
                  <svg viewBox="0 0 900 320" class="w-full">
                    <%!-- Grid --%>
                    <line x1="50" y1="10" x2="50" y2="280" stroke="currentColor" opacity="0.15" />
                    <line x1="50" y1="280" x2="880" y2="280" stroke="currentColor" opacity="0.15" />
                    <line :for={i <- 1..4} x1="50" y1={280 - i * 54} x2="880" y2={280 - i * 54} stroke="currentColor" opacity="0.06" stroke-dasharray="4" />
                    <line :for={i <- 1..4} x1={50 + i * 166} y1="10" x2={50 + i * 166} y2="280" stroke="currentColor" opacity="0.06" stroke-dasharray="4" />

                    <%!-- Axis labels --%>
                    <text x="465" y="305" text-anchor="middle" fill="currentColor" opacity="0.5" font-size="11">{scatter_label(@scatter_x)}</text>
                    <text x="15" y="145" text-anchor="middle" fill="currentColor" opacity="0.5" font-size="11" transform="rotate(-90, 15, 145)">{scatter_label(@scatter_y)}</text>

                    <%!-- Data points --%>
                    <% x_max = scatter_max(@scanned_only, @scatter_x) %>
                    <% y_max = scatter_max(@scanned_only, @scatter_y) %>
                    <% color_max = scatter_max(@scanned_only, @scatter_color) %>
                    <%= for entry <- @scanned_only do %>
                      <% cx = 50 + scatter_val(entry, @scatter_x) / x_max * 830 %>
                      <% cy = 280 - scatter_val(entry, @scatter_y) / y_max * 270 %>
                      <% color_t = Float.round(min(scatter_val(entry, @scatter_color) / color_max, 1.0), 3) %>
                      <% hue = Float.round(240 * (1 - color_t), 0) %>
                      <circle
                        cx={Float.round(cx, 1)} cy={Float.round(cy, 1)} r={if @selected_file == entry.path, do: "6", else: "4"}
                        fill={if @selected_file == entry.path, do: "hsl(var(--p))", else: "hsl(#{hue}, 80%, 55%)"}
                        opacity={if @selected_file == entry.path, do: "1", else: "0.7"}
                        class="cursor-pointer hover:opacity-100 transition-opacity"
                        phx-click="select_file" phx-value-file={entry.path}
                      >
                        <title>{entry.name} — {scatter_label(@scatter_x)}: {scatter_val(entry, @scatter_x)}, {scatter_label(@scatter_y)}: {scatter_val(entry, @scatter_y)}, {scatter_label(@scatter_color)}: {scatter_val(entry, @scatter_color)}</title>
                      </circle>
                    <% end %>

                    <%!-- Color legend --%>
                    <rect :for={i <- 0..9} x={700 + i * 18} y="10" width="18" height="8" rx="1"
                      fill={"hsl(#{240 - i * 24}, 80%, 55%)"} />
                    <text x="700" y="28" fill="currentColor" opacity="0.4" font-size="9">low</text>
                    <text x="880" y="28" text-anchor="end" fill="currentColor" opacity="0.4" font-size="9">{scatter_label(@scatter_color)}</text>
                  </svg>
                </div>
              </div>
            <% end %>

            <%!-- ═══════════════════════════════════════ --%>
            <%!-- VIEW 6: TIMELINE SPARKLINES            --%>
            <%!-- ═══════════════════════════════════════ --%>
            <%= if @metrics_view == "timeline" do %>
              <div class="overflow-x-auto">
                <% det_max = samples_max(@scanned_only, "det") %>
                <% bright_max = samples_max(@scanned_only, "bright") %>
                <% motion_max = samples_max(@scanned_only, "motion") %>
                <div class="flex items-center gap-3 text-[10px] text-base-content/50 mb-2">
                  <span class="mr-1 text-base-content/40">Sort:</span>
                  <button class={"flex items-center gap-1 hover:text-success cursor-pointer #{if @sort_by == "det", do: "text-success font-bold"}"} phx-click="sort_files" phx-value-col="det">
                    <span class="inline-block w-3 h-0.5 rounded bg-success" />Detections {sort_indicator(@sort_by, @sort_dir, "det")}
                  </button>
                  <button class={"flex items-center gap-1 hover:text-warning cursor-pointer #{if @sort_by == "brightness", do: "text-warning font-bold"}"} phx-click="sort_files" phx-value-col="brightness">
                    <span class="inline-block w-3 h-0.5 rounded bg-warning" />Brightness {sort_indicator(@sort_by, @sort_dir, "brightness")}
                  </button>
                  <button class={"flex items-center gap-1 hover:text-secondary cursor-pointer #{if @sort_by == "motion", do: "text-secondary font-bold"}"} phx-click="sort_files" phx-value-col="motion">
                    <span class="inline-block w-3 h-0.5 rounded bg-secondary" />Motion {sort_indicator(@sort_by, @sort_dir, "motion")}
                  </button>
                  <button class={"flex items-center gap-1 hover:text-base-content cursor-pointer #{if @sort_by == "name", do: "font-bold"}"} phx-click="sort_files" phx-value-col="name">
                    Name {sort_indicator(@sort_by, @sort_dir, "name")}
                  </button>
                  <span class="mx-1 text-base-content/20">|</span>
                  <label class="flex items-center gap-1 cursor-pointer">
                    <input type="checkbox" class="checkbox checkbox-xs" checked={@show_thumbs} phx-click="toggle_thumbs" />
                    <span>Thumbs</span>
                  </label>
                </div>
                <div class="space-y-1">
                  <%= for entry <- @metrics_page, entry.type == :file do %>
                    <div
                      class={["flex items-center gap-2 p-1 rounded hover:bg-base-300/50 cursor-pointer",
                        @selected_file == entry.path && "ring-1 ring-primary bg-primary/10",
                        MapSet.member?(@selected_files, entry.path) && "bg-error/10"]}
                    >
                      <input
                        type="checkbox"
                        class="checkbox checkbox-xs checkbox-error shrink-0"
                        checked={MapSet.member?(@selected_files, entry.path)}
                        phx-click="toggle_select"
                        phx-value-file={entry.path}
                      />
                      <div class="w-[140px] shrink-0" phx-click="select_file" phx-value-file={entry.path}>
                        <span class="flex items-center gap-1">
                          <%= if entry.processed do %>
                            <span class={["w-2 h-2 rounded-full shrink-0",
                              entry.processed.status == "completed" && profile_dot(entry.processed.profile),
                              entry.processed.status == "processing" && "bg-info animate-pulse",
                              entry.processed.status == "pending" && "bg-base-content/30"
                            ]} />
                          <% end %>
                          <span class="font-mono text-xs truncate" title={entry.name}>{entry.name}</span>
                        </span>
                        <div class="text-[10px] text-base-content/40">
                          {entry.size_mb}MB
                          <%= if entry.metrics do %>
                            &middot; {entry.metrics["duration_s"]}s
                          <% end %>
                        </div>
                      </div>
                      <div
                        class="flex-1 min-w-[200px] relative"
                        id={"tl-row-#{entry.name}"}
                        phx-hook="TimelinePlayhead"
                        data-duration={if entry.metrics, do: entry.metrics["duration_s"]}
                        data-active={if @selected_file == entry.path, do: "true"}
                        data-file={entry.path}
                        data-project-active={if @active_project, do: "true"}
                      >
                        <div
                          id={"tl-playhead-slot-#{entry.name}"}
                          phx-update="ignore"
                          class="absolute inset-0 pointer-events-none z-20"
                        ></div>
                        <%= if has_samples?(entry) do %>
                          <% samples = get_samples(entry) %>
                          <% n = length(samples) %>
                          <% file_duration = (entry.metrics && entry.metrics["duration_s"]) || 1 %>
                          <% file_anns = Map.get(@annotations_by_file, entry.name, []) %>
                          <% has_anns = file_anns != [] %>
                          <% file_segs = Map.get(@project_segments_by_file, entry.path, []) %>
                          <% has_segs = file_segs != [] %>
                          <% svg_h = 30 + (if has_anns, do: 6, else: 0) + (if has_segs, do: 6, else: 0) %>
                          <% svg_class_h = cond do
                            has_anns and has_segs -> "h-10"
                            has_anns or has_segs -> "h-9"
                            true -> "h-8"
                          end %>
                          <svg viewBox={"0 0 200 #{svg_h}"} class={"w-full #{svg_class_h}"} preserveAspectRatio="none">
                            <rect x="0" y="0" width="200" height="30" fill="currentColor" opacity="0.03" rx="2" />
                            <%!-- Detection bars (clickable, time-based x) --%>
                            <% bar_w = max(200 / max(n, 1) - 1, 2) %>
                            <%= for {s, _i} <- Enum.with_index(samples) do %>
                              <% bar_x = (s["t"] || 0) / file_duration * 200 %>
                              <% bar_h = if det_max > 0, do: (s["det"] || 0) / det_max * 28, else: 0 %>
                              <rect
                                x={Float.round(bar_x, 1)}
                                y="0" width={Float.round(bar_w, 1)} height="30"
                                fill="transparent" class="cursor-pointer tl-sample-bar"
                                phx-click="seek_sample"
                                phx-value-file={entry.path}
                                phx-value-time={"#{s["t"] / 1}"}
                                data-time={s["t"]}
                                data-det={s["det"]}
                                data-bright={s["bright"]}
                                data-motion={s["motion"]}
                                data-contrast={s["contrast"]}
                              />
                              <rect
                                x={Float.round(bar_x, 1)}
                                y={Float.round(30 - bar_h, 1)}
                                width={Float.round(bar_w, 1)}
                                height={Float.round(max(bar_h, 0), 1)}
                                fill="hsl(142, 70%, 50%)" opacity="0.5" rx="1"
                                class="pointer-events-none"
                              />
                            <% end %>
                            <%!-- Brightness line --%>
                            <path d={sparkline_path(samples, "bright", 200, 30, bright_max, file_duration)} fill="none" stroke="hsl(45, 80%, 55%)" stroke-width="1.5" opacity="0.7" class="pointer-events-none" />
                            <%!-- Motion line --%>
                            <path d={sparkline_path(samples, "motion", 200, 30, motion_max, file_duration)} fill="none" stroke="hsl(280, 70%, 55%)" stroke-width="1" opacity="0.6" stroke-dasharray="3,2" class="pointer-events-none" />
                            <%!-- Annotation strip below graph --%>
                            <%= if has_anns do %>
                              <% file_duration = entry.metrics["duration_s"] || 1 %>
                              <rect x="0" y="31" width="200" height="5" fill="currentColor" opacity="0.05" rx="1" class="pointer-events-none" />
                              <%= for ann <- file_anns do %>
                                <%= if ann.end_seconds do %>
                                  <rect
                                    x={Float.round(ann.timestamp_seconds / file_duration * 200, 1)}
                                    y="31"
                                    width={Float.round(max((ann.end_seconds - ann.timestamp_seconds) / file_duration * 200, 2), 1)}
                                    height="5"
                                    fill="hsl(200, 80%, 60%)" opacity="0.7" rx="1"
                                    class="pointer-events-none"
                                  />
                                <% else %>
                                  <rect
                                    x={Float.round(ann.timestamp_seconds / file_duration * 200 - 1, 1)}
                                    y="31"
                                    width="3"
                                    height="5"
                                    fill="hsl(200, 80%, 60%)" opacity="0.9" rx="0.5"
                                    class="pointer-events-none"
                                />
                              <% end %>
                            <% end %>
                          <% end %>
                          <%!-- Project segment ghosts --%>
                          <%= if has_segs do %>
                            <% seg_y = if has_anns, do: 37, else: 31 %>
                            <rect x="0" y={seg_y} width="200" height="5" fill="hsl(142, 70%, 50%)" opacity="0.08" rx="1" class="pointer-events-none" />
                            <%= for seg <- file_segs do %>
                              <rect
                                x={Float.round(seg.start_seconds / file_duration * 200, 1)}
                                y={seg_y}
                                width={Float.round(max((seg.end_seconds - seg.start_seconds) / file_duration * 200, 2), 1)}
                                height="5"
                                fill="hsl(142, 70%, 50%)" opacity="0.85" rx="1"
                                class="pointer-events-none"
                              >
                                <title>segment #{seg.position}: {seg.label || "(unlabeled)"}</title>
                              </rect>
                            <% end %>
                          <% end %>
                          </svg>
                        <% else %>
                          <div class="h-8 flex items-center justify-center">
                            <span class="text-[10px] text-base-content/20 italic">No temporal data</span>
                          </div>
                        <% end %>
                        <%= if @show_thumbs and Map.get(entry, :thumbs, []) != [] do %>
                          <div class="flex gap-px mt-0.5 overflow-hidden rounded" style="height:24px">
                            <%= for thumb_path <- Map.get(entry, :thumbs, []) do %>
                              <% relative = Path.relative_to(thumb_path, "/videos") %>
                              <img
                                src={"/serve/videos/#{relative}"}
                                data-full-thumb={"/serve/videos/#{relative}"}
                                class="h-full flex-1 object-cover min-w-0 cursor-pointer opacity-70 hover:opacity-100 transition-opacity"
                                loading="lazy"
                              />
                            <% end %>
                          </div>
                        <% end %>
                      </div>
                      <div class="w-16 text-right text-xs font-mono text-base-content/50 shrink-0">
                        <%= if entry.metrics && !entry.metrics["error"] do %>
                          {entry.metrics["avg_detections_per_frame"]} det
                        <% end %>
                      </div>
                    </div>
                  <% end %>
                </div>
              </div>
            <% end %>

            <%!-- ═══════════════════════════════════════ --%>
            <%!-- VIEW 7: TEMPORAL SCATTER               --%>
            <%!-- ═══════════════════════════════════════ --%>
            <%= if @metrics_view == "temporal_scatter" do %>
              <div>
                <div class="flex items-center gap-4 mb-2">
                  <form class="flex items-center gap-1" phx-change="set_temporal_y">
                    <span class="text-xs text-base-content/60">Y axis:</span>
                    <select class="select select-bordered select-xs" name="value">
                      <option :for={k <- ["det", "bright", "contrast", "motion"]}
                        value={k} selected={@temporal_y == k}>
                        {case k do; "det" -> "Detections"; "bright" -> "Brightness"; "contrast" -> "Contrast"; "motion" -> "Motion"; _ -> k; end}
                      </option>
                    </select>
                  </form>
                  <span class="text-[10px] text-base-content/40">X = time position in video (s). Each color = one file.</span>
                </div>
                <div class="bg-base-100 rounded-lg p-4">
                  <% temporal_files = Enum.filter(@scanned_only, &has_samples?/1) |> Enum.with_index() %>
                  <% y_max = samples_max(@scanned_only, @temporal_y) %>
                  <% x_max = Enum.reduce(@scanned_only, 0.001, fn f, acc -> max(acc, f.metrics["duration_s"] || 0) end) %>
                  <svg viewBox="0 0 900 300" class="w-full">
                    <%!-- Grid --%>
                    <line x1="50" y1="10" x2="50" y2="260" stroke="currentColor" opacity="0.15" />
                    <line x1="50" y1="260" x2="880" y2="260" stroke="currentColor" opacity="0.15" />
                    <line :for={i <- 1..4} x1="50" y1={260 - i * 50} x2="880" y2={260 - i * 50} stroke="currentColor" opacity="0.06" stroke-dasharray="4" />
                    <line :for={i <- 1..4} x1={50 + i * 166} y1="10" x2={50 + i * 166} y2="260" stroke="currentColor" opacity="0.06" stroke-dasharray="4" />

                    <%!-- Axis labels --%>
                    <text x="465" y="285" text-anchor="middle" fill="currentColor" opacity="0.5" font-size="11">Time (s)</text>
                    <text x="15" y="135" text-anchor="middle" fill="currentColor" opacity="0.5" font-size="11" transform="rotate(-90, 15, 135)">
                      {case @temporal_y do; "det" -> "Detections"; "bright" -> "Brightness"; "contrast" -> "Contrast"; "motion" -> "Motion"; _ -> @temporal_y; end}
                    </text>

                    <%!-- Data points per file --%>
                    <%= for {entry, fi} <- temporal_files do %>
                      <% color = file_color(fi) %>
                      <% samples = get_samples(entry) %>
                      <%= for s <- samples do %>
                        <% cx = 50 + (s["t"] || 0) / x_max * 830 %>
                        <% val = s[@temporal_y] || 0 %>
                        <% cy = 260 - val / y_max * 250 %>
                        <circle
                          cx={Float.round(cx, 1)} cy={Float.round(cy, 1)}
                          r={if @selected_file == entry.path, do: "5", else: "3.5"}
                          fill={color}
                          opacity={if @selected_file == entry.path, do: "0.9", else: "0.5"}
                          class="cursor-pointer hover:opacity-100"
                          phx-click="seek_sample"
                          phx-value-file={entry.path}
                          phx-value-time={"#{s["t"] / 1}"}
                        >
                          <title>{entry.name} — t={s["t"]}s, {@temporal_y}={s[@temporal_y]} — click to play</title>
                        </circle>
                      <% end %>
                    <% end %>

                    <%!-- Legend --%>
                    <%= for {entry, fi} <- Enum.take(temporal_files, 10) do %>
                      <circle cx={60 + rem(fi, 5) * 166} cy={270 + div(fi, 5) * 12} r="3" fill={file_color(fi)} />
                      <text x={67 + rem(fi, 5) * 166} y={273 + div(fi, 5) * 12} fill="currentColor" opacity="0.5" font-size="8">
                        {String.slice(entry.name, 0, 12)}
                      </text>
                    <% end %>
                  </svg>
                </div>
              </div>
            <% end %>

            <%!-- ═══════════════════════════════════════ --%>
            <%!-- VIEW 8: TEMPORAL HEATMAP               --%>
            <%!-- ═══════════════════════════════════════ --%>
            <%= if @metrics_view == "temporal_heatmap" do %>
              <div class="overflow-x-auto">
                <div class="flex items-center gap-4 mb-2">
                  <span class="text-xs text-base-content/60">Rows = files, columns = sample time points, color intensity = detection count</span>
                  <div class="flex items-center gap-1 text-[10px] text-base-content/40">
                    <span class="inline-block w-3 h-3 rounded" style="background: hsla(142, 70%, 50%, 0.05)" /> 0
                    <span class="inline-block w-3 h-3 rounded" style="background: hsla(142, 70%, 50%, 0.3)" /> low
                    <span class="inline-block w-3 h-3 rounded" style="background: hsla(142, 70%, 50%, 0.6)" /> high
                  </div>
                </div>
                <% det_max_h = samples_max(@scanned_only, "det") %>
                <% max_samples = Enum.reduce(@scanned_only, 0, fn f, acc -> max(acc, length(get_samples(f))) end) %>
                <% max_samples = max(max_samples, 1) %>
                <div class="space-y-px">
                  <%= for entry <- @metrics_page, entry.type == :file do %>
                    <div
                      class={["flex items-center gap-1 cursor-pointer hover:bg-base-300/30 rounded",
                        @selected_file == entry.path && "ring-1 ring-primary",
                        MapSet.member?(@selected_files, entry.path) && "bg-error/10"]}
                    >
                      <input
                        type="checkbox"
                        class="checkbox checkbox-xs checkbox-error shrink-0"
                        checked={MapSet.member?(@selected_files, entry.path)}
                        phx-click="toggle_select"
                        phx-value-file={entry.path}
                      />
                      <div class="w-[130px] shrink-0 pr-1" phx-click="select_file" phx-value-file={entry.path}>
                        <span class="font-mono text-[10px] truncate block" title={entry.name}>{entry.name}</span>
                      </div>
                      <div class="flex-1 flex items-center gap-px h-5">
                        <%= if has_samples?(entry) do %>
                          <% samples = get_samples(entry) %>
                          <%= for s <- samples do %>
                            <% det = s["det"] || 0 %>
                            <% alpha = if det_max_h > 0, do: Float.round(det / det_max_h * 0.7 + 0.05, 2), else: 0.05 %>
                            <div
                              class="h-full rounded-sm flex-1 cursor-pointer hover:ring-1 hover:ring-primary"
                              style={"background: hsla(142, 70%, 50%, #{alpha}); min-width: 4px"}
                              title={"t=#{s["t"]}s det=#{det} — click to play"}
                              phx-click="seek_sample"
                              phx-value-file={entry.path}
                              phx-value-time={"#{s["t"] / 1}"}
                            />
                          <% end %>
                          <%!-- Pad if fewer samples than max --%>
                          <%= if length(samples) < max_samples do %>
                            <div :for={_ <- 1..(max_samples - length(samples))} class="h-full flex-1" style="min-width: 4px" />
                          <% end %>
                        <% else %>
                          <div class="h-full flex-1 flex items-center justify-center">
                            <span class="text-[9px] text-base-content/20 italic">no data</span>
                          </div>
                        <% end %>
                      </div>
                      <div class="w-12 text-right text-[10px] font-mono text-base-content/40 shrink-0">
                        <%= if entry.metrics do %>
                          {entry.metrics["duration_s"]}s
                        <% end %>
                      </div>
                    </div>
                  <% end %>
                </div>
              </div>
            <% end %>

            <%!-- Load more --%>
            <%= if @has_more_metrics do %>
              <div class="flex items-center justify-center gap-2 py-2">
                <span class="text-xs text-base-content/40">
                  Showing {@metrics_limit} of {@total_visible} files
                </span>
                <button class="btn btn-ghost btn-xs" phx-click="load_more_metrics">Load more</button>
                <button class="btn btn-ghost btn-xs" phx-click="load_all_metrics">All</button>
              </div>
            <% else %>
              <%= if @total_visible > 0 do %>
                <div class="text-center text-xs text-base-content/30 py-1">
                  All {@total_visible} files shown
                </div>
              <% end %>
            <% end %>

          </div>
        </div>
      <% end %>

      <%!-- Files tab --%>
      <%= if @active_tab == "files" do %>
          <div class="card bg-base-200">
            <div class="card-body p-4">
              <div class="flex items-center justify-between">
                <div class="flex items-center gap-2">
                  <h2 class="card-title text-lg">Files</h2>
                  <div class="join">
                    <button
                      class={"join-item btn btn-xs #{if @source == "local", do: "btn-active"}"}
                      phx-click="switch_source" phx-value-source="local"
                    >Local</button>
                    <button
                      class={"join-item btn btn-xs #{if @source == "gcs", do: "btn-active"}"}
                      phx-click="switch_source" phx-value-source="gcs"
                    >GCS</button>
                  </div>
                </div>
                <div class="flex items-center gap-1">
                  <%= if @scanning do %>
                    <button class="btn btn-error btn-xs gap-1" phx-click="cancel_scan">
                      <span class="loading loading-spinner loading-xs"></span> Cancel
                    </button>
                  <% else %>
                    <label class="label cursor-pointer gap-1 p-0">
                      <span class="label-text text-[10px] text-base-content/50">Force</span>
                      <input type="checkbox" class="checkbox checkbox-xs" checked={@scan_force} phx-click="toggle_scan_force" />
                    </label>
                    <button class="btn btn-ghost btn-xs" phx-click="scan_metrics">Scan</button>
                    <button class="btn btn-ghost btn-xs" phx-click="generate_thumbnails" title="Extract thumbnail frames from each video">Thumbs</button>
                    <button class="btn btn-ghost btn-xs" phx-click="fix_timestamps" title="Remux MP4s to fix non-zero start_time (enables browser seeking)">Fix seek</button>
                    <button class="btn btn-ghost btn-xs" phx-click="select_black_videos" title="Select videos with 0 detections">Select empty</button>
                  <% end %>
                </div>
              </div>

              <%!-- Scan progress bar --%>
              <%= if @scanning do %>
                <div class="bg-base-300 rounded-lg p-2 space-y-1">
                  <%= if @scan_progress do %>
                    <% done = @scan_progress["done"] || 0 %>
                    <% total = @scan_progress["total"] || 1 %>
                    <% executing = @scan_progress["executing"] || 0 %>
                    <% pending = @scan_progress["pending"] || 0 %>
                    <% failed = @scan_progress["failed"] || 0 %>
                    <% pct = if total > 0, do: round(done / total * 100), else: 0 %>
                    <div class="flex items-center gap-2">
                      <progress class="progress progress-primary flex-1" value={done} max={total} />
                      <span class="text-xs font-mono font-bold whitespace-nowrap">{pct}%</span>
                    </div>
                    <div class="flex items-center gap-3 text-[10px] text-base-content/50">
                      <span class="text-success">{done} done</span>
                      <span>{executing} running</span>
                      <span>{pending} queued</span>
                      <span :if={failed > 0} class="text-error">{failed} failed</span>
                      <span class="ml-auto">{total} total</span>
                    </div>
                  <% else %>
                    <div class="flex items-center gap-2">
                      <span class="loading loading-spinner loading-xs"></span>
                      <span class="text-xs text-base-content/50">Starting scan...</span>
                    </div>
                  <% end %>
                </div>
              <% end %>

              <%!-- GCS bucket selector --%>
              <%= if @source == "gcs" do %>
                <div class="flex items-center gap-1 flex-wrap">
                  <%= for b <- @gcs_buckets do %>
                    <div class="flex items-center gap-0">
                      <button
                        class={"btn btn-xs #{if @selected_bucket == b["id"], do: "btn-primary", else: "btn-ghost"}"}
                        phx-click="select_bucket" phx-value-id={b["id"]}
                        title={b["credentials"] && b["credentials"]["client_email"] || "no credentials"}
                      >
                        <span :if={b["credentials"]} class="text-success text-[8px]">*</span>
                        {b["name"]}
                      </button>
                      <button class="btn btn-xs btn-ghost opacity-50 hover:opacity-100 px-1" phx-click="edit_bucket" phx-value-id={b["id"]} title="Edit">e</button>
                      <button class="btn btn-xs btn-ghost text-error opacity-50 hover:opacity-100 px-1" phx-click="delete_bucket" phx-value-id={b["id"]} data-confirm={"Delete bucket '#{b["name"]}'?"}>x</button>
                    </div>
                  <% end %>
                  <button class="btn btn-xs btn-ghost" phx-click="toggle_add_bucket">+ Add</button>
                </div>

                <%= if @adding_bucket do %>
                  <div class="bg-base-300 rounded-lg p-3 mt-1 space-y-2">
                    <div class="text-xs font-semibold"><%= if @editing_bucket, do: "Edit Bucket", else: "Add GCS Bucket" %></div>
                    <form phx-submit="save_bucket" class="space-y-2">
                      <div class="flex gap-2 flex-wrap">
                        <div class="form-control">
                          <label class="label py-0"><span class="label-text text-xs">Display Name</span></label>
                          <input type="text" name="name" placeholder="Marine Cam East" class="input input-xs input-bordered w-36" value={@new_bucket_name} />
                        </div>
                        <div class="form-control">
                          <label class="label py-0"><span class="label-text text-xs">GCS Bucket ID</span></label>
                          <input type="text" name="bucket" placeholder="my-project-videos" class="input input-xs input-bordered w-44" value={@new_bucket_id} />
                        </div>
                        <div class="form-control">
                          <label class="label py-0"><span class="label-text text-xs">Path Prefix (optional)</span></label>
                          <input type="text" name="prefix" placeholder="cameras/east/" class="input input-xs input-bordered w-36" value={@new_bucket_prefix} />
                        </div>
                      </div>
                      <div class="form-control">
                        <label class="label py-0">
                          <span class="label-text text-xs">
                            Service Account JSON
                            <%= if @editing_bucket do %><span class="text-base-content/40">(leave empty to keep existing)</span><% end %>
                          </span>
                        </label>
                        <textarea name="credentials" rows="3" placeholder='{"type": "service_account", ...}' class="textarea textarea-bordered textarea-xs font-mono text-[10px] leading-tight w-full">{@new_bucket_creds}</textarea>
                      </div>
                      <div class="flex items-center gap-2">
                        <button type="submit" name="action" value="test" class="btn btn-xs btn-outline">Test</button>
                        <button type="submit" name="action" value="save" class="btn btn-xs btn-primary"><%= if @editing_bucket, do: "Update", else: "Save" %></button>
                        <button type="button" class="btn btn-xs btn-ghost" phx-click="toggle_add_bucket">Cancel</button>
                        <%= if @bucket_test_result do %>
                          <%= case @bucket_test_result do %>
                            <% :ok -> %><span class="badge badge-xs badge-success">Connected</span>
                            <% {:error, msg} -> %><span class="badge badge-xs badge-error" title={msg}>Failed</span>
                          <% end %>
                        <% end %>
                      </div>
                    </form>
                  </div>
                <% end %>
              <% end %>

              <%!-- Breadcrumbs --%>
              <div class="text-sm breadcrumbs py-0">
                <ul>
                  <%= if @source == "gcs" do %>
                    <% bucket_config = Enum.find(@gcs_buckets, fn b -> b["id"] == @selected_bucket end) %>
                    <li>
                      <a class="link link-hover" phx-click="navigate_dir" phx-value-path={bucket_config && bucket_config["prefix"] || ""}>
                        gs://{bucket_config && bucket_config["bucket"]}
                      </a>
                    </li>
                    <li :for={crumb <- gcs_breadcrumbs(@gcs_prefix, bucket_config && bucket_config["prefix"])}>
                      <a class="link link-hover" phx-click="navigate_dir" phx-value-path={crumb.path}>{crumb.name}</a>
                    </li>
                  <% else %>
                    <li><a class="link link-hover" phx-click="navigate_dir" phx-value-path="/videos">/videos</a></li>
                    <li :for={crumb <- @breadcrumbs}>
                      <a class="link link-hover" phx-click="navigate_dir" phx-value-path={crumb.path}>{crumb.name}</a>
                    </li>
                  <% end %>
                </ul>
              </div>

              <%!-- Selection bar --%>
              <div class="flex items-center gap-2 py-1">
                <button class="btn btn-ghost btn-xs" phx-click="select_all">All</button>
                <button class="btn btn-ghost btn-xs" phx-click="select_none">None</button>
                <%= if MapSet.size(@selected_files) > 0 do %>
                  <span class="text-xs text-base-content/60">{MapSet.size(@selected_files)} selected</span>
                  <button class="btn btn-error btn-xs" phx-click="delete_selected" data-confirm={"Delete #{MapSet.size(@selected_files)} file(s)? This cannot be undone."}>Delete selected</button>
                <% end %>
              </div>

              <%!-- File listing --%>
              <div class="overflow-y-auto max-h-[50vh]">
                <%= cond do %>
                <% @loading_entries -> %>
                  <div class="flex items-center gap-2 p-4">
                    <span class="loading loading-spinner loading-sm"></span>
                    <span class="text-sm text-base-content/50">Loading files...</span>
                  </div>
                <% Enum.empty?(@visible) -> %>
                  <p class="text-base-content/50 italic text-sm">No video files match filters.</p>
                <% true -> %>
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
                      <%= for entry <- @visible do %>
                        <%= if entry.type == :dir do %>
                          <tr class="hover cursor-pointer">
                            <td>
                              <input
                                type="checkbox"
                                class="checkbox checkbox-xs checkbox-primary"
                                phx-click="toggle_select"
                                phx-value-file={entry.path}
                              />
                            </td>
                            <td class="font-mono text-sm" phx-click="navigate_dir" phx-value-path={entry.path}><span class="text-primary">📁</span> {entry.name}/</td>
                            <td phx-click="navigate_dir" phx-value-path={entry.path}></td>
                            <td phx-click="navigate_dir" phx-value-path={entry.path}></td>
                          </tr>
                        <% else %>
                          <tr class={[
                              "hover cursor-pointer",
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
                              class="font-mono text-sm truncate max-w-[300px]"
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
                            <td class="text-sm text-base-content/60 whitespace-nowrap" phx-click="select_file" phx-value-file={entry.path}>{entry.size_mb} MB</td>
                            <td class="text-xs font-mono text-base-content/50" phx-click="select_file" phx-value-file={entry.path}>
                              <%= if entry.metrics && !entry.metrics["error"] do %>
                                <span class="flex items-center gap-1" title={"brightness: #{entry.metrics["avg_brightness"] || "?"}/255, #{get_in(entry.metrics, ["bbox_areas", "count"]) || 0} bboxes, #{entry.metrics["duration_s"]}s"}>
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
            </div>
          </div>

      <% end %>

      <%!-- Annotations tab --%>
      <%= if @active_tab == "annotations" do %>
        <div class="card bg-base-200">
          <div class="card-body p-4">
            <h2 class="card-title text-lg">All Annotations</h2>

            <%!-- Search with autocomplete --%>
            <div class="relative">
              <form phx-change="search_annotations" class="mb-2">
                <input
                  type="text"
                  name="query"
                  value={@annotation_search}
                  placeholder="Search by filename or text..."
                  class="input input-sm input-bordered w-full"
                  phx-debounce="200"
                  autocomplete="off"
                />
              </form>
              <%= if @annotation_suggestions != [] do %>
                <ul class="absolute z-10 bg-base-100 shadow-lg rounded-box w-full max-h-48 overflow-y-auto border border-base-300">
                  <%= for sug <- @annotation_suggestions do %>
                    <li>
                      <button
                        class="w-full text-left px-3 py-1.5 hover:bg-base-200 text-sm flex items-center gap-2"
                        phx-click="pick_annotation_suggestion"
                        phx-value-value={sug.value}
                      >
                        <span class={"badge badge-xs #{if sug.type == "file", do: "badge-primary", else: "badge-ghost"}"}>{sug.type}</span>
                        <span class="truncate">{sug.value}</span>
                      </button>
                    </li>
                  <% end %>
                </ul>
              <% end %>
            </div>

            <%!-- Results grouped by file --%>
            <% grouped = Enum.group_by(@all_annotations, & &1.filename) %>
            <%= if map_size(grouped) == 0 do %>
              <p class="text-base-content/50 italic text-sm">No annotations found.</p>
            <% else %>
              <div class="space-y-4 overflow-y-auto max-h-[60vh]">
                <%= for {filename, anns} <- grouped do %>
                  <div>
                    <div class="flex items-center gap-2 mb-1">
                      <button class="font-mono text-sm font-bold link link-hover" phx-click="select_annotation_file" phx-value-filename={filename}>{filename}</button>
                      <span class="badge badge-sm">{length(anns)}</span>
                    </div>

                    <%!-- Timeline bar --%>
                    <% max_ts = anns |> Enum.map(fn a -> a.end_seconds || a.timestamp_seconds end) |> Enum.max(fn -> 1 end) %>
                    <% timeline_end = max(max_ts * 1.1, 1) %>
                    <div class="relative h-6 bg-base-300 rounded-full mb-2 overflow-hidden">
                      <%= for ann <- anns do %>
                        <% left_pct = ann.timestamp_seconds / timeline_end * 100 %>
                        <%= if ann.end_seconds do %>
                          <% width_pct = (ann.end_seconds - ann.timestamp_seconds) / timeline_end * 100 %>
                          <div
                            class="absolute top-0 h-full bg-primary/40 hover:bg-primary/60 cursor-pointer"
                            style={"left: #{left_pct}%; width: #{width_pct}%"}
                            title={"#{format_timestamp(ann.timestamp_seconds)}–#{format_timestamp(ann.end_seconds)}: #{ann.text}"}
                            phx-click="select_annotation_file" phx-value-filename={filename} onclick={"window._pendingSeek=#{ann.timestamp_seconds}"}
                          />
                        <% else %>
                          <div
                            class="absolute top-0 h-full w-1 bg-primary hover:bg-primary-focus cursor-pointer rounded-full"
                            style={"left: #{left_pct}%"}
                            title={"#{format_timestamp(ann.timestamp_seconds)}: #{ann.text}"}
                            phx-click="select_annotation_file" phx-value-filename={filename} onclick={"window._pendingSeek=#{ann.timestamp_seconds}"}
                          />
                        <% end %>
                      <% end %>
                      <%!-- Time labels --%>
                      <span class="absolute left-1 top-0.5 text-[9px] text-base-content/40">0:00</span>
                      <span class="absolute right-1 top-0.5 text-[9px] text-base-content/40">{format_timestamp(timeline_end)}</span>
                    </div>

                    <%!-- Annotation list --%>
                    <div class="space-y-0.5">
                      <%= for ann <- anns do %>
                        <%= if @editing_annotation == ann.id do %>
                          <form phx-submit="save_annotation" phx-value-id={ann.id} class="flex items-center gap-1 text-sm">
                            <input type="text" name="annotation[timestamp]" value={format_timestamp(ann.timestamp_seconds)} class="input input-xs input-bordered w-14 font-mono" />
                            <input type="text" name="annotation[end_timestamp]" value={if ann.end_seconds, do: format_timestamp(ann.end_seconds), else: ""} class="input input-xs input-bordered w-14 font-mono" placeholder="to" />
                            <input type="text" name="annotation[text]" value={ann.text} class="input input-xs input-bordered flex-1" />
                            <button type="submit" class="btn btn-xs btn-success">Save</button>
                            <button type="button" class="btn btn-xs btn-ghost" phx-click="cancel_edit_annotation">Cancel</button>
                          </form>
                        <% else %>
                          <% thumb_url = nearest_thumb_url(filename, ann.timestamp_seconds, @annotation_thumbs) %>
                          <div class="flex items-center gap-2 text-sm">
                            <button
                              class="shrink-0 cursor-pointer overflow-hidden rounded ann-thumb-trigger"
                              phx-click="select_annotation_file" phx-value-filename={filename}
                              onclick={"window._pendingSeek=#{ann.timestamp_seconds}"}
                            >
                              <%= if thumb_url do %>
                                <img src={thumb_url} class="w-12 h-8 object-cover" loading="lazy" data-full-thumb={thumb_url} />
                              <% else %>
                                <div class="w-12 h-8 bg-base-300 flex items-center justify-center">
                                  <.icon name="hero-film" class="size-3 text-base-content/30" />
                                </div>
                              <% end %>
                            </button>
                            <button class="font-mono text-xs text-base-content/60 w-20 shrink-0 text-left hover:text-primary cursor-pointer" phx-click="select_annotation_file" phx-value-filename={filename} onclick={"window._pendingSeek=#{ann.timestamp_seconds}"}>
                              {format_timestamp(ann.timestamp_seconds)}<%= if ann.end_seconds do %>–{format_timestamp(ann.end_seconds)}<% end %>
                            </button>
                            <button class="flex-1 text-left hover:text-primary cursor-pointer" phx-click="select_annotation_file" phx-value-filename={filename} onclick={"window._pendingSeek=#{ann.timestamp_seconds}"}>{ann.text}</button>
                            <%= if @active_project do %>
                              <button
                                class="btn btn-xs btn-ghost text-primary"
                                phx-click="add_annotation_to_project"
                                phx-value-id={ann.id}
                                title={"Add to '#{@active_project.name}'"}
                              >+ clip</button>
                            <% end %>
                            <button class="btn btn-xs btn-ghost" phx-click="edit_annotation" phx-value-id={ann.id}>Edit</button>
                            <button class="btn btn-xs btn-ghost text-error" phx-click="delete_annotation" phx-value-id={ann.id}>✕</button>
                          </div>
                        <% end %>
                      <% end %>
                    </div>
                  </div>
                <% end %>
              </div>
            <% end %>
          </div>
        </div>
      <% end %>

      <%!-- Preview --%>
      <div id="floating-preview-container" phx-hook="FloatingPreview" class="card bg-base-200 relative">
        <div class="card-body p-4">
          <div class="flex items-center justify-between mb-1">
            <h3 class="text-sm font-semibold">Preview</h3>
            <button
              class={"btn btn-xs btn-ghost gap-1 #{if @preview_floating, do: "btn-active"}"}
              phx-click="toggle_preview_floating"
              title={if @preview_floating, do: "Dock preview", else: "Float preview"}
            >
              <svg xmlns="http://www.w3.org/2000/svg" class="w-3.5 h-3.5" viewBox="0 0 20 20" fill="currentColor">
                <path d="M3 4a1 1 0 011-1h12a1 1 0 011 1v2a1 1 0 01-1 1H4a1 1 0 01-1-1V4zm0 6a1 1 0 011-1h6a1 1 0 011 1v6a1 1 0 01-1 1H4a1 1 0 01-1-1v-6z" />
              </svg>
              <%= if @preview_floating, do: "Dock", else: "Float" %>
            </button>
          </div>
          <div
            id="video-preview-hook"
            phx-hook="VideoPreview"
            phx-update="ignore"
          >
            <div class="flex items-center justify-center aspect-video bg-base-300 rounded-lg">
              <p class="text-base-content/40 text-sm">Select a video to preview</p>
            </div>
          </div>


          <%!-- Annotations --%>
          <%= if @selected_file do %>
            <% file_annotations = Map.get(cached_annotations_by_file(), Path.basename(@selected_file), []) %>
            <div class="mt-2 space-y-2">
              <h3 class="text-sm font-semibold">Annotations ({length(file_annotations)})</h3>

              <%= if file_annotations != [] do %>
                <div class="space-y-1">
                  <%= for ann <- file_annotations do %>
                    <%= if @editing_annotation == ann.id do %>
                      <form phx-submit="save_annotation" phx-value-id={ann.id} class="flex items-center gap-1 text-sm">
                        <input type="text" name="annotation[timestamp]" id={"ann-edit-from-#{ann.id}"} value={format_timestamp(ann.timestamp_seconds)} class="input input-xs input-bordered w-14 font-mono" />
                        <button type="button" class="btn btn-xs btn-ghost" title="Use current time" onclick={"var v=document.querySelector('#video-preview-hook video');if(v)document.getElementById('ann-edit-from-#{ann.id}').value=window._fmtTime(v.currentTime)"}>Now</button>
                        <input type="text" name="annotation[end_timestamp]" id={"ann-edit-to-#{ann.id}"} value={if ann.end_seconds, do: format_timestamp(ann.end_seconds), else: ""} class="input input-xs input-bordered w-14 font-mono" placeholder="to" />
                        <button type="button" class="btn btn-xs btn-ghost" title="Use current time" onclick={"var v=document.querySelector('#video-preview-hook video');if(v)document.getElementById('ann-edit-to-#{ann.id}').value=window._fmtTime(v.currentTime)"}>Now</button>
                        <input type="text" name="annotation[text]" value={ann.text} class="input input-xs input-bordered flex-1" />
                        <button type="submit" class="btn btn-xs btn-success">Save</button>
                        <button type="button" class="btn btn-xs btn-ghost" phx-click="cancel_edit_annotation">Cancel</button>
                      </form>
                    <% else %>
                      <div class="flex items-center gap-2 text-sm">
                        <button class="btn btn-xs btn-ghost font-mono" onclick={"var v=document.querySelector('#video-preview-hook video');if(v){v.currentTime=#{ann.timestamp_seconds};v.play()}"}>
                          {format_timestamp(ann.timestamp_seconds)}<%= if ann.end_seconds do %>–{format_timestamp(ann.end_seconds)}<% end %>
                        </button>
                        <button class="flex-1 text-left hover:text-primary cursor-pointer" onclick={"var v=document.querySelector('#video-preview-hook video');if(v){v.currentTime=#{ann.timestamp_seconds};v.play()}"}>
                          {ann.text}
                        </button>
                        <%= if @active_project do %>
                          <button
                            class="btn btn-xs btn-ghost text-primary"
                            phx-click="add_annotation_to_project"
                            phx-value-id={ann.id}
                            title={"Add to '#{@active_project.name}'"}
                          >+ clip</button>
                        <% end %>
                        <button class="btn btn-xs btn-ghost" phx-click="edit_annotation" phx-value-id={ann.id}>Edit</button>
                        <button class="btn btn-xs btn-ghost text-error" phx-click="delete_annotation" phx-value-id={ann.id}>✕</button>
                      </div>
                    <% end %>
                  <% end %>
                </div>
              <% end %>

              <%!-- Add annotation form --%>
              <form phx-submit="add_annotation" class="flex items-center gap-1">
                <input type="text" name="annotation[timestamp]" id="ann-from" placeholder="from" class="input input-xs input-bordered w-14 font-mono" />
                <button type="button" class="btn btn-xs btn-ghost" title="Use current time" onclick="var v=document.querySelector('#video-preview-hook video');if(v)document.getElementById('ann-from').value=window._fmtTime(v.currentTime)">Now</button>
                <input type="text" name="annotation[end_timestamp]" id="ann-to" placeholder="to" class="input input-xs input-bordered w-14 font-mono" />
                <button type="button" class="btn btn-xs btn-ghost" title="Use current time" onclick="var v=document.querySelector('#video-preview-hook video');if(v)document.getElementById('ann-to').value=window._fmtTime(v.currentTime)">Now</button>
                <input type="text" name="annotation[text]" placeholder="Add annotation..." class="input input-xs input-bordered flex-1" />
                <button type="submit" class="btn btn-xs btn-primary">Add</button>
              </form>
            </div>
          <% end %>
        </div>
      </div>

      <%!-- Processing + Queue --%>
      <div class="grid grid-cols-1 lg:grid-cols-2 gap-4">

        <%!-- Processing config --%>
          <div class="card bg-base-200">
            <div class="card-body p-4">
              <h2 class="card-title text-lg">Processing</h2>

              <div class="join flex-wrap">
                <button
                  :for={{key, profile} <- @profiles}
                  class={"join-item btn btn-sm #{if @selected_profile == key, do: "btn-primary", else: "btn-ghost"}"}
                  phx-click="select_profile"
                  phx-value-profile={key}
                >
                  {profile.label}
                </button>
              </div>
              <p class="text-xs text-base-content/50">{(@profiles[@selected_profile] || %{}).description}</p>

              <div class="space-y-2 mt-2">
                <form phx-change="set_min_bbox_area">
                  <label class="text-xs text-base-content/70">Min detection area</label>
                  <div class="flex items-center gap-2">
                    <input type="range" min="1000" max="100000" step="1000" value={@min_bbox_area} class="range range-xs range-primary flex-1" name="area" />
                    <span class="text-xs font-mono w-16">{@min_bbox_area}</span>
                  </div>
                  <span class="text-[10px] text-base-content/40">~{round(:math.sqrt(@min_bbox_area))}x{round(:math.sqrt(@min_bbox_area))} px</span>
                </form>

                <form phx-change="set_vlm_sample_pct">
                  <label class="text-xs text-base-content/70">VLM sample %</label>
                  <div class="flex items-center gap-2">
                    <input type="range" min="5" max="100" step="5" value={@vlm_sample_pct} class="range range-xs range-secondary flex-1" name="pct" />
                    <span class="text-xs font-mono w-10">{@vlm_sample_pct}%</span>
                  </div>
                </form>

                <form phx-change="set_ttl_days" class="flex items-center gap-2">
                  <label class="text-xs text-base-content/70">TTL</label>
                  <input type="number" min="1" max="365" value={@classification_ttl_days} class="input input-bordered input-xs w-16" name="days" />
                  <span class="text-xs text-base-content/40">days</span>
                </form>
              </div>

              <div class="flex items-center gap-3 mt-2">
                <label class="label cursor-pointer gap-1 p-0">
                  <span class="label-text text-xs">Fishial</span>
                  <input type="checkbox" class="toggle toggle-xs toggle-info" checked={@fishial_enabled} phx-click="toggle_fishial" disabled={not @fishial_ready} />
                </label>
                <label class="label cursor-pointer gap-1 p-0">
                  <span class="label-text text-xs">VLM</span>
                  <input type="checkbox" class="toggle toggle-xs toggle-secondary" checked={@vlm_enabled} phx-click="toggle_vlm" />
                </label>
                <span class="text-[10px] text-base-content/40">
                  <%= cond do %>
                    <% not @fishial_ready and @fishial_enabled -> %><span class="text-warning">Model not downloaded</span>
                    <% @fishial_enabled and @vlm_enabled -> %>Fishial + VLM fallback
                    <% @fishial_enabled -> %>Fishial only
                    <% @vlm_enabled -> %>VLM only
                    <% true -> %>No classification
                  <% end %>
                </span>
              </div>

              <%!-- VLM Context --%>
              <div class="mt-2">
                <div class="flex items-center gap-1">
                  <select class="select select-bordered select-xs flex-1" phx-change="select_context" name="id">
                    <option :for={ctx <- @vlm_contexts} value={ctx["id"]} selected={ctx["id"] == @selected_context_id}>{ctx["name"]}</option>
                  </select>
                  <button class="btn btn-ghost btn-xs" phx-click="edit_context" title="Edit">Edit</button>
                  <button class="btn btn-ghost btn-xs" phx-click="new_context" title="New">+</button>
                </div>
                <%= if @editing_context do %>
                  <div class="mt-1 space-y-1">
                    <input type="text" class="input input-bordered input-xs w-full" placeholder="Context name" value={@context_name} phx-blur="set_context_name" phx-keyup="set_context_name" phx-value-name="" name="name" phx-change="set_context_name" />
                    <textarea class="textarea textarea-bordered textarea-xs w-full" rows="2" placeholder="Location and species context..." phx-blur="edit_context_prompt" name="prompt" phx-change="edit_context_prompt">{@vlm_context_prompt}</textarea>
                    <div class="flex gap-1">
                      <button class="btn btn-primary btn-xs" phx-click="save_context">Save</button>
                      <button class="btn btn-ghost btn-xs" phx-click="cancel_edit_context">Cancel</button>
                      <%= if @selected_context_id do %>
                        <button class="btn btn-error btn-xs btn-outline ml-auto" phx-click="delete_context" data-confirm="Delete this context?">Delete</button>
                      <% end %>
                    </div>
                  </div>
                <% else %>
                  <p class="text-[10px] text-base-content/50 mt-1 line-clamp-2">{@vlm_context_prompt}</p>
                <% end %>
              </div>

              <% process_count = if MapSet.size(@selected_files) > 0, do: MapSet.size(@selected_files), else: if(@selected_file, do: 1, else: 0) %>
              <button
                class="btn btn-primary btn-sm mt-3"
                phx-click="start_processing"
                disabled={process_count == 0}
              >
                <%= if process_count > 1 do %>
                  Process {process_count} files
                <% else %>
                  Start Processing
                <% end %>
              </button>
            </div>
          </div>

          <%!-- Job queue --%>
          <div class="card bg-base-200">
            <div class="card-body p-4">
              <div class="flex items-center justify-between">
                <h2 class="card-title text-lg">Queue</h2>
                <button class="btn btn-ghost btn-xs text-warning" phx-click="clean_orphans" data-confirm="Remove all video records whose files no longer exist on disk?">Clean</button>
              </div>
              <div class="overflow-y-auto max-h-96">
                <%= if Enum.empty?(@jobs) do %>
                  <p class="text-base-content/50 italic text-sm">No jobs yet.</p>
                <% else %>
                  <div class="space-y-2">
                    <div :for={job <- @jobs} class="card card-compact bg-base-100">
                      <div class="card-body p-3">
                        <div class="flex items-center justify-between">
                          <span class="font-mono text-xs font-bold truncate">{job.filename}</span>
                          <div class="flex items-center gap-1">
                            <span class={["badge badge-xs",
                              job.status == "completed" && "badge-success",
                              job.status == "processing" && "badge-info",
                              job.status == "pending" && "badge-ghost",
                              job.status == "failed" && "badge-error"
                            ]}>{job.status}</span>
                            <%= if job.status in ["processing", "pending"] do %>
                              <button class="btn btn-ghost btn-xs text-warning" phx-click="cancel_job" phx-value-id={job.id}>Cancel</button>
                            <% end %>
                            <%= if job.status == "failed" do %>
                              <button class="btn btn-ghost btn-xs text-info" phx-click="retry_job" phx-value-id={job.id}>Retry</button>
                            <% end %>
                            <%= if job.status in ["completed", "failed"] do %>
                              <button class="btn btn-ghost btn-xs text-error" phx-click="delete_job" phx-value-id={job.id} data-confirm="Remove this job?">Del</button>
                            <% end %>
                          </div>
                        </div>
                        <%= if job.status == "processing" do %>
                          <progress class="progress progress-info w-full" value={job.progress_pct} max="100" />
                          <span class="text-xs text-base-content/50">{job.status_message || "#{job.progress_pct}%"}</span>
                        <% end %>
                        <%= if job.status == "completed" and job.status_message do %>
                          <span class="text-xs text-success">{job.status_message}</span>
                        <% end %>
                        <%= if job.status == "failed" and job.error_message do %>
                          <p class="text-xs text-error">{job.error_message}</p>
                        <% end %>
                        <div class="text-[10px] text-base-content/40 flex flex-wrap gap-x-2">
                          <span>{job.processing_profile}</span>
                          <%= if job.total_tracks do %>
                            <span>VLM: {job.vlm_classified_count || 0}/{job.vlm_qualified || 0} ({job.total_tracks} tracks)</span>
                          <% end %>
                          <span :if={job.fishial_enabled} class="badge badge-info badge-xs">Fish</span>
                          <span :if={Map.get(job, :vlm_enabled, true)} class="badge badge-secondary badge-xs">VLM</span>
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
