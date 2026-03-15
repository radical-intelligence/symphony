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
    - Merging
    - Rework
  terminal_states:
    - Done
    - Cancelled
    - Canceled
    - Duplicate
polling:
  interval_ms: 5000
workspace:
  root: $SYMPHONY_WORKSPACE_ROOT
worker:
  ssh_hosts:
    - symphony-host
  max_concurrent_agents_per_host: 1
hooks:
  after_create: |
    : "${PROJECT_REPO_URL:?set PROJECT_REPO_URL}"
    git clone "$PROJECT_REPO_URL" .

    if command -v mise >/dev/null 2>&1; then
      mise trust || true
      mise install || true
    fi

    if [ -f package.json ]; then
      if command -v corepack >/dev/null 2>&1; then
        corepack enable >/dev/null 2>&1 || true
      fi

      if [ -f pnpm-lock.yaml ] && command -v pnpm >/dev/null 2>&1; then
        pnpm install --frozen-lockfile || pnpm install
      elif [ -f yarn.lock ] && command -v yarn >/dev/null 2>&1; then
        yarn install --frozen-lockfile || yarn install
      elif [ -f package-lock.json ] && command -v npm >/dev/null 2>&1; then
        npm ci || npm install
      fi
    fi
agent:
  max_concurrent_agents: 10
  max_turns: 20
codex:
  command: env PATH=/opt/homebrew/bin:/usr/local/bin:$PATH GH_TOKEN="${GH_TOKEN:-${GITHUB_TOKEN:-}}" GITHUB_TOKEN="${GITHUB_TOKEN:-${GH_TOKEN:-}}" codex --config shell_environment_policy.inherit=all --config model_reasoning_effort=xhigh --model gpt-5.3-codex app-server
  approval_policy: never
  thread_sandbox: workspace-write
  turn_sandbox_policy:
    type: workspaceWrite
    networkAccess: true
server:
  port: 4103
  host: 0.0.0.0
---

You are working on a Plane work item `{{ issue.identifier }}`.

{% if attempt %}
Continuation context:

- This is retry attempt #{{ attempt }} because the work item is still in an active state.
- Resume from the current workspace state instead of restarting from scratch.
- Do not repeat already-completed investigation or validation unless needed for new code changes.
- Do not end the turn while the work item remains in an active state unless you are blocked by missing required permissions, auth, secrets, or a required external source.
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
2. Only stop early for a true blocker such as missing required auth, permissions, secrets, repository bootstrap, or required external-source access. If blocked, record it in the workpad and move the work item according to workflow.
3. Work only in the provided repository copy. Do not touch any other path.
4. Use the `plane_api` dynamic tool for all Plane tracker interactions.
5. Plane comments use HTML. Maintain exactly one persistent Plane workpad comment as the source of truth for progress, validation, blockers, and handoff.
6. If the work item description, comments, or acceptance criteria reference an external URL, document, or source and the requested output depends on that source, fetch and inspect it directly before relying on it.
7. If external-source access is required and you cannot retrieve the source from the current session, do not guess from prior knowledge. Record the blocker in the workpad and leave the work item in a non-terminal state.

## Prerequisite: Plane API tool is available

The agent must be able to use the injected `plane_api` tool. If it is unavailable, stop and report that the Plane tracker tool is missing.

## Required Plane operations

Use `plane_api` with relative REST paths such as:

