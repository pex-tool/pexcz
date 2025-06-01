import os
import platform
import shlex
import shutil
import subprocess
import sys

TYPE_CHECKING = False
if TYPE_CHECKING:
    # Ruff doesn't understand Python 2 and thus the type comment usages.
    from typing import Any  # noqa: F401

PEXCZ_LIB_DIR = os.path.abspath(os.path.join("src", "python", "pexcz", ".lib"))

IS_WINDOWS = platform.system() == "Windows"


class ZigNotFoundError(Exception):
    pass


def find_zig():
    # type: () -> str

    # TODO(John Sirois): Confirm version vs build.zig.zon.
    zig_exe = "zig.exe" if IS_WINDOWS else "zig"
    path = os.environ.get("PATH", os.defpath).split(os.pathsep)
    for entry in path:
        zig_candidate = os.path.join(entry, zig_exe)
        if IS_WINDOWS and os.path.isfile(zig_candidate):
            return zig_candidate
        elif os.access(zig_candidate, os.R_OK | os.X_OK):
            return zig_candidate
    raise ZigNotFoundError(
        "Could not find an {zig_exe} on PATH with entries:\n".format(
            zig_exe=zig_exe,
        )
    )


def clean_components():
    # type: () -> None

    shutil.rmtree(PEXCZ_LIB_DIR, ignore_errors=True)


def build_components():
    # type: () -> None

    zig = os.environ.get("PEXCZ_ZIG_BUILD")
    if zig:
        args = shlex.split(zig)
    else:
        args = ["zig", "build"]

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


def main():
    # type: () -> Any

    try:
        zig_exe = find_zig()
    except ZigNotFoundError as e:
        return str(e)

    args = [zig_exe] + sys.argv[1:]
    if IS_WINDOWS:
        return subprocess.call(args)
    else:
        os.execv(args[0], args)


if __name__ == "__main__":
    sys.exit(main())
