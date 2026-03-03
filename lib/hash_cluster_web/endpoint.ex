defmodule HashClusterWeb.Endpoint do
  use Phoenix.Endpoint, otp_app: :hash_cluster

  @session_options [
    store: :cookie,
    key: "_hash_cluster_key",
    signing_salt: "xT4m9kLp",
    same_site: "Lax"
  ]

  socket "/live", Phoenix.LiveView.Socket,
    websocket: [connect_info: [session: @session_options]]

  plug Plug.Static,
    at: "/",
    from: :hash_cluster,
    gzip: false,
    only: HashClusterWeb.static_paths()

  plug Plug.RequestId
  plug Plug.Telemetry, event_prefix: [:phoenix, :endpoint]

  plug Plug.Parsers,
    parsers: [:urlencoded, :multipart, :json],
    pass: ["*/*"],
    json_decoder: Phoenix.json_library()

  plug Plug.MethodOverride
  plug Plug.Head
  plug Plug.Session, @session_options
  plug HashClusterWeb.Router
end
