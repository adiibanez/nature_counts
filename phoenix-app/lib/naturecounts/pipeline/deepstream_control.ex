defmodule Naturecounts.Pipeline.DeepstreamControl do
  @moduledoc """
  Controls the DeepStream Docker container via the Docker Engine API.
  Provides start/stop and status polling over the Unix socket.
  """
  use GenServer

  require Logger

  @poll_interval 5_000

  # --- Public API ---

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Returns current pipeline status."
  def status do
    GenServer.call(__MODULE__, :status)
  end

  @doc "Starts the DeepStream container."
  def start_pipeline do
    GenServer.call(__MODULE__, :start_pipeline, 15_000)
  end

  @doc "Stops the DeepStream container."
  def stop_pipeline do
    GenServer.call(__MODULE__, :stop_pipeline, 15_000)
  end

  # --- GenServer callbacks ---

  @impl true
  def init(_opts) do
    container = System.get_env("DEEPSTREAM_CONTAINER_NAME", "2022_naturecounts-deepstream-1")
    socket_path = System.get_env("DOCKER_SOCKET_PATH", "/var/run/docker.sock")

    Phoenix.PubSub.subscribe(Naturecounts.PubSub, "deepstream:connection")

    state = %{
      container: container,
      socket_path: socket_path,
      container_status: :unknown,
      ws_connected: false
    }

    # Check if socket exists before polling
    state =
      if File.exists?(socket_path) do
        send(self(), :poll_status)
        state
      else
        Logger.warning("Docker socket not found at #{socket_path} — pipeline control disabled")
        state
      end

    {:ok, state}
  end

  @impl true
  def handle_call(:status, _from, state) do
    {:reply, %{container: state.container_status, ws_connected: state.ws_connected}, state}
  end

  def handle_call(:start_pipeline, _from, state) do
    case docker_post(state, "/containers/#{state.container}/start") do
      {:ok, status} when status in [204, 304] ->
        state = %{state | container_status: :running}
        broadcast_status(state)
        {:reply, :ok, state}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call(:stop_pipeline, _from, state) do
    case docker_post(state, "/containers/#{state.container}/stop?t=10") do
      {:ok, status} when status in [204, 304] ->
        state = %{state | container_status: :stopped}
        broadcast_status(state)
        {:reply, :ok, state}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  @impl true
  def handle_info(:poll_status, state) do
    Process.send_after(self(), :poll_status, @poll_interval)

    state =
      case docker_get(state, "/containers/#{state.container}/json") do
        {:ok, %{"State" => %{"Running" => running}}} ->
          new_status = if running, do: :running, else: :stopped

          if new_status != state.container_status do
            state = %{state | container_status: new_status}
            broadcast_status(state)
            state
          else
            %{state | container_status: new_status}
          end

        {:error, _reason} ->
          if state.container_status != :unknown do
            state = %{state | container_status: :unknown}
            broadcast_status(state)
            state
          else
            state
          end
      end

    {:noreply, state}
  end

  def handle_info({:deepstream_connected, connected}, state) do
    state = %{state | ws_connected: connected}
    broadcast_status(state)
    {:noreply, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  # --- Docker API helpers ---

  defp docker_get(state, path) do
    req = Req.new(unix_socket: state.socket_path, base_url: "http://localhost/v1.41")

    case Req.get(req, url: path) do
      {:ok, %{status: 200, body: body}} -> {:ok, body}
      {:ok, %{status: 404}} -> {:error, :not_found}
      {:ok, resp} -> {:error, {:unexpected_status, resp.status}}
      {:error, err} -> {:error, err}
    end
  rescue
    e -> {:error, Exception.message(e)}
  end

  defp docker_post(state, path) do
    req = Req.new(unix_socket: state.socket_path, base_url: "http://localhost/v1.41")

    case Req.post(req, url: path) do
      {:ok, %{status: status}} -> {:ok, status}
      {:error, err} -> {:error, err}
    end
  rescue
    e -> {:error, Exception.message(e)}
  end

  defp broadcast_status(state) do
    Phoenix.PubSub.broadcast(
      Naturecounts.PubSub,
      "pipeline:status",
      {:pipeline_status, %{container: state.container_status, ws_connected: state.ws_connected}}
    )
  end
end
