import Config

config :hash_cluster, HashClusterWeb.Endpoint,
  http: [ip: {0, 0, 0, 0}, port: 4000],
  check_origin: false,
  debug_errors: true,
  secret_key_base: "xT4m9kLpRsTuVwXyZ0123456789AbCdEfGhIjKlMnOpQrStUvWxYz0123456789aB"

config :logger, level: :info
