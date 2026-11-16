#!/usr/bin/env bash
set -euo pipefail

WEB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../Web" && pwd)"
DESTINATION="${1:?Pass the StudyWeb directory inside the app bundle}"

if ! command -v npm >/dev/null || ! node -e 'process.exit(Number(process.versions.node.split(".")[0]) < 24 ? 1 : 0)'; then
  echo 'Building Study Web requires Node.js 24 or newer with npm.' >&2
  exit 1
fi

npm --prefix "$WEB_DIR" ci --no-audit --no-fund
npm --prefix "$WEB_DIR" run build
mkdir -p "$DESTINATION/licenses"
cp -R "$WEB_DIR/dist/." "$DESTINATION"
install -m 644 "$WEB_DIR/licenses/shadcn-ui.txt" "$DESTINATION/licenses/shadcn-ui.txt"
install -m 644 "$WEB_DIR/node_modules/@fontsource-variable/inter/LICENSE" "$DESTINATION/licenses/Inter.txt"
install -m 644 "$WEB_DIR/node_modules/@fontsource/pt-serif/LICENSE" "$DESTINATION/licenses/PT-Serif.txt"
