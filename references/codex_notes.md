# codex (Codex CLI) — notes for BetterCallChatGPT

Distilled from a live self-interview of `codex` plus verification probes. Self-contained so the
skill works without the raw interview file.

**Pinned to codex-cli 0.146.0.** Everything marked *verified* below was re-checked against
0.146.0 on Linux (kernel 5.10) on 2026-08-01. The previous pin was 0.142.5; the flag set,
`exec resume` restrictions and rollout shapes were all re-confirmed at the new version.

## Capability matrix — what was actually confirmed, and where

| Claim | codex | Platform | Status |
|---|---|---|---|
| `-s read-only` accepted top-level, applies to `exec` and `exec resume` | 0.146.0 | Linux 5.10 | verified |
| `-s` overrides `-c sandbox_mode` | 0.146.0 | Linux 5.10 | verified |
| A misspelled `-c` key is silently inert | 0.146.0 | Linux 5.10 | verified |
| `exec resume` rejects `-C/--cd` and `--color` | 0.146.0 | Linux 5.10 | verified (not in `--help`) |
| Rollout records `session_meta.cwd` | 0.146.0 | Linux 5.10 | verified |
| Rollout records `turn_context.sandbox_policy` / `approval_policy` | 0.146.0 | Linux 5.10 | verified |
| A repo-planted `.mcp.json` / `.codex/config.toml` is NOT registered | 0.146.0 | Linux 5.10 | verified |
| Kernel-level enforcement of the sandbox (Landlock/seccomp) | — | — | **NOT established** |
| The exact `--json` signature of a context-limit stop | — | — | **NOT pinned** |

The bottom three rows are deliberate: we record what we checked, not what we hope.

## Invocation (non-interactive, what we use)
- `codex exec [PROMPT]` (alias `codex e`) — run one prompt, print result, exit. Prompt may be an
  arg, or `-` / omitted to read from **stdin** (we use stdin via `-` to avoid ARG_MAX and the
  "Reading additional input from stdin" wait).
- `-C, --cd <DIR>` — working root. **`exec` only** — `exec resume` does not accept it.
- `-m, --model <MODEL>` — pick the model. Default resolves to **`gpt-5.5`**.
- `--json` — emit JSONL events to stdout (we parse these; see below).
- `-o, --output-last-message <FILE>` — write only the final message to a file (a filesystem
  write; we parse `--json` instead so a run leaves no file behind).
- `--output-schema <FILE>` — force the final message to match a JSON Schema.
- `--skip-git-repo-check` — allow running outside a git repo.
- `--ephemeral` — don't persist the session (then nothing is resumable, **and no rollout is
  written**, so the sandbox verification below degrades to `unknown`).
- `--ignore-user-config` / `--ignore-rules` — skip `$CODEX_HOME/config.toml` and user/project
  `.rules`. Both are `exec`-level, **not** top-level: `codex --ignore-user-config mcp list` errors
  with *unexpected argument*. We set both on the codex call for a reproducible, sterile critique.
- `--color never` — plain output. **`exec` only**, like `-C`.
- `codex exec resume [SESSION_ID] [PROMPT]` / `resume --last` — iterative rounds.

## Write-blocking (what the sandbox actually buys — verified)
We always run:
```
codex -a never -s read-only -c sandbox_mode="read-only" -c approval_policy="never" \
      -c network_access=false exec ...
```
- `-a never` and `-s read-only` are **TOP-LEVEL** — `codex -a never -s read-only exec …`, NOT
  `codex exec -a never`. Default approval is `OnRequest`, which would hang a non-interactive run.
  Being top-level is also why they still apply on the `exec resume` path.
- **Why both `-s` and `-c sandbox_mode`.** MEASURED on 0.146.0 with `codex debug prompt-input`,
  which renders the resolved permissions block offline and free:

  | invocation | resolved `sandbox_mode` |
  |---|---|
  | `-c sandbox_mode="workspace-write"` | `workspace-write` |
  | `-c sandbox_moad="workspace-write"` (typo) | `read-only` — **silently inert** |
  | `-s read-only -c sandbox_mode="workspace-write"` | `read-only` — **`-s` wins** |
  | `-s read_only` (bad value) | `error: invalid value … [possible values: read-only, …]` |

  So a renamed or misspelled `-c` key would leave the run on codex's default sandbox with no
  complaint, whereas the typed flag fails loudly. `-s` is the guarantee; `-c` is defence in depth.
