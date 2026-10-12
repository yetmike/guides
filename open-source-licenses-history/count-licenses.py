#!/usr/bin/env python3
"""Count license families in the installed Debian/Ubuntu packages.

Reads every /usr/share/doc/*/copyright file and looks at its "License:" fields.
A package counts once per family if any of its License: fields mentions it.

  python3 count-licenses.py            the count used in the video
  python3 count-licenses.py --strict   GPL without LGPL/AGPL, and without the
                                       Debian packaging files (Files: debian/*)

Rough on purpose: see README.md for what it gets wrong.
"""
import glob
import re
import sys

strict = "--strict" in sys.argv
GPL = r"(?<![LA])GPL" if strict else r"GPL"
PERMISSIVE = r"MIT|Expat|BSD|Apache|ISC|Zlib"

files = glob.glob("/usr/share/doc/*/copyright")
if not files:
    sys.exit("no /usr/share/doc/*/copyright files found: this needs Debian or Ubuntu")

count = dict(gpl=0, permissive=0, mit=0, both=0, unparsed=0)
for path in files:
    try:
        text = open(path, errors="ignore").read()
    except OSError:
        continue
    if strict:  # drop the paragraphs that only cover the packaging
        text = "\n\n".join(p for p in re.split(r"\n\s*\n", text) if not re.search(r"(?im)^Files:\s*debian/", p))
    licenses = " ".join(re.findall(r"(?im)^License:\s*(.*)$", text))
    if not licenses:
        count["unparsed"] += 1
        continue
    gpl = bool(re.search(GPL, licenses, re.I))
    permissive = bool(re.search(PERMISSIVE, licenses, re.I))
    count["gpl"] += gpl
    count["permissive"] += permissive
    count["mit"] += bool(re.search(r"MIT|Expat", licenses, re.I))
    count["both"] += gpl and permissive

n = len(files)
print(f"packages with a license file: {n}")
for name, value in count.items():
    print(f"{name:>10}: {value:5d}  {100 * value / n:4.1f}%")
