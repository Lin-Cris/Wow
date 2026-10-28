#!/usr/bin/env python3
"""Export reviewed HEAD files into a new directory, without Git history."""
import argparse
import hashlib
import json
from pathlib import Path, PurePosixPath
import subprocess

ROOT = Path(__file__).resolve().parents[1]
FILES = {
    ".gitignore", "AGENTS.md", "README.md", "LICENSE", "OPEN_SOURCE.md",
    "scripts/cloud-check.py", "scripts/cloud-setup.sh",
    "scripts/export-silent-companion.swift", "scripts/export-open-source.py",
    "Wow.xcworkspace/contents.xcworkspacedata",
    "CheckBot 首页/.gitignore", "CheckBot 首页/README.md",
    "CheckBot 首页/scripts/prepare-ios-picker-test.mjs",
    "Counter copy/Package.swift",
    "picture-remarker(mainIOS) copy/.gitignore",
    "picture-remarker(mainIOS) copy/.gitattributes",
    "picture-remarker(mainIOS) copy/README.md",
    "picture-remarker(mainIOS) copy/LICENSE",
    "提词器 copy/.gitignore", "提词器 copy/README.md",
}
PREFIXES = (
    "CheckBot 首页/ios/", "Counter copy/CounterApp/",
    "Counter copy/CounterAppTests/", "Counter copy/CounterApp.xcodeproj/",
    "picture-remarker(mainIOS) copy/ios/",
    "提词器 copy/TeleprompterApp/", "提词器 copy/TeleprompterApp.xcodeproj/",
)
EXCLUDED = {
    "Counter copy/CounterApp/BrandAssetSources.md",
    "Counter copy/CounterApp/CompanionLoop.mp4",
    "Counter copy/CounterApp/CompanionLoop.mov",
}
FIXTURE = "Counter copy/CounterAppTests/Fixtures/CounterV1Fixture.sqlite"
BLOCKED_PARTS = {
    ".git", ".aws", ".codex", ".agents", "xcuserdata", "node_modules",
    "DerivedData", ".build", "build", "__pycache__", ".swiftpm",
}
BLOCKED_SUFFIXES = {
    ".p12", ".pfx", ".pem", ".key", ".mobileprovision", ".sqlite",
    ".sqlite3", ".db", ".wowbackup", ".xcuserstate", ".log", ".pyc",
}


def include(name):
    path = PurePosixPath(name)
    if name in EXCLUDED or any(p in BLOCKED_PARTS for p in path.parts):
        return False
    if any(p.startswith("brand_") and p.endswith(".imageset") for p in path.parts):
        return False
    if path.name == ".DS_Store" or path.name.startswith(".env"):
        return False
    if path.suffix.lower() in BLOCKED_SUFFIXES and name != FIXTURE:
        return False
    return name in FILES or name.startswith(PREFIXES)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("destination", type=Path)
    args = parser.parse_args()
    destination = args.destination.expanduser().absolute()
    if destination.exists():
        parser.error("Destination already exists; choose a new directory.")
    revision = subprocess.check_output(
        ["git", "-C", str(ROOT), "rev-parse", "HEAD"], text=True
    ).strip()
    tree = subprocess.check_output(
        ["git", "-C", str(ROOT), "ls-tree", "-rz", revision]
    )
    entries = []
    excluded = 0
    for record in tree.split(b"\0"):
        if not record:
            continue
        info, raw_name = record.split(b"\t", 1)
        mode, kind, object_id = info.decode().split()
        name = raw_name.decode()
        if not include(name):
            excluded += 1
            continue
        if mode not in {"100644", "100755"} or kind != "blob":
            raise SystemExit("Refusing non-regular source: " + name)
        entries.append((name, mode, object_id))
    required = {"README.md", "LICENSE", "OPEN_SOURCE.md", "Counter copy/Package.swift"}
    if not required.issubset({name for name, _, _ in entries}):
        raise SystemExit("Commit the release documentation before exporting.")
    destination.mkdir(parents=True)
    manifest = []
    for name, mode, object_id in entries:
        data = subprocess.check_output(["git", "-C", str(ROOT), "cat-file", "blob", object_id])
        if name == "Counter copy/Package.swift":
            data = b"".join(line for line in data.splitlines(keepends=True)
                            if line.strip() not in {b'"CompanionLoop.mp4",', b'"CompanionLoop.mov",'})
        target = destination / name
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_bytes(data)
        target.chmod(0o755 if mode == "100755" else 0o644)
        manifest.append({"path": name, "sha256": hashlib.sha256(data).hexdigest(), "bytes": len(data)})
    (destination / "SOURCE_MANIFEST.json").write_text(json.dumps({
        "source_commit": revision, "files": manifest,
    }, ensure_ascii=False, indent=2) + "\n")
    print(f"Exported {len(entries)} files plus manifest; excluded {excluded} tracked files.")
    print(destination)


if __name__ == "__main__":
    main()
