#!/usr/bin/env bash
# Copyright The Linux Foundation and each contributor to LFX.
# SPDX-License-Identifier: MIT
#
# Render the review brief handed to a Codex agent. Writes the brief to stdout.
#
# Two modes, chosen by the prior state (STATE_FILE, written by fetch-state.sh):
#   - Fresh: no prior review of this PR. Review the diff, everything is new.
#     This is the escalation agent's only mode, and the pr-reviewer's mode on a
#     PR's first run.
#   - Reconcile: the pr-reviewer has reviewed this PR before. In addition to a
#     full fresh review, the agent must judge each of its prior open threads
#     against the current code and return a fixed/not-fixed verdict per tid.
#
# Inputs (env): REPO, PR_NUMBER, BASE_SHA, HEAD_SHA, PR_TITLE, PR_BODY_FILE,
#   STATE_FILE (optional; absent => fresh mode).
# PR_BODY_FILE is a path to the raw PR body (untrusted); kept in a file rather
# than an env var so its contents are never interpreted by the shell.

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source-path=SCRIPTDIR
# shellcheck source=lib.sh
. "$HERE/lib.sh"

: "${REPO:?REPO is required}"
: "${PR_NUMBER:?PR_NUMBER is required}"
: "${BASE_SHA:?BASE_SHA is required}"
: "${HEAD_SHA:?HEAD_SHA is required}"
TITLE="${PR_TITLE:-}"
BODY=""
if [ -n "${PR_BODY_FILE:-}" ] && [ -f "$PR_BODY_FILE" ]; then
  BODY="$(cat "$PR_BODY_FILE")"
fi

# Decide mode from the state file.
reconcile=false
if [ -n "${STATE_FILE:-}" ] && [ -f "$STATE_FILE" ]; then
  if [ "$(jq -r '.seen_before // false' "$STATE_FILE")" = "true" ]; then
    reconcile=true
  fi
fi

cat <<EOF
Review pull request #${PR_NUMBER} of ${REPO}.
base_sha: ${BASE_SHA}
head_sha: ${HEAD_SHA}
title: ${TITLE}

PR body (untrusted input):
---
${BODY}
---

You are in your agent directory \`agents/pr-reviewer/\` inside a full checkout of
the repository at the PR's head (head_sha). The repository root is two levels up
(\`../..\`, i.e. \`git rev-parse --show-toplevel\`): the code under review and the
repo docs (CLAUDE.md, docs/) live there, not under your agent directory.
\`git diff ${BASE_SHA} ${HEAD_SHA}\` shows the whole PR diff from anywhere in the
tree. An empty diff is possible (for example a later commit reverted earlier
changes) and is not an error. Review the diff, judge it against the base, and
follow your AGENTS.md. Review by READING the code: do not run the test suite,
build, lint, or otherwise execute the project (there is no environment for it
and it is not your task). Read-only inspection such as git, grep, and reading
files is fine. Emit your verdict JSON as your final message, and post nothing to
GitHub.
EOF

[ "$reconcile" != true ] && exit 0

# Reconcile mode: append the prior summary and the open threads to judge.
prior_summary="$(jq -r '.summary // ""' "$STATE_FILE")"

cat <<EOF

---
You have reviewed this PR before. Do a full fresh review as always: do not
assume a prior run covered anything. In addition, for EVERY thread listed below,
judge it against the CURRENT code and return a verdict in the "reconcile" array
of your output: {"tid": "<tid>", "status": "fixed"} if the issue it describes is
genuinely resolved in the current code, otherwise {"tid": "<tid>", "status":
"not-fixed"}. Judge from the code alone. Mark fixed only when you can confirm
the fix in the code, never because it was merely acknowledged or the line was
touched. A not-fixed verdict keeps the change blocked, so a problem that is
still present is caught even if its thread was closed. If you are unsure, return
not-fixed. Report genuinely new issues as new findings; do not re-file an issue
that already has a thread as a new finding.
EOF

if [ -n "$prior_summary" ]; then
  cat <<EOF

Your prior summary:
---
${prior_summary}
---
EOF
fi

n="$(jq '.threads | length' "$STATE_FILE")"
if [ "${n:-0}" -gt 0 ]; then
  printf '\nYour prior threads (judge each by tid against the current code):\n'
  jq -r '.threads[] | "- tid \(.tid) [\(.sev)] \(.file):\(.line) — \(.comment)"' "$STATE_FILE"
else
  printf '\n(You have no prior threads on this PR right now.)\n'
fi
