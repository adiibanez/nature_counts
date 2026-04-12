defmodule Naturecounts.Clips.Project do
  use Ecto.Schema
  import Ecto.Changeset

  alias Naturecounts.Clips.{Segment, Render}

  @statuses ~w(draft rendering rendered failed)

  schema "clip_projects" do
    field :name, :string
    field :description, :string
    field :output_format, :string, default: "mp4"
    field :output_codec, :string, default: "h264"
    field :output_audio_codec, :string, default: "aac"
    field :status, :string, default: "draft"
    field :last_render_path, :string
    field :last_render_at, :utc_datetime

    has_many :segments, Segment, preload_order: [asc: :position]
    has_many :renders, Render

    timestamps()
  end

  def changeset(project, attrs) do
    project
    |> cast(attrs, [
      :name,
      :description,
      :output_format,
      :output_codec,
      :output_audio_codec,
      :status,
      :last_render_path,
      :last_render_at
    ])
    |> validate_required([:name])
    |> validate_inclusion(:status, @statuses)
  end
end
