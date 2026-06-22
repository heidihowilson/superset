#!/usr/bin/env bash
# visionOS loop driver — durable orchestration for one batch of issues.
# Usage:  bash .github/scripts/loop-driver.sh <LO> <HI>   (e.g. 41 45)
#
# Responsibilities (the worker/reviewer agents + GitHub Actions do the rest):
#   - COLD-START preflight gate (only when nothing is in flight — queueing a label
#     self-fires a dispatch, so a mid-batch relaunch must NOT re-preflight).
#   - auto-merge agent-approved + MERGEABLE PRs.
#   - dispatch the worker when the pipeline is idle (repo-wide single-flight).
#   - bounded reviewer self-heal: one re-dispatch, then a CodeRabbit+CI fallback-merge.
#   - leak watchdog (stop if the vision-pro workspace count climbs) + stale claim-lock GC.
#   - exit on a terminal RESULT (DONE / TRIAGE needs-human / REVIEW-STALL / LEAK-GUARD /
#     CHECKPOINT). Relaunch on CHECKPOINT; on DONE/TRIAGE an Overseer SESSION reflects.
set -uo pipefail
LO="${1:?usage: loop-driver.sh <LO> <HI>}"; HI="${2:?usage: loop-driver.sh <LO> <HI>}"
REPO=heidihowilson/superset
ORG=05edb58f-bb09-4f1b-932e-b8d7fc1115d9
WORKER=5b6b8a61-1f19-41b9-a334-5e022ac3d8eb
REVIEWER=2d162700-ca60-4034-b78b-7a820bc39cf6
HERE="$(cd "$(dirname "$0")" && pwd)"
log(){ echo "[$(date -u +%H:%M:%S)] $*"; }
q(){ python3 -c "import sys,json;$1" 2>/dev/null; }

# COLD-START preflight gate — skip if a batch is already in flight.
inflight=$(( $(gh issue list --repo $REPO --state open --label agent-working --json number -q 'length' 2>/dev/null || echo 0) \
           + $(gh issue list --repo $REPO --state open --label agent-review  --json number -q 'length' 2>/dev/null || echo 0) ))
if [ "$inflight" -eq 0 ]; then
  bash "$HERE/loop-preflight.sh" || { echo "RESULT: PREFLIGHT-BLOCKED"; exit 0; }
else
  log "batch already in flight — skip cold-start preflight"
fi

