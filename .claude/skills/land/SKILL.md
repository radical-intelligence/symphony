---
name: land
description:
  Land a PR by ensuring checks pass, resolving conflicts, and squash-merging;
  use when asked to land, merge, or shepherd a PR to completion.
---

# Land

## Goals

- Ensure the PR is conflict-free with main.
- Keep CI green and fix failures when they occur.
- Squash-merge the PR once checks pass.
- Do not yield until the PR is merged; keep retrying unless blocked.

## Preconditions

- `gh` CLI is authenticated.
- You are on the PR branch with a clean working tree.

## Steps

1. Locate the PR for the current branch.
2. Check mergeability and conflicts against main.
3. If conflicts exist, use the `pull` skill to fetch/merge `origin/main` and
   resolve conflicts, then push the updated branch.
4. Watch checks until complete: `gh pr checks --watch`
5. If checks fail:
   - Pull logs: `gh run view <run-id> --log-failed`
   - Fix the issue, commit, push, and rerun checks.
6. Address any outstanding review comments before merging:
   - For each comment: accept (fix + reply), push back (reply with rationale),
     or clarify.
   - Reply to inline review comments via the review comment endpoint.
7. When all checks are green and review feedback is addressed, squash-merge:
   ```
   gh pr merge --squash
   ```
8. If mergeability is `UNKNOWN`, wait and re-check.

## Failure Handling

- If checks fail, pull details with `gh pr checks` and `gh run view --log`,
  fix locally, commit, push, and rerun.
- Use judgment to identify flaky failures. If a failure is clearly a flake,
  you may proceed without fixing it.
- If the remote PR branch advanced (e.g. auto-fix commit), pull locally,
  merge if needed, and push to retrigger CI.
- Do not enable auto-merge; merge explicitly after checks pass.
- Do not merge while review comments are outstanding.
