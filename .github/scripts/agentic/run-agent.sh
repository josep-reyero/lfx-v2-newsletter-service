#!/usr/bin/env bash
# Copyright The Linux Foundation and each contributor to LFX.
# SPDX-License-Identifier: MIT
#
# Run one Codex agent over a brief and capture its verdict JSON. This is the
# exact invocation proven in agents/simulate/simulate.sh: the agent's cwd is its
# own folder (its identity), workspace-write lets it write only inside that
# folder, and reasoning effort is pinned so CI matches the evaluation.
#
# The agent holds no token that can comment, approve, or merge. It only produces
# judgment as data; a separate deterministic step decides how that reaches
# GitHub. The verdict is written outside the agent directory so a compromised
# run cannot tamper with it.
#
# Usage: run-agent.sh <agent-dir-name> <output-json> <brief-file>

set -euo pipefail

AGENT="${1:?agent dir name required}"
OUT="${2:?output json path required}"
BRIEF="${3:?brief file required}"

REPO_ROOT="$(git rev-parse --show-toplevel)"
AGENT_DIR="$REPO_ROOT/agents/$AGENT"
[ -d "$AGENT_DIR" ] || { echo "ERROR: agent dir not found: $AGENT_DIR" >&2; exit 1; }
[ -f "$BRIEF" ] || { echo "ERROR: brief not found: $BRIEF" >&2; exit 1; }

EFFORT="${CODEX_EFFORT:-xhigh}"

# Capture the full Codex transcript to a file (it is verbose and the verdict we
# care about is written separately via --output-last-message). On failure, the
# transcript holds the only diagnostic (auth, model access, sandbox), so surface
# its tail to stderr instead of leaving CI with a bare "exit code 1".
set +e
codex exec \
  --cd "$AGENT_DIR" \
  --sandbox workspace-write \
  -c model_reasoning_effort="$EFFORT" \
  --output-last-message "$OUT" \
  - < "$BRIEF" > "$OUT.transcript.log" 2>&1
rc=$?
set -e

if [ "$rc" -ne 0 ]; then
  echo "ERROR: codex exec failed (exit $rc) for agent '$AGENT'." >&2
  echo "--- transcript tail (last 60 lines) ---" >&2
  tail -n 60 "$OUT.transcript.log" >&2 || true
  echo "--- end transcript tail ---" >&2
  exit "$rc"
fi
