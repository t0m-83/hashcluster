#!/usr/bin/env bash
# start_worker.sh — Lance un noeud worker HashCluster
# Usage: WORKER_NAME=worker1@192.168.1.2 MASTER_NODE=master@192.168.1.1 ./start_worker.sh
set -e

COOKIE="${CLUSTER_COOKIE:-hashcluster_secret}"
WORKER_NAME="${WORKER_NAME:-worker1@$(hostname -s)}"
MASTER_NODE="${MASTER_NODE:-master@localhost}"

export MNESIA_DIR="./mnesia_data/${WORKER_NAME//@/_}"
mkdir -p "$MNESIA_DIR"
mkdir -p priv/static/assets

echo "==> Demarrage du worker: $WORKER_NAME"
echo "==> Noeud maitre: $MASTER_NODE"
echo "==> Cookie: $COOKIE"

# Connexion au master apres demarrage de l'application
connect_to_master() {
  sleep 2
  elixir --name "connector_$$@127.0.0.1" --cookie "$COOKIE" \
    -e "Node.connect(:\"$MASTER_NODE\") |> IO.inspect(label: \"connect\")" 2>/dev/null || true
}

exec elixir \
  --name "$WORKER_NAME" \
  --cookie "$COOKIE" \
  --erl "-mnesia dir '\"$MNESIA_DIR\"'" \
  -S mix run --no-halt \
  --eval "
    master = :\"$MASTER_NODE\"
    IO.puts(\"Tentative de connexion a #{master}...\")
    case Node.connect(master) do
      true -> IO.puts(\"Connecte au maitre: #{master}\")
      _    -> IO.puts(\"Connexion au maitre echouee - connecter manuellement via l'UI\")
    end
  "
