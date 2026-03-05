defmodule HashCluster.WorkerSupervisor do
  use Supervisor

  def start_link(_), do: Supervisor.start_link(__MODULE__, [], name: __MODULE__)

  def get_worker do
    if Code.ensure_loaded?(HashCluster.FileWorker), do: {:ok, :available}, else: {:error, :not_loaded}
  end

  @impl true
  def init(_), do: Supervisor.init([], strategy: :one_for_one)
end

defmodule HashCluster.FileWorker do
  require Logger

  @concurrency 8

  def process_batch(job_id, files, master_node, coordinator_node) do
    Logger.info("[#{node()}] Batch #{length(files)} fichiers")

    # Traitement parallèle — chaque tâche est indépendante
    files
    |> Task.async_stream(
      fn file_path ->
        unless HashCluster.CancelFlag.cancelled?(job_id) do
          case compute_hash(file_path) do
            {:ok, hash} ->
              name = Path.basename(file_path)
              case :rpc.call(master_node, HashCluster.MnesiaStore, :save_file_and_increment,
                             [file_path, name, hash, node(), job_id], 30_000) do
                {:badrpc, reason} ->
                  Logger.warning("[#{node()}] RPC save échoué #{Path.basename(file_path)}: #{inspect(reason)}")
                _ -> :ok
              end
            {:error, reason} ->
              Logger.warning("[#{node()}] ✗ #{Path.basename(file_path)}: #{inspect(reason)}")
          end
        end
      end,
      max_concurrency: @concurrency,
      timeout: 120_000,
      ordered: false
    )
    |> Enum.each(fn
      {:ok, _}       -> :ok
      {:exit, reason} -> Logger.warning("[#{node()}] Task exit: #{inspect(reason)}")
    end)

    # Signaler fin + demander le prochain batch en un seul appel
    if HashCluster.CancelFlag.cancelled?(job_id) do
      # Signaler la fin proprement même en cas d'annulation
      :rpc.call(coordinator_node, HashCluster.Coordinator, :batch_done,
                [node(), length(files)], 10_000)
    else
      fetch_next(job_id, files, master_node, coordinator_node)
    end
  end

  defp fetch_next(job_id, last_batch, master_node, coordinator_node) do
    case :rpc.call(coordinator_node, HashCluster.Coordinator, :next_batch,
                   [node(), length(last_batch)], 30_000) do
      {:ok, next_batch} ->
        Logger.info("[#{node()}] Prochain batch: #{length(next_batch)} fichiers")
        process_batch(job_id, next_batch, master_node, coordinator_node)

      {:wait, []} ->
        # D'autres workers ont encore des batches en vol — attendre et réessayer
        Logger.info("[#{node()}] Attente (queue vide, job en cours)...")
        Process.sleep(300)
        # Appel avec 0 pour ne pas re-décrémenter in_flight
        case :rpc.call(coordinator_node, HashCluster.Coordinator, :next_batch,
                       [node(), 0], 30_000) do
          {:ok, next_batch} ->
            process_batch(job_id, next_batch, master_node, coordinator_node)
          _ ->
            Logger.info("[#{node()}] Terminé sur #{node()}")
        end

      {:done, []} ->
        Logger.info("[#{node()}] Job terminé sur #{node()}")

      {:badrpc, reason} ->
        Logger.error("[#{node()}] RPC next_batch échoué: #{inspect(reason)}")
    end
  end

  defp compute_hash(path) do
    hash =
      File.stream!(path, [], 65_536)
      |> Enum.reduce(:crypto.hash_init(:sha256), fn chunk, acc ->
        :crypto.hash_update(acc, chunk)
      end)
      |> :crypto.hash_final()
      |> Base.encode16(case: :lower)
    {:ok, hash}
  rescue
    e -> {:error, Exception.message(e)}
  end
end
