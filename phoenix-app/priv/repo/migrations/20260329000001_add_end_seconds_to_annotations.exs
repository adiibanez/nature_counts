defmodule Naturecounts.Repo.Migrations.AddEndSecondsToAnnotations do
  use Ecto.Migration

  def change do
    alter table(:annotations) do
      add :end_seconds, :float
    end
  end
end
