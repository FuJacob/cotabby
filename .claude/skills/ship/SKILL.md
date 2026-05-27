---
name: ship
description: Ship the current work to main via a squash-merged PR. Branches off latest main (unless a branch is given), pushes, opens a PR using the repo template, then squash-merges with admin bypass. Use when the user says "ship it", "/ship", or wants to land changes on main end-to-end.
---

# /ship

End-to-end "land this on main" workflow for Cotabby. The goal is a **single linear
commit on main** — squash merge, never a merge commit. Cotabby's `main` ruleset
rejects merge commits, so squashing is what keeps history clean; `--admin` bypasses
the required-status-check protection so the owner can merge directly.

`$ARGUMENTS` is optional:
- empty → branch off the latest `origin/main` with a derived name
- a branch name (e.g. `feat/foo`) → use/create that branch instead of deriving one
- `from <ref>` → base the new branch on `<ref>` instead of `origin/main`

## Steps

1. **Establish the branch.**
   - `git fetch origin`.
   - If the user is already on a feature branch that holds the work, keep it.
   - Otherwise (on `main`/detached, or a branch name was given), create the branch
     off the latest base: `git checkout -b <name> origin/main` (or the `from <ref>`
     base). Derive `<name>` from the change: `feat/`, `fix/`, or `chore/` + a short
     kebab slug. Never do the work directly on `main`.

2. **Commit the work.** Stage and commit anything pending. Follow the repo's
   GitHub rules in `.claude/CLAUDE.md`: **no `Co-Authored-By` trailers.** Write a
   concise, real commit message.

3. **Validate before pushing.** Run the narrowest useful checks, broaden if shared
   behavior changed:
   ```bash
   swiftlint lint --quiet
   xcodebuild -project Cotabby.xcodeproj -scheme Cotabby -destination 'platform=macOS' build
   ```
   For test-affecting changes also run `build-for-testing`. Local `test` execution
   often fails on a **Team ID / signing mismatch** — that's an environment issue, not
   a code failure; report it and rely on `build-for-testing` succeeding.
   - **XcodeGen:** `project.yml` is the source of truth and `Cotabby.xcodeproj` is
     generated. New files under `Cotabby/` and `CotabbyTests/` are auto-discovered —
     no project edit needed. Only structural changes (targets, build settings,
     packages, scheme) require editing `project.yml` then `xcodegen generate` and
     committing the regenerated project. Fix all lint/build errors before continuing.

4. **Push.** `git push -u origin <branch>`.

5. **Open the PR using the repo template.** Read `.github/PULL_REQUEST_TEMPLATE.md`
   and fill in **every** section — Summary (what + why), Validation (what you
   actually ran and saw), Linked issues (`Fixes #N` / `Refs #N`), Risk / rollout
   notes. Do not invent a format. Use a heredoc body:
   ```bash
   gh pr create --base main --head <branch> --title "<title>" --body "$(cat <<'EOF'
   ## Summary
   ...
   EOF
   )"
   ```

6. **Confirm, then squash-merge with admin bypass.** Merging to `main` is an
   irreversible outward action — show the PR URL and the one-line summary, and get an
   explicit go-ahead unless the user already said to merge in this turn. Then:
   ```bash
   gh pr merge <branch-or-#> --squash --admin --delete-branch
   ```
   `--squash` keeps main linear (no merge commit → satisfies the ruleset);
   `--admin` bypasses required checks; `--delete-branch` cleans up the remote branch.

7. **Sync local main.**
   ```bash
   git checkout main && git pull --ff-only origin main
   ```
   Confirm `main` now contains the squashed commit and report the result.

## Guardrails

- **Never force-push `main` or rebase published history to "fix" merges.** If
  `origin/main` moved while you worked, integrate it (rebase the branch onto the new
  `origin/main`) and re-validate — don't clobber others' commits.
- **Never delete or overwrite work you didn't create** without checking it first.
- If validation fails, stop and surface the failure — don't merge red.
- If the user named a target other than `main`, ship there instead, but keep the
  squash-merge shape.
