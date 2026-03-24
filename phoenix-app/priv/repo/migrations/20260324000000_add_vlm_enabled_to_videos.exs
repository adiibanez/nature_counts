defmodule Naturecounts.Repo.Migrations.AddVlmEnabledToVideos do
  use Ecto.Migration

  def change do
    alter table(:videos) do
      add :vlm_enabled, :boolean, default: true
    end
  end
end