deadline=$(( $(date +%s) + 3000 ))
rev_issue=""; rev_since=0; rev_redisp=0; last_disp=0; ref_seen=0; maxws=0
while [ $(date +%s) -lt $deadline ]; do
  now=$(date +%s)
  open=$(gh issue list --repo $REPO --state open --json number,labels -q "[.[]|select(.number>=$LO and .number<=$HI)]" 2>/dev/null); [ -z "$open" ] && open="[]"
  [ "$(printf '%s' "$open" | q "print(len(json.load(sys.stdin)))")" = "0" ] && { echo "RESULT: DONE — #$LO-#$HI all merged"; break; }
  # auto-merge approved + mergeable
  for i in $(printf '%s' "$open" | q "print(' '.join(str(x['number']) for x in json.load(sys.stdin) if any(l['name']=='agent-approved' for l in x['labels'])))"); do
    p=$(gh pr list --repo $REPO --head "agent/issue-$i" --state open --json number,mergeable -q '.[0]|"\(.number) \(.mergeable)"' 2>/dev/null); pn=${p%% *}; mg=${p##* }
    [ -n "$pn" ] && [ "$mg" = "MERGEABLE" ] && gh pr merge "$pn" --repo $REPO --squash --delete-branch >/dev/null 2>&1 && log "MERGED #$i (PR #$pn, approved)"
  done
  nh=$(printf '%s' "$open" | q "print(' '.join(str(x['number']) for x in json.load(sys.stdin) if any(l['name']=='needs-human' for l in x['labels'])))")
  [ -n "$nh" ] && { echo "RESULT: TRIAGE — needs-human on #$nh"; break; }
  rw_work=$(gh issue list --repo $REPO --state open --label agent-working --json number -q 'length' 2>/dev/null)
  rw_rev=$(gh issue list --repo $REPO --state open --label agent-review --json number -q 'length' 2>/dev/null)
  arv=$(printf '%s' "$open" | q "xs=[x['number'] for x in json.load(sys.stdin) if any(l['name']=='agent-review' for l in x['labels'])];print(xs[0] if xs else '')")
  if [ "${rw_work:-0}" = "0" ] && [ "${rw_rev:-0}" = "0" ]; then
    rdy=$(printf '%s' "$open" | q "xs=[x['number'] for x in json.load(sys.stdin) if any(l['name']=='agent-ready' for l in x['labels']) and not any(l['name']=='needs-human' for l in x['labels'])];print(min(xs) if xs else '')")
    if [ -n "$rdy" ] && [ $(( now - last_disp )) -gt 240 ]; then
      superset organization switch $ORG >/dev/null 2>&1; superset automations run $WORKER >/dev/null 2>&1; last_disp=$now; log "DISPATCHED worker (lowest ready = #$rdy)"
    fi
  fi
  if [ -n "$arv" ]; then
    [ "$arv" != "$rev_issue" ] && { rev_issue=$arv; rev_since=$now; rev_redisp=0; }
    el=$(( now - rev_since ))
    if [ "$el" -gt 720 ]; then
      p=$(gh pr list --repo $REPO --head "agent/issue-$arv" --state open --json number,mergeable -q '.[0]|"\(.number) \(.mergeable)"' 2>/dev/null); pn=${p%% *}; mg=${p##* }
      cr=$(gh pr view "$pn" --repo $REPO --json reviews -q '[.reviews[]|select(.author.login=="coderabbitai")]|length' 2>/dev/null)
      if [ -n "$pn" ] && [ "$mg" = "MERGEABLE" ] && [ "${cr:-0}" -gt 0 ]; then
        gh pr merge "$pn" --repo $REPO --squash --delete-branch >/dev/null 2>&1 && log "FALLBACK-MERGED #$arv (PR #$pn; reviewer stalled, CodeRabbit+CI gate)"
      elif [ "$el" -gt 1080 ]; then echo "RESULT: REVIEW-STALL on #$arv"; break; fi
    elif [ "$el" -gt 480 ] && [ "$rev_redisp" -eq 0 ]; then
      superset organization switch $ORG >/dev/null 2>&1; superset automations run $REVIEWER >/dev/null 2>&1; rev_redisp=1; log "re-dispatched reviewer for #$arv (once)"
    fi
  else rev_issue=""; rev_since=0; rev_redisp=0; fi
  wc=$(superset workspaces list --json 2>/dev/null | q "print(sum(1 for w in json.load(sys.stdin) if (w.get('projectName') or '').find('Vision Pro')>=0))")
  [ -n "$wc" ] && [ "$wc" -gt "$maxws" ] && { maxws=$wc; log "vision-pro workspaces: $wc"; }
  [ -n "$wc" ] && [ "$wc" -gt 5 ] && { echo "RESULT: LEAK-GUARD — $wc workspaces (>5)"; break; }
  if gh api "repos/$REPO/git/ref/heads/_agent-claim-lock" >/dev/null 2>&1; then
    [ "$ref_seen" = 0 ] && ref_seen=$now
    [ $(( now - ref_seen )) -gt 120 ] && { gh api -X DELETE "repos/$REPO/git/refs/heads/_agent-claim-lock" >/dev/null 2>&1; log "cleared stale claim-lock"; ref_seen=0; }
  else ref_seen=0; fi
  sleep 30
done
[ $(date +%s) -ge $deadline ] && echo "RESULT: CHECKPOINT — still in progress"
echo "--- state ---"
gh issue list --repo $REPO --state all --json number,state,labels -q ".[]|select(.number>=$LO and .number<=$HI)|\"#\(.number) [\(.state)] \([.labels[].name]|map(select(startswith(\"agent\")or.==\"needs-human\"or.==\"bounced\"))|join(\",\"))\"" 2>/dev/null | sort
echo "merged #$LO-$HI: $(gh issue list --repo $REPO --state closed --json number -q "[.[]|select(.number>=$LO and .number<=$HI)]|length" 2>/dev/null)/$(( HI-LO+1 ))"
