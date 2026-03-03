defmodule HashCluster.Coordinator do
  use GenServer
  require Logger

  # Chaque worker traite UN batch à la fois — la queue reste disponible
  # pour les workers qui arrivent en cours de route
  @batch_size 30

  def start_link(_), do: GenServer.start_link(__MODULE__, %{}, name: __MODULE__)
  def start_job(directory), do: GenServer.call(__MODULE__, {:start_job, directory})
  def stop_job,             do: GenServer.call(__MODULE__, :stop_job)
  def status,               do: GenServer.call(__MODULE__, :status)

  def batch_done(worker_node, count) do
    GenServer.cast(__MODULE__, {:batch_done, worker_node, count})
  end

  @impl true
  def init(_), do: {:ok, %{job_id: nil, status: :idle, queue: [], in_flight: 0}}

  @impl true
  def handle_call({:start_job, directory}, _from, state) do
    cond do
      state.status == :running ->
        {:reply, {:error, :already_running}, state}
      not File.exists?(directory) ->
        {:reply, {:error, :directory_not_found}, state}
      true ->
        job_id = HashCluster.MnesiaStore.create_job(directory)
        HashCluster.MnesiaStore.update_job(job_id, status: :running, started_at: DateTime.utc_now())
        files = list_files(directory)
        total = length(files)
        HashCluster.MnesiaStore.update_job(job_id, total: total)
        Logger.info("Job #{job_id}: #{total} fichiers, batch_size=#{@batch_size}")
        new_state = %{state | job_id: job_id, status: :running, queue: files, in_flight: 0}
        send(self(), :initial_dispatch)
        {:reply, :ok, new_state}
    end
  end

  @impl true
  def handle_call(:stop_job, _from, state) do
    if state.job_id do
      HashCluster.MnesiaStore.update_job(state.job_id,
        status: :stopped, finished_at: DateTime.utc_now())
    end
    {:reply, :ok, %{state | status: :idle, job_id: nil, queue: [], in_flight: 0}}
  end

  @impl true
  def handle_call(:status, _from, state), do: {:reply, state.status, state}

  @impl true
  def handle_cast({:batch_done, worker_node, count}, state) do
    new_in_flight = max(0, state.in_flight - count)
    Logger.info("batch_done #{worker_node}: #{count} | queue=#{length(state.queue)} | in_flight=#{new_in_flight}")
    new_state = %{state | in_flight: new_in_flight}

    cond do
      new_in_flight == 0 and new_state.queue == [] ->
        Logger.info("Job #{state.job_id} terminé ✓")
        HashCluster.MnesiaStore.update_job(state.job_id,
          status: :done, finished_at: DateTime.utc_now())
        {:noreply, %{new_state | status: :idle, job_id: nil}}

      new_state.queue != [] ->
        {:noreply, send_batch_to(worker_node, new_state)}

      true ->
        {:noreply, new_state}
    end
  end

  @impl true
  def handle_info(:initial_dispatch, state) do
    workers = get_workers()
    Logger.info("Workers au démarrage (#{length(workers)}): #{inspect(workers)}")
    new_state = Enum.reduce(workers, state, fn wn, acc -> send_batch_to(wn, acc) end)
    Logger.info("Après dispatch initial: queue=#{length(new_state.queue)}, in_flight=#{new_state.in_flight}")
    {:noreply, new_state}
  end

  def handle_info({:new_worker, worker_node}, state) do
    Logger.info("Nouveau worker: #{worker_node} | status=#{state.status} | queue=#{length(state.queue)}")
    if state.status == :running and state.queue != [] do
      Logger.info("Dispatch vers #{worker_node}")
      {:noreply, send_batch_to(worker_node, state)}
    else
      Logger.info("Pas de dispatch (status=#{state.status}, queue=#{length(state.queue)})")
      {:noreply, state}
    end
  end

  defp send_batch_to(_worker_node, %{queue: []} = state), do: state
  defp send_batch_to(worker_node, state) do
    {batch, remaining} = Enum.split(state.queue, @batch_size)
    job_id = state.job_id
    master = node()
    coordinator = node()
    Logger.info("  -> #{worker_node}: #{length(batch)} fichiers (#{length(remaining)} restants)")
    spawn(fn ->
      :rpc.call(worker_node, HashCluster.FileWorker, :process_batch,
                [job_id, batch, master, coordinator], :infinity)
    end)
    %{state | queue: remaining, in_flight: state.in_flight + length(batch)}
  end

  defp get_workers do
    all_nodes = [node() | Node.list()]
    workers = Enum.flat_map(all_nodes, fn n ->
      case :rpc.call(n, HashCluster.WorkerSupervisor, :get_worker, [], 3_000) do
        {:ok, _} -> [n]
        other -> Logger.warning("Worker KO sur #{n}: #{inspect(other)}"); []
      end
    end)
    case workers do
      [] -> [node()]
      w  -> w
    end
  end

  defp list_files(directory) do
    directory |> Path.expand() |> Path.join("**/*") |> Path.wildcard() |> Enum.filter(&File.regular?/1)
  end
end