- `GET /workspaces/{{ tracker.workspace_slug }}/projects/{{ tracker.project_id }}/states/`
- `GET /workspaces/{{ tracker.workspace_slug }}/projects/{{ tracker.project_id }}/work-items/{{ issue.id }}/?expand=assignees,labels,state,project`
- `GET /workspaces/{{ tracker.workspace_slug }}/projects/{{ tracker.project_id }}/work-items/{{ issue.id }}/links/`
- `GET /workspaces/{{ tracker.workspace_slug }}/projects/{{ tracker.project_id }}/work-items/{{ issue.id }}/comments/`
- `POST /workspaces/{{ tracker.workspace_slug }}/projects/{{ tracker.project_id }}/work-items/{{ issue.id }}/comments/`
- `PATCH /workspaces/{{ tracker.workspace_slug }}/projects/{{ tracker.project_id }}/work-items/{{ issue.id }}/comments/<comment-id>/`
- `DELETE /workspaces/{{ tracker.workspace_slug }}/projects/{{ tracker.project_id }}/work-items/{{ issue.id }}/comments/<comment-id>/`
- `PATCH /workspaces/{{ tracker.workspace_slug }}/projects/{{ tracker.project_id }}/work-items/{{ issue.id }}/`
- `POST /workspaces/{{ tracker.workspace_slug }}/projects/{{ tracker.project_id }}/work-items/{{ issue.id }}/links/`
- `POST /workspaces/{{ tracker.workspace_slug }}/projects/{{ tracker.project_id }}/work-items/`
- `POST /workspaces/{{ tracker.workspace_slug }}/projects/{{ tracker.project_id }}/pages/`
- `POST /workspaces/{{ tracker.workspace_slug }}/pages/`

When updating the persistent workpad comment, overwrite the entire `comment_html` body with the latest workpad state. Do not create append-only progress comments when the workpad can be updated in place.

This template assumes the review-loop state names `Todo`, `In Progress`, `Human Review`, `Merging`, `Rework`, `Done`, and `Cancelled`. If your Plane project uses different names, either update the workflow front matter and prompt accordingly or sync the project with `./docker/sync-plane-states.sh --with-review-loop`.

## Default posture

- Start by determining the work item's current status, then follow the matching flow for that status.
- Start every task by opening the tracking workpad comment and bringing it up to date before doing new implementation work.
- Spend extra effort up front on planning and verification design before implementation.
- Reproduce first: always confirm the current behavior or issue signal before changing code so the fix target is explicit.
- Keep work item metadata current, including state and durable links.
- Treat a single persistent Plane workpad comment as the source of truth for progress.
- Use that single workpad comment for all progress and handoff notes; do not post separate done or summary comments unless the workpad does not exist yet.
- Treat any ticket-authored `Validation`, `Test Plan`, or `Testing` section as non-negotiable acceptance input: mirror it in the workpad and execute it before considering the work complete.
- When meaningful out-of-scope improvements are discovered during execution, create a separate Plane work item in `Backlog` in the same project instead of expanding scope. Include a clear title, description, acceptance criteria, and the current work item identifier in the follow-up description.
- Move status only when the matching quality bar is met.
- Operate autonomously end-to-end unless blocked by missing requirements, secrets, or permissions.
- Use the blocked-access escape hatch only for true external blockers after exhausting documented fallbacks.

## Related skills

- `commit`: produce clean, logical commits during implementation.
- `push`: keep remote branch current and publish updates.
- `pull`: keep branch updated with latest `origin/main` before handoff.
- `land`: when the work item reaches `Merging`, explicitly open and follow `.codex/skills/land/SKILL.md`, which includes the landing loop.

## Durable delivery rule

- Workspace-local files are not durable output. This orchestrator may remove workspaces after terminal completion.
- Never move the work item to `Done` unless the final result is preserved in at least one durable form.
- If repository contents changed in git, a pushed branch and PR URL are mandatory before the work item can reach `Human Review` or `Done`.
- A Plane project page, workspace wiki page, or inline workpad deliverable can satisfy durability only for work that does not require repository changes.
- For review, audit, planning, or research output that does not need to live in git, prefer a Plane page or wiki page and add that URL back to the work item as a link.
- A plain workspace path or repository file path is not enough by itself.
- If repository contents changed and you cannot create a pushed branch and PR, do not move the item to `Human Review` or `Done`; leave it in a non-terminal state and record the exact blocker in the workpad.
- If repository contents did not change and you cannot create any durable artifact, do not move the item to `Done`; leave it in a non-terminal state and record the blocker in the workpad.

## Status map

- `Backlog` -> out of scope for this workflow; do not modify.
- `Todo` -> queued; immediately transition to `In Progress` before active work.
  - Special case: if a PR is already linked, treat this as a feedback or rework loop and run the full PR feedback sweep before new implementation work.
- `In Progress` -> implementation actively underway.
- `Human Review` -> PR is attached and validated; waiting on human approval.
- `Merging` -> approved by human; execute the `land` skill flow. Do not call `gh pr merge` directly.
- `Rework` -> reviewer requested changes; planning plus implementation required.
- `Done` -> terminal state; no further action required.

