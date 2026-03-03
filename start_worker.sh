#!/usr/bin/env bash
# start_worker.sh — Lance un worker SANS copie du code source
# Le master pousse automatiquement les modules via le réseau Erlang
#
# Prérequis sur le worker : Elixir + Erlang installés (pas le projet)
# Usage : WORKER_NAME=worker1@192.168.1.2 MASTER_NODE=master@192.168.1.1 ./start_worker.sh

set -e

COOKIE="${CLUSTER_COOKIE:-hashcluster_secret}"
WORKER_NAME="${WORKER_NAME:-worker1@$(hostname -s)}"
MASTER_NODE="${MASTER_NODE:-master@localhost}"

echo "==> Worker: $WORKER_NAME"
echo "==> Master: $MASTER_NODE"
echo "==> Cookie: $COOKIE"
echo ""
echo "Le code sera poussé automatiquement par le master."

exec elixir \
  --name "$WORKER_NAME" \
  --cookie "$COOKIE" \
  --erl "+P 1000000" \
  -e "
    master = :\"$MASTER_NODE\"
    IO.puts(\"Connexion à \#{master}...\")

    case Node.connect(master) do
      true ->
        IO.puts(\"Connecté. En attente du chargement du code...\")
        # Le master va détecter la connexion via :nodeup et pousser le code
        # On attend indéfiniment
        Process.sleep(:infinity)

      false ->
        IO.puts(\"ERREUR: impossible de joindre \#{master}\")
        IO.puts(\"Vérifiez que le master est démarré et que le cookie est correct.\")
        System.halt(1)

      :ignored ->
        IO.puts(\"ERREUR: ce noeud n'est pas distribué (net_kernel non démarré ?)\")
        System.halt(1)
    end
  "
