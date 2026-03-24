defmodule Naturecounts.Repo.Migrations.AddFishialEnabledToVideos do
  use Ecto.Migration

  def change do
    alter table(:videos) do
      add :fishial_enabled, :boolean
    end
  end
end