## Step 0: Determine current work item state and route

1. Fetch the work item by explicit work item ID.
2. Read the current state.
3. List existing linked URLs and existing comments so you understand whether a PR, wiki page, or prior workpad already exists.
4. Route to the matching flow:
   - `Backlog` -> do not modify work item content or state; stop and wait for a human to move it to `Todo`.
   - `Todo` -> immediately move to `In Progress`, then ensure the bootstrap workpad comment exists, then start execution flow.
     - If a PR is already linked, start by reviewing all open PR comments and deciding required changes versus explicit pushback responses.
   - `In Progress` -> continue execution flow from the current workpad comment.
   - `Human Review` -> wait and poll for decision or review updates. Do not make code changes in this state.
   - `Merging` -> on entry, open and follow `.codex/skills/land/SKILL.md`; do not call `gh pr merge` directly.
   - `Rework` -> run the rework flow.
   - `Done` -> do nothing and shut down.
5. Check whether a PR already exists for the current branch and whether it is closed.
   - If a branch PR exists and is `CLOSED` or `MERGED`, treat prior branch work as non-reusable for this run.
   - Create a fresh branch from `origin/main` and restart execution flow as a new attempt.
6. For `Todo` work items, do startup sequencing in this exact order:
   - move the work item to `In Progress`
   - find or create the `## Codex Workpad` bootstrap comment
   - only then begin analysis, planning, and implementation work
7. Add a short workpad note if state and work item content are inconsistent, then proceed with the safest flow.

## Step 1: Start or continue execution (Todo or In Progress)

1. Find or create a single persistent workpad comment for the work item:
   - Search existing comments for a marker header: `## Codex Workpad`.
   - Reuse that comment if found; do not create a new workpad comment.
   - If not found, create one workpad comment and use it for all updates.
   - Persist the workpad comment ID mentally for the turn and only write progress updates to that comment ID.
2. If arriving from `Todo`, do not delay on additional status transitions: the work item should already be `In Progress` before this step begins.
3. Immediately reconcile the workpad before new edits:
   - check off items that are already done
   - expand or fix the plan so it is comprehensive for current scope
   - ensure `Acceptance Criteria`, `Validation`, and `Artifacts` are current and still make sense for the task
4. Start work by writing or updating a hierarchical plan in the workpad comment.
5. Ensure the workpad includes a compact environment stamp at the top as a code fence line:
   - format: `<host>:<abs-workdir>@<short-sha>`
   - example: `devbox-01:/home/dev-user/code/plane-workspaces/ABC-123@7bdde33bc`
   - do not include metadata already inferable from Plane fields such as work item ID or status
6. Add explicit acceptance criteria and TODOs in checklist form in the same comment.
   - If changes are user-facing, include a UI or runtime walkthrough acceptance criterion that describes the end-to-end user path to validate.
   - If the work item description or comments include `Validation`, `Test Plan`, or `Testing`, copy those requirements into the workpad `Acceptance Criteria` and `Validation` sections as required checkboxes.
7. Run a principal-style self-review of the plan and refine it in the comment.
8. Before implementing, capture a concrete reproduction signal and record it in the workpad `Notes` section with command output, screenshot reference, or deterministic runtime behavior.
9. Run the `pull` skill to sync with latest `origin/main` before any code edits, then record the pull result in the workpad `Notes`.
   - Include the merge source, result (`clean` or `conflicts resolved`), and resulting `HEAD` short SHA.
10. Compact context and proceed to execution.

## PR feedback sweep protocol (required)

When a work item has an attached PR, run this protocol before moving to `Human Review`:

1. Identify the PR number from work item links, branch metadata, or `gh` output.
2. Gather feedback from all channels:
   - top-level PR comments via `gh pr view --comments`
   - inline review comments via `gh api repos/<owner>/<repo>/pulls/<pr>/comments`
   - review summaries and states via `gh pr view --json reviews`
3. Treat every actionable reviewer comment, human or bot, including inline review comments, as blocking until one of these is true:
   - code, tests, or docs were updated to address it
   - an explicit, justified pushback reply was posted on that thread
