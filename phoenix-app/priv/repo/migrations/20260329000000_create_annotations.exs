defmodule Naturecounts.Repo.Migrations.CreateAnnotations do
  use Ecto.Migration

  def change do
    create table(:annotations) do
      add :filename, :string, null: false
      add :timestamp_seconds, :float, null: false
      add :text, :text, null: false

      timestamps()
    end

    create index(:annotations, [:filename])
  end
end
