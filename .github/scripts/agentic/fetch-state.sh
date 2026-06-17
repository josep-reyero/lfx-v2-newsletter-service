#!/usr/bin/env bash
# Copyright The Linux Foundation and each contributor to LFX.
# SPDX-License-Identifier: MIT
#
# Fetch the pr-reviewer's prior state for this PR before the agent runs: the
# review threads WE authored (with their stable tid and severity) and the
# latest review summary text if present. Writes a JSON state file:
#
#   { "seen_before": bool, "summary": "<prior summary text>",
#     "threads": [ {id, tid, sev, isResolved, file, line, comment} ] }
#
# render-brief.sh reads it to choose fresh vs reconcile mode; post-comments.sh
# reads it to execute the agent's verdicts and compute clean. Read-only.
#
# Inputs (env): REPO, PR_NUMBER, STATE_FILE (output path).

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source-path=SCRIPTDIR
# shellcheck source=lib.sh
. "$HERE/lib.sh"

: "${REPO:?REPO is required}"
: "${PR_NUMBER:?PR_NUMBER is required}"
: "${STATE_FILE:?STATE_FILE path is required}"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# Fetch our threads. Fail closed: a fetch error must not look like "no threads",
# which would make the agent review fresh and re-post duplicates.
raw="$TMP/raw.jsonl"
if ! ag_fetch_owned_threads "$REPO" "$PR_NUMBER" >"$raw"; then
  ag_die "could not fetch review threads for ${REPO}#${PR_NUMBER}; aborting (fail closed)"
fi

# Normalize each owned thread: recover tid+sev from the marker, strip markers
# from the body to recover the finding text. Drop any without a pr-reviewer
# marker (viewerDidAuthor can be true for other agentic surfaces).
norm="$TMP/threads.jsonl"; : >"$norm"
while IFS= read -r t; do
  [ -z "$t" ] && continue
  body="$(jq -r '.body // ""' <<<"$t")"
  tid="$(printf '%s' "$body" | ag_tid_of)"
  [ -z "$tid" ] && continue
  sev="$(printf '%s' "$body" | ag_sev_of)"
  resolved="$(jq -r '.isResolved' <<<"$t")"
  # Pass resolved BLOCKING threads (so a fix that was only acknowledged still
  # blocks via the agent's not-fixed verdict), but drop resolved nits: they never
  # block, so re-judging them is pure noise.
  if [ "$resolved" = "true" ] && ! ag_is_blocking "$sev"; then continue; fi
  # Strip both the agentic markers and the leading **[severity]** prefix so the
  # recovered comment is the bare finding text (the summary re-adds the severity).
  comment="$(printf '%s' "$body" | ag_strip_markers \
    | sed -E 's/^[[:space:]]*\*\*\[[a-z-]+\]\*\*[[:space:]]*//; s/^[[:space:]]+//; s/[[:space:]]+$//')"
  jq -nc --argjson t "$t" --arg tid "$tid" --arg sev "$sev" --arg comment "$comment" \
    '{id: $t.id, tid: $tid, sev: $sev, isResolved: $t.isResolved,
      file: ($t.path // ""), line: ($t.line // 0), comment: $comment}' >>"$norm"
done <"$raw"

summary="$(ag_summary_get "$REPO" "$PR_NUMBER")"

# seen_before drives reconcile mode. The summary is the authoritative signal,
# but having any owned thread is equally conclusive, so OR them: that way a
# transient summary-read miss cannot drop us back to a duplicate-posting fresh
# review when threads already exist.
n_threads="$(jq -s 'length' "$norm")"
seen_before=false
{ [ -n "$summary" ] || [ "${n_threads:-0}" -gt 0 ]; } && seen_before=true

jq -s --argjson seen "$seen_before" --arg summary "$summary" \
  '{seen_before: $seen, summary: $summary, threads: .}' "$norm" >"$STATE_FILE"

ag_log "state: seen_before=$seen_before, owned_threads=$n_threads, summary=$([ -n "$summary" ] && echo present || echo absent)"
