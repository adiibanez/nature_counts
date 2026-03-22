defmodule Naturecounts.Repo.Migrations.CreateVideosAndTracks do
  use Ecto.Migration

  def change do
    create table(:videos) do
      add :filename, :string, null: false
      add :path, :string, null: false
      add :duration_seconds, :float
      add :resolution, :string
      add :recorded_at, :utc_datetime
      add :location, :string
      add :status, :string, null: false, default: "pending"
      add :processing_profile, :string, null: false, default: "standard"
      add :progress_pct, :integer, null: false, default: 0
      add :error_message, :text

      timestamps()
    end

    create index(:videos, [:status])

    create table(:tracks) do
      add :video_id, references(:videos, on_delete: :delete_all), null: false
      add :track_id, :integer, null: false
      add :species, :string
      add :scientific_name, :string
      add :species_confidence, :string
      add :vlm_reasoning, :text
      add :best_confidence, :float
      add :best_bbox_area, :integer
      add :first_frame, :integer
      add :last_frame, :integer
      add :frame_count, :integer
      add :thumbnail, :binary
      add :vlm_classified, :boolean, null: false, default: false

      timestamps()
    end

    create index(:tracks, [:video_id])
    create index(:tracks, [:species])
    create index(:tracks, [:vlm_classified])
    create unique_index(:tracks, [:video_id, :track_id])
  end
end
