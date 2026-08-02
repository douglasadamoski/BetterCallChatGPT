<div align="center">

<img src="assets/banner.svg" alt="It's Better Call ChatGPT! — terminal banner" width="760">

# ⚖ BetterCallChatGPT ⚖

**A [Claude Code](https://claude.com/claude-code) skill that gets OpenAI's Codex CLI
(`codex`, ChatGPT) to _criticize_ your codebase — then Claude triages the feedback and
implements it. `codex` only reviews and proposes: under its native read-only sandbox it can
inspect your repo but never edits your code or runs the fixes it proposes — Claude does that.**

[![License: GPL-3.0](https://img.shields.io/badge/License-GPLv3-blue.svg)](LICENSE)

**🔗 Sibling skills — same idea, different second opinion:
[⚖ BetterCallGemini ⚖](https://github.com/douglasadamoski/BetterCallGemini) (Google's Gemini, via `agy`)
· [⚖ BetterCallGrok ⚖](https://github.com/douglasadamoski/BetterCallGrok) (xAI's `grok`)**

</div>

---

## 🚀 Let's get the job done

Three steps and you're reviewing code with ChatGPT from inside Claude Code.

### 1️⃣ Put `codex` to work
Install **[Codex CLI](https://developers.openai.com/codex/cli/)** and make sure `codex` is on
your `PATH`. Log in once and confirm it answers:

```bash
codex login                 # complete the ChatGPT sign-in in your browser
                            #   (headless / over SSH? run instead:  codex login --device-auth )
codex login status          # should print "Logged in using ChatGPT"
codex exec -s read-only --skip-git-repo-check "reply with OK"   # a quick smoke test
```

### 2️⃣ Put this skill in your Claude
Easiest — install it as a **plugin** from its built-in marketplace, right inside Claude Code:

```
/plugin marketplace add douglasadamoski/BetterCallChatGPT
/plugin install better-call-chatgpt@bettercallchatgpt
```

Prefer a plain clone instead? The repo root *is* the skill, so:

```bash
git clone https://github.com/douglasadamoski/BetterCallChatGPT.git ~/.claude/skills/BetterCallChatGPT
```

(See [Install](#install) for all three methods.)

### 3️⃣ That's it — call it
In Claude Code, run the slash command:

```
/BetterCallChatGPT
```

…or just describe the task and let Claude auto-trigger it:

```
better call chatgpt on this folder
```

Either way, Claude composes the critique prompt, points Codex at your codebase, brings back a
prioritized review, and implements the findings worth keeping — while Codex's **native
read-only sandbox** makes sure it never changed a thing. ✅

---

## Why

Claude is great at writing and changing code, but a second, *independent* model is a powerful
critic. BetterCallChatGPT hands a whole codebase to ChatGPT via `codex`, asks for a broad,
intent-first critique (no test suite spoon-fed — Codex invents the tests it would write), and
brings back a prioritized findings report. **Claude** then decides what's valid and implements it.

Unlike its siblings **[BetterCallGemini](https://github.com/douglasadamoski/BetterCallGemini)** and
**[BetterCallGrok](https://github.com/douglasadamoski/BetterCallGrok)** — where the CLI couldn't be
trusted to stay out of your files, so an external *edit-guard* had to restore anything it touched —
**Codex has a native read-only sandbox**. So "ChatGPT doesn't touch your code" is guaranteed by
Codex itself, with **no edit-guard and no PTY hacks**:

- Every call runs `codex -a never -s read-only -c sandbox_mode="read-only" -c approval_policy="never" …`,
  which blocks the model's file writes, `apply_patch`, new files, and `git` mutations, and stops
  it pausing for approval (which would hang a non-interactive run). The typed `-s` flag is what
  makes this reliable: a misspelled `-c` key is *silently inert*, while `-s` overrides `-c` and
  fails loudly on a bad value.
- **Claude is the sole executor** — in experiment mode Codex *proposes* scripts as text; Claude
  reviews each one and runs only the approved ones.
- Codex is **never** run with `--dangerously-bypass-approvals-and-sandbox`.
- Every report records what the sandbox actually **resolved** to, read back from Codex's own
  session rollout — so a silently-dropped config key shows up instead of being assumed away.

> [!IMPORTANT]
> **Read-only blocks writes, not reads.** Codex can still `cat` anything inside the scope you
> point it at — including `.env` files, keys, or a symlink escaping to `~/.ssh` — and whatever it
> reads ends up in the report *and* in OpenAI's session store. Codex has no "deny read" switch, so
> BetterCallChatGPT refuses over-broad roots (`/`, `$HOME`, `/etc`, …) and **warns** about
> secret-shaped files and escaping symlinks (`BCC_STRICT_SCOPE=1` makes those a refusal), and the
> prompt templates tell the model to leave them alone. Keep `--scope` tight.

See [`references/codex_notes.md`](references/codex_notes.md) for the full, verified integration notes.

## Two modes

| Mode | What happens |
|------|--------------|
| **A — Critique** (default) | `codex` reads the scope and returns a written, prioritized critique. Claude triages each finding (accept/reject/investigate) and implements the good ones. No conda needed. |
| **B — Experiment** | `codex` *designs* experiments/tests and **proposes** scripts as text (it can't write them under read-only). Claude writes them into a sandbox dir, reviews each, runs the approved ones in a conda env, and feeds results back. |

## Requirements

- **[Claude Code](https://claude.com/claude-code)** — this is a skill it loads.
- **`codex`** (Codex CLI) — on your `PATH` and logged in (`codex login`, or `codex login
  --device-auth` on a headless box). Default model `gpt-5.5`.
- **bash 4+**, **python3** (a hard requirement — it parses Codex's `--json` stream, and the
  wrapper checks for it *before* spending anything), and a `timeout` supporting `--kill-after`
  (`gtimeout` is accepted, so `brew install coreutils` is enough on macOS). `flock` and
  `readlink -f` are used when present and degrade gracefully when not. Pillow only if you
  regenerate the banner. Run `--preflight` and it will tell you exactly what's missing.
- **conda** — only for Mode B (running proposed scripts). Configurable env via `--env` /
  `$BCC_CONDA_ENV` (default `base`). Mode A needs no conda.
- **chafa** — optional, only if you want to regenerate the banner with it (a dependency-free
  Python renderer is bundled).

## Install

Pick whichever you like — all three end up with the skill available as `/BetterCallChatGPT`.
No build step in any of them.

### Method 1 — Plugin marketplace (recommended)
This repo is also a Claude Code plugin marketplace, so you can install it without leaving Claude:

```
/plugin marketplace add douglasadamoski/BetterCallChatGPT
/plugin install better-call-chatgpt@bettercallchatgpt
```

Update later with `/plugin marketplace update bettercallchatgpt`.

### Method 2 — Clone into your skills folder
Claude Code auto-discovers skills under `~/.claude/skills/`. The repo root *is* the skill, so
clone it directly as the skill folder:

```bash
git clone https://github.com/douglasadamoski/BetterCallChatGPT.git ~/.claude/skills/BetterCallChatGPT
```

### Method 3 — Let Claude clone it for you
In any Claude Code session, just ask:

> clone `https://github.com/douglasadamoski/BetterCallChatGPT` into `~/.claude/skills/BetterCallChatGPT`

### Then use it
```
/BetterCallChatGPT
```
…or just say *"better call chatgpt on this folder"* / *"have codex criticize this code"*.

## Usage

Once installed, you drive it through Claude Code in natural language — Claude composes the
intent description, runs the wrapper, and triages the results for you. Under the hood it calls:

```bash
# Mode A — critique
scripts/codex_review.sh \
  --prompt-file <prompt.md> \
  --out PROJECT/BETTERCALLCHATGPT_REVIEW_<ts>.md \
  --scope <dir> \
  --model gpt-5.5 --effort high
```

The script's last stdout line is `RESULT=<OK|TRUNCATED|AUTH|CAP|QUOTA|TIMEOUT|ERROR>` so Claude can
branch (e.g. **stop and wait** on quota rather than hammering the API). Every exit path prints one
— including an interrupted run, which also saves the raw JSON you already paid for so the report
can be recovered without calling again.

Add `--preflight` to run every gate — dependencies, login, scopes, cap, writability — **without
making a billed call**. Its `RESULT` is what a real run *would* have returned (`AUTH` if you're
not logged in, `CAP` if the cap is spent), so it's the fastest way to debug an install.

### Quota

There is no programmatic quota readout for `codex`, so the skill tracks usage: a daily **call
cap** (`--cap`, default 99999 — effectively unlimited) and an append-only ledger at
`~/.bettercallchatgpt/usage.jsonl` that logs **real token counts** from Codex's `--json` stream.
The cap counts calls that were actually *billed* — recorded the moment Codex is launched, so an
interrupted or misclassified run can't quietly vanish from it. On a rate-limit / quota / credits
error it **stops and tells you to wait** for the reset. Higher `--effort` (`xhigh`) burns rate
limits faster.

> The ledger lives outside the skill folder on purpose. Before v1.1.0 a plugin install and a
> `~/.claude/skills` clone each kept their own, so `--cap N` silently behaved like `2N`. Old
> per-install ledgers are reconciled into the shared one **on every run** (deduped, so there's no
> write when there's nothing new) — a one-time merge would lose whatever an install you hadn't
> upgraded yet wrote afterwards. Leftovers are named on stderr; upgrade or delete them.

## Layout

```
SKILL.md                 # how Claude orchestrates the skill (the "brain")
scripts/
  codex_review.sh        # entrypoint: one codex exec turn (critique or experiment) + ledger
  _codex_common.sh       # shared lib: read-only runner, quota/token ledger, error classification
  codex_extract.py       # parse codex --json → critique text + token usage + session id
  run_local.sh           # Claude runs an approved script, confined to the sandbox dir
  show_header.sh          # the colored banner header
  img2ansi.py             # regenerate the banner art from the poster PNG (no chafa needed)
  blacken_to_transparent.py  # drop a chafa capture's black bg to the terminal background
  make_banner_svg.py      # render the ANSI art into the README's terminal-window SVG (needs rich)
templates/
  critique_prompt.md     # Mode A prompt template
  experiment_prompt.md   # Mode B prompt template
references/
  codex_notes.md         # verified codex knowledge: flags, sandbox, error strings, JSON shapes
assets/                  # banner art + source poster
```

Runtime state (ledger, per-scope session ids, temp prompts) lives in
`$BCC_STATE_DIR`, default `~/.bettercallchatgpt/` — outside the repo, so one install can't hide
another's usage from the cap.

## Configuration

| Knob | Where | Default |
|------|-------|---------|
| Model | `--model` | `gpt-5.5` |
| Reasoning effort | `--effort` (`low`/`medium`/`high`/`xhigh`) | `high` |
| Daily call cap | `--cap` | `99999` (effectively unlimited) |
| Sandbox conda env | `--env` / `$BCC_CONDA_ENV` | `base` |
| Wrapper timeout | `$BCC_TIMEOUT` | `20m` |
| State / ledger location | `$BCC_STATE_DIR` | `~/.bettercallchatgpt` |
| Skip session persistence | `$BCC_EPHEMERAL=1` | off (sessions kept for `--continue`) |
| Scope scan → refusal | `$BCC_STRICT_SCOPE=1` | off (warns only) |
| Skip the scope scan | `$BCC_SKIP_SCAN=1` | off |
| Skip the pre-run auth check | `$BCC_SKIP_LOGIN_CHECK=1` | off |

## Safety notes

- **Read-only means write-blocked, not read-restricted.** Codex can read anything your `--scope`
  reaches, and it all lands in the report and in OpenAI's session store. Keep the scope tight; the
  wrapper's root refusal and scope scan are defence in depth, not a boundary.
- `run_local.sh` is **not** a security jail — it only verifies the script lives under the
  sandbox dir and runs it with your normal privileges. **The Claude review gate is the real
  boundary**: never run an unreviewed Codex-proposed script.
- Write-blocking is enforced by Codex's own sandbox; the wrapper always passes `-a never
  -s read-only -c sandbox_mode="read-only" -c approval_policy="never"`. A *nested* codex run
  inside the sandbox fails by design (`os error 30`) — the skill never nests. See
  [`references/codex_notes.md`](references/codex_notes.md).
- A repository under review is untrusted input, and both prompt templates say so — any instruction
  found inside it is data to be reviewed, never a command to obey. A planted `.mcp.json` /
  `.codex/config.toml` was probed against codex-cli 0.146.0 and is **not** registered, so no
  scanner was added; the probe and its scope are recorded in the notes.

## License

[GPL-3.0](LICENSE) © 2026 Douglas Adamoski.
