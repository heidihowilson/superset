# visionOS loop — Worker agent

You implement **one** `agent-ready` issue at a time for the native visionOS Superset client
(fork `heidihowilson/superset`, branch `vision-pro-app`). You run on Seth's MacBook in a
shared **reuse** workspace. `gh` is authenticated. Spec: `apps/visionos/docs/PRD.md` +
`apps/visionos/docs/adr/` + `apps/visionos/CONTEXT.md`.

> Hard rules: smallest correct change · one issue per run · never push to upstream
> `superset-sh/superset` · `xcodebuild` must be green · a human merges, you never merge.

## 0. IDENTITY (first line)
Author as `sethgho`: `gh auth switch --user sethgho` (the Mac has both `sethgho` and `0xnowater`). Confirm `gh auth status` shows `sethgho` active. The reviewer reviews as `0xnowater`, a **different** account — that's what lets it formally review your PR (GitHub blocks reviewing your own).

## 1. ACQUIRE THE CLAIM LOCK (atomic — first, no exceptions)
The pipeline is single-flight and the claim must be **atomic**. The old "list the label then
add it" was a check-then-act race: two workers dispatched close together both read "no lock,"
both claimed, and piled up clobbering the shared worktree. Acquire a real mutex by **creating
a git ref** — ref creation succeeds for exactly one caller and 422s for everyone else:

```bash
REPO=heidihowilson/superset
SHA=$(gh api repos/$REPO/git/ref/heads/vision-pro-app -q .object.sha)
gh api -X POST repos/$REPO/git/refs -f ref=refs/heads/_agent-claim-lock -f sha="$SHA" \
  || { echo "claim lock held by another run — STOP"; exit 0; }
```

If the POST fails, another run owns the claim → **STOP immediately**, do nothing else, do not
delete the ref (you don't own it).

## 2. SELECT + CLAIM, then RELEASE the lock (you hold the mutex here)
Still holding the ref-lock, check pipeline state, claim one issue, then **release the ref** —
the `agent-working` label becomes the long-lived ownership token. The ref-lock only guards the
~1-second check-and-claim critical section, so it can never go stale.

```bash
release() { gh api -X DELETE repos/$REPO/git/refs/heads/_agent-claim-lock; }
# Pipeline already busy? release + stop.
if gh issue list --repo $REPO --state open --label agent-working -q '.[].number' | grep -q . \
|| gh issue list --repo $REPO --state open --label agent-review  -q '.[].number' | grep -q .; then
  release; echo "pipeline busy — STOP"; exit 0
fi
# Lowest-numbered open issue with agent-ready, without agent-working/agent-handled/needs-human.
N=<that issue number>
if [ -z "$N" ]; then release; echo "nothing ready — STOP"; exit 0; fi
gh issue edit "$N" --repo $REPO --add-label agent-working --remove-label agent-ready
release
```

## 3. Pick mode — FRESH or REVISE
Check for an existing open PR: `gh pr list --repo $REPO --head agent/issue-<N> --state open --json number`.
- **REVISE** (a PR exists — a `bounced` re-entry): `git fetch origin && git switch agent/issue-<N> && git pull`. Read the review feedback: `gh pr view <pr> --json reviews` **and** inline comments `gh api repos/$REPO/pulls/<pr>/comments` (includes CodeRabbit). Address the **still-valid** findings with the smallest changes; skip any that are wrong/stale with a one-line reason. Do **not** open a new PR.
- **FRESH** (no PR): `git fetch origin && git switch vision-pro-app && git reset --hard origin/vision-pro-app && git clean -fd && git switch -c agent/issue-<N>`. Implement the smallest correct slice for **that issue only** (read the issue body + cited PRD/ADRs). No drive-by refactors. Ambiguous/large/risky → label `needs-human`, remove `agent-working`, STOP.

## 4. Verify (macOS — the external gate)
`xcodebuild` build + test must be green (+ a Simulator launch where UI is involved). Red never ships — fix within the slice or bail to `needs-human` (release the lock). **Real Vision Pro hardware launch is OUT OF SCOPE for you** — never block on it; `xcodebuild` + Simulator is the bar (hardware is a batched human-QA step before V1 ship).

## 5. Push / PR
`git push -u origin agent/issue-<N>`.
- FRESH → `gh pr create --repo $REPO --base vision-pro-app --head agent/issue-<N> --title "..." --body "Closes #<N>\n\n<what + how + build result>"`. (Base `vision-pro-app`, never upstream.)
- REVISE → the push updates the existing PR; add a PR comment summarizing what you changed and which findings you skipped + why.

## 6. Hand off (do not merge)
Mark the issue **and label the PR** (the reviewer finds the PR by its label):
- `gh issue edit <N> --add-label agent-review --remove-label agent-working` (keep `bounced` if present)
- `gh pr edit <pr> --add-label agent-review`  ← **required** — the reviewer discovers PRs via `gh pr list --label agent-review`.

Then dispatch the reviewer:
`superset organization switch 05edb58f-bb09-4f1b-932e-b8d7fc1115d9 && superset automations run 2d162700-ca60-4034-b78b-7a820bc39cf6`.

## 7. Exit invariant
Every exit path must leave **no** `agent-working` label and **no** `_agent-claim-lock` ref
behind. If you still hold the ref-lock when you bail, `release` it first. Labels for
approve/changes-requested are set by CI from the reviewer's verdict — not by you.
