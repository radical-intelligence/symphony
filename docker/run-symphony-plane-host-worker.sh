#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
WORKFLOW_ARG="${1:-./elixir/WORKFLOW.plane.md}"
IMAGE="${SYMPHONY_DOCKER_IMAGE:-elixir:1.19}"
CONTAINER_NAME="${SYMPHONY_CONTAINER_NAME:-symphony-plane-orchestrator}"
SSH_KEY_PATH="${SYMPHONY_SSH_KEY_PATH:-${HOME}/.ssh/symphony_worker_ed25519}"
SSH_CONFIG_PATH="${SYMPHONY_SSH_CONFIG_PATH:-${ROOT_DIR}/docker/symphony_ssh_config.local}"
HOST_WORKFLOW_PATH="${ROOT_DIR}/${WORKFLOW_ARG#./}"
CONTAINER_WORKFLOW_PATH="/work/${WORKFLOW_ARG#./}"
ENV_FILE_PATH="${ROOT_DIR}/.env.plane.local"

if [ -f "${ENV_FILE_PATH}" ]; then
  # shellcheck disable=SC1090
  set -a
  . "${ENV_FILE_PATH}"
  set +a
fi

if [ -z "${GH_TOKEN:-}" ] && [ -z "${GITHUB_TOKEN:-}" ] && command -v gh >/dev/null 2>&1; then
  detected_gh_token="$(gh auth token 2>/dev/null || true)"

  if [ -n "${detected_gh_token}" ]; then
    GH_TOKEN="${detected_gh_token}"
    export GH_TOKEN
  fi
fi

missing=0

for var in PLANE_API_KEY PLANE_WORKSPACE_SLUG PLANE_PROJECT_ID PROJECT_REPO_URL SYMPHONY_WORKSPACE_ROOT; do
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
  echo "Create it from ${ROOT_DIR}/docker/symphony_ssh_config.example or point SYMPHONY_SSH_CONFIG_PATH at your local file." >&2
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

if docker ps -a --format '{{.Names}}' | grep -Fxq "${CONTAINER_NAME}"; then
  docker rm -f "${CONTAINER_NAME}" >/dev/null
fi

docker run -d \
  --name "${CONTAINER_NAME}" \
  -p 4103:4103 \
  -e PLANE_API_KEY \
  -e PLANE_WORKSPACE_SLUG \
  -e PLANE_PROJECT_ID \
  -e PLANE_ASSIGNEE \
  -e PROJECT_REPO_URL \
  -e GH_TOKEN \
  -e GITHUB_TOKEN \
  -e SYMPHONY_WORKSPACE_ROOT \
  -e SYMPHONY_SSH_CONFIG=/run/secrets/symphony_ssh_config \
  -v "${ROOT_DIR}:/work" \
  -v "${SSH_KEY_PATH}:/run/secrets/symphony_worker_ed25519:ro" \
  -v "${SSH_CONFIG_PATH}:/run/secrets/symphony_ssh_config:ro" \
  -w /work/elixir \
  "${IMAGE}" \
  sh -lc "mix local.hex --force >/dev/null && \
    mix local.rebar --force >/dev/null && \
    mix deps.get && \
    mix build && \
    ./bin/symphony --i-understand-that-this-will-be-running-without-the-usual-guardrails ${CONTAINER_WORKFLOW_PATH}"

docker logs --tail 50 "${CONTAINER_NAME}"