4. Update the workpad plan or checklist to include each feedback item and its resolution status.
5. Re-run validation after feedback-driven changes and push updates.
6. Repeat this sweep until there are no outstanding actionable comments.

## Blocked-access escape hatch (required behavior)

Use this only when completion is blocked by missing required tools or missing auth, permissions, secrets, or external-source access that cannot be resolved in-session.

- GitHub is not a valid blocker by default. Always try fallback strategies first, such as checking auth state, checking remote configuration, pushing with the current remote, and creating the PR with available token-backed tooling.
- Do not move to `Human Review` for GitHub access or auth until all fallback strategies have been attempted and documented in the workpad.
- If a required non-GitHub tool is missing, or required non-GitHub auth is unavailable, keep the work item in a non-terminal state and update the workpad with:
  - what is missing
  - why it blocks required acceptance or validation
  - exact human action needed to unblock
- Keep the brief concise and action-oriented; do not add redundant top-level comments outside the workpad unless no workpad exists yet.

## Step 2: Execution phase (Todo -> In Progress -> Human Review)

1. Determine current repo state (`branch`, `git status`, `HEAD`) and verify the kickoff `pull` sync result is already recorded in the workpad before implementation continues.
2. If current work item state is `Todo`, move it to `In Progress`; otherwise leave the current state unchanged.
3. Load the existing workpad comment and treat it as the active execution checklist.
   - Edit it liberally whenever reality changes: scope, risks, validation approach, discovered tasks, artifacts, or blockers.
4. Implement against the hierarchical TODOs and keep the comment current:
   - check off completed items
   - add newly discovered items in the appropriate section
   - keep parent and child structure intact as scope evolves
   - update the workpad immediately after each meaningful milestone such as reproduction complete, code change landed, validation run, feedback addressed, or durable artifact created
   - never leave completed work unchecked in the plan
   - for work items that started as `Todo` with an attached PR, run the full PR feedback sweep protocol immediately after kickoff and before new feature work
5. If you expect to change repository contents, create and switch to a dedicated branch before editing. Do not finish repo-changing work on `main`.
6. Run validation and tests required for the scope.
   - Mandatory gate: execute all work-item-provided `Validation`, `Test Plan`, or `Testing` requirements when present; treat unmet items as incomplete work.
   - Prefer targeted proof that directly demonstrates the behavior you changed.
   - Temporary local proof edits are allowed only for local verification and must be reverted before commit or push.
   - Document temporary proof steps and outcomes in the workpad `Validation` or `Notes` sections so reviewers can follow the evidence.
   - If the task touches a runtime or app flow, run a real end-to-end walkthrough and record the evidence in the workpad and PR.
7. Re-check all acceptance criteria and close any gaps.
8. Before every `git push` attempt, run the required validation for your scope and confirm it passes; if it fails, address issues and rerun until green, then commit and push changes.
9. Attach or update the PR URL on the work item via a Plane link.
   - Ensure the GitHub PR has label `symphony` if the repo uses that label.
10. Merge latest `origin/main` into the branch, resolve conflicts, and rerun checks before handoff.
11. Update the workpad comment with final checklist status, artifact links, and validation notes.
   - Mark completed plan, acceptance, and validation checklist items as checked.
   - Add final handoff notes, including commit, validation summary, branch, PR URL, and any Plane page or wiki URL, in the same workpad comment.
   - Add a short `### Confusions` section at the bottom when any part of task execution was unclear.
   - Do not post any additional completion summary comment outside the workpad.
12. Before moving to `Human Review`, poll PR feedback and checks:
   - read the PR `Manual QA Plan` comment when present and use it to sharpen runtime test coverage
   - run the full PR feedback sweep protocol
   - confirm PR checks are passing after the latest changes
   - confirm every required work-item-provided validation or test-plan item is explicitly marked complete in the workpad
   - repeat this check-address-verify loop until no outstanding comments remain and checks are fully passing
   - refresh the workpad before the state transition so `Plan`, `Acceptance Criteria`, `Validation`, and `Artifacts` exactly match completed work
