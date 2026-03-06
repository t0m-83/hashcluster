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

  # Fichiers normaux : 8 en parallèle, timeout 2 min
  @concurrency_normal   8
  @timeout_normal       120_000

  # Gros fichiers (> 512 Mo) : 2 en parallèle, timeout calculé dynamiquement
  # Base : 60s + 1s par 10 Mo, plafonné à 2h
  @large_file_threshold 512 * 1024 * 1024   # 512 Mo
  @concurrency_large    2
  @timeout_large_base   60_000
  @timeout_large_per_mb 1_000               # +1s par 10 Mo
  @timeout_large_max    7_200_000           # 2h max

  def process_batch(job_id, files, master_node, coordinator_node) do
    Logger.info("[#{node()}] Batch #{length(files)} fichiers")
    do_process_batch(job_id, files, master_node, coordinator_node)
  end

  defp do_process_batch(job_id, files, master_node, coordinator_node) do
    # Séparer petits et gros fichiers
    {large, normal} = Enum.split_with(files, &large_file?/1)

    Logger.info("[#{node()}] #{length(normal)} normaux, #{length(large)} gros fichiers")

    # Traiter les fichiers normaux en parallèle (8 concurrents, timeout 2min)
    process_group(normal, job_id, master_node, :normal)

    # Traiter les gros fichiers avec pool réduit et timeout dynamique
    process_group(large, job_id, master_node, :large)

    if HashCluster.CancelFlag.cancelled?(job_id) do
      :rpc.call(master_node, HashCluster.Coordinator, :batch_done,
                [node(), length(files)], 10_000)
    else
      fetch_next(job_id, files, master_node, master_node)
    end
  rescue
    e ->
      Logger.error("[#{node()}] process_batch crash: #{Exception.message(e)}")
      :rpc.call(master_node, HashCluster.Coordinator, :batch_done,
                [node(), length(files)], 10_000)
  catch
    kind, reason ->
      Logger.error("[#{node()}] process_batch throw #{kind}: #{inspect(reason)}")
      :rpc.call(master_node, HashCluster.Coordinator, :batch_done,
                [node(), length(files)], 10_000)
  end

  # Traite un groupe de fichiers avec les paramètres adaptés à leur taille
  defp process_group([], _job_id, _master_node, _type), do: :ok
  defp process_group(files, job_id, master_node, type) do
    {concurrency, timeout} = case type do
      :normal -> {@concurrency_normal, @timeout_normal}
      :large  -> {@concurrency_large,  max_timeout(files)}
    end

    files
    |> Task.async_stream(
      fn file_path ->
        if HashCluster.CancelFlag.cancelled?(job_id) do
          :cancelled
        else
          process_file(file_path, job_id, master_node)
        end
      end,
      max_concurrency: concurrency,
      timeout: timeout,
      on_timeout: :kill_task,
      ordered: true
    )
    |> Enum.zip(files)
    |> Enum.each(fn
      {{:ok, _}, _}              -> :ok
      {{:exit, :timeout}, path}  ->
        name = Path.basename(path)
        size_mb = file_size_mb(path)
        t = if type == :large, do: div(large_timeout(path), 1000), else: div(@timeout_normal, 1000)
        Logger.warning("[#{node()}] ⏱ timeout #{name} (#{size_mb} Mo) — timeout=#{t}s")
        :rpc.call(master_node, HashCluster.MnesiaStore, :save_error_and_increment,
                  [path, name, :timeout, node(), job_id], 30_000)
      {{:exit, reason}, path} ->
        name = Path.basename(path)
        Logger.warning("[#{node()}] ✗ exit #{inspect(reason)}: #{name}")
        :rpc.call(master_node, HashCluster.MnesiaStore, :save_error_and_increment,
                  [path, name, :error, node(), job_id], 30_000)
    end)
  end

  defp process_file(file_path, job_id, master_node) do
    name = Path.basename(file_path)
    size_mb = file_size_mb(file_path)
    if size_mb > 512 do
      Logger.info("[#{node()}] 📦 Gros fichier: #{name} (#{size_mb} Mo), timeout=#{div(large_timeout(file_path), 1000)}s")
    end
    case compute_hash(file_path) do
      {:ok, hash} ->
        :rpc.call(master_node, HashCluster.MnesiaStore, :save_file_and_increment,
                  [file_path, name, hash, node(), job_id], 30_000)
      {:error, :permission_denied} ->
        Logger.info("[#{node()}] ⛔ #{name}: droits insuffisants")
        :rpc.call(master_node, HashCluster.MnesiaStore, :save_error_and_increment,
                  [file_path, name, :permission_denied, node(), job_id], 30_000)
      {:error, reason} ->
        Logger.warning("[#{node()}] ✗ #{name}: #{inspect(reason)}")
        :rpc.call(master_node, HashCluster.MnesiaStore, :save_error_and_increment,
                  [file_path, name, :error, node(), job_id], 30_000)
    end
  end

  # Timeout dynamique : 60s de base + 1s par 10 Mo, max 2h
  defp large_timeout(path) do
    size_mb = file_size_mb(path)
    t = @timeout_large_base + size_mb * @timeout_large_per_mb
    min(t, @timeout_large_max)
  end

  # Pour Task.async_stream on a besoin d'un timeout unique par groupe —
  # on prend le max de tous les fichiers du groupe
  defp max_timeout([]),  do: @timeout_normal
  defp max_timeout(files), do: files |> Enum.map(&large_timeout/1) |> Enum.max()

  defp large_file?(path) do
    case :file.read_file_info(path, [{:time, :posix}]) do
      {:ok, info} -> elem(info, 1) >= @large_file_threshold
      _           -> false
    end
  end

  defp file_size_mb(path) do
    case :file.read_file_info(path, [{:time, :posix}]) do
      {:ok, info} -> div(elem(info, 1), 1024 * 1024)
      _           -> 0
    end
  end

  defp fetch_next(job_id, last_batch, master_node, coordinator_node) do
    do_fetch_next(job_id, length(last_batch), master_node, coordinator_node)
  end

  defp do_fetch_next(job_id, completed_count, master_node, coordinator_node) do
    case :rpc.call(coordinator_node, HashCluster.Coordinator, :next_batch,
                   [node(), completed_count], 30_000) do
      {:ok, next_batch} ->
        Logger.info("[#{node()}] Prochain batch: #{length(next_batch)} fichiers")
        process_batch(job_id, next_batch, master_node, coordinator_node)

      {:wait, []} ->
        Logger.info("[#{node()}] Attente (queue vide, job en cours)...")
        Process.sleep(500)
        do_fetch_next(job_id, 0, master_node, coordinator_node)

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
    e in File.Error ->
      if e.reason == :eacces, do: {:error, :permission_denied}, else: {:error, Exception.message(e)}
    e ->
      {:error, Exception.message(e)}
  end
end
