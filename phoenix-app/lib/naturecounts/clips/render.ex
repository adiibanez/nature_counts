defmodule Naturecounts.Clips.Render do
  use Ecto.Schema
  import Ecto.Changeset

  alias Naturecounts.Clips.Project

  @statuses ~w(queued running done failed)

  schema "clip_renders" do
    belongs_to :project, Project
    field :output_path, :string
    field :status, :string, default: "queued"
    field :error, :string
    field :ffmpeg_command, :string
    field :started_at, :utc_datetime
    field :finished_at, :utc_datetime
    field :duration_ms, :integer

    timestamps()
  end

  def changeset(render, attrs) do
    render
    |> cast(attrs, [
      :project_id,
      :output_path,
      :status,
      :error,
      :ffmpeg_command,
      :started_at,
      :finished_at,
      :duration_ms
    ])
    |> validate_required([:project_id, :status])
    |> validate_inclusion(:status, @statuses)
  end
end
