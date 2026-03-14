#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
WORKFLOW_ARG="${1:-./elixir/WORKFLOW.notion.smoke.host-worker.md}"
IMAGE="${SYMPHONY_DOCKER_IMAGE:-elixir:1.19}"
SSH_KEY_PATH="${HOME}/.ssh/symphony_worker_ed25519"
SSH_CONFIG_PATH="${ROOT_DIR}/docker/symphony_ssh_config"
HOST_WORKFLOW_PATH="${ROOT_DIR}/${WORKFLOW_ARG#./}"
CONTAINER_WORKFLOW_PATH="/work/${WORKFLOW_ARG#./}"
ENV_FILE_PATH="${ROOT_DIR}/.env.notion.local"

if [ -f "${ENV_FILE_PATH}" ]; then
  # shellcheck disable=SC1090
  . "${ENV_FILE_PATH}"
fi

missing=0

for var in NOTION_API_KEY NOTION_DATA_SOURCE_ID; do
  if [ -z "${!var:-}" ]; then
    echo "Missing required environment variable: ${var}" >&2
    missing=1
  fi
done

if [ ! -f "${SSH_KEY_PATH}" ]; then
  echo "Missing SSH key: ${SSH_KEY_PATH}" >&2
  missing=1
fi

if [ ! -f "${SSH_CONFIG_PATH}" ]; then
  echo "Missing SSH config: ${SSH_CONFIG_PATH}" >&2
  missing=1
fi

if [ ! -f "${HOST_WORKFLOW_PATH}" ]; then
  echo "Missing workflow file: ${WORKFLOW_ARG}" >&2
  missing=1
fi

if [ "${missing}" -ne 0 ]; then
  exit 1
fi

cd "${ROOT_DIR}"

docker run --rm -it \
  -p 4103:4103 \
  -e NOTION_API_KEY \
  -e NOTION_DATA_SOURCE_ID \
  -e NOTION_ASSIGNEE \
  -e SYMPHONY_SSH_CONFIG=/run/secrets/symphony_ssh_config \
  -v "${ROOT_DIR}:/work" \
  -v "${SSH_KEY_PATH}:/run/secrets/symphony_worker_ed25519:ro" \
  -v "${SSH_CONFIG_PATH}:/run/secrets/symphony_ssh_config:ro" \
  -w /work/elixir \
  "${IMAGE}" \
  sh -lc '
    mix local.hex --force >/dev/null &&
    mix local.rebar --force >/dev/null &&
    mix deps.get &&
    mix build &&
    ./bin/symphony --i-understand-that-this-will-be-running-without-the-usual-guardrails '"${CONTAINER_WORKFLOW_PATH}"'
  '
