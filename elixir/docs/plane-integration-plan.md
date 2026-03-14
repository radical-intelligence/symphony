# Plane Tracker Integration Plan

## Recommendation

Use the current `notion-tracker` work as the base for Plane.

That branch already extracted the tracker boundary out of Linear and added the main extension points
Plane needs:

- `SymphonyElixir.Tracker` adapter dispatch
- tracker-specific config validation
- tracker-specific raw dynamic tools
- tracker-specific workflow templates
- tracker-specific test slices

I do not think a different base branch is better for this work. Plane is much closer to Linear than
Notion at the product level, but the Notion branch is the one that actually removed the hard-coded
Linear assumptions from Symphony.

## What Plane Gives Us

Based on Plane's official docs and repos:

- Plane has a public REST API under `https://api.plane.so`.
- Plane supports API-key auth and bearer auth.
- Plane has project-scoped work item endpoints for list/get/update/comment operations.
- Plane exposes workspace-scoped endpoints for project lookup and current-user lookup.
- Plane ships an official MCP server with local stdio mode and hosted remote HTTP modes.
- Plane publishes official SDK guidance for TypeScript and Python.
- Plane's visible "CLI" surface is primarily for self-hosting and dev tooling, not day-to-day issue
  operations, so it should not be the core Symphony integration surface.

Implication for Symphony: the primary integration should be REST, with a built-in raw `plane_api`
dynamic tool. Plane MCP is useful as an optional downstream agent tool, but Symphony should not
depend on an external MCP server just to poll and mutate tracker state.

## Key Plane API Constraints

The official API shape is workable, but there are a few design constraints that matter:

- Work item list/get/update/comment endpoints are project-scoped and include both
  `workspace_slug` and `project_id` in the path.
- State transitions use state IDs in update payloads, so state-name to state-ID resolution is
  required.
- Work item comments are separate resources and use comment payload fields such as
  `comment_html`.
- Plane also has a workspace-scoped "get issue by identifier" endpoint, which can be useful for
  recovery and agent-side workflows.
- Several API reference pages currently show inconsistent or placeholder response examples, so the
  implementation should trust endpoint paths and request parameters from docs, then verify exact
  response fields against a live workspace or the SDK models during coding.

## Recommended Symphony Config

Add `tracker.kind: plane` and keep the integration scoped to one configured Plane project, matching
the current Symphony model.

Recommended new tracker fields:

- `workspace_slug`
- `project_id`
- `api_key`
- `assignee`
- `active_states`
- `terminal_states`

Recommended defaults and env support:

- `tracker.endpoint` default: `https://api.plane.so`
- `tracker.api_key` default env: `PLANE_API_KEY`
- `tracker.workspace_slug` allow `$PLANE_WORKSPACE_SLUG`
- `tracker.project_id` allow `$PLANE_PROJECT_ID`
- `tracker.assignee` allow `$PLANE_ASSIGNEE`

Notes:

- `project_id` is the safest required field because the Plane work-item endpoints are project-ID
  based.
- If we want a friendlier config later, we can add optional `project_identifier` lookup on top of
  `project_id`, but I would not make that the first implementation because it adds one more
  resolution step and more failure cases.
- `assignee` should mean "only route work assigned to this Plane user ID", mirroring the Notion
  behavior more than the current Linear email/ID hybrid.

## Proposed Code Shape

### 1. Config and adapter dispatch

Update:

- `elixir/lib/symphony_elixir/config.ex`
- `elixir/lib/symphony_elixir/config/schema.ex`
- `elixir/lib/symphony_elixir/tracker.ex`

Changes:

- Accept `tracker.kind: "plane"`.
- Add Plane-specific config fields and env resolution.
- Add Plane-specific validation errors.
- Route `Tracker.adapter()` to `SymphonyElixir.Plane.Adapter`.

### 2. Plane request helper

Add:

- `elixir/lib/symphony_elixir/plane/api.ex`

Purpose:

- Mirror `SymphonyElixir.Notion.API`.
- Centralize auth headers, endpoint joining, `Req` calls, and normalized error tuples.
- Make the same request helper usable from both the tracker client and the dynamic tool.

### 3. Plane tracker client

Add:

- `elixir/lib/symphony_elixir/plane/adapter.ex`
- `elixir/lib/symphony_elixir/plane/client.ex`

Scope:

- `fetch_candidate_issues/0`
- `fetch_issues_by_states/1`
- `fetch_issue_states_by_ids/1`
- `create_comment/2`
- `update_issue_state/2`

Recommended implementation details:

- Resolve Plane state IDs from the configured project by listing project states once per call path.
- Poll issues with the Plane project issues endpoint and page through results.
- Prefer using `expand` query params to fetch enough nested data in one round trip where Plane
  supports it.
- Filter by configured active-state names by first resolving those names to Plane state IDs.
- Filter by `assignee` when configured.
- Use the existing normalized issue struct for orchestration.

## Normalization into Symphony's issue model

Continue using `SymphonyElixir.Linear.Issue` for now. It is already the effective normalized issue
struct across Linear and Notion, even though the module name is now misleading.

Plane mapping should aim for:

