#!/usr/bin/env bash
# One-click from-scratch install of dsh web behind a path-prefix proxy.
# Idempotent: safe to re-run at any time.
#
# Assumes the repo checkout is already present (it lives on the shared disk and
# survives container switches); this script installs everything else:
#   - the bwrap process sandbox (Linux only) — apt bubblewrap plus a
#     --unshare-user shim for containers without CAP_SYS_ADMIN
#   - Node/pnpm prerequisites
#   - workspace dependencies (pnpm install) and the web build (tsc + tsdown + Vite)
#   - the cross-container ~/.dsh home (symlink into the gitignored repo .dsh/)
#   - the web profile deployment layer (optional; see deployment values below)
#
# DEPLOYMENT VALUES are read from the environment or from the optional
# gitignored file deploy/deploy.env (copy deploy.env.example):
#   DSH_TRUSTED_HOSTS      space-separated authorities the /api trust fence admits
#   DSH_WORKSPACE_DEFAULT  absolute path the workspace picker opens at
# When both are unset the profile layer is skipped and dsh defaults apply
# (loopback-only fence, picker at the host home). Do not hardcode deployment
# values in this file.
#
# Start the server afterwards with: deploy/start.sh   (or: pnpm dsh web)
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DSH_HOME_TARGET="${REPO_DIR}/.dsh"                    # shared-disk DSH home (gitignored)
PNPM_VERSION=11.7.0
NODE_MIN_MAJOR=22
NODE_MIN_MINOR=19

# ── deployment values (env or gitignored deploy/deploy.env) ────────────────
if [ -f "${REPO_DIR}/deploy/deploy.env" ]; then
  # shellcheck disable=SC1091
  . "${REPO_DIR}/deploy/deploy.env"
fi
DSH_TRUSTED_HOSTS="${DSH_TRUSTED_HOSTS:-}"
DSH_WORKSPACE_DEFAULT="${DSH_WORKSPACE_DEFAULT:-}"

# ── helpers ─────────────────────────────────────────────────────────────────
say() { printf '\033[1;34m[install]\033[0m %s\n' "$*"; }
die() { printf '\033[1;31m[install] ERROR:\033[0m %s\n' "$*" >&2; exit 1; }

check_node() {
  command -v node >/dev/null 2>&1 || die "node not found — install Node >= ${NODE_MIN_MAJOR}.${NODE_MIN_MINOR} (nvm recommended)"
  local ver major minor
  ver="$(node --version | sed 's/^v//')"
  major="${ver%%.*}"
  minor="${ver#*.}"
  minor="${minor%%.*}"
  if [ "$major" -lt "$NODE_MIN_MAJOR" ] || { [ "$major" -eq "$NODE_MIN_MAJOR" ] && [ "$minor" -lt "$NODE_MIN_MINOR" ]; }; then
    die "node $ver is too old; the harness needs >= ${NODE_MIN_MAJOR}.${NODE_MIN_MINOR}"
  fi
  say "node $ver ok"
}

ensure_pnpm() {
  command -v pnpm >/dev/null 2>&1 && { say "pnpm $(pnpm --version) present"; return 0; }
  say "installing pnpm@${PNPM_VERSION} (npm global)"
  npm install --global "pnpm@${PNPM_VERSION}" || die "pnpm install failed — is the npm registry reachable?"
  say "pnpm installed"
}

find_real_bwrap() {
  # Resolve the binary the PATH shim must exec. `command -v bwrap` may return
  # the shim itself, so probe absolute-path candidates first.
  local shim='/usr/local/bin/bwrap' cand
  for cand in /usr/bin/bwrap /bin/bwrap "$(command -v bwrap 2>/dev/null || true)"; do
    if [ -n "$cand" ] && [ "$cand" != "$shim" ] && [ -x "$cand" ]; then
      printf '%s\n' "$cand"
      return 0
    fi
  done
  return 1
}

