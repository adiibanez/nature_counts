defmodule Naturecounts.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    # Run pending migrations on startup (non-blocking — app works without DB)
    Task.start(fn ->
      Process.sleep(5_000)
      try do
        Naturecounts.Release.migrate()
      rescue
        e -> require Logger; Logger.warning("Auto-migration skipped: #{Exception.message(e)}")
      end
    end)

    # Download Fishial model if not present (non-blocking)
    Task.start(fn ->
      Process.sleep(3_000)
      try do
        Naturecounts.Offline.FishialSetup.ensure_model()
      rescue
        e -> require Logger; Logger.warning("Fishial setup skipped: #{Exception.message(e)}")
      end
    end)

    children =
      [
        NaturecountsWeb.Telemetry,
        Naturecounts.Repo,
        Naturecounts.Cache,
        {DNSCluster, query: Application.get_env(:naturecounts, :dns_cluster_query) || :ignore},
        {Phoenix.PubSub, name: Naturecounts.PubSub},
        NaturecountsWeb.Presence,
        Naturecounts.Detection.TrackerState,
        Naturecounts.Pipeline.PipelineManager,
        Naturecounts.Pipeline.DeepstreamControl,
        {Oban, Application.fetch_env!(:naturecounts, Oban)},
        NaturecountsWeb.Endpoint
      ]

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: Naturecounts.Supervisor]
    Supervisor.start_link(children, opts)
  end

  @impl true
  def config_change(changed, _new, removed) do
    NaturecountsWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
