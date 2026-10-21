import Config

# We don't run a server during test. If one is required,
# you can enable the server option below.
config :visor, VisorWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "o6bxcWNHO4vcsEgAbIftnnfvT3iXOMF4cdcRK68u3b3drIHZYeGopznF+nGal9Kl",
  server: false

# Never call a real model from tests; run the scripted one without delays.
config :visor, model_provider: Visor.Model.Demo, demo_delay_ms: 0

# Tests that check session logs pass their own directory.
config :visor, session_log_dir: false, server_log_dir: false

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
