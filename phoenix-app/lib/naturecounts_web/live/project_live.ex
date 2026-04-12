defmodule NaturecountsWeb.ProjectLive do
  use NaturecountsWeb, :live_view

  alias Naturecounts.Clips
  alias Naturecounts.Clips.Segment

  @transitions Segment.transitions()

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    case Clips.get_project(String.to_integer(id)) do
      nil ->
        {:ok, push_navigate(socket, to: ~p"/projects")}

      project ->
        {:ok,
         assign(socket,
           page_title: "Project: #{project.name}",
           project: project,
           editing_name: false,
           name_input: project.name,
           selected_segment_id: nil,
           preview_url: nil
         )}
    end
  end

  @impl true
  def handle_event("toggle_edit_name", _, socket) do
    {:noreply, assign(socket, editing_name: !socket.assigns.editing_name, name_input: socket.assigns.project.name)}
  end

  def handle_event("save_name", %{"name" => name}, socket) do
    case Clips.update_project(socket.assigns.project, %{"name" => String.trim(name)}) do
      {:ok, project} ->
        {:noreply, assign(socket, project: reload(project), editing_name: false)}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "name required")}
    end
  end

  def handle_event("delete_segment", %{"id" => id}, socket) do
    seg = Clips.get_segment!(String.to_integer(id))
    {:ok, _} = Clips.delete_segment(seg)
    {:noreply, assign(socket, project: reload(socket.assigns.project))}
  end

  def handle_event("update_segment", %{"segment_id" => id} = params, socket) do
    seg = Clips.get_segment!(String.to_integer(id))

    attrs =
      params
      |> Map.take(["transition_in", "transition_duration_ms", "label", "start_seconds", "end_seconds"])
      |> coerce_numbers(["transition_duration_ms", "start_seconds", "end_seconds"])

    case Clips.update_segment(seg, attrs) do
      {:ok, _} -> {:noreply, assign(socket, project: reload(socket.assigns.project))}
      {:error, cs} -> {:noreply, put_flash(socket, :error, error_msg(cs))}
    end
  end

  def handle_event("move", %{"id" => id, "dir" => dir}, socket) do
    project = socket.assigns.project
    ids = Enum.map(project.segments, & &1.id)
    idx = Enum.find_index(ids, &(&1 == String.to_integer(id)))

    new_ids =
      cond do
        is_nil(idx) -> ids
        dir == "up" and idx > 0 -> swap(ids, idx, idx - 1)
        dir == "down" and idx < length(ids) - 1 -> swap(ids, idx, idx + 1)
        true -> ids
      end

    if new_ids != ids do
      Clips.reorder_segments(project.id, new_ids)
      {:noreply, assign(socket, project: reload(project))}
    else
      {:noreply, socket}
    end
  end

  def handle_event("select_segment", %{"id" => id}, socket) do
    seg = Enum.find(socket.assigns.project.segments, &(&1.id == String.to_integer(id)))

    preview_url =
      case seg do
        nil -> nil
        s -> "/serve/videos/#{Path.relative_to(s.file_path, "/videos")}#t=#{s.start_seconds},#{s.end_seconds}"
      end

    {:noreply, assign(socket, selected_segment_id: seg && seg.id, preview_url: preview_url)}
  end

  defp swap(list, i, j) do
    a = Enum.at(list, i)
    b = Enum.at(list, j)
    list |> List.replace_at(i, b) |> List.replace_at(j, a)
  end

  defp reload(project), do: Clips.get_project!(project.id)

  defp coerce_numbers(attrs, keys) do
    Enum.reduce(keys, attrs, fn k, acc ->
      case Map.get(acc, k) do
        nil -> acc
        "" -> Map.delete(acc, k)
        v when is_binary(v) ->
          case Float.parse(v) do
            {f, _} -> Map.put(acc, k, f)
            :error -> acc
          end
        _ -> acc
      end
    end)
  end

  defp error_msg(%Ecto.Changeset{errors: [{field, {msg, _}} | _]}), do: "#{field}: #{msg}"
  defp error_msg(_), do: "invalid"

  defp fmt_time(s) when is_number(s) do
    m = trunc(s / 60)
    sec = s - m * 60
    "#{m}:#{:io_lib.format("~5.2.0f", [sec])}"
  end
  defp fmt_time(_), do: "—"

  defp duration(seg), do: seg.end_seconds - seg.start_seconds

  defp total_duration(project) do
    Enum.reduce(project.segments, 0.0, fn s, acc -> acc + duration(s) end)
  end

  @impl true
  def render(assigns) do
    assigns = assign(assigns, transitions: @transitions)

    ~H"""
    <div class="p-6 max-w-6xl mx-auto">
      <div class="mb-4">
        <.link navigate={~p"/projects"} class="text-xs link link-hover">← All projects</.link>
      </div>

      <div class="flex items-center justify-between mb-2">
        <%= if @editing_name do %>
          <form phx-submit="save_name" class="flex gap-2 flex-1">
            <input
              name="name"
              value={@name_input}
              class="input input-bordered input-sm flex-1 max-w-md"
              autofocus
            />
            <button type="submit" class="btn btn-sm btn-primary">Save</button>
            <button type="button" phx-click="toggle_edit_name" class="btn btn-sm btn-ghost">Cancel</button>
          </form>
        <% else %>
          <h1 class="text-2xl font-bold">
            {@project.name}
            <button phx-click="toggle_edit_name" class="btn btn-ghost btn-xs ml-2">✎</button>
          </h1>
        <% end %>
        <span class={"badge " <> status_class(@project.status)}>{@project.status}</span>
      </div>

      <div class="text-sm text-base-content/60 mb-6">
        {length(@project.segments)} segment{if length(@project.segments) != 1, do: "s"}
        &middot; total {fmt_time(total_duration(@project))}
      </div>

      <%= if @preview_url do %>
        <div class="mb-4">
          <video src={@preview_url} controls autoplay class="max-h-64 rounded border border-base-300" />
        </div>
      <% end %>

      <%= if @project.segments == [] do %>
        <div class="text-center text-base-content/50 py-12 border border-dashed border-base-300 rounded">
          <p>No segments yet.</p>
          <p class="text-xs mt-2">
            Open
            <.link navigate={~p"/videos"} class="link link-primary">Offline videos</.link>,
            set this project as the active project, then add segments by dragging on a file's timeline or from annotations.
          </p>
        </div>
      <% else %>
        <table class="table table-sm">
          <thead>
            <tr>
              <th>#</th>
              <th>File</th>
              <th class="text-right">Start</th>
              <th class="text-right">End</th>
              <th class="text-right">Dur</th>
              <th>Transition in</th>
              <th>Label</th>
              <th></th>
            </tr>
          </thead>
          <tbody>
            <%= for {seg, idx} <- Enum.with_index(@project.segments) do %>
              <tr
                class={[
                  "hover cursor-pointer",
                  @selected_segment_id == seg.id && "bg-primary/10"
                ]}
                phx-click="select_segment"
                phx-value-id={seg.id}
              >
                <td class="font-mono">{idx + 1}</td>
                <td class="font-mono text-xs truncate max-w-[200px]" title={seg.file_path}>
                  {Path.basename(seg.file_path)}
                </td>
                <td class="font-mono text-xs text-right">{fmt_time(seg.start_seconds)}</td>
                <td class="font-mono text-xs text-right">{fmt_time(seg.end_seconds)}</td>
                <td class="font-mono text-xs text-right">{fmt_time(duration(seg))}</td>
                <td>
                  <form phx-change="update_segment" phx-click-away="" class="flex gap-1">
                    <input type="hidden" name="segment_id" value={seg.id} />
                    <select name="transition_in" class="select select-xs select-bordered">
                      <%= for t <- @transitions do %>
                        <option value={t} selected={t == seg.transition_in}>{t}</option>
                      <% end %>
                    </select>
                    <input
                      type="number"
                      name="transition_duration_ms"
                      value={seg.transition_duration_ms}
                      class="input input-xs input-bordered w-16"
                      disabled={seg.transition_in == "cut"}
                    />
                  </form>
                </td>
                <td>
                  <form phx-change="update_segment" class="m-0">
                    <input type="hidden" name="segment_id" value={seg.id} />
                    <input
                      type="text"
                      name="label"
                      value={seg.label || ""}
                      placeholder="—"
                      class="input input-xs input-bordered w-full"
                    />
                  </form>
                </td>
                <td class="text-right whitespace-nowrap">
                  <button
                    phx-click="move"
                    phx-value-id={seg.id}
                    phx-value-dir="up"
                    class="btn btn-ghost btn-xs"
                    disabled={idx == 0}
                  >↑</button>
                  <button
                    phx-click="move"
                    phx-value-id={seg.id}
                    phx-value-dir="down"
                    class="btn btn-ghost btn-xs"
                    disabled={idx == length(@project.segments) - 1}
                  >↓</button>
                  <button
                    phx-click="delete_segment"
                    phx-value-id={seg.id}
                    data-confirm="Delete this segment?"
                    class="btn btn-ghost btn-xs text-error"
                  >×</button>
                </td>
              </tr>
            <% end %>
          </tbody>
        </table>
      <% end %>
    </div>
    """
  end

  defp status_class("draft"), do: "badge-ghost"
  defp status_class("rendering"), do: "badge-info"
  defp status_class("rendered"), do: "badge-success"
  defp status_class("failed"), do: "badge-error"
  defp status_class(_), do: "badge-ghost"
end
