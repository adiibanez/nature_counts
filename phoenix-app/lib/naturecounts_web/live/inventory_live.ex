defmodule NaturecountsWeb.InventoryLive do
  use NaturecountsWeb, :live_view

  alias Naturecounts.Repo
  alias Naturecounts.Offline.{Track, Video}

  import Ecto.Query

  @default_limit 100

  @impl true
  def mount(_params, _session, socket) do
    socket =
      assign(socket,
        page_title: "Biodiversity Inventory",
        species_summary: [],
        recent_tracks: [],
        stats: %{total_tracks: 0, vlm_classified: 0, fishial_classified: 0, total_videos: 0, unique_species: 0, kept: 0, pending_review: 0},
        video_files: [],
        filter_species: nil,
        filter_review: nil,
        filter_file: nil,
        filter_source: nil,
        filter_age: nil,
        print_mode: false,
        loading: true
      )

    if connected?(socket) do
      send(self(), :load_data)
    end

    {:ok, socket}
  end

  @impl true
  def handle_info(:load_data, socket) do
    species_summary = load_species_summary()
    recent_tracks = load_recent_tracks(%{}, limit: @default_limit)
    stats = compute_stats()
    video_files = load_video_files()

    {:noreply,
     assign(socket,
       species_summary: species_summary,
       recent_tracks: recent_tracks,
       stats: stats,
       video_files: video_files,
       loading: false
     )}
  end

  defp filters(socket), do: Map.take(socket.assigns, [:filter_species, :filter_review, :filter_file, :filter_source, :filter_age])

  defp apply_filter(socket, key, value) do
    filter = if value == "", do: nil, else: value
    new_assigns = Map.put(filters(socket), key, filter)
    tracks = load_recent_tracks(new_assigns, limit: @default_limit)
    {:noreply, assign(socket, [{key, filter}, {:recent_tracks, tracks}])}
  end

  @impl true
  def handle_event("filter_species", %{"species" => species}, socket) do
    apply_filter(socket, :filter_species, species)
  end

  def handle_event("filter_review", %{"status" => status}, socket) do
    apply_filter(socket, :filter_review, status)
  end

  def handle_event("filter_file", %{"file" => file}, socket) do
    apply_filter(socket, :filter_file, file)
  end

  def handle_event("filter_source", %{"source" => source}, socket) do
    apply_filter(socket, :filter_source, source)
  end

  def handle_event("filter_age", %{"age" => age}, socket) do
    apply_filter(socket, :filter_age, age)
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

  def handle_event("print_mode", _params, socket) do
    tracks = load_recent_tracks(filters(socket), sort: :species, limit: nil)
    {:noreply, assign(socket, print_mode: true, recent_tracks: tracks)}
  end

  def handle_event("exit_print", _params, socket) do
    tracks = load_recent_tracks(filters(socket), limit: @default_limit)
    {:noreply, assign(socket, print_mode: false, recent_tracks: tracks)}
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

    Naturecounts.Cache.invalidate_group(:inventory)
  end

  defp reload(socket) do
    tracks = load_recent_tracks(filters(socket), limit: @default_limit)
    stats = compute_stats()
    species_summary = load_species_summary()
    {:noreply, assign(socket, recent_tracks: tracks, stats: stats, species_summary: species_summary)}
  end

  defp format_confidence(nil), do: "-"
  defp format_confidence(%Decimal{} = d), do: d |> Decimal.round(2) |> Decimal.to_string()
  defp format_confidence(f) when is_float(f), do: Float.round(f, 2) |> to_string()

  defp load_species_summary do
    Naturecounts.Cache.get_or_compute(:species_summary, fn ->
      Track
      |> where([t], (t.vlm_classified == true or not is_nil(t.classifier_source)) and not is_nil(t.species) and t.species != "unidentified")
      |> group_by([t], t.species)
      |> select([t], %{
        species: t.species,
        count: count(t.id),
        avg_confidence: avg(t.best_confidence),
        total_frames: sum(t.frame_count)
      })
      |> order_by([t], desc: count(t.id))
      |> Repo.all()
    end, ttl: 30_000, group: :inventory)
  end

  defp load_recent_tracks(filter_map \\ %{}, opts \\ []) do
    species_filter = filter_map[:filter_species]
    review_filter = filter_map[:filter_review]
    file_filter = filter_map[:filter_file]
    source_filter = filter_map[:filter_source]
    age_filter = filter_map[:filter_age]

    max_rows = Keyword.get(opts, :limit, @default_limit)
    sort = Keyword.get(opts, :sort, :recent)

    query =
      Track
      |> join(:inner, [t], v in Video, on: t.video_id == v.id)
      |> where([t], t.vlm_classified == true or not is_nil(t.classifier_source))
      |> select([t, v], %{
        id: t.id, track_id: t.track_id, species: t.species,
        scientific_name: t.scientific_name, species_confidence: t.species_confidence,
        best_confidence: t.best_confidence, best_bbox_area: t.best_bbox_area,
        frame_count: t.frame_count, vlm_reasoning: t.vlm_reasoning,
        video_filename: v.filename, has_thumbnail: not is_nil(t.thumbnail),
        thumbnail: t.thumbnail, review_status: t.review_status,
        reviewed_at: t.reviewed_at, expires_at: t.expires_at,
        classifier_source: t.classifier_source, inserted_at: t.inserted_at
      })

    query =
      case sort do
        :species -> order_by(query, [t], [asc: t.species, desc: t.best_confidence])
        :recent -> order_by(query, [t], desc: t.inserted_at)
      end

    query = if max_rows, do: limit(query, ^max_rows), else: query

    query = if species_filter, do: where(query, [t], t.species == ^species_filter), else: query
    query = if review_filter, do: where(query, [t], t.review_status == ^review_filter), else: query
    query = if file_filter, do: where(query, [t, v], v.filename == ^file_filter), else: query

    query =
      if source_filter do
        case source_filter do
          "fishial" -> where(query, [t], t.classifier_source == "fishial")
          "vlm" -> where(query, [t], t.classifier_source == "vlm" or (is_nil(t.classifier_source) and t.vlm_classified == true))
        end
      else
        query
      end

    query =
      if age_filter do
        cutoff = age_cutoff(age_filter)
        if cutoff, do: where(query, [t], t.inserted_at >= ^cutoff), else: query
      else
        query
      end

    query
    |> Repo.all()
    |> Enum.map(fn track ->
      crop_name = "#{track.video_filename}_track#{track.track_id}.jpg"
      crop_path = Path.join("/videos/vlm_crops", crop_name)
      crop_url = if File.exists?(crop_path), do: "/debug/crops/#{crop_name}"

      image_url =
        cond do
          crop_url -> crop_url
          track.thumbnail -> "data:image/jpeg;base64,#{Base.encode64(track.thumbnail)}"
          true -> nil
        end

      track
      |> Map.put(:crop_url, image_url)
      |> Map.delete(:thumbnail)
    end)
  end

  defp age_cutoff("1h"), do: NaiveDateTime.add(NaiveDateTime.utc_now(), -3600)
  defp age_cutoff("24h"), do: NaiveDateTime.add(NaiveDateTime.utc_now(), -86400)
  defp age_cutoff("7d"), do: NaiveDateTime.add(NaiveDateTime.utc_now(), -7 * 86400)
  defp age_cutoff("30d"), do: NaiveDateTime.add(NaiveDateTime.utc_now(), -30 * 86400)
  defp age_cutoff(_), do: nil

  defp load_video_files do
    Naturecounts.Cache.get_or_compute(:video_files, fn ->
      Video
      |> where([v], v.status == "completed")
      |> select([v], v.filename)
      |> order_by([v], desc: v.inserted_at)
      |> Repo.all()
    end, ttl: 30_000, group: :inventory)
  end

  defp compute_stats do
    Naturecounts.Cache.get_or_compute(:inventory_stats, fn ->
      track_stats =
        Repo.one(
          from t in Track,
            select: %{
              total_tracks: count(t.id),
              vlm_classified: count(fragment("CASE WHEN ? = true OR ? IS NOT NULL THEN 1 END", t.vlm_classified, t.classifier_source)),
              fishial_classified: count(fragment("CASE WHEN ? = 'fishial' THEN 1 END", t.classifier_source)),
              unique_species: fragment(
                "COUNT(DISTINCT CASE WHEN (? = true OR ? IS NOT NULL) AND ? != 'unidentified' AND ? != 'discarded' THEN ? END)",
                t.vlm_classified, t.classifier_source, t.species, t.review_status, t.species
              ),
              kept: count(fragment("CASE WHEN ? = 'kept' THEN 1 END", t.review_status)),
              pending_review: count(fragment("CASE WHEN (? = true OR ? IS NOT NULL) AND ? = 'pending' THEN 1 END", t.vlm_classified, t.classifier_source, t.review_status))
            }
        )

      total_videos = Repo.one(from v in Video, where: v.status == "completed", select: count()) || 0

      Map.put(track_stats, :total_videos, total_videos)
    end, ttl: 30_000, group: :inventory)
  end

  @impl true
  def render(assigns) do
    if assigns.print_mode do
      render_print(assigns)
    else
      render_normal(assigns)
    end
  end

  defp render_print(assigns) do
    ~H"""
    <div id="print-view" class="p-6 max-w-[210mm] mx-auto" phx-hook="PrintMode">
      <div class="no-print mb-4 flex items-center gap-2">
        <button class="btn btn-sm btn-ghost" phx-click="exit_print">Back to inventory</button>
        <button class="btn btn-sm btn-primary" onclick="window.print()">Print / Save PDF</button>
        <span class="text-sm text-base-content/50">{length(@recent_tracks)} classifications</span>
      </div>

      <div class="print-header text-center mb-6">
        <h1 class="text-2xl font-bold">Biodiversity Inventory</h1>
        <p class="text-sm text-base-content/60">
          Generated {Calendar.strftime(NaiveDateTime.utc_now(), "%Y-%m-%d")}
          <%= if @filter_species do %>
            | Species: {@filter_species}
          <% end %>
          <%= if @filter_review do %>
            | Review: {@filter_review}
          <% end %>
        </p>
      </div>

      <%!-- Summary table --%>
      <div class="mb-6">
        <h2 class="text-lg font-semibold mb-2">Species Summary</h2>
        <table class="table table-xs w-full">
          <thead>
            <tr>
              <th>Species</th>
              <th class="text-right">Count</th>
              <th class="text-right">Avg Confidence</th>
              <th class="text-right">Total Frames</th>
            </tr>
          </thead>
          <tbody>
            <tr :for={s <- @species_summary}>
              <td class="font-medium">{s.species}</td>
              <td class="text-right">{s.count}</td>
              <td class="text-right">{format_confidence(s.avg_confidence)}</td>
              <td class="text-right">{s.total_frames}</td>
            </tr>
          </tbody>
        </table>
      </div>

      <%!-- Classification grid --%>
      <h2 class="text-lg font-semibold mb-2">All Classifications</h2>
      <div class="print-grid">
        <div
          :for={track <- @recent_tracks}
          class="print-card"
        >
          <div class="print-thumb">
            <%= if track.crop_url do %>
              <img src={track.crop_url} />
            <% else %>
              <div class="print-no-thumb">No image</div>
            <% end %>
          </div>
          <div class="print-info">
            <div class="font-bold text-sm">{track.species || "unidentified"}</div>
            <%= if track.scientific_name do %>
              <div class="text-xs italic text-base-content/60">{track.scientific_name}</div>
            <% end %>
            <div class="text-xs mt-1">
              Confidence: {track.species_confidence}
              ({Float.round(track.best_confidence || 0.0, 2)})
            </div>
            <%= if track.vlm_reasoning do %>
              <div class="text-xs text-base-content/50 mt-1 print-reasoning">{track.vlm_reasoning}</div>
            <% end %>
            <div class="text-xs text-base-content/40 mt-1">
              {track.video_filename} | {track.frame_count} frames
              | {track.review_status}
            </div>
          </div>
        </div>
      </div>
    </div>
    """
  end

  defp render_normal(assigns) do
    ~H"""
    <div class="p-4">
      <div class="flex items-center justify-between mb-6">
        <h1 class="text-2xl font-bold">Biodiversity Inventory</h1>
        <%= if @loading do %>
          <span class="loading loading-spinner loading-md"></span>
        <% end %>
        <div class="flex gap-2">
          <button class="btn btn-outline btn-sm" phx-click="print_mode">Print</button>
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
          <div class="stat-title">Classified</div>
          <div class="stat-value text-secondary">{@stats.vlm_classified}</div>
          <div class="stat-desc">{@stats.fishial_classified} Fishial / {max(@stats.vlm_classified - @stats.fishial_classified, 0)} VLM</div>
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
        <%!-- Filters + Species summary --%>
        <div class="card bg-base-200">
          <div class="card-body">
            <h2 class="card-title text-lg">Filters</h2>

            <div class="text-xs font-semibold text-base-content/60 mt-1">Video file</div>
            <form phx-change="filter_file">
              <select
                class="select select-xs select-bordered w-full"
                name="file"
              >
                <option value="" selected={@filter_file == nil}>All files</option>
                <option
                  :for={f <- @video_files}
                  value={f}
                  selected={@filter_file == f}
                >{f}</option>
              </select>
            </form>

            <div class="text-xs font-semibold text-base-content/60 mt-2">Classifier</div>
            <div class="join w-full">
              <button
                class={"join-item btn btn-xs flex-1 #{if @filter_source == nil, do: "btn-active"}"}
                phx-click="filter_source"
                phx-value-source=""
              >All</button>
              <button
                class={"join-item btn btn-xs flex-1 #{if @filter_source == "fishial", do: "btn-info"}"}
                phx-click="filter_source"
                phx-value-source="fishial"
              >Fishial</button>
              <button
                class={"join-item btn btn-xs flex-1 #{if @filter_source == "vlm", do: "btn-secondary"}"}
                phx-click="filter_source"
                phx-value-source="vlm"
              >VLM</button>
            </div>

            <div class="text-xs font-semibold text-base-content/60 mt-2">Classification age</div>
            <div class="join w-full">
              <button
                class={"join-item btn btn-xs flex-1 #{if @filter_age == nil, do: "btn-active"}"}
                phx-click="filter_age"
                phx-value-age=""
              >All</button>
              <button
                class={"join-item btn btn-xs flex-1 #{if @filter_age == "1h", do: "btn-active"}"}
                phx-click="filter_age"
                phx-value-age="1h"
              >1h</button>
              <button
                class={"join-item btn btn-xs flex-1 #{if @filter_age == "24h", do: "btn-active"}"}
                phx-click="filter_age"
                phx-value-age="24h"
              >24h</button>
              <button
                class={"join-item btn btn-xs flex-1 #{if @filter_age == "7d", do: "btn-active"}"}
                phx-click="filter_age"
                phx-value-age="7d"
              >7d</button>
              <button
                class={"join-item btn btn-xs flex-1 #{if @filter_age == "30d", do: "btn-active"}"}
                phx-click="filter_age"
                phx-value-age="30d"
              >30d</button>
            </div>

            <div class="text-xs font-semibold text-base-content/60 mt-2">Review status</div>
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

            <div class="divider my-1 text-xs">Species</div>
            <%= if Enum.empty?(@species_summary) do %>
              <p class="text-base-content/50 italic">No species identified yet.</p>
            <% else %>
              <div class="space-y-1 overflow-y-auto max-h-[40vh]">
                <button
                  class={"btn btn-ghost btn-sm btn-block justify-between #{if @filter_species == nil, do: "btn-active"}"}
                  phx-click="filter_species"
                  phx-value-species=""
                >
                  <span>All species</span>
                  <span class="badge badge-sm">{Enum.reduce(@species_summary, 0, &(&1.count + &2))}</span>
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
            <h2 class="card-title text-lg flex flex-wrap gap-1">
              Tracks
              <span class="text-sm text-base-content/50">({length(@recent_tracks)})</span>
              <%= if @filter_species do %>
                <span class="badge badge-primary badge-sm">{@filter_species}</span>
              <% end %>
              <%= if @filter_source do %>
                <span class="badge badge-info badge-sm">{@filter_source}</span>
              <% end %>
              <%= if @filter_age do %>
                <span class="badge badge-sm">{@filter_age}</span>
              <% end %>
              <%= if @filter_file do %>
                <span class="badge badge-sm badge-outline truncate max-w-[150px]" title={@filter_file}>{@filter_file}</span>
              <% end %>
            </h2>
            <%= if Enum.empty?(@recent_tracks) do %>
              <p class="text-base-content/50 italic">No classified tracks found.</p>
            <% else %>
              <div class="grid grid-cols-1 md:grid-cols-2 gap-2 overflow-y-auto max-h-[70vh]">
                <div
                  :for={track <- @recent_tracks}
                  class={[
                    "card card-compact bg-base-100",
                    track.review_status == "kept" && "ring-1 ring-success",
                    track.review_status == "discarded" && "opacity-40"
                  ]}
                >
                  <%!-- Crop thumbnail --%>
                  <figure class="bg-black h-32">
                    <%= if track.crop_url do %>
                      <div class="relative group w-full h-full" phx-hook="CropZoom" id={"crop-#{track.id}"}>
                        <img
                          src={track.crop_url}
                          class="w-full h-full object-contain cursor-zoom-in"
                        />
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
                          <span class={[
                            "badge badge-xs badge-outline",
                            track.classifier_source == "fishial" && "badge-info",
                            track.classifier_source == "vlm" && "badge-secondary"
                          ]}>
                            {track.classifier_source || "vlm"}
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
