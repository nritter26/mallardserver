#!/usr/bin/env bash
# Starts all stacks in dependency order.
# Usage:
#   ./scripts/up-all.sh                 # start every stack
#   ./scripts/up-all.sh data-stack ai-stack   # start only these, in the order given
# Env:
#   SKIP="auth-stack"   space-separated stacks to skip
#   WAIT=5              seconds to pause between stacks
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
COMPOSE_DIR="$ROOT/docker-compose"
SKIP="${SKIP:-}"
WAIT="${WAIT:-5}"

DEFAULT_ORDER=(
  dns-stack
  vpn-stack
  devops-stack
  data-stack
  auth-stack
  monitoring-stack
  ai-stack
  plane-stack
  cloud-stack
  sftp-stack
)

if [ "$#" -gt 0 ]; then
  STACKS=("$@")
else
  STACKS=("${DEFAULT_ORDER[@]}")
fi

"$ROOT/scripts/create-networks.sh"

for stack in "${STACKS[@]}"; do
  dir="$COMPOSE_DIR/$stack"

  if [[ " $SKIP " == *" $stack "* ]]; then
    echo "[skip]    $stack (in SKIP)"
    continue
  fi
  if [ ! -f "$dir/docker-compose.yml" ]; then
    echo "[missing] $stack (no docker-compose.yml)"
    continue
  fi
  if [ ! -f "$dir/.env" ] && [ -f "$dir/.env.example" ]; then
    echo "[warn]    $stack has no .env - copy .env.example to .env and edit it"
    continue
  fi

  echo "[up]      $stack"
  (cd "$dir" && docker compose up -d)
  sleep "$WAIT"
done

echo "Done."
