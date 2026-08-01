#!/usr/bin/env bash
# run_local.sh — Claude executes an APPROVED, Codex-proposed script inside a sandbox
# dir. Codex (running read-only) never runs the scripts it proposes — it may inspect the
# repo with read-only commands, but cannot execute proposals or mutate anything; it only
# proposes script text in its report. Claude writes that script into a sandbox dir, reviews it, and then
# runs it here. Execution runs with cwd = the sandbox dir, in a conda env
# (--env / $BCC_CONDA_ENV, default `base`). NOTE: this is NOT a security jail — it only
# verifies the script lives under the sandbox; review scripts before running them.
#
# Usage:
#   run_local.sh --sandbox <sandbox_dir> --script <path-under-sandbox> \
#                [--interpreter <cmd>] [--env <conda_env>] [--timeout <secs>] [-- <args...>]
#
# --interpreter overrides the extension heuristic and may include flags (e.g.
# "python -u", "ts-node", "node"). Pass it with whatever run command Codex specified
# for the script — don't rely on the heuristic for anything but .py/.r/.sh/.js/.rb/.pl.
# It is word-split on spaces (NO shell quoting), so keep it a simple "interpreter [flags]" —
# it can't carry quoted args like -c "code"; put that logic inside the script instead.
#
# Refuses to run if the script is not inside the sandbox dir.
set -uo pipefail

ENV="${BCC_CONDA_ENV:-base}"; TIMEOUT=600; SANDBOX=""; SCRIPT=""; INTERP=""; ARGS=()
ENV_EXPLICIT=0   # did the caller actually ASK for a specific env?
# Reject a missing value being swallowed from the next option (e.g. `--sandbox --script`).
need() { [[ -n "${2:-}" && "${2:0:1}" != "-" ]] || { echo "ERROR: $1 needs a value" >&2; exit 2; }; }
while [[ $# -gt 0 ]]; do
  case "$1" in
    --sandbox)     need "$1" "${2:-}"; SANDBOX="$2"; shift 2;;
    --script)      need "$1" "${2:-}"; SCRIPT="$2"; shift 2;;
    --interpreter) need "$1" "${2:-}"; INTERP="$2"; shift 2;;
    --env)         need "$1" "${2:-}"; ENV="$2"; ENV_EXPLICIT=1; shift 2;;
    --timeout)     need "$1" "${2:-}"; TIMEOUT="$2"; shift 2;;
    --)            shift; ARGS=("$@"); break;;
    *) echo "Unknown arg: $1" >&2; exit 2;;
  esac
done
[[ -n "$SANDBOX" && -d "$SANDBOX" ]] || { echo "ERROR: --sandbox dir required/invalid" >&2; exit 2; }
[[ -n "$SCRIPT" && -f "$SCRIPT" ]] || { echo "ERROR: --script required/invalid" >&2; exit 2; }
[[ "$TIMEOUT" =~ ^[0-9]+[smhd]?$ ]] || { echo "ERROR: invalid --timeout: $TIMEOUT" >&2; exit 2; }
# Advisory only — this script avoids bash 4-only syntax so it can run on macOS's stock 3.2.
[[ "${BASH_VERSINFO[0]:-0}" -ge 4 ]] \
  || echo "Note: bash ${BASH_VERSION:-unknown} (< 4) — supported here, but the review wrapper itself needs bash >= 4." >&2

# The timeout binary must actually SUPPORT --kill-after, and the launch path below must use the
# resolved name. Homebrew installs GNU coreutils g-prefixed unless gnubin is on PATH, so a Mac
# set up per the README can have gtimeout and no timeout at all.
if timeout --kill-after=1s 1s sh -c ':' >/dev/null 2>&1; then TIMEOUT_CMD=timeout
elif gtimeout --kill-after=1s 1s sh -c ':' >/dev/null 2>&1; then TIMEOUT_CMD=gtimeout
else echo "ERROR: need 'timeout' or 'gtimeout' supporting --kill-after (macOS: brew install coreutils)" >&2; exit 2; fi

# Portable canonicalization: `readlink -f` is GNU-only, and a path left relative would defeat the
# containment check below.
_rp() {
  local r
  r="$(readlink -f "$1" 2>/dev/null)" && [[ -n "$r" ]] && { printf '%s' "$r"; return 0; }
  python3 -c 'import os,sys;print(os.path.realpath(sys.argv[1]))' "$1" 2>/dev/null
}
SANDBOX_REAL="$(_rp "$SANDBOX")"
SCRIPT_REAL="$(_rp "$SCRIPT")"
[[ -n "$SANDBOX_REAL" && -n "$SCRIPT_REAL" ]] \
  || { echo "ERROR: cannot canonicalize paths (need readlink -f or python3)" >&2; exit 2; }
