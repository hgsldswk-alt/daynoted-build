"""Export named XCTest attachments, retaining the names used in the store listing."""
import argparse
import json
from pathlib import Path
import re
import shutil
import subprocess
import tempfile

SHOT = re.compile(r"(?<![A-Za-z0-9])(store-(?:en|zh-Hans|zh-Hant)-\d{2}-[a-z]+|paid-01-paywall)(?![A-Za-z0-9-])")
LANGUAGES = ("en", "zh-Hans", "zh-Hant")
SCENES = ("01-today", "02-compose", "03-week", "04-history", "05-share")
EXPECTED = {f"store-{lang}-{scene}" for lang in LANGUAGES for scene in SCENES} | {"paid-01-paywall"}


def attachments(node):
    if isinstance(node, dict):
        if "exportedFileName" in node:
            yield node
        for value in node.values():
            yield from attachments(value)
    elif isinstance(node, list):
        for value in node:
            yield from attachments(value)


def collect(raw, output):
    root = raw.resolve()
    found = {}
    for manifest in raw.rglob("manifest.json"):
        for attachment in attachments(json.loads(manifest.read_text(encoding="utf-8"))):
            source = (manifest.parent / attachment["exportedFileName"]).resolve()
            if not source.is_relative_to(root) or not source.is_file() or source.suffix.lower() != ".png":
                continue
            names = (attachment.get("suggestedHumanReadableName") or "", source.name)
            match = next((match for name in names if (match := SHOT.search(name))), None)
            if match and match.group(1) in EXPECTED:
                found[match.group(1)] = source
    for source in raw.rglob("*.png"):
        if (match := SHOT.search(source.name)) and match.group(1) in EXPECTED:
            found.setdefault(match.group(1), source)
    missing = EXPECTED - found.keys()
    if missing:
        raise ValueError("Missing XCTest attachments: " + ", ".join(sorted(missing)))
    output.mkdir(parents=True, exist_ok=True)
    for name, source in sorted(found.items()):
        shutil.copyfile(source, output / f"{name}.png")
    return len(found)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("xcresult", type=Path)
    parser.add_argument("output", type=Path)
    parser.add_argument("--raw", type=Path, help="Use existing attachment export, for tests.")
    args = parser.parse_args()
    try:
        if args.raw:
            count = collect(args.raw, args.output)
        else:
            with tempfile.TemporaryDirectory(dir=args.xcresult.resolve().parent) as directory:
                raw = Path(directory)
                subprocess.run(["xcrun", "xcresulttool", "export", "attachments", "--path", str(args.xcresult),
                                "--output-path", str(raw)], check=True)
                count = collect(raw, args.output)
    except (OSError, ValueError, subprocess.CalledProcessError) as exc:
        parser.exit(1, f"{exc}\n")
    print(f"Exported {count} named PNG attachments to {args.output}")


if __name__ == "__main__":
    main()
