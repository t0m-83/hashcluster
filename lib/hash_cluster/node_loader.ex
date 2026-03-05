defmodule HashCluster.NodeLoader do
  @moduledoc """
  Permet à un worker de rejoindre le cluster sans avoir le code source.
  Le master pousse tous les modules .beam nécessaires via le réseau Erlang.
  """
  require Logger

  def bootstrap_worker(worker_node) do
    case push_code_to(worker_node) do
      :ok ->
        # Utiliser rpc.cast : fire-and-forget, pas de lien de processus
        # Le supervisor démarré ne sera pas lié au processus RPC
        :rpc.cast(worker_node, HashCluster.NodeLoader, :start_worker_app, [])
        :ok
      err ->
        err
    end
  end

  def push_code_to(worker_node) do
    modules = modules_to_push()
    Logger.info("NodeLoader: push #{length(modules)} modules vers #{worker_node}")

    results = Enum.map(modules, fn mod ->
      case push_module(worker_node, mod) do
        :ok  -> {:ok, mod}
        err  -> {:error, mod, err}
      end
    end)

    errors = Enum.filter(results, &match?({:error, _, _}, &1))
    if errors == [] do
      Logger.info("NodeLoader: tous les modules chargés sur #{worker_node}")
      :ok
    else
      Logger.error("NodeLoader: échecs: #{inspect(errors)}")
      {:error, errors}
    end
  end

  # Exécuté sur le worker via rpc.cast — dans un processus indépendant,
  # sans lien avec quoi que ce soit sur le master
  def start_worker_app do
    Logger.info("[#{node()}] Démarrage de l'application worker...")

    Application.ensure_all_started(:crypto)
    Application.ensure_all_started(:logger)

    case Process.whereis(HashCluster.WorkerApp) do
      nil ->
        # Démarrer le Supervisor dans un processus détaché (spawn sans link)
        # pour qu'il survive indépendamment
        pid = spawn(fn ->
          Process.flag(:trap_exit, true)
          children = [{HashCluster.CancelFlag, []}, {HashCluster.WorkerSupervisor, []}]
          {:ok, sup} = Supervisor.start_link(children,
            strategy: :one_for_one, name: HashCluster.WorkerApp)
          Logger.info("[#{node()}] Worker prêt (supervisor: #{inspect(sup)})")
          # Garder ce processus vivant pour maintenir le Supervisor
          receive do
            {:stop} -> :ok
          end
        end)
        Process.register(pid, HashCluster.WorkerAppKeeper)
        :ok

      _pid ->
        Logger.info("[#{node()}] Worker déjà démarré")
        :ok
    end
  end

  # ---- Privé ----

  defp modules_to_push do
    worker_modules = [
      HashCluster.FileWorker,
      HashCluster.WorkerSupervisor,
      HashCluster.NodeLoader,
      HashCluster.MnesiaStore,
      HashCluster.CancelFlag,
      HashCluster.BroadcastThrottle,
    ]

    Enum.filter(worker_modules, fn mod ->
      case Code.ensure_loaded(mod) do
        {:module, _} -> true
        _ ->
          Logger.warning("Module #{mod} non trouvé localement")
          false
      end
    end)
  end

  defp push_module(worker_node, module) do
    {^module, beam_binary, filename} = :code.get_object_code(module)
    case :rpc.call(worker_node, :code, :load_binary,
                   [module, filename, beam_binary], 15_000) do
      {:module, ^module} -> :ok
      {:badrpc, reason}  -> {:error, reason}
      err                -> {:error, err}
    end
  end
end
