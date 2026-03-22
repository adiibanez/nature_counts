defmodule Naturecounts.Pipeline.PipelineManager do
  @moduledoc """
  Manages camera configurations and spawns per-viewer pipelines.

  This GenServer holds the camera source configurations (RTSP URIs or file paths)
  and provides an API for:
    - Listing available cameras and their sources
    - Switching a camera's source at runtime (e.g. real → fake)
    - Spawning a viewer pipeline for a given camera + signaling

  Camera configuration comes from application config:

      config :naturecounts, :cameras, [
        %{id: "cam1", source: {:file, "/path/to/video.mp4"}},
        %{id: "cam2", source: {:rtsp, "rtsp://deepstream:8554/cam2"}}
      ]
  """

  use GenServer

  require Logger

  alias Naturecounts.Pipeline.CameraPipeline

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "List all configured cameras."
  def list_cameras do
    GenServer.call(__MODULE__, :list_cameras)
  end

  @doc "Get the source config for a camera."
  def get_source(camera_id) do
    GenServer.call(__MODULE__, {:get_source, camera_id})
  end

  @doc "Switch a camera's source at runtime. Existing viewers keep their current pipeline."
  def switch_source(camera_id, new_source) do
    GenServer.call(__MODULE__, {:switch_source, camera_id, new_source})
  end

  @doc """
  Start a viewer pipeline for a camera.

  Returns `{:ok, supervisor_pid, pipeline_pid}` on success.
  The pipeline connects to the given `Membrane.WebRTC.Signaling` to stream to the viewer.
  """
  def start_viewer_pipeline(camera_id, signaling) do
    case get_source(camera_id) do
      {:ok, source} ->
        # Use start (not start_link) so a pipeline crash doesn't take down the LiveView.
        Membrane.Pipeline.start(CameraPipeline,
          camera_id: camera_id,
          source: source,
          signaling: signaling
        )

      {:error, _} = error ->
        error
    end
  end

  # -- GenServer callbacks ---------------------------------------------------

  @impl true
  def init(_opts) do
    cameras = Application.get_env(:naturecounts, :cameras, [])

    sources =
      cameras
      |> Enum.map(fn %{id: id, source: source} -> {id, source} end)
      |> Map.new()

    Logger.info("PipelineManager: #{map_size(sources)} camera(s) configured: #{inspect(Map.keys(sources))}")

    {:ok, %{sources: sources}}
  end

  @impl true
  def handle_call(:list_cameras, _from, state) do
    cameras =
      Enum.map(state.sources, fn {id, source} ->
        %{id: id, source: source, source_type: elem(source, 0)}
      end)

    {:reply, cameras, state}
  end

  @impl true
  def handle_call({:get_source, camera_id}, _from, state) do
    case Map.get(state.sources, camera_id) do
      nil -> {:reply, {:error, :not_found}, state}
      source -> {:reply, {:ok, source}, state}
    end
  end

  @impl true
  def handle_call({:switch_source, camera_id, new_source}, _from, state) do
    if Map.has_key?(state.sources, camera_id) do
      Logger.info("PipelineManager: switching #{camera_id} to #{inspect(new_source)}")
      state = put_in(state, [:sources, camera_id], new_source)
      Phoenix.PubSub.broadcast(Naturecounts.PubSub, "cameras", {:source_changed, camera_id, new_source})
      {:reply, :ok, state}
    else
      {:reply, {:error, :not_found}, state}
    end
  end
end
