defmodule NaturecountsWeb.VideosLive do
  use NaturecountsWeb, :live_view

  alias Naturecounts.Repo
  alias Naturecounts.Offline.{Video, Profiles, ProcessVideoWorker, ScanMetricsWorker, VlmContexts}
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

    if connected?(socket), do: send(self(), {:load_dir, @videos_root})

    jobs = list_jobs()

    default_profile = Profiles.get("standard")

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
       scan_force: false,
       sort_by: "name",
       sort_dir: "asc",
       metric_filters: %{},
       show_metrics: false,
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
       bucket_test_result: nil
     )
     |> recompute_metrics()}
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
    # Reload entries to pick up new metrics from this batch
    Naturecounts.Cache.invalidate_group(:file_browser)
    processed_files = load_processed_files()
    entries =
      list_dir(socket.assigns.current_dir, processed_files)
      |> sort_entries(socket.assigns.sort_by, socket.assigns.sort_dir)

    # Check if any scan jobs are still running
    still_scanning = scan_running?()

    socket = assign(socket, entries: entries, processed_files: processed_files, scanning: still_scanning)
    socket = if not still_scanning, do: assign(socket, scan_progress: nil), else: socket

    {:noreply, recompute_metrics(socket)}
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
    scanning = if was_scanning, do: scan_running?(), else: false

    socket = assign(socket, jobs: list_jobs(), scanning: scanning)

    cond do
      # Scan just finished — reload entries to pick up new metrics
      was_scanning and not scanning ->
        Naturecounts.Cache.invalidate_group(:file_browser)
        processed_files = load_processed_files()
        entries =
          list_dir(socket.assigns.current_dir, processed_files)
          |> sort_entries(socket.assigns.sort_by, socket.assigns.sort_dir)

        {:noreply, assign(socket, entries: entries, processed_files: processed_files, scan_progress: nil) |> recompute_metrics()}

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
    case socket.assigns.source do
      "gcs" ->
        prefix = path
        send(self(), {:load_gcs, socket.assigns.selected_bucket, prefix})

        {:noreply,
         socket
         |> assign(
           gcs_prefix: prefix,
           entries: :loading,
           selected_file: nil,
           preview_url: nil,
           selected_files: MapSet.new()
         )
         |> recompute_metrics()
         |> push_event("preview", %{url: nil, filename: nil})}

      _ ->
        safe_path = safe_resolve(path)
        breadcrumbs = build_breadcrumbs(safe_path)
        send(self(), {:load_dir, safe_path})

        {:noreply,
         socket
         |> assign(
           current_dir: safe_path,
           breadcrumbs: breadcrumbs,
           entries: :loading,
           selected_file: nil,
           preview_url: nil,
           selected_files: MapSet.new()
         )
         |> recompute_metrics()
         |> push_event("preview", %{url: nil, filename: nil})}
    end
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
               |> assign(selected_file: file, preview_url: url)
               |> push_event("preview", %{url: url, filename: Path.basename(file)})}

            {:error, reason} ->
              {:noreply, put_flash(socket, :error, "GCS signed URL error: #{reason}")}
          end
        else
          {:noreply, put_flash(socket, :error, "No bucket selected")}
        end

      _ ->
        relative = Path.relative_to(file, @videos_root)
        preview_url = "/serve/videos/#{relative}"

        {:noreply,
         socket
         |> assign(selected_file: file, preview_url: preview_url)
         |> push_event("preview", %{url: preview_url, filename: Path.basename(file)})}
    end
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

  def handle_event("sort_files", %{"col" => col}, %{assigns: %{entries: :loading}} = socket) do
    {:noreply, assign(socket, sort_by: col, sort_dir: "asc")}
  end

  def handle_event("sort_files", %{"col" => col}, socket) do
    {sort_by, sort_dir} =
      if socket.assigns.sort_by == col do
        {col, if(socket.assigns.sort_dir == "asc", do: "desc", else: "asc")}
      else
        {col, "asc"}
      end

    entries = sort_entries(socket.assigns.entries, sort_by, sort_dir)
    {:noreply, assign(socket, sort_by: sort_by, sort_dir: sort_dir, entries: entries) |> recompute_metrics()}
  end

  def handle_event("scan_metrics", _params, socket) do
    %{
      "directory" => socket.assigns.current_dir,
      "force" => socket.assigns.scan_force,
      "sample_frames" => 20,
      "parallel" => true
    }
    |> ScanMetricsWorker.new()
    |> Oban.insert!()

    {:noreply, assign(socket, scanning: true)}
  end

  def handle_event("toggle_scan_force", _params, socket) do
    {:noreply, assign(socket, scan_force: !socket.assigns.scan_force)}
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
      gcs_attrs =
        case socket.assigns.source do
          "gcs" ->
            %{storage_backend: "gcs", gcs_bucket: socket.assigns.selected_bucket}

          _ ->
            %{storage_backend: "local"}
        end

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

  def handle_event("toggle_metrics", _params, socket) do
    {:noreply, assign(socket, show_metrics: !socket.assigns.show_metrics)}
  end

  def handle_event("set_metrics_view", %{"view" => view}, socket) do
    {:noreply, assign(socket, metrics_view: view, metrics_limit: 50) |> recompute_metrics()}
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

    min_val = parse_number(min_str)
    max_val = parse_number(max_str)

    filters =
      if min_val == nil and max_val == nil do
        Map.delete(filters, field)
      else
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

    {:noreply, assign(socket, metric_filters: filters, metrics_limit: 50) |> recompute_metrics()}
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
    tmp = System.tmp_dir!()

    # Read all batch progress files and aggregate
    progress_files =
      case File.ls(tmp) do
        {:ok, names} ->
          names
          |> Enum.filter(&String.starts_with?(&1, "scan_progress_"))
          |> Enum.map(&Path.join(tmp, &1))

        _ -> []
      end

    # Also check legacy single-worker file
    legacy = Path.join(tmp, "scan_progress.json")
    progress_files = if File.exists?(legacy), do: [legacy | progress_files], else: progress_files

    if progress_files == [] do
      nil
    else
      results = Enum.flat_map(progress_files, fn f ->
        case File.read(f) do
          {:ok, data} ->
            case Jason.decode(data) do
              {:ok, p} -> [p]
              _ -> []
            end
          _ -> []
        end
      end)

      if results == [] do
        nil
      else
        total_done = Enum.reduce(results, 0, fn p, acc -> acc + (p["done"] || 0) end)
        total_total = Enum.reduce(results, 0, fn p, acc -> acc + (p["total"] || 0) end)
        current = results |> Enum.max_by(fn p -> p["done"] || 0 end) |> Map.get("current", "")
        %{"done" => total_done, "total" => total_total, "current" => current}
      end
    end
  end

  defp scan_running? do
    import Ecto.Query

    Naturecounts.Cache.get_or_compute(:scan_running, fn ->
      Oban.Job
      |> where([j], j.worker == "Naturecounts.Offline.ScanMetricsWorker")
      |> where([j], j.state in ["available", "executing", "scheduled"])
      |> Repo.exists?()
    end, ttl: 2_000, group: :videos)
  end

  defp scan_active_count do
    import Ecto.Query

    Naturecounts.Cache.get_or_compute(:scan_active_count, fn ->
      Oban.Job
      |> where([j], j.worker == "Naturecounts.Offline.ScanMetricsWorker")
      |> where([j], j.state in ["available", "executing"])
      |> Repo.aggregate(:count)
    end, ttl: 2_000, group: :videos)
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
    Naturecounts.Cache.get_or_compute(:processed_files, fn ->
      Video
      |> where([v], v.status in ["completed", "processing", "pending"])
      |> select([v], {v.path, %{status: v.status, profile: v.processing_profile}})
      |> Repo.all()
      |> Map.new()
    end, ttl: 3_000, group: :videos)
  end

  defp list_dir(dir, processed_files) do
    base =
      Naturecounts.Cache.get_or_compute({:file_browser, dir}, fn ->
        list_dir_from_fs(dir)
      end, ttl: 10_000, group: :file_browser)

    Enum.map(base, fn
      %{type: :file, path: path} = entry ->
        %{entry | processed: Map.get(processed_files, path)}

      dir_entry ->
        dir_entry
    end)
  end

  defp list_dir_from_fs(dir) do
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
              m = Map.get(metrics, name)
              {dirs, files ++ [%{type: :file, name: name, path: path, size_mb: size_mb, processed: nil, metrics: m}]}

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
          scanned_only: [],
          loading_entries: true
        )

      entries ->
        visible = filtered_entries(entries, assigns.metric_filters)
        summary = compute_metrics_summary(visible)

        scanned_files = Enum.filter(visible, &(&1.type == :file and &1.metrics != nil and !&1.metrics["error"]))
        maxes = %{
          det: Enum.reduce(scanned_files, 0, fn f, acc -> max(acc, f.metrics["avg_detections_per_frame"] || 0) end),
          brightness: 255,
          contrast: Enum.reduce(scanned_files, 0, fn f, acc -> max(acc, f.metrics["contrast"] || 0) end),
          motion: Enum.reduce(scanned_files, 0, fn f, acc -> max(acc, f.metrics["motion_score"] || 0) end),
          bbox_mean: Enum.reduce(scanned_files, 0, fn f, acc -> max(acc, get_in(f.metrics, ["bbox_areas", "mean"]) || 0) end),
          duration: Enum.reduce(scanned_files, 0, fn f, acc -> max(acc, f.metrics["duration_s"] || 0) end)
        }

        scanned_only = Enum.filter(scanned_files, &(&1.metrics != nil))

        visible_files = Enum.filter(visible, &(&1.type == :file))
        total_visible = length(visible_files)
        metrics_page = Enum.take(visible, assigns.metrics_limit)
        has_more = total_visible > assigns.metrics_limit

        assign(socket,
          visible: visible,
          metrics_page: metrics_page,
          total_visible: total_visible,
          has_more_metrics: has_more,
          summary: summary,
          maxes: maxes,
          scanned_only: Enum.take(scanned_only, assigns.metrics_limit),
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

  defp compute_metrics_summary(entries) do
    scanned = Enum.filter(entries, &(&1.type == :file and &1.metrics != nil and !&1.metrics["error"]))
    count = length(scanned)

    if count == 0 do
      nil
    else
      metrics_list = Enum.map(scanned, & &1.metrics)

      %{
        count: count,
        total_duration: Enum.reduce(metrics_list, 0, &((&1["duration_s"] || 0) + &2)) |> Float.round(1),
        avg_det: (Enum.reduce(metrics_list, 0, &((&1["avg_detections_per_frame"] || 0) + &2)) / count) |> Float.round(1),
        avg_brightness: (Enum.reduce(metrics_list, 0, &((&1["avg_brightness"] || 0) + &2)) / count) |> Float.round(1),
        avg_contrast: (Enum.reduce(metrics_list, 0, &((&1["contrast"] || 0) + &2)) / count) |> Float.round(1),
        avg_motion: (Enum.reduce(metrics_list, 0, &((&1["motion_score"] || 0) + &2)) / count) |> Float.round(2),
        total_bbox: Enum.reduce(metrics_list, 0, &((get_in(&1, ["bbox_areas", "count"]) || 0) + &2))
      }
    end
  end

  defp bar_pct(_val, max) when max == 0 or max == nil, do: 0
  defp bar_pct(nil, _max), do: 0
  defp bar_pct(val, max), do: min(round(val / max * 100), 100)

  # Heatmap: returns an rgba background color string for a value in [0, max]
  defp heatmap_bg(_val, max, _hue) when max == 0 or max == nil, do: "background: transparent"
  defp heatmap_bg(nil, _max, _hue), do: "background: transparent"
  defp heatmap_bg(val, max, hue) do
    intensity = min(val / max, 1.0)
    alpha = Float.round(intensity * 0.6 + 0.05, 2)
    "background: hsla(#{hue}, 70%, 50%, #{alpha})"
  end

  # Radar chart: generates SVG points for a radar/spider chart
  defp radar_points(entry, maxes) do
    axes = [
      {metric_val(entry, "det"), maxes.det},
      {metric_val(entry, "brightness"), 255},
      {metric_val(entry, "contrast"), maxes.contrast},
      {metric_val(entry, "motion"), maxes.motion},
      {safe_bbox_mean(entry), maxes.bbox_mean}
    ]

    n = length(axes)

    axes
    |> Enum.with_index()
    |> Enum.map(fn {{val, max_v}, i} ->
      r = if max_v > 0 and val >= 0, do: min(val / max_v, 1.0) * 18, else: 0
      angle = 2 * :math.pi() * i / n - :math.pi() / 2
      x = 22 + r * :math.cos(angle)
      y = 22 + r * :math.sin(angle)
      "#{Float.round(x, 1)},#{Float.round(y, 1)}"
    end)
    |> Enum.join(" ")
  end

  defp radar_grid_points(ring, n) do
    Enum.map(0..(n - 1), fn i ->
      angle = 2 * :math.pi() * i / n - :math.pi() / 2
      x = 22 + ring * :math.cos(angle)
      y = 22 + ring * :math.sin(angle)
      "#{Float.round(x, 1)},#{Float.round(y, 1)}"
    end)
    |> Enum.join(" ")
  end

  defp safe_bbox_mean(%{metrics: nil}), do: 0
  defp safe_bbox_mean(%{metrics: m}), do: get_in(m, ["bbox_areas", "mean"]) || 0
  defp safe_bbox_mean(_), do: 0

  # Scatter: get normalized value for a metric key
  defp scatter_val(entry, key) do
    case key do
      "det" -> metric_val(entry, "det")
      "brightness" -> metric_val(entry, "brightness")
      "contrast" -> metric_val(entry, "contrast")
      "motion" -> metric_val(entry, "motion")
      "duration" -> metric_val(entry, "duration")
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
      "det" -> "Detections/frame"
      "brightness" -> "Brightness"
      "contrast" -> "Contrast"
      "motion" -> "Motion"
      "duration" -> "Duration (s)"
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
  defp sparkline_path(samples, key, width, height, max_val) do
    n = length(samples)
    if n < 2 or max_val == 0 do
      ""
    else
      samples
      |> Enum.with_index()
      |> Enum.map(fn {s, i} ->
        x = Float.round(i / max(n - 1, 1) * width, 1)
        val = Map.get(s, key, 0) || 0
        y = Float.round(height - val / max_val * height, 1)
        cmd = if i == 0, do: "M", else: "L"
        "#{cmd}#{x},#{y}"
      end)
      |> Enum.join(" ")
    end
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

  defp distribution_data(files, key) do
    vals =
      files
      |> Enum.map(&scatter_val(&1, key))
      |> Enum.filter(&(&1 >= 0))
      |> Enum.sort()

    case vals do
      [] -> nil
      _ ->
        n = length(vals)
        %{
          min: List.first(vals),
          q1: Enum.at(vals, div(n, 4)),
          median: Enum.at(vals, div(n, 2)),
          q3: Enum.at(vals, div(3 * n, 4)),
          max: List.last(vals)
        }
    end
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
    end, ttl: 2_000, group: :videos)
  end

  defp schedule_refresh do
    Process.send_after(self(), :refresh, @refresh_interval)
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="p-4 space-y-4">
      <div class="flex items-center justify-between">
        <h1 class="text-2xl font-bold">Video Processing</h1>
        <div class="flex items-center gap-1">
          <%= if @show_metrics do %>
            <div class="flex flex-col items-end gap-0.5 mr-2">
              <div class="join">
                <button :for={v <- [{"heatmap", "Heatmap"}, {"cards", "Cards"}, {"scatter", "Scatter"}, {"grouped", "Grouped"}, {"radar", "Radar"}]}
                  class={"join-item btn btn-xs #{if @metrics_view == elem(v, 0), do: "btn-active"}"}
                  phx-click="set_metrics_view" phx-value-view={elem(v, 0)}
                >
                  {elem(v, 1)}
                </button>
              </div>
              <div class="join">
                <button :for={v <- [{"timeline", "Timeline"}, {"temporal_scatter", "T-Scatter"}, {"temporal_heatmap", "T-Heatmap"}]}
                  class={"join-item btn btn-xs #{if @metrics_view == elem(v, 0), do: "btn-active"}"}
                  phx-click="set_metrics_view" phx-value-view={elem(v, 0)}
                >
                  {elem(v, 1)}
                </button>
              </div>
            </div>
          <% end %>
          <button
            class={"btn btn-sm #{if @show_metrics, do: "btn-primary", else: "btn-ghost"}"}
            phx-click="toggle_metrics"
          >
            Metrics
          </button>
        </div>
      </div>

      <%!-- Metrics dashboard --%>
      <%= if @show_metrics do %>
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
              <% end %>
            </div>

            <%!-- Range filters --%>
            <div class="grid grid-cols-2 md:grid-cols-3 lg:grid-cols-6 gap-2 mb-3">
              <form phx-change="set_metric_filter" class="form-control">
                <label class="label py-0"><span class="label-text text-xs">Detections/frame</span></label>
                <div class="flex gap-1">
                  <input type="hidden" name="field" value="avg_detections_per_frame" />
                  <input type="number" step="0.1" min="0" placeholder="min" name="min" value={elem(@metric_filters["avg_detections_per_frame"] || {nil, nil}, 0)} class="input input-bordered input-xs w-full" />
                  <input type="number" step="0.1" min="0" placeholder="max" name="max" value={elem(@metric_filters["avg_detections_per_frame"] || {nil, nil}, 1)} class="input input-bordered input-xs w-full" />
                </div>
              </form>
              <form phx-change="set_metric_filter" class="form-control">
                <label class="label py-0"><span class="label-text text-xs">Brightness (0-255)</span></label>
                <div class="flex gap-1">
                  <input type="hidden" name="field" value="avg_brightness" />
                  <input type="number" step="1" min="0" max="255" placeholder="min" name="min" value={elem(@metric_filters["avg_brightness"] || {nil, nil}, 0)} class="input input-bordered input-xs w-full" />
                  <input type="number" step="1" min="0" max="255" placeholder="max" name="max" value={elem(@metric_filters["avg_brightness"] || {nil, nil}, 1)} class="input input-bordered input-xs w-full" />
                </div>
              </form>
              <form phx-change="set_metric_filter" class="form-control">
                <label class="label py-0"><span class="label-text text-xs">Duration (s)</span></label>
                <div class="flex gap-1">
                  <input type="hidden" name="field" value="duration_s" />
                  <input type="number" step="1" min="0" placeholder="min" name="min" value={elem(@metric_filters["duration_s"] || {nil, nil}, 0)} class="input input-bordered input-xs w-full" />
                  <input type="number" step="1" min="0" placeholder="max" name="max" value={elem(@metric_filters["duration_s"] || {nil, nil}, 1)} class="input input-bordered input-xs w-full" />
                </div>
              </form>
              <form phx-change="set_metric_filter" class="form-control">
                <label class="label py-0"><span class="label-text text-xs">Contrast</span></label>
                <div class="flex gap-1">
                  <input type="hidden" name="field" value="contrast" />
                  <input type="number" step="0.1" min="0" placeholder="min" name="min" value={elem(@metric_filters["contrast"] || {nil, nil}, 0)} class="input input-bordered input-xs w-full" />
                  <input type="number" step="0.1" min="0" placeholder="max" name="max" value={elem(@metric_filters["contrast"] || {nil, nil}, 1)} class="input input-bordered input-xs w-full" />
                </div>
              </form>
              <form phx-change="set_metric_filter" class="form-control">
                <label class="label py-0"><span class="label-text text-xs">Motion</span></label>
                <div class="flex gap-1">
                  <input type="hidden" name="field" value="motion_score" />
                  <input type="number" step="0.1" min="0" placeholder="min" name="min" value={elem(@metric_filters["motion_score"] || {nil, nil}, 0)} class="input input-bordered input-xs w-full" />
                  <input type="number" step="0.1" min="0" placeholder="max" name="max" value={elem(@metric_filters["motion_score"] || {nil, nil}, 1)} class="input input-bordered input-xs w-full" />
                </div>
              </form>
              <form phx-change="set_metric_filter" class="form-control">
                <label class="label py-0"><span class="label-text text-xs">Bbox mean area</span></label>
                <div class="flex gap-1">
                  <input type="hidden" name="field" value="bbox_mean" />
                  <input type="number" step="1000" min="0" placeholder="min" name="min" value={elem(@metric_filters["bbox_mean"] || {nil, nil}, 0)} class="input input-bordered input-xs w-full" />
                  <input type="number" step="1000" min="0" placeholder="max" name="max" value={elem(@metric_filters["bbox_mean"] || {nil, nil}, 1)} class="input input-bordered input-xs w-full" />
                </div>
              </form>
            </div>

            <%!-- ═══════════════════════════════════════ --%>
            <%!-- VIEW 1: HEATMAP TABLE                  --%>
            <%!-- ═══════════════════════════════════════ --%>
            <%= if @metrics_view == "heatmap" do %>
              <div class="overflow-x-auto">
                <table class="table table-xs">
                  <thead>
                    <tr class="text-xs">
                      <th class="cursor-pointer select-none" phx-click="sort_files" phx-value-col="name">File {sort_indicator(@sort_by, @sort_dir, "name")}</th>
                      <th class="cursor-pointer select-none" phx-click="sort_files" phx-value-col="size">Size {sort_indicator(@sort_by, @sort_dir, "size")}</th>
                      <th class="cursor-pointer select-none" phx-click="sort_files" phx-value-col="duration">Dur {sort_indicator(@sort_by, @sort_dir, "duration")}</th>
                      <th class="cursor-pointer select-none" phx-click="sort_files" phx-value-col="det">Det/f {sort_indicator(@sort_by, @sort_dir, "det")}</th>
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
                        class={["hover cursor-pointer", @selected_file == entry.path && "ring-1 ring-primary"]}
                        phx-click="select_file" phx-value-file={entry.path}
                      >
                        <td class="font-mono text-xs truncate max-w-[180px]" title={entry.name}>
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
                        <td class="text-xs text-base-content/60">{entry.size_mb}MB</td>
                        <%= if entry.metrics && !entry.metrics["error"] do %>
                          <td class="text-xs font-mono">{entry.metrics["duration_s"]}s</td>
                          <td class="text-xs font-mono text-center rounded" style={heatmap_bg(entry.metrics["avg_detections_per_frame"], @maxes.det, 142)}>
                            {entry.metrics["avg_detections_per_frame"]}
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
                          <td colspan="7" class="text-xs text-base-content/30 italic">Not scanned</td>
                        <% end %>
                      </tr>
                    <% end %>
                  </tbody>
                </table>
              </div>
            <% end %>

            <%!-- ═══════════════════════════════════════ --%>
            <%!-- VIEW 2: CARD GRID                      --%>
            <%!-- ═══════════════════════════════════════ --%>
            <%= if @metrics_view == "cards" do %>
              <div class="grid grid-cols-2 md:grid-cols-3 lg:grid-cols-4 xl:grid-cols-5 gap-2 max-h-[500px] overflow-y-auto">
                <%= for entry <- @metrics_page, entry.type == :file do %>
                  <div
                    class={["card card-compact bg-base-100 cursor-pointer hover:shadow-md transition-shadow",
                      @selected_file == entry.path && "ring-2 ring-primary"]}
                    phx-click="select_file" phx-value-file={entry.path}
                  >
                    <div class="card-body p-3">
                      <div class="flex items-center gap-1 mb-1">
                        <%= if entry.processed do %>
                          <span class={["w-2 h-2 rounded-full shrink-0",
                            entry.processed.status == "completed" && profile_dot(entry.processed.profile),
                            entry.processed.status == "processing" && "bg-info animate-pulse",
                            entry.processed.status == "pending" && "bg-base-content/30"
                          ]} />
                        <% end %>
                        <span class="font-mono text-xs truncate" title={entry.name}>{entry.name}</span>
                      </div>
                      <div class="text-[10px] text-base-content/50">{entry.size_mb}MB</div>

                      <%= if entry.metrics && !entry.metrics["error"] do %>
                        <%!-- Micro bar chart fingerprint --%>
                        <div class="flex items-end gap-px h-8 mt-1">
                          <div class="flex-1 rounded-t" style={"height: #{bar_pct(entry.metrics["avg_detections_per_frame"], @maxes.det)}%; background: hsl(142, 70%, 50%); min-height: 2px"} title={"Det: #{entry.metrics["avg_detections_per_frame"]}"} />
                          <div class="flex-1 rounded-t" style={"height: #{bar_pct(entry.metrics["avg_brightness"], 255)}%; background: hsl(45, 70%, 50%); min-height: 2px"} title={"Bright: #{entry.metrics["avg_brightness"]}"} />
                          <div class="flex-1 rounded-t" style={"height: #{bar_pct(entry.metrics["contrast"], @maxes.contrast)}%; background: hsl(200, 70%, 50%); min-height: 2px"} title={"Contrast: #{entry.metrics["contrast"]}"} />
                          <div class="flex-1 rounded-t" style={"height: #{bar_pct(entry.metrics["motion_score"], @maxes.motion)}%; background: hsl(280, 70%, 50%); min-height: 2px"} title={"Motion: #{entry.metrics["motion_score"]}"} />
                          <div class="flex-1 rounded-t" style={"height: #{bar_pct(get_in(entry.metrics, ["bbox_areas", "mean"]), @maxes.bbox_mean)}%; background: hsl(30, 70%, 50%); min-height: 2px"} title={"Bbox: #{get_in(entry.metrics, ["bbox_areas", "mean"])}"} />
                        </div>
                        <div class="flex justify-between text-[9px] text-base-content/40 mt-0.5">
                          <span>Det</span><span>Bri</span><span>Con</span><span>Mot</span><span>Bbx</span>
                        </div>
                        <div class="flex gap-2 text-[10px] text-base-content/60 mt-1">
                          <span>{entry.metrics["duration_s"]}s</span>
                          <span>{entry.metrics["avg_detections_per_frame"]} det</span>
                        </div>
                      <% else %>
                        <div class="h-8 flex items-center justify-center">
                          <span class="text-[10px] text-base-content/30 italic">Not scanned</span>
                        </div>
                      <% end %>
                    </div>
                  </div>
                <% end %>
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
                      <option :for={k <- ["brightness", "det", "contrast", "motion", "duration", "bbox_mean", "size"]}
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
            <%!-- VIEW 4: GROUPED TABLE + DISTRIBUTIONS  --%>
            <%!-- ═══════════════════════════════════════ --%>
            <%= if @metrics_view == "grouped" do %>
              <div class="overflow-x-auto">
                <table class="table table-xs">
                  <thead>
                    <tr class="text-xs">
                      <th class="cursor-pointer select-none" phx-click="sort_files" phx-value-col="name">File {sort_indicator(@sort_by, @sort_dir, "name")}</th>
                      <th :for={{col, label} <- [{"det", "Det/f"}, {"brightness", "Bright"}, {"contrast", "Contrast"}, {"motion", "Motion"}, {"bbox_mean", "Bbox avg"}]}
                        class="cursor-pointer select-none" phx-click="sort_files" phx-value-col={col}
                      >
                        <div class="flex flex-col gap-1">
                          <span>{label} {sort_indicator(@sort_by, @sort_dir, col)}</span>
                          <%!-- Distribution strip --%>
                          <% dist = distribution_data(@scanned_only, col) %>
                          <%= if dist do %>
                            <% col_max = case col do
                              "brightness" -> 255
                              "det" -> @maxes.det
                              "contrast" -> @maxes.contrast
                              "motion" -> @maxes.motion
                              "bbox_mean" -> @maxes.bbox_mean
                              _ -> dist.max
                            end %>
                            <% col_max = if col_max == 0, do: 1, else: col_max %>
                            <svg viewBox="0 0 60 8" class="w-full h-2">
                              <rect x="0" y="3" width="60" height="2" rx="1" fill="currentColor" opacity="0.1" />
                              <rect
                                x={Float.round(dist.q1 / col_max * 60, 1)}
                                y="1" rx="1"
                                width={Float.round(max((dist.q3 - dist.q1) / col_max * 60, 1.0), 1)}
                                height="6"
                                fill="currentColor" opacity="0.2"
                              />
                              <line
                                x1={Float.round(dist.median / col_max * 60, 1)} y1="0"
                                x2={Float.round(dist.median / col_max * 60, 1)} y2="8"
                                stroke="currentColor" opacity="0.6" stroke-width="1.5"
                              />
                            </svg>
                          <% end %>
                        </div>
                      </th>
                    </tr>
                  </thead>
                  <tbody>
                    <%!-- Group: processed files --%>
                    <% {processed, unprocessed} = Enum.split_with(
                      Enum.filter(@metrics_page, &(&1.type == :file)),
                      &(&1.processed && &1.processed.status == "completed")
                    ) %>
                    <%= if length(processed) > 0 do %>
                      <tr><td colspan="6" class="text-xs font-bold text-success/80 bg-success/5 py-1">Processed ({length(processed)})</td></tr>
                      <%= for entry <- processed do %>
                        <tr class={["hover cursor-pointer", @selected_file == entry.path && "ring-1 ring-primary"]}
                          phx-click="select_file" phx-value-file={entry.path}>
                          <td class="font-mono text-xs truncate max-w-[180px]" title={entry.name}>
                            <span class="flex items-center gap-1">
                              <span class={["w-2 h-2 rounded-full shrink-0", profile_dot(entry.processed.profile)]} />
                              {entry.name}
                            </span>
                          </td>
                          <%= if entry.metrics && !entry.metrics["error"] do %>
                            <td class="text-xs font-mono">{entry.metrics["avg_detections_per_frame"]}</td>
                            <td class="text-xs font-mono">{entry.metrics["avg_brightness"] || "-"}</td>
                            <td class="text-xs font-mono">{entry.metrics["contrast"] || "-"}</td>
                            <td class="text-xs font-mono">{entry.metrics["motion_score"] || "-"}</td>
                            <td class="text-xs font-mono">{get_in(entry.metrics, ["bbox_areas", "mean"]) || 0}</td>
                          <% else %>
                            <td colspan="5" class="text-xs text-base-content/30 italic">Not scanned</td>
                          <% end %>
                        </tr>
                      <% end %>
                    <% end %>
                    <%= if length(unprocessed) > 0 do %>
                      <tr><td colspan="6" class="text-xs font-bold text-base-content/50 bg-base-300/30 py-1">Unprocessed ({length(unprocessed)})</td></tr>
                      <%= for entry <- unprocessed do %>
                        <tr class={["hover cursor-pointer", @selected_file == entry.path && "ring-1 ring-primary"]}
                          phx-click="select_file" phx-value-file={entry.path}>
                          <td class="font-mono text-xs truncate max-w-[180px]" title={entry.name}>
                            <span class="flex items-center gap-1">
                              <%= if entry.processed do %>
                                <span class={["w-2 h-2 rounded-full shrink-0",
                                  entry.processed.status == "processing" && "bg-info animate-pulse",
                                  entry.processed.status == "pending" && "bg-base-content/30"
                                ]} />
                              <% end %>
                              {entry.name}
                            </span>
                          </td>
                          <%= if entry.metrics && !entry.metrics["error"] do %>
                            <td class="text-xs font-mono">{entry.metrics["avg_detections_per_frame"]}</td>
                            <td class="text-xs font-mono">{entry.metrics["avg_brightness"] || "-"}</td>
                            <td class="text-xs font-mono">{entry.metrics["contrast"] || "-"}</td>
                            <td class="text-xs font-mono">{entry.metrics["motion_score"] || "-"}</td>
                            <td class="text-xs font-mono">{get_in(entry.metrics, ["bbox_areas", "mean"]) || 0}</td>
                          <% else %>
                            <td colspan="5" class="text-xs text-base-content/30 italic">Not scanned</td>
                          <% end %>
                        </tr>
                      <% end %>
                    <% end %>
                  </tbody>
                </table>
              </div>
            <% end %>

            <%!-- ═══════════════════════════════════════ --%>
            <%!-- VIEW 5: RADAR / SPIDER THUMBNAILS      --%>
            <%!-- ═══════════════════════════════════════ --%>
            <%= if @metrics_view == "radar" do %>
              <div class="overflow-x-auto">
                <%!-- Legend --%>
                <div class="flex gap-3 text-[10px] text-base-content/50 mb-2">
                  <span :for={{label, color} <- [{"Det", "hsl(142, 70%, 50%)"}, {"Bright", "hsl(45, 70%, 50%)"}, {"Contrast", "hsl(200, 70%, 50%)"}, {"Motion", "hsl(280, 70%, 50%)"}, {"Bbox", "hsl(30, 70%, 50%)"}]}>
                    <span class="inline-block w-2 h-2 rounded-full mr-0.5" style={"background: #{color}"} />{label}
                  </span>
                </div>
                <table class="table table-xs">
                  <thead>
                    <tr class="text-xs">
                      <th class="w-12">Shape</th>
                      <th class="cursor-pointer select-none" phx-click="sort_files" phx-value-col="name">File {sort_indicator(@sort_by, @sort_dir, "name")}</th>
                      <th class="cursor-pointer select-none" phx-click="sort_files" phx-value-col="size">Size {sort_indicator(@sort_by, @sort_dir, "size")}</th>
                      <th class="cursor-pointer select-none" phx-click="sort_files" phx-value-col="det">Det/f {sort_indicator(@sort_by, @sort_dir, "det")}</th>
                      <th class="cursor-pointer select-none" phx-click="sort_files" phx-value-col="brightness">Bright {sort_indicator(@sort_by, @sort_dir, "brightness")}</th>
                      <th class="cursor-pointer select-none" phx-click="sort_files" phx-value-col="contrast">Contrast {sort_indicator(@sort_by, @sort_dir, "contrast")}</th>
                      <th class="cursor-pointer select-none" phx-click="sort_files" phx-value-col="motion">Motion {sort_indicator(@sort_by, @sort_dir, "motion")}</th>
                      <th class="cursor-pointer select-none" phx-click="sort_files" phx-value-col="bbox_mean">Bbox avg {sort_indicator(@sort_by, @sort_dir, "bbox_mean")}</th>
                    </tr>
                  </thead>
                  <tbody>
                    <%= for entry <- @metrics_page, entry.type == :file do %>
                      <tr class={["hover cursor-pointer", @selected_file == entry.path && "ring-1 ring-primary"]}
                        phx-click="select_file" phx-value-file={entry.path}>
                        <td class="p-1">
                          <%= if entry.metrics && !entry.metrics["error"] do %>
                            <svg viewBox="0 0 44 44" class="w-10 h-10">
                              <%!-- Grid rings --%>
                              <polygon points={radar_grid_points(18, 5)} fill="none" stroke="currentColor" opacity="0.08" />
                              <polygon points={radar_grid_points(12, 5)} fill="none" stroke="currentColor" opacity="0.06" />
                              <polygon points={radar_grid_points(6, 5)} fill="none" stroke="currentColor" opacity="0.04" />
                              <%!-- Axes --%>
                              <line :for={i <- 0..4}
                                x1="22" y1="22"
                                x2={Float.round(22 + 18 * :math.cos(2 * :math.pi() * i / 5 - :math.pi() / 2), 1)}
                                y2={Float.round(22 + 18 * :math.sin(2 * :math.pi() * i / 5 - :math.pi() / 2), 1)}
                                stroke="currentColor" opacity="0.1"
                              />
                              <%!-- Data polygon --%>
                              <polygon
                                points={radar_points(entry, @maxes)}
                                fill="hsl(var(--s))" fill-opacity="0.3"
                                stroke="hsl(var(--s))" stroke-width="1.5"
                              />
                            </svg>
                          <% else %>
                            <div class="w-10 h-10 flex items-center justify-center text-base-content/20 text-lg">?</div>
                          <% end %>
                        </td>
                        <td class="font-mono text-xs truncate max-w-[160px]" title={entry.name}>
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
                        <td class="text-xs text-base-content/60">{entry.size_mb}MB</td>
                        <%= if entry.metrics && !entry.metrics["error"] do %>
                          <td class="text-xs font-mono">{entry.metrics["avg_detections_per_frame"]}</td>
                          <td class="text-xs font-mono">{entry.metrics["avg_brightness"] || "-"}</td>
                          <td class="text-xs font-mono">{entry.metrics["contrast"] || "-"}</td>
                          <td class="text-xs font-mono">{entry.metrics["motion_score"] || "-"}</td>
                          <td class="text-xs font-mono">{get_in(entry.metrics, ["bbox_areas", "mean"]) || 0}</td>
                        <% else %>
                          <td colspan="5" class="text-xs text-base-content/30 italic">Not scanned</td>
                        <% end %>
                      </tr>
                    <% end %>
                  </tbody>
                </table>
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
                </div>
                <div class="space-y-1">
                  <%= for entry <- @metrics_page, entry.type == :file do %>
                    <div
                      class={["flex items-center gap-2 p-1 rounded hover:bg-base-300/50 cursor-pointer",
                        @selected_file == entry.path && "ring-1 ring-primary bg-primary/10"]}
                      phx-click="select_file" phx-value-file={entry.path}
                    >
                      <div class="w-[140px] shrink-0">
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
                      <div class="flex-1 min-w-[200px]">
                        <%= if has_samples?(entry) do %>
                          <% samples = get_samples(entry) %>
                          <% n = length(samples) %>
                          <svg viewBox="0 0 200 30" class="w-full h-8" preserveAspectRatio="none">
                            <rect x="0" y="0" width="200" height="30" fill="currentColor" opacity="0.03" rx="2" />
                            <%!-- Detection bars (clickable) --%>
                            <%= for {s, i} <- Enum.with_index(samples) do %>
                              <% bar_w = max(200 / max(n, 1) - 1, 2) %>
                              <% bar_h = if det_max > 0, do: (s["det"] || 0) / det_max * 28, else: 0 %>
                              <rect
                                x={Float.round(i / max(n, 1) * 200, 1)}
                                y="0" width={Float.round(bar_w, 1)} height="30"
                                fill="transparent" class="cursor-pointer"
                                phx-click="seek_sample"
                                phx-value-file={entry.path}
                                phx-value-time={"#{s["t"] / 1}"}
                              >
                                <title>t={s["t"]}s det={s["det"]} — click to play</title>
                              </rect>
                              <rect
                                x={Float.round(i / max(n, 1) * 200, 1)}
                                y={Float.round(30 - bar_h, 1)}
                                width={Float.round(bar_w, 1)}
                                height={Float.round(max(bar_h, 0), 1)}
                                fill="hsl(142, 70%, 50%)" opacity="0.5" rx="1"
                                class="pointer-events-none"
                              />
                            <% end %>
                            <%!-- Brightness line --%>
                            <path d={sparkline_path(samples, "bright", 200, 30, bright_max)} fill="none" stroke="hsl(45, 80%, 55%)" stroke-width="1.5" opacity="0.7" class="pointer-events-none" />
                            <%!-- Motion line --%>
                            <path d={sparkline_path(samples, "motion", 200, 30, motion_max)} fill="none" stroke="hsl(280, 70%, 55%)" stroke-width="1" opacity="0.6" stroke-dasharray="3,2" class="pointer-events-none" />
                          </svg>
                        <% else %>
                          <div class="h-8 flex items-center justify-center">
                            <span class="text-[10px] text-base-content/20 italic">No temporal data</span>
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
                        @selected_file == entry.path && "ring-1 ring-primary"]}
                      phx-click="select_file" phx-value-file={entry.path}
                    >
                      <div class="w-[130px] shrink-0 pr-1">
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

      <div class="grid grid-cols-1 lg:grid-cols-3 gap-6">
        <%!-- File browser --%>
        <div class="card bg-base-200">
          <div class="card-body">
            <div class="flex items-center justify-between">
              <h2 class="card-title text-lg">Browse Files</h2>
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
                    <button
                      class="btn btn-xs btn-ghost opacity-50 hover:opacity-100 px-1"
                      phx-click="edit_bucket" phx-value-id={b["id"]}
                      title="Edit bucket config"
                    >e</button>
                    <button
                      class="btn btn-xs btn-ghost text-error opacity-50 hover:opacity-100 px-1"
                      phx-click="delete_bucket" phx-value-id={b["id"]}
                      data-confirm={"Delete bucket '#{b["name"]}'?"}
                    >x</button>
                  </div>
                <% end %>
                <button class="btn btn-xs btn-ghost" phx-click="toggle_add_bucket">+ Add Bucket</button>
              </div>

              <%= if @adding_bucket do %>
                <div class="bg-base-300 rounded-lg p-3 mt-1 space-y-2">
                  <div class="text-xs font-semibold">
                    <%= if @editing_bucket, do: "Edit Bucket", else: "Add GCS Bucket" %>
                  </div>
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
                          <%= if @editing_bucket do %>
                            <span class="text-base-content/40">(leave empty to keep existing)</span>
                          <% end %>
                        </span>
                      </label>
                      <textarea
                        name="credentials"
                        rows="4"
                        placeholder='{"type": "service_account", "project_id": "...", "private_key": "...", "client_email": "..."}'
                        class="textarea textarea-bordered textarea-xs font-mono text-[10px] leading-tight w-full"
                      >{@new_bucket_creds}</textarea>
                    </div>
                    <%!-- Test + Save buttons --%>
                    <div class="flex items-center gap-2">
                      <button type="submit" name="action" value="test" class="btn btn-xs btn-outline">Test Connection</button>
                      <button type="submit" name="action" value="save" class="btn btn-xs btn-primary">
                        <%= if @editing_bucket, do: "Update", else: "Save Bucket" %>
                      </button>
                      <button type="button" class="btn btn-xs btn-ghost" phx-click="toggle_add_bucket">Cancel</button>
                      <%= if @bucket_test_result do %>
                        <%= case @bucket_test_result do %>
                          <% :ok -> %>
                            <span class="badge badge-xs badge-success">Connected</span>
                          <% {:error, msg} -> %>
                            <span class="badge badge-xs badge-error" title={msg}>Failed: {msg}</span>
                        <% end %>
                      <% end %>
                    </div>
                  </form>
                </div>
              <% end %>
            <% end %>

            <%!-- Breadcrumbs + Scan --%>
            <div class="flex items-center justify-between">
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
                      <a class="link link-hover" phx-click="navigate_dir" phx-value-path={crumb.path}>
                        {crumb.name}
                      </a>
                    </li>
                  <% else %>
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
                  <% end %>
              </ul>
              </div>
              <div class="flex items-center gap-1">
                <%= if @scanning do %>
                  <span class="text-xs text-base-content/50">{scan_active_count()} workers</span>
                  <button
                    class="btn btn-error btn-xs gap-1"
                    phx-click="cancel_scan"
                  >
                    <span class="loading loading-spinner loading-xs"></span>
                    Cancel
                  </button>
                <% else %>
                  <label class="label cursor-pointer gap-1 p-0">
                    <span class="label-text text-[10px] text-base-content/50">Force</span>
                    <input
                      type="checkbox"
                      class="checkbox checkbox-xs"
                      checked={@scan_force}
                      phx-click="toggle_scan_force"
                    />
                  </label>
                  <button class="btn btn-ghost btn-xs" phx-click="scan_metrics">Scan</button>
                  <button
                    class="btn btn-ghost btn-xs"
                    phx-click="select_black_videos"
                    title="Select videos with 0 detections"
                  >
                    Select empty
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
            <div class="flex items-center justify-between">
              <h2 class="card-title text-lg">Processing Queue</h2>
              <button
                class="btn btn-ghost btn-xs text-warning"
                phx-click="clean_orphans"
                data-confirm="Remove all video records whose files no longer exist on disk?"
              >Clean orphans</button>
            </div>
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
