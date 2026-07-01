#!/usr/bin/env bash
# codex_review.sh — BetterCallChatGPT: one `codex exec` turn (critique OR experiment).
#
# Runs Codex non-interactively to review/criticize a codebase (and, in experiment
# mode, to PROPOSE scripts as text). Codex is ALWAYS run read-only:
#     codex -a never -c sandbox_mode="read-only" -c approval_policy="never" ...
# so the model cannot edit the codebase, create files, or run mutations. There is no
# edit-guard because the sandbox is the guarantee. Codex NEVER runs the scripts it
# proposes — Claude reviews and runs those (see run_local.sh).
#
# Last stdout line is:  RESULT=<OK|AUTH|CAP|QUOTA|TIMEOUT|ERROR>
#
# Usage:
#   codex_review.sh --prompt-file <f> --out <report.md> \
#                   [--scope <dir>]... [--model <m>] [--effort <e>] \
#                   [--cap <N>] [--mode <critique|experiment>] \
#                   [--continue | --thread-id <id>]
#
# --continue resumes the last session (state/last_thread); --thread-id <id> resumes a specific
# session and is race-free under parallel runs (Claude reads the id from a prior report).
set -uo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_codex_common.sh"

MODEL="gpt-5.5"
EFFORT="high"
CAP=99999   # effectively unlimited by default; set --cap to enforce a real daily limit
PROMPT_FILE=""; OUT=""; MODE="critique"; CONT=""; TID_ARG=""
SCOPES=()

die() { echo "$1" >&2; echo "RESULT=ERROR"; exit 1; }
while [[ $# -gt 0 ]]; do
  case "$1" in
    --prompt-file) PROMPT_FILE="${2:-}"; shift 2 2>/dev/null || shift "$#";;
    --out)         OUT="${2:-}"; shift 2 2>/dev/null || shift "$#";;
    --scope)       SCOPES+=("${2:-}"); shift 2 2>/dev/null || shift "$#";;
    --model)       MODEL="${2:-}"; shift 2 2>/dev/null || shift "$#";;
    --effort)      EFFORT="${2:-}"; shift 2 2>/dev/null || shift "$#";;
    --cap)         CAP="${2:-}"; shift 2 2>/dev/null || shift "$#";;
    --mode)        MODE="${2:-}"; shift 2 2>/dev/null || shift "$#";;
    --continue)    CONT="1"; shift;;
    --thread-id)   TID_ARG="${2:-}"; shift 2 2>/dev/null || shift "$#";;  # explicit resume id (beats last_thread; safe under concurrency)
    *) die "Unknown arg: $1";;
  esac
