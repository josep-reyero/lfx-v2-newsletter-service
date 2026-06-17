#!/usr/bin/env bash
# Copyright The Linux Foundation and each contributor to LFX.
# SPDX-License-Identifier: MIT
#
# Execute the pr-reviewer's output against GitHub: post new findings as
# resolvable threads, tally the agent's fixed/not-fixed verdicts on its existing
# threads, post this turn's review summary, and emit whether the head is clean.
#
# This is the deterministic half of the pr-reviewer. The model decides WHAT is
# wrong and WHICH of its prior threads are fixed (findings.json); this script
# decides HOW that reaches GitHub. It holds the token; the model never does.
#
# clean derives from the AGENT OUTPUT, not from GitHub thread state: green only
# when no blocking item is live. A blocking item is live if it is a new blocking
# finding, an existing blocking thread the agent verdicted not-fixed, or an
# existing blocking thread the agent did not verdict at all (fail-closed, so an
# incomplete review can never turn the gate green). Only an explicit "fixed" on
# every blocking thread plus zero new blocking findings is clean.
#
# Inputs (env):
#   REPO        owner/name
#   PR_NUMBER   pull request number
#   FINDINGS    path to the agent's findings.json {summary, findings[], reconcile[]}
#   STATE_FILE  path to fetch-state.sh output (prior threads + summary)
#   HEAD_SHA    head commit (for the summary text)
#   GITHUB_OUTPUT  optional; "clean=true|false" is appended when set
# Honors AGENTIC_DRY_RUN / missing token via lib.sh (prints instead of mutating).

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source-path=SCRIPTDIR
# shellcheck source=lib.sh
. "$HERE/lib.sh"

: "${REPO:?REPO is required}"
: "${PR_NUMBER:?PR_NUMBER is required}"
: "${FINDINGS:?FINDINGS path is required}"
STATE_FILE="${STATE_FILE:-}"
HEAD_SHA="${HEAD_SHA:-}"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# --- 1. Read the agent output -------------------------------------------------
findings_json="$(ag_read_agent_json "$FINDINGS")"
jq -e '(.findings // []) | type == "array"' <<<"$findings_json" >/dev/null \
  || ag_die "findings.json: findings is not an array"
jq -e '(.reconcile // []) | type == "array"' <<<"$findings_json" >/dev/null \
  || ag_die "findings.json: reconcile is not an array"
summary="$(jq -r '.summary // ""' <<<"$findings_json")"

# reconcile verdicts as JSONL of {tid, status}
recon="$TMP/recon.jsonl"
jq -c '(.reconcile // [])[]? | {tid: (.tid // ""), status: (.status // ""), note: (.note // "")}' \
  <<<"$findings_json" >"$recon"
verdict_of() { jq -r --arg tid "$1" 'select(.tid==$tid) | .status' "$recon" 2>/dev/null | head -1; }
note_of()    { jq -r --arg tid "$1" 'select(.tid==$tid) | .note'   "$recon" 2>/dev/null | head -1; }

# Collapse a finding to a single trimmed line for the summary's blocking list.
oneline() { printf '%s' "$1" | tr '\n' ' ' | sed -E 's/  +/ /g; s/^ +//; s/ +$//' | cut -c1-180; }
loc() { if [ "${2:-0}" -gt 0 ] 2>/dev/null; then printf '%s:%s' "$1" "$2"; else printf '%s' "$1"; fi; }

# Accumulates the actionable "still blocking" list rendered into the summary, so
# a developer sees exactly what to fix even when a thread was resolved manually.
blocking_md="$TMP/blocking.md"; : >"$blocking_md"

# prior threads we own (from fetch-state.sh)
threads="$TMP/threads.jsonl"; : >"$threads"
if [ -n "$STATE_FILE" ] && [ -f "$STATE_FILE" ]; then
  jq -c '.threads[]?' "$STATE_FILE" >"$threads"
fi

