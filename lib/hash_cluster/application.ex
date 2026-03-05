defmodule HashCluster.Application do
  use Application
  require Logger

  @impl true
  def start(_type, _args) do
    HashCluster.MnesiaStore.setup()

    children = [
      {Phoenix.PubSub, name: HashCluster.PubSub},
      HashClusterWeb.Endpoint,
      {HashCluster.CancelFlag, []},
      {HashCluster.BroadcastThrottle, []},
      {HashCluster.Coordinator, []},
      {HashCluster.WorkerSupervisor, []},
      {HashCluster.NodeMonitor, []}
      # NodeLoader n'a pas besoin d'être supervisé, ses fonctions sont appelées via RPC
    ]

    opts = [strategy: :one_for_one, name: HashCluster.Supervisor]
    Supervisor.start_link(children, opts)
  end

  @impl true
  def config_change(changed, _new, removed) do
    HashClusterWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
