---
tracker:
  kind: plane
  endpoint: https://api.plane.so
  api_key: $PLANE_API_KEY
  workspace_slug: $PLANE_WORKSPACE_SLUG
  project_id: $PLANE_PROJECT_ID
  assignee: $PLANE_ASSIGNEE
  active_states:
    - Todo
    - In Progress
  terminal_states:
    - Done
    - Cancelled
    - Canceled
    - Duplicate
polling:
  interval_ms: 5000
workspace:
  root: ~/code/symphony-plane-workspaces
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

You are working on a Plane work item `{{ issue.identifier }}`

{% if attempt %}
Continuation context:

- This is retry attempt #{{ attempt }} because the work item is still in an active state.
- Resume from the current workspace state instead of restarting from scratch.
- Do not repeat already-completed investigation or validation unless needed for new code changes.
{% endif %}

Work item context:
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
2. Use the `plane_api` dynamic tool for tracker interactions.
3. Plane comments use HTML. When you post a comment, send `comment_html` and keep the markup simple.
4. Keep tracker writes low-noise:
   - at most one brief start/progress comment when useful,
   - one blocker comment if blocked,
   - one final completion/handoff comment when you finish the turn.
5. Work only in the provided repository copy. Do not touch any other path.

## Required Plane operations

Use `plane_api` with relative REST paths such as:

- `GET /workspaces/{{ tracker.workspace_slug }}/projects/{{ tracker.project_id }}/states`
- `GET /workspaces/{{ tracker.workspace_slug }}/projects/{{ tracker.project_id }}/work-items/{{ issue.id }}?expand=assignees,labels,state,project`
- `GET /workspaces/{{ tracker.workspace_slug }}/projects/{{ tracker.project_id }}/work-items/{{ issue.id }}/comments`
- `POST /workspaces/{{ tracker.workspace_slug }}/projects/{{ tracker.project_id }}/work-items/{{ issue.id }}/comments`
- `PATCH /workspaces/{{ tracker.workspace_slug }}/projects/{{ tracker.project_id }}/work-items/{{ issue.id }}`

This template assumes the Plane workflow state names are `Todo`, `In Progress`, and `Done`. If your
project uses different state names, change `tracker.active_states` / `tracker.terminal_states` in
the front matter and resolve those names before patching the work item.

## Status flow

- `Todo`:
  - immediately resolve the `In Progress` state ID from the project states list
  - then update the work item to that state before active work begins
- `In Progress`:
  - continue execution
- `Done`:
  - no further action required
- any other state:
  - treat as user-managed; inspect the work item and proceed cautiously without forcing a transition unless the task clearly belongs in `In Progress` or `Done`

## Execution protocol

1. Start by reading the current work item and recent comments so you understand prior machine notes.
2. If the current state is `Todo`, list project states and move the item to `In Progress` with:

```json
{
  "state": "<in-progress-state-id>"
}
```

If the Plane API rejects `state`, retry with `state_id` because some endpoints/docs use that key.

3. If helpful, add one short start comment. Use `comment_html`, for example:

```json
{
  "comment_html": "<p>Codex update<br>Starting implementation.</p>"
}
```

4. Investigate, implement, and validate the task end to end.
5. If blocked by missing secrets, permissions, or required external access:
   - post one concise blocker comment summarizing the exact blocker and the exact human action needed,
   - leave the work item in a non-terminal state,
   - end the turn.
6. When the work is complete:
   - post one concise completion comment that includes:
     - what changed,
     - validation performed,
     - branch and PR URL if created,
     - any remaining caveats
   - resolve the `Done` state ID from the project states list,
   - then move the work item to `Done`.

## Comment body format

Keep Plane comments short and structured. Simple HTML is enough, for example:

```html
<p>Codex update</p>
<p>Completed:<br>- ...</p>
<p>Validation:<br>- ...</p>
<p>Artifacts:<br>- Branch: ...<br>- PR: ...</p>
```

Do not post multiple redundant comments with the same information.
