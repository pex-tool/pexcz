import os
import shlex
import shutil
import subprocess
import sys

TYPE_CHECKING = False
if TYPE_CHECKING:
    # Ruff doesn't understand Python 2 and thus the type comment usages.
    from typing import Any  # noqa: F401

PEXCZ_LIB_DIR = os.path.abspath(os.path.join("src", "python", "pexcz", "__pex__", ".lib"))


def clean_components():
    # type: () -> None

    shutil.rmtree(PEXCZ_LIB_DIR, ignore_errors=True)


def build_components():
    # type: () -> None

    zig = os.environ.get("PEXCZ_ZIG_BUILD")
    if zig:
        args = shlex.split(zig)
    else:
        args = [sys.executable, "-m", "ziglang", "build"]

    targets = os.environ.get("PEXCZ_BUILD_TARGETS", "Current")
    release_mode = os.environ.get("PEXCZ_RELEASE_MODE", "off")
    args.extend(
        (
            "--release={release_mode}".format(release_mode=release_mode),
            "--prefix-lib-dir",
            PEXCZ_LIB_DIR,
            "-Dtargets={targets}".format(targets=targets),
        )
    )
    subprocess.check_call(args)
