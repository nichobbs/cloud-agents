#!/usr/bin/env bash
# Start the frontend Vite dev server for local development.
# Installs npm dependencies automatically if node_modules is absent.
#
# Usage:  ./scripts/dev.sh
#
# The dev server proxies /api/* to http://localhost:8080 by default (see
# frontend/vite.config.ts). Start the API server separately before sending
# real requests; the UI itself works without a backend for page navigation.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FRONTEND="$REPO_ROOT/frontend"

command -v node >/dev/null || { echo "dev: 'node' not on PATH" >&2; exit 1; }
command -v npm  >/dev/null || { echo "dev: 'npm' not on PATH"  >&2; exit 1; }

if [ ! -d "$FRONTEND/node_modules" ]; then
    echo "==> Installing frontend dependencies"
    npm --prefix "$FRONTEND" install
fi

echo "==> Starting frontend dev server → http://localhost:5173"
exec npm --prefix "$FRONTEND" run dev