ensure_sandbox() {
  # The Linux sandbox chain probes bwrap first, then the Landlock launcher;
  # macOS (Seatbelt) and Windows (ACL runner) need no package, so this is a
  # no-op there. The probe argv is the one dsh-sandbox-local runs at startup.
  [ "$(uname -s)" = 'Linux' ] || { say "sandbox: non-Linux host — nothing to install"; return 0; }

  if ! command -v bwrap >/dev/null 2>&1; then
    command -v apt-get >/dev/null 2>&1 \
      || die "bwrap missing — install bubblewrap (apt-get install bubblewrap) or run a Landlock-enforcing kernel"
    say "installing bubblewrap via apt-get"
    apt-get update -y >/dev/null || die "apt-get update failed — is the apt mirror reachable?"
    apt-get install -y bubblewrap || die "bubblewrap install failed"
  else
    say "bwrap present ($(command -v bwrap))"
  fi

  local real
  real="$(find_real_bwrap)" || die "bwrap present but no real binary found on the system"

  if "$real" --ro-bind / / --dev /dev --proc /proc --die-with-parent -- true >/dev/null 2>&1; then
    say "bwrap functional probe passed — no shim needed"
    return 0
  fi

  # Container without CAP_SYS_ADMIN: root bwrap skips the user namespace and
  # unshare(CLONE_NEWNS) fails with EPERM. A PATH shim prepending --unshare-user
  # makes the standard bwrap argv work; where plain bwrap already succeeds the
  # flag is a no-op difference.
  if [ -e /usr/local/bin/bwrap ]; then
    if /usr/local/bin/bwrap --ro-bind / / --dev /dev --proc /proc --die-with-parent -- true >/dev/null 2>&1; then
      say "bwrap shim already probes clean"
      return 0
    fi
    say "replacing broken bwrap shim at /usr/local/bin/bwrap"
    rm -f /usr/local/bin/bwrap
  fi
  [ -w /usr/local/bin ] \
    || die "bwrap fails its functional probe and /usr/local/bin is not writable — create the --unshare-user shim as root, or run a Landlock-enforcing kernel"
  {
    echo '#!/bin/sh'
    echo '# Container fallback wrapper for bubblewrap (generated by deploy/install.sh).'
    echo '# A container without CAP_SYS_ADMIN permits user namespaces, so bubblewrap'
    echo '# must create a user namespace before its mount namespace; running as root it'
    echo '# otherwise skips the user namespace and unshare(CLONE_NEWNS) fails with EPERM.'
    echo '# Prepending --unshare-user makes the standard bwrap invocation work here, and'
    echo '# is a no-op difference where plain bwrap already succeeds.'
    echo "exec '$real' --unshare-user \"\$@\""
  } > /usr/local/bin/bwrap
  chmod 0755 /usr/local/bin/bwrap
  if ! /usr/local/bin/bwrap --ro-bind / / --dev /dev --proc /proc --die-with-parent -- true >/dev/null 2>&1; then
    die "bwrap still fails its functional probe with the --unshare-user shim — user namespaces may be disabled"
  fi
  say "wrote --unshare-user shim (plain bwrap cannot create its mount namespace here)"
}

ensure_dsh_home() {
  # The home directory is per-container: keep ~/.dsh as a symlink into the
  # shared disk so profiles, sessions, and credentials survive container switches.
  local link="$HOME/.dsh"
  if [ -L "$link" ]; then
    if [ "$(readlink "$link")" = "$DSH_HOME_TARGET" ]; then return 0; fi
    say "repointing stale ~/.dsh symlink"
    rm "$link"
  elif [ -d "$link" ]; then
    say "merging container-local ~/.dsh into the shared home"
    mkdir -p "$DSH_HOME_TARGET"
    cp -a "$link/." "$DSH_HOME_TARGET/"
    rm -rf "$link"
  fi
  mkdir -p "$DSH_HOME_TARGET"
  ln -s "$DSH_HOME_TARGET" "$link"
  say "~/.dsh -> $DSH_HOME_TARGET"
}

