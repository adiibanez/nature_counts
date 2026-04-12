defmodule NaturecountsWeb.ProjectsLive do
  use NaturecountsWeb, :live_view

  alias Naturecounts.Clips

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     assign(socket,
       page_title: "Clip Projects",
       projects: Clips.list_projects(),
       creating: false,
       new_name: ""
     )}
  end

  @impl true
  def handle_event("toggle_create", _, socket) do
    {:noreply, assign(socket, creating: !socket.assigns.creating, new_name: "")}
  end

  def handle_event("create", %{"name" => name}, socket) do
    name = String.trim(name)

    if name == "" do
      {:noreply, socket}
    else
      case Clips.create_project(%{"name" => name}) do
        {:ok, project} ->
          {:noreply, push_navigate(socket, to: ~p"/projects/#{project.id}")}

        {:error, cs} ->
          {:noreply, put_flash(socket, :error, error_msg(cs))}
      end
    end
  end

  def handle_event("delete", %{"id" => id}, socket) do
    project = Clips.get_project!(String.to_integer(id))
    {:ok, _} = Clips.delete_project(project)
    {:noreply, assign(socket, projects: Clips.list_projects())}
  end

  defp error_msg(%Ecto.Changeset{errors: [{field, {msg, _}} | _]}), do: "#{field}: #{msg}"
  defp error_msg(_), do: "invalid"

  defp segment_count(project), do: length(project.segments || [])

  defp total_duration(project) do
    (project.segments || [])
    |> Enum.reduce(0.0, fn s, acc -> acc + (s.end_seconds - s.start_seconds) end)
  end

  defp fmt_duration(s) when s < 60, do: "#{:erlang.float_to_binary(s, decimals: 1)}s"
  defp fmt_duration(s) do
    m = trunc(s / 60)
    rem = s - m * 60
    "#{m}m #{:erlang.float_to_binary(rem, decimals: 0)}s"
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="p-6 max-w-5xl mx-auto">
      <div class="flex items-center justify-between mb-4">
        <h1 class="text-2xl font-bold">Clip Projects</h1>
        <button class="btn btn-primary btn-sm" phx-click="toggle_create">
          {if @creating, do: "Cancel", else: "+ New project"}
        </button>
      </div>

      <%= if @creating do %>
        <form phx-submit="create" class="flex gap-2 mb-4">
          <input
            name="name"
            value={@new_name}
            placeholder="Project name"
            class="input input-bordered input-sm flex-1"
            autofocus
          />
          <button type="submit" class="btn btn-sm btn-primary">Create</button>
        </form>
      <% end %>

      <%= if @projects == [] do %>
        <div class="text-center text-base-content/50 py-12">
          No projects yet. Create one to start collecting video segments.
        </div>
      <% else %>
        <table class="table table-sm">
          <thead>
            <tr>
              <th>Name</th>
              <th class="text-right">Segments</th>
              <th class="text-right">Duration</th>
              <th>Status</th>
              <th>Last render</th>
              <th></th>
            </tr>
          </thead>
          <tbody>
            <%= for project <- @projects do %>
              <tr class="hover">
                <td>
                  <.link navigate={~p"/projects/#{project.id}"} class="link link-hover font-medium">
                    {project.name}
                  </.link>
                </td>
                <td class="text-right font-mono text-xs">{segment_count(project)}</td>
                <td class="text-right font-mono text-xs">{fmt_duration(total_duration(project))}</td>
                <td>
                  <span class={"badge badge-sm " <> status_class(project.status)}>
                    {project.status}
                  </span>
                </td>
                <td class="text-xs text-base-content/60">
                  {if project.last_render_at, do: Calendar.strftime(project.last_render_at, "%Y-%m-%d %H:%M"), else: "—"}
                </td>
                <td class="text-right">
                  <button
                    phx-click="delete"
                    phx-value-id={project.id}
                    data-confirm={"Delete project \"#{project.name}\" and all its segments?"}
                    class="btn btn-ghost btn-xs text-error"
                  >
                    Delete
                  </button>
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
