#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")"

python3 - <<'PY'
from __future__ import annotations

import os
import re
import shlex
import subprocess
import sys
from pathlib import Path

REPO = Path.cwd()
MAX_BATCH_FILES = int(os.environ.get("MAX_BATCH_FILES", "1000"))
MAX_BATCH_BYTES = int(os.environ.get("MAX_BATCH_BYTES", str(200 * 1024 * 1024)))
LFS_THRESHOLD = int(os.environ.get("LFS_THRESHOLD", str(100 * 1024 * 1024)))
DRY_RUN = os.environ.get("DRY_RUN", "").lower() in {"1", "true", "yes", "on"}


def run(cmd: list[str]) -> None:
    print("+ " + " ".join(shlex.quote(part) for part in cmd))
    if not DRY_RUN:
        subprocess.run(cmd, cwd=REPO, check=True)


def capture(cmd: list[str]) -> str:
    return subprocess.check_output(cmd, cwd=REPO, text=True).strip()


def get_untracked_paths() -> list[Path]:
    raw = subprocess.check_output(
        ["git", "ls-files", "--others", "--exclude-standard", "-z"],
        cwd=REPO,
    )
    paths: list[Path] = []
    for item in raw.split(b"\0"):
        if not item:
            continue
        paths.append(Path(item.decode("utf-8", errors="surrogateescape")))
    return sorted(paths, key=lambda path: path.as_posix().lower())


def file_size(path: Path) -> int:
    try:
        return (REPO / path).stat().st_size
    except FileNotFoundError:
        return 0


def discover_start_batch() -> int:
    explicit = os.environ.get("START_BATCH")
    if explicit:
        return int(explicit, 10)

    try:
        subject = capture(["git", "log", "-1", "--format=%s"])
    except subprocess.CalledProcessError:
        return 1

    match = re.fullmatch(r"batch\s+(\d+)", subject)
    if match:
        return int(match.group(1), 10) + 1
    return 1


def build_batches(paths: list[Path]) -> list[list[Path]]:
    batches: list[list[Path]] = []
    current: list[Path] = []
    current_bytes = 0

    for path in paths:
        size = file_size(path)
        if current and (
            len(current) >= MAX_BATCH_FILES
            or current_bytes + size > MAX_BATCH_BYTES
        ):
            batches.append(current)
            current = []
            current_bytes = 0

        current.append(path)
        current_bytes += size

    if current:
        batches.append(current)

    return batches


def track_large_files(paths: list[Path]) -> list[Path]:
    large_files = [path for path in paths if file_size(path) > LFS_THRESHOLD]
    if not large_files:
        return []

    print(
        f"Found {len(large_files)} file(s) over {LFS_THRESHOLD // (1024 * 1024)} MB; "
        "tracking them with Git LFS."
    )
    for path in large_files:
        run(["git", "lfs", "track", "--", path.as_posix()])
    return large_files


def main() -> int:
    run(["git", "lfs", "install", "--local"])

    untracked = get_untracked_paths()
    if not untracked:
        print("No untracked files found. Pushing current branch state.")
        run(["git", "push"])
        return 0

    start_batch = discover_start_batch()
    large_files = track_large_files(untracked)
    if large_files:
        run(["git", "add", "--", ".gitattributes"])

    batches = build_batches(untracked)
    print(
        f"Planned {len(batches)} batch(es) from {len(untracked)} untracked file(s), "
        f"starting at batch {start_batch:02d}."
    )

    if DRY_RUN:
        for offset, batch in enumerate(batches, start=start_batch):
            batch_bytes = sum(file_size(path) for path in batch)
            print(
                f"== batch {offset:02d} == {len(batch)} file(s), "
                f"{batch_bytes / (1024 * 1024):.2f} MB"
            )
        return 0

    for offset, batch in enumerate(batches, start=start_batch):
        batch_bytes = sum(file_size(path) for path in batch)
        print(f"\n== batch {offset:02d} ==")
        print(f"# {len(batch)} file(s), {batch_bytes / (1024 * 1024):.2f} MB")

        add_cmd = ["git", "add", "--"]
        if offset == start_batch and large_files:
            add_cmd.append(".gitattributes")
        add_cmd.extend(path.as_posix() for path in batch)
        run(add_cmd)

        run(["git", "commit", "-m", f"batch {offset:02d}"])
        run(["git", "push"])

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
PY
