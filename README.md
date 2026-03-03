# HashCluster

Calcul distribué de hachages (SHA-256) de fichiers via un cluster Erlang/Elixir.

- **Backend** : Elixir + OTP (GenServer, Mnesia, distribution Erlang)
- **Frontend** : Phoenix LiveView (temps réel, pas de JS custom)
- **Persistance** : Mnesia (base de données distribuée intégrée à Erlang)

---

## Architecture

```
┌─────────────────────────────────────────────────────┐
│                    Nœud Maître                       │
│  Phoenix (UI) ──► Coordinator ──► WorkerSupervisor  │
│                        │                             │
│              ┌─────────┘                             │
│              ▼                                       │
│         MnesiaStore ◄──── FileWorker                │
└──────────────┬──────────────────────────────────────┘
               │ Erlang Distribution (TCP)
    ┌──────────┴──────────┐
    ▼                     ▼
┌──────────┐         ┌──────────┐
│ Worker 1 │         │ Worker 2 │
│FileWorker│         │FileWorker│
│  Mnesia  │         │  Mnesia  │
└──────────┘         └──────────┘
```

---

## Installation sur NixOS

### Prérequis

#### Option A — Avec Flakes (recommandé)

Activer les flakes dans `/etc/nixos/configuration.nix` :
```nix
nix.settings.experimental-features = [ "nix-command" "flakes" ];
```

Puis :
```bash
cd hashcluster
nix develop
```

#### Option B — Sans flakes (nix-shell)

Ajouter dans votre `configuration.nix` ou utiliser `nix-shell` :
```nix
environment.systemPackages = with pkgs; [
  elixir_1_16
  erlang_26
  inotify-tools
];
```

Ou créer un `shell.nix` :
```nix
{ pkgs ? import <nixpkgs> {} }:
pkgs.mkShell {
  buildInputs = with pkgs; [ elixir_1_16 erlang_26 inotify-tools ];
}
```
```bash
nix-shell
```

#### Option C — direnv (auto-activation)

```bash
nix-env -iA nixos.direnv
echo 'eval "$(direnv hook bash)"' >> ~/.bashrc  # ou zsh
direnv allow .
```

---

## Installation du projet

```bash
# 1. Installer les dépendances Hex
mix local.hex --force
mix local.rebar --force

# 2. Télécharger les dépendances
mix deps.get

# 3. Compiler
mix compile
```

---

## Démarrage

### Mode standalone (un seul PC)

```bash
chmod +x start_master.sh
./start_master.sh
```

L'interface web est disponible sur **http://localhost:4000**

### Mode cluster (maître + workers)

#### Sur la machine maître :
```bash
MASTER_NODE=master@192.168.1.10 CLUSTER_COOKIE=mon_secret ./start_master.sh
```

#### Sur chaque machine worker :
```bash
# Copier le projet sur le worker
rsync -av hashcluster/ user@192.168.1.20:~/hashcluster/
ssh user@192.168.1.20

# Sur le worker
cd hashcluster
mix deps.get && mix compile

WORKER_NAME=worker1@192.168.1.20 MASTER_NODE=master@192.168.1.10 CLUSTER_COOKIE=mon_secret ./start_worker.sh
```

#### Depuis l'interface web (maître) :
1. Aller sur http://localhost:4000
2. Dans **Gestion du cluster** → saisir `worker1@192.168.1.20`
3. Cliquer **+ Ajouter**
4. Le worker apparaît dans la liste des nœuds

---

## Utilisation

### Interface Web

| Zone | Description |
|------|-------------|
| **Contrôle du calcul** | Saisir le chemin, démarrer/arrêter le calcul |
| **Gestion du cluster** | Ajouter/retirer des workers distants |
| **Stats** | Nombre de fichiers, nœuds, progression |
| **Tableau des fichiers** | Nom, chemin complet, hash SHA-256, worker, date |

### Points importants

- **Cookie Erlang** : tous les nœuds du cluster doivent avoir le même cookie (`CLUSTER_COOKIE`)
- **Résolution DNS** : les nœuds doivent se résoudre mutuellement (éditer `/etc/hosts` si nécessaire)
- **Firewall** : le port EPMD (4369) et les ports dynamiques Erlang doivent être ouverts

### Configuration réseau NixOS

```nix
# /etc/nixos/configuration.nix
networking.firewall = {
  enable = true;
  allowedTCPPortRanges = [
    { from = 4369; to = 4369; }   # EPMD
    { from = 9000; to = 9100; }   # Erlang distribution
    { from = 4000; to = 4001; }   # Phoenix web
  ];
};
```

Pour forcer les ports Erlang :
```bash
ERL_DIST_PORT=9001 ./start_master.sh
```

---

## Variables d'environnement

| Variable | Défaut | Description |
|----------|--------|-------------|
| `MASTER_NODE` | `master@<hostname>` | Nom complet du nœud maître |
| `WORKER_NAME` | `worker1@<hostname>` | Nom complet du worker |
| `CLUSTER_COOKIE` | `hashcluster_secret` | Secret partagé du cluster |
| `PORT` | `4000` | Port HTTP Phoenix |
| `MNESIA_DIR` | `./mnesia_data/...` | Répertoire de persistance |

---

## Structure du projet

```
hashcluster/
├── lib/
│   └── hash_cluster/
│       ├── application.ex       # Supervision OTP
│       ├── mnesia_store.ex      # Persistance Mnesia
│       ├── coordinator.ex       # Distribution du travail
│       ├── workers.ex           # FileWorker (calcul SHA-256)
│       ├── node_monitor.ex      # Gestion du cluster
│       └── web/
│           ├── endpoint.ex      # Phoenix Endpoint
│           ├── router.ex        # Routes
│           ├── live/
│           │   └── dashboard_live.ex  # UI temps réel
│           └── components/
│               ├── core_components.ex
│               └── layouts/
├── config/
│   ├── config.exs
│   ├── dev.exs
│   └── prod.exs
├── mix.exs
├── flake.nix
├── start_master.sh
└── start_worker.sh
```

---

## Résolution de problèmes

### "noconnection" entre les nœuds
```bash
# Vérifier qu'EPMD tourne
epmd -names

# Tester la connectivité
erl -name test@192.168.1.10 -cookie mon_secret
# Dans iex: Node.connect(:"worker1@192.168.1.20")
```

### Mnesia ne démarre pas
```bash
rm -rf ./mnesia_data/
mix run --no-halt
```

### Recompiler proprement
```bash
mix deps.clean --all
mix deps.get
mix compile
```
