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

  # Traite un batch complet de fichiers, puis signale au Coordinator qu'il a terminé
  # et redemande immédiatement un nouveau batch (pull model)
  def process_batch(job_id, files, master_node, coordinator_node) do
    Logger.info("[#{node()}] Traitement batch #{length(files)} fichiers")

    Enum.each(files, fn file_path ->
      case compute_hash(file_path) do
        {:ok, hash} ->
          name = Path.basename(file_path)
          :rpc.call(master_node, HashCluster.MnesiaStore, :save_file,
                    [file_path, name, hash, node()], 30_000)
          :rpc.call(master_node, HashCluster.MnesiaStore, :increment_done,
                    [job_id], 30_000)
        {:error, reason} ->
          Logger.warning("✗ #{file_path}: #{inspect(reason)}")
      end
    end)

    # Signaler la fin du batch au Coordinator
    :rpc.call(coordinator_node, HashCluster.Coordinator, :batch_done,
              [node(), length(files)], 30_000)

    # Pull : demander immédiatement un nouveau batch
    case :rpc.call(coordinator_node, HashCluster.Coordinator, :request_batch,
                   [node()], 30_000) do
      {:ok, next_batch} when next_batch != [] ->
        Logger.info("[#{node()}] Nouveau batch reçu: #{length(next_batch)} fichiers")
        process_batch(job_id, next_batch, master_node, coordinator_node)

      _ ->
        Logger.info("[#{node()}] File épuisée, worker #{node()} en attente")
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
