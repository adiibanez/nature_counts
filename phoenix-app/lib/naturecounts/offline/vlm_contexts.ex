defmodule Naturecounts.Offline.VlmContexts do
  @moduledoc """
  Persists saved VLM context prompts to a JSON file.
  Each context has a name and a prompt string used as location context for species identification.
  """

  @path Application.compile_env(:naturecounts, :vlm_contexts_path, "/data/vlm_contexts.json")

  @defaults [
    %{
      "id" => "fulhadhoo_reef",
      "name" => "Fulhadhoo Reef",
      "prompt" => "Shallow coral reef on the north-west end of Fulhadhoo island, Baa Atoll, Maldives. Tropical Indo-Pacific reef fish species expected."
    },
    %{
      "id" => "generic_reef",
      "name" => "Generic Reef Camera",
      "prompt" => "Underwater reef camera monitoring fish biodiversity."
    }
  ]

  def list do
    case read() do
      [] -> @defaults
      contexts -> contexts
    end
  end

  def get(id) do
    Enum.find(list(), fn c -> c["id"] == id end)
  end

  def add(name, prompt) do
    id = slugify(name)
    contexts = list()

    case Enum.find_index(contexts, fn c -> c["id"] == id end) do
      nil ->
        write(contexts ++ [%{"id" => id, "name" => name, "prompt" => prompt}])

      idx ->
        write(List.replace_at(contexts, idx, %{"id" => id, "name" => name, "prompt" => prompt}))
    end

    id
  end

  def update(id, name, prompt) do
    contexts = list()

    case Enum.find_index(contexts, fn c -> c["id"] == id end) do
      nil -> add(name, prompt)
      idx -> write(List.replace_at(contexts, idx, %{"id" => id, "name" => name, "prompt" => prompt}))
    end

    id
  end

  def delete(id) do
    contexts = list() |> Enum.reject(fn c -> c["id"] == id end)
    write(contexts)
  end

  defp slugify(name) do
    name
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9\s-]/, "")
    |> String.replace(~r/[\s-]+/, "_")
    |> String.trim("_")
  end

  defp read do
    case File.read(@path) do
      {:ok, data} ->
        case Jason.decode(data) do
          {:ok, list} when is_list(list) -> list
          _ -> []
        end

      _ ->
        []
    end
  end

  defp write(contexts) do
    dir = Path.dirname(@path)
    File.mkdir_p!(dir)
    File.write!(@path, Jason.encode!(contexts, pretty: true))
  end
end
