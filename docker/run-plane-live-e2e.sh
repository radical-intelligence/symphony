#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
ENV_FILE_PATH="${ROOT_DIR}/.env.plane.local"
DOCKERFILE_PATH="${ROOT_DIR}/docker/live-e2e-runner.Dockerfile"
DOCKER_IMAGE="${SYMPHONY_LIVE_E2E_DOCKER_IMAGE:-symphony-live-e2e-runner}"
HOST_HOME="${HOME}"
HOST_AUTH_JSON_PATH="${HOST_HOME}/.codex/auth.json"
RUNNER_HOME="${ROOT_DIR}/.live-e2e-home"
RUNNER_AUTH_JSON_PATH="${RUNNER_HOME}/.codex/auth.json"
RUNNER_TMPDIR="${ROOT_DIR}/.tmp/live-e2e"

if [ -f "${ENV_FILE_PATH}" ]; then
  set -a
  # shellcheck disable=SC1090
  . "${ENV_FILE_PATH}"
  set +a
fi

missing=0

for var in PLANE_API_KEY PLANE_WORKSPACE_SLUG; do
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
  exec mise exec -- make e2e-plane
fi

if command -v mix >/dev/null 2>&1; then
  exec make e2e-plane
fi

if command -v docker >/dev/null 2>&1; then
  if [ ! -S /var/run/docker.sock ]; then
    echo "Missing Docker socket: /var/run/docker.sock" >&2
    exit 1
  fi

  if [ ! -f "${HOST_AUTH_JSON_PATH}" ]; then
    echo "Missing Codex auth file: ${HOST_AUTH_JSON_PATH}" >&2
    exit 1
  fi

  mkdir -p "$(dirname "${RUNNER_AUTH_JSON_PATH}")" "${RUNNER_TMPDIR}"
  cp "${HOST_AUTH_JSON_PATH}" "${RUNNER_AUTH_JSON_PATH}"
  chmod 600 "${RUNNER_AUTH_JSON_PATH}"

  cleanup() {
    rm -rf "${RUNNER_HOME}" "${RUNNER_TMPDIR}"
  }

  trap cleanup EXIT

  docker build -f "${DOCKERFILE_PATH}" -t "${DOCKER_IMAGE}" "${ROOT_DIR}" >/dev/null

  docker run --rm -it \
    --add-host=host.docker.internal:host-gateway \
    -e PLANE_API_KEY \
    -e PLANE_WORKSPACE_SLUG \
    -e SYMPHONY_LIVE_PLANE_ENDPOINT \
    -e SYMPHONY_LIVE_DOCKER_WORKER_HOST=host.docker.internal \
    -e SYMPHONY_LIVE_PLANE_E2E_BACKEND=ssh \
    -e SYMPHONY_LIVE_SSH_WORKER_HOSTS \
    -e SYMPHONY_RUN_LIVE_PLANE_E2E=1 \
    -e HOME="${RUNNER_HOME}" \
    -e TMPDIR="${RUNNER_TMPDIR}" \
    -e MIX_HOME="${RUNNER_TMPDIR}/.mix" \
    -e HEX_HOME="${RUNNER_TMPDIR}/.hex" \
    -e MIX_BUILD_PATH="${RUNNER_TMPDIR}/_build" \
    -e MIX_DEPS_PATH="${RUNNER_TMPDIR}/deps" \
    -v /var/run/docker.sock:/var/run/docker.sock \
    -v "${ROOT_DIR}:${ROOT_DIR}" \
    -w "${ROOT_DIR}/elixir" \
    "${DOCKER_IMAGE}" \
    sh -lc '
      mix local.hex --force >/dev/null &&
      mix local.rebar --force >/dev/null &&
      mix deps.get >/dev/null &&
      mix test test/symphony_elixir/live_plane_e2e_test.exs
    '

  exit $?
fi

echo "Missing runtime: install mise, Elixir/mix, or Docker before running the Plane live e2e test." >&2
exit 1
