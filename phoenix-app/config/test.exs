import Config

# We don't run a server during test. If one is required,
# you can enable the server option below.
config :naturecounts, NaturecountsWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "pIH6tk0Zkp6aZbNtpbO3I2ZA/9N+nmeh0ON2Xt7Ac97Ba+kho3yqWfrOz82lr2+Q",
  server: false

# Print only warnings and errors during test
config :logger, level: :warning

# Initialize plugs at runtime for faster test compilation
config :phoenix, :plug_init_mode, :runtime

# Enable helpful, but potentially expensive runtime checks
config :phoenix_live_view,
  enable_expensive_runtime_checks: true

# Sort query params output of verified routes for robust url comparisons
config :phoenix,
  sort_verified_routes_query_params: true
