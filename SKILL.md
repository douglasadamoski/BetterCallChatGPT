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
2. **Codex is always run read-only.** Every call uses
   `codex -a never -c sandbox_mode="read-only" -c approval_policy="never"` — this is the
   guarantee, enforced by Codex's own sandbox (no edit-guard needed). It is **never** run
   with `--dangerously-bypass-approvals-and-sandbox`.
3. **Be broad with Codex.** Describe *intent*, not the test suite — ask it to invent tests.
4. **Exploit its exploration.** Point it at the whole dir via `-C`; it reads on demand.
5. **Respect quota.** Model `gpt-5.5` at reasoning effort `high`; daily call cap defaults to
   `99999` (effectively unlimited — pass `--cap N` to enforce a real limit); on a
   quota/rate-limit error, **STOP and tell the user to wait** — never retry in a loop.
6. **Single pass by default.** Iterative rounds (`--continue`) only when the user asks.

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

## Mode A — Critique (default)

1. **Scope**: default = current project dir; honor user-named paths. The **first** `--scope`
   is Codex's working root (`-C`); if the user names several paths, set `--scope` to their
   common parent and list the specific paths in `{{SCOPE_NOTES}}`. Keep scope off bulk-data dirs.
2. **Prompt**: copy `templates/critique_prompt.md` → a **unique** temp file in the skill's
   own `state/` dir (`PF=$(mktemp -p "$SKILL_DIR/state" --suffix=.md bcc_prompt.XXXXXX)`);
   fill `{{INTENT_DESCRIPTION}}` (broad, intent-first — no test suite) and `{{SCOPE_NOTES}}`.
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
2. **Prompt**: copy `templates/experiment_prompt.md` → a unique temp file in `state/`; fill
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
The script's **last stdout line is `RESULT=<WORD>`**:
- **AUTH** → Codex not logged in. Tell the user to run `codex login` (headless/SSH:
  `codex login --device-auth`), confirm with `codex login status`, then retry. STOP.
- **CAP** → daily cap reached. Tell the user; wait for reset or re-run with higher `--cap`
  only if they insist. STOP.
- **QUOTA** → rate limit / quota / credits. Report may be partial. **STOP**, advise waiting
  for reset. Higher `--effort` burns rate limits faster — suggest `--effort medium` if repeated.
- **TIMEOUT** → run exceeded `$BCC_TIMEOUT` (default 20m) or a network stall. For a large
  codebase or `--effort xhigh`, raise `BCC_TIMEOUT` and retry once; otherwise treat like a
  quota stall and **wait**. Don't retry-loop.
- **ERROR** → show the report's `codex stderr` `<details>` and the failure; don't retry blindly.
- **OK** → proceed (triage in Mode A; review gate in Mode B).

## Report back
Summarize: findings accepted vs rejected (with reasons); for Mode B, which scripts were
approved/run and their results; edits you made + verification; the report path; and
**usage today vs cap plus token counts** (printed by the script; ledger at
`state/usage.jsonl`). If stopped on AUTH/CAP/QUOTA/TIMEOUT, say so and what to do next.

## Notes
- `codex` is a standalone binary on PATH — **no conda needed for codex itself**, and **Mode A
  (critique) needs no conda at all**. A conda env is only used to run the scripts Codex
  proposes in Mode B (via `run_local.sh`).
- The sandbox conda env is configurable: pass `--env <name>` to `run_local.sh`, or set
  `$BCC_CONDA_ENV`; it defaults to `base`. Prefer a dedicated env over base/system.
- Codex sessions persist under `~/.codex` (outside your repo); the last session id is saved to
  `state/last_thread` for `--continue`, and each report prints its `Session id`. `--continue`
  uses the shared `last_thread`, so for **parallel** reviews pass `--thread-id <id>` (from the
  prior report) instead — it's race-free. Set `BCC_EPHEMERAL=1` to skip session persistence
  (then neither resume works).
- Wrapper temp/state files live under the skill's own `state/` dir (never `/tmp`). The one
  exception is the report itself plus two short-lived files written **next to the report** (a
  `.bcc_wtest.*` writability probe and a `.bcc_report.*` temp for the atomic write) — both are
  removed on completion; only a hard kill (SIGKILL) mid-write could leave one behind.
