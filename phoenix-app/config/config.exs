# This file is responsible for configuring your application
# and its dependencies with the aid of the Config module.
#
# This configuration file is loaded before any dependency and
# is restricted to this project.

# General application configuration
import Config

config :naturecounts,
  ecto_repos: [Naturecounts.Repo],
  generators: [timestamp_type: :utc_datetime],
  deepstream_token: "dev-secret-token",
  num_cameras: 3,
  mediamtx_host: "localhost:8889",
  cameras: []

config :naturecounts, Naturecounts.Repo,
  username: "naturecounts",
  password: "naturecounts_dev",
  hostname: "postgres",
  database: "naturecounts",
  port: 5433,
  pool_size: 10

config :naturecounts, Oban,
  repo: Naturecounts.Repo,
  queues: [video_processing: 1]

config :pythonx, :uv_init,
  pyproject_toml: """
  [project]
  name = "naturecounts-offline"
  version = "0.0.0"
  requires-python = "==3.12.*"
  dependencies = [
    "ultralytics>=8.3",
    "opencv-python-headless>=4.9",
    "numpy>=1.26",
    "supervision>=0.25",
    "torch>=2.4",
    "torchvision>=0.19",
  ]

  [tool.uv.sources]
  torch = {index = "pytorch-cu121"}
  torchvision = {index = "pytorch-cu121"}

  [[tool.uv.index]]
  name = "pytorch-cu121"
  url = "https://download.pytorch.org/whl/cu121"
  explicit = true
  """

# Configure the endpoint
config :naturecounts, NaturecountsWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [
    formats: [html: NaturecountsWeb.ErrorHTML, json: NaturecountsWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: Naturecounts.PubSub,
  live_view: [signing_salt: "TGZC+mrf"]

# Configure esbuild (the version is required)
config :esbuild,
  version: "0.25.4",
  naturecounts: [
    args:
      ~w(js/app.js --bundle --target=es2022 --outdir=../priv/static/assets/js --external:/fonts/* --external:/images/* --alias:@=.),
    cd: Path.expand("../assets", __DIR__),
    env: %{"NODE_PATH" => [Path.expand("../deps", __DIR__), Mix.Project.build_path()]}
  ]

# Configure tailwind (the version is required)
config :tailwind,
  version: "4.1.12",
  naturecounts: [
    args: ~w(
      --input=assets/css/app.css
      --output=priv/static/assets/css/app.css
    ),
    cd: Path.expand("..", __DIR__)
  ]

# Configure Elixir's Logger
config :logger, :default_formatter,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

# Use Jason for JSON parsing in Phoenix
config :phoenix, :json_library, Jason

# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
import_config "#{config_env()}.exs"
