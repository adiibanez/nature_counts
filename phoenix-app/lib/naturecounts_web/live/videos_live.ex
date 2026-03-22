defmodule NaturecountsWeb.VideosLive do
  use NaturecountsWeb, :live_view

  alias Naturecounts.Repo
  alias Naturecounts.Offline.{Video, Profiles, ProcessVideoWorker}

  import Ecto.Query

  @refresh_interval 2000
  @videos_root "/videos"
  @video_extensions ~w(.mp4 .avi .mkv .mov .ts)

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: schedule_refresh()

    jobs = list_jobs()
    entries = list_dir(@videos_root)

    default_profile = Profiles.get("standard")

    {:ok,
     assign(socket,
       page_title: "Video Processing",
       current_dir: @videos_root,
       breadcrumbs: [],
       entries: entries,
       jobs: jobs,
       selected_file: nil,
       preview_url: nil,
       selected_profile: "standard",
       profiles: Profiles.all(),
       min_bbox_area: default_profile.min_bbox_area,
       vlm_sample_pct: default_profile.vlm_sample_pct,
       classification_ttl_days: Application.get_env(:naturecounts, :classification_ttl_days, 30)
     )}
  end

  @impl true
  def handle_info(:refresh, socket) do
    schedule_refresh()
    {:noreply, assign(socket, jobs: list_jobs())}
  end

  # --- Navigation events ---

  @impl true
  def handle_event("navigate_dir", %{"path" => path}, socket) do
    safe_path = safe_resolve(path)
    entries = list_dir(safe_path)
    breadcrumbs = build_breadcrumbs(safe_path)

    {:noreply,
     assign(socket,
       current_dir: safe_path,
       breadcrumbs: breadcrumbs,
       entries: entries,
       selected_file: nil,
       preview_url: nil
     )}
  end

  def handle_event("select_file", %{"file" => file}, socket) do
    relative = Path.relative_to(file, @videos_root)
    preview_url = "/serve/videos/#{relative}"
    {:noreply, assign(socket, selected_file: file, preview_url: preview_url)}
  end

  def handle_event("select_profile", %{"profile" => profile}, socket) do
    p = Profiles.get(profile)
    {:noreply, assign(socket, selected_profile: profile, min_bbox_area: p.min_bbox_area, vlm_sample_pct: p.vlm_sample_pct)}
  end

  def handle_event("set_min_bbox_area", %{"area" => area_str}, socket) do
    area = String.to_integer(area_str)
    {:noreply, assign(socket, min_bbox_area: area)}
  end

  def handle_event("set_vlm_sample_pct", %{"pct" => pct_str}, socket) do
    {:noreply, assign(socket, vlm_sample_pct: String.to_integer(pct_str))}
  end

  def handle_event("set_ttl_days", %{"days" => days_str}, socket) do
    days = String.to_integer(days_str)
    {:noreply, assign(socket, classification_ttl_days: days)}
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
          vlm_sample_pct: socket.assigns.vlm_sample_pct
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

  defp list_dir(dir) do
    case File.ls(dir) do
      {:ok, names} ->
        names
        |> Enum.sort()
        |> Enum.reduce({[], []}, fn name, {dirs, files} ->
          path = Path.join(dir, name)

          cond do
            File.dir?(path) and not String.starts_with?(name, ".") ->
              {dirs ++ [%{type: :dir, name: name, path: path}], files}

            video_file?(name) ->
              stat = File.stat!(path)
              size_mb = Float.round(stat.size / 1_048_576, 1)
              {dirs, files ++ [%{type: :file, name: name, path: path, size_mb: size_mb}]}

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
    <div class="p-4 max-w-7xl mx-auto">
      <h1 class="text-2xl font-bold mb-6">Video Processing</h1>

      <div class="grid grid-cols-1 lg:grid-cols-3 gap-6">
        <%!-- File browser --%>
        <div class="card bg-base-200">
          <div class="card-body">
            <h2 class="card-title text-lg">Browse Files</h2>

            <%!-- Breadcrumbs --%>
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

            <%!-- File listing --%>
            <div class="overflow-y-auto max-h-80">
              <%= if Enum.empty?(@entries) do %>
                <p class="text-base-content/50 italic text-sm">No video files in this directory.</p>
              <% else %>
                <table class="table table-sm">
                  <thead>
                    <tr>
                      <th>Name</th>
                      <th>Size</th>
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
                          <td class="font-mono text-sm">
                            <span class="text-primary">📁</span> {entry.name}/
                          </td>
                          <td></td>
                        </tr>
                      <% else %>
                        <tr
                          class={"hover cursor-pointer #{if @selected_file == entry.path, do: "bg-primary/20"}"}
                          phx-click="select_file"
                          phx-value-file={entry.path}
                        >
                          <td class="font-mono text-sm truncate max-w-[200px]" title={entry.name}>
                            {entry.name}
                          </td>
                          <td class="text-sm text-base-content/60 whitespace-nowrap">{entry.size_mb} MB</td>
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
              <div class="form-control flex-1">
                <label class="label py-0"><span class="label-text text-xs">Min detection area (px)</span></label>
                <div class="flex items-center gap-2">
                  <input
                    type="range"
                    min="1000"
                    max="100000"
                    step="1000"
                    value={@min_bbox_area}
                    class="range range-xs range-primary flex-1"
                    phx-change="set_min_bbox_area"
                    name="area"
                  />
                  <span class="text-xs font-mono w-16">{@min_bbox_area}</span>
                </div>
                <label class="label py-0">
                  <span class="label-text-alt text-base-content/40">
                    ~{round(:math.sqrt(@min_bbox_area))}x{round(:math.sqrt(@min_bbox_area))} px
                  </span>
                </label>
              </div>
              <div class="form-control flex-1">
                <label class="label py-0"><span class="label-text text-xs">VLM sample %</span></label>
                <div class="flex items-center gap-2">
                  <input
                    type="range"
                    min="5"
                    max="100"
                    step="5"
                    value={@vlm_sample_pct}
                    class="range range-xs range-secondary flex-1"
                    phx-change="set_vlm_sample_pct"
                    name="pct"
                  />
                  <span class="text-xs font-mono w-10">{@vlm_sample_pct}%</span>
                </div>
              </div>
              <div class="form-control">
                <label class="label py-0"><span class="label-text text-xs">TTL (days)</span></label>
                <input
                  type="number"
                  min="1"
                  max="365"
                  value={@classification_ttl_days}
                  class="input input-bordered input-sm w-20"
                  phx-change="set_ttl_days"
                  name="days"
                />
              </div>
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
            <%= if @preview_url do %>
              <div
                id={"video-container-#{:erlang.phash2(@selected_file)}"}
                phx-update="ignore"
                class="bg-black rounded-lg overflow-hidden"
              >
                <video
                  id={"video-preview-#{:erlang.phash2(@selected_file)}"}
                  src={@preview_url}
                  controls
                  autoplay
                  muted
                  class="w-full h-auto max-h-[50vh]"
                >
                  Your browser does not support video playback.
                </video>
              </div>
              <p class="text-xs text-base-content/60 font-mono mt-1 truncate" title={@selected_file}>
                {Path.basename(@selected_file)}
              </p>
            <% else %>
              <div class="flex items-center justify-center aspect-video bg-base-300 rounded-lg">
                <p class="text-base-content/40 text-sm">Select a video to preview</p>
              </div>
            <% end %>
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
