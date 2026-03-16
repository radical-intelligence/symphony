---
name: pull
description:
  Pull latest origin/main into the current local branch and resolve merge
  conflicts. Use when the agent needs to sync a feature branch with origin
  before pushing or handing off.
---

# Pull

## Workflow

1. Verify git status is clean or commit/stash changes before merging.
2. Enable rerere locally:
   - `git config rerere.enabled true`
   - `git config rerere.autoupdate true`
3. Fetch latest refs: `git fetch origin`
4. Sync the remote feature branch first:
   - `git pull --ff-only origin $(git branch --show-current)`
5. Merge origin/main:
   - `git -c merge.conflictstyle=zdiff3 merge origin/main`
6. If conflicts appear, resolve them, then:
   - `git add <files>`
   - `git merge --continue`
7. Verify with project checks.
8. Summarize the merge: call out challenging conflicts and how they were resolved.

## Conflict Resolution

- Inspect context before editing: use `git status`, `git diff`.
- With zdiff3, conflict markers include base, ours, and theirs.
- Summarize the intent of both changes, decide the correct outcome, then edit.
- Prefer minimal, intention-preserving edits.
- Resolve one file at a time and rerun tests after each batch.
- For generated files, resolve source conflicts first then regenerate.
- Ensure no conflict markers remain: `git diff --check`
