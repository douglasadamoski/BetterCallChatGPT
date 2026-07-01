#!/usr/bin/env bash
# _codex_common.sh — shared helpers for BetterCallChatGPT.
# Source this; do not execute directly. Provides auth/quota/timeout detection, the
# daily call cap + token ledger, and the `codex exec` runner.
#
# Unlike BetterCallGemini, there is NO edit-guard and NO PTY wrapper:
#   * Read-only is enforced NATIVELY by Codex's sandbox. We always run with
#       codex -a never -c sandbox_mode="read-only" -c approval_policy="never"
#     which blocks the model's file writes / apply_patch / new files / git mutations.
#     (`-a never` and the sandbox/approval keys are the guarantee — verified.)
#   * `codex exec` runs cleanly headless (no TTY needed), so we just run it directly
#     and capture its `--json` stream.
# The prompt is fed on STDIN (via `-` so codex reads instructions from stdin) to avoid
# ARG_MAX limits and the "Reading additional input from stdin" wait.

BCC_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(cd "$BCC_LIB_DIR/.." && pwd)"
STATE_DIR="$SKILL_DIR/state"
LEDGER="$STATE_DIR/usage.jsonl"
THREAD_FILE="$STATE_DIR/last_thread"   # last session id, for --continue

# Initialize temp-file globals so an inherited value can't make cleanup rm an arbitrary file.
BCC_RUN_OUT=""; BCC_RUN_ERR=""; BCC_RAW=""; BCC_META=""
BCC_RESULT="OK"; BCC_RC=0; BCC_THREAD_ID=""
BCC_TOK_IN=0; BCC_TOK_OUT=0; BCC_TOK_CACHED=0; BCC_TOK_REASON=0

# All temp files live under state/ (never /tmp) — the skill leaves no trace elsewhere.
bcc_mktemp() { mkdir -p "$STATE_DIR"; mktemp -p "$STATE_DIR" "bcc.${1:-tmp}.XXXXXX"; }

bcc_now_iso() { date -u +%Y-%m-%dT%H:%M:%SZ; }
bcc_today()   { date -u +%Y-%m-%d; }
bcc_have_codex() { command -v codex >/dev/null 2>&1; }

# --- error classification (signatures verified against codex-cli 0.142.5) ----------
bcc_is_auth_error() {  # $1=file
  grep -qiE "not logged in|unauthenticated|unauthorized|token expired|client authentication not set up|please (log|sign) in|invalid[_ ]?api[_ ]?key|authentication (failed|required)" "$1" 2>/dev/null
}
bcc_is_quota_error() { # $1=file
  grep -qiE "RESOURCE_EXHAUSTED|ResourceExhausted|TooManyRequests|too many requests|\\b429\\b|rate.?limit|quota|usage limit|credits depleted|WorkspaceMemberUsageLimitReached|workspace_owner_credits_depleted|noCredit" "$1" 2>/dev/null
}
bcc_is_net_timeout() { # $1=file
  grep -qiE "request has timed out|timed out|connection timed out|Responses WebSocket failed|provider endpoints are unreachable|network error|failed to fetch" "$1" 2>/dev/null
}

bcc_json_escape() {
  local s="${1:-}"; s="${s//\\/\\\\}"; s="${s//\"/\\\"}"
  s="${s//$'\t'/\\t}"; s="${s//$'\r'/\\r}"; s="${s//$'\n'/\\n}"
  printf '%s' "$s"
}

# bcc_ledger_append mode model scope exit tok_in tok_out tok_cached tok_reason out_file
# flock serializes concurrent appends so lines don't interleave.
bcc_ledger_append() {
  mkdir -p "$STATE_DIR"
  local ti="${5:-0}" to="${6:-0}" tc="${7:-0}" tr="${8:-0}"
  ti="${ti//[!0-9]/}"; to="${to//[!0-9]/}"; tc="${tc//[!0-9]/}"; tr="${tr//[!0-9]/}"
  # flock on a DEDICATED lock file (fd 9), then append the ledger with a fresh `>>`.
  # CRITICAL portability point: do NOT point fd 9 at the ledger itself (`9>>"$LEDGER"`).
  # On CIFS, opening a SECOND append-mode handle on the same file fails every write with
  # EACCES ("printf: write error: Permission denied"). Pointing fd 9 at a separate .lock
  # file leaves exactly one append handle on the ledger (the `>>`), which works on CIFS,
  # ext4, NFS, etc. Mutual exclusion still comes from the lock gating this section.
  {
    flock 9 2>/dev/null || true
    printf '{"ts":"%s","mode":"%s","model":"%s","scope":"%s","tokens_in":%s,"tokens_out":%s,"tokens_cached":%s,"tokens_reasoning":%s,"exit":"%s","out_file":"%s"}\n' \
      "$(bcc_now_iso)" "$(bcc_json_escape "$1")" "$(bcc_json_escape "$2")" \
      "$(bcc_json_escape "$3")" "${ti:-0}" "${to:-0}" "${tc:-0}" "${tr:-0}" \
      "$(bcc_json_escape "$4")" "$(bcc_json_escape "${9:-}")" >> "$LEDGER"
  } 9>"$STATE_DIR/.ledger.lock"
}

# Count today's API calls (exclude AUTH — auth failures consume no quota).
bcc_cap_used() {
  [[ -f "$LEDGER" ]] || { echo 0; return; }
  local n; n="$(grep "^{\"ts\":\"$(bcc_today)" "$LEDGER" 2>/dev/null | grep -vc '"exit":"AUTH"' || true)"
  echo "${n:-0}"
}

