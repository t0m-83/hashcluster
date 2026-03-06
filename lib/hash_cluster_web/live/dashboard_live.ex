defmodule HashClusterWeb.DashboardLive do
  use HashClusterWeb, :live_view
  require Logger

  # Intervalles adaptatifs selon l'état
  @refresh_active   500    # pendant une analyse : progression fluide
  @refresh_idle     10_000 # au repos : vérification minimale toutes les 10s
  @files_refresh    4_000  # liste fichiers : seulement quand visible et idle

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(HashCluster.PubSub, "dashboard")
      # Démarrer au rythme idle, s'accélérera si un job est actif
      Process.send_after(self(), :refresh, @refresh_idle)
      Process.send_after(self(), :refresh_files, @files_refresh)
    end

    {:ok,
     socket
     |> assign(:nodes, HashCluster.NodeMonitor.list_nodes())
     |> assign(:job, HashCluster.MnesiaStore.get_current_job())
     |> assign(:files, [])
     |> assign(:file_count, HashCluster.MnesiaStore.count_files())
     |> assign(:new_node, "")
     |> assign(:directory, "/tmp")
     |> assign(:search, "")
     |> assign(:show_files, false)
     |> assign(:files_loaded, false)}
  end

  # ---- handle_info ----

  @impl true
  def handle_info(:state_changed, socket) do
    job = HashCluster.MnesiaStore.get_current_job()
    was_running = is_running?(socket.assigns.job)

    cond do
      # Le job vient de se terminer normalement
      was_running && job && job.status == :done ->
        {:noreply,
         socket
         |> clear_flash()
         |> put_flash(:info, "✅ Analyse terminée — #{job.done} fichiers traités")
         |> assign(:job, job)
         |> assign(:show_files, true)
         |> assign(:files_loaded, true)
         |> assign(:files, HashCluster.MnesiaStore.list_files())
         |> assign(:file_count, HashCluster.MnesiaStore.count_files())}

      # Le job vient d'être arrêté manuellement
      was_running && job && job.status == :stopped ->
        {:noreply,
         socket
         |> assign(:job, job)
         |> assign(:show_files, true)
         |> assign(:files_loaded, true)
         |> assign(:files, HashCluster.MnesiaStore.list_files())
         |> assign(:file_count, HashCluster.MnesiaStore.count_files())}

      true ->
        {:noreply, assign(socket, :job, job)}
    end
  end

  def handle_info(:cluster_changed, socket) do
    {:noreply, assign(socket, :nodes, HashCluster.NodeMonitor.list_nodes())}
  end

  # Refresh adaptatif : rapide pendant une analyse, lent au repos
  def handle_info(:refresh, socket) do
    job = HashCluster.MnesiaStore.get_current_job()
    running = is_running?(job)
    # Intervalle selon l'état
    interval = if running, do: @refresh_active, else: @refresh_idle
    Process.send_after(self(), :refresh, interval)

    # Au repos sans changement : éviter d'envoyer un diff inutile au navigateur
    if not running and job == socket.assigns.job do
      {:noreply, socket}
    else
      {:noreply,
       socket
       |> assign(:nodes, HashCluster.NodeMonitor.list_nodes())
       |> assign(:job, job)
       |> assign(:file_count, HashCluster.MnesiaStore.count_files())}
    end
  end

  # Refresh fichiers : seulement si la liste est visible et que rien ne tourne
  def handle_info(:refresh_files, socket) do
    Process.send_after(self(), :refresh_files, @files_refresh)
    running = is_running?(socket.assigns.job)
    cond do
      # Analyse en cours : pas de liste à afficher, rien à faire
      running ->
        {:noreply, socket}
      # Liste déjà chargée et stable : ne plus recharger (économise CPU/RAM/WebSocket)
      socket.assigns.show_files and socket.assigns.files_loaded ->
        {:noreply, socket}
      # Liste visible mais pas encore chargée
      socket.assigns.show_files ->
        socket2 = assign(socket, :files, [])
        :erlang.garbage_collect(self())
        {:noreply, socket2
          |> assign(:files, HashCluster.MnesiaStore.list_files())
          |> assign(:files_loaded, true)}
      true ->
        {:noreply, socket}
    end
  end

  # ---- handle_event ----

  @impl true
  def handle_event("update_directory", %{"directory" => dir}, socket) do
    {:noreply, assign(socket, :directory, dir)}
  end

  def handle_event("start_job", _params, socket) do
    dir = socket.assigns.directory
    case HashCluster.Coordinator.start_job(dir) do
      :ok ->
        {:noreply,
         socket
         |> put_flash(:info, "Calcul démarré pour #{dir}")
         |> assign(:job, HashCluster.MnesiaStore.get_current_job())}
      {:error, :already_running} ->
        {:noreply, put_flash(socket, :error, "Un calcul est déjà en cours")}
      {:error, :directory_not_found} ->
        {:noreply, put_flash(socket, :error, "Répertoire introuvable : #{dir}")}
    end
  end

  def handle_event("stop_job", _params, socket) do
    HashCluster.Coordinator.stop_job()
    {:noreply,
     socket
     |> clear_flash()
     |> put_flash(:info, "⏹ Analyse arrêtée")
     |> assign(:job, HashCluster.MnesiaStore.get_current_job())
     |> assign(:show_files, true)
     |> assign(:files_loaded, true)
     |> assign(:files, HashCluster.MnesiaStore.list_files())
     |> assign(:file_count, HashCluster.MnesiaStore.count_files())}
  end

  def handle_event("clear_data", _params, socket) do
    HashCluster.MnesiaStore.clear_files()
    # Forcer le GC sur ce processus LiveView pour libérer @files de la mémoire
    :erlang.garbage_collect(self())
    {:noreply,
     socket
     |> clear_flash()
     |> put_flash(:info, "Données effacées")
     |> assign(:job, nil)
     |> assign(:files, [])
     |> assign(:file_count, 0)
     |> assign(:show_files, false)
     |> assign(:files_loaded, false)}
  end

  def handle_event("update_node", %{"node" => node}, socket) do
    {:noreply, assign(socket, :new_node, node)}
  end

  def handle_event("connect_node", _params, socket) do
    node_name = socket.assigns.new_node
    case HashCluster.NodeMonitor.connect_node(node_name) do
      {:ok, _} ->
        {:noreply,
         socket
         |> put_flash(:info, "Nœud #{node_name} connecté")
         |> assign(:new_node, "")
         |> assign(:nodes, HashCluster.NodeMonitor.list_nodes())}
      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Impossible de connecter #{node_name}")}
    end
  end

  def handle_event("disconnect_node", %{"node" => node}, socket) do
    HashCluster.NodeMonitor.disconnect_node(node)
    {:noreply,
     socket
     |> put_flash(:info, "Nœud #{node} déconnecté")
     |> assign(:nodes, HashCluster.NodeMonitor.list_nodes())}
  end

  def handle_event("search", %{"value" => q}, socket) do
    {:noreply, assign(socket, :search, q)}
  end
  def handle_event("search", params, socket) do
    q = Map.get(params, "value", Map.get(params, "search", ""))
    {:noreply, assign(socket, :search, q)}
  end
  def handle_event("clear_search", _params, socket) do
    {:noreply, assign(socket, :search, "")}
  end

  def handle_event("load_files", _params, socket) do
    {:noreply,
     socket
     |> assign(:show_files, true)
     |> assign(:files_loaded, true)
     |> assign(:files, HashCluster.MnesiaStore.list_files())
     |> assign(:file_count, HashCluster.MnesiaStore.count_files())}
  end

  def handle_event("export_json", _params, socket) do
    files = socket.assigns.files
    rows = Enum.map(files, fn f ->
      %{name: f.name, path: f.path, hash_sha256: f.hash, status: f.status,
        worker: to_string(f.worker_node), computed_at: fmt_dt(f.computed_at)}
    end)
    json = Jason.encode!(%{exported_at: DateTime.utc_now(), total: length(rows), files: rows}, pretty: true)
    now  = Calendar.strftime(DateTime.utc_now(), "%Y%m%d_%H%M%S")
    {:noreply, push_event(socket, "download_json", %{filename: "hashcluster_export_#{now}.json", content: json})}
  end

  # ---- Helpers ----

  defp filtered_files(files, ""), do: files
  defp filtered_files(files, q) do
    q = String.downcase(q)
    Enum.filter(files, fn f ->
      String.contains?(String.downcase(f.name || ""), q)
    end)
  end

  defp job_badge(nil), do: {"—", "badge-gray"}
  defp job_badge(%{status: :running}), do: {"⚡ En cours", "badge-blue"}
  defp job_badge(%{status: :done}),    do: {"✓ Terminé", "badge-green"}
  defp job_badge(%{status: :stopped}), do: {"⏹ Arrêté", "badge-yellow"}
  defp job_badge(%{status: :scanning}), do: {"🔍 Scan en cours…", "badge-blue"}
  defp job_badge(%{status: :pending}), do: {"⏳ En attente", "badge-gray"}
  defp job_badge(_), do: {"—", "badge-gray"}

  defp progress_pct(nil), do: 0
  defp progress_pct(%{total: 0}), do: 0
  defp progress_pct(%{done: done, total: total}), do: round(done / total * 100)

  defp fmt_dt(nil), do: "—"
  defp fmt_dt(%DateTime{} = dt), do: Calendar.strftime(dt, "%d/%m/%Y %H:%M:%S")
  defp fmt_dt(_), do: "—"

  defp is_running?(nil), do: false
  defp is_running?(%{status: :running}), do: true
  defp is_running?(%{status: :scanning}), do: true
  defp is_running?(_), do: false

  @impl true
  def render(assigns) do
    ~H"""
    <div style="max-width:1400px; margin:0 auto; padding:1.5rem;">

      <%!-- Header --%>
      <div style="display:flex; align-items:center; justify-content:space-between; margin-bottom:1.5rem;">
        <div>
          <h1 style="font-size:1.75rem; font-weight:700; background:linear-gradient(135deg,#60a5fa,#a78bfa); -webkit-background-clip:text; -webkit-text-fill-color:transparent;">
            🔐 HashCluster
          </h1>
          <p style="color:#94a3b8; font-size:0.875rem; margin-top:0.25rem;">Calcul distribué de hachages SHA-256</p>
        </div>
        <div style="display:flex; gap:0.5rem; align-items:center;">
          <span style="color:#94a3b8; font-size:0.75rem;">Nœud local :</span>
          <span class="badge badge-green" style="font-family:monospace; font-size:0.7rem;"><%= node() %></span>
        </div>
      </div>

      <%!-- Flash --%>
      <%= if msg = Phoenix.Flash.get(@flash, :info) do %>
        <div class="flash-success">ℹ️ <%= msg %></div>
      <% end %>
      <%= if msg = Phoenix.Flash.get(@flash, :error) do %>
        <div class="flash-error">⚠️ <%= msg %></div>
      <% end %>

      <%!-- Top grid --%>
      <div style="display:grid; grid-template-columns:1fr 1fr; gap:1rem; margin-bottom:1rem;">

        <%!-- Job Control --%>
        <div class="card">
          <h2 style="font-size:1rem; font-weight:700; margin-bottom:1rem; color:#f1f5f9;">⚙️ Contrôle du calcul</h2>

          <form phx-change="update_directory" style="margin-bottom:1rem;">
            <label style="font-size:0.75rem; color:#94a3b8; display:block; margin-bottom:0.35rem;">Répertoire à analyser</label>
            <input type="text" name="directory" class="input" value={@directory} placeholder="/chemin/vers/dossier" />
          </form>

          <div style="display:flex; gap:0.5rem; flex-wrap:wrap; margin-bottom:1rem;">
            <button class="btn btn-success" phx-click="start_job" disabled={is_running?(@job)}>▶ Démarrer</button>
            <button class="btn btn-danger"  phx-click="stop_job"  disabled={!is_running?(@job)}>⏹ Arrêter</button>
            <button class="btn btn-secondary" phx-click="clear_data">🗑 Effacer tout</button>
          </div>

          <%= if @job do %>
            <% {label, cls} = job_badge(@job) %>
            <% pct = progress_pct(@job) %>
            <div style="background:#0f172a; border-radius:8px; padding:1rem;">
              <div style="display:flex; justify-content:space-between; align-items:center; margin-bottom:0.5rem;">
                <span class={"badge #{cls}"}><%= label %></span>
                <span style="font-size:0.75rem; color:#94a3b8;"><%= @job.done %>/<%= @job.total %> fichiers</span>
              </div>
              <div class="progress-bar">
                <div class="progress-fill" style={"width:#{pct}%"}></div>
              </div>
              <div style="margin-top:0.5rem; font-size:0.75rem; color:#94a3b8; line-height:1.6;">
                <div>📁 <%= @job.directory %></div>
                <div>Démarré : <%= fmt_dt(@job.started_at) %></div>
                <%= if @job.finished_at do %>
                  <div>Terminé : <%= fmt_dt(@job.finished_at) %></div>
                <% end %>
              </div>
            </div>
          <% else %>
            <p style="color:#475569; font-size:0.875rem;">Aucun calcul en cours.</p>
          <% end %>
        </div>

        <%!-- Cluster --%>
        <div class="card">
          <h2 style="font-size:1rem; font-weight:700; margin-bottom:1rem; color:#f1f5f9;">🌐 Gestion du cluster</h2>

          <form phx-change="update_node" phx-submit="connect_node" style="margin-bottom:1rem;">
            <label style="font-size:0.75rem; color:#94a3b8; display:block; margin-bottom:0.35rem;">Connecter un worker (nom@host)</label>
            <div style="display:flex; gap:0.5rem;">
              <input type="text" name="node" class="input" value={@new_node} placeholder="worker1@192.168.1.20" />
              <button type="submit" class="btn btn-primary" disabled={@new_node == ""} style="white-space:nowrap;">+ Ajouter</button>
            </div>
          </form>

          <p style="font-size:0.75rem; color:#94a3b8; margin-bottom:0.5rem;">Nœuds actifs (<%= length(@nodes) %>)</p>
          <div style="display:flex; flex-direction:column; gap:0.5rem; max-height:220px; overflow-y:auto;">
            <%= for n <- @nodes do %>
              <div style="display:flex; justify-content:space-between; align-items:center; background:#0f172a; border-radius:8px; padding:0.5rem 0.75rem;">
                <span class={"badge #{if n == node(), do: "badge-green", else: "badge-blue"}"}
                  style="font-family:monospace; font-size:0.68rem;">
                  <%= if n == node(), do: "🏠 " %><%= n %>
                </span>
                <%= if n != node() do %>
                  <button class="btn btn-danger" style="padding:0.2rem 0.6rem; font-size:0.72rem;"
                    phx-click="disconnect_node" phx-value-node={n}>Retirer</button>
                <% end %>
              </div>
            <% end %>
          </div>
        </div>
      </div>

      <%!-- Stats — utilise file_count (O(1)) au lieu de length(@files) (O(n)) --%>
      <div style="display:grid; grid-template-columns:repeat(4,1fr); gap:1rem; margin-bottom:1rem;">
        <%= for {label, value, color} <- [
          {"Fichiers hashés", @file_count, "#60a5fa"},
          {"Nœuds actifs", length(@nodes), "#34d399"},
          {"Progression", "#{progress_pct(@job)}%", "#a78bfa"},
          {"État", if(@job, do: to_string(@job.status), else: "idle"), "#f9a8d4"}
        ] do %>
          <div class="card" style="text-align:center; padding:1rem;">
            <div style={"font-size:1.5rem; font-weight:700; color:#{color}"}><%= value %></div>
            <div style="font-size:0.75rem; color:#64748b; margin-top:0.25rem;"><%= label %></div>
          </div>
        <% end %>
      </div>

      <%!-- Files table --%>
      <div id="export-container" phx-hook="DownloadJson" class="card">
        <%= if is_running?(@job) do %>
          <%!-- Pendant l'analyse : afficher uniquement la progression, pas la table --%>
          <div style="text-align:center; padding:2rem; color:#94a3b8;">
            <div style="font-size:2.5rem; margin-bottom:1rem; animation: pulse 1.5s infinite;">⚙️</div>
            <p style="font-size:1rem; font-weight:600; color:#f1f5f9; margin-bottom:0.5rem;">
              <%= if @job && @job.status == :scanning, do: "Scan du répertoire en cours…", else: "Analyse en cours…" %>
            </p>
            <p style="font-size:0.85rem; margin-bottom:1.5rem;">
              <%= if @job && @job.status == :scanning do %>
                Comptage des fichiers, veuillez patienter…
              <% else %>
                <%= @file_count %> / <%= if @job, do: @job.total, else: "?" %> fichiers traités
              <% end %>
            </p>
            <p style="font-size:0.75rem; color:#475569;">
              La liste des fichiers sera affichée à la fin de l'analyse pour ne pas surcharger le navigateur.
            </p>
          </div>
        <% else %>
          <div style="display:flex; justify-content:space-between; align-items:center; margin-bottom:1rem;">
            <h2 style="font-size:1rem; font-weight:700; color:#f1f5f9;">
              📋 Fichiers analysés
            </h2>
            <div style="display:flex; align-items:center; gap:0.75rem;">
              <%= if not @show_files and @file_count > 0 do %>
                <button class="btn btn-primary"
                  style="font-size:0.8rem;"
                  phx-click="load_files">
                  📂 Afficher les <%= @file_count %> fichiers
                </button>
              <% end %>
              <button class="btn btn-secondary"
                style="font-size:0.8rem;"
                phx-click="export_json"
                disabled={@files == []}>
                ⬇ Exporter JSON
              </button>
              <%= if @show_files do %>
                <input
                  type="text"
                  id="search-input"
                  class="input"
                  style="max-width:280px;"
                  value={@search}
                  placeholder="🔍 Rechercher nom ou chemin…"
                  phx-change="search"
                  phx-keyup="search"
                  phx-debounce="100"
                />
                <%= if @search != "" do %>
                  <button type="button" class="btn btn-secondary"
                    style="padding:0.4rem 0.6rem; font-size:0.75rem;"
                    phx-click="clear_search">✕</button>
                <% end %>
              <% end %>
            </div>
          </div>

          <%= if not @show_files do %>
            <div style="text-align:center; padding:3rem; color:#475569;">
              <div style="font-size:2.5rem; margin-bottom:0.5rem;">📂</div>
              <%= if @file_count == 0 do %>
                <p>Aucun fichier analysé pour l'instant.</p>
                <p style="font-size:0.75rem; margin-top:0.25rem;">Démarrez un calcul pour voir les résultats ici.</p>
              <% else %>
                <p style="color:#94a3b8;"><%= @file_count %> fichiers disponibles.</p>
                <button class="btn btn-primary" style="margin-top:1rem;" phx-click="load_files">
                  📂 Afficher les fichiers
                </button>
              <% end %>
            </div>
          <% else %>
            <% display = filtered_files(@files, @search) %>
            <%= if display == [] do %>
              <div style="text-align:center; padding:2rem; color:#475569;">
                <p>Aucun résultat pour <strong style="color:#94a3b8;">"<%= @search %>"</strong></p>
              </div>
            <% else %>
              <div style="overflow-x:auto; max-height:500px; overflow-y:auto;">
                <table>
                  <thead style="position:sticky; top:0; background:#1e293b; z-index:1;">
                    <tr>
                      <th>Nom</th><th>Chemin</th><th>Hash SHA-256</th><th>Worker</th><th>Date</th>
                    </tr>
                  </thead>
                  <tbody>
                    <%= for f <- display do %>
                      <tr>
                        <td style="font-weight:500; color:#f1f5f9; max-width:160px; overflow:hidden; text-overflow:ellipsis; white-space:nowrap;"><%= f.name %></td>
                        <td style="font-family:monospace; font-size:0.73rem; color:#94a3b8; max-width:220px; overflow:hidden; text-overflow:ellipsis; white-space:nowrap;" title={f.path}><%= f.path %></td>
                        <td style="font-family:monospace; font-size:0.7rem;" title={f.hash}>
                          <%= cond do %>
                            <% f.status == :permission_denied -> %>
                              <span style="color:#f87171;">⛔ Droits insuffisants</span>
                            <% f.status == :timeout -> %>
                              <span style="color:#fb923c;">⏱ Timeout</span>
                            <% f.status == :error -> %>
                              <span style="color:#fb923c;">⚠ Erreur lecture</span>
                            <% f.hash != nil -> %>
                              <span style="color:#60a5fa;"><%= String.slice(f.hash, 0, 20) %>…</span>
                            <% true -> %>
                              <span style="color:#64748b;">—</span>
                          <% end %>
                        </td>
                        <td><span class="badge badge-blue" style="font-size:0.65rem; font-family:monospace;"><%= f.worker_node %></span></td>
                        <td style="font-size:0.75rem; color:#64748b; white-space:nowrap;"><%= fmt_dt(f.computed_at) %></td>
                      </tr>
                    <% end %>
                  </tbody>
                </table>
              </div>
              <div style="margin-top:0.75rem; font-size:0.75rem; color:#64748b;">
                <%= length(display) %> / <%= @file_count %> fichier(s)
                <%= if @search != "", do: " · filtre : \"#{@search}\"" %>
              </div>
            <% end %>
          <% end %>
        <% end %>
      </div>

    </div>
    """
  end
end
