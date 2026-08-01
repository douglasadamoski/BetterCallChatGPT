#!/usr/bin/env bash
# codex_review.sh — BetterCallChatGPT: one `codex exec` turn (critique OR experiment).
#
# Runs Codex non-interactively to review/criticize a codebase (and, in experiment mode, to
# PROPOSE scripts as text). Codex is ALWAYS run write-blocked:
#     codex -a never -s read-only -c sandbox_mode="read-only" -c approval_policy="never" ...
# so the model cannot edit the codebase, create files, or run mutations. There is no edit-guard
# because the sandbox is the write-side guarantee. Codex NEVER runs the scripts it proposes —
# Claude reviews and runs those (see run_local.sh).
#
# NOTE read-only blocks WRITES, not READS. The read side is defended by the scope-breadth
# refusal and the scope scan below plus the prompt templates — defence in depth, not a guarantee.
# See the header of _codex_common.sh.
#
# Last stdout line is:  RESULT=<OK|TRUNCATED|AUTH|CAP|QUOTA|TIMEOUT|ERROR>
#
# Usage:
#   codex_review.sh --prompt-file <f> --out <report.md> \
#                   [--scope <dir>]... [--model <m>] [--effort <e>] \
#                   [--cap <N>] [--mode <critique|experiment>] \
#                   [--continue | --thread-id <id>] [--preflight]
#
# --continue resumes THIS SCOPE's last session; --thread-id <id> resumes a specific session and
# is race-free under parallel runs. --preflight runs every gate and makes no billed call.
set -uo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_codex_common.sh"

MODEL="gpt-5.5"
EFFORT="high"
CAP=99999   # effectively unlimited by default; set --cap to enforce a real daily limit
PROMPT_FILE=""; OUT=""; MODE="critique"; CONT=""; TID_ARG=""; PREFLIGHT=0
SCOPES=()

die() { echo "$1" >&2; echo "RESULT=ERROR"; exit 1; }
need() { [[ -n "${2:-}" && "${2:0:1}" != "-" ]] || die "Missing value for $1"; }

# An EARLY signal trap, before any of the gates. Nothing is billed yet at this point, but the
# pre-call work (the scope scan in particular) can take a while on a large tree, and a signal
# there must still leave the caller a RESULT= line to branch on — every other exit path prints
# one. It is replaced below by the full cleanup trap once there is state worth unwinding.
trap 'echo "RESULT=ERROR"; exit 130' INT TERM
while [[ $# -gt 0 ]]; do
  case "$1" in
    --prompt-file) need "$1" "${2:-}"; PROMPT_FILE="$2"; shift 2;;
    --out)         need "$1" "${2:-}"; OUT="$2"; shift 2;;
    --scope)       need "$1" "${2:-}"; SCOPES+=("$2"); shift 2;;
    --model)       need "$1" "${2:-}"; MODEL="$2"; shift 2;;
    --effort)      need "$1" "${2:-}"; EFFORT="$2"; shift 2;;
    --cap)         need "$1" "${2:-}"; CAP="$2"; shift 2;;
    --mode)        need "$1" "${2:-}"; MODE="$2"; shift 2;;
    --continue)    CONT="1"; shift;;
    --thread-id)   need "$1" "${2:-}"; TID_ARG="$2"; shift 2;;  # explicit resume id; safe under concurrency
    --preflight)   PREFLIGHT=1; shift;;
    -h|--help)     sed -n '2,28p' "$0" | sed 's/^# \{0,1\}//'; exit 0;;
    *) die "Unknown arg: $1";;
  esac
done

# --- argument validation ------------------------------------------------------------
[[ -n "$PROMPT_FILE" && -f "$PROMPT_FILE" ]] || die "Missing/invalid --prompt-file"
[[ -s "$PROMPT_FILE" ]] || die "Prompt file is empty: $PROMPT_FILE"
[[ -n "$OUT" ]] || die "Missing --out"
# An existing DIRECTORY at --out used to pass every gate: the writability probe succeeded, the
# atomic `mv -f` succeeded, and the temp landed INSIDE it as report.md/.bcc_report.XXXXXX while
# the caller was told "Report: …/report.md".
if [[ -d "$OUT" || "$OUT" == */ ]]; then
  die "--out must be a file path, not a directory: $OUT"
