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
       filter_species: nil,
       filter_review: nil
     )}
  end

  @impl true
  def handle_event("filter_species", %{"species" => species}, socket) do
    filter = if species == "", do: nil, else: species
    tracks = load_recent_tracks(filter, socket.assigns.filter_review)
    {:noreply, assign(socket, filter_species: filter, recent_tracks: tracks)}
  end

  def handle_event("filter_review", %{"status" => status}, socket) do
    filter = if status == "", do: nil, else: status
    tracks = load_recent_tracks(socket.assigns.filter_species, filter)
    {:noreply, assign(socket, filter_review: filter, recent_tracks: tracks)}
  end

  def handle_event("keep_track", %{"id" => id}, socket) do
    set_review_status(id, "kept")
    reload(socket)
  end

  def handle_event("discard_track", %{"id" => id}, socket) do
    set_review_status(id, "discarded")
    reload(socket)
  end

  def handle_event("reset_track", %{"id" => id}, socket) do
    set_review_status(id, "pending")
    reload(socket)
  end

  def handle_event("export_csv", _params, socket) do
    {:noreply, put_flash(socket, :info, "CSV export coming soon")}
  end

  defp set_review_status(id, status) do
    track = Repo.get!(Track, id)
    now = NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)

    changes =
      case status do
        "kept" -> %{review_status: "kept", reviewed_at: now, expires_at: nil}
        "discarded" -> %{review_status: "discarded", reviewed_at: now}
        "pending" -> %{review_status: "pending", reviewed_at: nil}
      end

    track
    |> Ecto.Changeset.change(changes)
    |> Repo.update!()
  end

  defp reload(socket) do
    tracks = load_recent_tracks(socket.assigns.filter_species, socket.assigns.filter_review)
    stats = compute_stats()
    species_summary = load_species_summary()
    {:noreply, assign(socket, recent_tracks: tracks, stats: stats, species_summary: species_summary)}
  end

  defp load_species_summary do
    Track
    |> where([t], t.vlm_classified == true and not is_nil(t.species))
    |> where([t], t.review_status != "discarded")
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

  defp load_recent_tracks(species_filter \\ nil, review_filter \\ nil) do
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
        has_thumbnail: not is_nil(t.thumbnail),
        review_status: t.review_status,
        reviewed_at: t.reviewed_at,
        expires_at: t.expires_at
      })

    query =
      if species_filter,
        do: where(query, [t], t.species == ^species_filter),
        else: query

    query =
      if review_filter,
        do: where(query, [t], t.review_status == ^review_filter),
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
          where: t.vlm_classified == true and t.species != "unidentified" and t.review_status != "discarded",
          select: count(t.species, :distinct)
      ) || 0

    kept = Repo.one(from t in Track, where: t.review_status == "kept", select: count()) || 0
    pending_review = Repo.one(from t in Track, where: t.vlm_classified == true and t.review_status == "pending", select: count()) || 0

    %{
      total_tracks: total_tracks,
      vlm_classified: vlm_classified,
      total_videos: total_videos,
      unique_species: unique_species,
      kept: kept,
      pending_review: pending_review
    }
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="p-4 max-w-6xl mx-auto">
      <div class="flex items-center justify-between mb-6">
        <h1 class="text-2xl font-bold">Biodiversity Inventory</h1>
        <button class="btn btn-outline btn-sm" phx-click="export_csv">Export CSV</button>
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
        <div class="stat">
          <div class="stat-title">Kept</div>
          <div class="stat-value text-success">{@stats.kept}</div>
        </div>
        <div class="stat">
          <div class="stat-title">Pending Review</div>
          <div class="stat-value text-warning">{@stats.pending_review}</div>
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

            <div class="divider my-1 text-xs">Review filter</div>
            <div class="join w-full">
              <button
                class={"join-item btn btn-xs flex-1 #{if @filter_review == nil, do: "btn-active"}"}
                phx-click="filter_review"
                phx-value-status=""
              >All</button>
              <button
                class={"join-item btn btn-xs flex-1 #{if @filter_review == "pending", do: "btn-warning"}"}
                phx-click="filter_review"
                phx-value-status="pending"
              >Pending</button>
              <button
                class={"join-item btn btn-xs flex-1 #{if @filter_review == "kept", do: "btn-success"}"}
                phx-click="filter_review"
                phx-value-status="kept"
              >Kept</button>
              <button
                class={"join-item btn btn-xs flex-1 #{if @filter_review == "discarded", do: "btn-error"}"}
                phx-click="filter_review"
                phx-value-status="discarded"
              >Discarded</button>
            </div>
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
              <div class="space-y-2 overflow-y-auto max-h-[70vh]">
                <div
                  :for={track <- @recent_tracks}
                  class={[
                    "card card-compact card-side bg-base-100",
                    track.review_status == "kept" && "ring-1 ring-success",
                    track.review_status == "discarded" && "opacity-40"
                  ]}
                >
                  <%!-- Crop thumbnail --%>
                  <figure class="shrink-0 w-24 bg-black">
                    <%= if track.crop_url do %>
                      <div class="relative group w-full h-full">
                        <img src={track.crop_url} class="w-full h-full object-contain cursor-pointer" />
                        <div class="hidden group-hover:flex fixed inset-0 z-[100] items-center justify-center bg-black/60 pointer-events-none">
                          <img src={track.crop_url} class="max-h-[80vh] max-w-[80vw] object-contain rounded-lg shadow-2xl" />
                        </div>
                      </div>
                    <% else %>
                      <div class="flex items-center justify-center w-full h-full text-base-content/20 text-xs">
                        No crop
                      </div>
                    <% end %>
                  </figure>

                  <div class="card-body p-3">
                    <%!-- Top row: species + stats --%>
                    <div class="flex items-start justify-between gap-2">
                      <div class="min-w-0">
                        <div class="flex items-center gap-2">
                          <span class="font-bold text-sm">{track.species || "unidentified"}</span>
                          <span class={[
                            "badge badge-xs",
                            track.species_confidence == "high" && "badge-success",
                            track.species_confidence == "medium" && "badge-warning",
                            track.species_confidence == "low" && "badge-ghost"
                          ]}>
                            {track.species_confidence}
                          </span>
                        </div>
                        <%= if track.scientific_name do %>
                          <div class="text-xs italic text-base-content/50">{track.scientific_name}</div>
                        <% end %>
                      </div>
                      <div class="flex items-center gap-2 shrink-0 text-xs text-base-content/50 font-mono">
                        <span>{Float.round(track.best_confidence || 0.0, 2)}</span>
                        <span>{track.best_bbox_area}px</span>
                      </div>
                    </div>

                    <%!-- Reasoning --%>
                    <%= if track.vlm_reasoning do %>
                      <p class="text-xs text-base-content/50 line-clamp-2" title={track.vlm_reasoning}>
                        {track.vlm_reasoning}
                      </p>
                    <% end %>

                    <%!-- Bottom row: video name + review actions --%>
                    <div class="flex items-center justify-between mt-auto">
                      <span class="text-xs text-base-content/40 truncate max-w-[150px]" title={track.video_filename}>
                        {track.video_filename}
                      </span>
                      <div class="flex items-center gap-1">
                        <%= case track.review_status do %>
                          <% "pending" -> %>
                            <button
                              class="btn btn-success btn-xs"
                              phx-click="keep_track"
                              phx-value-id={track.id}
                            >Keep</button>
                            <button
                              class="btn btn-error btn-xs btn-outline"
                              phx-click="discard_track"
                              phx-value-id={track.id}
                            >Discard</button>
                          <% "kept" -> %>
                            <span class="badge badge-success badge-sm">Kept</span>
                            <button class="btn btn-ghost btn-xs" phx-click="reset_track" phx-value-id={track.id}>Undo</button>
                          <% "discarded" -> %>
                            <span class="badge badge-error badge-sm">Discarded</span>
                            <button class="btn btn-ghost btn-xs" phx-click="reset_track" phx-value-id={track.id}>Undo</button>
                          <% _ -> %>
                        <% end %>
                        <%= if track.expires_at do %>
                          <span class="text-xs text-base-content/30" title={"Expires #{Calendar.strftime(track.expires_at, "%Y-%m-%d")}"}>
                            ⏳
                          </span>
                        <% end %>
                      </div>
                    </div>
                  </div>
                </div>
              </div>
            <% end %>
          </div>
        </div>
      </div>
    </div>
    """
  end
end