ensure_profile_patch() {
  local patch="$DSH_HOME_TARGET/profiles/web/cordis.patch.yml"
  mkdir -p "$(dirname "$patch")"
  if [ -f "$patch" ]; then
    say "web profile patch already exists — leaving it"
    return 0
  fi
  if [ -z "$DSH_TRUSTED_HOSTS" ] && [ -z "$DSH_WORKSPACE_DEFAULT" ]; then
    say "no deployment values set (DSH_TRUSTED_HOSTS / DSH_WORKSPACE_DEFAULT) — skipping profile layer"
    return 0
  fi
  local hosts=""
  local h
  for h in $DSH_TRUSTED_HOSTS; do hosts="${hosts}'${h}', "; done
  hosts="${hosts%, }"
  {
    echo "# Web profile deployment layer (generated by deploy/install.sh — gitignored)."
    echo "# One-click: \`pnpm dsh web\` needs no flags; every deployment value lives here."
    if [ -n "$DSH_WORKSPACE_DEFAULT" ]; then
      echo "- id: directory-picker"
      echo "  config:"
      echo "    defaultPath: ${DSH_WORKSPACE_DEFAULT}"
    fi
    if [ -n "$hosts" ]; then
      # The proxy authority also feeds webRuntime.trustedHosts (the web-runtime
      # row declares webStartup in inject, so the !!js here is legal) — every
      # fence that reads webRuntime (official /api, ssh, aionui, better-sidebar)
      # admits it from one place.
      echo "- id: web-runtime"
      echo "  config:"
      echo "    printUrl: true"
      echo "    surfaceContext: true"
      echo "    trustedHosts: !!js ctx.webStartup.trustedHosts.concat([${hosts}])"
      echo "- id: connection"
      echo "  config:"
      echo "    trustedHosts: !!js ctx.webRuntime.trustedHosts.concat([${hosts}])"
      echo "    privilegedHosts: !!js ctx.webRuntime.explicitTrustedHosts.concat([${hosts}])"
      # The dsh-web-ui family plugins run their own loopback fence (socket +
      # Host); feed them the same proxy authorities so their routes are
      # reachable through the path-prefix proxy while the socket stays
      # loopback. Literal arrays: the loader's !!js config evaluation cannot
      # reach webRuntime without the row declaring it in inject.
      echo "- id: ssh"
      echo "  config:"
      echo "    trustedHosts: [${hosts}]"
      # aionui right panel disabled while dsh-better-sidebar owns the right
      # side (visual overlap; remove the line to re-enable).
      echo "- id: ui-dsh-aionui-panel"
      echo "  disabled: true"
      echo "  config:"
      echo "    trustedHosts: [${hosts}]"
    fi
  } > "$patch"
  say "wrote web profile patch from deployment values"
}

needs_build() {
  local dist_html="$REPO_DIR/apps/web/dist/index.html"
  [ -f "$dist_html" ] || return 0
  local newer
  newer="$(find "$REPO_DIR/packages" "$REPO_DIR/apps" -type f \
    \( -name '*.ts' -o -name '*.tsx' -o -name '*.yml' -o -name '*.html' \) \
    -newer "$dist_html" -print -quit 2>/dev/null || true)"
  [ -n "$newer" ]
}

main() {
  cd "$REPO_DIR"
  say "repo: $REPO_DIR"
  ensure_sandbox
  check_node
  ensure_pnpm
  ensure_dsh_home
  ensure_profile_patch
  say "installing workspace dependencies (pnpm install)"
  pnpm install || die "pnpm install failed"
  if needs_build; then
    say "building (tsc + tsdown + web frontend)"
    pnpm run build || die "build failed"
  else
    say "build artifacts are up to date — skipping build"
  fi
  say "install complete. Start the server with: deploy/start.sh"
}

main "$@"
