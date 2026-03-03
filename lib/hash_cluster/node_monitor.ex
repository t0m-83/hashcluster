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
    broadcast_cluster_change()
    # Notifier le Coordinator uniquement si on est le master
    # (le Coordinator n'est enregistré que sur le master)
    case Process.whereis(HashCluster.Coordinator) do
      nil -> :ok
      coordinator_pid ->
        Logger.info("NodeMonitor: notify Coordinator of new worker #{new_node}")
        send(coordinator_pid, {:new_worker, new_node})
    end
    {:noreply, state}
  end

  @impl true
  def handle_info({:nodedown, node}, state) do
    Logger.warning("Node left cluster: #{node}")
    broadcast_cluster_change()
    {:noreply, state}
  end

  defp broadcast_cluster_change do
    Phoenix.PubSub.broadcast(HashCluster.PubSub, "dashboard", :cluster_changed)
  end
end
