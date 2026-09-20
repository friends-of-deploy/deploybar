#!/usr/bin/env python3
"""Print one dated CHANGELOG entry for GitHub Releases and the Sparkle feeds."""
import argparse
from datetime import date
from pathlib import Path
import re
import sys


def extract(text: str, version: str) -> str:
    sections = list(re.finditer(r"^## (.+)$", text, re.MULTILINE))
    matches = [(index, heading) for index, heading in enumerate(sections)
               if heading.group(1).startswith(f"[{version}]")]
    if len(matches) != 1:
        raise ValueError(f"Expected exactly one changelog entry for {version}; found {len(matches)}")
    index, heading = matches[0]
    dated = re.fullmatch(rf"\[{re.escape(version)}\] - (\d{{4}}-\d{{2}}-\d{{2}})", heading.group(1))
    if not dated:
        raise ValueError(f"Entry {version} must use '## [VERSION] - YYYY-MM-DD'")
    date.fromisoformat(dated.group(1))
    end = sections[index + 1].start() if index + 1 < len(sections) else len(text)
    body = text[heading.end():end].strip()
    if not body:
        raise ValueError(f"Changelog entry {version} is empty")
    return body + "\n"


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("version", help="Release version or v-prefixed tag")
    parser.add_argument("changelog", nargs="?", type=Path,
                        default=Path(__file__).resolve().parent.parent / "CHANGELOG.md")
    args = parser.parse_args()
    version = args.version.removeprefix("v")
    if not re.fullmatch(r"\d+\.\d+\.\d+(?:-[0-9A-Za-z]+(?:[.-][0-9A-Za-z]+)*)?", version):
        parser.error("version must look like 1.2.0 or 1.2.0-beta.1")
    try:
        body = extract(args.changelog.read_text(encoding="utf-8"), version)
    except (OSError, ValueError) as error:
        print(f"release-notes: {error}", file=sys.stderr)
        return 1
    sys.stdout.write(body)
    return 0


if __name__ == "__main__":
    sys.exit(main())
