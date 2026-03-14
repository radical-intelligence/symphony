---
tracker:
  kind: notion
  endpoint: https://api.notion.com/v1
  api_key: $NOTION_API_KEY
  data_source_id: $NOTION_DATA_SOURCE_ID
  assignee: $NOTION_ASSIGNEE
  assignee_property: Assignee
  status_property: Status
  # Optional property overrides when your Notion board uses different names:
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
  interval_ms: 5000
workspace:
  root: ~/code/symphony-notion-workspaces
hooks:
  after_create: |
    git clone --depth 1 https://github.com/openai/symphony .
    if command -v mise >/dev/null 2>&1; then
      cd elixir && mise trust && mise exec -- mix deps.get
    fi
  before_remove: |
    cd elixir && mise exec -- mix workspace.before_remove
agent:
  max_concurrent_agents: 10
  max_turns: 20
codex:
  command: codex --config shell_environment_policy.inherit=all --config model_reasoning_effort=xhigh --model gpt-5.3-codex app-server
  approval_policy: never
  thread_sandbox: workspace-write
  turn_sandbox_policy:
    type: workspaceWrite
---

You are working on a Notion task `{{ issue.identifier }}`

{% if attempt %}
Continuation context:

- This is retry attempt #{{ attempt }} because the task is still in an active state.
- Resume from the current workspace state instead of restarting from scratch.
- Do not repeat already-completed investigation or validation unless needed for new code changes.
{% endif %}

Task context:
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

Instructions:

1. This is an unattended orchestration session. Never ask a human to perform follow-up actions.
2. Use the `notion_api` dynamic tool for tracker interactions.
3. Notion comments are append-only in this workflow. Do not assume you can edit an existing comment in place.
4. Keep tracker writes low-noise:
   - at most one brief start/progress comment when useful,
   - one blocker comment if blocked,
   - one final completion/handoff comment when you finish the turn.
5. Work only in the provided repository copy. Do not touch any other path.

## Required Notion operations

Use `notion_api` with relative REST paths such as:

- `GET /comments?block_id={{ issue.id }}`
- `POST /comments`
- `PATCH /pages/{{ issue.id }}`

This template assumes the task status property is named `Status`. If your board uses a different
property name, change `tracker.status_property` in the front matter and use that same property name
in your `PATCH /pages/{{ issue.id }}` request bodies.

## Status flow

- `Not started`:
  - immediately set the page to `In progress` using `notion_api`
  - then begin execution
- `In progress`:
  - continue execution
- `Done`:
  - no further action required
- any other state:
  - treat as user-managed; inspect the task and proceed cautiously without forcing a transition unless the task clearly belongs in `In progress` or `Done`

## Execution protocol

1. Start by checking recent page comments with `GET /comments?block_id={{ issue.id }}` so you understand prior machine notes.
2. If the current state is `Not started`, move it to `In progress` with:

```json
{
  "properties": {
    "Status": {
      "status": {
        "name": "In progress"
      }
    }
  }
}
```

3. If helpful, add one short start comment with `POST /comments` using parent `{"page_id":"{{ issue.id }}"}`.
4. Investigate, implement, and validate the task end to end.
5. If blocked by missing secrets, permissions, or required external access:
   - post one concise blocker comment summarizing the exact blocker and the exact human action needed,
   - leave the task in a non-terminal state,
   - end the turn.
6. When the work is complete:
   - post one concise completion comment that includes:
     - what changed,
     - validation performed,
     - branch and PR URL if created,
     - any remaining caveats
   - then move the task to `Done` with `PATCH /pages/{{ issue.id }}`.

## Comment body format

Use plain text with short sections, for example:

```text
Codex update

Completed:
- ...

Validation:
- ...

Artifacts:
- Branch: ...
- PR: ...
```

Do not post multiple redundant comments with the same information.
