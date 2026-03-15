#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
ENV_FILE_PATH="${ROOT_DIR}/.env.plane.local"

if [ -f "${ENV_FILE_PATH}" ]; then
  set -a
  # shellcheck disable=SC1090
  . "${ENV_FILE_PATH}"
  set +a
fi

missing=0

for var in PLANE_API_KEY PLANE_WORKSPACE_SLUG PLANE_PROJECT_ID; do
  if [ -z "${!var:-}" ]; then
    echo "Missing required environment variable: ${var}" >&2
    missing=1
  fi
done

if [ "${missing}" -ne 0 ]; then
  echo "Create ${ENV_FILE_PATH} from .env.plane.local.example or export the variables in your shell." >&2
  exit 1
fi

cd "${ROOT_DIR}/elixir"

if command -v mise >/dev/null 2>&1; then
  exec mise exec -- mix plane.sync_states "$@"
fi

if command -v mix >/dev/null 2>&1; then
  exec mix plane.sync_states "$@"
fi

if command -v docker >/dev/null 2>&1; then
  exec docker run --rm \
    -u "$(id -u):$(id -g)" \
    -e PLANE_API_KEY \
    -e PLANE_WORKSPACE_SLUG \
    -e PLANE_PROJECT_ID \
    -e PLANE_ASSIGNEE \
    -e SYMPHONY_LIVE_PLANE_ENDPOINT \
    -e HOME=/tmp \
    -e MIX_HOME=/tmp/.mix \
    -e HEX_HOME=/tmp/.hex \
    -v "${ROOT_DIR}/elixir:/app" \
    -w /app \
    elixir:1.19 \
    sh -lc '
      mix local.hex --force >/dev/null &&
      mix local.rebar --force >/dev/null &&
      mix deps.get >/dev/null &&
      mix plane.sync_states "$@"
    ' sh "$@"
fi

echo "Missing runtime: install mise, Elixir/mix, or Docker before syncing Plane states." >&2
exit 1
