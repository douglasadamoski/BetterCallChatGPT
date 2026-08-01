#!/usr/bin/env python3
"""codex_extract.py — turn `codex exec --json` JSONL into a report + metadata.

Codex's `--json` stream is one JSON object per line (JSONL). The shapes we rely on
(verified against codex-cli 0.146.0):

  {"type":"thread.started","thread_id":"..."}
  {"type":"item.completed","item":{"type":"agent_message","text":"..."}}
  {"type":"turn.completed","usage":{"input_tokens":N,"cached_input_tokens":N,
                                    "output_tokens":N,"reasoning_output_tokens":N}}
  {"type":"error", ...}  (best-effort; shape not guaranteed)

The payload is spread across DIFFERENT objects — the thread id in one, N message chunks in
others, usage in the last — so this must stay a per-line JSONL parser. A "find the object with
the payload fields" parser (correct for a single pretty-printed document) would discard the
thread id, the usage, and every message after the first.

Usage:
  codex_extract.py <in.jsonl> [--meta meta.json] [--errfile err.txt] [--kv kv.txt]

Outputs:
  stdout      the concatenated agent-message text — becomes the report body
  --meta      normalized metadata as JSON (thread id, token usage, counts)
  --errfile   ONLY allow-listed API/CLI error strings, for the wrapper's AUTH/QUOTA
              classifiers. Kept OUT of --meta on purpose: the previous version appended
              json.dumps(whole_event)[:2000], and those bodies routinely embed model- and
              repo-controlled strings (failed command text, file paths, upstream messages
              quoting file contents). A review of a repo containing src/rate_limit/ or a failed
              `grep -rn unauthorized` could therefore land matching text in the very channel the
              code certified as "isolated API error events, never agent-message text", producing
              a false AUTH — which is cap-exempt, so the paid call vanished from the ledger AND
              the user was told to re-authenticate on top of a good review.
  --kv        one TAB-separated KEY<TAB>VALUE line per field, so the wrapper needs ONE python
              invocation instead of the extractor plus five `python3 -c` calls. The wrapper reads
              it with a fixed key allowlist and does NOT `source` it, so nothing here is ever
              evaluated as shell.

THIS SCRIPT MUST NOT LOSE A RUN THAT WAS ALREADY PAID FOR. By the time it runs, the money is
spent. So every failure mode degrades rather than aborts: any unexpected exception is caught and
recorded in `error_text`, and the meta/errfile/kv artifacts are written even when parsing fails.
Exit status is always 0 — the shell classifies from codex's own exit code plus these artifacts.

Two things deliberately NOT done here:
  * No `json.dump(..., allow_nan=False)`. Today a non-finite value costs nothing: json.load
    accepts it and the classifiers only grep. With that flag json.dump raises mid-write and
    leaves a truncated or absent meta — no thread id, no tokens, no error_text — turning a
    harmless value into a lost meta file. It would only be safe alongside a re-dump fallback.
  * No character-stripping integer coercion. `${v//[!0-9]/}` turns -5 into 5 and 1e5 into 15 —
    a silent sign flip in billing data. We validate instead.
"""
import argparse
import json
import os
import sys

MAX_ERR_FIELD = 500      # per extracted string
MAX_ERR_TOTAL = 4000     # for the whole errfile

# The only keys the wrapper reads back. Keys are code, not data: the wrapper matches this exact
# fixed set and ignores anything else, so a stray key from a future version cannot introduce a
# new shell variable.
KV_KEYS = (
    "THREAD_ID",
    "TOK_IN",
    "TOK_CACHED",
    "TOK_OUT",
    "TOK_REASON",
    "N_MESSAGES",
    "N_ERRORS",
    "STOP_REASON",
)


