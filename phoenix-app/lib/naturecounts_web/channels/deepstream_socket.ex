defmodule NaturecountsWeb.DeepstreamSocket do
  @moduledoc """
  Socket for the DeepStream Python pipeline.

  Accepts connections at /deepstream/websocket with a shared secret token.
  Hosts the IngestionChannel for receiving detection batches.
  """

  use Phoenix.Socket

  channel "ingestion:*", NaturecountsWeb.IngestionChannel

  @impl true
  def connect(%{"token" => token}, socket, _connect_info) do
    expected = Application.get_env(:naturecounts, :deepstream_token, "dev-secret-token")

    if Plug.Crypto.secure_compare(token, expected) do
      {:ok, socket}
    else
      :error
    end
  end

  def connect(_params, _socket, _connect_info), do: :error

  @impl true
  def id(_socket), do: "deepstream:pipeline"
end
