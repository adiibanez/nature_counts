import Config

# config/runtime.exs is executed for all environments, including
# during releases. It is executed after compilation and before the
# system starts, so it is typically used to load production configuration
# and secrets from environment variables or elsewhere. Do not define
# any compile-time configuration in here, as it won't be applied.
# The block below contains prod specific runtime configuration.

# ## Using releases
#
# If you use `mix release`, you need to explicitly enable the server
# by passing the PHX_SERVER=true when you start it:
#
#     PHX_SERVER=true bin/naturecounts start
#
# Alternatively, you can use `mix phx.gen.release` to generate a `bin/server`
# script that automatically sets the env var above.
if System.get_env("PHX_SERVER") do
  config :naturecounts, NaturecountsWeb.Endpoint, server: true
end

config :naturecounts, NaturecountsWeb.Endpoint,
  http: [port: String.to_integer(System.get_env("PORT", "4005"))]

# Database
if database_url = System.get_env("DATABASE_URL") do
  config :naturecounts, Naturecounts.Repo, url: database_url
end

# Anthropic Claude API key for offline species classification
if api_key = System.get_env("ANTHROPIC_API_KEY") do
  config :naturecounts, anthropic_api_key: api_key
end

# DeepStream pipeline token (shared secret for WebSocket auth)
if ds_token = System.get_env("DEEPSTREAM_TOKEN") do
  config :naturecounts, deepstream_token: ds_token
end

if num_cams = System.get_env("NUM_CAMERAS") do
  config :naturecounts, num_cameras: String.to_integer(num_cams)
end

if mtx_host = System.get_env("MEDIAMTX_HOST") do
  config :naturecounts, mediamtx_host: mtx_host
end

# Override camera sources at runtime.
# CAMERAS=rtsp switches all cameras to DeepStream RTSP output.
# CAMERAS=file keeps the dev file sources (default in dev).
case System.get_env("CAMERAS") do
  "rtsp" ->
    num = String.to_integer(System.get_env("NUM_CAMERAS", "3"))
    rtsp_base = System.get_env("DEEPSTREAM_RTSP_BASE", "rtsp://deepstream:8554/cam")

    cameras =
      for i <- 1..num do
        %{id: "cam#{i}", source: {:rtsp, "#{rtsp_base}#{i}"}}
      end

    config :naturecounts, :cameras, cameras

  "file" ->
    num = String.to_integer(System.get_env("NUM_CAMERAS", "3"))
    videos_dir = System.get_env("VIDEOS_DIR", "/videos")

    cameras =
      for i <- 1..num do
        %{id: "cam#{i}", source: {:file, Path.join(videos_dir, "cam_#{i}.mp4")}}
      end

    config :naturecounts, :cameras, cameras

  "webrtc" ->
    # Clear Membrane camera sources — detail view uses MediaMTX WebRTC directly
    config :naturecounts, :cameras, []

  _ ->
    :ok
end

if config_env() == :prod do
  # The secret key base is used to sign/encrypt cookies and other secrets.
  # A default value is used in config/dev.exs and config/test.exs but you
  # want to use a different value for prod and you most likely don't want
  # to check this value into version control, so we use an environment
  # variable instead.
  secret_key_base =
    System.get_env("SECRET_KEY_BASE") ||
      raise """
      environment variable SECRET_KEY_BASE is missing.
      You can generate one by calling: mix phx.gen.secret
      """

  host = System.get_env("PHX_HOST") || "example.com"

  config :naturecounts, :dns_cluster_query, System.get_env("DNS_CLUSTER_QUERY")

  config :naturecounts, NaturecountsWeb.Endpoint,
    url: [host: host, port: 443, scheme: "https"],
    http: [
      # Enable IPv6 and bind on all interfaces.
      # Set it to  {0, 0, 0, 0, 0, 0, 0, 1} for local network only access.
      # See the documentation on https://hexdocs.pm/bandit/Bandit.html#t:options/0
      # for details about using IPv6 vs IPv4 and loopback vs public addresses.
      ip: {0, 0, 0, 0, 0, 0, 0, 0}
    ],
    secret_key_base: secret_key_base

  # ## SSL Support
  #
  # To get SSL working, you will need to add the `https` key
  # to your endpoint configuration:
  #
  #     config :naturecounts, NaturecountsWeb.Endpoint,
  #       https: [
  #         ...,
  #         port: 443,
  #         cipher_suite: :strong,
  #         keyfile: System.get_env("SOME_APP_SSL_KEY_PATH"),
  #         certfile: System.get_env("SOME_APP_SSL_CERT_PATH")
  #       ]
  #
  # The `cipher_suite` is set to `:strong` to support only the
  # latest and more secure SSL ciphers. This means old browsers
  # and clients may not be supported. You can set it to
  # `:compatible` for wider support.
  #
  # `:keyfile` and `:certfile` expect an absolute path to the key
  # and cert in disk or a relative path inside priv, for example
  # "priv/ssl/server.key". For all supported SSL configuration
  # options, see https://hexdocs.pm/plug/Plug.SSL.html#configure/1
  #
  # We also recommend setting `force_ssl` in your config/prod.exs,
  # ensuring no data is ever sent via http, always redirecting to https:
  #
  #     config :naturecounts, NaturecountsWeb.Endpoint,
  #       force_ssl: [hsts: true]
  #
  # Check `Plug.SSL` for all available options in `force_ssl`.
end
