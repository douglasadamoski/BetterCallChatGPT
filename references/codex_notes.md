# codex (Codex CLI) — notes for BetterCallChatGPT

Distilled from a live self-interview of `codex` (codex-cli 0.142.5) plus verification
probes. Self-contained so the skill works without the raw interview file.

## Invocation (non-interactive, what we use)
- `codex exec [PROMPT]` (alias `codex e`) — run one prompt, print result, exit. Prompt
  may be an arg, or `-` / omitted to read from **stdin** (we use stdin via `-` to avoid
  ARG_MAX and the "Reading additional input from stdin" wait).
- `-C, --cd <DIR>` — working root (the codebase to review).
- `-m, --model <MODEL>` — pick the model. Default resolves to **`gpt-5.5`**.
- `--json` — emit JSONL events to stdout (we parse these; see below).
- `-o, --output-last-message <FILE>` — write only the final message to a file (a
  filesystem write; we don't use it for zero-write runs — we parse `--json` instead).
- `--output-schema <FILE>` — force the final message to match a JSON Schema (structured findings).
- `--skip-git-repo-check` — allow running outside a git repo (needed for non-git dirs).
- `--ephemeral` — don't persist the session to disk (then nothing is resumable).
- `--ignore-user-config` / `--ignore-rules` — skip `$CODEX_HOME/config.toml` and
  user/project `.rules`; we set both for a reproducible, sterile critique.
- `--color never` — plain output for wrappers.
- `codex exec resume [SESSION_ID] [PROMPT]` / `resume --last` — iterative rounds.

## Read-only enforcement (the whole point — verified)
Codex has a **native read-only sandbox**, so BetterCallChatGPT needs **no edit-guard**
(unlike BetterCallGemini). We always run:
```
codex -a never -c sandbox_mode="read-only" -c approval_policy="never" -c network_access=false exec ...
```
- `-a never` (approval policy `never`) is **TOP-LEVEL** — `codex -a never exec ...`, NOT
  `codex exec -a never`. Default approval is `OnRequest`, which would pause/hang a
  non-interactive run.
- `-s read-only` / `sandbox_mode="read-only"` blocks the **model's** tool actions:
  file writes, `apply_patch`, new files, and `git` mutations. This is the guarantee.
- `network_access=false` blocks the **model's** shell network (curl, etc.). It does NOT
  block Codex's own connection to OpenAI/ChatGPT — that provider network is separate.
- `codex doctor` reports `restricted fs + restricted network` via a `codex-linux-sandbox`
  helper (Linux). Treat as kernel-backed enough for this design; not a formal claim.

### Gotcha: `os error 30` on NESTED codex
`-s read-only` makes the filesystem read-only for **tool-executed** commands, so a
`codex exec` spawned *as a model tool inside the sandbox* fails to init its own
`$CODEX_HOME` with:
`Error: failed to initialize in-process app-server client: Read-only file system (os error 30)`.
The **top-level** codex process is unaffected (it writes `~/.codex` normally) — so our
wrapper run is fine. We never nest codex, so this never bites us. **Verified:** the outer
read-only command runs with exit 0 and needs no `CODEX_HOME` override.

## `--json` event shapes we parse (verified)
- `{"type":"thread.started","thread_id":"…"}` — the session id (our `--continue` handle).
- `{"type":"item.completed","item":{"type":"agent_message","text":"…"}}` — the critique text.
- `{"type":"turn.completed","usage":{"input_tokens":N,"cached_input_tokens":N,
  "output_tokens":N,"reasoning_output_tokens":N}}` — **real token usage** (logged to the
  ledger; better than BetterCallGemini's byte estimate).
`scripts/codex_extract.py` turns this stream into the report body + a metadata blob.

## Models & reasoning effort
- List: `codex debug models` (or offline `codex debug models --bundled`).
- Default / deepest review model: **`gpt-5.5`**. Context window ~272k.
- Reasoning effort: `-c model_reasoning_effort="high"` (values: `low|medium|high|xhigh`;
  default `medium`). Higher = deeper but **burns plan rate limits faster** — drop to
  `medium` if you hit quota.

## Native `codex review` (why we don't use it here)
`codex review` / `codex exec review` (`--base` / `--uncommitted` / `--commit`) is
**diff-oriented** — a review of git changes, not a broad whole-codebase critique. For
BetterCallChatGPT's intent-first, no-diff critique we use plain `codex exec "<prompt>"`.

## Auth
- Default: ChatGPT login (`codex login`; headless/SSH: `codex login --device-auth`).
  API key: `printenv OPENAI_API_KEY | codex login --with-api-key`. Access token:
  `... | codex login --with-access-token`.
- Creds: `$CODEX_HOME` = `~/.codex`, auth file `~/.codex/auth.json`.
- Check: `codex login status` → `Logged in using ChatGPT` when OK.
- Detect failure: nonzero status or output matching `not logged in|unauthenticated|
  unauthorized|token expired|client authentication not set up|authentication failed`.

## Quota / rate limits / usage
- **No stable quota readout** from the CLI (`account/rateLimits/read` exists internally
  but isn't a documented CLI command). `codex doctor` does NOT show remaining quota.
- Detect exhaustion by matching: `429`, `TooManyRequests`, `ResourceExhausted`,
  `rate limit`, `quota`, `usage limit`, `credits depleted`,
  `WorkspaceMemberUsageLimitReached`, `workspace_owner_credits_depleted`, `noCredit`.
- Policy: **never retry-loop** on quota — stop and wait for reset. Retry only obvious
  transient transport errors (connection reset/timeout/503), bounded.

## Exit codes (verified where possible)
- `0` success · `2` CLI usage error · `1` various (doctor/reachability, app-server init).
- Auth/quota exact exit codes could not be safely forced; the wrapper classifies on
  nonzero-exit **plus** matched signature strings, else generic ERROR.

## PTY / headless
- `codex exec` is built for non-interactive subprocess use — **no PTY needed** (unlike
  `agy`). Main hang risks: forgetting `-a never` (approval prompt), auth/login flows,
  network stalls, or a non-writable `$CODEX_HOME`.

## Sessions
- Stored under `$CODEX_HOME` (`~/.codex/sessions/YYYY/MM/DD/rollout-*.jsonl`). The rollout
  records the resolved `model`. `--ephemeral` skips persistence (then nothing to resume).
- We persist by default and save the last `thread_id` to `state/last_thread` for `--continue`.

## Config knobs (best set for a deterministic read-only critique)
```
-c sandbox_mode="read-only"
-c approval_policy="never"
-c network_access=false
-c model_reasoning_effort="high"   # or "xhigh" for expensive deep review
```
Plus flags: `--ignore-user-config --ignore-rules --skip-git-repo-check --color never --json`.
Codex reads `AGENTS.md` / project docs by default; `--ignore-rules` skips `.rules` but keeps
`AGENTS.md`. For a fully sterile review, tell the user which project docs remain in play.

## Experiment mode (Mode B) — the key difference from BetterCallGemini
Read-only forbids the model writing scripts anywhere, so agy's "write into a sandbox"
pattern does NOT map. Instead Codex **proposes** script contents as fenced code blocks in
its report; Claude writes them into a sandbox dir, reviews each, and runs the approved ones
with `scripts/run_local.sh`, then feeds results back via `--continue`. Codex never executes
the scripts it proposes (Claude does) — though it may still run read-only inspection commands
to review the code.