fi
[[ -L "$OUT" ]] && echo "WARNING: --out is a symlink; the atomic write will REPLACE the link itself, not its target." >&2
case "$MODE" in critique|experiment) ;; *) die "Invalid --mode (critique|experiment): $MODE";; esac
[[ "$CAP" =~ ^[0-9]+$ ]] || die "Invalid --cap (must be an integer): $CAP"
case "$EFFORT" in low|medium|high|xhigh) ;; *) die "Invalid --effort (low|medium|high|xhigh): $EFFORT";; esac
# Garbage here makes `timeout` exit 125, which writes a ledger row for a call that never happened.
[[ "${BCC_TIMEOUT:-20m}" =~ ^[0-9]+[smhd]?$ ]] \
  || die "Invalid \$BCC_TIMEOUT (e.g. 600, 20m, 1h): ${BCC_TIMEOUT:-}"

# --- scopes -------------------------------------------------------------------------
[[ ${#SCOPES[@]} -gt 0 ]] || SCOPES=("$(pwd)")
for _i in "${!SCOPES[@]}"; do
  SCOPES[$_i]="$(bcc_realpath "${SCOPES[$_i]}" || echo "${SCOPES[$_i]}")"
  [[ -e "${SCOPES[$_i]}" ]] || die "Scope does not exist: ${SCOPES[$_i]}"
done
PRIMARY="${SCOPES[0]}"
[[ -d "$PRIMARY" ]] || die "The first --scope must be a directory (it becomes codex's -C): $PRIMARY"
# Extra scopes were canonicalized, printed in the report header as though reviewed, and never
# passed to codex at all — only $PRIMARY becomes -C. Require containment rather than lie.
for _s in "${SCOPES[@]:1}"; do
  [[ "$_s" == "$PRIMARY" || "$_s" == "$PRIMARY"/* ]] \
    || die "Extra --scope must live under the first scope ($PRIMARY): $_s"
done
# Refuse a root so broad that a mistyped --scope points codex at a home directory full of
# credentials. read-only does not restrict reads, so with no read-side defence this is the actual
# exfiltration path — everything read lands in the report AND in OpenAI's session store.
_home_real="$(bcc_realpath "$HOME" 2>/dev/null || echo "$HOME")"
for _s in "${SCOPES[@]}"; do
  case "$_s" in
    /|/home|/Users|/root|/mnt|/media|/Volumes|/var|/tmp|/opt|/srv|/usr|/etc|/private)
      die "Refusing a scope of $_s — point --scope at a project directory." ;;
  esac
  [[ "$_s" == "$_home_real" ]] && die "Refusing a scope of your home directory ($_s) — point --scope at a project."
  [[ "$_home_real" == "$_s"/* ]] && die "Refusing a scope of $_s — it contains your home directory."
done

# --- gates that must pass BEFORE money is spent -------------------------------------
bcc_init_state || die "Could not create the state directory: $STATE_DIR"
if ! _missing="$(bcc_check_deps)"; then
  echo "Missing prerequisites:" >&2
  while IFS= read -r _m; do [[ -n "$_m" ]] && echo "  - $_m" >&2; done <<< "$_missing"
  die "Install the above and retry."
fi
bcc_have_codex || die "'codex' not found on PATH."

mkdir -p "$(dirname "$OUT")" 2>/dev/null
# Fail fast if the report directory isn't writable — BEFORE burning a codex call.
_wt="$(dirname "$OUT")/.bcc_wtest.$$"
{ : > "$_wt"; } 2>/dev/null && rm -f "$_wt" 2>/dev/null || die "Output directory not writable: $(dirname "$OUT")"

# Structural auth check. It is local, free and ~0.1s, and it converts the single most
# consequential classification in the system — AUTH, the cap-exempt class — from "grep chatty
# stderr after paying, and if we guess wrong the call becomes invisible to the cap" into a check
# that cannot be fooled. BCC_SKIP_LOGIN_CHECK=1 for setups where `codex login status` is not
# authoritative (e.g. a pure API-key environment).
LOGIN_STATE="skipped"
if [[ -z "${BCC_SKIP_LOGIN_CHECK:-}" ]]; then
  if bcc_logged_in; then
    LOGIN_STATE="logged in"
  else
    LOGIN_STATE="NOT logged in"
    if [[ "$PREFLIGHT" != 1 ]]; then
      echo "Codex is not authenticated ('codex login status' failed). No call was made, so nothing was billed." >&2
      echo "Run 'codex login' (headless/SSH: 'codex login --device-auth'), confirm with 'codex login status', then retry." >&2
      echo "RESULT=AUTH"; exit 0
    fi
  fi
fi

# Best-effort purge of stale temps from crashed runs (>24h). Matches ONLY `bcc.*`, never
# `orphan-*` — an orphan holds the raw JSON of a paid-for run that was interrupted, and letting
# the 24h purge eat it would quietly undo the salvage. Orphans get their own 30-day sweep.
find "$STATE_DIR" -maxdepth 1 -name 'bcc.*' -mmin +1440 -delete 2>/dev/null || true
find "$STATE_DIR" -maxdepth 1 -name 'orphan-*.jsonl' -mtime +30 -delete 2>/dev/null || true

# --- cap check (no codex call if exhausted) -----------------------------------------
USED="$(bcc_cap_used)"
if [[ "$USED" -ge "$CAP" && "$PREFLIGHT" != 1 ]]; then
  echo "CAP: $USED/$CAP codex calls today. Stop and wait for quota reset, or raise --cap." >&2
  echo "RESULT=CAP"; exit 0
fi

# --- resume id ----------------------------------------------------------------------
# An explicit --thread-id always wins (race-free — Claude reads the id from the prior report);
# otherwise --continue uses THIS SCOPE's session file. A single global last_thread meant that
# reviewing repo A on Monday and running --continue in repo B on Tuesday resumed A's session,
# which KEEPS A's working root (`exec resume` accepts no -C), reviewed the wrong tree, and printed
# repo B in the header — leaking A's contents into a report written into B.
CONT_TID=""
if [[ -n "$TID_ARG" ]]; then
  CONT_TID="$(printf '%s' "$TID_ARG" | tr -d '[:space:]')"
elif [[ -n "$CONT" ]]; then
  if [[ -n "${BCC_EPHEMERAL:-}" ]]; then
    echo "Note: --continue ignored under BCC_EPHEMERAL (no persisted session); pass --thread-id to resume a specific session." >&2
  else
    _sf="$(bcc_session_file "$PRIMARY")" || _sf=""
    if [[ -n "$_sf" && -f "$_sf" ]]; then
      CONT_TID="$(tr -d '[:space:]' < "$_sf" 2>/dev/null)"
    else
      echo "Note: --continue found no prior session for $PRIMARY; starting fresh." >&2
    fi
  fi
fi
# Whichever way the id arrived, the session's own recorded cwd must match this scope. codex stores
# it in the rollout's session_meta, so this costs nothing.
RESUME_CWD_STATE="n/a"
if [[ -n "$CONT_TID" ]]; then
  if _ctx="$(bcc_thread_context "$CONT_TID")"; then
    _rcwd="$(printf '%s' "$_ctx" | cut -f1)"
    if [[ -n "$_rcwd" && "$_rcwd" != "$PRIMARY" ]]; then
      echo "Refusing to resume session $CONT_TID: it was created in" >&2
      echo "  $_rcwd" >&2
      echo "but this run's scope is" >&2
      echo "  $PRIMARY" >&2
      echo "'codex exec resume' cannot be re-pointed (-C is not accepted), so it would review the" >&2
      echo "OTHER tree while this report claimed yours. Drop --continue to start a fresh session." >&2
      die "Cross-project resume refused."
    fi
    RESUME_CWD_STATE="verified ($_rcwd)"
  else
    # FAIL CLOSED. Warning and resuming anyway defeats the whole check: an unverifiable session
    # is exactly the case where it might belong to another tree, and `exec resume` keeps its
    # original working root, so the report would confidently name the wrong directory.
    RESUME_CWD_STATE="UNVERIFIED (no rollout found for $CONT_TID)"
    if [[ -z "${BCC_ALLOW_UNVERIFIED_RESUME:-}" ]]; then
      echo "Refusing to resume session $CONT_TID: its rollout could not be read, so there is no" >&2
      echo "way to confirm it belongs to $PRIMARY. 'codex exec resume' keeps the session's own" >&2
      echo "working root, so resuming blind can review a different tree while this report claims" >&2
      echo "yours. Drop --continue/--thread-id to start fresh, or set BCC_ALLOW_UNVERIFIED_RESUME=1" >&2
      echo "if you are certain the session belongs to this project." >&2
      die "Unverifiable resume refused."
    fi
    echo "WARNING: resuming $CONT_TID unverified (BCC_ALLOW_UNVERIFIED_RESUME=1)." >&2
  fi
fi

# --- read-side scope scan -----------------------------------------------------------
SCAN_NOTE="clean"
if ! bcc_scan_scope "$PRIMARY" "${SCOPES[@]}"; then
  SCAN_NOTE="${#BCC_SCAN_SECRETS[@]} secret-shaped file(s), ${#BCC_SCAN_LINKS[@]} escaping symlink(s)"
  [[ -n "$BCC_SCAN_TRUNCATED" ]] && SCAN_NOTE="$SCAN_NOTE — INCOMPLETE: $BCC_SCAN_TRUNCATED"
  echo "Scope warning — read-only blocks WRITES, not READS, so anything below can be read into the report:" >&2
  [[ ${#BCC_SCAN_SECRETS[@]} -gt 0 ]] && { echo "  secret-shaped files:" >&2; printf '    - %s\n' "${BCC_SCAN_SECRETS[@]}" >&2; }
  [[ ${#BCC_SCAN_LINKS[@]} -gt 0 ]]   && { echo "  symlinks whose target escapes the scope:" >&2; printf '    - %s\n' "${BCC_SCAN_LINKS[@]}" >&2; }
  [[ -n "$BCC_SCAN_TRUNCATED" ]]      && echo "  NOTE: $BCC_SCAN_TRUNCATED — treat 'clean' as unproven." >&2
  if [[ -n "${BCC_STRICT_SCOPE:-}" ]]; then
    die "BCC_STRICT_SCOPE=1 — refusing to review this scope."
  fi
  echo "  (warning only; set BCC_STRICT_SCOPE=1 to make this a refusal)" >&2
fi

# --- preflight: every gate, no billed call ------------------------------------------
if [[ "$PREFLIGHT" == 1 ]]; then
  echo "codex:        $(command -v codex) ($(codex --version 2>/dev/null || echo 'version unknown'))"
  echo "login:        $LOGIN_STATE"
  echo "state dir:    $STATE_DIR"
  echo "ledger:       $LEDGER"
  echo "timeout cmd:  ${BCC_TIMEOUT_CMD:-none} (\$BCC_TIMEOUT=${BCC_TIMEOUT:-20m})"
  echo "mode/model:   $MODE / $MODEL (effort $EFFORT)"
  echo "scopes:       ${SCOPES[*]}"
  echo "working root: $PRIMARY"
  echo "resume:       ${CONT_TID:-none} ${CONT_TID:+[$RESUME_CWD_STATE]}"
  echo "scope scan:   $SCAN_NOTE"
  echo "cap:          $USED/$CAP used today (UTC)"
  echo "report path:  $OUT (directory writable)"
  # Report what a REAL run would do, not merely "the gates ran". Callers branch on RESULT=, so a
  # preflight that prints RESULT=OK while login has failed or the cap is exhausted is telling
  # automation the exact opposite of the truth.
  if [[ "$LOGIN_STATE" == "NOT logged in" ]]; then
    echo "verdict:      a real run would STOP — codex is not authenticated"
    echo "RESULT=AUTH"; exit 0
  fi
  if [[ "$USED" -ge "$CAP" ]]; then
    echo "verdict:      a real run would STOP — daily cap reached"
    echo "RESULT=CAP"; exit 0
  fi
  echo "verdict:      a real run would proceed to launch codex"
  echo "RESULT=OK"
  exit 0
fi

# --- traps: a signal must not destroy a paid-for run --------------------------------
# codex is launched in the BACKGROUND with an explicit wait (see bcc_run_codex), so these fire
# promptly instead of being deferred until codex exits — which for a foreground child meant
# SIGTERM did nothing for up to $BCC_TIMEOUT while codex ran to completion and billed in full.
_bcc_ledgered=0
# Belt-and-braces against a double append. `_bcc_ledgered` records SUCCESS; this records that the
# normal path already tried. The trap exists only to cover a call that never reached the append at
# all, so a failed-but-attempted append must not be retried from the trap — retrying is how one
# billed call becomes two ledger rows and the cap silently halves.
_bcc_ledger_attempted=0
_bcc_report_written=0
OUT_TMP=""
bcc_cleanup() {
  trap '' INT TERM EXIT     # non-re-entrant: a second signal must not abort cleanup
  # Stop codex and WAIT for it to die before touching anything else; otherwise it keeps running
  # unattended after we have already given up on it.
  if [[ -n "${BCC_CHILD:-}" ]]; then
    bcc_kill_child "$BCC_CHILD" || echo "WARNING: codex (pid $BCC_CHILD) did not die." >&2
    wait "$BCC_CHILD" 2>/dev/null || true
    BCC_CHILD=""
  fi
  # Salvage the raw JSON of a call that was paid for but never made it into a report. It must NOT
  # be named state/bcc.* — the 24h stale-temp purge above would quietly delete the salvage.
  if [[ "${BCC_BILLED:-0}" == 1 && "$_bcc_report_written" == 0 && -s "${BCC_RAW:-}" ]]; then
    local _orphan="$STATE_DIR/orphan-$(date -u +%Y%m%dT%H%M%SZ).$$.jsonl"
    if cp "$BCC_RAW" "$_orphan" 2>/dev/null; then
      echo "Saved the interrupted run's raw output to $_orphan (kept 30 days)." >&2
      echo "Recover the report body with: python3 $BCC_LIB_DIR/codex_extract.py $_orphan" >&2
    fi
  fi
  # A launched call that never reached the normal ledger append would vanish from cap accounting,
  # silently raising the effective daily limit. The _bcc_ledgered guard is a HARD precondition,
  # not a detail: this function is registered on EXIT as well as INT/TERM, so an unguarded append
  # would fire on EVERY normal run and halve the cap.
  if [[ "${BCC_BILLED:-0}" == 1 && "$_bcc_ledgered" == 0 && "$_bcc_ledger_attempted" == 0 ]]; then
    bcc_ledger_append "${MODE:-critique}" "${MODEL:-}" "${EFFORT:-}" "$(IFS=,; echo "${SCOPES[*]:-}")" \
      "INTERRUPTED" "${BCC_TOK_IN:-0}" "${BCC_TOK_OUT:-0}" "${BCC_TOK_CACHED:-0}" \
      "${BCC_TOK_REASON:-0}" "${OUT:-}" "$( [[ "${BCC_RC:-0}" -gt 0 ]] && echo "${BCC_RC}" || echo 130 )" \
      "${BCC_THREAD_ID:-}" "${BCC_SANDBOX_VERIFIED:-unknown}" \
      && _bcc_ledgered=1 \
      || echo "WARNING: an interrupted BILLED call could not be recorded in the usage ledger." >&2
  fi
  rm -f "${BCC_RAW:-}" "${BCC_META:-}" "${BCC_RUN_OUT:-}" "${BCC_RUN_ERR:-}" "${BCC_ERRFILE:-}" \
        "${OUT_TMP:-}" 2>/dev/null || true
}
trap bcc_cleanup EXIT
# Run cleanup, print the contract line, THEN exit. Every `die` path prints a RESULT=; this was
# the one path that did not, leaving the caller with no line to branch on.
trap 'bcc_cleanup; echo "RESULT=ERROR"; exit 130' INT TERM

bcc_run_codex "$PROMPT_FILE" "$MODEL" "$EFFORT" "$PRIMARY" "$CONT_TID"

# Record the codex call in the ledger FIRST, so the daily cap stays accurate even if writing the
# report file fails below. Scopes are comma-joined (not space) to stay unambiguous in JSON.
SCOPES_JOINED="$(IFS=,; echo "${SCOPES[*]}")"
_bcc_ledger_attempted=1
if bcc_ledger_append "$MODE" "$MODEL" "$EFFORT" "$SCOPES_JOINED" "$BCC_RESULT" \
     "$BCC_TOK_IN" "$BCC_TOK_OUT" "$BCC_TOK_CACHED" "$BCC_TOK_REASON" "$OUT" \
     "$BCC_RC" "$BCC_THREAD_ID" "$BCC_SANDBOX_VERIFIED"; then
  _bcc_ledgered=1
elif [[ "${BCC_BILLED:-0}" == 1 ]]; then
  # A billed call missing from the ledger silently raises tomorrow's effective cap, so it must not
  # be reported as a clean success — escalate from ANY class.
  LEDGER_FAILED_FROM="$BCC_RESULT"
  BCC_RESULT="ERROR"
fi

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
  [[ -n "$CONT_TID" ]] && echo "- Resumed session: $CONT_TID [$RESUME_CWD_STATE]"
  echo "- Outcome: $BCC_RESULT (codex exit $BCC_RC)"
  echo "- Billed: $([[ "${BCC_BILLED:-0}" == 1 ]] && echo "yes" || echo "no (codex never reached the model)")"
  echo "- Sandbox (resolved config, not kernel enforcement): $BCC_SANDBOX_VERIFIED — $BCC_SANDBOX_WHY"
  echo "- Scope scan: $SCAN_NOTE"
  echo "- Tokens: in=$BCC_TOK_IN (cached=$BCC_TOK_CACHED) out=$BCC_TOK_OUT reasoning=$BCC_TOK_REASON"
  [[ -n "$BCC_THREAD_ID" ]] && echo "- Session id (for --continue): $BCC_THREAD_ID"
  echo; echo "---"; echo
  if [[ ${#BCC_SCAN_SECRETS[@]} -gt 0 || ${#BCC_SCAN_LINKS[@]} -gt 0 ]]; then
    echo "> [!WARNING]"
    echo "> Codex's read-only sandbox blocks WRITES, not READS. These were present in the scope"
    echo "> and could have been read into this report (and into OpenAI's session store):"
    [[ ${#BCC_SCAN_SECRETS[@]} -gt 0 ]] && printf '> - secret-shaped: `%s`\n' "${BCC_SCAN_SECRETS[@]}"
    [[ ${#BCC_SCAN_LINKS[@]} -gt 0 ]]   && printf '> - escaping symlink: `%s`\n' "${BCC_SCAN_LINKS[@]}"
    echo
  fi
  if [[ "$BCC_RESULT" == "AUTH" ]]; then
    echo "> [!IMPORTANT]"
    echo "> Codex is not authenticated. Run \`codex login\` (or, headless/SSH, \`codex login --device-auth\`),"
    echo "> confirm with \`codex login status\` (\"Logged in using ChatGPT\"), then retry."
    echo
  elif [[ "$BCC_RESULT" == "QUOTA" ]]; then
    echo "> [!IMPORTANT]"
    echo "> Rate limit / quota / credits hit. Output may be partial even though the run finished."
    echo "> STOP and wait for reset before retrying."
    echo "> Higher reasoning effort burns the plan's rate limits faster — consider --effort medium."
    echo
  elif [[ "$BCC_RESULT" == "TRUNCATED" ]]; then
    echo "> [!IMPORTANT]"
    echo "> The run stopped early (context/turn exhaustion), so this review is **partial** —"
    echo "> findings below are incomplete, not a clean bill of health. Narrow \`--scope\` and re-run,"
    echo "> or continue the session with \`--thread-id $BCC_THREAD_ID\`."
    echo
  elif [[ "$BCC_RESULT" == "TIMEOUT" ]]; then
    echo "> [!IMPORTANT]"
    echo "> The run exceeded the wrapper timeout (\$BCC_TIMEOUT=${BCC_TIMEOUT:-20m}), was signalled, or a network stall occurred."
    echo "> If the codebase is large or effort is xhigh, raise BCC_TIMEOUT; otherwise treat like a quota stall and wait."
    echo
  fi
  if [[ -n "${LEDGER_FAILED_FROM:-}" ]]; then
    echo "> [!WARNING]"
    echo "> This billed call could NOT be written to the usage ledger ($LEDGER), so today's cap"
    echo "> undercounts by one. The review itself completed as **$LEDGER_FAILED_FROM**."
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
_bcc_report_written=1
# (temps are removed by the bcc_cleanup EXIT trap)

# Recompute usage from the ledger so the printed count matches the cap.
USED_AFTER="$(bcc_cap_used)"
echo "Report: $OUT"
echo "Usage today: $USED_AFTER/$CAP  |  tokens in=$BCC_TOK_IN out=$BCC_TOK_OUT"
echo "RESULT=$BCC_RESULT"
exit 0
