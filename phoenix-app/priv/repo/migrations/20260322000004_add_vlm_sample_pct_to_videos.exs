defmodule Naturecounts.Repo.Migrations.AddVlmSamplePctToVideos do
  use Ecto.Migration

  def change do
    alter table(:videos) do
      add :vlm_sample_pct, :integer
    end
  end
end