def _int(value):
    """A non-negative int, or 0. Validates; never strips characters."""
    if isinstance(value, bool):          # bool is an int subclass; True must not become 1 token
        return 0
    if isinstance(value, int):
        return value if value >= 0 else 0
    if isinstance(value, float):
        # Rejects inf/nan (int() would raise) and negatives.
        try:
            i = int(value)
        except (ValueError, OverflowError):
            return 0
        return i if i >= 0 else 0
    if isinstance(value, str):
        s = value.strip()
        return int(s) if s.isdigit() else 0
    return 0


def _text(value):
    """A single-line, control-free string, capped. NULs are dropped: bash silently truncates at
    a NUL when reading, so leaving one in would be lossy rather than dangerous."""
    if value is None:
        return ""
    if not isinstance(value, str):
        try:
            value = json.dumps(value)
        except (TypeError, ValueError):
            value = repr(value)
    value = value.replace("\x00", "")
    value = "".join(" " if (ch < " " or ch == "\x7f") else ch for ch in value)
    return value[:MAX_ERR_FIELD].strip()


def _error_strings(obj):
    """Allow-listed fields only — never the whole event object."""
    out = []
    for key in ("type", "code", "message"):
        v = obj.get(key)
        if isinstance(v, (str, int, float)) and not isinstance(v, bool):
            t = _text(v)
            if t:
                out.append("%s=%s" % (key, t))
    err = obj.get("error")
    if isinstance(err, dict):
        for key in ("type", "code", "message"):
            v = err.get(key)
            if isinstance(v, (str, int, float)) and not isinstance(v, bool):
                t = _text(v)
                if t:
                    out.append("error.%s=%s" % (key, t))
    elif isinstance(err, str):
        t = _text(err)
        if t:
            out.append("error=%s" % t)
    return out


def _empty_meta():
    """Single source of truth for the meta schema — defined ONCE. Duplicated dict literals drift,
    and a drifted copy is how a field ends up populated on only one code path."""
    return {
        "thread_id": "",
        "input_tokens": 0,
        "cached_input_tokens": 0,
        "output_tokens": 0,
        "reasoning_output_tokens": 0,
        "n_messages": 0,
        "n_errors": 0,
        "stop_reason": "",
        "error_text": "",
    }


def _write_atomic(path, data):
    """Write via a temp + os.replace so a crash mid-write cannot leave a half-file that the
    wrapper would then read as authoritative."""
    tmp = path + ".tmp"
    with open(tmp, "w", encoding="utf-8", errors="replace") as fh:
        fh.write(data)
    os.replace(tmp, path)


def _emit(args, meta, errors):
    """Write every artifact. Called on the success path AND from the catch-all, so a run that
    blew up still yields a meta file, an errfile and a kv file."""
    if args.errfile:
        blob = " | ".join(errors)[:MAX_ERR_TOTAL]
        try:
            _write_atomic(args.errfile, blob + ("\n" if blob else ""))
        except OSError:
            pass
    if args.meta:
        try:
            _write_atomic(args.meta, json.dumps(meta))
        except (OSError, TypeError, ValueError):
            # Last resort: a minimal, definitely-serializable meta beats no meta at all.
            try:
                _write_atomic(args.meta, json.dumps(_empty_meta()))
            except OSError:
                pass
    if args.kv:
        values = {
            "THREAD_ID": meta.get("thread_id", ""),
            "TOK_IN": meta.get("input_tokens", 0),
            "TOK_CACHED": meta.get("cached_input_tokens", 0),
            "TOK_OUT": meta.get("output_tokens", 0),
            "TOK_REASON": meta.get("reasoning_output_tokens", 0),
            "N_MESSAGES": meta.get("n_messages", 0),
            "N_ERRORS": meta.get("n_errors", 0),
            "STOP_REASON": meta.get("stop_reason", ""),
        }
        lines = []
        for key in KV_KEYS:
            # Tab-separated and single-line by construction: _text() has already flattened every
            # control character, so one record can never spill into the next.
            lines.append("%s\t%s" % (key, _text(values.get(key, ""))))
        try:
            _write_atomic(args.kv, "\n".join(lines) + "\n")
        except OSError:
            pass