- `network_access=false` is **belt-and-braces and its key placement is unverified.** Under
  `-s read-only` codex's own permissions instruction already reads *"Network access is
  restricted"*, so the effect is achieved regardless. It never blocks codex's own connection to
  OpenAI — that provider network is separate.
- `codex doctor` reports `restricted fs + restricted network` via a `codex-linux-sandbox` helper
  on Linux. Treat as kernel-backed enough for this design; **not a formal claim** — Landlock is
  unavailable on this host (`landlock_create_ruleset` → `errno 38`).

### `-s read-only` blocks WRITES, not READS
This is the most important sentence in this file. Under `-s read-only` the model may still run
read-only shell commands — that is how it explores, and we want it to. So `cat ~/.aws/credentials`,
`cat ../../.env` and `cat ~/.ssh/id_ed25519` are **permitted**, and whatever is read lands in the
report file *and* in OpenAI's session store. codex has no `--deny Read` equivalent. The read side
is therefore defended by three weaker layers, none of them an enforcement boundary:
1. `codex_review.sh` refuses over-broad roots (`/`, `$HOME`, a parent of `$HOME`, `/etc`, `/mnt`…);
2. `bcc_scan_scope` warns about secret-shaped filenames and symlinks whose target escapes the
   scope (`BCC_STRICT_SCOPE=1` makes those a refusal);
3. both prompt templates instruct the model not to read secret-bearing files.

### Gotcha: `os error 30` on NESTED codex
`-s read-only` makes the filesystem read-only for **tool-executed** commands, so a `codex exec`
spawned *as a model tool inside the sandbox* fails to init its own `$CODEX_HOME` with:
`Error: failed to initialize in-process app-server client: Read-only file system (os error 30)`.
The **top-level** codex process is unaffected. We never nest codex, so this never bites us.

## Verifying what actually applied (free, structured)
Each session writes `$CODEX_HOME/sessions/YYYY/MM/DD/rollout-<ts>-<thread_id>.jsonl`. Two records
there are worth reading and cost nothing (`bcc_thread_context` reads both):

```jsonc
{"type":"session_meta","payload":{"cwd":"…","originator":"codex_exec","cli_version":"0.146.0", …}}
{"type":"turn_context","payload":{"cwd":"…","approval_policy":"never",
                                  "sandbox_policy":{"type":"read-only"},"model":"gpt-5.5"}}
```

- `session_meta.cwd` is which tree the session actually reviewed → the cross-project `--continue`
  guard. `exec resume` cannot be re-pointed (no `-C`), so resuming another project's session would
  review the wrong tree while the report claimed yours. We refuse instead.
- `turn_context.sandbox_policy` is what the config **resolved** to → the ledger's
  `sandbox_verified` field and the report header.

**Two caveats, or this becomes false assurance.** It proves the *resolved configuration*, not
kernel enforcement — it is the right detector for a silently-dropped `-c` key, not evidence that
Landlock applied. And under `BCC_EPHEMERAL=1` no rollout is written, so it degrades to `unknown`,
never to `false`. A stderr substring scan was deliberately *not* used: that is exactly the failure
mode where a chatty-but-successful run gets flipped to a failure, in a new costume.

`codex debug prompt-input [PROMPT]` is the same idea *before* the call: it renders the resolved
permissions block offline in ~1.6s with no model turn. It cannot mirror the argv exactly (it
takes no `--ignore-user-config`), which is why it is a diagnostic here rather than a gate.

## `--json` event shapes we parse (verified)
- `{"type":"thread.started","thread_id":"…"}` — the session id (our resume handle, and the key to
  the rollout file above).
