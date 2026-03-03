import Config

config :hash_cluster, HashClusterWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [
    formats: [html: HashClusterWeb.ErrorHTML],
    layout: false
  ],
  pubsub_server: HashCluster.PubSub,
  live_view: [signing_salt: "xT4m9kLp"]

config :esbuild,
  version: "0.25.0",
  default: [
    args: ~w(js/app.js --bundle --target=es2017 --outdir=../priv/static/assets),
    cd: Path.expand("../assets", __DIR__),
    env: %{"NODE_PATH" => Path.expand("../deps", __DIR__)}
  ]

config :logger, :console,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

config :phoenix, :json_library, Jason

import_config "#{config_env()}.exs"
