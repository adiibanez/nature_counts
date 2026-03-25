defmodule Naturecounts.Cache do
  @moduledoc """
  ETS-based cache for hot data. Postgres is the source of truth;
  this module keeps frequently-read aggregates in memory for snappy UI.

  All public functions gracefully degrade if the table doesn't exist yet
  (e.g. during boot), falling back to direct computation.
  """

  use GenServer

  @table :naturecounts_cache

  # --- Public API ---

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, [], name: __MODULE__)
  end

  def get_or_compute(key, compute_fn, opts \\ []) do
    if table_alive?() do
      ttl = Keyword.get(opts, :ttl, 10_000)
      group = Keyword.get(opts, :group, nil)
      now = System.monotonic_time(:millisecond)

      case :ets.lookup(@table, key) do
        [{^key, value, expires_at, _group}] when expires_at > now ->
          value

        _ ->
          value = compute_fn.()
          :ets.insert(@table, {key, value, now + ttl, group})
          value
      end
    else
      compute_fn.()
    end
  end

  def get(key) do
    if table_alive?() do
      now = System.monotonic_time(:millisecond)

      case :ets.lookup(@table, key) do
        [{^key, value, expires_at, _group}] when expires_at > now -> value
        _ -> nil
      end
    end
  end

  def put(key, value, opts \\ []) do
    if table_alive?() do
      ttl = Keyword.get(opts, :ttl, 10_000)
      group = Keyword.get(opts, :group, nil)
      now = System.monotonic_time(:millisecond)
      :ets.insert(@table, {key, value, now + ttl, group})
    end

    :ok
  end

  def invalidate(key) do
    if table_alive?(), do: :ets.delete(@table, key)
    :ok
  end

  def invalidate_group(group) do
    if table_alive?(), do: :ets.match_delete(@table, {:_, :_, :_, group})
    :ok
  end

  def invalidate_all do
    if table_alive?(), do: :ets.delete_all_objects(@table)
    :ok
  end

  # --- GenServer ---

  @impl true
  def init(_) do
    :ets.new(@table, [:named_table, :set, :public, read_concurrency: true])
    {:ok, %{}}
  end

  # --- Private ---

  defp table_alive? do
    :ets.whereis(@table) != :undefined
  end
end
