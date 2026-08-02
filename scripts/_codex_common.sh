#!/usr/bin/env bash
# _codex_common.sh — shared helpers for BetterCallChatGPT.
# Source this; do not execute directly. Provides the dependency gate, auth/quota/timeout
# detection, the daily call cap + token ledger, the scope scan, and the `codex exec` runner.
#
# Unlike BetterCallGemini, there is NO edit-guard and NO PTY wrapper:
#   * Write-blocking is enforced NATIVELY by Codex's sandbox. We always run with
#       codex -a never -s read-only -c sandbox_mode="read-only" -c approval_policy="never"
#     which blocks the model's file writes / apply_patch / new files / git mutations.
#   * `codex exec` runs cleanly headless (no TTY needed), so we just run it and capture `--json`.
# The prompt is fed on STDIN (via `-`) to avoid ARG_MAX limits and the "Reading additional input
# from stdin" wait.
#
# WHAT READ-ONLY DOES AND DOES NOT BUY (read this before trusting it)
# `-s read-only` promises no MUTATION. It does NOT restrict READS: under it the model may still
# run read-only shell commands — which is how it explores, and we want that — so `cat
# ~/.aws/credentials`, `cat ../../.env` and `cat ~/.ssh/id_ed25519` are all PERMITTED, and
# whatever is read lands in the report file AND in OpenAI's session store. codex has no
# `--deny Read` equivalent, so the read side is defended by three weaker layers instead:
#   1. the wrapper refuses over-broad roots ($HOME, /, /etc …) — see codex_review.sh;
#   2. the wrapper warns about secret-shaped files and scope-escaping symlinks (bcc_scan_scope);
#   3. the prompt templates tell the model not to read secret-bearing files.
# Layer 3 is a guardrail inside the model's context, not an enforcement boundary. Treat all
# three as defence in depth, never as a guarantee.
#
# WHY `-s read-only` AND the `-c` override (both, deliberately)
# `-c` takes arbitrary keys: a renamed or misspelled key becomes an inert config entry and the
# run silently falls back to codex's default sandbox. MEASURED on codex-cli 0.146.0:
#   -c sandbox_moad="workspace-write"   -> resolved sandbox_mode stayed read-only (silently inert)
#   -s read-only -c sandbox_mode="workspace-write" -> resolved read-only  (the TYPED flag wins)
#   -s read_only                        -> error: invalid value ... (the typed flag fails LOUDLY)
# So `-s` is the authoritative form; the `-c` override is kept for defence in depth. `-s` and
# `-a` are TOP-LEVEL flags, which also means they apply to `exec resume` — `-C/--cd` does not.

BCC_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(cd "$BCC_LIB_DIR/.." && pwd)"

# State lives in ONE install-independent place. Deriving it from BASH_SOURCE meant a plugin
# install and a ~/.claude/skills clone never saw each other's ledger, so `--cap N` silently
# became `2N` and the version-scoped plugin path reset the ledger on every marketplace update.
# (This is not hypothetical in this family: BetterCallGemini has two live ledgers right now.)
STATE_DIR="${BCC_STATE_DIR:-$HOME/.bettercallchatgpt}"
LEGACY_STATE_DIR="$SKILL_DIR/state"
LEDGER="$STATE_DIR/usage.jsonl"
SESSION_DIR="$STATE_DIR/sessions"      # per-scope thread ids; NEVER one global file
CODEX_HOME_DIR="${CODEX_HOME:-$HOME/.codex}"

# Initialize temp-file globals so an inherited value can't make cleanup rm an arbitrary file.
BCC_RUN_OUT=""; BCC_RUN_ERR=""; BCC_RAW=""; BCC_META=""; BCC_ERRFILE=""
BCC_RESULT="OK"; BCC_RC=0; BCC_THREAD_ID=""; BCC_STOP_REASON=""
BCC_TOK_IN=0; BCC_TOK_OUT=0; BCC_TOK_CACHED=0; BCC_TOK_REASON=0
BCC_SANDBOX_VERIFIED="unknown"; BCC_SANDBOX_WHY="not checked"
BCC_CHILD=""
# Set to 1 the instant codex is launched. The daily cap counts THIS, not the outcome word: a run
# reclassified to AUTH because a chatty stderr matched the regex still cost money if the model
# had already produced a body.
BCC_BILLED=0

# `setsid`-equivalent so $! is a process-GROUP leader and cleanup can signal the whole tree.
# python3 is preferred and is a hard dependency anyway: os.setpgrp() + os.execvp() run in the
# SAME process, so $! is deterministically the leader. `setsid --wait` is NOT used — it forks,
# leaving $! as a waiting parent whose PGID is not codex's.
BCC_SETSID=(); BCC_CHILD_IS_LEADER=0
if python3 -c 'import os,sys' >/dev/null 2>&1; then
  BCC_SETSID=(python3 -c 'import os,sys;os.setpgrp();os.execvp(sys.argv[1],sys.argv[1:])')
  BCC_CHILD_IS_LEADER=1
elif command -v setsid >/dev/null 2>&1; then
  BCC_SETSID=(setsid); BCC_CHILD_IS_LEADER=1
fi

