---
name: push
description:
  Push current branch changes to origin and create or update the corresponding
  pull request; use when asked to push, publish updates, or create a pull request.
---

# Push

## Prerequisites

- `gh` CLI is installed and authenticated.

## Goals

- Push current branch changes to `origin` safely.
- Create a PR if none exists for the branch, otherwise update the existing PR.
- Keep branch history clean when remote has moved.

## Steps

1. Identify current branch and confirm remote state.
2. Run local validation before pushing (project-specific: e.g. `pnpm test`, `make all`).
3. Push branch to `origin` with upstream tracking if needed.
4. If push is rejected:
   - If non-fast-forward or sync problem, run the `pull` skill to merge
     `origin/main`, resolve conflicts, and rerun validation.
   - Push again; use `--force-with-lease` only when history was rewritten.
   - If auth/permissions error, stop and surface the exact error.
5. Ensure a PR exists for the branch:
   - If no PR exists, create one with `gh pr create`.
   - If a PR exists and is open, update title/body if scope changed.
   - If branch is tied to a closed/merged PR, create a new branch + PR.
6. Write a clear PR title and body reflecting the full scope of changes.
7. Reply with the PR URL.

## Notes

- Do not use `--force`; only use `--force-with-lease` as last resort.
- Distinguish sync problems (use `pull` skill) from auth problems (surface error).
