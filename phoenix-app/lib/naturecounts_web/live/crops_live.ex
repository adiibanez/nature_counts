defmodule NaturecountsWeb.CropsLive do
  use NaturecountsWeb, :live_view

  @crops_dir "/videos/vlm_crops"

  @impl true
  def mount(_params, _session, socket) do
    {:ok, assign(socket, page_title: "VLM Crops", crops: list_crops())}
  end

  @impl true
  def handle_event("refresh", _params, socket) do
    {:noreply, assign(socket, crops: list_crops())}
  end

  @impl true
  def handle_event("delete_all", _params, socket) do
    File.rm_rf(@crops_dir)
    File.mkdir_p(@crops_dir)
    {:noreply, assign(socket, crops: [])}
  end

  defp list_crops do
    case File.ls(@crops_dir) do
      {:ok, files} ->
        files
        |> Enum.filter(&String.ends_with?(&1, ".jpg"))
        |> Enum.sort()
        |> Enum.map(fn name ->
          path = Path.join(@crops_dir, name)
          stat = File.stat!(path)
          %{
            name: name,
            url: "/debug/crops/#{name}",
            size_kb: Float.round(stat.size / 1024, 1),
            modified: stat.mtime
          }
        end)

      _ ->
        []
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="p-4 max-w-6xl mx-auto">
      <div class="flex items-center justify-between mb-6">
        <h1 class="text-2xl font-bold">VLM Crops ({length(@crops)})</h1>
        <div class="flex gap-2">
          <button class="btn btn-ghost btn-sm" phx-click="refresh">Refresh</button>
          <button class="btn btn-error btn-sm" phx-click="delete_all" data-confirm="Delete all crops?">
            Clear All
          </button>
        </div>
      </div>

      <%= if Enum.empty?(@crops) do %>
        <p class="text-base-content/50 italic">No crops yet. Process a video to generate them.</p>
      <% else %>
        <div class="grid grid-cols-2 md:grid-cols-3 lg:grid-cols-4 xl:grid-cols-5 gap-4">
          <div :for={crop <- @crops} class="card card-compact bg-base-200">
            <figure class="bg-black p-2">
              <img src={crop.url} alt={crop.name} class="max-h-48 object-contain" />
            </figure>
            <div class="card-body p-2">
              <p class="font-mono text-xs truncate" title={crop.name}>{crop.name}</p>
              <p class="text-xs text-base-content/50">{crop.size_kb} KB</p>
            </div>
          </div>
        </div>
      <% end %>
    </div>
    """
  end
end
