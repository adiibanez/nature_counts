defmodule Naturecounts.Pipeline.PipelineState do
  @moduledoc """
  Persists desired pipeline state (started/stopped) to disk so it survives restarts.
  """

  @path Application.compile_env(:naturecounts, :pipeline_state_path, "/data/pipeline_state.json")

  @defaults %{"desired" => "stopped"}

  def get do
    case File.read(@path) do
      {:ok, data} ->
        case Jason.decode(data) do
          {:ok, map} when is_map(map) -> Map.merge(@defaults, map)
          _ -> @defaults
        end

      _ ->
        @defaults
    end
  end

  def set_desired(state) when state in ["running", "stopped"] do
    current = get()
    write(Map.put(current, "desired", state))
  end

  def desired_running? do
    get()["desired"] == "running"
  end

  defp write(data) do
    dir = Path.dirname(@path)
    File.mkdir_p!(dir)
    File.write!(@path, Jason.encode!(data, pretty: true))
  end
end
