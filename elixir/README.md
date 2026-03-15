# Symphony Elixir

This directory contains the current Elixir/OTP implementation of Symphony, based on
[`SPEC.md`](../SPEC.md) at the repository root.

> [!WARNING]
> Symphony Elixir is prototype software intended for evaluation only and is presented as-is.
> We recommend implementing your own hardened version based on `SPEC.md`.

## Screenshot

![Symphony Elixir screenshot](../.github/media/elixir-screenshot.png)

## How it works

1. Polls the configured tracker for candidate work
2. Creates a workspace per issue
3. Launches Codex in [App Server mode](https://developers.openai.com/codex/app-server/) inside the
   workspace
4. Sends a workflow prompt to Codex
5. Keeps Codex working on the issue until the work is done

Supported tracker adapters today:

- `linear`: polls a Linear project via GraphQL
- `plane`: polls a Plane project via the REST API
- `notion`: polls a Notion data source via the REST API
- `memory`: in-memory tracker for tests and local harnesses

During tracker-backed app-server sessions, Symphony also serves a client-side tool for raw tracker
access:

- `linear_graphql` for Linear workflows
- `plane_api` for Plane workflows
- `notion_api` for Notion workflows

If a claimed issue moves to a terminal state (`Done`, `Closed`, `Cancelled`, or `Duplicate`),
Symphony stops the active agent for that issue and cleans up matching workspaces.

## How to use it

1. Make sure your codebase is set up to work well with agents: see
   [Harness engineering](https://openai.com/index/harness-engineering/).
2. Choose your tracker credentials.
   - Linear: get a new personal token via Settings → Security & access → Personal API keys, and
     set it as the `LINEAR_API_KEY` environment variable.
   - Plane: create a Plane API key and set `PLANE_API_KEY`. Also set `PLANE_WORKSPACE_SLUG` and
     `PLANE_PROJECT_ID` for the workspace/project Symphony should manage. If you want Symphony to
     pick up only issues assigned to one Plane user, also set `PLANE_ASSIGNEE`. The bundled Plane
     templates also expect `PROJECT_REPO_URL`, and the host-worker helper expects
     `SYMPHONY_WORKSPACE_ROOT`.
   - Notion: create an internal integration, share the target data source with it, and set the
     integration token as the `NOTION_API_KEY` environment variable.
3. Copy this directory's `WORKFLOW.md` to your repo.
4. Optionally copy the `commit`, `push`, `pull`, `land`, and `linear` skills to your repo.
   - The `linear` skill expects Symphony's `linear_graphql` app-server tool for raw Linear GraphQL
     operations such as comment editing or upload flows.
5. Customize the copied `WORKFLOW.md` file for your project.
   - Linear:
     - To get your project's slug, right-click the project and copy its URL. The slug is part of
       the URL.
     - When creating a workflow based on this repo, note that it depends on non-standard Linear
       issue statuses: "Rework", "Human Review", and "Merging". You can customize them in
       Team Settings → Workflow in Linear.
   - Notion:
     - Set `tracker.kind: notion`.
     - Set `tracker.data_source_id` to the target Notion data source ID.
     - If you want Symphony to route only tasks assigned to a specific user, set
       `tracker.assignee` and `tracker.assignee_property`.
   - Plane:
     - Set `tracker.kind: plane`.
     - Set `tracker.workspace_slug` and `tracker.project_id` to the Plane workspace/project that
       Symphony should manage.
     - If you want Symphony to route only tasks assigned to a specific Plane user, set
       `tracker.assignee`.
     - Set `PROJECT_REPO_URL` in the shell or local env file used by the workflow helper so
       `hooks.after_create` can clone the repo under automation.
     - Set `workspace.root` directly or export `SYMPHONY_WORKSPACE_ROOT` for the bundled Plane
       templates.
     - The bundled Plane templates assume the review-loop states `Todo`, `In Progress`,
       `Human Review`, `Merging`, `Rework`, `Done`, and `Cancelled`. Either sync those states with
       `./docker/sync-plane-states.sh --with-review-loop` or customize the workflow state names to
       match your project.
     - Keep repo/project-specific values in local env files or copied local workflow files rather
       than editing the committed Plane templates in this repo.
6. Follow the instructions below to install the required runtime dependencies and start the service.

## Prerequisites

We recommend using [mise](https://mise.jdx.dev/) to manage Elixir/Erlang versions.

```bash
mise install
mise exec -- elixir --version
```

## Run

```bash
git clone https://github.com/openai/symphony
cd symphony/elixir
mise trust
mise install
mise exec -- mix setup
mise exec -- mix build
mise exec -- ./bin/symphony ./WORKFLOW.md
```

## Configuration

Pass a custom workflow file path to `./bin/symphony` when starting the service:

```bash
./bin/symphony /path/to/custom/WORKFLOW.md
```

If no path is passed, Symphony defaults to `./WORKFLOW.md`.

For a local Notion tracker smoke test in this repo, you can start from
`./WORKFLOW.notion.smoke.md`.

For a fuller Notion end-to-end workflow template, start from `./WORKFLOW.notion.md`.

Optional flags:

- `--logs-root` tells Symphony to write logs under a different directory (default: `./log`)
- `--port` also starts the Phoenix observability service (default: disabled)

The `WORKFLOW.md` file uses YAML front matter for configuration, plus a Markdown body used as the
Codex session prompt.

Minimal Linear example:

```md
---
tracker:
  kind: linear
  project_slug: "..."
workspace:
  root: ~/code/workspaces
hooks:
  after_create: |
    git clone git@github.com:your-org/your-repo.git .
agent:
  max_concurrent_agents: 10
  max_turns: 20
codex:
  command: codex app-server
---

You are working on a Linear issue {{ issue.identifier }}.

Title: {{ issue.title }} Body: {{ issue.description }}
```

Minimal Notion example:

```md
---
tracker:
  kind: notion
  data_source_id: "..."
  api_key: $NOTION_API_KEY
  assignee: $NOTION_ASSIGNEE
  assignee_property: Assignee
  active_states:
    - Not started
    - In progress
workspace:
  root: ~/code/workspaces
hooks:
  after_create: |
    git clone git@github.com:your-org/your-repo.git .
agent:
  max_concurrent_agents: 10
  max_turns: 20
codex:
  command: codex app-server
---

You are working on task {{ issue.identifier }}.

Title: {{ issue.title }} Body: {{ issue.description }}
```

Minimal Plane example:

```md
---
tracker:
  kind: plane
  workspace_slug: "..."
  project_id: "..."
  api_key: $PLANE_API_KEY
  assignee: $PLANE_ASSIGNEE
  active_states:
    - Todo
    - In Progress
workspace:
  root: ~/code/workspaces
hooks:
  after_create: |
    git clone git@github.com:your-org/your-repo.git .
agent:
  max_concurrent_agents: 10
  max_turns: 20
codex:
  command: codex app-server
---

You are working on Plane work item {{ issue.identifier }}.

Title: {{ issue.title }} Body: {{ issue.description }}
```

Reference Notion workflow templates in this repo:

- `./WORKFLOW.notion.md`: fuller end-to-end Notion workflow using `notion_api`
- `./WORKFLOW.notion.smoke.md`: low-risk local smoke test that proves polling, workspace bootstrap,
  tool access, and comment round-tripping

Reference Plane workflow templates in this repo:

- `./WORKFLOW.plane.md`: generic Plane reference workflow using a single editable Plane workpad
  comment, review-loop states, `plane_api`, direct external-source verification, and durable
  artifact gates
- `./WORKFLOW.plane.host-worker.md`: the same Plane reference workflow plus Docker-orchestrator to
  SSH-worker wiring, dashboard config, and GitHub token passthrough for unattended PR creation

Bundled Plane workflow conventions:

- exactly one persistent Plane workpad comment (`## Codex Workpad`) per work item
- review-loop states with `Human Review`, `Merging`, and `Rework`
- required direct retrieval of cited external sources or a non-terminal blocker
- repository-changing tasks must have a pushed branch and PR before `Human Review` or `Done`
- durable research/review output must live in a Plane page/wiki or in the workpad itself
- repo/project-specific values belong in local-only files such as `.env.plane.local`,
  `docker/symphony_ssh_config.local`, or copied local workflow files, not in the committed
  Symphony templates

Notes:

- If a value is missing, defaults are used.
- Safer Codex defaults are used when policy fields are omitted:
  - `codex.approval_policy` defaults to `{"reject":{"sandbox_approval":true,"rules":true,"mcp_elicitations":true}}`
  - `codex.thread_sandbox` defaults to `workspace-write`
  - `codex.turn_sandbox_policy` defaults to a `workspaceWrite` policy rooted at the current issue workspace
- Supported `codex.approval_policy` values depend on the targeted Codex app-server version. In the current local Codex schema, string values include `untrusted`, `on-failure`, `on-request`, and `never`, and object-form `reject` is also supported.
- Supported `codex.thread_sandbox` values: `read-only`, `workspace-write`, `danger-full-access`.
- When `codex.turn_sandbox_policy` is set explicitly, Symphony passes the map through to Codex
  unchanged. Compatibility then depends on the targeted Codex app-server version rather than local
  Symphony validation.
- `agent.max_turns` caps how many back-to-back Codex turns Symphony will run in a single agent
  invocation when a turn completes normally but the issue is still in an active state. Default: `20`.
- If the Markdown body is blank, Symphony uses a default prompt template that includes the issue
  identifier, title, and body.
- Use `hooks.after_create` to bootstrap a fresh workspace. For a Git-backed repo, you can run
  `git clone ... .` there, along with any other setup commands you need.
- If a hook needs `mise exec` inside a freshly cloned workspace, trust the repo config and fetch
  the project dependencies in `hooks.after_create` before invoking `mise` later from other hooks.
- `tracker.endpoint` defaults to `https://api.linear.app/graphql` for `tracker.kind: linear` and
  `https://api.notion.com/v1` for `tracker.kind: notion`, and `https://api.plane.so` for
  `tracker.kind: plane`.
- `tracker.api_key` reads from `LINEAR_API_KEY` for Linear, `NOTION_API_KEY` for Notion, and
  `PLANE_API_KEY` for Plane when unset or when value is `$LINEAR_API_KEY`, `$NOTION_API_KEY`, or
  `$PLANE_API_KEY`.
- `tracker.project_slug` is required for Linear workflows.
- `tracker.workspace_slug` and `tracker.project_id` are required for Plane workflows.
- `tracker.data_source_id` is required for Notion workflows.
- If `tracker.assignee` is set for a Notion workflow, `tracker.assignee_property` is also
  required.
- If `tracker.assignee` is set for a Plane workflow and omitted in config, Symphony reads it from
  `PLANE_ASSIGNEE`.
- Notion workflows require a title property plus a `status` or `select` property for task state.
  Optional overrides are available for `status_property`, `title_property`,
  `identifier_property`, `description_property`, `labels_property`, `priority_property`, and
  `assignee_property`.
- Plane agent sessions get a raw `plane_api` tool rooted at the configured Plane endpoint and auth.
  The tool accepts a relative REST path plus optional HTTP method, query, and JSON body.
- Notion agent sessions get a raw `notion_api` tool rooted at the configured Notion endpoint and
  auth. The tool accepts a relative REST path plus optional HTTP method and JSON body.
- Prompt templates also receive a non-secret `tracker` object, which is useful for Plane REST paths
  such as `{{ tracker.workspace_slug }}` and `{{ tracker.project_id }}`.
- The bundled Plane workflow templates use a single editable workpad comment in Plane rather than
  append-only progress comments, and they expect the review-loop state machine documented above.
- The bundled Notion workflow template uses append-only page comments for progress/handoff notes
  rather than trying to edit a single persistent comment in place.
- For path values, `~` is expanded to the home directory.
- For env-backed path values, use `$VAR`. `workspace.root` resolves `$VAR` before path handling,
  while `codex.command` stays a shell command string and any `$VAR` expansion there happens in the
  launched shell.

```yaml
tracker:
  api_key: $LINEAR_API_KEY
workspace:
  root: $SYMPHONY_WORKSPACE_ROOT
hooks:
  after_create: |
    git clone --depth 1 "$SOURCE_REPO_URL" .
codex:
  command: "$CODEX_BIN app-server --model gpt-5.3-codex"
```

- If `WORKFLOW.md` is missing or has invalid YAML at startup, Symphony does not boot.
- If a later reload fails, Symphony keeps running with the last known good workflow and logs the
  reload error until the file is fixed.
- `server.port` or CLI `--port` enables the optional Phoenix LiveView dashboard and JSON API at
  `/`, `/api/v1/state`, `/api/v1/<issue_identifier>`, and `/api/v1/refresh`.

## Web dashboard

The observability UI now runs on a minimal Phoenix stack:

- LiveView for the dashboard at `/`
- JSON API for operational debugging under `/api/v1/*`
- Bandit as the HTTP server
- Phoenix dependency static assets for the LiveView client bootstrap

## Project Layout

- `lib/`: application code and Mix tasks
- `test/`: ExUnit coverage for runtime behavior
- `WORKFLOW.md`: in-repo workflow contract used by local runs
- `../.codex/`: repository-local Codex skills and setup helpers

## Testing

```bash
make all
```

Run the real external Linear end-to-end test only when you want Symphony to create disposable
Linear resources and launch a real `codex app-server` session:

```bash
cd elixir
export LINEAR_API_KEY=...
make e2e
```

Optional environment variables:

- `SYMPHONY_LIVE_LINEAR_TEAM_KEY` defaults to `SYME2E`
- `SYMPHONY_LIVE_SSH_WORKER_HOSTS` uses those SSH hosts when set, as a comma-separated list

`make e2e` runs two live scenarios:
- one with a local worker
- one with SSH workers

If `SYMPHONY_LIVE_SSH_WORKER_HOSTS` is unset, the SSH scenario uses `docker compose` to start two
disposable SSH workers on `localhost:<port>`. The live test generates a temporary SSH keypair,
mounts the host `~/.codex/auth.json` into each worker, verifies that Symphony can talk to them
over real SSH, then runs the same orchestration flow against those worker addresses. This keeps
the transport representative without depending on long-lived external machines.

Set `SYMPHONY_LIVE_SSH_WORKER_HOSTS` if you want `make e2e` to target real SSH hosts instead.

The live test creates a temporary Linear project and issue, writes a temporary `WORKFLOW.md`, runs
a real agent turn, verifies the workspace side effect, requires Codex to comment on and close the
Linear issue, then marks the project completed so the run remains visible in Linear.

Run the real external Plane end-to-end test only when you want Symphony to create a disposable
Plane project and work item and launch a real `codex app-server` session:

```bash
cd elixir
export PLANE_API_KEY=...
export PLANE_WORKSPACE_SLUG=...
make e2e-plane
```

If you want the same local-file workflow we use for Notion helpers, copy the example env file at
the repo root and use the helper script instead:

```bash
cp .env.plane.local.example .env.plane.local
./docker/run-plane-live-e2e.sh
```

The helper script sources `.env.plane.local` if present, validates the required Plane variables,
then runs `make e2e-plane` via `mise` when available, plain `make` otherwise, and falls back to
Docker when neither host runtime is installed.

The Docker fallback mounts the repo into a purpose-built runner image, launches the real
`codex app-server` inside that container, and mounts the host Docker socket so the SSH scenario can
still bring up the disposable worker containers. Because the test process itself is containerized in
that mode, the helper runs the SSH-worker scenario only; use a host Elixir runtime if you want the
local-worker scenario as well.

Optional environment variables:

- `SYMPHONY_LIVE_PLANE_ENDPOINT` overrides the default `https://api.plane.so` API base, which is
  useful for self-hosted Plane instances
- `SYMPHONY_LIVE_SSH_WORKER_HOSTS` uses those SSH hosts when set, as a comma-separated list

`make e2e-plane` runs two live scenarios:
- one with a local worker
- one with SSH workers

If `SYMPHONY_LIVE_SSH_WORKER_HOSTS` is unset, the SSH scenario uses `docker compose` to start two
disposable SSH workers on `localhost:<port>` using the same transport setup as the Linear live
test.

The Plane live test creates a temporary project inside `PLANE_WORKSPACE_SLUG`, writes a temporary
`WORKFLOW.md`, runs a real agent turn, verifies the workspace side effect, requires Codex to
comment on and complete the Plane work item, then deletes the temporary project in cleanup.

To run Symphony against a real Plane project from Docker with an SSH worker on the host, keep the
project-specific values in local-only files and use the generic helper:

```bash
cp .env.plane.local.example .env.plane.local
cp docker/symphony_ssh_config.example docker/symphony_ssh_config.local
./docker/run-symphony-plane-host-worker.sh
```

By default the helper runs `./WORKFLOW.plane.host-worker.md`, sources `.env.plane.local` if it
exists, mounts `docker/symphony_ssh_config.local` into the container, and expects at least:

- `PLANE_API_KEY`
- `PLANE_WORKSPACE_SLUG`
- `PLANE_PROJECT_ID`
- `PROJECT_REPO_URL`
- `SYMPHONY_WORKSPACE_ROOT`

Optional variables for that helper:

- `PLANE_ASSIGNEE`
- `GH_TOKEN` or `GITHUB_TOKEN`
- `SYMPHONY_SSH_KEY_PATH`
- `SYMPHONY_SSH_CONFIG_PATH`
- `SYMPHONY_CONTAINER_NAME`

The committed helper and templates are generic. Keep concrete project IDs, repo URLs, workspace
paths, SSH usernames, and similar local details in `.env.plane.local`,
`docker/symphony_ssh_config.local`, or a copied local workflow file.

To sync a Plane project's workflow states to a Symphony-friendly setup, use:

```bash
./docker/sync-plane-states.sh
```

By default this ensures the minimal state set:

- `Backlog`
- `Todo`
- `In Progress`
- `Done`
- `Cancelled`

It also prints optional review-loop recommendations for `Human Review`, `Merging`, and `Rework`.
To create those optional states too, run:

```bash
./docker/sync-plane-states.sh --with-review-loop
```

Use `--with-review-loop` for the bundled `WORKFLOW.plane.md` and
`WORKFLOW.plane.host-worker.md` templates, since both assume the full review-loop state machine.

Use `--dry-run` to print recommendations without changing Plane:

```bash
./docker/sync-plane-states.sh --dry-run
```

The sync helper prefers local `mise`/`mix` when available and falls back to Docker otherwise.

Notion tracker coverage remains in the unit and integration-style tests under
`test/symphony_elixir/notion_client_test.exs`. Plane also retains its adapter-level coverage under
`test/symphony_elixir/plane_client_test.exs`.

## FAQ

### Why Elixir?

Elixir is built on Erlang/BEAM/OTP, which is great for supervising long-running processes. It has an
active ecosystem of tools and libraries. It also supports hot code reloading without stopping
actively running subagents, which is very useful during development.

### What's the easiest way to set this up for my own codebase?

Launch `codex` in your repo, give it the URL to the Symphony repo, and ask it to set things up for
you.

## License

This project is licensed under the [Apache License 2.0](../LICENSE).
