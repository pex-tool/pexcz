from __future__ import annotations

import os
import shlex
import shutil
import subprocess
import sys
from pathlib import Path
from typing import List, Mapping, Union

import setuptools.build_meta
from setuptools.build_meta import *  # noqa
from typing_extensions import Protocol, TypeAlias


class PathLike(Protocol):
    def __fspath__(self) -> str:
        pass


StrPath: TypeAlias = Union[str, PathLike]
ConfigSettings: TypeAlias = Mapping[str, Union[str, List[str], None]]

PEXCZ_PACKAGE_DIR = Path("python") / "pexcz"


def clean_zig_components() -> None:
    shutil.rmtree(PEXCZ_PACKAGE_DIR / "bin", ignore_errors=True)
    shutil.rmtree(PEXCZ_PACKAGE_DIR / "lib", ignore_errors=True)


def build_zig_components() -> None:
    zig = os.environ.get("PEXCZ_ZIG_BUILD")
    if zig:
        args = shlex.split(zig)
    else:
        args = [sys.executable, "-m", "ziglang", "build"]

    targets = os.environ.get("PEXCZ_BUILD_TARGETS", "Current")
    release_mode = os.environ.get("PEXCZ_RELEASE_MODE", "off")
    args.extend(
        (
            f"--release={release_mode}",
            "--prefix",
            PEXCZ_PACKAGE_DIR,
            f"-Dtargets={targets}",
        )
    )
    subprocess.run(args, check=True)


def build_sdist(sdist_directory: StrPath, config_settings: ConfigSettings | None = None) -> str:
    clean_zig_components()
    return setuptools.build_meta.build_sdist(sdist_directory, config_settings=config_settings)


def build_wheel(
    wheel_directory: StrPath,
    config_settings: ConfigSettings | None = None,
    metadata_directory: StrPath | None = None,
) -> str:
    build_zig_components()
    return setuptools.build_meta.build_wheel(
        wheel_directory, config_settings=config_settings, metadata_directory=metadata_directory
    )


def build_editable(
    wheel_directory: StrPath,
    config_settings: ConfigSettings | None = None,
    metadata_directory: StrPath | None = None,
) -> str:
    build_zig_components()
    return setuptools.build_meta.build_editable(
        wheel_directory, config_settings=config_settings, metadata_directory=metadata_directory
    )
