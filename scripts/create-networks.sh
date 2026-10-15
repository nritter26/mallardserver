#!/usr/bin/env bash
# Stops all stacks in reverse dependency order. Volumes are kept.
# Usage:
#   ./scripts/down-all.sh               # stop every stack
#   ./scripts/down-all.sh ai-stack      # stop only these
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
COMPOSE_DIR="$ROOT/docker-compose"

DEFAULT_ORDER=(
  sftp-stack
  cloud-stack
  plane-stack
  ai-stack
  monitoring-stack
  auth-stack
  data-stack
  devops-stack
  vpn-stack
  dns-stack
)

if [ "$#" -gt 0 ]; then
  STACKS=("$@")
else
  STACKS=("${DEFAULT_ORDER[@]}")
fi

for stack in "${STACKS[@]}"; do
  dir="$COMPOSE_DIR/$stack"
  if [ ! -f "$dir/docker-compose.yml" ]; then
    echo "[missing] $stack"
    continue
  fi
  echo "[down]    $stack"
  (cd "$dir" && docker compose down)
done

echo "Done."
