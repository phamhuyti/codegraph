#!/usr/bin/env bash
#
# Install CodeGraph from a local offline kit (no network required).
#
# Run this ON the air-gapped machine, from the kit directory produced by
# scripts/build-offline-kit.sh:
#
#   cd /path/to/codegraph-offline-kit
#   ./install-offline.sh
#
# Options:
#   --uninstall          Remove the offline install
#   --install-dir DIR    Bundle location (default: ~/.codegraph)
#   --bin-dir DIR        Symlink location (default: ~/.local/bin)
#   --target TARGET      Force platform (e.g. linux-x64); default: auto-detect
#
set -euo pipefail

INSTALL_DIR="${CODEGRAPH_INSTALL_DIR:-$HOME/.codegraph}"
BIN_DIR="${CODEGRAPH_BIN_DIR:-$HOME/.local/bin}"
FORCE_TARGET=""
UNINSTALL=0

while [ $# -gt 0 ]; do
  case "$1" in
    --uninstall) UNINSTALL=1; shift ;;
    --install-dir) INSTALL_DIR="$2"; shift 2 ;;
    --bin-dir) BIN_DIR="$2"; shift 2 ;;
    --target) FORCE_TARGET="$2"; shift 2 ;;
    -h|--help)
      sed -n '2,20p' "$0" | sed 's/^# \?//'
      exit 0
      ;;
    *) echo "install-offline: unknown arg: $1" >&2; exit 1 ;;
  esac
done

if [ "$UNINSTALL" = 1 ]; then
  rm -f "$BIN_DIR/codegraph"
  rm -rf "$INSTALL_DIR"
  echo "CodeGraph uninstalled (removed $INSTALL_DIR and $BIN_DIR/codegraph)."
  exit 0
fi

# Kit root = directory containing this script (or CWD if copied alone next to bundles/).
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
KIT_DIR="$SCRIPT_DIR"
if [ ! -d "$KIT_DIR/bundles" ]; then
  if [ -d "$PWD/bundles" ]; then
    KIT_DIR="$PWD"
  else
    echo "install-offline: no bundles/ next to this script or in \$PWD." >&2
    echo "  Copy the whole offline kit folder to this machine and run from inside it." >&2
    exit 1
  fi
fi

detect_target() {
  local os arch
  os="$(uname -s)"
  arch="$(uname -m)"
  case "$os" in
    Darwin) os="darwin" ;;
    Linux)  os="linux" ;;
    MINGW*|MSYS*|CYGWIN*) os="win32" ;;
    *) echo "install-offline: unsupported OS '$os'." >&2; exit 1 ;;
  esac
  case "$arch" in
    arm64|aarch64) arch="arm64" ;;
    x86_64|amd64)  arch="x64" ;;
    *) echo "install-offline: unsupported architecture '$arch'." >&2; exit 1 ;;
  esac
  echo "${os}-${arch}"
}

target="${FORCE_TARGET:-$(detect_target)}"
archive=""
for candidate in \
  "$KIT_DIR/bundles/codegraph-${target}.tar.gz" \
  "$KIT_DIR/bundles/codegraph-${target}.zip"
do
  if [ -f "$candidate" ]; then archive="$candidate"; break; fi
done

if [ -z "$archive" ]; then
  echo "install-offline: no bundle for target '${target}' in $KIT_DIR/bundles/" >&2
  echo "Available:" >&2
  ls -1 "$KIT_DIR/bundles" 2>/dev/null | sed 's/^/  /' >&2 || true
  exit 1
fi

version="offline"
if [ -f "$KIT_DIR/VERSION" ]; then
  version="$(tr -d '[:space:]' < "$KIT_DIR/VERSION")"
  case "$version" in v*) ;; *) version="v$version" ;; esac
fi

echo "Installing CodeGraph $version ($target) from local kit (offline)..."
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

dest="$INSTALL_DIR/versions/$version"
rm -rf "$dest"
mkdir -p "$dest"

case "$archive" in
  *.tar.gz)
    tar -xzf "$archive" -C "$tmp"
    # Archives contain a top-level codegraph-<target>/ dir; strip it.
    inner="$(find "$tmp" -mindepth 1 -maxdepth 1 -type d | head -n1)"
    # shellcheck disable=SC2086
    cp -R "$inner"/. "$dest"/
    ;;
  *.zip)
    if command -v unzip >/dev/null 2>&1; then
      unzip -q "$archive" -d "$tmp"
    else
      tar -xf "$archive" -C "$tmp"
    fi
    inner="$(find "$tmp" -mindepth 1 -maxdepth 1 -type d | head -n1)"
    cp -R "$inner"/. "$dest"/
    ;;
esac

mkdir -p "$BIN_DIR"
ln -sfn "$dest/bin/codegraph" "$BIN_DIR/codegraph"
mkdir -p "$INSTALL_DIR"
ln -sfn "$dest" "$INSTALL_DIR/current"

# Air-gapped defaults: never phone home (telemetry / update check).
mkdir -p "$INSTALL_DIR"
cat > "$INSTALL_DIR/offline-env.sh" <<'ENV'
# Sourced by optional shell profile snippet; also documented for MCP wrappers.
export DO_NOT_TRACK=1
export CODEGRAPH_TELEMETRY=0
export CODEGRAPH_NO_UPDATE_CHECK=1
ENV

# Persist telemetry off in the global preference file if the binary supports it.
if [ -x "$BIN_DIR/codegraph" ]; then
  # Prefer PATH that includes BIN_DIR for this call.
  PATH="$BIN_DIR:$PATH" codegraph telemetry off >/dev/null 2>&1 || true
fi

# Drop a tiny marker so operators can see this was an offline install.
cat > "$INSTALL_DIR/OFFLINE_INSTALL" <<META
installed_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)
version=$version
target=$target
kit=$KIT_DIR
META

case ":$PATH:" in
  *":$BIN_DIR:"*) ;;
  *)
    echo
    echo "Note: $BIN_DIR is not on your PATH."
    echo "  Add this to ~/.bashrc or ~/.zshrc:"
    echo "    export PATH=\"$BIN_DIR:\$PATH\""
    echo "    [ -f \"$INSTALL_DIR/offline-env.sh\" ] && . \"$INSTALL_DIR/offline-env.sh\""
    ;;
esac

echo
echo "✓ CodeGraph $version installed offline → $BIN_DIR/codegraph"
echo "  Telemetry / update-check disabled (DO_NOT_TRACK=1)."
echo
echo "Next (still offline):"
echo "  1. Open a new terminal (or source $INSTALL_DIR/offline-env.sh)"
echo "  2. codegraph install"
echo "  3. cd <your-repo> && codegraph init"
echo
echo "Uninstall:  $0 --uninstall"
