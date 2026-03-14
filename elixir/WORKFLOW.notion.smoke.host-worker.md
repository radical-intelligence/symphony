---
tracker:
  kind: notion
  endpoint: https://api.notion.com/v1
  api_key: $NOTION_API_KEY
  data_source_id: $NOTION_DATA_SOURCE_ID
  assignee: $NOTION_ASSIGNEE
  assignee_property: Assignee
  # Optional property overrides when your Notion board uses different names:
  # status_property: Status
  # title_property: Task
  # identifier_property: Identifier
  # description_property: Description
  # labels_property: Labels
  # priority_property: Priority
  active_states:
    - Not started
    - In progress
  terminal_states:
    - Done
    - Cancelled
    - Canceled
    - Duplicate
polling:
  interval_ms: 10000
workspace:
  root: /Users/pandemosthenous/code/symphony-notion-smoke-workspaces
worker:
  ssh_hosts:
    - symphony-host
  max_concurrent_agents_per_host: 1
hooks:
  after_create: |
    git clone --depth 1 https://github.com/openai/symphony .
    if command -v mise >/dev/null 2>&1; then
      cd elixir && mise trust && mise exec -- mix deps.get
    fi
  before_remove: |
    cd elixir && mise exec -- mix workspace.before_remove
agent:
  max_concurrent_agents: 1
  max_turns: 1
codex:
  command: /opt/homebrew/bin/codex --config shell_environment_policy.inherit=all app-server
  approval_policy: never
  thread_sandbox: workspace-write
  turn_sandbox_policy:
    type: workspaceWrite
server:
  port: 4103
---

You are running a local Symphony smoke test against a Notion task board.

Issue context:
Identifier: {{ issue.identifier }}
Title: {{ issue.title }}
Current status: {{ issue.state }}
Labels: {{ issue.labels }}
URL: {{ issue.url }}

Description:
{% if issue.description %}
{{ issue.description }}
{% else %}
No description provided.
{% endif %}

Rules:

1. This workflow is for local smoke testing of tracker polling, workspace bootstrap, and one agent turn.
2. Use the `notion_api` tool to prove tracker round-tripping works:
   - read recent comments with `GET /comments?block_id={{ issue.id }}`
   - post one short smoke-test comment to the page with `POST /comments`
3. Default to read-only investigation. Do not modify repository files unless the task explicitly asks for a safe smoke-test code change.
4. If the task is a real implementation request rather than a smoke test, stop and say that this workflow is intentionally limited to smoke testing.
5. Run a small amount of repo inspection only:
   - report the current branch,
   - report the current `HEAD` short SHA,
   - list the top-level repository entries,
   - run one low-risk sanity command relevant to the repo.
6. Do not change the Notion page status in this smoke-test workflow.
7. End after one concise final report. Do not ask the user follow-up questions.

The operator will stop Symphony or manually move the Notion task to a terminal state after verifying the run.
