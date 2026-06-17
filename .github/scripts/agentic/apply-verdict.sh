#!/usr/bin/env bash
# Copyright The Linux Foundation and each contributor to LFX.
# SPDX-License-Identifier: MIT
#
# Apply the escalation judge's verdict (escalation.json: {needs-human, reason}).
# The needs-human label is sticky and add-only: this script only ever ADDS it,
# never removes it, so a later push that makes the change benign does not
# un-escalate. Only a human clears the label. A false verdict is a no-op.
#
# To avoid a new comment on every push, the label is added and the reason
# commented only when the PR is not already escalated; once set it stays.
#
# Inputs (env): REPO, PR_NUMBER, VERDICT (path to escalation.json).
# Honors AGENTIC_DRY_RUN / missing token via lib.sh.

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source-path=SCRIPTDIR
# shellcheck source=lib.sh
. "$HERE/lib.sh"

: "${REPO:?REPO is required}"
: "${PR_NUMBER:?PR_NUMBER is required}"
: "${VERDICT:?VERDICT path is required}"

LABEL="needs-human"

verdict_json="$(ag_read_agent_json "$VERDICT")"
needs_human="$(jq -r '."needs-human" // false' <<<"$verdict_json")"
reason="$(jq -r '.reason // ""' <<<"$verdict_json" | ag_strip_markers)"

if [ "$needs_human" != "true" ]; then
  # No label change (the judge never removes it), but record why it declined to
  # escalate, so the decision is auditable in the run summary.
  ag_log "needs-human=false: ${reason:-<no reason given>}"
  if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
    printf 'Escalation judge: needs-human=false. %s\n' "${reason:-<no reason given>}" >> "$GITHUB_STEP_SUMMARY"
  fi
  exit 0
fi

# Is the PR already escalated? This gates only the comment (anti-spam), never
# the label: the label is the gate's safety signal and must always be applied
# when the verdict is true. On a read failure, fail closed for the comment
# (assume already escalated, skip it) but still add the label below.
already=false
if [ -n "${GH_TOKEN:-${GITHUB_TOKEN:-}}" ]; then
  if labels_has="$(gh pr view "$PR_NUMBER" --repo "$REPO" --json labels \
       --jq 'any(.labels[].name; . == "needs-human")' 2>/dev/null)"; then
    [ "$labels_has" = "true" ] && already=true
  else
    ag_log "could not read PR labels; adding the label but skipping the comment"
    already=true
  fi
fi

if ag_is_dry_run; then
  if [ "$already" = true ]; then
    ag_log "[dry-run] ensure label '$LABEL' (already escalated; no comment)"
  else
    ag_log "[dry-run] add label '$LABEL' and comment: needs-human: $reason"
  fi
  exit 0
fi

# Always ensure and add the label (idempotent) — this is the safety-critical
# action the gate reads. Label first, then comment, so the PR is never
# commented-but-unlabeled; keep that order.
gh label create "$LABEL" --repo "$REPO" \
  --color FBCA04 --description "Agentic escalation: a human must review before merge" \
  --force >/dev/null 2>&1 || true
gh pr edit "$PR_NUMBER" --repo "$REPO" --add-label "$LABEL" >/dev/null

if [ "$already" = true ]; then
  ag_log "label ensured; already escalated, no duplicate comment"
else
  gh pr comment "$PR_NUMBER" --repo "$REPO" \
    --body "**needs-human** set by the escalation judge: ${reason}"
  ag_log "escalated: $reason"
fi
