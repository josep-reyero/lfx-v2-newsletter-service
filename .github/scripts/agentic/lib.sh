# Copyright The Linux Foundation and each contributor to LFX.
# SPDX-License-Identifier: MIT
#
# Shared helpers for the agentic review scripts. Source this file; it defines
# ag_* functions and exposes no side effects on its own. These run in the
# deterministic (no-model) workflow steps, so they hold the write token: keep
# them simple and auditable.

# shellcheck shell=bash
# GraphQL queries below quote $-prefixed variables that are GraphQL variables,
# not shell variables, so they are deliberately single-quoted (SC2016).
# shellcheck disable=SC2016

# Print to stderr.
ag_log() { printf '%s\n' "$*" >&2; }
ag_die() { ag_log "ERROR: $*"; exit 1; }

# True when we must not make mutating GitHub calls: explicit dry-run, or no
# token available. Read-only GraphQL/REST reads still run when a token exists.
# Fails closed: any AGENTIC_DRY_RUN value other than the clearly-off set is
# treated as dry-run, so a typo like AGENTIC_DRY_RUN=true still suppresses
# mutations rather than silently arming them.
ag_is_dry_run() {
  case "${AGENTIC_DRY_RUN:-0}" in
    ''|0|false|FALSE|no|off) : ;;   # not forced on; fall through to token check
    *) return 0 ;;                  # any other value => dry-run
  esac
  [ -z "${GH_TOKEN:-${GITHUB_TOKEN:-}}" ]
}

# Strip Markdown code fences and any prose around a JSON object, mirroring the
# lenient read_agent_json in agents/simulate. Emits the cleaned JSON on stdout,
# or exits non-zero if nothing parseable is found.
ag_read_agent_json() {
  local path="$1" text
  [ -f "$path" ] || ag_die "agent output not found: $path"
  text="$(cat "$path")"
  # Drop a pure-fence first or last line (```json / ```), removing the whole
  # line so no leading blank line remains for downstream byte-exact consumers.
  text="$(printf '%s' "$text" | sed -E '1{/^[[:space:]]*```([a-zA-Z]+)?[[:space:]]*$/d;}; ${/^[[:space:]]*```[[:space:]]*$/d;}')"
  if printf '%s' "$text" | jq -e . >/dev/null 2>&1; then
    printf '%s' "$text"
    return 0
  fi
  # Fallback: the outermost {...} span (first '{' to last '}'). Handles a single
  # JSON object wrapped in prose; multi-object output will fail to parse.
  local block
  block="$(printf '%s' "$text" | tr '\n' '\f' | grep -oE '\{.*\}' | head -1 | tr '\f' '\n')"
  if [ -n "$block" ] && printf '%s' "$block" | jq -e . >/dev/null 2>&1; then
    printf '%s' "$block"
    return 0
  fi
  ag_die "could not parse JSON from $path"
}

# --- Thread identity ----------------------------------------------------------
# A pr-reviewer thread carries a hidden marker in its first comment:
#   <!-- agentic:pr-reviewer tid=<16 hex> sev=<severity> -->
# The tid is minted ONCE when the thread is created and never recomputed, so it
# is stable for the life of the thread regardless of code edits or rewording.
# The role (pr-reviewer) routes ownership; the sev lets clean be computed
# without re-parsing the body.

# Mint a fresh random thread id (16 hex).
ag_new_tid() {
  if command -v openssl >/dev/null 2>&1; then
    openssl rand -hex 8
  else
    od -An -tx1 -N8 /dev/urandom | tr -d ' \n'
  fi
}

# Render the marker for a new thread.
ag_pr_marker() { printf '<!-- agentic:pr-reviewer tid=%s sev=%s -->' "$1" "$2"; }

# Extract tid / sev from a comment body, or empty if it carries no pr-reviewer
# marker. Takes the LAST marker: the real marker is appended last and finding
# text is stripped of markers before posting, so a spoofed marker cannot win.
ag_tid_of() {
  grep -oE 'agentic:pr-reviewer[[:space:]]+tid=[0-9a-f]{16}[[:space:]]+sev=[a-z-]+' \
    | tail -1 | sed -E 's/.*tid=([0-9a-f]{16}).*/\1/'
}
ag_sev_of() {
  grep -oE 'agentic:pr-reviewer[[:space:]]+tid=[0-9a-f]{16}[[:space:]]+sev=[a-z-]+' \
    | tail -1 | sed -E 's/.*sev=([a-z-]+).*/\1/'
}

