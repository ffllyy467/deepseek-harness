#!/usr/bin/env bash
# Start dsh web in the background; restart the running instance if present.
# Deployment values (trusted NAT hosts, workspace default path) come from the
# gitignored profile layer, so no flags are needed here.
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DSH_HOME_TARGET="${REPO_DIR}/.dsh"
WEB_PORT="${WEB_PORT:-3080}"
LOG_FILE="${DSH_HOME_TARGET}/logs/dsh_web.log"
BOOT_WAIT_SECS="${BOOT_WAIT_SECS:-45}"

say() { printf '\033[1;32m[start]\033[0m %s\n' "$*"; }
die() { printf '\033[1;31m[start] ERROR:\033[0m %s\n' "$*" >&2; exit 1; }

ensure_dsh_home() {
  # /root is per-container: keep ~/.dsh as a symlink into the shared disk.
  local link="$HOME/.dsh"
  if [ -L "$link" ]; then
    [ "$(readlink "$link")" = "$DSH_HOME_TARGET" ] && return 0
    rm "$link"
  elif [ -d "$link" ]; then
    mkdir -p "$DSH_HOME_TARGET"
    cp -a "$link/." "$DSH_HOME_TARGET/"
    rm -rf "$link"
  fi
  mkdir -p "$DSH_HOME_TARGET"
  ln -s "$DSH_HOME_TARGET" "$link"
}

stop_existing() {
  # The script's own cmdline is the script path, so this pattern cannot match
  # the shell running it — only the pnpm wrapper and the dsh node process.
  local pids
  pids="$(pgrep -f 'apps/cli/src/bin.ts' || true)"
  [ -z "$pids" ] && return 0
  say "stopping running dsh (pids: $(echo "$pids" | tr '\n' ' '))"
  echo "$pids" | xargs -r kill 2>/dev/null || true   # SIGTERM: graceful drain
  local i
  for i in $(seq 1 8); do
    pgrep -f 'apps/cli/src/bin.ts' >/dev/null 2>&1 || return 0
    sleep 1
  done
  say "process did not drain in 8s — sending SIGKILL"
  echo "$pids" | xargs -r kill -9 2>/dev/null || true
  sleep 1
}

start_server() {
  command -v pnpm >/dev/null 2>&1 || die "pnpm missing — run deploy/install.sh first"
  command -v curl >/dev/null 2>&1 || die "curl missing"
  mkdir -p "$(dirname "$LOG_FILE")"
  cd "$REPO_DIR"
  say "starting dsh web in the background (log: $LOG_FILE)"
  nohup pnpm dsh web >> "$LOG_FILE" 2>&1 &
  local i
  for i in $(seq 1 "$BOOT_WAIT_SECS"); do
    if curl -sf -o /dev/null "http://127.0.0.1:${WEB_PORT}/"; then
      say "dsh web is up: http://127.0.0.1:${WEB_PORT}"
      say "in the web IDE, open your VSCode forward to port ${WEB_PORT} (path prefix handled by the proxy)"
      return 0
    fi
    sleep 1
  done
  die "server did not come up within ${BOOT_WAIT_SECS}s — tail ${LOG_FILE}"
}

ensure_dsh_home
stop_existing
start_server