case "$SCRIPT_REAL" in
  "$SANDBOX_REAL"/*) : ;;
  *) echo "REFUSED: script ($SCRIPT_REAL) is not inside the sandbox ($SANDBOX_REAL)." >&2; exit 3;;
esac

# An explicit --interpreter wins (may carry args, e.g. "python -u"); otherwise pick by the
# BASENAME's extension (a dot in a parent dir must not be mistaken for an extension).
# Extensionless & unknown: run directly if executable, else bash. Prefer --interpreter for
# anything outside the known set below.
if [[ -n "$INTERP" ]]; then
  IFS=' ' read -ra CMD <<< "$INTERP"; CMD+=("$SCRIPT_REAL")
else
  bn="${SCRIPT_REAL##*/}"; ext=""; [[ "$bn" == *.* ]] && ext="${bn##*.}"
  # `tr`, not `${ext,,}`: the bash 4 lowercase expansion is a "bad substitution" on macOS's stock
  # bash 3.2, and it would blow up right here — *after* passing the friendly version check above,
  # which is the worst of both worlds. This way the check is advisory and the script still works.
  ext="$(printf '%s' "$ext" | tr '[:upper:]' '[:lower:]')"
  case "$ext" in
    # python3, NOT python: plenty of conda envs (and every modern distro) ship python3 with no
    # bare `python`, and the failure is a bare 127 long after the sandbox has been set up.
    py)          CMD=(python3 "$SCRIPT_REAL");;
    r)           CMD=(Rscript "$SCRIPT_REAL");;
    sh|bash)     CMD=(bash -- "$SCRIPT_REAL");;
    js|mjs|cjs)  CMD=(node "$SCRIPT_REAL");;
    rb)          CMD=(ruby "$SCRIPT_REAL");;
    pl)          CMD=(perl "$SCRIPT_REAL");;
    *)           if [[ -x "$SCRIPT_REAL" ]]; then CMD=("$SCRIPT_REAL"); else CMD=(bash -- "$SCRIPT_REAL"); fi;;
  esac
fi

echo "[run_local] env=$ENV cwd=$SANDBOX_REAL script=$SCRIPT_REAL timeout=${TIMEOUT}s"
echo "---------------- output ----------------"
# cwd = sandbox so relative paths stay local.
# timeout goes INSIDE conda run so it wraps the interpreter directly (conda run may not forward
# signals); --kill-after SIGKILLs a child that ignores SIGTERM.
#
# NO `--` separator before the command. `conda run` does NOT treat it as end-of-options — it
# passes it through as the first WORD of the command, so every Mode B run died with
#   /tmp/tmpXXXX: line 3: --: command not found
#   ERROR conda.cli.main_run:execute(127)
# Reproduced on conda 25.7.0. This one character made the entire mode dead on every host.
#
# `${ARGS[@]+"${ARGS[@]}"}` — expanding an EMPTY array as "${ARGS[@]}" under `set -u` is an
# unbound-variable error on bash < 4.4.
if command -v conda >/dev/null 2>&1; then
  ( cd "$SANDBOX_REAL" && conda run --no-capture-output -n "$ENV" \
      "$TIMEOUT_CMD" --kill-after=10s "$TIMEOUT" "${CMD[@]}" ${ARGS[@]+"${ARGS[@]}"} )
else
  # No conda on PATH. Honour an EXPLICIT --env or fail: silently running somewhere else when the
  # caller named an environment makes an experiment's result unreproducible and hides a missing
  # dependency. With no --env we fall back to the ambient environment loudly, because failing
  # closed here would make Mode B unusable on a perfectly good conda-less host.
  if [[ "$ENV_EXPLICIT" == 1 ]]; then
    echo "ERROR: --env '$ENV' was requested but 'conda' is not on PATH." >&2
    echo "       Install conda, or drop --env to run in the ambient environment." >&2
    exit 2
  fi
  echo "[run_local] WARNING: conda not found — running in the AMBIENT environment, not '$ENV'." >&2
  echo "[run_local]          Results may not be reproducible; install conda or pass --env to fail loudly." >&2
  ( cd "$SANDBOX_REAL" && "$TIMEOUT_CMD" --kill-after=10s "$TIMEOUT" "${CMD[@]}" ${ARGS[@]+"${ARGS[@]}"} )
fi
RC=$?
echo "----------------------------------------"
echo "[run_local] exit=$RC"
exit "$RC"
