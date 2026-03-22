defmodule Naturecounts.Repo.Migrations.AddVlmStatsAndReview do
  use Ecto.Migration

  def change do
    alter table(:videos) do
      add :total_tracks, :integer
      add :vlm_qualified, :integer
      add :vlm_classified_count, :integer
      add :min_bbox_area, :integer
    end

    alter table(:tracks) do
      add :review_status, :string, default: "pending"
      add :reviewed_at, :utc_datetime
      add :expires_at, :utc_datetime
    end

    create index(:tracks, [:review_status])
    create index(:tracks, [:expires_at])
  end
end
