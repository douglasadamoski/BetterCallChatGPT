#!/usr/bin/env python3
"""codex_extract.py — turn `codex exec --json` JSONL into a report + metadata.

Codex's `--json` stream is one JSON object per line. The shapes we rely on
(verified against codex-cli 0.142.5):

  {"type":"thread.started","thread_id":"..."}
  {"type":"item.completed","item":{"type":"agent_message","text":"..."}}
  {"type":"turn.completed","usage":{"input_tokens":N,"cached_input_tokens":N,
                                    "output_tokens":N,"reasoning_output_tokens":N}}
  {"type":"error", ...}  (best-effort; shape not guaranteed)

Usage:
  codex_extract.py <in.jsonl> [--meta meta.json]
Writes the concatenated agent-message text to stdout (the critique/report body),
and, if --meta is given, a small JSON blob with thread_id + token usage + any
error text (used by the wrapper for the ledger and error classification).
"""
import argparse
import json
import sys


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("infile")
    ap.add_argument("--meta")
    args = ap.parse_args()

    thread_id = ""
    usage = {}
    messages = []
    errors = []

    with open(args.infile, encoding="utf-8", errors="replace") as fh:
        for line in fh:
            line = line.strip()
            if not line:
                continue
            try:
                o = json.loads(line)
            except ValueError:
                continue  # non-JSON noise; skip
            t = o.get("type", "")
            if t == "thread.started":
                thread_id = o.get("thread_id", "") or thread_id
            elif t == "turn.completed":
                u = o.get("usage") or {}
                if isinstance(u, dict):
                    usage = u
            elif t == "item.completed":
                item = o.get("item") or {}
                if item.get("type") == "agent_message":
                    txt = item.get("text")
                    if txt:
                        messages.append(txt)
            # Capture API/CLI failure text for the wrapper's AUTH/QUOTA/TIMEOUT classifier.
            # Match failure-ish event TYPES (error / failed / cancelled / timeout) OR any event
            # carrying a truthy top-level error/status field — but NEVER an agent_message (that
            # would let the model's own critique text false-trigger the classifier).
            is_agent = (t == "item.completed"
                        and isinstance(o.get("item"), dict)
                        and o["item"].get("type") == "agent_message")
            tl = t.lower()
            if not is_agent and (
                any(w in tl for w in ("error", "failed", "cancel", "timeout"))
                or o.get("error") or o.get("status") in ("failed", "error", "cancelled")
            ):
                errors.append(json.dumps(o)[:2000])

    sys.stdout.write("\n\n".join(messages))
    if messages:
        sys.stdout.write("\n")

    if args.meta:
        meta = {
            "thread_id": thread_id,
            "input_tokens": usage.get("input_tokens", 0),
            "cached_input_tokens": usage.get("cached_input_tokens", 0),
            "output_tokens": usage.get("output_tokens", 0),
            "reasoning_output_tokens": usage.get("reasoning_output_tokens", 0),
            "n_messages": len(messages),
            "error_text": " | ".join(errors),
        }
        with open(args.meta, "w", encoding="utf-8") as fh:
            json.dump(meta, fh)


if __name__ == "__main__":
    main()