# --- codex runner ------------------------------------------------------------------
# Globals set: BCC_RUN_OUT (file: critique text), BCC_RUN_ERR, BCC_RC, BCC_RESULT,
#   BCC_THREAD_ID, BCC_TOK_IN/OUT/CACHED/REASON.
# bcc_run_codex PROMPT_FILE MODEL EFFORT SCOPE CONTINUE_TID
bcc_run_codex() {
  local prompt_file="$1" model="$2" effort="$3" scope="$4" cont_tid="$5"
  rm -f "${BCC_RAW:-}" "${BCC_RUN_ERR:-}" "${BCC_RUN_OUT:-}" "${BCC_META:-}" 2>/dev/null
  BCC_RAW="$(bcc_mktemp raw)"; BCC_RUN_ERR="$(bcc_mktemp err)"
  BCC_RUN_OUT="$(bcc_mktemp out)"; BCC_META="$(bcc_mktemp meta)"
  local hard_to="${BCC_TIMEOUT:-20m}"

  # Base config: read-only sandbox + never-approve + no model network + reasoning effort.
  # `-a` and these `-c` are TOP-LEVEL (before the subcommand) so they apply to exec/resume.
  local -a cmd=( codex -a never
    -c 'sandbox_mode="read-only"'
    -c 'approval_policy="never"'
    -c 'network_access=false'
    -c "model_reasoning_effort=\"$effort\""
    exec )
  # Flags accepted by BOTH `exec` and `exec resume` (verified against codex-cli 0.142.5).
  local -a common=( --ignore-user-config --ignore-rules --skip-git-repo-check --json -m "$model" )
  # Resume a prior session for iterative rounds; otherwise fresh (optionally ephemeral).
  # NOTE: `exec resume` does NOT accept `-C/--cd` or `--color` — the session remembers its
  # working root — so those go on the fresh path only.
  if [[ -n "$cont_tid" ]]; then
    cmd+=( resume "$cont_tid" "${common[@]}" - )
  else
    [[ -n "${BCC_EPHEMERAL:-}" ]] && cmd+=( --ephemeral )
    cmd+=( "${common[@]}" --color never -C "$scope" - )
  fi

  # Prompt on stdin (via `-`); </dev/null is replaced by the prompt file.
  LC_ALL=C timeout --kill-after=15s "$hard_to" "${cmd[@]}" \
    < "$prompt_file" > "$BCC_RAW" 2>"$BCC_RUN_ERR"
  BCC_RC=$?

  # Extract critique text + usage + thread id from the JSONL.
  python3 "$BCC_LIB_DIR/codex_extract.py" "$BCC_RAW" --meta "$BCC_META" > "$BCC_RUN_OUT" 2>>"$BCC_RUN_ERR" || true
  if [[ -s "$BCC_META" ]]; then
    BCC_THREAD_ID="$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1])).get("thread_id",""))' "$BCC_META" 2>/dev/null)"
    BCC_TOK_IN="$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1])).get("input_tokens",0))' "$BCC_META" 2>/dev/null)"
    BCC_TOK_OUT="$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1])).get("output_tokens",0))' "$BCC_META" 2>/dev/null)"
    BCC_TOK_CACHED="$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1])).get("cached_input_tokens",0))' "$BCC_META" 2>/dev/null)"
    BCC_TOK_REASON="$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1])).get("reasoning_output_tokens",0))' "$BCC_META" 2>/dev/null)"
  fi
  # Persist the session id for --continue, but NOT under BCC_EPHEMERAL: an ephemeral run isn't
  # resumable, so recording its id would let a later --continue pick up a stale/dead session.
  [[ -n "$BCC_THREAD_ID" && -z "${BCC_EPHEMERAL:-}" ]] && printf '%s\n' "$BCC_THREAD_ID" > "$THREAD_FILE"

  # Classify. Check the wall-clock TIMEOUT exit first so a killed run's partial output
  # isn't misclassified.
  # IMPORTANT: classify ONLY from stderr ($BCC_RUN_ERR) and the EXTRACTED error metadata
  # ($BCC_META) — NEVER from $BCC_RAW. $BCC_RAW carries the model's own critique text, so
  # reviewing code that mentions "rate limit" / "unauthorized" / "timed out" would otherwise
  # false-trigger QUOTA/AUTH/TIMEOUT on a perfectly successful run. $BCC_META holds only the
  # isolated API error events (from codex_extract.py), never agent-message text.
  BCC_RESULT="OK"
  if [[ "$BCC_RC" -eq 124 || "$BCC_RC" -eq 137 ]]; then
    BCC_RESULT="TIMEOUT"
  elif bcc_is_auth_error "$BCC_RUN_ERR" || bcc_is_auth_error "$BCC_META"; then
    BCC_RESULT="AUTH"
  elif bcc_is_quota_error "$BCC_RUN_ERR" || bcc_is_quota_error "$BCC_META"; then
    BCC_RESULT="QUOTA"
  elif [[ "$BCC_RC" -ne 0 ]]; then
    # A model-network stall shows up as a nonzero exit with a timeout string.
    if bcc_is_net_timeout "$BCC_RUN_ERR" || bcc_is_net_timeout "$BCC_META"; then
      BCC_RESULT="TIMEOUT"
    else
      BCC_RESULT="ERROR"
    fi
  elif [[ ! -s "$BCC_RUN_OUT" ]]; then
    BCC_RESULT="ERROR"   # exit 0 but no agent message — treat as a failed run
  fi
}

# Convenience: is codex logged in? (0 = yes)
bcc_logged_in() { codex login status >/dev/null 2>&1; }
