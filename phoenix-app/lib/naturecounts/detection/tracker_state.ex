defmodule Naturecounts.Detection.TrackerState do
  @moduledoc """
  ETS-backed GenServer that maintains per-camera active tracks and trajectories.

  Stores the last N positions per track for trajectory trails, prunes tracks
  not seen for more than a configurable timeout, and provides fish counting.
  """

  use GenServer

  alias Naturecounts.Detection.DetectionEvent

  @table :tracker_state
  @prune_interval :timer.seconds(5)
  # Timeout in milliseconds to match DeepStream C++ epoch-ms timestamps
  @track_timeout_ms 5_000
  @max_trajectory_length 50

  # --- Public API ---

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, [], name: __MODULE__)
  end

  @doc "Update tracker state with a new detection event."
  def update(%DetectionEvent{} = event) do
    GenServer.cast(__MODULE__, {:update, event})
  end

  @doc "Get active track count for a camera."
  def active_count(cam_id) do
    now = latest_ts(cam_id)
    cutoff = now - @track_timeout_ms

    # ETS rows: {{cam_id, track_id}, trajectory, last_seen, label, thumbnail}
    :ets.match(@table, {{cam_id, :_}, :_, :"$1", :_, :_})
    |> Enum.count(fn [last_seen] -> is_number(last_seen) and last_seen > cutoff end)
  end

  @doc "Get total unique tracks seen for a camera (fish count estimate)."
  def total_tracks(cam_id) do
    case :ets.lookup(@table, {cam_id, :total_count}) do
      [{{^cam_id, :total_count}, count}] -> count
      [] -> 0
    end
  end

  @doc "Get trajectory (list of recent positions) for a specific track."
  def trajectory(cam_id, track_id) do
    case :ets.lookup(@table, {cam_id, track_id}) do
      [{{^cam_id, ^track_id}, trajectory, _last_seen, _label, _thumb}] -> trajectory
      [] -> []
    end
  end

  @doc "Get active tracks with their latest bbox, label, and thumbnail for a camera."
  def active_tracks(cam_id) do
    now = latest_ts(cam_id)
    cutoff = now - @track_timeout_ms

    # ETS rows: {{cam_id, track_id}, trajectory, last_seen, label, thumbnail}
    :ets.match_object(@table, {{cam_id, :_}, :_, :_, :_, :_})
    |> Enum.filter(fn {{_cam, _tid}, _traj, last_seen, _label, _thumb} ->
      is_number(last_seen) and last_seen > cutoff
    end)
    |> Enum.map(fn {{_cam, track_id}, [{left, top, w, h} | _], _last_seen, label, thumbnail} ->
      %{
        track_id: track_id,
        label: label,
        bbox: %{left: left, top: top, width: w, height: h},
        thumbnail: thumbnail
      }
    end)
  end

  @doc "Get summary stats for a camera."
  def camera_stats(cam_id) do
    %{
      active_tracks: active_count(cam_id),
      total_tracks: total_tracks(cam_id)
    }
  end

  # --- GenServer callbacks ---

  @impl true
  def init(_opts) do
    :ets.new(@table, [:named_table, :set, :public, read_concurrency: true])
    schedule_prune()
    {:ok, %{known_tracks: MapSet.new()}}
  end

  @impl true
  def handle_cast({:update, %DetectionEvent{cam_id: cam_id, ts: ts, objects: objects}}, state) do
    # Use the DeepStream frame timestamp so track freshness aligns with video time,
    # not server wall-clock time. This keeps "active tracks" in sync with what's
    # visible on the WebRTC stream.
    frame_ts = ts || System.monotonic_time(:millisecond)

    # Store the latest frame timestamp per camera for active_count comparisons
    :ets.insert(@table, {{cam_id, :latest_ts}, frame_ts})

    new_state = Enum.reduce(objects, state, fn obj, acc ->
      key = {cam_id, obj.track_id}
      pos = {obj.bbox.left, obj.bbox.top, obj.bbox.width, obj.bbox.height}

      trajectory =
        case :ets.lookup(@table, key) do
          [{^key, existing, _last_seen, _label, _thumb}] ->
            Enum.take([pos | existing], @max_trajectory_length)

          [] ->
            [pos]
        end

      thumbnail = obj.thumbnail
      :ets.insert(@table, {key, trajectory, frame_ts, obj.label, thumbnail})

      # Track unique fish
      track_key = {cam_id, obj.track_id}

      if MapSet.member?(acc.known_tracks, track_key) do
        acc
      else
        counter_key = {cam_id, :total_count}

        case :ets.lookup(@table, counter_key) do
          [{^counter_key, count}] -> :ets.insert(@table, {counter_key, count + 1})
          [] -> :ets.insert(@table, {counter_key, 1})
        end

        %{acc | known_tracks: MapSet.put(acc.known_tracks, track_key)}
      end
    end)

    {:noreply, new_state}
  end

  @impl true
  def handle_info(:prune, state) do
    # Prune per-camera using each camera's latest frame timestamp as reference.
    latest_ts_entries = :ets.match(@table, {{:"$1", :latest_ts}, :"$2"})

    for [cam_id, latest_ts] <- latest_ts_entries do
      cutoff = latest_ts - @track_timeout_ms

      :ets.select_delete(@table, [
        {{{cam_id, :_}, :_, :"$1", :_, :_}, [{:is_number, :"$1"}, {:<, :"$1", cutoff}], [true]}
      ])
    end

    schedule_prune()
    {:noreply, state}
  end

  defp latest_ts(cam_id) do
    case :ets.lookup(@table, {cam_id, :latest_ts}) do
      [{{^cam_id, :latest_ts}, ts}] -> ts
      [] -> :erlang.system_time(:second)
    end
  end

  defp schedule_prune do
    Process.send_after(self(), :prune, @prune_interval)
  end
end
