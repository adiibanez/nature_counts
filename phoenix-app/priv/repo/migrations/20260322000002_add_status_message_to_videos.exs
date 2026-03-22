defmodule Naturecounts.Repo.Migrations.AddStatusMessageToVideos do
  use Ecto.Migration

  def change do
    alter table(:videos) do
      add :status_message, :string
    end
  end
end
