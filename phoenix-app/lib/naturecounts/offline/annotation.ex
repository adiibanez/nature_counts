defmodule Naturecounts.Offline.Annotation do
  use Ecto.Schema
  import Ecto.Changeset

  schema "annotations" do
    field :filename, :string
    field :timestamp_seconds, :float
    field :end_seconds, :float
    field :text, :string

    timestamps()
  end

  def changeset(annotation, attrs) do
    annotation
    |> cast(attrs, [:filename, :timestamp_seconds, :end_seconds, :text])
    |> validate_required([:filename, :timestamp_seconds, :text])
  end
end
