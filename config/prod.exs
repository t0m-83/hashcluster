import Config

config :hash_cluster, HashClusterWeb.Endpoint,
  http: [ip: {0, 0, 0, 0}, port: System.get_env("PORT", "4000") |> String.to_integer()],
  secret_key_base: System.fetch_env!("SECRET_KEY_BASE"),
  server: true

config :logger, level: :info
