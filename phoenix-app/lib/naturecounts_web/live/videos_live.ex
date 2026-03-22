defmodule NaturecountsWeb.VideosLive do
  use NaturecountsWeb, :live_view

  alias Naturecounts.Repo
  alias Naturecounts.Offline.{Video, Profiles, ProcessVideoWorker}

  import Ecto.Query

  @refresh_interval 2000

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: schedule_refresh()

    videos_dir = "/videos"
    available_files = list_video_files(videos_dir)
    jobs = list_jobs()

    {:ok,
     assign(socket,
       page_title: "Video Processing",
       available_files: available_files,
       jobs: jobs,
       selected_file: nil,
       selected_profile: "standard",
       profiles: Profiles.all()
     )}
  end

  @impl true
  def handle_info(:refresh, socket) do
    schedule_refresh()
    {:noreply, assign(socket, jobs: list_jobs())}
  end

  @impl true
  def handle_event("select_file", %{"file" => file}, socket) do
    {:noreply, assign(socket, selected_file: file)}
  end

  def handle_event("select_profile", %{"profile" => profile}, socket) do
    {:noreply, assign(socket, selected_profile: profile)}
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
          processing_profile: profile
        })
        |> Repo.insert!()

      %{video_id: video.id}
      |> ProcessVideoWorker.new()
      |> Oban.insert!()

      {:noreply,
       socket
       |> assign(selected_file: nil, jobs: list_jobs())
       |> put_flash(:info, "Processing started for #{Path.basename(file)}")}
    else
      {:noreply, put_flash(socket, :error, "No file selected")}
    end
  end

  def handle_event("cancel_job", %{"id" => id}, socket) do
    video = Repo.get!(Video, id)

    # Cancel the Oban job if still queued or running
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

    # Cancel any active Oban job first
    Oban.Job
    |> where([j], j.args == ^%{"video_id" => video.id})
    |> where([j], j.state in ["available", "executing", "scheduled", "retryable"])
    |> Repo.all()
    |> Enum.each(&Oban.cancel_job(&1.id))

    Repo.delete!(video)
    {:noreply, assign(socket, jobs: list_jobs())}
  end

  defp list_video_files(dir) do
    case File.ls(dir) do
      {:ok, files} ->
        files
        |> Enum.filter(fn f ->
          ext = Path.extname(f) |> String.downcase()
          ext in ~w(.mp4 .avi .mkv .mov .ts)
        end)
        |> Enum.sort()
        |> Enum.map(fn f ->
          path = Path.join(dir, f)
          stat = File.stat!(path)
          size_mb = Float.round(stat.size / 1_048_576, 1)
          %{name: f, path: path, size_mb: size_mb}
        end)

      _ ->
        []
    end
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
    <div class="p-4 max-w-6xl mx-auto">
      <div class="flex items-center justify-between mb-6">
        <h1 class="text-2xl font-bold">Video Processing</h1>
        <div class="flex gap-2">
          <.link navigate={~p"/"} class="btn btn-ghost btn-sm">Dashboard</.link>
          <.link navigate={~p"/inventory"} class="btn btn-ghost btn-sm">Inventory</.link>
        </div>
      </div>

      <div class="grid grid-cols-1 lg:grid-cols-2 gap-6">
        <%!-- File selector --%>
        <div class="card bg-base-200">
          <div class="card-body">
            <h2 class="card-title text-lg">Select Video</h2>
            <div class="overflow-y-auto max-h-64">
              <table class="table table-sm">
                <thead>
                  <tr>
                    <th>File</th>
                    <th>Size</th>
                    <th></th>
                  </tr>
                </thead>
                <tbody>
                  <tr
                    :for={file <- @available_files}
                    class={"hover cursor-pointer #{if @selected_file == file.path, do: "bg-primary/20"}"}
                    phx-click="select_file"
                    phx-value-file={file.path}
                  >
                    <td class="font-mono text-sm">{file.name}</td>
                    <td class="text-sm text-base-content/60">{file.size_mb} MB</td>
                    <td>
                      <%= if @selected_file == file.path do %>
                        <span class="badge badge-primary badge-xs">selected</span>
                      <% end %>
                    </td>
                  </tr>
                </tbody>
              </table>
            </div>

            <%!-- Profile selector --%>
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

            <button
              class="btn btn-primary mt-2"
              phx-click="start_processing"
              disabled={@selected_file == nil}
            >
              Start Processing
            </button>
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
                      <div class="text-xs text-base-content/40">
                        Profile: {job.processing_profile}
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
