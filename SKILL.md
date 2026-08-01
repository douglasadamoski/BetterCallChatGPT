---
name: BetterCallChatGPT
description: >-
  Delegate an independent, critical code review to OpenAI's Codex CLI (`codex`,
  ChatGPT) and then implement the feedback yourself. Codex ONLY criticizes and
  PROPOSES; under its native read-only sandbox it may inspect the repo but cannot edit
  your codebase or run the fixes/experiments it proposes — Claude reviews and executes those.
  Use when the user says "better call chatgpt", "have codex/chatgpt review/criticize
  this", "get a second opinion from codex", or wants an outside critique of a
  file/folder/codebase. Requests to Codex are deliberately broad (intent-first, no test
  suite handed over) so it invents its own tests. Codex runs in its native READ-ONLY
  sandbox, so no edit-guard is needed. Tracks usage quota and stops + waits for reset
  when exhausted.
---

# BetterCallChatGPT

Get ChatGPT (via OpenAI's `codex`) to **criticize** your codebase and **design
experiments**, then **you** (Claude) triage and implement. Codex gives feedback and
proposes scripts; **Claude is the only one who edits the codebase or runs the proposed
scripts.** (Codex runs under a read-only sandbox: it may inspect the repo with read-only
commands to review it, but it cannot change anything.)

`SKILL_DIR` = the folder containing this file. Read `references/codex_notes.md` for
codex flags/paths/error-strings and the read-only design.

## Step 0 — Show the banner (do this FIRST, every invocation)
Emit the banner with **ONE `printf`** (NOT `cat` — `cat <file>` renders as a "Read 1 file"
block with no preview). `assets/banner.txt` has the **colored header on top** then the full
image, so Claude Code's collapsed preview shows the header while **Ctrl+O reveals the full
art**. Run silently — **no narration** (don't announce/explain it), just the one command:
```bash
[[ -f "$SKILL_DIR/assets/banner.txt" ]] && printf '%s\n' "$(< "$SKILL_DIR/assets/banner.txt")"
```
If the file is missing, skip silently. Regenerate `banner.txt` (= header + transparent image):
```bash
{ bash "$SKILL_DIR/scripts/show_header.sh"; cat "$SKILL_DIR/assets/better_call_chatgpt.txt"; } > "$SKILL_DIR/assets/banner.txt"
```
The image comes from the source poster `assets/BetterCallChatGPT_black.png` (black
background). Either (a) with chafa: `chafa --symbols=half --colors=full --size=88x35 -t 0.5
<png>` then make black terminal-transparent, or (b) dependency-free with the bundled tools:
`python3 scripts/img2ansi.py assets/BetterCallChatGPT_black.png --cols 88 --knockout black >
assets/better_call_chatgpt.txt` (already black-transparent). If you start from a raw chafa
capture, run it through `python3 scripts/blacken_to_transparent.py <raw> -o
assets/better_call_chatgpt.txt` to drop the black to the terminal background. Header
text/colors live in `scripts/show_header.sh` (yellow rule + `⚖ It's Better Call ChatGPT! ⚖`
in yellow/green + dim subtitle with the Ctrl+O hint).

## Core principles (from the user)
1. **Codex never changes your codebase.** It reads/inspects + criticizes + proposes. Under the
   read-only sandbox it may run read-only inspection commands (grep/ls/cat) to explore — that's
   how it reviews — but it cannot modify any file and does not execute the scripts it proposes
   (Claude does). Note: Codex keeps its own session/auth state under `~/.codex`, outside your
   repo — that's expected and is not a change to your code.
2. **Codex is always run write-blocked.** Every call uses
   `codex -a never -s read-only -c sandbox_mode="read-only" -c approval_policy="never"`. The
   typed `-s` flag is the guarantee (it overrides `-c` and fails loudly on a bad value, where a
   misspelled `-c` key is *silently inert*); the `-c` override is defence in depth. It is
   **never** run with `--dangerously-bypass-approvals-and-sandbox`.
3. **Read-only means WRITE-blocked, not READ-restricted.** ⚠️ This is the one thing to be clear
   about with the user. Codex can still `cat` anything the scope reaches — `.env`, `~/.ssh/`,
   `../../secrets` via a symlink — and everything it reads lands in the report file *and* in
   OpenAI's session store. There is no `--deny Read` in codex. The wrapper refuses over-broad
   roots and warns about secret-shaped files and escaping symlinks, and the prompt templates tell
   the model to stay away from them, but **none of that is an enforcement boundary**. Keep
   `--scope` tight, and say so if the user points it somewhere sensitive.
4. **Be broad with Codex.** Describe *intent*, not the test suite — ask it to invent tests.
5. **Exploit its exploration.** Point it at the whole dir via `-C`; it reads on demand.
6. **Respect quota.** Model `gpt-5.5` at reasoning effort `high`; daily call cap defaults to
   `99999` (effectively unlimited — pass `--cap N` to enforce a real limit); on a
   quota/rate-limit error, **STOP and tell the user to wait** — never retry in a loop.
7. **Single pass by default.** Iterative rounds (`--continue`) only when the user asks.

## Why read-only is native (and simpler than BetterCallGemini)
`agy` could not be sandboxed headlessly, so BetterCallGemini needed an external edit-guard.
**Codex can:** `-s read-only` blocks the model's file writes / `apply_patch` / new files /
`git` mutations, and `-a never` stops it pausing for approval. The guarantee is specifically
**no mutation of your codebase** — Codex is still free to run read-only inspection commands
(grep/ls/cat) to explore and review, which is exactly what we want; it simply cannot change
anything. So "Codex doesn't change your code" is guaranteed by **Codex's own sandbox** — this
skill has **no edit-guard and no PTY wrapper**. (One caveat: a *nested* codex-in-sandbox fails
with `os error 30`; we never nest, and the top-level run is unaffected. See
`references/codex_notes.md`.) The cap check is best-effort under parallel runs (check-then-call
is not atomic) — fine for the default unlimited cap; for a strict `--cap` run sequentially.

Each report header records what the sandbox actually **resolved** to, read from codex's own
rollout (`turn_context.sandbox_policy`). That detects a silently-dropped config key; it is *not*
evidence that the kernel enforced anything, and it reads `unknown` under `BCC_EPHEMERAL=1`.

## Preflight (free — use it when an install misbehaves)
`--preflight` runs every gate — deps, login, state dir, timeout binary, scopes, scope scan, cap,
report writability — and prints `RESULT=OK` **without making a billed call**:
```bash
bash "$SKILL_DIR/scripts/codex_review.sh" --preflight \
  --prompt-file "$PF" --out "<project>/preflight.md" --scope "<dir>"
```
Run this first whenever a review fails in a confusing way; it costs nothing. Its `RESULT=` is
what a *real* run would have done — `AUTH` if Codex isn't logged in, `CAP` if the cap is spent,
`ERROR` if a gate fails, `OK` only if a real run would reach the launch.

## Mode A — Critique (default)

1. **Scope**: default = current project dir; honor user-named paths. The **first** `--scope`
   is Codex's working root (`-C`); if the user names several paths, set `--scope` to their
   common parent and list the specific paths in `{{SCOPE_NOTES}}`. Keep scope off bulk-data dirs.
2. **Prompt**: copy `templates/critique_prompt.md` → a **unique** temp file in the state dir
   (`mktemp -p` and `--suffix` are GNU-only, so use the portable form):
   ```bash
   BCC_STATE="${BCC_STATE_DIR:-$HOME/.bettercallchatgpt}"; mkdir -p "$BCC_STATE"
   PF="$(mktemp "$BCC_STATE/bcc_prompt.XXXXXX.md")"
   ```
   Fill `{{INTENT_DESCRIPTION}}` (broad, intent-first — no test suite) and `{{SCOPE_NOTES}}`.
   Remove it when done.
3. **Run**:
   ```bash
   bash "$SKILL_DIR/scripts/codex_review.sh" \
     --prompt-file "$PF" \
     --out "<project>/BETTERCALLCHATGPT_REVIEW_<UTC-ts>.md" \
     --scope "<dir>" --model gpt-5.5 --effort high
   ```
4. **Branch on the last line `RESULT=<WORD>`** (see below).
5. **Triage** each finding independently (accept/reject/investigate, with reasons — don't
   obey Codex blindly), then **implement** the accepted ones yourself and verify.

## Mode B — Experiment (Codex designs experiments; Claude runs them)

Use when Codex should design tests/experiments/prototypes. Because Codex is read-only, it
**proposes scripts as text** (fenced code blocks) rather than writing them — Claude writes,
reviews, and runs them.

1. **Sandbox dir**: `<project>/BetterCallChatGPT/sandbox/<run-or-task>/` (Claude creates it).
2. **Prompt**: copy `templates/experiment_prompt.md` → a unique temp file in the state dir (same
   portable `mktemp` recipe as Mode A step 2); fill
   `{{INTENT_DESCRIPTION}}` and `{{TASK_DESCRIPTION}}`. Run `codex_review.sh` with
   `--mode experiment` (add `--continue` on follow-up turns to keep Codex's context):
   ```bash
   bash "$SKILL_DIR/scripts/codex_review.sh" \
     --prompt-file "$PF" \
     --out "<project>/BETTERCALLCHATGPT_EXPERIMENT_<UTC-ts>.md" \
     --scope "<dir>" --mode experiment --model gpt-5.5 --effort high
   ```
3. On `RESULT=OK`: Codex's report contains proposed scripts as fenced code blocks (with
   filenames, run commands, expected output). **Write each into the sandbox dir yourself.**
4. **REVIEW GATE (required before running anything):** inspect every script — directly or via
   a general subagent (Agent/Task tool). Confirm each: stays inside the sandbox, doesn't touch
   the real codebase/system, has no destructive/exfiltration/network-abuse ops, and matches
   its stated purpose. Reject or edit anything unsafe. Only approved scripts run.
   > [!WARNING]
   > `run_local.sh` is NOT a security jail — it only path-checks the script location and runs
   > it with your normal privileges (no chroot/namespace/network isolation). **This review gate
   > is the only real security boundary** — review thoroughly; never run an unreviewed script.
5. **Tool installs**: if a script needs a package Codex flagged as missing, vet it, then
   install into the sandbox conda env (`--env <name>` / `$BCC_CONDA_ENV`, default `base`):
   `conda install -n <env> ...` or `conda run -n <env> pip install ...`. Codex installs nothing.
6. **Run approved scripts** (Claude executes, confined to the sandbox, in the chosen env).
   Pass the run command Codex specified for the script via `--interpreter` (the extension
   heuristic only covers `.py/.r/.sh/.js/.rb/.pl` — always use `--interpreter` for anything
   else, e.g. `ts-node`, `go run`, `python -u`):
   ```bash
   bash "$SKILL_DIR/scripts/run_local.sh" \
     --sandbox "<sandbox>" --script "<sandbox>/<task>/<file>" \
     [--interpreter "<cmd Codex gave>"] [--env <conda-env>] [--timeout 600]
   ```
7. **Feed results back** to Codex for the next turn (re-run Mode B with `--continue`, pasting
   the captured output into the prompt), or proceed to implement fixes yourself.

## Result handling (both modes)
The script's **last stdout line is `RESULT=<WORD>`**. Branch on that line, not on prose in the
report — every failure path, including a signal, prints one.
- **OK** → proceed (triage in Mode A; review gate in Mode B).
- **TRUNCATED** → the run stopped early (context/turn exhaustion), so the review is **partial**.
  Findings are incomplete — *not* a clean bill of health. Say so, then narrow `--scope` and re-run,
  or continue with `--thread-id <id from the report>`.
- **AUTH** → Codex not logged in. Tell the user to run `codex login` (headless/SSH:
  `codex login --device-auth`), confirm with `codex login status`, then retry. STOP. (This is now
  usually caught by a free pre-run check, so nothing was billed.)
- **CAP** → daily cap reached. Tell the user; wait for reset or re-run with higher `--cap`
  only if they insist. STOP.
- **QUOTA** → rate limit / quota / credits. **Output may be partial even if the run finished** —
  quota evidence in Codex's own error events is reported whatever the exit status. **STOP**,
  advise waiting for reset. Higher `--effort` burns rate limits faster — suggest `--effort medium`
  if repeated.
- **TIMEOUT** → run exceeded `$BCC_TIMEOUT` (default 20m) or a network stall. For a large codebase
  or `--effort xhigh`, raise `BCC_TIMEOUT` and retry once; otherwise treat like a quota stall and
  **wait**. Don't retry-loop.
- **ERROR** → show the report's `codex stderr` `<details>` and the failure; don't retry blindly.
  **This also covers an interrupted run** (Ctrl-C, or SIGTERM to either the wrapper or Codex) —
  deliberately, so the wrapper's own signal trap and Codex's exit status agree on one word rather
  than telling the caller to "raise the timeout and retry" after a deliberate interrupt. If the
  interrupt landed after Codex had already been paid for, the wrapper says so and saves the raw
  JSON to `$BCC_STATE_DIR/orphan-<ts>.jsonl` — recover the body with
  `python3 "$SKILL_DIR/scripts/codex_extract.py" <that file>` rather than paying again.

The report header also carries `Billed:` (whether the call reached the model), `Sandbox:` (what
the config resolved to) and `Scope scan:` — mention them if they are anything but the happy path.

## Report back
Summarize: findings accepted vs rejected (with reasons); for Mode B, which scripts were
approved/run and their results; edits you made + verification; the report path; and
**usage today vs cap plus token counts** (printed by the script; ledger at
`${BCC_STATE_DIR:-$HOME/.bettercallchatgpt}/usage.jsonl`). If stopped on
AUTH/CAP/QUOTA/TIMEOUT/TRUNCATED, say so and what to do next.

## Notes
- `codex` is a standalone binary on PATH — **no conda needed for codex itself**, and **Mode A
  (critique) needs no conda at all**. A conda env is only used to run the scripts Codex
  proposes in Mode B (via `run_local.sh`).
- The sandbox conda env is configurable: pass `--env <name>` to `run_local.sh`, or set
  `$BCC_CONDA_ENV`; it defaults to `base`. Prefer a dedicated env over base/system.
- **One ledger, one cap.** State lives at `${BCC_STATE_DIR:-$HOME/.bettercallchatgpt}`, *not*
  inside the skill folder — a plugin install and a `~/.claude/skills` clone used to keep separate
  ledgers, so `--cap N` silently became `2N`. On first run the ledger is migrated from whichever
  old per-install location has the most history, and any others are named on stderr so they can
  be reconciled and deleted.
- Codex sessions persist under `~/.codex` (outside your repo); the thread id is saved **per
  scope** under `$BCC_STATE_DIR/sessions/`, and each report prints its `Session id`.
  `--continue` resumes *this scope's* last session; for **parallel** reviews pass
  `--thread-id <id>` (from the prior report) — it's race-free. Either way the wrapper checks the
  session's own recorded working directory and **refuses a cross-project resume**, because
  `codex exec resume` cannot be re-pointed at a different tree. It also refuses when the session's
  rollout is missing and the directory therefore *cannot* be checked — an unverifiable session is
  exactly the one that might belong elsewhere (`BCC_ALLOW_UNVERIFIED_RESUME=1` to override). Set
  `BCC_EPHEMERAL=1` to skip session persistence (then neither resume works, and sandbox
  verification reads `unknown`).
- Wrapper temp/state files live under `$BCC_STATE_DIR` (never `/tmp`). The one exception is the
  report itself plus two short-lived files written **next to the report** (a `.bcc_wtest.*`
  writability probe and a `.bcc_report.*` temp for the atomic write) — both are removed on
  completion; only a hard kill (SIGKILL) mid-write could leave one behind.
- **Environment knobs:** `BCC_STATE_DIR` (state/ledger location), `BCC_TIMEOUT` (default `20m`),
  `BCC_EPHEMERAL=1`, `BCC_CONDA_ENV`, `BCC_STRICT_SCOPE=1` (turn scope-scan warnings into a
  refusal), `BCC_SKIP_SCAN=1` (skip the scan entirely), `BCC_SKIP_LOGIN_CHECK=1` (skip the free
  pre-run auth gate, e.g. in a pure API-key setup), `BCC_ALLOW_UNVERIFIED_RESUME=1`.
- **Mode B and conda:** `run_local.sh` runs the approved script in the conda env you name. If
  `conda` isn't installed it falls back to the ambient environment with a loud warning — *unless*
  you passed `--env` explicitly, in which case it fails rather than silently running somewhere
  other than the environment you asked for.

## Sibling skills
Same idea, different second opinion — mention them if the user wants another model's view:
- **[⚖ BetterCallGemini ⚖](https://github.com/douglasadamoski/BetterCallGemini)** — Google's
  Gemini via Antigravity's `agy`, with an external edit-guard (agy can't be sandboxed headlessly).
- **[⚖ BetterCallGrok ⚖](https://github.com/douglasadamoski/BetterCallGrok)** — xAI's `grok`,
  with a three-layer defence (tool allowlist + edit-guard + kernel sandbox).
