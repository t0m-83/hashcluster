defmodule HashCluster.NodeMonitor do
  use GenServer
  require Logger

  def start_link(_), do: GenServer.start_link(__MODULE__, [], name: __MODULE__)
  def connect_node(node_name), do: GenServer.call(__MODULE__, {:connect, node_name})
  def disconnect_node(node_name), do: GenServer.call(__MODULE__, {:disconnect, node_name})
  def list_nodes, do: [node() | Node.list()]

  @impl true
  def init(_) do
    :net_kernel.monitor_nodes(true)
    {:ok, %{}}
  end

  @impl true
  def handle_call({:connect, node_name}, _from, state) do
    node_atom = String.to_atom(node_name)
    case Node.connect(node_atom) do
      true ->
        spawn(fn ->
          :timer.sleep(1000)
          HashCluster.MnesiaStore.add_node_to_schema(node_atom)
        end)
        broadcast_cluster_change()
        {:reply, {:ok, node_atom}, state}
      _ ->
        {:reply, {:error, :connection_failed}, state}
    end
  end

  @impl true
  def handle_call({:disconnect, node_name}, _from, state) do
    :erlang.disconnect_node(String.to_atom(node_name))
    broadcast_cluster_change()
    {:reply, :ok, state}
  end

  @impl true
  def handle_info({:nodeup, new_node}, state) do
    Logger.info("Node joined cluster: #{new_node}")

    # Broadcaster immédiatement pour que l'UI se mette à jour
    broadcast_cluster_change()

    # Bootstrap uniquement si on est le master (Coordinator présent localement)
    case Process.whereis(HashCluster.Coordinator) do
      nil ->
        # On est un worker, rien à faire
        :ok
      coordinator_pid ->
        spawn(fn -> bootstrap_and_notify(new_node, coordinator_pid) end)
    end

    {:noreply, state}
  end

  @impl true
  def handle_info({:nodedown, node}, state) do
    Logger.warning("Node left cluster: #{node}")
    broadcast_cluster_change()
    {:noreply, state}
  end

  # ---- Privé ----

  defp bootstrap_and_notify(new_node, coordinator_pid) do
    Logger.info("Bootstrap #{new_node}...")
    case HashCluster.NodeLoader.bootstrap_worker(new_node) do
      :ok ->
        Logger.info("Code pushé vers #{new_node}, attente démarrage WorkerSupervisor...")
        case wait_until_ready(new_node, 20) do
          :ok ->
            Logger.info("#{new_node} opérationnel — notification Coordinator")
            broadcast_cluster_change()
            send(coordinator_pid, {:new_worker, new_node})
          :timeout ->
            Logger.error("Timeout: #{new_node} ne répond pas après bootstrap")
            broadcast_cluster_change()
        end
      err ->
        Logger.error("Échec bootstrap #{new_node}: #{inspect(err)}")
    end
  end

  # Sonde le worker jusqu'à ce que WorkerSupervisor réponde
  defp wait_until_ready(_node, 0), do: :timeout
  defp wait_until_ready(worker_node, retries) do
    case :rpc.call(worker_node, HashCluster.WorkerSupervisor, :get_worker, [], 2_000) do
      {:ok, _} -> :ok
      _ ->
        Process.sleep(300)
        wait_until_ready(worker_node, retries - 1)
    end
  end

  defp broadcast_cluster_change do
    Phoenix.PubSub.broadcast(HashCluster.PubSub, "dashboard", :cluster_changed)
  end
end