- `id`: Plane work item ID
- `identifier`: Plane project identifier plus sequence ID
- `title`: Plane issue name
- `description`: best-effort plain-text form derived from Plane description fields
- `priority`: mapped into Symphony's integer sort model
- `state`: Plane state name
- `url`: Plane app URL when available, otherwise `nil`
- `assignee_id`: selected assignee ID or `nil`
- `labels`: lowercased label names
- `created_at` / `updated_at`: parse when present
- `branch_name`: `nil` initially
- `blocked_by`: `[]` initially unless Plane dependency data is easy to pull in the same request

Two follow-ups are worth considering, but not required for the first pass:

- rename `SymphonyElixir.Linear.Issue` to a tracker-neutral module
- add first-class dependency normalization if Plane exposes it cheaply enough

## Dynamic tool strategy

Add a built-in `plane_api` tool instead of trying to wire the external Plane MCP server directly
into Symphony runtime.

Why:

- Symphony already has a successful pattern for tracker-native tools:
  - `linear_graphql`
  - `notion_api`
- A built-in tool keeps auth, request normalization, and tests inside Symphony.
- It avoids adding a second external service dependency to every agent run.
- It still leaves room for users to configure the official Plane MCP server separately if they want
  richer agent capabilities.

Recommended `plane_api` contract:

- relative REST path only
- optional `method`
- optional JSON `query`
- optional JSON `body`

This is slightly richer than `notion_api` because Plane is a more conventional REST API and query
param composition will matter.

## Workflow-template recommendation

Add a Plane workflow template rather than forcing users to adapt the Linear or Notion templates.

Suggested file:

- `elixir/WORKFLOW.plane.md`

Recommended style:

- closer to the Linear flow than the Notion flow
- use `plane_api` for issue refreshes, state moves, comments, and PR linkage
- keep a single persistent workpad comment if the Plane comment update endpoints are reliable
- fall back to append-only comments if comment editing proves awkward in practice

My default implementation bias is:

- MVP: append-only comments, because it is simpler and matches the Notion branch pattern
- fast follow: upgrade the workflow to a single editable workpad comment once the Plane comment
  update/list semantics are confirmed in a live workspace

## Tests to add

Mirror the Notion footprint.

### Config and core

- validate Plane-specific required fields
- validate Plane env resolution
- validate Plane endpoint default

### Tracker dispatch

- `Tracker.adapter()` returns the Plane adapter
- tracker calls delegate correctly through the adapter

### Plane client

- fetch candidate issues resolves states and normalizes issues
- fetch by ID preserves requested order
- create comment hits the correct endpoint and payload shape
- update state resolves state ID from state name before patching
- paging and assignee filtering behave correctly

### Dynamic tool

- `tool_specs/0` advertises `plane_api`
- request validation rejects full URLs and invalid methods
- success and failure formatting match current tool behavior

### App server

- Plane workflows advertise `plane_api` to Codex

## Implementation order

1. Add config fields, validation, env resolution, and tracker dispatch.
2. Add `Plane.API`.
3. Add `Plane.Adapter` and `Plane.Client` read paths.
4. Add write paths for comment creation and state transitions.
5. Add `plane_api` dynamic tool support.
6. Add tests for config, adapter, client, dynamic tool, and app-server tool advertisement.
7. Add `WORKFLOW.plane.md` and README/docs updates.
8. Run targeted tests first, then `make all`.

## Risks and open questions

### 1. Plane docs response examples are inconsistent

The endpoint paths and request sections look usable, but some response examples appear to be wrong
or copied from other resources. During implementation, verify exact issue/state/comment payload
shapes against a live Plane workspace or the official SDK models.

### 2. Priority mapping is not yet confirmed

Symphony sorts on integer priority. Plane appears to expose a richer priority model. We need one
explicit mapping function and tests for it.

### 3. Comment payload format may need HTML or editor JSON

The docs surface `comment_html`. It may also want structured editor JSON in some cases. We should
prove the minimum accepted payload with a real request before locking down the client and workflow.

### 4. The official Plane MCP server is useful but should stay optional

It is strong evidence that Plane is agent-friendly, but Symphony should not make its own tracker
poll loop or workflow correctness depend on a separately installed MCP service.

### 5. There is no obvious issue-operations CLI surface worth building around

Plane's public CLI story appears to be oriented around self-hosting and platform operations, not
tracker CRUD. Symphony should treat REST as the primary integration and MCP as the optional richer
agent surface.

## Sources

- https://developers.plane.so/api-reference/introduction
- https://developers.plane.so/api-reference/user/get-current-user
- https://developers.plane.so/api-reference/project/list-projects
- https://developers.plane.so/api-reference/state/list-states
- https://developers.plane.so/api-reference/issue/list-issues
- https://developers.plane.so/api-reference/issue/get-issue-detail
- https://developers.plane.so/api-reference/issue/get-issue-sequence-id
- https://developers.plane.so/api-reference/issue/update-issue-detail
- https://developers.plane.so/api-reference/issue-comment/add-issue-comment
- https://developers.plane.so/api-reference/issue-comment/list-issue-comments
- https://developers.plane.so/dev-tools/mcp-server
- https://developers.plane.so/dev-tools/build-plane-app/sdks
- https://github.com/makeplane/plane-mcp-server
- https://github.com/makeplane/plane-prime-cli