- `{"type":"item.completed","item":{"type":"agent_message","text":"…"}}` — the critique text.
- `{"type":"turn.completed","usage":{"input_tokens":N,"cached_input_tokens":N,
  "output_tokens":N,"reasoning_output_tokens":N}}` — **real token usage** (logged to the ledger;
  better than BetterCallGemini's byte estimate).

The stream is **JSONL, and the payload is spread across different objects** — the id in one, N
message chunks in others, usage in the last. `codex_extract.py` must stay a per-line parser; a
"find the object with the payload fields" parser would discard the thread id, the usage, and every
message after the first.

## Truncation — NOT pinned
BCC passes no `--max-turns` equivalent, so for codex the likely truncation source is
**token/context exhaustion** rather than turn exhaustion, and the exact `--json` signature of a
context-limit stop has not been reproduced. `bcc_is_truncation` matches the plausible strings and
`RESULT=TRUNCATED` is checked *before* the generic non-zero-exit branch, so a partial review is not
reported as a plain ERROR. The experiment still to run: capture `--json` from a run that exhausts
the model's context window and record what `turn.completed` reports against it.

The general lesson from the sibling skill transfers regardless: its CLI's docs said turn exhaustion
produced `stopReason: max_turn_requests`; it actually produced exit 1, stderr
`Error: max turns reached`, and `stopReason: "cancelled"`. Pin the real signature, don't trust docs.

## Repo-planted MCP config — probed, NEGATIVE, so nothing was built
A reviewed repository is untrusted input, and configuration that names a *program* is loaded
before any tool restriction applies — so the question is whether codex reads such config from the
tree under review. **Probed on 0.146.0 and it does not.** With `.mcp.json` and `.codex/config.toml`
both planted in a scratch directory, each naming `sh -c 'touch /tmp/PWNED'`:

```
$ cd /scratch/probe && codex mcp list --json
[]                        # not registered
$ ls /tmp/PWNED*
No such file or directory # never launched
```

MCP servers resolve from `$CODEX_HOME/config.toml` only — the file `--ignore-user-config`
suppresses on our calls anyway. Per the "if the experiments come back negative, build nothing"
rule, **no scanner was added**. The sibling skill's equivalent scanner would have refused 6 of 7 of
a real user's project directories, which is worse than useless.

*Scope of the claim:* this covers registration and launch of MCP servers from a reviewed tree at
0.146.0 on Linux. It does not cover hooks or plugins, and it should be re-probed when the CLI's
config discovery changes.

## Models & reasoning effort
- List: `codex debug models` (or offline `codex debug models --bundled`).
- Default / deepest review model: **`gpt-5.5`**. Context window ~272k (a rollout on this host
  reported `model_context_window: 258400`).
- Reasoning effort: `-c model_reasoning_effort="high"` (`low|medium|high|xhigh`; default
  `medium`). Higher = deeper but **burns plan rate limits faster** — drop to `medium` on quota.

## Native `codex review` (why we don't use it here)
`codex review` / `codex exec review` (`--base` / `--uncommitted` / `--commit`) is **diff-oriented**
— a review of git changes, not a broad whole-codebase critique. For BetterCallChatGPT's
intent-first, no-diff critique we use plain `codex exec`.

## Auth
- Default: ChatGPT login (`codex login`; headless/SSH: `codex login --device-auth`). API key:
  `printenv OPENAI_API_KEY | codex login --with-api-key`.
- Creds: `$CODEX_HOME` = `~/.codex`, auth file `~/.codex/auth.json`.
- Check: `codex login status` → `Logged in using ChatGPT` when OK. **Measured at 94 ms and it
  makes no billed call**, which is why the wrapper calls it as a pre-run gate rather than relying
  on a stderr regex after paying. That converts the most consequential classification in the
  system — AUTH is the cap-exempt class — into a structural check that cannot be fooled.
  `BCC_SKIP_LOGIN_CHECK=1` opts out where it is not authoritative.
- Failure strings (still used as a fallback classifier): `not logged in|unauthenticated|
  unauthorized|token expired|client authentication not set up|authentication failed`. Note there
  is deliberately no bare `401` in this pattern.

## Quota / rate limits / usage
- **No stable quota readout** from the CLI. `codex doctor` does NOT show remaining quota.
- Detect exhaustion by matching: `429`, `TooManyRequests`, `ResourceExhausted`, `rate limit`,
  `quota`, `usage limit`, `credits depleted`, `WorkspaceMemberUsageLimitReached`,
  `workspace_owner_credits_depleted`, `noCredit`.
- **Where that match counts is not symmetric.** In `$BCC_ERRFILE` — allow-listed fields of codex's
  own error *events* — it counts unconditionally, so a throttled-but-completed run is still
  reported as `QUOTA` rather than a clean `OK` hiding a partial review. In raw stderr it counts
  only when the run failed, because codex's stderr is chatty and `info: quota check passed` or
  `read_file src/rate_limit/a.py` match the same regex on a perfectly good run.
  *Known limit:* if codex ever throttles, degrades, exits 0 with a full body and reports it on
  stderr only, we cannot distinguish that from success and will report `OK`.
- Policy: **never retry-loop** on quota — stop and wait for reset.

## Exit codes
- `0` success · `2` CLI usage error · `1` various (doctor/reachability, app-server init).
- `124`/`137` wall-clock timeout, `130`/`143` signalled → all classified `TIMEOUT`.
- `125`/`126`/`127` belong to `timeout(1)` / exec failure: nothing reached the model, so these are
  the **only** codes on which the wrapper clears the `billed` flag from the exit status alone.
  Everything else once launched stays billed — bias toward over-counting.

## PTY / headless
`codex exec` is built for non-interactive subprocess use — **no PTY needed** (unlike `agy`). Main
hang risks: forgetting `-a never` (approval prompt), auth/login flows, network stalls, or a
non-writable `$CODEX_HOME`. The wrapper launches codex in the **background** with an explicit
`wait`, as a process-group leader, so a signal is acted on immediately instead of being deferred
until codex exits — which for a foreground child meant a SIGTERM did nothing for up to
`$BCC_TIMEOUT` while codex ran to completion and billed in full.

## Sessions
- Stored under `$CODEX_HOME` (`~/.codex/sessions/YYYY/MM/DD/rollout-*.jsonl`). `--ephemeral` skips
  persistence (then nothing to resume and no rollout to verify against).
- We persist by default and save the thread id **per scope** under `$BCC_STATE_DIR/sessions/`.
  A single global `last_thread` meant `--continue` in project B resumed project A's session,
  kept A's working root, and reviewed the wrong tree while the header claimed B.

## Config knobs (a deterministic write-blocked critique)
```
-s read-only                       # typed, top-level, wins over -c, fails loudly
-c sandbox_mode="read-only"        # defence in depth
-c approval_policy="never"
-c network_access=false            # belt-and-braces; key placement unverified
-c model_reasoning_effort="high"   # or "xhigh" for expensive deep review
```
Plus flags: `--ignore-user-config --ignore-rules --skip-git-repo-check --color never --json`.
Codex reads `AGENTS.md` / project docs by default; `--ignore-rules` skips `.rules` but **keeps
`AGENTS.md`**, so the prompt templates are the only place a prompt-injection defence can land.
For a fully sterile review, tell the user which project docs remain in play.

## Experiment mode (Mode B) — the key difference from BetterCallGemini
Write-blocking forbids the model writing scripts anywhere, so agy's "write into a sandbox" pattern
does NOT map. Instead Codex **proposes** script contents as fenced code blocks in its report;
Claude writes them into a sandbox dir, reviews each, and runs the approved ones with
`scripts/run_local.sh`, then feeds results back via `--continue`.

**`conda run` and `--`:** do NOT put a `--` separator before the command. `conda run` does not
treat it as end-of-options — it passes it through as the first *word* of the command:
```
/tmp/tmpsugs0eeh: line 3: --: command not found
ERROR conda.cli.main_run:execute(127): `conda run -- timeout …` failed.
```
Reproduced on conda 25.7.0. That single character made Mode B dead on every host until v1.1.0.
