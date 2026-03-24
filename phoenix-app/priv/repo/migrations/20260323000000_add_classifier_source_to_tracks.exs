defmodule Naturecounts.Repo.Migrations.AddClassifierSourceToTracks do
  use Ecto.Migration

  def change do
    alter table(:tracks) do
      add :classifier_source, :string
    end
  end
end
