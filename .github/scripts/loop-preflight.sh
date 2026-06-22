#!/usr/bin/env bash
# visionOS loop — preflight health-check (the Overseer's "before" arm).
# Catches the silent-failure modes that wasted ~80% of debugging time: dead gh
# tokens, an unmaterialized/mis-routed Mac workspace, and stray pipeline labels.
# Exit 0 = healthy (PASS), 1 = BLOCKED (prints the exact reason). Run BEFORE a batch.
set -uo pipefail
REPO=heidihowilson/superset
ORG=05edb58f-bb09-4f1b-932e-b8d7fc1115d9
MAC=865c5f712772fcaeac456c42780b0398
WORKER=5b6b8a61-1f19-41b9-a334-5e022ac3d8eb
REVIEWER=2d162700-ca60-4034-b78b-7a820bc39cf6
SSH="ssh -i /home/wilson/.ssh/id_ed25519 -o IdentitiesOnly=yes -o ConnectTimeout=8 mac"
fail=0
echo "== visionOS loop preflight $(date -u +%H:%M:%SZ) =="

# 1. Each automation pinned to a MATERIALIZED workspace, and worker/reviewer on DISTINCT
#    workspaces — sharing one makes the reviewer dispatch_failed via session contention
#    (the hidden cause of the "reviewer stalls"). Checks current state, not run history.
superset organization switch "$ORG" >/dev/null 2>&1
wslist=$(superset workspaces list --json 2>/dev/null)
wsw=$(superset automations get "$WORKER"   --json 2>/dev/null | python3 -c "import sys,json;print(json.load(sys.stdin).get('v2WorkspaceId') or '')" 2>/dev/null)
wsr=$(superset automations get "$REVIEWER" --json 2>/dev/null | python3 -c "import sys,json;print(json.load(sys.stdin).get('v2WorkspaceId') or '')" 2>/dev/null)
for pair in "worker:$wsw" "reviewer:$wsr"; do
  role=${pair%%:*}; ws=${pair#*:}
  if [ -z "$ws" ]; then echo "FAIL: $role automation has no workspace pinned"; fail=1; continue; fi
  printf '%s' "$wslist" | python3 -c "import sys,json;exit(0 if '$ws' in [w['id'] for w in json.load(sys.stdin)] else 1)" \
    || { echo "FAIL: $role workspace $ws not materialized (will dispatch_failed: Workspace not found)"; fail=1; }
done
[ -n "$wsw" ] && [ "$wsw" = "$wsr" ] && { echo "FAIL: worker & reviewer share workspace $wsw — session contention → reviewer dispatch_failed"; fail=1; }

# 2. gh tokens on the Mac — WARN only (SSH reads the keychain in a different security
#    context than the GUI worker, so it can false-negative; the worker's in-agent
#    assertion is the authoritative check). Still useful as an early heads-up.
if $SSH 'true' 2>/dev/null; then
  for u in sethgho 0xNoWater; do
    login=$($SSH "export PATH=/opt/homebrew/bin:/usr/local/bin:\$PATH; gh auth switch --user $u >/dev/null 2>&1; gh api user -q .login 2>/dev/null" 2>/dev/null)
    [ -z "$login" ] && echo "WARN: Mac gh '$u' may be unauthenticated (keychain-context caveat — confirm via a worker claim, or re-auth)"
  done
else echo "WARN: cannot SSH to Mac to spot-check gh auth"; fi

# 3. Label hygiene — a stray agent-working/agent-review on ANY issue makes the worker STOP
#    (its pipeline check is repo-wide), and the worker picks the lowest agent-ready repo-wide.
work=$(gh issue list --repo "$REPO" --state open --label agent-working  --json number -q '[.[].number]|join(",")' 2>/dev/null)
rev=$(gh issue list --repo "$REPO" --state open --label agent-review   --json number -q '[.[].number]|join(",")' 2>/dev/null)
[ -n "$work" ] && { echo "FAIL: stray agent-working on #$work — worker will STOP (clear it)"; fail=1; }
[ -n "$rev" ]  && { echo "FAIL: stray agent-review on #$rev — worker will STOP (clear it)"; fail=1; }
gh api "repos/$REPO/git/ref/heads/_agent-claim-lock" >/dev/null 2>&1 && echo "WARN: _agent-claim-lock ref present — clear if no worker is mid-claim"

if [ "$fail" = 0 ]; then echo "PREFLIGHT: PASS"; else echo "PREFLIGHT: BLOCKED — fix the FAILs above before dispatching"; fi
exit "$fail"
