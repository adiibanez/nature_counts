defmodule Naturecounts.Repo.Migrations.AddStorageBackendToVideos do
  use Ecto.Migration

  def change do
    alter table(:videos) do
      add :storage_backend, :string, default: "local"
      add :gcs_bucket, :string
    end
  end
end
