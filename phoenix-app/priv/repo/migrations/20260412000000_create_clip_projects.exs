defmodule Naturecounts.Repo.Migrations.CreateClipProjects do
  use Ecto.Migration

  def change do
    create table(:clip_projects) do
      add :name, :string, null: false
      add :description, :text
      add :output_format, :string, default: "mp4", null: false
      add :output_codec, :string, default: "h264", null: false
      add :output_audio_codec, :string, default: "aac", null: false
      add :status, :string, default: "draft", null: false
      add :last_render_path, :string
      add :last_render_at, :utc_datetime

      timestamps()
    end

    create table(:clip_segments) do
      add :project_id, references(:clip_projects, on_delete: :delete_all), null: false
      add :file_path, :string, null: false
      add :start_seconds, :float, null: false
      add :end_seconds, :float, null: false
      add :position, :integer, null: false
      add :transition_in, :string, default: "cut", null: false
      add :transition_duration_ms, :integer, default: 500, null: false
      add :label, :string
      add :source_annotation_id, references(:annotations, on_delete: :nilify_all)

      timestamps()
    end

    create index(:clip_segments, [:project_id, :position])
    create index(:clip_segments, [:file_path])

    create table(:clip_renders) do
      add :project_id, references(:clip_projects, on_delete: :delete_all), null: false
      add :output_path, :string
      add :status, :string, default: "queued", null: false
      add :error, :text
      add :ffmpeg_command, :text
      add :started_at, :utc_datetime
      add :finished_at, :utc_datetime
      add :duration_ms, :integer

      timestamps()
    end

    create index(:clip_renders, [:project_id])
  end
end
