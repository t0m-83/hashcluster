#!/usr/bin/env bash
# start_master.sh — Lance le noeud maitre HashCluster
set -e

COOKIE="${CLUSTER_COOKIE:-hashcluster_secret}"
NODE_NAME="${MASTER_NODE:-master@$(hostname -s)}"
PORT="${PORT:-4000}"

export MNESIA_DIR="./mnesia_data/master"
mkdir -p "$MNESIA_DIR"
mkdir -p priv/static/assets

echo "==> Compilation des assets JS..."
mix esbuild default

echo ""
echo "==> Demarrage du noeud maitre: $NODE_NAME"
echo "==> Interface web: http://localhost:$PORT"
echo "==> Cookie: $COOKIE"

exec elixir \
  --name "$NODE_NAME" \
  --cookie "$COOKIE" \
  --erl "-mnesia dir '\"$MNESIA_DIR\"'" \
  -S mix phx.server
