defmodule HashCluster.Coordinator do
  use GenServer
  require Logger

  @batch_size 30
  # Nombre de batches dispatché d'emblée par worker au démarrage
  # Assure que chaque worker a du travail en avance même si le réseau est lent
  @prefetch 3

  def start_link(_), do: GenServer.start_link(__MODULE__, %{}, name: __MODULE__)
  def start_job(directory), do: GenServer.call(__MODULE__, {:start_job, directory}, 30_000)
  def stop_job,             do: GenServer.call(__MODULE__, :stop_job, 5_000)
  def status,               do: GenServer.call(__MODULE__, :status)

  # Pull atomique : signale la fin du batch précédent ET demande le suivant
  def next_batch(worker_node, completed_count) do
    GenServer.call(__MODULE__, {:next_batch, worker_node, completed_count}, 30_000)
  end

  # Fin de batch sans redemande (annulation)
  def batch_done(worker_node, count) do
    GenServer.cast(__MODULE__, {:batch_done, worker_node, count})
  end

  @impl true
  def init(_) do
    {:ok, %{
      job_id:    nil,
      status:    :idle,
      queue:     [],
      # Tracker par worker : combien de fichiers chaque worker a en vol
      # Map %{worker_node => count}
      workers:   %{}
    }}
  end

  # ---- handle_call ----

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
        Logger.info("Job #{job_id}: #{total} fichiers, batch_size=#{@batch_size}, prefetch=#{@prefetch}")
        HashCluster.CancelFlag.init_job(job_id)
        new_state = %{state | job_id: job_id, status: :running, queue: files, workers: %{}}
        send(self(), :initial_dispatch)
        {:reply, :ok, new_state}
    end
  end

  @impl true
  def handle_call(:stop_job, _from, state) do
    if state.job_id do
      HashCluster.CancelFlag.cancel(state.job_id)
      HashCluster.MnesiaStore.update_job(state.job_id,
        status: :stopped, finished_at: DateTime.utc_now())
      Logger.info("Job #{state.job_id} annulé")
    end
    {:reply, :ok, %{state | status: :idle, job_id: nil, queue: [], workers: %{}}}
  end

  @impl true
  def handle_call(:status, _from, state), do: {:reply, state.status, state}

  @impl true
  def handle_call({:next_batch, worker_node, completed_count}, _from, state) do
    if state.status != :running do
      {:reply, {:done, []}, state}
    else
      # Mettre à jour le compteur de ce worker
      prev = Map.get(state.workers, worker_node, 0)
      new_worker_count = max(0, prev - completed_count)
      workers1 = Map.put(state.workers, worker_node, new_worker_count)
      state1 = %{state | workers: workers1}

      # Vérifier si TOUS les workers ont 0 en vol ET queue vide
      if state1.queue == [] and all_idle?(workers1) do
        Logger.info("Job #{state.job_id} terminé ✓")
        HashCluster.MnesiaStore.update_job(state.job_id,
          status: :done, finished_at: DateTime.utc_now())
        HashCluster.CancelFlag.cleanup(state.job_id)
        {:reply, {:done, []}, %{state1 | status: :idle, job_id: nil, workers: %{}}}
      else
        case state1.queue do
          [] ->
            Logger.info("next_batch #{worker_node}: queue vide (in_flight global=#{total_in_flight(workers1)})")
            {:reply, {:wait, []}, state1}
          _ ->
            {batch, remaining} = Enum.split(state1.queue, @batch_size)
            workers2 = Map.update(workers1, worker_node, length(batch), &(&1 + length(batch)))
            state2 = %{state1 | queue: remaining, workers: workers2}
            Logger.info("next_batch #{worker_node}: #{length(batch)} fichiers " <>
              "(#{length(remaining)} restants, in_flight=#{total_in_flight(workers2)})")
            {:reply, {:ok, batch}, state2}
        end
      end
    end
  end

  # ---- handle_cast ----

  @impl true
  def handle_cast({:batch_done, _wn, _c}, %{status: s} = state) when s != :running,
    do: {:noreply, state}
  def handle_cast({:batch_done, worker_node, count}, state) do
    prev = Map.get(state.workers, worker_node, 0)
    workers1 = Map.put(state.workers, worker_node, max(0, prev - count))
    new_state = %{state | workers: workers1}
    Logger.info("batch_done #{worker_node}: in_flight=#{total_in_flight(workers1)}, queue=#{length(new_state.queue)}")

    if new_state.queue == [] and all_idle?(workers1) do
      Logger.info("Job #{state.job_id} terminé ✓ (batch_done)")
      HashCluster.MnesiaStore.update_job(state.job_id,
        status: :done, finished_at: DateTime.utc_now())
      HashCluster.CancelFlag.cleanup(state.job_id)
      {:noreply, %{new_state | status: :idle, job_id: nil, workers: %{}}}
    else
      {:noreply, new_state}
    end
  end

  # ---- handle_info ----

  @impl true
  def handle_info(:initial_dispatch, state) do
    workers = get_workers()
    Logger.info("Workers disponibles (#{length(workers)}): #{inspect(workers)}")
    # Dispatcher @prefetch batches par worker d'emblée pour éviter la famine
    new_state = Enum.reduce(workers, state, fn wn, acc ->
      Enum.reduce(1..@prefetch, acc, fn _, s -> send_batch_to(wn, s) end)
    end)
    Logger.info("Après dispatch initial: queue=#{length(new_state.queue)}, in_flight=#{total_in_flight(new_state.workers)}")
    {:noreply, new_state}
  end

  def handle_info({:new_worker, worker_node}, state) do
    Logger.info("Nouveau worker: #{worker_node} | status=#{state.status} | queue=#{length(state.queue)}")
    if state.status == :running and state.queue != [] do
      # Donner @prefetch batches au nouveau worker
      new_state = Enum.reduce(1..@prefetch, state, fn _, s -> send_batch_to(worker_node, s) end)
      {:noreply, new_state}
    else
      {:noreply, state}
    end
  end

  # ---- Helpers ----

  defp all_idle?(workers), do: Enum.all?(workers, fn {_, count} -> count == 0 end)

  defp total_in_flight(workers), do: Enum.sum(Map.values(workers))

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
    workers = Map.update(state.workers, worker_node, length(batch), &(&1 + length(batch)))
    %{state | queue: remaining, workers: workers}
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
    directory
    |> Path.expand()
    |> Path.join("**/*")
    |> Path.wildcard()
    |> Enum.filter(&File.regular?/1)
  end
end
