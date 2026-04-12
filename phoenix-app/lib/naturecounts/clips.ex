defmodule Naturecounts.Clips do
  @moduledoc """
  Context for clip projects: ordered collections of video segments
  fed to the render pipeline.
  """

  import Ecto.Query
  alias Naturecounts.Repo
  alias Naturecounts.Clips.{Project, Segment}

  ## Projects

  def list_projects do
    Project
    |> order_by(desc: :updated_at)
    |> preload(:segments)
    |> Repo.all()
  end

  def get_project!(id) do
    Project
    |> Repo.get!(id)
    |> Repo.preload(segments: from(s in Segment, order_by: s.position))
  end

  def get_project(id) do
    case Repo.get(Project, id) do
      nil -> nil
      project -> Repo.preload(project, segments: from(s in Segment, order_by: s.position))
    end
  end

  def create_project(attrs) do
    %Project{}
    |> Project.changeset(attrs)
    |> Repo.insert()
  end

  def update_project(%Project{} = project, attrs) do
    project
    |> Project.changeset(attrs)
    |> Repo.update()
  end

  def delete_project(%Project{} = project) do
    Repo.delete(project)
  end

  ## Segments

  @doc "Append a segment to a project; computes the next position."
  def add_segment(%Project{id: project_id}, attrs) do
    next = next_position(project_id)

    %Segment{}
    |> Segment.changeset(Map.merge(%{"position" => next, "project_id" => project_id}, stringify(attrs)))
    |> Repo.insert()
  end

  def update_segment(%Segment{} = segment, attrs) do
    segment
    |> Segment.changeset(attrs)
    |> Repo.update()
  end

  def delete_segment(%Segment{} = segment) do
    Repo.delete(segment)
  end

  def get_segment!(id), do: Repo.get!(Segment, id)

  @doc """
  Reorder segments within a project. `ordered_ids` is a list of segment ids
  in their new order. Positions are written sparsely (100, 200, 300, ...).
  """
  def reorder_segments(project_id, ordered_ids) when is_list(ordered_ids) do
    Repo.transaction(fn ->
      ordered_ids
      |> Enum.with_index(1)
      |> Enum.each(fn {id, idx} ->
        from(s in Segment, where: s.id == ^id and s.project_id == ^project_id)
        |> Repo.update_all(set: [position: idx * 100, updated_at: now()])
      end)
    end)
  end

  @doc "All segments belonging to a project that reference any of the given file paths."
  def segments_for_files(project_id, file_paths) when is_list(file_paths) do
    Segment
    |> where([s], s.project_id == ^project_id and s.file_path in ^file_paths)
    |> order_by([s], s.position)
    |> Repo.all()
  end

  defp next_position(project_id) do
    max =
      Segment
      |> where([s], s.project_id == ^project_id)
      |> select([s], max(s.position))
      |> Repo.one()

    case max do
      nil -> 100
      n -> n + 100
    end
  end

  defp stringify(map) when is_map(map) do
    Map.new(map, fn
      {k, v} when is_atom(k) -> {Atom.to_string(k), v}
      {k, v} -> {k, v}
    end)
  end

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:second)
end
