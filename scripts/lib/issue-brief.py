#!/usr/bin/env python3
"""Render a `gh issue view --json` payload as a runner brief.

Sourced by scripts/claim-next-issue.sh. Reads the issue JSON on stdin and writes
either a paste-ready brief (for a spawn prompt or sticky next-prompt) or the same
information as JSON, so an orchestrator can act on the fields without scraping
prose.

Issue bodies come from two places and both have to parse: the `agent-work.yml`
issue *form*, which renders its fields as `### Goal` headings, and the
hand-written issues that predate it, which use `## Goal`. Anything the parser
does not recognise still survives in `body`, so a brief is never lossier than
the issue itself.
"""

import argparse
import json
import re
import sys

# Fields the runner acts on, in the order they belong in a brief. Aliases cover
# the wording drift between the form and hand-written issues.
SECTIONS = [
    ("goal", ("goal", "summary", "problem")),
    ("acceptance", ("acceptance", "acceptance criteria", "done when")),
    ("constraints", ("constraints", "constraint")),
    ("forbidden", ("forbidden", "non-goals", "out of scope")),
    ("needs", ("needs", "blocked on", "depends on")),
    ("parent", ("parent", "parent epic", "epic")),
]

HEADING = re.compile(r"^#{2,4}\s+(?P<title>.+?)\s*$", re.MULTILINE)


def split_sections(body):
    """Map normalised heading -> section text for every heading in the body."""
    matches = list(HEADING.finditer(body or ""))
    sections = {}

    for index, match in enumerate(matches):
        end = matches[index + 1].start() if index + 1 < len(matches) else len(body)
        title = match.group("title").strip().rstrip(":").lower()
        sections[title] = body[match.end() : end].strip()

    return sections


def pick(sections, aliases):
    for alias in aliases:
        if sections.get(alias):
            return sections[alias]
    return ""


def label_value(labels, prefix):
    for name in labels:
        if name.startswith(prefix):
            return name[len(prefix) :]
    return ""


def task_slug(number, title):
    """A branch/worktree-safe slug for spawn-agent-worker.sh.

    Truncates on a word boundary: the slug becomes a branch and a directory
    name, and `...-git-mutati` reads like a typo every time someone lists them.
    """
    words = [w for w in re.sub(r"[^a-z0-9]+", "-", (title or "").lower()).split("-") if w]

    tail = ""
    for word in words:
        candidate = "%s-%s" % (tail, word) if tail else word
        if len(candidate) > 32:
            break
        tail = candidate

    return "issue%s%s" % (number, "-" + tail if tail else "")


def render_brief(brief):
    lines = [
        "ISSUE #%s — %s" % (brief["number"], brief["title"]),
        brief["url"],
    ]

    meta = [
        ("workspace", brief["workspace"]),
        ("priority", brief["priority"]),
        ("kind", brief["kind"]),
        ("parent", brief["parent"]),
    ]
    meta = ["%s: %s" % (key, value) for key, value in meta if value]
    if meta:
        lines.append(" | ".join(meta))

    if brief["state"] == "already-mine":
        lines.append("claim: already held by %s — continue it" % brief["owner"])
    elif brief["state"] == "dry-run":
        lines.append("claim: NOT claimed (dry run)")
    else:
        lines.append("claim: held by %s" % brief["owner"])

    for key, heading in (
        ("goal", "GOAL"),
        ("acceptance", "ACCEPTANCE"),
        ("constraints", "CONSTRAINTS"),
        ("forbidden", "FORBIDDEN"),
        ("needs", "NEEDS"),
    ):
        if brief[key]:
            lines += ["", heading, brief[key]]

    if not brief["goal"] and not brief["acceptance"]:
        # Nothing recognisable to summarise — better a verbatim body than a
        # confident-looking brief with the substance parsed away.
        lines += ["", "BODY (unstructured)", brief["body"].strip() or "(empty)"]

    lines += [
        "",
        "PROTOCOL",
        "Work in your own worktree branched from origin/master. Open a PR, comment",
        "its URL on the issue, then close the issue with queue/done. If you get",
        "stuck, comment BLOCKED with **Needs:** and swap queue/claimed →",
        "queue/blocked so someone else can pick it up. Do not merge unless the",
        "issue says to.",
        "",
        "SPAWN",
        "bash scripts/spawn-agent-worker.sh <runtime> %s" % brief["task_slug"],
    ]

    return "\n".join(lines) + "\n"


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--format", choices=("brief", "json"), default="brief")
    parser.add_argument("--owner", default="")
    parser.add_argument("--state", default="claimed")
    parser.add_argument("--workspace-label", default="")
    args = parser.parse_args()

    issue = json.load(sys.stdin)
    body = issue.get("body") or ""
    sections = split_sections(body)
    labels = [label["name"] for label in issue.get("labels") or []]

    brief = {
        "number": issue["number"],
        "url": issue.get("url", ""),
        "title": issue.get("title", ""),
        "labels": labels,
        "workspace": label_value(labels, "workspace/") or args.workspace_label,
        "priority": label_value(labels, "priority/"),
        "kind": label_value(labels, "kind/"),
        "owner": args.owner,
        "state": args.state,
        "body": body,
        "task_slug": task_slug(issue["number"], issue.get("title", "")),
    }

    for key, aliases in SECTIONS:
        brief[key] = pick(sections, aliases)

    if args.format == "json":
        brief["brief"] = render_brief(brief)
        json.dump(brief, sys.stdout, indent=2, sort_keys=True)
        sys.stdout.write("\n")
    else:
        sys.stdout.write(render_brief(brief))


if __name__ == "__main__":
    main()
