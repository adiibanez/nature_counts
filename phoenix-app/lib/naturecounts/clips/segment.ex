defmodule Naturecounts.Clips.Segment do
  use Ecto.Schema
  import Ecto.Changeset

  alias Naturecounts.Clips.Project

  @transitions ~w(cut crossfade fade_black)

  schema "clip_segments" do
    belongs_to :project, Project
    field :file_path, :string
    field :start_seconds, :float
    field :end_seconds, :float
    field :position, :integer
    field :transition_in, :string, default: "cut"
    field :transition_duration_ms, :integer, default: 500
    field :label, :string
    field :source_annotation_id, :id

    timestamps()
  end

  def changeset(segment, attrs) do
    segment
    |> cast(attrs, [
      :project_id,
      :file_path,
      :start_seconds,
      :end_seconds,
      :position,
      :transition_in,
      :transition_duration_ms,
      :label,
      :source_annotation_id
    ])
    |> validate_required([:project_id, :file_path, :start_seconds, :end_seconds, :position])
    |> validate_inclusion(:transition_in, @transitions)
    |> validate_number(:transition_duration_ms, greater_than_or_equal_to: 0)
    |> validate_range()
  end

  defp validate_range(changeset) do
    start_s = get_field(changeset, :start_seconds)
    end_s = get_field(changeset, :end_seconds)

    if is_number(start_s) and is_number(end_s) and end_s <= start_s do
      add_error(changeset, :end_seconds, "must be greater than start_seconds")
    else
      changeset
    end
  end

  def transitions, do: @transitions
end
