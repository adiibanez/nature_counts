defmodule NaturecountsWeb.InventoryLive do
  use NaturecountsWeb, :live_view

  alias Naturecounts.Repo
  alias Naturecounts.Offline.{Track, Video}

  import Ecto.Query

  @impl true
  def mount(_params, _session, socket) do
    species_summary = load_species_summary()
    recent_tracks = load_recent_tracks()
    stats = compute_stats()

    {:ok,
     assign(socket,
       page_title: "Biodiversity Inventory",
       species_summary: species_summary,
       recent_tracks: recent_tracks,
       stats: stats,
       filter_species: nil
     )}
  end

  @impl true
  def handle_event("filter_species", %{"species" => species}, socket) do
    filter = if species == "", do: nil, else: species
    tracks = load_recent_tracks(filter)
    {:noreply, assign(socket, filter_species: filter, recent_tracks: tracks)}
  end

  def handle_event("export_csv", _params, socket) do
    # TODO: implement CSV download
    {:noreply, put_flash(socket, :info, "CSV export coming soon")}
  end

  defp load_species_summary do
    Track
    |> where([t], t.vlm_classified == true and not is_nil(t.species))
    |> group_by([t], t.species)
    |> select([t], %{
      species: t.species,
      count: count(t.id),
      avg_confidence: avg(t.best_confidence),
      total_frames: sum(t.frame_count)
    })
    |> order_by([t], desc: count(t.id))
    |> Repo.all()
  end

  defp load_recent_tracks(species_filter \\ nil) do
    query =
      Track
      |> join(:inner, [t], v in Video, on: t.video_id == v.id)
      |> where([t], t.vlm_classified == true)
      |> order_by([t], desc: t.inserted_at)
      |> limit(50)
      |> select([t, v], %{
        id: t.id,
        track_id: t.track_id,
        species: t.species,
        scientific_name: t.scientific_name,
        species_confidence: t.species_confidence,
        best_confidence: t.best_confidence,
        best_bbox_area: t.best_bbox_area,
        frame_count: t.frame_count,
        vlm_reasoning: t.vlm_reasoning,
        video_filename: v.filename,
        has_thumbnail: not is_nil(t.thumbnail)
      })

    query =
      if species_filter,
        do: where(query, [t], t.species == ^species_filter),
        else: query

    query
    |> Repo.all()
    |> Enum.map(fn track ->
      crop_name = "#{track.video_filename}_track#{track.track_id}.jpg"
      crop_path = Path.join("/videos/vlm_crops", crop_name)
      Map.put(track, :crop_url, if(File.exists?(crop_path), do: "/debug/crops/#{crop_name}"))
    end)
  end

  defp compute_stats do
    total_tracks = Repo.aggregate(Track, :count, :id) || 0
    vlm_classified = Repo.one(from t in Track, where: t.vlm_classified == true, select: count()) || 0
    total_videos = Repo.one(from v in Video, where: v.status == "completed", select: count()) || 0
    unique_species =
      Repo.one(
        from t in Track,
          where: t.vlm_classified == true and t.species != "unidentified",
          select: count(t.species, :distinct)
      ) || 0

    %{
      total_tracks: total_tracks,
      vlm_classified: vlm_classified,
      total_videos: total_videos,
      unique_species: unique_species
    }
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="p-4 max-w-6xl mx-auto">
      <div class="flex items-center justify-between mb-6">
        <h1 class="text-2xl font-bold">Biodiversity Inventory</h1>
        <div class="flex gap-2">
          <.link navigate={~p"/"} class="btn btn-ghost btn-sm">Dashboard</.link>
          <.link navigate={~p"/videos"} class="btn btn-ghost btn-sm">Videos</.link>
          <button class="btn btn-outline btn-sm" phx-click="export_csv">Export CSV</button>
        </div>
      </div>

      <%!-- Stats --%>
      <div class="stats shadow mb-6 w-full">
        <div class="stat">
          <div class="stat-title">Videos Processed</div>
          <div class="stat-value text-primary">{@stats.total_videos}</div>
        </div>
        <div class="stat">
          <div class="stat-title">Total Tracks</div>
          <div class="stat-value">{@stats.total_tracks}</div>
        </div>
        <div class="stat">
          <div class="stat-title">VLM Classified</div>
          <div class="stat-value text-secondary">{@stats.vlm_classified}</div>
        </div>
        <div class="stat">
          <div class="stat-title">Unique Species</div>
          <div class="stat-value text-accent">{@stats.unique_species}</div>
        </div>
      </div>

      <div class="grid grid-cols-1 lg:grid-cols-3 gap-6">
        <%!-- Species summary --%>
        <div class="card bg-base-200">
          <div class="card-body">
            <h2 class="card-title text-lg">Species</h2>
            <%= if Enum.empty?(@species_summary) do %>
              <p class="text-base-content/50 italic">No species identified yet. Process some videos first.</p>
            <% else %>
              <div class="space-y-1">
                <button
                  class={"btn btn-ghost btn-sm btn-block justify-start #{if @filter_species == nil, do: "btn-active"}"}
                  phx-click="filter_species"
                  phx-value-species=""
                >
                  All species
                </button>
                <button
                  :for={s <- @species_summary}
                  class={"btn btn-ghost btn-sm btn-block justify-between #{if @filter_species == s.species, do: "btn-active"}"}
                  phx-click="filter_species"
                  phx-value-species={s.species}
                >
                  <span>{s.species}</span>
                  <span class="badge badge-sm">{s.count}</span>
                </button>
              </div>
            <% end %>
          </div>
        </div>

        <%!-- Track list --%>
        <div class="lg:col-span-2 card bg-base-200">
          <div class="card-body">
            <h2 class="card-title text-lg">
              Tracks
              <%= if @filter_species do %>
                <span class="badge badge-primary">{@filter_species}</span>
              <% end %>
            </h2>
            <%= if Enum.empty?(@recent_tracks) do %>
              <p class="text-base-content/50 italic">No classified tracks found.</p>
            <% else %>
              <div class="overflow-x-auto">
                <table class="table table-sm">
                  <thead>
                    <tr>
                      <th>Crop</th>
                      <th>Species</th>
                      <th>Confidence</th>
                      <th>Det. Score</th>
                      <th>Bbox Area</th>
                      <th>Frames</th>
                      <th>Video</th>
                    </tr>
                  </thead>
                  <tbody>
                    <tr :for={track <- @recent_tracks} class="hover">
                      <td>
                        <%= if track.crop_url do %>
                          <div class="relative group">
                            <img src={track.crop_url} class="h-12 rounded bg-black object-contain cursor-pointer" />
                            <div class="hidden group-hover:flex fixed inset-0 z-[100] items-center justify-center bg-black/60 pointer-events-none">
                              <img src={track.crop_url} class="max-h-[80vh] max-w-[80vw] object-contain rounded-lg shadow-2xl" />
                            </div>
                          </div>
                        <% else %>
                          <span class="text-xs text-base-content/30">—</span>
                        <% end %>
                      </td>
                      <td>
                        <div class="font-bold">{track.species || "unidentified"}</div>
                        <%= if track.scientific_name do %>
                          <div class="text-xs italic text-base-content/50">{track.scientific_name}</div>
                        <% end %>
                      </td>
                      <td>
                        <span class={[
                          "badge badge-xs",
                          track.species_confidence == "high" && "badge-success",
                          track.species_confidence == "medium" && "badge-warning",
                          track.species_confidence == "low" && "badge-ghost"
                        ]}>
                          {track.species_confidence}
                        </span>
                      </td>
                      <td class="font-mono text-xs">{Float.round(track.best_confidence || 0.0, 2)}</td>
                      <td class="font-mono text-xs">{track.best_bbox_area} px</td>
                      <td class="font-mono text-xs">{track.frame_count}</td>
                      <td class="text-xs text-base-content/60">{track.video_filename}</td>
                    </tr>
                  </tbody>
                </table>
              </div>
            <% end %>
          </div>
        </div>
      </div>
    </div>
    """
  end
end
