#!/usr/bin/env python3
"""README checks: the disclaimer is the first line, every #anchor link points at
a heading (GitHub slug rules), and every repo path the README links to exists."""
import os
import re
import sys

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
text = open(os.path.join(REPO, "README.md"), encoding="utf-8").read()
fails = []


def slug(heading):
    return re.sub(r"[^\w\- ]", "", heading.strip().lower()).replace(" ", "-")


first = text.splitlines()[0]
if first != "**This project was made with Claude Ai**":
    fails.append(f"first line is not the disclaimer: {first!r}")

headings = {slug(h) for h in re.findall(r"^#{1,6} (.+)$", text, re.M)}
for anchor in re.findall(r"\]\(#([^)]+)\)", text):
    if anchor not in headings:
        fails.append(f"broken anchor #{anchor}")

for target in re.findall(r"\]\(((?!https?:|#|\.\./)[^)\s]+)\)", text):
    if not os.path.exists(os.path.join(REPO, target.split("#")[0])):
        fails.append(f"missing linked path {target}")

for path in sorted(set(re.findall(r"`((?:build|flash|images|tools|prebuilt|tests)/[\w./-]+)`", text))):
    if not os.path.exists(os.path.join(REPO, path)):
        fails.append(f"README mentions missing file {path}")

for f in fails:
    print("FAIL ", f)
print("README checks passed" if not fails else f"{len(fails)} README problem(s)")
sys.exit(1 if fails else 0)