# --- state dir + one-time migration -------------------------------------------------
bcc_init_state() {
  mkdir -p "$STATE_DIR" 2>/dev/null || return 1
  [[ "$STATE_DIR" == "$LEGACY_STATE_DIR" ]] && return 0

  # Every place a previous version could have kept a ledger. A skills clone and a plugin install
  # each got their own, so `--cap N` silently became `2N`; the plugin's path is version-scoped, so
  # it also reset on every marketplace update.
  local -a legacies=( "$LEGACY_STATE_DIR/usage.jsonl" "$HOME/.claude/skills/BetterCallChatGPT/state/usage.jsonl" )
  local g
  for g in "$HOME"/.claude/plugins/cache/*bettercallchatgpt*/*/*/state/usage.jsonl \
           "$HOME"/.claude/plugins/cache/*bettercallchatgpt*/*/state/usage.jsonl; do
    [[ -f "$g" ]] && legacies+=("$g")
  done

  # Dedupe by canonical path: the running install is often ALSO one of the well-known locations
  # (a ~/.claude/skills clone is both $SKILL_DIR and the hardcoded skills path), and listing the
  # same ledger twice makes the migration notice look like there are more strays than there are.
  local -a present=()
  local f rf seen_paths=":"
  for f in "${legacies[@]}"; do
    [[ -f "$f" && -s "$f" ]] || continue
    rf="$(bcc_realpath "$f" 2>/dev/null || echo "$f")"
    [[ "$seen_paths" == *":$rf:"* ]] && continue
    seen_paths="${seen_paths}${rf}:"
    present+=("$rf")
  done
  [[ ${#present[@]} -gt 0 ]] || return 0

  if [[ ! -f "$LEDGER" ]]; then
    # MERGE every legacy ledger, don't just copy the biggest. If two installs each billed calls
    # today, seeding from one of them undercounts the cap — which is the same dishonesty the
    # single-ledger change exists to fix, just quieter. Dedupe on the exact line: rows are
    # append-only JSON with a timestamp, so an identical line is genuinely the same call (e.g.
    # a ledger that was previously copied between installs).
    python3 - "$LEDGER" "${present[@]}" <<'PY' 2>/dev/null || true
import sys
out, sources = sys.argv[1], sys.argv[2:]
seen, rows = set(), []
for src in sources:
    try:
        with open(src, encoding="utf-8", errors="replace") as fh:
            for line in fh:
                line = line.rstrip("\n")
                if not line.strip() or line in seen:
                    continue
                seen.add(line)
                rows.append(line)
    except OSError:
        continue
# Chronological where possible, so the file still reads like a log.
rows.sort(key=lambda r: r[9:29] if r.startswith('{"ts":"') else "")
tmp = out + ".tmp"
with open(tmp, "w", encoding="utf-8") as fh:
    for r in rows:
        fh.write(r + "\n")
import os
os.replace(tmp, out)
PY
    [[ -f "$LEDGER" ]] && echo "Note: merged ${#present[@]} legacy usage ledger(s) into $LEDGER." >&2
  fi
  # Anything still sitting in an old location is invisible to the cap from now on. Say so once,
  # by name, so the user can reconcile rather than wonder why the count changed.
  # `present`, not `legacies` — the latter still holds the pre-dedupe list.
  local -a others=("${present[@]}")
  if [[ ${#others[@]} -gt 0 ]]; then
    echo "Note: BetterCallChatGPT now keeps ONE ledger at $LEDGER." >&2
    echo "      These older per-install ledgers are no longer counted (delete them once reconciled):" >&2
    printf '        - %s\n' "${others[@]}" >&2
  fi
  return 0
}

# All wrapper temp files live under $STATE_DIR (never /tmp).
# `mktemp -p DIR TEMPLATE` is GNU-only — BSD/macOS mktemp has no -p and wants the XXXXXX at the
# END. `mktemp "$DIR/prefix.XXXXXX"` satisfies both.
bcc_mktemp() { mkdir -p "$STATE_DIR"; mktemp "$STATE_DIR/bcc.${1:-tmp}.XXXXXX"; }

bcc_now_iso() { date -u +%Y-%m-%dT%H:%M:%SZ; }
bcc_today()   { date -u +%Y-%m-%d; }
bcc_have_codex() { command -v codex >/dev/null 2>&1; }

# Is codex logged in? (0 = yes.) Local, ~0.1s, and free — see bcc_check_login's note.
bcc_logged_in() { codex login status >/dev/null 2>&1; }

# Canonicalize a path, or print nothing. `readlink -f` is GNU-only; python3 is already a hard
# dependency, so it is the portable fallback rather than a silent skip.
bcc_realpath() {
  local r
  r="$(readlink -f "$1" 2>/dev/null)" && [[ -n "$r" ]] && { printf '%s' "$r"; return 0; }
  r="$(python3 -c 'import os,sys;print(os.path.realpath(sys.argv[1]))' "$1" 2>/dev/null)" \
    && [[ -n "$r" ]] && { printf '%s' "$r"; return 0; }
  return 1
}

# sha256 of a STRING, for stable per-scope session filenames.
bcc_sha256_str() {
  local h
  h="$(printf '%s' "$1" | sha256sum 2>/dev/null)" || h="$(printf '%s' "$1" | shasum -a 256 2>/dev/null)" || {
    h="$(python3 -c 'import hashlib,sys;print(hashlib.sha256(sys.argv[1].encode("utf-8","surrogateescape")).hexdigest())' "$1" 2>/dev/null)" || return 1
  }
  printf '%s' "${h%% *}"
}

# The timeout binary that actually supports --kill-after, resolved ONCE into the variable the
# launch path uses. Homebrew installs GNU coreutils g-prefixed unless gnubin is on PATH, so
# `timeout` may not exist at all on an otherwise correctly set up Mac. Resolving it and then
# forgetting the consumer would make every review fail with 127 while the dependency check passed.
bcc_resolve_timeout() {
  if timeout --kill-after=1s 1s sh -c ':' >/dev/null 2>&1; then BCC_TIMEOUT_CMD="timeout"; return 0; fi
  if gtimeout --kill-after=1s 1s sh -c ':' >/dev/null 2>&1; then BCC_TIMEOUT_CMD="gtimeout"; return 0; fi
  BCC_TIMEOUT_CMD=""
  return 1
}
BCC_TIMEOUT_CMD=""
bcc_resolve_timeout || true

# Everything the wrapper needs must exist BEFORE money is spent. These fail at DIFFERENT times
# and only one of them costs anything:
#   python3  — fails AFTER codex has run (the extractor), i.e. billed, then an empty report
#              classified ERROR with the paid-for JSON deleted on the way out. HARD gate.
#   timeout  — fails before launch; not billed, just a confusing failure. Checked for clarity.
#   flock    — never fatal; degrades to an unserialized append. Warned about, not gated.
bcc_check_deps() {
  local missing=() c
  for c in python3 find grep date mktemp; do
    command -v "$c" >/dev/null 2>&1 || missing+=("$c")
  done
  [[ -n "$BCC_TIMEOUT_CMD" ]] || bcc_resolve_timeout \
    || missing+=("timeout or gtimeout supporting --kill-after (GNU coreutils; on macOS: brew install coreutils)")
  local _mt
  _mt="$(mktemp "$STATE_DIR/bcc.deptest.XXXXXX" 2>/dev/null)" && rm -f "$_mt" \
    || missing+=("a working mktemp (could not create a temp in $STATE_DIR)")
  bcc_realpath / >/dev/null 2>&1 || missing+=("a working 'readlink -f' or python3 realpath")
  [[ "${BASH_VERSINFO[0]:-0}" -ge 4 ]] || missing+=("bash >= 4 (found ${BASH_VERSION:-unknown})")
  python3 "$BCC_LIB_DIR/codex_extract.py" --help >/dev/null 2>&1 \
    || missing+=("a working scripts/codex_extract.py")
  if [[ ${#missing[@]} -gt 0 ]]; then
    printf '%s\n' "${missing[@]}"
    return 1
  fi
  command -v flock >/dev/null 2>&1 \
    || echo "Note: 'flock' not found — ledger appends will not be serialized across parallel runs." >&2
  return 0
}

# --- error classification (signatures verified against codex-cli 0.146.0) ----------
bcc_is_auth_error() {  # $1=file
  grep -qiE "not logged in|unauthenticated|unauthorized|token expired|client authentication not set up|please (log|sign) in|invalid[_ ]?api[_ ]?key|authentication (failed|required)" "$1" 2>/dev/null
}
bcc_is_quota_error() { # $1=file
  grep -qiE "RESOURCE_EXHAUSTED|ResourceExhausted|TooManyRequests|too many requests|\\b429\\b|rate.?limit|quota|usage limit|credits depleted|WorkspaceMemberUsageLimitReached|workspace_owner_credits_depleted|noCredit" "$1" 2>/dev/null
}
bcc_is_net_timeout() { # $1=file
  grep -qiE "request has timed out|timed out|connection timed out|Responses WebSocket failed|provider endpoints are unreachable|network error|failed to fetch" "$1" 2>/dev/null
}
# The review stopped early and is therefore PARTIAL. BCC passes no --max-turns equivalent, so for
# codex the likely source is token/context exhaustion rather than turn exhaustion, and the exact
# `--json` signature for a context-limit stop is NOT pinned (see references/codex_notes.md).
# These are the strings worth matching until it is; a partial review reported as a generic ERROR
# hides the fact that it is partial.
bcc_is_truncation() {  # $1=file
  grep -qiE "max turns reached|max_turn_requests|maximum turns|turn limit reached|max tokens reached|max_tokens|context (window )?(limit|exceeded|length exceeded)|exceeds the context" "$1" 2>/dev/null
}

# --- JSON emission -----------------------------------------------------------------
# The full C0 range must be handled, not just the common five: a raw 0x0c/0x1b/0x01 anywhere in a
# path or model name produces a line json.loads rejects with "Invalid control character",
# silently corrupting the ledger for every reader.
bcc_json_escape() {
  local s="${1:-}"
  s="${s//\\/\\\\}"; s="${s//\"/\\\"}"
  s="${s//$'\t'/\\t}"; s="${s//$'\r'/\\r}"; s="${s//$'\n'/\\n}"
  s="${s//$'\b'/\\b}"; s="${s//$'\f'/\\f}"
  local out="" ch i
  if [[ "$s" == *[$'\x01'-$'\x1f']* ]]; then
    for (( i=0; i<${#s}; i++ )); do
      ch="${s:i:1}"
      [[ "$ch" == [$'\x01'-$'\x1f'] ]] && printf -v ch '\\u%04x' "'$ch"
      out+="$ch"
    done
    s="$out"
  fi
  printf '%s' "$s"
}

# A non-negative integer, or 0. Deliberately NOT character deletion (`${v//[!0-9]/}`), which
# turns -5 into 5 and 1e5 into 15 — a silent sign flip in billing data.
bcc_json_int() {
  local v="${1:-}"
  [[ "$v" =~ ^[0-9]+$ ]] && printf '%s' "$v" || printf '0'
}

# bcc_ledger_append mode model effort scope exit tok_in tok_out tok_cached tok_reason \
#                   out_file codex_rc thread_id sandbox_verified
bcc_ledger_append() {
  mkdir -p "$STATE_DIR"
  local ti to tc tr rc
  ti="$(bcc_json_int "${6:-0}")"; to="$(bcc_json_int "${7:-0}")"
  tc="$(bcc_json_int "${8:-0}")"; tr="$(bcc_json_int "${9:-0}")"
  rc="$(bcc_json_int "${11:-0}")"
  local billed="false"; [[ "${BCC_BILLED:-0}" == 1 ]] && billed="true"
  local _rc=0
  # flock on a DEDICATED lock file (fd 9), then append the ledger with a fresh `>>`.
  # CRITICAL portability point: do NOT point fd 9 at the ledger itself (`9>>"$LEDGER"`).
  # On CIFS, opening a SECOND append-mode handle on the same file fails every write with EACCES
  # ("printf: write error: Permission denied"). Pointing fd 9 at a separate .lock file leaves
  # exactly one append handle on the ledger (the `>>`), which works on CIFS, ext4 and NFS.
  # (This repo lives on CIFS, so this is not hypothetical.)
  # The lock is ADVISORY and optional — `|| true`, never `|| _rc=1`. flock is absent on stock
  # macOS and unsupported on some network filesystems, and there the append itself still succeeds.
  # Conflating "could not take the lock" with "could not write the row" made every run on such a
  # host report RESULT=ERROR *and* append twice: the caller saw the failure status, left
  # _bcc_ledgered=0, and the EXIT trap then wrote a second INTERRUPTED row — halving the cap on
  # the one platform least likely to notice. Only the printf may set _rc.
  {
    flock 9 2>/dev/null || true
    printf '{"ts":"%s","mode":"%s","model":"%s","effort":"%s","scope":"%s","tokens_in":%s,"tokens_out":%s,"tokens_cached":%s,"tokens_reasoning":%s,"exit":"%s","codex_rc":%s,"thread_id":"%s","sandbox_verified":"%s","billed":%s,"out_file":"%s"}\n' \
      "$(bcc_now_iso)" "$(bcc_json_escape "${1:-}")" "$(bcc_json_escape "${2:-}")" \
      "$(bcc_json_escape "${3:-}")" "$(bcc_json_escape "${4:-}")" \
      "$ti" "$to" "$tc" "$tr" \
      "$(bcc_json_escape "${5:-}")" "$rc" "$(bcc_json_escape "${12:-}")" \
      "$(bcc_json_escape "${13:-unknown}")" "$billed" \
      "$(bcc_json_escape "${10:-}")" >> "$LEDGER" || _rc=1
  } 9>"$STATE_DIR/.ledger.lock" || _rc=1
  # Check the ACTUAL append status. "The ledger is non-empty" says nothing when it already had
  # rows, and a billed call missing from the ledger silently raises tomorrow's effective cap.
  if [[ "$_rc" -ne 0 ]]; then
    echo "WARNING: could not record this call in $LEDGER (cap accounting may undercount)" >&2
    return 1
  fi
  return 0
}

# Today's BILLED calls. Parsed as JSON, not grepped: a grep counts a line json.loads would reject
# and misses a valid line with a leading space, so the counter and every JSON reader disagree
# permanently. This is the ONE definition of "billed".
bcc_cap_used() {
  [[ -f "$LEDGER" ]] || { echo 0; return; }
  python3 - "$LEDGER" "$(bcc_today)" <<'PY' 2>/dev/null || echo 0
import json, sys
ledger, today = sys.argv[1], sys.argv[2]
FREE = {"AUTH", "CAP"}          # consumed no billable work
n = 0
try:
    with open(ledger, "r", encoding="utf-8", errors="replace") as fh:
        for line in fh:
            # Cheap prefilter: the ledger is append-only and never rotated, so parsing every
            # historical row on every run is pure waste. A row stamped today always contains
            # today's date, so this cannot produce a false negative; a false positive (the date
            # appearing in, say, a report path) is caught by the real ts check below.
            if today not in line:
                continue
            line = line.strip()
            if not line:
                continue
            try:
                row = json.loads(line)
            except ValueError:
                continue
            if not isinstance(row, dict):
                continue
            if str(row.get("ts", ""))[:10] != today:
                continue
            billed = row.get("billed")
            if billed is None:                      # rows written before `billed` existed
                billed = row.get("exit") not in FREE
            if billed:
                n += 1
except OSError:
    pass
print(n)
PY
}

# Per-scope thread file, so `--continue` in project B can never resume project A's session.
bcc_session_file() {
  mkdir -p "$SESSION_DIR" 2>/dev/null
  local k; k="$(bcc_sha256_str "${1:-}")" || return 1
  [[ -n "$k" ]] || return 1
  printf '%s/%s' "$SESSION_DIR" "${k:0:32}"
}

# --- codex rollout introspection (free, structured) ---------------------------------
# codex records each session under $CODEX_HOME/sessions/YYYY/MM/DD/rollout-<ts>-<thread_id>.jsonl.
# Two records there are worth reading and cost nothing:
#   session_meta -> {"cwd": …, "cli_version": …}      (which tree the session actually reviewed)
#   turn_context -> {"cwd": …, "approval_policy": …, "sandbox_policy": {"type":"read-only"}, …}
# Verified on this host at codex-cli 0.146.0.
bcc_rollout_for_thread() {
  local tid="${1:-}"
  [[ -n "$tid" && -d "$CODEX_HOME_DIR/sessions" ]] || return 1
  local f
  f="$(find "$CODEX_HOME_DIR/sessions" -type f -name "rollout-*-${tid}.jsonl" -print 2>/dev/null | head -n1)"
  [[ -n "$f" ]] || return 1
  printf '%s' "$f"
}

# Print "cwd<TAB>sandbox<TAB>approval" for a thread id, or fail.
bcc_thread_context() {
  local f; f="$(bcc_rollout_for_thread "${1:-}")" || return 1
  python3 - "$f" <<'PY' 2>/dev/null || return 1
import json, sys
cwd = sandbox = approval = ""
try:
    with open(sys.argv[1], encoding="utf-8", errors="replace") as fh:
        for line in fh:
            line = line.strip()
            if not line:
                continue
            try:
                o = json.loads(line)
            except ValueError:
                continue
            if not isinstance(o, dict):
                continue
            p = o.get("payload")
            if not isinstance(p, dict):
                continue
            if o.get("type") == "session_meta" and not cwd:
                cwd = str(p.get("cwd", "") or "")
            elif o.get("type") == "turn_context":
                cwd = str(p.get("cwd", "") or cwd)
                sp = p.get("sandbox_policy")
                if isinstance(sp, dict):
                    sandbox = str(sp.get("type", "") or "")
                elif isinstance(sp, str):
                    sandbox = sp
                approval = str(p.get("approval_policy", "") or approval)
except OSError:
    sys.exit(1)
if not (cwd or sandbox or approval):
    sys.exit(1)
print("%s\t%s\t%s" % (cwd, sandbox, approval))
PY
}

# What actually applied, from the rollout — for the ledger and the report header.
#
# TWO CAVEATS, or this becomes false assurance:
#   * It proves the RESOLVED CONFIGURATION, not kernel enforcement. It is the right detector for
#     a silently-dropped `-c` key; it is NOT evidence that Landlock applied.
#   * Under BCC_EPHEMERAL=1 no rollout is written, so it degrades to `unknown` — never to `false`.
# A stderr substring scan was deliberately NOT used: that is exactly the failure mode where a
# chatty-but-successful run gets flipped to a failure, in a new costume.
bcc_sandbox_verify() {
  BCC_SANDBOX_VERIFIED="unknown"
  if [[ -n "${BCC_EPHEMERAL:-}" ]]; then
    BCC_SANDBOX_WHY="ephemeral run — codex writes no rollout, so the resolved config cannot be read"
    return 0
  fi
  if [[ -z "$BCC_THREAD_ID" ]]; then
    BCC_SANDBOX_WHY="no thread id captured — nothing to look up"
    return 0
  fi
  local ctx; ctx="$(bcc_thread_context "$BCC_THREAD_ID")" || {
    BCC_SANDBOX_WHY="no rollout found for thread $BCC_THREAD_ID"
    return 0
  }
  local sandbox approval
  sandbox="$(printf '%s' "$ctx" | cut -f2)"
  approval="$(printf '%s' "$ctx" | cut -f3)"
  if [[ "$sandbox" == "read-only" && "$approval" == "never" ]]; then
    BCC_SANDBOX_VERIFIED="true"
    BCC_SANDBOX_WHY="rollout turn_context: sandbox_policy=read-only, approval_policy=never (resolved config, not kernel enforcement)"
  else
    BCC_SANDBOX_VERIFIED="false"
    BCC_SANDBOX_WHY="rollout turn_context reported sandbox_policy='${sandbox:-?}' approval_policy='${approval:-?}' — expected read-only/never"
  fi
  return 0
}

# --- scope safety scan (read side; runs BEFORE any codex call) ----------------------
# read-only blocks WRITES, not READS. A symlink whose target escapes the scope reads a secret
# straight into the report, and the report is also stored server-side. Neither is addressed by
# any sandbox, because reading is not editing.
#
# This WARNS by default rather than refusing: the equivalent scanner in a sibling skill refused
# 6 of 7 of a real user's project directories, which is worse than useless. BCC_STRICT_SCOPE=1
# turns the findings into a refusal for anyone who wants that trade.
BCC_SCAN_SECRETS=(); BCC_SCAN_LINKS=(); BCC_SCAN_TRUNCATED=""
bcc_scan_scope() {   # $1 = primary scope (containment root); $@ = scopes to walk
  BCC_SCAN_SECRETS=(); BCC_SCAN_LINKS=(); BCC_SCAN_TRUNCATED=""
  local primary="$1"
  [[ -n "${BCC_SKIP_SCAN:-}" ]] && return 0
  local out
  # The heredoc body must follow the line carrying `<<'PY'`, and the command substitution can only
  # close AFTER the terminator — hence the `)"` on its own line below.
  out="$(python3 - "$primary" "$@" 2>/dev/null <<'PY'
import os, sys

primary = os.path.realpath(sys.argv[1])
scopes = sys.argv[2:]

# Heavy, uninteresting trees. Skipping them keeps the scan cheap on a real project; none of them
# is a plausible place for a hand-planted credential.
PRUNE = {".git", "node_modules", ".venv", "venv", "__pycache__", ".mypy_cache",
         ".pytest_cache", ".tox", "target", "dist", "build", ".next", ".cache"}
SECRET_NAMES = {"id_rsa", "id_dsa", "id_ecdsa", "id_ed25519", ".netrc", ".npmrc",
                ".pypirc", ".git-credentials", "credentials", ".htpasswd"}
SECRET_SUFFIX = (".pem", ".key", ".p12", ".pfx", ".jks", ".keystore")
# `.env.example` and friends are templates, not secrets. Flagging them is the noise that makes a
# scanner get ignored.
ENV_TEMPLATES = {".env.example", ".env.sample", ".env.template", ".env.dist", ".env.defaults"}
MAX_HITS = 40
MAX_ENTRIES = 400000

secrets, links = [], []
seen = set()
entries = 0
truncated = False

def is_secret(name, parent):
    low = name.lower()
    if low in ENV_TEMPLATES:
        return False
    if low == ".env" or low.startswith(".env"):
        return True
    if low in SECRET_NAMES:
        # A bare `credentials` only matters inside .aws/ and friends.
        return low != "credentials" or os.path.basename(parent).lower() in (".aws", ".gcloud", ".config")
    return low.endswith(SECRET_SUFFIX)

for scope in scopes:
    for root, dirs, files in os.walk(scope, followlinks=False):
        dirs[:] = [d for d in dirs if d not in PRUNE]
        if os.path.basename(root) == ".ssh":
            for f in files:
                secrets.append(os.path.join(root, f))
        for name in list(files) + list(dirs):
            entries += 1
            if entries > MAX_ENTRIES:
                # Stopping silently would report a huge tree as "clean" while never having looked
                # at the tail of it — a false all-clear on the only read-side warning we have.
                truncated = True
                break
            path = os.path.join(root, name)
            if path in seen:
                continue
            seen.add(path)
            if os.path.islink(path):
                try:
                    target = os.path.realpath(path)
                except OSError:
                    links.append("%s -> <unresolvable>" % path)
                    continue
                if not (target == primary or target.startswith(primary + os.sep)):
                    links.append("%s -> %s" % (path, target))
            elif name in files and is_secret(name, root):
                secrets.append(path)
        if entries > MAX_ENTRIES:
            break

def emit(tag, items):
    for item in sorted(set(items))[:MAX_HITS]:
        print("%s\t%s" % (tag, item.replace("\t", " ").replace("\n", " ")))
    extra = len(set(items)) - MAX_HITS
    if extra > 0:
        print("%s\t… and %d more" % (tag, extra))

emit("secret", secrets)
emit("link", links)
if truncated:
    print("truncated\tscan stopped after %d entries — the rest of the tree was NOT examined" % MAX_ENTRIES)
PY
)" || return 0
  local tag rest
  while IFS=$'\t' read -r tag rest; do
    [[ -z "$tag" ]] && continue
    case "$tag" in
      secret)    BCC_SCAN_SECRETS+=("$rest") ;;
      link)      BCC_SCAN_LINKS+=("$rest") ;;
      truncated) BCC_SCAN_TRUNCATED="$rest" ;;
    esac
  done <<< "$out"
  # An incomplete scan is NOT a clean scan.
  [[ ${#BCC_SCAN_SECRETS[@]} -eq 0 && ${#BCC_SCAN_LINKS[@]} -eq 0 && -z "$BCC_SCAN_TRUNCATED" ]]
}

# --- child process control ----------------------------------------------------------
# Signal the GROUP and the leader. Not `group || pid`: a failed group signal falling through to
# the single pid silently leaves detached workers running.
bcc_kill_child() {
  local pid="${1:-}" i
  [[ -n "$pid" ]] || return 0
  if [[ "${BCC_CHILD_IS_LEADER:-0}" == 1 ]]; then
    kill -TERM -- "-$pid" 2>/dev/null || true
    kill -TERM "$pid" 2>/dev/null || true
  else
    kill -TERM "$pid" 2>/dev/null || true
  fi
  for i in $(seq 1 20); do
    kill -0 "$pid" 2>/dev/null || return 0
    sleep 0.5
  done
  if [[ "${BCC_CHILD_IS_LEADER:-0}" == 1 ]]; then
    kill -KILL -- "-$pid" 2>/dev/null || true
    kill -KILL "$pid" 2>/dev/null || true
  else
    kill -KILL "$pid" 2>/dev/null || true
  fi
  for i in $(seq 1 10); do
    kill -0 "$pid" 2>/dev/null || return 0
    sleep 0.5
  done
  return 1   # still alive after TERM and KILL — the caller must not assume it is quiesced
}

# --- codex runner -------------------------------------------------------------------
# Globals set: BCC_RUN_OUT (file: critique text), BCC_RUN_ERR, BCC_ERRFILE, BCC_RC, BCC_RESULT,
#   BCC_THREAD_ID, BCC_TOK_IN/OUT/CACHED/REASON, BCC_BILLED, BCC_SANDBOX_VERIFIED.
# bcc_run_codex PROMPT_FILE MODEL EFFORT SCOPE CONTINUE_TID
bcc_run_codex() {
  local prompt_file="$1" model="$2" effort="$3" scope="$4" cont_tid="$5"
  rm -f "${BCC_RAW:-}" "${BCC_RUN_ERR:-}" "${BCC_RUN_OUT:-}" "${BCC_META:-}" "${BCC_ERRFILE:-}" 2>/dev/null
  BCC_RAW="$(bcc_mktemp raw)";   BCC_RUN_ERR="$(bcc_mktemp err)"
  BCC_RUN_OUT="$(bcc_mktemp out)"; BCC_META="$(bcc_mktemp meta)"
  BCC_ERRFILE="$(bcc_mktemp errtext)"
  local hard_to="${BCC_TIMEOUT:-20m}"
  # Fail closed rather than exec a name that does not exist: bcc_check_deps should have caught
  # this, but the launch path must not depend on that having run.
  [[ -n "$BCC_TIMEOUT_CMD" ]] || { BCC_RESULT="ERROR"; BCC_RC=127; return 1; }

  # `-a`, `-s` and these `-c` are TOP-LEVEL (before the subcommand) so they apply to exec AND to
  # exec resume. See the header for why BOTH -s and -c sandbox_mode are passed.
  # network_access=false is belt-and-braces: under -s read-only codex's own permissions
  # instruction already reads "Network access is restricted" (rendered via `codex debug
  # prompt-input`), and this key's placement at top level is NOT verified.
  local -a cmd=( codex -a never -s read-only
    -c 'sandbox_mode="read-only"'
    -c 'approval_policy="never"'
    -c 'network_access=false'
    -c "model_reasoning_effort=\"$effort\""
    exec )
  # Flags accepted by BOTH `exec` and `exec resume` (verified against codex-cli 0.146.0).
  local -a common=( --ignore-user-config --ignore-rules --skip-git-repo-check --json -m "$model" )
  # NOTE: `exec resume` accepts neither `-C/--cd` nor `--color` — the session remembers its own
  # working root — so those go on the fresh path only. codex_review.sh refuses a resume whose
  # recorded cwd differs from the current scope, because that root is NOT re-pointable here.
  # --ephemeral goes on BOTH paths. Putting it only on the fresh path meant an explicit
  # --thread-id under BCC_EPHEMERAL=1 still persisted a rollout, so the run was ephemeral in the
  # docs and not in fact.
  if [[ -n "$cont_tid" ]]; then
    cmd+=( resume "$cont_tid" "${common[@]}" )
    [[ -n "${BCC_EPHEMERAL:-}" ]] && cmd+=( --ephemeral )
    cmd+=( - )
  else
    [[ -n "${BCC_EPHEMERAL:-}" ]] && cmd+=( --ephemeral )
    cmd+=( "${common[@]}" --color never -C "$scope" - )
  fi

  # Launched in the BACKGROUND with an explicit `wait`, and as a process-group leader.
  # Foreground would defer any trap until codex exits — measured at 5s on a `sleep 5`, and up to
  # $BCC_TIMEOUT (20 min) here. A SIGTERM would then do nothing while codex ran to completion and
  # billed in full, after which the trap deleted the paid-for JSON and exited without ever
  # appending the ledger row or printing a RESULT= line.
  BCC_BILLED=1                      # set BEFORE the wait: a signal mid-call must still be billed
  ${BCC_SETSID[@]+"${BCC_SETSID[@]}"} env LC_ALL=C \
    "$BCC_TIMEOUT_CMD" --kill-after=15s "$hard_to" "${cmd[@]}" \
    < "$prompt_file" > "$BCC_RAW" 2>"$BCC_RUN_ERR" &
  BCC_CHILD=$!
  wait "$BCC_CHILD"; BCC_RC=$?
  BCC_CHILD=""
  # timeout(1) owns exactly these three: the wrapper itself failed, or codex could not be
  # executed at all. Nothing reached the model. Bias everything else toward OVER-counting —
  # 124/137 (wall-clock timeout) and any signal mean the call ran and must stay billed.
  case "$BCC_RC" in 125|126|127) BCC_BILLED=0 ;; esac

  # ONE python invocation produces the report body (stdout), the meta JSON, the isolated error
  # text for the classifiers, and the KV file. The previous version shelled out to python six
  # times to read one small file.
  local kv; kv="$(bcc_mktemp kv)"
  python3 "$BCC_LIB_DIR/codex_extract.py" "$BCC_RAW" \
    --meta "$BCC_META" --errfile "$BCC_ERRFILE" --kv "$kv" \
    > "$BCC_RUN_OUT" 2>>"$BCC_RUN_ERR" || true
  # Read with a FIXED key allowlist and no `source`: nothing from the model's output is ever
  # evaluated as shell. Values are single-line and tab-free by construction (codex_extract flattens
  # every control character), so one record cannot spill into the next.
  if [[ -s "$kv" ]]; then
    local _k _v
    while IFS=$'\t' read -r _k _v; do
      case "$_k" in
        THREAD_ID)   BCC_THREAD_ID="$_v" ;;
        TOK_IN)      BCC_TOK_IN="$(bcc_json_int "$_v")" ;;
        TOK_CACHED)  BCC_TOK_CACHED="$(bcc_json_int "$_v")" ;;
        TOK_OUT)     BCC_TOK_OUT="$(bcc_json_int "$_v")" ;;
        TOK_REASON)  BCC_TOK_REASON="$(bcc_json_int "$_v")" ;;
        STOP_REASON) BCC_STOP_REASON="$_v" ;;
        *)           : ;;   # unknown keys are ignored, never turned into variables
      esac
    done < "$kv"
  fi
  rm -f "$kv" 2>/dev/null

  # Only now can "never reached the model" be decided, and only on the full conjunction. Each
  # term matters: the AUTH regex matches "unauthorized", which a path like src/unauthorized/x.py
  # produces on a run that DID bill, and AUTH is the cap-exempt class — so a weaker test makes a
  # real charge invisible to the cap. There is deliberately NO request-id term: codex_extract
  # emits thread_id, not a request id, so that clause would be permanently vacuous, and a vacuous
  # term inside a conjunction makes the condition EASIER to satisfy — biasing toward
  # under-counting, the exact opposite of the intent.
  if [[ "$BCC_RC" -ne 0 ]] \
     && [[ "${BCC_TOK_IN:-0}" -eq 0 && "${BCC_TOK_OUT:-0}" -eq 0 ]] \
     && [[ ! -s "$BCC_RUN_OUT" ]] \
     && bcc_is_auth_error "$BCC_RUN_ERR"; then
    BCC_BILLED=0
  fi

  # --- classify --------------------------------------------------------------------
  # Classify ONLY from stderr ($BCC_RUN_ERR) and the ISOLATED error text ($BCC_ERRFILE) — NEVER
  # from $BCC_RAW, which carries the model's own critique. Reviewing code that mentions "rate
  # limit" or "unauthorized" would otherwise false-trigger QUOTA/AUTH on a successful run.
  #
  # A run that exited 0 WITH a report body succeeded, whatever its stderr says. codex's stderr is
  # chatty, and `info: quota check passed` or `read_file src/unauthorized/a.py` legitimately
  # appear there. Grepping it on such a run used to report a completed, billed review as AUTH —
  # which is cap-exempt, so the call also vanished from the cap — or as QUOTA.
  #
  # But AUTH and QUOTA are NOT symmetric, and gating both would be its own bug:
  #   * AUTH is gated. Exit 0 with a body means authenticated, full stop.
  #   * QUOTA stays UNCONDITIONAL. A run where codex hits its rate limiter, degrades and still
  #     exits 0 with a partial body must not be reported as a clean OK — that is a partial review
  #     presented as complete. The caller's action (stop and wait) is right either way, and the
  #     cap is unaffected because it counts `billed`, not the outcome word.
  local failed=0
  [[ "$BCC_RC" -ne 0 || ! -s "$BCC_RUN_OUT" ]] && failed=1

  # "Unconditional" means unconditional on STRUCTURED evidence, which is the distinction that
  # makes this work. $BCC_ERRFILE holds only allow-listed fields of codex's own error EVENTS, so
  # a throttled-but-completed turn still lands there and is still reported. Raw stderr is not
  # structured — `info: quota check passed` matches the same regex — so it only counts when the
  # run actually failed. Grepping raw stderr unconditionally reported a completed, billed review
  # with a good body as QUOTA, which is the very failure this classifier exists to prevent.
  local quota=0
  bcc_is_quota_error "$BCC_ERRFILE" && quota=1
  [[ "$failed" -eq 1 ]] && bcc_is_quota_error "$BCC_RUN_ERR" && quota=1

  BCC_RESULT="OK"
  if [[ "$BCC_RC" -eq 124 || "$BCC_RC" -eq 137 ]]; then
    # Wall-clock timeout (timeout(1) fired). Checked FIRST so a killed run's partial output cannot
    # be misread as a quota error.
    BCC_RESULT="TIMEOUT"
  elif [[ "$BCC_RC" -eq 130 || "$BCC_RC" -eq 143 ]]; then
    # SIGINT / SIGTERM. These previously fell through to a bare ERROR by accident; they are now
    # classified DELIBERATELY, and deliberately as ERROR rather than TIMEOUT — the wrapper's own
    # INT/TERM trap prints RESULT=ERROR, and the two paths describe the same event (somebody
    # stopped this run), so they must not disagree on the one line the caller branches on.
    # TIMEOUT's documented advice is "raise $BCC_TIMEOUT and retry", which is wrong for a
    # deliberate interrupt. The precise exit status is preserved in the ledger's codex_rc.
    BCC_RESULT="ERROR"
  elif [[ "$quota" -eq 1 ]]; then
    BCC_RESULT="QUOTA"
  elif [[ "$BCC_STOP_REASON" == "max_tokens" || "$BCC_STOP_REASON" == "max_turn_requests" ]] \
       || { [[ "$failed" -eq 1 ]] && { bcc_is_truncation "$BCC_RUN_ERR" || bcc_is_truncation "$BCC_ERRFILE"; }; }; then
    # Ran out of context/turns: the review is PARTIAL. Checked BEFORE the generic non-zero-exit
    # branch, because a truncated review reported as a plain ERROR hides that it is partial.
    BCC_RESULT="TRUNCATED"
  elif [[ "$failed" -eq 1 ]]; then
    # AUTH additionally requires an EMPTY report body, not merely `failed`. The regex matches
    # `unauthorized` and `invalid_api_key`, which a tool error naming a path like
    # src/unauthorized/x.py or invalid_api_key.js reproduces on a run that reached the model and
    # produced a critique. Word boundaries do not help (a `/` is one), and grep -E has no
    # lookahead — but a genuine auth failure never returns a body, so the body is the clean
    # discriminator. Without it the user is told to re-authenticate on top of a real review.
    if [[ ! -s "$BCC_RUN_OUT" ]] \
       && { bcc_is_auth_error "$BCC_RUN_ERR" || bcc_is_auth_error "$BCC_ERRFILE"; }; then
      BCC_RESULT="AUTH"
    elif bcc_is_net_timeout "$BCC_RUN_ERR" || bcc_is_net_timeout "$BCC_ERRFILE"; then
      BCC_RESULT="TIMEOUT"
    else
      BCC_RESULT="ERROR"
    fi
  fi

  # What actually applied, read from the rollout (free, structured).
  bcc_sandbox_verify

  # Persist the thread id PER SCOPE. Never under BCC_EPHEMERAL: an ephemeral run isn't resumable,
  # so recording its id would let a later --continue pick up a dead session.
  if [[ -n "$BCC_THREAD_ID" && -z "${BCC_EPHEMERAL:-}" ]]; then
    local sf; sf="$(bcc_session_file "$scope")" \
      && printf '%s\n' "$BCC_THREAD_ID" > "$sf" 2>/dev/null || true
  fi
  return 0
}
