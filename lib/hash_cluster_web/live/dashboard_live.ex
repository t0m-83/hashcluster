defmodule HashClusterWeb.DashboardLive do
  use HashClusterWeb, :live_view
  require Logger

  @refresh_interval 2_000

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(HashCluster.PubSub, "dashboard")
      Process.send_after(self(), :refresh, @refresh_interval)
    end

    {:ok,
     socket
     |> assign(:nodes, HashCluster.NodeMonitor.list_nodes())
     |> assign(:job, HashCluster.MnesiaStore.get_current_job())
     |> assign(:files, HashCluster.MnesiaStore.list_files())
     |> assign(:new_node, "")
     |> assign(:directory, "/tmp")
     |> assign(:search, "")}
  end

  # ---- handle_info : ne jamais écraser :search ni :directory ----

  @impl true
  def handle_info(:state_changed, socket) do
    {:noreply,
     socket
     |> assign(:job, HashCluster.MnesiaStore.get_current_job())
     |> assign(:files, HashCluster.MnesiaStore.list_files())}
  end

  def handle_info(:cluster_changed, socket) do
    {:noreply, assign(socket, :nodes, HashCluster.NodeMonitor.list_nodes())}
  end

  def handle_info(:refresh, socket) do
    Process.send_after(self(), :refresh, @refresh_interval)
    {:noreply,
     socket
     |> assign(:nodes, HashCluster.NodeMonitor.list_nodes())
     |> assign(:job, HashCluster.MnesiaStore.get_current_job())
     |> assign(:files, HashCluster.MnesiaStore.list_files())}
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
         |> assign(:job, HashCluster.MnesiaStore.get_current_job())
         |> assign(:files, HashCluster.MnesiaStore.list_files())}
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
     |> put_flash(:info, "Calcul arrêté")
     |> assign(:job, HashCluster.MnesiaStore.get_current_job())}
  end

  def handle_event("clear_data", _params, socket) do
    HashCluster.MnesiaStore.clear_files()
    {:noreply,
     socket
     |> put_flash(:info, "Données effacées")
     |> assign(:job, HashCluster.MnesiaStore.get_current_job())
     |> assign(:files, [])}
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

  # Recherche live : phx-keyup envoie {"key" => ..., "value" => ...}
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

  def handle_event("export_json", _params, socket) do
    files = socket.assigns.files

    rows = Enum.map(files, fn f ->
      %{
        name:        f.name,
        path:        f.path,
        hash_sha256: f.hash,
        worker:      to_string(f.worker_node),
        computed_at: fmt_dt(f.computed_at)
      }
    end)

    json    = Jason.encode!(%{exported_at: DateTime.utc_now(), total: length(rows), files: rows}, pretty: true)
    now     = Calendar.strftime(DateTime.utc_now(), "%Y%m%d_%H%M%S")
    filename = "hashcluster_export_#{now}.json"

    {:noreply, push_event(socket, "download_json", %{filename: filename, content: json})}
  end

  # ---- Helpers ----

  defp filtered_files(files, ""), do: files
  defp filtered_files(files, q) do
    q = String.downcase(q)
    Enum.filter(files, fn f ->
      String.contains?(String.downcase(f.name || ""), q) or
        String.contains?(String.downcase(f.path || ""), q)
    end)
  end

  defp job_badge(nil), do: {"—", "badge-gray"}
  defp job_badge(%{status: :running}), do: {"⚡ En cours", "badge-blue"}
  defp job_badge(%{status: :done}), do: {"✓ Terminé", "badge-green"}
  defp job_badge(%{status: :stopped}), do: {"⏹ Arrêté", "badge-yellow"}
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
              <button type="submit" class="btn btn-primary" disabled={@new_node == ""} style="white-space:nowrap;">
                + Ajouter
              </button>
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
                    phx-click="disconnect_node" phx-value-node={n}>
                    Retirer
                  </button>
                <% end %>
              </div>
            <% end %>
          </div>
        </div>
      </div>

      <%!-- Stats --%>
      <div style="display:grid; grid-template-columns:repeat(4,1fr); gap:1rem; margin-bottom:1rem;">
        <%= for {label, value, color} <- [
          {"Fichiers hashés", length(@files), "#60a5fa"},
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
        <div style="display:flex; justify-content:space-between; align-items:center; margin-bottom:1rem;">
          <h2 style="font-size:1rem; font-weight:700; color:#f1f5f9;">
            📋 Fichiers analysés
          </h2>
          <div style="display:flex; align-items:center; gap:0.75rem;">
            <button class="btn btn-secondary"
              style="font-size:0.8rem; display:flex; align-items:center; gap:0.4rem;"
              phx-click="export_json"
              disabled={@files == []}>
              ⬇ Exporter JSON
            </button>
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
                phx-click="clear_search">
                ✕
              </button>
            <% end %>
          </div>
        </div>

        <% display = filtered_files(@files, @search) %>

        <%= if @files == [] do %>
          <div style="text-align:center; padding:3rem; color:#475569;">
            <div style="font-size:2.5rem; margin-bottom:0.5rem;">📂</div>
            <p>Aucun fichier analysé pour l'instant.</p>
            <p style="font-size:0.75rem; margin-top:0.25rem;">Démarrez un calcul pour voir les résultats ici.</p>
          </div>
        <% else %>
          <%= if display == [] do %>
            <div style="text-align:center; padding:2rem; color:#475569;">
              <p>Aucun résultat pour <strong style="color:#94a3b8;">"<%= @search %>"</strong></p>
            </div>
          <% else %>
            <div style="overflow-x:auto; max-height:500px; overflow-y:auto;">
              <table>
                <thead style="position:sticky; top:0; background:#1e293b; z-index:1;">
                  <tr>
                    <th>Nom</th>
                    <th>Chemin</th>
                    <th>Hash SHA-256</th>
                    <th>Worker</th>
                    <th>Date</th>
                  </tr>
                </thead>
                <tbody>
                  <%= for f <- display do %>
                    <tr>
                      <td style="font-weight:500; color:#f1f5f9; max-width:160px; overflow:hidden; text-overflow:ellipsis; white-space:nowrap;">
                        <%= f.name %>
                      </td>
                      <td style="font-family:monospace; font-size:0.73rem; color:#94a3b8; max-width:220px; overflow:hidden; text-overflow:ellipsis; white-space:nowrap;" title={f.path}>
                        <%= f.path %>
                      </td>
                      <td style="font-family:monospace; font-size:0.7rem; color:#60a5fa;" title={f.hash}>
                        <%= String.slice(f.hash || "", 0, 20) %>…
                      </td>
                      <td>
                        <span class="badge badge-blue" style="font-size:0.65rem; font-family:monospace;">
                          <%= f.worker_node %>
                        </span>
                      </td>
                      <td style="font-size:0.75rem; color:#64748b; white-space:nowrap;">
                        <%= fmt_dt(f.computed_at) %>
                      </td>
                    </tr>
                  <% end %>
                </tbody>
              </table>
            </div>
            <div style="margin-top:0.75rem; font-size:0.75rem; color:#64748b;">
              <%= length(display) %> / <%= length(@files) %> fichier(s)
              <%= if @search != "", do: " · filtre : \"#{@search}\"" %>
            </div>
          <% end %>
        <% end %>
      </div>

    </div>
    """
  end
end
