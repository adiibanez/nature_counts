defmodule NaturecountsWeb.Presence do
  use Phoenix.Presence,
    otp_app: :naturecounts,
    pubsub_server: Naturecounts.PubSub
end
