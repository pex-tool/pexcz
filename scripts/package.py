# /// script
# requires-python = ">=3.9"
# ///

from __future__ import annotations

import hashlib
import io
import os
import subprocess
import sys
from argparse import ArgumentParser
from pathlib import Path
from typing import Any

PEXCZ_DIST_DIR = Path("dist").resolve()

PEXCZ_BUILD_TARGETS = "All"
PEXCZ_RELEASE_MODE = "small"


def describe_file(path: Path) -> tuple[str, int]:
    hasher = hashlib.sha256()
    size = 0
    with path.open("rb") as fp:
        for chunk in iter(lambda: fp.read(io.DEFAULT_BUFFER_SIZE), b""):
            hasher.update(chunk)
            size += len(chunk)

    return hasher.hexdigest(), size


def package_pexcz(exe_dir: Path) -> None:
    subprocess.run(
        args=[
            sys.executable,
            "-m",
            "ziglang",
            "build",
            f"-Dtargets={PEXCZ_BUILD_TARGETS}",
            f"--release={PEXCZ_RELEASE_MODE}",
            "--prefix-exe-dir",
            exe_dir,
        ],
        check=True,
    )
    hash_table: dict[Path, tuple[str, int]] = {}
    for root, dirs, files in os.walk(exe_dir, topdown=False):
        root_dir = Path(root)
        for d in dirs:
            (root_dir / d).rmdir()

        if exe_dir.samefile(root):
            continue

        for f in files:
            exe = root_dir / f
            dest = exe_dir / f"{exe.stem}-{root_dir.name}{exe.suffix}"
            exe.rename(dest)

            fingerprint, size = describe_file(dest)
            hash_table[dest] = fingerprint, size

            fingerprint = hashlib.sha256(dest.read_bytes()).hexdigest()
            (exe_dir / f"{dest.name}.sha256").write_text(f"{fingerprint} *{dest.name}")
    with (exe_dir / "hashes.md").open(mode="w") as fp:
        print("|file|sha256|size|", file=fp)
        print("|----|------|----|", file=fp)
        for file, (sha256, size) in sorted(hash_table.items()):
            print(f"|{file.name}|{sha256}|{size}|", file=fp)


def main() -> Any:
    parser = ArgumentParser()
    parser.add_argument("--pexcz", dest="include_pexcz", action="store_true", default=True)
    parser.add_argument("--no-pexcz", dest="include_pexcz", action="store_false")
    parser.add_argument("--dists", dest="include_python_dists", action="store_true", default=False)
    parser.add_argument("--no-dists", dest="include_python_dists", action="store_false")
    options = parser.parse_args()

    if options.include_pexcz:
        package_pexcz(PEXCZ_DIST_DIR)

    if options.include_python_dists:
        subprocess.run(
            args=["uv", "build"],
            env={
                **os.environ,
                "PEXCZ_BUILD_TARGETS": PEXCZ_BUILD_TARGETS,
                "PEXCZ_RELEASE_MODE": PEXCZ_RELEASE_MODE,
            },
            check=True,
        )


if __name__ == "__main__":
    sys.exit(main())
