defmodule Naturecounts.Models.Manifest do
  @moduledoc """
  Loads and writes `deepstream-app-fish/models.json`, the manifest of model
  files fetched by `mix models.fetch`.
  """

  @manifest_rel "../deepstream-app-fish/models.json"

  @doc """
  Returns `{manifest_path, parsed_manifest, models_dir}`.

  The manifest path is resolved relative to the project root (parent of
  `phoenix-app/`). Raises if the file is missing or unparseable.
  """
  def load! do
    path = Path.expand(@manifest_rel, File.cwd!())

    unless File.exists?(path) do
      Mix.raise("manifest not found: #{path}")
    end

    manifest = path |> File.read!() |> Jason.decode!()
    {path, manifest, Path.dirname(path)}
  end

  @doc "Writes the manifest back to disk with stable formatting."
  def write!(path, manifest) do
    json = Jason.encode_to_iodata!(manifest, pretty: true)
    File.write!(path, [json, ?\n])
  end
end