def parse(path, meta, errors):
    messages = []
    usage = {}
    with open(path, encoding="utf-8", errors="replace") as fh:
        for line in fh:
            line = line.strip()
            if not line:
                continue
            try:
                o = json.loads(line)
            except ValueError:
                continue  # non-JSON noise (a banner line, a partial write); skip just this line
            if not isinstance(o, dict):
                continue
            t = o.get("type", "")
            if not isinstance(t, str):
                t = ""

            if t == "thread.started":
                tid = o.get("thread_id")
                if isinstance(tid, str) and tid:
                    meta["thread_id"] = tid
            elif t == "turn.completed":
                u = o.get("usage")
                if isinstance(u, dict):
                    usage = u
                for key in ("stop_reason", "status", "reason"):
                    v = o.get(key)
                    if isinstance(v, str) and v:
                        meta["stop_reason"] = _text(v)
                        break
            elif t == "item.completed":
                item = o.get("item")
                if isinstance(item, dict) and item.get("type") == "agent_message":
                    txt = item.get("text")
                    # Schema drift guard: `text` arriving as a dict used to raise TypeError out
                    # of main() and discard the entire paid-for run.
                    if isinstance(txt, str) and txt:
                        messages.append(txt)

            # Failure text for the wrapper's AUTH/QUOTA/TIMEOUT classifiers. Match failure-ish
            # event TYPES, or an event carrying a truthy error / a failed status — but NEVER an
            # agent_message, which would let the model's own critique false-trigger the
            # classifier.
            is_agent = (
                t == "item.completed"
                and isinstance(o.get("item"), dict)
                and o["item"].get("type") == "agent_message"
            )
            tl = t.lower()
            if not is_agent and (
                any(w in tl for w in ("error", "failed", "cancel", "timeout"))
                or o.get("error")
                or o.get("status") in ("failed", "error", "cancelled")
            ):
                fields = _error_strings(o)
                if fields:
                    errors.extend(fields)
                    meta["n_errors"] += 1   # failure EVENTS, not extracted field count

    meta["input_tokens"] = _int(usage.get("input_tokens", 0))
    meta["cached_input_tokens"] = _int(usage.get("cached_input_tokens", 0))
    meta["output_tokens"] = _int(usage.get("output_tokens", 0))
    meta["reasoning_output_tokens"] = _int(usage.get("reasoning_output_tokens", 0))
    meta["n_messages"] = len(messages)
    return messages


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("infile")
    ap.add_argument("--meta")
    ap.add_argument("--errfile")
    ap.add_argument("--kv")
    args = ap.parse_args()

    meta = _empty_meta()
    errors = []
    messages = []
    try:
        messages = parse(args.infile, meta, errors)
    except Exception as exc:  # noqa: BLE001 — deliberate catch-all; see the module docstring
        # The run is already billed. Record what went wrong and still emit every artifact, so the
        # wrapper can classify and the ledger stays accurate, instead of losing the call outright.
        meta["error_text"] = _text("codex_extract failed: %s: %s" % (type(exc).__name__, exc))
        errors.append(meta["error_text"])
        meta["n_errors"] += 1

    if errors and not meta["error_text"]:
        meta["error_text"] = _text(" | ".join(errors))

    try:
        body = "\n\n".join(messages)
        if body:
            body += "\n"
        sys.stdout.write(body)
        sys.stdout.flush()
    except Exception as exc:  # noqa: BLE001 — e.g. UnicodeEncodeError under a C locale
        # Retry through the byte layer with replacement rather than dropping the report body.
        try:
            sys.stdout.buffer.write(
                "\n\n".join(messages).encode("utf-8", "replace") + b"\n"
            )
            sys.stdout.buffer.flush()
        except Exception:  # noqa: BLE001
            if not meta["error_text"]:
                meta["error_text"] = _text("codex_extract could not write the report body: %s" % exc)

    _emit(args, meta, errors)
    return 0


if __name__ == "__main__":
    sys.exit(main())