# Remove any agentic markers a model may have embedded in finding text, so it
# cannot forge a thread id or the summary marker. Reads stdin, writes stdout.
ag_strip_markers() {
  sed -E 's@<!--[[:space:]]*agentic:[^>]*-->@@g
          s@agentic:pr-reviewer[[:space:]]+tid=[0-9a-f]*[[:space:]]+sev=[a-z-]*@@g
          s@agentic:(summary|escalation)@@g
          s@agentic:id=[0-9a-f]*@@g'
}

# Marker on each review summary comment (a fresh PR-level issue comment is posted
# per review turn). Used to detect prior reviews and recover the latest summary.
# shellcheck disable=SC2034
ag_summary_marker='<!-- agentic:summary -->'

# --- Reading prior state (read-only) ------------------------------------------
# Ownership is two-part and fails closed: a thread is the pr-reviewer's only if
# its first comment was authored by us (viewerDidAuthor, GitHub-attested, a PR
# author cannot forge it) AND carries a pr-reviewer marker (routing). Marker
# presence alone is never trusted, since a PR author controls comment content.

# Emit this PR's review threads that WE authored, as JSONL of
# {id, isResolved, path, line, body}. The caller parses tid/sev from body and
# drops any without a pr-reviewer marker. With no token it yields nothing and
# succeeds (dry-run); a real API error returns non-zero so the caller fails
# closed rather than mistaking an error for "no threads."
ag_fetch_owned_threads() {
  local repo="$1" pr="$2" owner name raw total
  owner="${repo%%/*}"; name="${repo#*/}"
  [ -z "${GH_TOKEN:-${GITHUB_TOKEN:-}}" ] && return 0
  if ! raw="$(gh api graphql \
      -f query='query($owner:String!,$name:String!,$pr:Int!){
        repository(owner:$owner,name:$name){
          pullRequest(number:$pr){
            reviewThreads(first:100){
              totalCount
              nodes{
                id isResolved path line
                comments(first:1){ nodes{ body viewerDidAuthor } }
              }
            }
          }
        }
      }' \
      -F owner="$owner" -F name="$name" -F pr="$pr" 2>/dev/null)"; then
    ag_log "ERROR: failed to fetch review threads for ${repo}#${pr}"
    return 1
  fi
  total="$(printf '%s' "$raw" | jq -r '.data.repository.pullRequest.reviewThreads.totalCount // 0')"
  if [ "${total:-0}" -gt 100 ]; then
    ag_log "WARNING: PR has ${total} review threads; only the first 100 are reconciled"
  fi
  printf '%s' "$raw" | jq -c '.data.repository.pullRequest.reviewThreads.nodes[]
    | select(.comments.nodes[0].viewerDidAuthor == true)
    | {id, isResolved, path, line, body: (.comments.nodes[0].body // "")}'
}

# Print the body of the LATEST review summary comment we authored (stripped of
# markers), or nothing if none. A summary is posted per turn, so the most recent
# is the one to show the agent. Presence is the authoritative "this PR has been
# reviewed" signal. Read-only; empty on no token or API error (not-present).
ag_summary_get() {
  local repo="$1" pr="$2" owner name raw
  owner="${repo%%/*}"; name="${repo#*/}"
  [ -z "${GH_TOKEN:-${GITHUB_TOKEN:-}}" ] && return 0
  raw="$(gh api graphql \
      -f query='query($owner:String!,$name:String!,$pr:Int!){
        repository(owner:$owner,name:$name){
          pullRequest(number:$pr){
            comments(first:100){ nodes{ body viewerDidAuthor } }
          }
        }
      }' \
      -F owner="$owner" -F name="$name" -F pr="$pr" 2>/dev/null)" || return 0
  printf '%s' "$raw" | jq -r '[.data.repository.pullRequest.comments.nodes[]
    | select(.viewerDidAuthor == true)
    | select(.body | contains("agentic:summary"))
    | .body] | last // ""'
}

# The bot deliberately never resolves or reopens review threads: GitHub thread
# state is the developer's to manage. The agent's fixed/not-fixed verdict feeds
# the clean status instead (see post-comments.sh), so a thread resolved without a
# real fix still blocks via clean. Hence no resolve/unresolve helpers here.

# Blocking severities gate the clean status; nit does not.
ag_is_blocking() {
  case "$1" in critical|high|should-fix) return 0 ;; *) return 1 ;; esac
}
