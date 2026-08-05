#!/usr/bin/env python3
"""Validate captured Slack webhook payloads against the Block Kit contract.

Prints a JSON summary on stdout so tests/run_tests.sh can assert on it with jq.
Exits non-zero only on an internal error; structural problems are reported in
the "errors" list so a test can assert on them explicitly.
"""
import argparse
import glob
import json
import os
import sys

MAX_BLOCKS = 50
MAX_HEADER = 150
MAX_SECTION = 3000
ALLOWED_BLOCK_TYPES = {"header", "section", "divider"}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("reqdir")
    args = ap.parse_args()

    errors = []
    messages = []

    paths = sorted(glob.glob(os.path.join(args.reqdir, "req_*.json")))
    for p in paths:
        raw = open(p, "rb").read()
        name = os.path.basename(p)
        try:
            doc = json.loads(raw.decode("utf-8"))
        except Exception as exc:
            errors.append("%s: not valid JSON: %s" % (name, exc))
            continue

        if not isinstance(doc, dict) or "blocks" not in doc:
            errors.append("%s: missing top-level 'blocks'" % name)
            continue
        blocks = doc["blocks"]
        if not isinstance(blocks, list):
            errors.append("%s: 'blocks' is not a list" % name)
            continue
        if len(blocks) == 0:
            errors.append("%s: 'blocks' is empty" % name)
        if len(blocks) > MAX_BLOCKS:
            errors.append("%s: %d blocks exceeds Slack limit of %d"
                          % (name, len(blocks), MAX_BLOCKS))

        headers, sections = [], []
        for i, b in enumerate(blocks):
            if not isinstance(b, dict) or "type" not in b:
                errors.append("%s: block %d has no type" % (name, i))
                continue
            t = b["type"]
            if t not in ALLOWED_BLOCK_TYPES:
                errors.append("%s: block %d unexpected type %r" % (name, i, t))
                continue
            if t == "divider":
                continue

            txt = b.get("text")
            if not isinstance(txt, dict):
                errors.append("%s: block %d (%s) has no text object" % (name, i, t))
                continue
            val = txt.get("text")
            if not isinstance(val, str) or val == "":
                errors.append("%s: block %d (%s) empty text" % (name, i, t))
                continue

            if t == "header":
                if txt.get("type") != "plain_text":
                    errors.append("%s: block %d header must be plain_text, got %r"
                                  % (name, i, txt.get("type")))
                if len(val) > MAX_HEADER:
                    errors.append("%s: header %d chars exceeds %d"
                                  % (name, len(val), MAX_HEADER))
                headers.append(val)
            else:
                if txt.get("type") != "mrkdwn":
                    errors.append("%s: block %d section must be mrkdwn, got %r"
                                  % (name, i, txt.get("type")))
                if len(val) > MAX_SECTION:
                    errors.append("%s: section %d chars exceeds %d"
                                  % (name, len(val), MAX_SECTION))
                sections.append(val)

        messages.append({
            "file": name,
            "blocks": len(blocks),
            "headers": headers,
            "sections": sections,
        })

    all_headers = [h for m in messages for h in m["headers"]]
    all_sections = [s for m in messages for s in m["sections"]]

    # A header belongs only at the very start of the first message.
    if len(all_headers) > 1:
        errors.append("expected at most 1 header across all messages, got %d"
                      % len(all_headers))
    if messages and messages[0]["blocks"] > 0:
        first = json.loads(open(os.path.join(args.reqdir, messages[0]["file"]),
                                "rb").read().decode("utf-8"))
        if first["blocks"][0].get("type") != "header":
            errors.append("first block of first message is not the header")

    summary = {
        "messages": len(messages),
        "blocks_total": sum(m["blocks"] for m in messages),
        "max_blocks_in_msg": max([m["blocks"] for m in messages], default=0),
        "headers": all_headers,
        "sections": all_sections,
        "errors": errors,
    }
    json.dump(summary, sys.stdout, indent=None)
    sys.stdout.write("\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