# Comment body: severity tag, the finding, optional suggestion, hidden marker.
render_body() {
  local sev="$1" comment="$2" suggestion="$3" tid="$4" out
  out="**[${sev}]** ${comment}"
  [ -n "$suggestion" ] && [ "$suggestion" != "null" ] && \
    out="${out}"$'\n\n'"_Suggested fix:_ ${suggestion}"
  printf '%s\n\n%s' "$out" "$(ag_pr_marker "$tid" "$sev")"
}

# --- 2. Tally existing threads from the agent's verdicts ----------------------
# The bot never resolves or reopens threads: GitHub thread state is the
# developer's to manage. The agent's verdict only feeds clean. A blocking thread
# stays live unless the agent explicitly verdicts it fixed; not-fixed, or no
# verdict at all (fail closed), keeps the head not-clean. So a thread a human
# resolved without a real fix still blocks, because clean comes from the verdict,
# not from whether the thread looks resolved. Nits never block.
live_existing_blocking=0
while IFS= read -r th; do
  [ -z "$th" ] && continue
  tid="$(jq -r '.tid' <<<"$th")"
  sev="$(jq -r '.sev' <<<"$th")"
  ag_is_blocking "$sev" || continue
  status="$(verdict_of "$tid")"
  [ "$status" = "fixed" ] && continue   # agent confirms it is fixed: not live
  [ "$status" = "not-fixed" ] || ag_log "no verdict for blocking thread $tid; treating as not-fixed (fail closed)"
  live_existing_blocking=$((live_existing_blocking + 1))
  # Record it in the actionable list. Flag threads a human resolved, since their
  # green checkmark hides that the issue is still live, and fold in any related
  # note the agent attached instead of opening a near-duplicate thread.
  file="$(jq -r '.file // ""' <<<"$th")"; line="$(jq -r '.line // 0' <<<"$th")"
  comment="$(jq -r '.comment // ""' <<<"$th")"; note="$(note_of "$tid")"
  tag=""; [ "$(jq -r '.isResolved' <<<"$th")" = "true" ] && tag=' _(you resolved this thread, but the issue is still present)_'
  # Backticks below are literal Markdown around the location, not expansion.
  # shellcheck disable=SC2016
  printf -- '- **[%s]** `%s` — %s%s\n' "$sev" "$(loc "$file" "$line")" "$(oneline "$comment")" "$tag" >>"$blocking_md"
  { [ -n "$note" ] && [ "$note" != "null" ]; } && printf -- '  - also: %s\n' "$(oneline "$note")" >>"$blocking_md"
done <"$threads"

# --- 3. Post new findings (each gets a fresh stable tid) -----------------------
new_inline="$TMP/new_inline.jsonl"; : >"$new_inline"
unanchored="$TMP/unanchored.txt"; : >"$unanchored"
new_blocking=0
while IFS= read -r f; do
  [ -z "$f" ] && continue
  file="$(jq -r '.file // ""' <<<"$f")"
  line="$(jq -r '.line // 0' <<<"$f")"
  case "$line" in ''|*[!0-9]*) line=0 ;; esac
  sev="$(jq -r '.severity // "should-fix"' <<<"$f")"
  comment="$(jq -r '.comment // ""' <<<"$f" | ag_strip_markers)"
  suggestion="$(jq -r '.suggestion // ""' <<<"$f" | ag_strip_markers)"
  tid="$(ag_new_tid)"
  body="$(render_body "$sev" "$comment" "$suggestion" "$tid")"
  if ag_is_blocking "$sev"; then
    new_blocking=$((new_blocking + 1))
    # shellcheck disable=SC2016
    printf -- '- **[%s]** `%s` — %s\n' "$sev" "$(loc "$file" "$line")" "$(oneline "$comment")" >>"$blocking_md"
  fi
  if [ "$line" -gt 0 ]; then
    jq -nc --arg path "$file" --argjson line "$line" --arg body "$body" \
      '{path:$path, line:$line, side:"RIGHT", body:$body}' >>"$new_inline"
  else
    printf -- '- %s\n' "$(printf '**[%s]** %s: %s' "$sev" "$file" "$(printf '%s' "$comment" | tr '\n' ' ')")" >>"$unanchored"
  fi
