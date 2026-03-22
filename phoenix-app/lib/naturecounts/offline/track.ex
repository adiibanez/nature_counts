defmodule Naturecounts.Offline.Track do
  use Ecto.Schema
  import Ecto.Changeset

  schema "tracks" do
    field :track_id, :integer
    field :species, :string
    field :scientific_name, :string
    field :species_confidence, :string
    field :vlm_reasoning, :string
    field :best_confidence, :float
    field :best_bbox_area, :integer
    field :first_frame, :integer
    field :last_frame, :integer
    field :frame_count, :integer
    field :thumbnail, :binary
    field :vlm_classified, :boolean, default: false
    field :review_status, :string, default: "pending"
    field :reviewed_at, :naive_datetime
    field :expires_at, :naive_datetime

    belongs_to :video, Naturecounts.Offline.Video

    timestamps()
  end

  def changeset(track, attrs) do
    track
    |> cast(attrs, [
      :track_id, :species, :scientific_name, :species_confidence,
      :vlm_reasoning, :best_confidence, :best_bbox_area,
      :first_frame, :last_frame, :frame_count, :thumbnail,
      :vlm_classified, :video_id,
      :review_status, :reviewed_at, :expires_at
    ])
    |> validate_required([:track_id, :video_id])
    |> unique_constraint([:video_id, :track_id])
  end
end
