#!/usr/bin/env python3
"""Checks every Localization/<lang>.lproj/Localizable.strings against en: valid syntax, the same keys, the
same format specifiers (same multiset, so "%@" can't turn into "%d" or vanish), no empty values.
Usage: python3 Tools/check_localization.py   (exit status 1 on any problem)"""
import re, subprocess, sys
from collections import Counter
from pathlib import Path

root = Path(__file__).resolve().parent.parent / "Localization"
pair = re.compile(r'^"((?:[^"\\]|\\.)*)"\s*=\s*"((?:[^"\\]|\\.)*)";\s*$')
spec = re.compile(r'%(?:\d+\$)?[-+ 0#]*\d*(?:\.\d+)?(?:lld|ld|d|@|f|s|%)')

def load(path):
    entries, problems = {}, []
    for number, line in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
        if not line.strip():
            continue
        m = pair.match(line)
        if not m:
            problems.append(f"{path.parent.name}:{number}: not a \"key\" = \"value\"; line: {line[:60]}")
            continue
        if m.group(1) in entries:
            problems.append(f"{path.parent.name}:{number}: duplicate key {m.group(1)[:50]!r}")
        entries[m.group(1)] = m.group(2)
    return entries, problems

english, problems = load(root / "en.lproj" / "Localizable.strings")
languages = sorted(p.name[:-6] for p in root.glob("*.lproj") if p.name != "en.lproj")
for lang in languages:
    path = root / f"{lang}.lproj" / "Localizable.strings"
    if not path.exists():
        problems.append(f"{lang}: Localizable.strings missing")
        continue
    lint = subprocess.run(["plutil", "-lint", str(path)], capture_output=True, text=True)
    if lint.returncode != 0:
        problems.append(f"{lang}: plutil: {lint.stdout.strip() or lint.stderr.strip()}")
    entries, p = load(path)
    problems += p
    for key in english.keys() - entries.keys():
        problems.append(f"{lang}: missing key {key[:60]!r}")
    for key in entries.keys() - english.keys():
        problems.append(f"{lang}: extra key {key[:60]!r}")
    for key, value in entries.items():
        if key not in english:
            continue
        if not value.strip():
            problems.append(f"{lang}: empty value for {key[:60]!r}")
        if Counter(spec.findall(key)) != Counter(spec.findall(value)):
            problems.append(f"{lang}: format specifiers differ for {key[:60]!r}: {spec.findall(key)} vs {spec.findall(value)}")

print(f"{len(english)} keys, {len(languages)} translated languages: {', '.join(languages) or 'none yet'}")
for line in problems:
    print("  PROBLEM", line)
print("OK" if not problems else f"{len(problems)} problem(s)")
sys.exit(1 if problems else 0)
