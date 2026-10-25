import Config

# Visor has no test suite; MIX_ENV=test only builds it.
config :visor, VisorWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "o6bxcWNHO4vcsEgAbIftnnfvT3iXOMF4cdcRK68u3b3drIHZYeGopznF+nGal9Kl",
  server: false

config :logger, level: :warning

# Initialize plugs at runtime for faster compilation
config :phoenix, :plug_init_mode, :runtime
