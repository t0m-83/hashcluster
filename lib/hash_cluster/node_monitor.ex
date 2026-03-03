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
    result = Node.connect(node_atom)
    if result == true do
      spawn(fn ->
        :timer.sleep(1000)
        HashCluster.MnesiaStore.add_node_to_schema(node_atom)
      end)
      broadcast_cluster_change()
      {:reply, {:ok, node_atom}, state}
    else
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

    # Pousser le code et démarrer le worker uniquement si on est le master
    case Process.whereis(HashCluster.Coordinator) do
      nil ->
        # On est un worker, rien à faire
        :ok
      coordinator_pid ->
        # On est le master : pousser le code vers le nouveau nœud
        spawn(fn ->
          Logger.info("NodeLoader: bootstrap de #{new_node}...")
          case HashCluster.NodeLoader.bootstrap_worker(new_node) do
            :ok ->
              Logger.info("NodeLoader: code pushé vers #{new_node}, attente démarrage...")
              broadcast_cluster_change()
              # rpc.cast est asynchrone : attendre que WorkerSupervisor soit prêt
              wait_for_worker(new_node, coordinator_pid, 20)
            err ->
              Logger.error("NodeLoader: échec bootstrap #{new_node}: #{inspect(err)}")
              broadcast_cluster_change()
          end
        end)
    end

    {:noreply, state}
  end

  @impl true
  def handle_info({:nodedown, node}, state) do
    Logger.warning("Node left cluster: #{node}")
    broadcast_cluster_change()
    {:noreply, state}
  end

  defp wait_for_worker(_node, _coordinator_pid, 0) do
    Logger.error("NodeLoader: timeout attente worker")
  end
  defp wait_for_worker(worker_node, coordinator_pid, retries) do
    case :rpc.call(worker_node, HashCluster.WorkerSupervisor, :get_worker, [], 2_000) do
      {:ok, _} ->
        Logger.info("NodeLoader: #{worker_node} opérationnel apres #{21 - retries} essais")
        broadcast_cluster_change()
        send(coordinator_pid, {:new_worker, worker_node})
      _ ->
        Process.sleep(500)
        wait_for_worker(worker_node, coordinator_pid, retries - 1)
    end
  end

  defp broadcast_cluster_change do
    Phoenix.PubSub.broadcast(HashCluster.PubSub, "dashboard", :cluster_changed)
  end
end
