#!/usr/bin/env bash
#
# Build a transferable offline kit for air-gapped machines.
#
# Run this ON a machine WITH network (once). Copy the resulting folder/USB
# archive to air-gapped company machines and run install-offline.sh there —
# no npm, no GitHub, no Node.js required on the target.
#
# Usage:
#   ./scripts/build-offline-kit.sh                  # all common desktop targets
#   ./scripts/build-offline-kit.sh linux-x64        # one target
#   ./scripts/build-offline-kit.sh linux-x64 darwin-arm64
#
# Output:
#   release/offline-kit/                 # folder ready to copy
#   release/codegraph-offline-kit.tar.gz # single archive to USB / share drive
#
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

DEFAULT_TARGETS=(linux-x64 linux-arm64 darwin-arm64 darwin-x64 win32-x64 win32-arm64)
if [ "$#" -gt 0 ]; then
  TARGETS=("$@")
else
  TARGETS=("${DEFAULT_TARGETS[@]}")
fi

VERSION="$(node -p "require('./package.json').version" 2>/dev/null || echo "0.0.0")"
KIT="$ROOT/release/offline-kit"
BUNDLES="$KIT/bundles"

echo "==> Offline kit for CodeGraph v${VERSION}"
echo "    targets: ${TARGETS[*]}"

# 1. Dependencies + compile (needs network the first time for npm ci).
if [ ! -d node_modules ]; then
  echo "==> npm ci"
  npm ci
else
  echo "==> node_modules present — skipping npm ci (run npm ci yourself if deps changed)"
fi

echo "==> npm run build"
npm run build

# 2. Platform bundles (downloads official Node runtimes — needs network here).
mkdir -p "$BUNDLES"
for target in "${TARGETS[@]}"; do
  echo "==> build-bundle ${target}"
  bash "$ROOT/scripts/build-bundle.sh" "$target"
  for ext in tar.gz zip; do
    src="$ROOT/release/codegraph-${target}.${ext}"
    if [ -f "$src" ]; then
      cp -f "$src" "$BUNDLES/"
      echo "    copied $(basename "$src")"
    fi
  done
done

# 3. Offline installer + docs into the kit.
cp -f "$ROOT/scripts/install-offline.sh" "$KIT/install-offline.sh"
chmod +x "$KIT/install-offline.sh"
# Windows helper (PowerShell) — thin wrapper around extracting the zip.
cat > "$KIT/install-offline.ps1" <<'PS'
# Install CodeGraph from a local offline kit on Windows (no network).
param(
  [string]$InstallDir = $(Join-Path $env:USERPROFILE ".codegraph"),
  [string]$BinDir = $(Join-Path $env:USERPROFILE ".local\bin"),
  [string]$Target = ""
)
$ErrorActionPreference = "Stop"
$KitDir = $PSScriptRoot
if (-not (Test-Path (Join-Path $KitDir "bundles"))) {
  throw "No bundles/ folder next to this script. Copy the whole offline kit."
}
if (-not $Target) {
  $arch = if ($env:PROCESSOR_ARCHITECTURE -match "ARM64") { "arm64" } else { "x64" }
  $Target = "win32-$arch"
}
$zip = Join-Path $KitDir "bundles\codegraph-$Target.zip"
if (-not (Test-Path $zip)) { throw "Missing bundle: $zip" }
$version = "offline"
$verFile = Join-Path $KitDir "VERSION"
if (Test-Path $verFile) { $version = "v" + ((Get-Content $verFile -Raw).Trim().TrimStart("v")) }
$dest = Join-Path $InstallDir "versions\$version"
if (Test-Path $dest) { Remove-Item -Recurse -Force $dest }
New-Item -ItemType Directory -Force -Path $dest | Out-Null
$tmp = Join-Path $env:TEMP ("codegraph-offline-" + [guid]::NewGuid())
New-Item -ItemType Directory -Force -Path $tmp | Out-Null
try {
  Expand-Archive -Path $zip -DestinationPath $tmp -Force
  $inner = Get-ChildItem $tmp -Directory | Select-Object -First 1
  Copy-Item -Path (Join-Path $inner.FullName "*") -Destination $dest -Recurse -Force
} finally {
  Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue
}
New-Item -ItemType Directory -Force -Path $BinDir | Out-Null
$launcher = Join-Path $dest "bin\codegraph.cmd"
$link = Join-Path $BinDir "codegraph.cmd"
Copy-Item -Force $launcher $link
$current = Join-Path $InstallDir "current"
if (Test-Path $current) { Remove-Item -Force $current -Recurse -ErrorAction SilentlyContinue }
cmd /c mklink /J "$current" "$dest" | Out-Null
# Air-gapped env defaults
$envFile = Join-Path $InstallDir "offline-env.cmd"
@"
set DO_NOT_TRACK=1
set CODEGRAPH_TELEMETRY=0
set CODEGRAPH_NO_UPDATE_CHECK=1
"@ | Set-Content -Path $envFile -Encoding ASCII
Write-Host "Installed CodeGraph $version ($Target) -> $link"
Write-Host "Add $BinDir to PATH, then: codegraph install && cd <repo> && codegraph init"
Write-Host "Before running, set: DO_NOT_TRACK=1 CODEGRAPH_TELEMETRY=0 CODEGRAPH_NO_UPDATE_CHECK=1"
PS

printf '%s\n' "$VERSION" > "$KIT/VERSION"

cat > "$KIT/INSTALL.txt" <<EOF
CodeGraph offline kit — v${VERSION}
===================================

Máy build (có mạng) đã chạy scripts/build-offline-kit.sh.
Máy cty (KHÔNG mạng): chỉ cần thư mục này (USB / share nội bộ).

Cài trên Linux / macOS
----------------------
  cd codegraph-offline-kit   # hoặc thư mục giải nén
  ./install-offline.sh

Cài trên Windows
----------------
  Mở PowerShell trong thư mục kit:
  .\\install-offline.ps1

Sau khi cài (vẫn offline)
-------------------------
  export DO_NOT_TRACK=1 CODEGRAPH_TELEMETRY=0 CODEGRAPH_NO_UPDATE_CHECK=1
  # hoặc: source ~/.codegraph/offline-env.sh

  codegraph install
  cd /path/to/company-repo
  codegraph init

Gỡ cài
------
  ./install-offline.sh --uninstall

Bundles trong kit
-----------------
$(ls -1 "$BUNDLES" | sed 's/^/  /')

Lưu ý
-----
- Bundle đã gồm Node runtime — máy air-gap KHÔNG cần cài Node/npm.
- Không gọi GitHub / npm / telemetry khi chạy từ bản offline này
  (nếu set các biến môi trường ở trên).
- Index (.codegraph/) tạo local trên từng máy / từng repo.
EOF

# 4. Single USB archive.
ARCHIVE="$ROOT/release/codegraph-offline-kit-v${VERSION}.tar.gz"
rm -f "$ARCHIVE"
tar --no-xattrs -czf "$ARCHIVE" -C "$ROOT/release" offline-kit

echo
echo "✓ Offline kit ready"
echo "  folder:  $KIT"
echo "  archive: $ARCHIVE ($(du -h "$ARCHIVE" | cut -f1))"
echo
echo "Copy the archive (or the offline-kit/ folder) to air-gapped machines,"
echo "extract, then run ./install-offline.sh"
