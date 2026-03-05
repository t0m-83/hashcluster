defmodule HashCluster.CancelFlag do
  @moduledoc """
  Flag d'annulation ultra-rapide basé sur :atomics.
  - Lecture O(1) sans message, sans GenServer, sans RPC
  - Sur le master : lecture directe depuis la mémoire partagée
  - Sur les workers distants : le master pousse le signal via Node.broadcast
    qui déclenche un handle_info dans ce GenServer sur chaque nœud worker
  """
  use GenServer
  require Logger

  @table :cancel_flag_refs  # ETS : {job_id => atomics_ref}

  def start_link(_), do: GenServer.start_link(__MODULE__, [], name: __MODULE__)

  # ---- API publique ----

  # Initialiser le flag pour un nouveau job (appelé par le Coordinator)
  def init_job(job_id) do
    ref = :atomics.new(1, signed: false)
    :atomics.put(ref, 1, 0)
    :ets.insert(@table, {job_id, ref})
    :ok
  end

  # Annuler un job : écriture locale + broadcast vers tous les workers distants
  def cancel(job_id) do
    # 1. Écrire localement dans atomics
    set_local(job_id, 1)
    # 2. Broadcaster le signal vers tous les nœuds connectés
    # (y compris ceux qui n'ont pas l'atomics_ref)
    Node.list() |> Enum.each(fn n ->
      :rpc.cast(n, HashCluster.CancelFlag, :receive_cancel, [job_id])
    end)
    :ok
  end

  # Vérification locale — appelée dans la hot path du worker
  # Retourne true si le job doit être annulé
  def cancelled?(job_id) do
    case :ets.lookup(@table, job_id) do
      [{^job_id, ref}] -> :atomics.get(ref, 1) == 1
      [] -> false
    end
  rescue
    _ -> false
  end

  # Appelé via rpc.cast depuis le master pour propager l'annulation
  def receive_cancel(job_id) do
    set_local(job_id, 1)
    Logger.info("[#{node()}] CancelFlag: job #{job_id} annulé")
  end

  # Nettoyage après un nouveau job (évite accumulation en mémoire)
  def cleanup(job_id) do
    :ets.delete(@table, job_id)
    Node.list() |> Enum.each(fn n ->
      :rpc.cast(n, :ets, :delete, [@table, job_id])
    end)
  end

  # ---- Internals ----

  defp set_local(job_id, value) do
    case :ets.lookup(@table, job_id) do
      [{^job_id, ref}] ->
        :atomics.put(ref, 1, value)
      [] ->
        # Créer un atomics local si le nœud n'en a pas encore
        ref = :atomics.new(1, signed: false)
        :atomics.put(ref, 1, value)
        :ets.insert(@table, {job_id, ref})
    end
  rescue
    _ -> :ok
  end

  @impl true
  def init(_) do
    :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])
    {:ok, %{}}
  end
end
