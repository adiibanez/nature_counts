defmodule Naturecounts.Offline.Video do
  use Ecto.Schema
  import Ecto.Changeset

  schema "videos" do
    field :filename, :string
    field :path, :string
    field :duration_seconds, :float
    field :resolution, :string
    field :recorded_at, :utc_datetime
    field :location, :string
    field :status, :string, default: "pending"
    field :processing_profile, :string, default: "standard"
    field :progress_pct, :integer, default: 0
    field :error_message, :string
    field :status_message, :string

    has_many :tracks, Naturecounts.Offline.Track

    timestamps()
  end

  def changeset(video, attrs) do
    video
    |> cast(attrs, [
      :filename, :path, :duration_seconds, :resolution,
      :recorded_at, :location, :status, :processing_profile,
      :progress_pct, :error_message, :status_message
    ])
    |> validate_required([:filename, :path])
    |> validate_inclusion(:status, ~w(pending processing completed failed))
    |> validate_inclusion(:processing_profile, ~w(light standard deep))
  end
end
