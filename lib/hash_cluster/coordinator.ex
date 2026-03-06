defmodule HashCluster.Coordinator do
  use GenServer
  require Logger

  @batch_size 30
  @prefetch 3

  def start_link(_), do: GenServer.start_link(__MODULE__, %{}, name: __MODULE__)
  def start_job(directory), do: GenServer.call(__MODULE__, {:start_job, directory}, 30_000)
  def stop_job,             do: GenServer.call(__MODULE__, :stop_job, 5_000)
  def status,               do: GenServer.call(__MODULE__, :status)

  def next_batch(worker_node, completed_count) do
    GenServer.call(__MODULE__, {:next_batch, worker_node, completed_count}, 30_000)
  end

  def batch_done(worker_node, count) do
    GenServer.cast(__MODULE__, {:batch_done, worker_node, count})
  end

  @impl true
  def init(_) do
    {:ok, %{job_id: nil, status: :idle, queue: [], workers: %{},
            scan_total: 0, scan_done: false}}
  end

  # ---- handle_call ----

  @impl true
  def handle_call({:start_job, directory}, _from, state) do
    cond do
      state.status in [:running, :scanning] ->
        {:reply, {:error, :already_running}, state}
      not File.exists?(directory) ->
        {:reply, {:error, :directory_not_found}, state}
      true ->
        job_id = HashCluster.MnesiaStore.create_job(directory)
        HashCluster.MnesiaStore.update_job(job_id, status: :running, started_at: DateTime.utc_now())
        HashCluster.CancelFlag.init_job(job_id)
        coordinator = self()
        # Lancer le scan en streaming : envoie des batches au fur et à mesure
        # sans jamais accumuler toute la liste en mémoire
        spawn(fn -> stream_scan(directory, job_id, coordinator) end)
        new_state = %{state |
          job_id: job_id, status: :scanning,
          queue: [], workers: %{},
          scan_total: 0, scan_done: false}
        {:reply, :ok, new_state}
    end
  end

  @impl true
  def handle_call(:stop_job, _from, state) do
    if state.job_id do
      HashCluster.CancelFlag.cancel(state.job_id)
      HashCluster.MnesiaStore.update_job(state.job_id,
        status: :stopped, finished_at: DateTime.utc_now())
      Logger.info("Job #{state.job_id} annulé (was: #{state.status})")
    end
    {:reply, :ok, %{state | status: :idle, job_id: nil, queue: [],
                             workers: %{}, scan_total: 0, scan_done: false}}
  end

  @impl true
  def handle_call(:status, _from, state), do: {:reply, state.status, state}

  @impl true
  def handle_call({:next_batch, worker_node, completed_count}, _from, state) do
    if state.status not in [:running, :scanning] do
      {:reply, {:done, []}, state}
    else
      prev = Map.get(state.workers, worker_node, 0)
      workers1 = Map.put(state.workers, worker_node, max(0, prev - completed_count))
      state1 = %{state | workers: workers1}

      if check_done(state1) do
        {:reply, {:done, []}, finish_job(state1)}
      else
        case state1.queue do
          [] ->
            # Double vérification : si scan terminé et tous idle, c'est fini
            if check_done(state1) do
              {:reply, {:done, []}, finish_job(state1)}
            else
              Logger.info("wait: workers=#{inspect(workers1)}, scan_done=#{state1.scan_done}")
              {:reply, {:wait, []}, state1}
            end
          _ ->
            {batch, remaining} = Enum.split(state1.queue, @batch_size)
            workers2 = Map.update(workers1, worker_node, length(batch), &(&1 + length(batch)))
            state2 = %{state1 | queue: remaining, workers: workers2}
            {:reply, {:ok, batch}, state2}
        end
      end
    end
  end

  # ---- handle_cast ----

  @impl true
  def handle_cast({:batch_done, _wn, _c}, %{status: s} = state)
      when s not in [:running, :scanning], do: {:noreply, state}
  def handle_cast({:batch_done, worker_node, count}, state) do
    prev = Map.get(state.workers, worker_node, 0)
    workers1 = Map.put(state.workers, worker_node, max(0, prev - count))
    state1 = %{state | workers: workers1}
    if check_done(state1) do
      {:noreply, finish_job(state1)}
    else
      {:noreply, state1}
    end
  end

  # ---- handle_info ----

  # Le scanner envoie des micro-batches de fichiers trouvés au fil du scan
  @impl true
  def handle_info({:scan_files, job_id, files}, state) do
    if state.job_id != job_id or HashCluster.CancelFlag.cancelled?(job_id) do
      {:noreply, state}
    else
      new_total = state.scan_total + length(files)
      # Mettre à jour le total en base (approximatif pendant le scan)
      HashCluster.MnesiaStore.update_job(job_id, total: new_total)
      new_queue = state.queue ++ files

      # Si c'est le premier batch et qu'on n'a pas encore dispatché, démarrer
      state1 = if state.status == :scanning and length(new_queue) >= @batch_size do
        workers = get_workers()
        # Transition vers :running
        st = %{state | status: :running, queue: new_queue, scan_total: new_total}
        Logger.info("Premier dispatch (#{length(workers)} workers, #{new_total} fichiers scannés jusqu'ici)...")
        Enum.reduce(workers, st, fn wn, acc ->
          Enum.reduce(1..@prefetch, acc, fn _, s -> send_batch_to(wn, s) end)
        end)
      else
        %{state | queue: new_queue, scan_total: new_total}
      end

      {:noreply, state1}
    end
  end

  # Le scanner signale qu'il a fini
  def handle_info({:scan_complete, job_id, total}, state) do
    Logger.info("scan_complete reçu: job_id=#{job_id}, state.job_id=#{state.job_id}, total=#{total}, scan_done=#{state.scan_done}")
    if state.job_id != job_id do
      Logger.warning("scan_complete IGNORÉ: job_id mismatch #{job_id} != #{state.job_id}")
      {:noreply, state}
    else
      Logger.info("Scan complet: #{total} fichiers au total")
      HashCluster.MnesiaStore.update_job(job_id, total: total)

      state1 = %{state | scan_done: true, scan_total: total}

      # Si on était encore en :scanning (très peu de fichiers), démarrer maintenant
      state2 = if state1.status == :scanning do
        workers = get_workers()
        st = %{state1 | status: :running}
        Enum.reduce(workers, st, fn wn, acc ->
          Enum.reduce(1..@prefetch, acc, fn _, s -> send_batch_to(wn, s) end)
        end)
      else
        state1
      end

      # Vérifier si tout est déjà terminé (0 fichiers ou déjà traités)
      Logger.info("Après scan_complete: status=#{state2.status}, queue=#{length(state2.queue)}, workers=#{inspect(state2.workers)}, scan_done=#{state2.scan_done}")
      if check_done(state2) do
        {:noreply, finish_job(state2)}
      else
        {:noreply, state2}
      end
    end
  end

  def handle_info({:new_worker, worker_node}, state) do
    Logger.info("Nouveau worker: #{worker_node} | status=#{state.status} | queue=#{length(state.queue)}")
    if state.status == :running and state.queue != [] do
      new_state = Enum.reduce(1..@prefetch, state, fn _, s -> send_batch_to(worker_node, s) end)
      {:noreply, new_state}
    else
      {:noreply, state}
    end
  end

  # ---- Helpers ----

  defp check_done(%{scan_done: false}), do: false
  defp check_done(%{queue: q, workers: w} = state) do
    result = q == [] and all_idle?(w)
    if not result do
      Logger.info("check_done false: queue=#{length(q)}, workers=#{inspect(w)}, scan_done=#{state.scan_done}")
    end
    result
  end

  defp finish_job(state) do
    Logger.info("Job #{state.job_id} terminé ✓ (#{state.scan_total} fichiers)")
    HashCluster.MnesiaStore.update_job(state.job_id,
      status: :done, finished_at: DateTime.utc_now())
    HashCluster.CancelFlag.cleanup(state.job_id)
    %{state | status: :idle, job_id: nil, workers: %{},
              scan_total: 0, scan_done: false}
  end

  defp all_idle?(workers), do: Enum.all?(workers, fn {_, c} -> c == 0 end)

  defp send_batch_to(_wn, %{queue: []} = state), do: state
  defp send_batch_to(worker_node, state) do
    {batch, remaining} = Enum.split(state.queue, @batch_size)
    job_id = state.job_id
    master = node()
    coordinator = node()
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

  # Scan récursif en streaming — n'accumule JAMAIS toute la liste en mémoire.
  # Utilise :file.list_dir_all (NIF C, beaucoup plus léger que Path.wildcard)
  # et envoie des micro-batches au Coordinator au fur et à mesure.
  defp stream_scan(directory, job_id, coordinator) do
    try do
      {leftover, total} = scan_dir(Path.expand(directory), job_id, coordinator, [], 0)
      if leftover != [] do
        send(coordinator, {:scan_files, job_id, leftover})
      end
      Logger.info("stream_scan terminé: #{total} fichiers, envoi scan_complete")
      send(coordinator, {:scan_complete, job_id, total})
    rescue
      e ->
        Logger.error("stream_scan crash: #{Exception.message(e)}")
        send(coordinator, {:scan_complete, job_id, 0})
    catch
      kind, reason ->
        Logger.error("stream_scan throw #{kind}: #{inspect(reason)}")
        send(coordinator, {:scan_complete, job_id, 0})
    end
  end

  # Retourne {buffer, total_count}
  @scan_batch 500  # Taille des micro-batches envoyés au Coordinator pendant le scan
  defp scan_dir(dir, job_id, coordinator, buffer, total) do
    if HashCluster.CancelFlag.cancelled?(job_id) do
      {buffer, total}
    else
      case :file.list_dir_all(dir) do
        {:ok, entries} ->
          Enum.reduce(entries, {buffer, total}, fn entry, {buf, tot} ->
            path = Path.join(dir, entry)
            case :file.read_file_info(path, [{:time, :posix}]) do
              {:ok, info} when elem(info, 2) == :regular ->
                new_buf = [path | buf]
                new_tot = tot + 1
                # Envoyer un micro-batch quand le buffer est plein
                if length(new_buf) >= @scan_batch do
                  send(coordinator, {:scan_files, job_id, new_buf})
                  {[], new_tot}
                else
                  {new_buf, new_tot}
                end
              {:ok, info} when elem(info, 2) == :directory ->
                scan_dir(path, job_id, coordinator, buf, tot)
              _ ->
                {buf, tot}
            end
          end)
        {:error, reason} ->
          Logger.debug("Scan skip #{dir}: #{inspect(reason)}")
          {buffer, total}
      end
    end
  end
end
