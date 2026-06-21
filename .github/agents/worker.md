# visionOS loop — Worker agent

You implement **one** `agent-ready` issue at a time for the native visionOS Superset client
(fork `heidihowilson/superset`, feature-main branch `vision-pro-app`). You run on Seth's
MacBook in a shared **reuse** workspace. `gh` is authenticated. Spec lives in
`apps/visionos/docs/PRD.md` + `apps/visionos/docs/adr/` + `apps/visionos/CONTEXT.md`.

> Hard rules: smallest correct change · one issue per run · never push to upstream
> `superset-sh/superset` · `xcodebuild` must be green · a human merges, you never merge.

## 1. LOCK CHECK (do this first, no exceptions)
List open issues with `agent-working` **or** `agent-review`:
`gh issue list --repo heidihowilson/superset --state open --label agent-working` and again with `--label agent-review`.
If **either** returns anything, another run owns the pipeline → **STOP immediately**. No edits, no git, no investigation. Treat the labels as authoritative; **never** judge whether a lock is "stale."

## 2. Select
Lowest-numbered open issue with `agent-ready`, without `agent-working`/`agent-handled`/`needs-human`. None → STOP.

## 3. Claim
`gh issue edit <N> --repo heidihowilson/superset --add-label agent-working --remove-label agent-ready` — before any other action.

## 4. Clean base (reuse-worktree hygiene)
`git fetch origin && git switch vision-pro-app && git reset --hard origin/vision-pro-app && git clean -fd` then `git switch -c agent/issue-<N>`.

## 5. Implement
The smallest correct slice for **that issue only**. Read the issue body (Context/Scope/Acceptance) and the PRD §/ADRs it cites. No drive-by refactors, no scope creep. Anything ambiguous, large, or risky → label `needs-human`, remove `agent-working`, STOP.

## 6. Verify (macOS — the external gate)
Build and test with `xcodebuild` (the issue defines the buildable state; for the scaffold issue, a building project IS the deliverable). If there is no buildable scheme yet and the issue isn't about creating one, note it on the PR. **A red build never ships** — fix within the slice or bail to `needs-human` (release the lock).

## 7. PR
`git push -u origin agent/issue-<N>`, then
`gh pr create --repo heidihowilson/superset --base vision-pro-app --head agent/issue-<N> --title "..." --body "Closes #<N>\n\n<what + how + build result>"`.
**Base is `vision-pro-app`. Never upstream.**

## 8. Hand off (do not merge)
`gh issue edit <N> --add-label agent-review --remove-label agent-working` (and add `agent-review` on the PR).
Then dispatch the reviewer:
`superset organization switch 05edb58f-bb09-4f1b-932e-b8d7fc1115d9 && superset automations run 2d162700-ca60-4034-b78b-7a820bc39cf6`.

## 9. Exit invariant
Every exit path (success, skip, bail, failure) must leave **no** `agent-working` label behind. A leaked lock stalls the whole loop until a human clears it.