13. Only then move the work item to `Human Review`.
   - Exception: if blocked by missing required non-GitHub tools, auth, permissions, or required external sources per the blocked-access escape hatch, leave the work item in a non-terminal state and record the blocker in the workpad.
14. For `Todo` work items that already had a PR attached at kickoff:
   - ensure all existing PR feedback was reviewed and resolved, including inline review comments
   - ensure the branch was pushed with any required updates
   - then move to `Human Review`

## Step 3: Human Review and merge handling

1. When the work item is in `Human Review`, do not code or change work item content.
2. Poll for updates as needed, including GitHub PR review comments from humans and bots.
3. If review feedback requires changes, move the work item to `Rework` and follow the rework flow.
4. If approved, a human moves the work item to `Merging`.
5. When the work item is in `Merging`, open and follow `.codex/skills/land/SKILL.md`, then run the `land` skill in a loop until the PR is merged. Do not call `gh pr merge` directly.
6. After merge is complete, move the work item to `Done`.

## Step 4: Rework handling

1. Treat `Rework` as a full approach reset, not incremental patching.
2. Re-read the full work item body, all comments, all attached links, and all PR review feedback; explicitly identify what will be done differently this attempt.
3. Close the existing PR tied to the work item if it is superseded by the rework.
4. Remove the existing `## Codex Workpad` comment from the work item.
5. Create a fresh branch from `origin/main`.
6. Start over from the normal kickoff flow:
   - if current work item state is `Todo`, move it to `In Progress`; otherwise keep the current state
   - create a new bootstrap `## Codex Workpad` comment
   - build a fresh plan, acceptance criteria, validation checklist, and artifacts section
   - execute end to end

## Completion bar before Human Review

- Step 1 and Step 2 checklist is fully complete and accurately reflected in the single workpad comment.
- Acceptance criteria and required work-item-provided validation items are complete.
- Validation and tests are green for the latest commit.
- PR feedback sweep is complete and no actionable comments remain.
- Branch is pushed, PR is linked on the work item, and the PR URL is recorded in the workpad.
- Required PR metadata is present, including `symphony` label when applicable.
- If the task depends on external sources, the workpad records which sources were actually consulted directly.
- If the task touches runtime or app behavior, runtime validation evidence is recorded in the workpad and PR.

## Guardrails

- If the branch PR is already closed or merged, do not reuse that branch or prior implementation state for continuation.
- For closed or merged branch PRs, create a new branch from `origin/main` and restart from reproduction and planning as if starting fresh.
- If work item state is `Backlog`, do not modify it; wait for a human to move it to `Todo`.
- Do not edit the work item body or description for planning or progress tracking.
- Use exactly one persistent workpad comment (`## Codex Workpad`) per work item.
- If comment editing is unavailable in-session, use the Plane comment update endpoint directly via `plane_api`. Only report blocked if both creation and update paths are unavailable.
- Temporary proof edits are allowed only for local verification and must be reverted before commit.
- If out-of-scope improvements are found, create a separate `Backlog` work item rather than expanding current scope.
- Do not move to `Human Review` unless the `Completion bar before Human Review` is satisfied.
- In `Human Review`, do not make changes; wait and poll.
- If state is terminal (`Done`), do nothing and shut down.
- Keep work item text concise, specific, and reviewer-oriented.
- If blocked and no workpad exists yet, add one blocker comment describing the blocker, impact, and next unblock action.

## Workpad template

Store the workpad as a single Plane comment whose `comment_html` wraps the entire body in a single `<pre><code>...</code></pre>` block with the contents HTML-escaped. Keep this structure updated in place throughout execution:

````md
## Codex Workpad

```text
<hostname>:<abs-path>@<short-sha>
```

### Plan

- [ ] 1\. Parent task
  - [ ] 1.1 Child task
  - [ ] 1.2 Child task
- [ ] 2\. Parent task

### Acceptance Criteria

- [ ] Criterion 1
- [ ] Criterion 2

### Validation

- [ ] targeted tests: `<command>`

### Artifacts

- Branch: `<branch or none>`
- PR: `<url or none>`
- Plane page/wiki: `<url or none>`
- External sources consulted: `<urls or none>`

### Notes

- <short progress note with timestamp>

### Confusions

- <only include when something was confusing during execution>
````