done
[[ -n "$PROMPT_FILE" && -f "$PROMPT_FILE" ]] || die "Missing/invalid --prompt-file"
[[ -n "$OUT" ]] || die "Missing --out"
[[ ${#SCOPES[@]} -gt 0 ]] || SCOPES=("$(pwd)")
# Canonicalize scopes to absolute paths; the first is Codex's working root (-C).
for _i in "${!SCOPES[@]}"; do SCOPES[$_i]="$(readlink -f "${SCOPES[$_i]}" 2>/dev/null || echo "${SCOPES[$_i]}")"; done
PRIMARY="${SCOPES[0]}"
[[ -d "$PRIMARY" ]] || die "Primary scope is not a directory: $PRIMARY"
[[ "$CAP" =~ ^[0-9]+$ ]] || die "Invalid --cap (must be an integer): $CAP"
case "$EFFORT" in low|medium|high|xhigh) ;; *) die "Invalid --effort (low|medium|high|xhigh): $EFFORT";; esac
mkdir -p "$(dirname "$OUT")" "$STATE_DIR"
# Fail fast if the report directory isn't writable — BEFORE burning a codex call.
_wt="$(dirname "$OUT")/.bcc_wtest.$$"
{ : > "$_wt"; } 2>/dev/null && rm -f "$_wt" 2>/dev/null || die "Output directory not writable: $(dirname "$OUT")"

bcc_have_codex || die "'codex' not found on PATH."
# Best-effort purge of stale temps from crashed runs (>24h old).
find "$STATE_DIR" -maxdepth 1 -name 'bcc.*' -mmin +1440 -delete 2>/dev/null || true

# Cap check (no codex call if exhausted).
USED="$(bcc_cap_used)"
if [[ "$USED" -ge "$CAP" ]]; then
  echo "CAP: $USED/$CAP codex calls today. Stop and wait for quota reset, or raise --cap." >&2
  echo "RESULT=CAP"; exit 0
fi

# Resume id: an explicit --thread-id always wins (race-free under concurrency — Claude reads
# the id from the prior report's "Session id" line); otherwise --continue falls back to the
# shared state/last_thread, which parallel runs can clobber.
CONT_TID=""
if [[ -n "$TID_ARG" ]]; then
  CONT_TID="$(printf '%s' "$TID_ARG" | tr -d '[:space:]')"
elif [[ -n "$CONT" ]]; then
  if [[ -n "${BCC_EPHEMERAL:-}" ]]; then
    echo "Note: --continue ignored under BCC_EPHEMERAL (no persisted session); pass --thread-id to resume a specific session." >&2
  elif [[ -f "$THREAD_FILE" ]]; then
    CONT_TID="$(tr -d '[:space:]' < "$THREAD_FILE" 2>/dev/null)"
  fi
fi

# Clean up ALL temps on any exit (incl. early INT/TERM/die) so state/ (and the report dir)
# never leak files.
OUT_TMP=""
bcc_cleanup() {
  trap '' INT TERM EXIT
  rm -f "${BCC_RAW:-}" "${BCC_META:-}" "${BCC_RUN_OUT:-}" "${BCC_RUN_ERR:-}" "${OUT_TMP:-}" 2>/dev/null || true
}
trap bcc_cleanup EXIT
trap 'bcc_cleanup; exit 130' INT TERM

bcc_run_codex "$PROMPT_FILE" "$MODEL" "$EFFORT" "$PRIMARY" "$CONT_TID"

# Record the codex call in the ledger FIRST, so the daily cap stays accurate even if writing
# the report file fails below. Scopes are comma-joined (not space) to stay unambiguous in JSON.
SCOPES_JOINED="$(IFS=,; echo "${SCOPES[*]}")"
bcc_ledger_append "$MODE" "$MODEL" "$SCOPES_JOINED" "$BCC_RESULT" \
  "$BCC_TOK_IN" "$BCC_TOK_OUT" "$BCC_TOK_CACHED" "$BCC_TOK_REASON" "$OUT"

# Write report to a same-dir temp, then atomically mv it over $OUT. `mv` renames over any
# symlink/file at $OUT without following it, closing the rm-then-redirect TOCTOU window. Fall
# back to a direct (rm-guarded) write if the dir isn't writable for a temp. A write/mv FAILURE
# must surface as RESULT=ERROR — never a false RESULT=OK with a bogus Report path.
OUT_TMP="$(mktemp "$(dirname "$OUT")/.bcc_report.XXXXXX" 2>/dev/null || true)"
DEST="${OUT_TMP:-$OUT}"
[[ -z "$OUT_TMP" ]] && rm -f "$OUT" 2>/dev/null
if ! {
  echo "# BetterCallChatGPT report ($MODE)"
  echo
  echo "- Generated: $(bcc_now_iso)"
  echo "- Model: $MODEL (reasoning effort: $EFFORT)"
  echo "- Scope(s): ${SCOPES[*]}"
  echo "- Working root (-C): $PRIMARY"
  [[ -n "$CONT_TID" ]] && echo "- Resumed session: $CONT_TID"
  echo "- Outcome: $BCC_RESULT (codex exit $BCC_RC)"
  echo "- Tokens: in=$BCC_TOK_IN (cached=$BCC_TOK_CACHED) out=$BCC_TOK_OUT reasoning=$BCC_TOK_REASON"
  [[ -n "$BCC_THREAD_ID" ]] && echo "- Session id (for --continue): $BCC_THREAD_ID"
  echo; echo "---"; echo
  if [[ "$BCC_RESULT" == "AUTH" ]]; then
    echo "> [!IMPORTANT]"
    echo "> Codex is not authenticated. Run \`codex login\` (or, headless/SSH, \`codex login --device-auth\`),"
    echo "> confirm with \`codex login status\` (\"Logged in using ChatGPT\"), then retry."
    echo
  elif [[ "$BCC_RESULT" == "QUOTA" ]]; then
    echo "> [!IMPORTANT]"
    echo "> Rate limit / quota / credits hit. Output may be partial. STOP and wait for reset before retrying."
    echo "> Higher reasoning effort burns the plan's rate limits faster — consider --effort medium."
    echo
  elif [[ "$BCC_RESULT" == "TIMEOUT" ]]; then
    echo "> [!IMPORTANT]"
    echo "> The run exceeded the wrapper timeout (\$BCC_TIMEOUT=${BCC_TIMEOUT:-20m}) or a network stall occurred."
    echo "> If the codebase is large or effort is xhigh, raise BCC_TIMEOUT; otherwise treat like a quota stall and wait."
    echo
  fi
  cat "$BCC_RUN_OUT"
  if [[ "$BCC_RESULT" != "OK" && -s "$BCC_RUN_ERR" ]]; then
    echo; echo "<details><summary>codex stderr</summary>"; echo
    echo '```'; tail -n 40 "$BCC_RUN_ERR"; echo '```'; echo "</details>"
  fi
} > "$DEST" 2>/dev/null; then
  echo "ERROR: failed to write report to $DEST (codex result was $BCC_RESULT)" >&2
  echo "RESULT=ERROR"; exit 1
fi
if [[ -n "$OUT_TMP" ]]; then
  if mv -f "$OUT_TMP" "$OUT" 2>/dev/null; then OUT_TMP=""
  else echo "ERROR: failed to finalize report at $OUT (codex result was $BCC_RESULT)" >&2; echo "RESULT=ERROR"; exit 1; fi
fi
# (temps are removed by the bcc_cleanup EXIT trap)

# Recompute usage from the ledger so the printed count matches the cap (AUTH is excluded by
# bcc_cap_used, so it won't be over-reported here).
USED_AFTER="$(bcc_cap_used)"
echo "Report: $OUT"
echo "Usage today: $USED_AFTER/$CAP  |  tokens in=$BCC_TOK_IN out=$BCC_TOK_OUT"
echo "RESULT=$BCC_RESULT"
exit 0