done < <(jq -c '.findings[]?' <<<"$findings_json")

post_inline_review() {
  [ ! -s "$new_inline" ] && return 0
  local comments payload
  comments="$(jq -s '.' "$new_inline")"
  payload="$(jq -nc --argjson comments "$comments" '{event:"COMMENT", comments:$comments}')"
  if ag_is_dry_run; then
    ag_log "[dry-run] POST $(jq length <<<"$comments") inline review comment(s) on ${REPO}#${PR_NUMBER}"
    return 0
  fi
  local err="$TMP/review_err.txt"
  if gh api "repos/${REPO}/pulls/${PR_NUMBER}/reviews" --input - <<<"$payload" >/dev/null 2>"$err"; then
    return 0
  fi
  ag_log "batch review failed ($(head -1 "$err" 2>/dev/null)); retrying comments individually"
  while IFS= read -r c; do
    [ -z "$c" ] && continue
    local one
    one="$(jq -nc --argjson c "$c" '{event:"COMMENT", comments:[$c]}')"
    if ! gh api "repos/${REPO}/pulls/${PR_NUMBER}/reviews" --input - <<<"$one" >/dev/null 2>&1; then
      printf -- '- %s\n' "$(jq -r '"\(.path):\(.line) "+(.body|gsub("\n";" "))' <<<"$c")" >>"$unanchored"
    fi
  done <"$new_inline"
}
post_inline_review

# --- 4. Compute clean from the agent output -----------------------------------
total_blocking=$((live_existing_blocking + new_blocking))
clean=true; [ "$total_blocking" -gt 0 ] && clean=false

# --- 5. Post this turn's review summary ---------------------------------------
# A fresh comment per review turn (never edit the previous one), so the PR keeps
# a visible history of how the review evolved across pushes.
summary_file="$TMP/summary.md"
{
  printf '## Agentic review\n\n'
  [ -n "$summary" ] && printf '%s\n\n' "$summary"
  if [ "$clean" = true ]; then
    printf '### No blocking issues\n'
  else
    printf '### Changes required: %s blocking issue(s) must be fixed before merge\n\n' "$total_blocking"
    # Literal Markdown backticks/asterisks below, not shell expansion.
    # shellcheck disable=SC2016
    printf 'Fix each of these in the code. The `agentic-review/clean` status turns green only once the reviewer confirms every one is fixed. **Resolving a thread does not clear a still-present issue.**\n'
    if [ -s "$blocking_md" ]; then
      printf '\n'
      cat "$blocking_md"
    fi
  fi
  if [ -s "$unanchored" ]; then
    printf '\n**Findings not anchored to a diff line:**\n\n'
    cat "$unanchored"
  fi
  # Literal Markdown backticks around the SHA, not shell expansion.
  # shellcheck disable=SC2016
  printf '\n_Reviewed commit `%s`._\n' "${HEAD_SHA:-head}"
  printf '\n%s\n' "$ag_summary_marker"
} >"$summary_file"

post_summary() {
  if ag_is_dry_run; then
    ag_log "[dry-run] post new agentic review summary comment"
    return 0
  fi
  gh api "repos/${REPO}/issues/${PR_NUMBER}/comments" -F body=@"$summary_file" >/dev/null
}
post_summary

# --- 6. Emit the clean verdict ------------------------------------------------
ag_log "clean=${clean} (new_blocking=${new_blocking}, existing_live_blocking=${live_existing_blocking})"
if [ -n "${GITHUB_OUTPUT:-}" ]; then
  printf 'clean=%s\n' "$clean" >>"$GITHUB_OUTPUT"
fi
printf '%s\n' "$clean"
