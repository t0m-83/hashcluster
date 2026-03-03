import Config

config :hash_cluster, HashClusterWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "testkey123456789012345678901234567890123456789012345678901234567890",
  server: false

config :logger, level: :warning
