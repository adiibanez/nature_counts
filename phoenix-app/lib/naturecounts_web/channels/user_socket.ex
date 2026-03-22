defmodule NaturecountsWeb.UserSocket do
  @moduledoc """
  Socket for browser clients.

  Hosts the DetectionChannel for receiving real-time bbox data.
  """

  use Phoenix.Socket

  channel "detections:*", NaturecountsWeb.DetectionChannel

  @impl true
  def connect(_params, socket, _connect_info) do
    {:ok, socket}
  end

  @impl true
  def id(_socket), do: nil
end
