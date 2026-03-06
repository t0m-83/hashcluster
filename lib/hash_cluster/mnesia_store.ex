defmodule HashCluster.MnesiaStore do
  require Logger

  @table_files :hash_files
  @table_jobs  :hash_jobs

  def setup do
    node = node()
    # Supprimer le schéma disque existant pour éviter de recharger
    # les anciennes données (disc_copies) au démarrage
    :mnesia.delete_schema([node])
    case :mnesia.create_schema([node]) do
      :ok -> Logger.info("Mnesia schema créé")
      {:error, {^node, {:already_exists, ^node}}} -> Logger.info("Mnesia schema existant")
      err -> Logger.warning("Mnesia schema: #{inspect(err)}")
    end
    :mnesia.start()
    # hash_files : toujours ram_copies — données recalculables, pas besoin de persistance
    # hash_jobs  : ram_copies aussi — on ne veut pas recharger 20k entrées au démarrage
    create_table(@table_files, [{:attributes, [:path, :name, :hash, :worker_node, :computed_at, :status]}, {:ram_copies, [node]}])
    create_table(@table_jobs,  [{:attributes, [:id, :directory, :status, :started_at, :finished_at, :total, :done]}, {:ram_copies, [node]}])
    Logger.info("Mnesia tables initialisées en ram_copies")
    :ok
  end

  defp create_table(name, opts) do
    case :mnesia.create_table(name, opts) do
      {:atomic, :ok} -> Logger.info("Table #{name} created")
      {:aborted, {:already_exists, ^name}} -> Logger.info("Table #{name} already exists")
      err -> Logger.warning("Table #{name}: #{inspect(err)}")
    end
  end

  # ---- Job operations ----

  def create_job(directory) do
    id = System.unique_integer([:positive, :monotonic])
    :mnesia.transaction(fn ->
      :mnesia.write({@table_jobs, id, directory, :pending, DateTime.utc_now(), nil, 0, 0})
    end)
    id
  end

  def update_job(id, updates) do
    :mnesia.transaction(fn ->
      case :mnesia.read(@table_jobs, id) do
        [{@table_jobs, ^id, dir, status, started, finished, total, done}] ->
          :mnesia.write({@table_jobs, id,
            dir,
            Keyword.get(updates, :status, status),
            Keyword.get(updates, :started_at, started),
            Keyword.get(updates, :finished_at, finished),
            Keyword.get(updates, :total, total),
            Keyword.get(updates, :done, done)})
        _ -> :ok
      end
    end)
    # Broadcaster uniquement pour les vrais changements d'état
    if Keyword.has_key?(updates, :status) do
      broadcast_now()
    end
  end

  def get_current_job do
    case :mnesia.transaction(fn ->
      :mnesia.select(@table_jobs, [{{@table_jobs, :_, :_, :_, :_, :_, :_, :_}, [], [:"$_"]}])
    end) do
      {:atomic, jobs} ->
        jobs |> Enum.map(&job_to_map/1) |> Enum.sort_by(& &1.id, :desc) |> List.first()
      _ -> nil
    end
  end

  defp job_to_map({@table_jobs, id, dir, status, started, finished, total, done}) do
    %{id: id, directory: dir, status: status, started_at: started,
      finished_at: finished, total: total, done: done}
  end

  # ---- File & counter operations ----

  def save_file(path, name, hash, worker_node) do
    :mnesia.transaction(fn ->
      :mnesia.write({@table_files, path, name, hash, worker_node, DateTime.utc_now(), :done})
    end)
    :ok
  end

  # Un seul appel RPC au lieu de deux (save_file + increment_done)
  # Réduit de moitié la latence réseau pour les workers distants
  def save_file_and_increment(path, name, hash, worker_node, job_id) do
    :mnesia.transaction(fn ->
      :mnesia.write({@table_files, path, name, hash, worker_node, DateTime.utc_now(), :done})
      case :mnesia.read(@table_jobs, job_id) do
        [{@table_jobs, ^job_id, dir, status, started, finished, total, done}] ->
          :mnesia.write({@table_jobs, job_id, dir, status, started, finished, total, done + 1})
        _ -> :ok
      end
    end)
    :ok
  end

  # Enregistre un fichier inaccessible et incrémente quand même le compteur
  def save_error_and_increment(path, name, status, worker_node, job_id) do
    :mnesia.transaction(fn ->
      :mnesia.write({@table_files, path, name, nil, worker_node, DateTime.utc_now(), status})
      case :mnesia.read(@table_jobs, job_id) do
        [{@table_jobs, ^job_id, dir, s, started, finished, total, done}] ->
          :mnesia.write({@table_jobs, job_id, dir, s, started, finished, total, done + 1})
        _ -> :ok
      end
    end)
    :ok
  end

  # Pas de broadcast — le LiveView poll toutes les 2s
  def increment_done(job_id) do
    :mnesia.transaction(fn ->
      case :mnesia.read(@table_jobs, job_id) do
        [{@table_jobs, ^job_id, dir, status, started, finished, total, done}] ->
          :mnesia.write({@table_jobs, job_id, dir, status, started, finished, total, done + 1})
        _ -> :ok
      end
    end)
    :ok
  end

  def list_files do
    case :mnesia.transaction(fn ->
      :mnesia.select(@table_files, [{{@table_files, :_, :_, :_, :_, :_, :_}, [], [:"$_"]}])
    end) do
      {:atomic, files} -> Enum.map(files, &file_to_map/1)
      _ -> []
    end
  end

  def count_files do
    :mnesia.table_info(@table_files, :size)
  rescue
    _ -> 0
  end

  def clear_files do
    # clear_table vide les données mais Mnesia garde la mémoire ETS allouée.
    # delete_table + recréer force la libération réelle de la RAM.
    node = node()
    :mnesia.delete_table(@table_files)
    :mnesia.delete_table(@table_jobs)
    create_table(@table_files, [{:attributes, [:path, :name, :hash, :worker_node, :computed_at, :status]}, {:ram_copies, [node]}])
    create_table(@table_jobs,  [{:attributes, [:id, :directory, :status, :started_at, :finished_at, :total, :done]}, {:ram_copies, [node]}])
    # GC global pour libérer les binaires orphelins
    for pid <- Process.list(), do: :erlang.garbage_collect(pid)
    broadcast_now()
  end

  defp file_to_map({@table_files, path, name, hash, worker, computed_at, status}) do
    %{path: path, name: name, hash: hash, worker_node: worker,
      computed_at: computed_at, status: status}
  end

  def add_node_to_schema(new_node) do
    :mnesia.change_config(:extra_db_nodes, [new_node])
    :mnesia.change_table_copy_type(:schema, new_node, :disc_copies)
    :mnesia.add_table_copy(@table_files, new_node, :disc_copies)
    :mnesia.add_table_copy(@table_jobs, new_node, :disc_copies)
  end

  def broadcast_now do
    Phoenix.PubSub.broadcast(HashCluster.PubSub, "dashboard", :state_changed)
  end
end


defmodule HashCluster.BroadcastThrottle do
  use GenServer
  def start_link(_), do: GenServer.start_link(__MODULE__, :idle, name: __MODULE__)
  def notify, do: :ok
  @impl true
  def init(state), do: {:ok, state}
end
