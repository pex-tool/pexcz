from __future__ import annotations

import os
import shutil
import subprocess
import sys
from os import PathLike
from pathlib import Path
from typing import Mapping, TypeAlias

import setuptools.build_meta
from setuptools.build_meta import *  # noqa

StrPath: TypeAlias = str | PathLike[str]
ConfigSettings: TypeAlias = Mapping[str, str | list[str] | None]

PEXCZ_PACKAGE_DIR = Path("python") / "pexcz"


def clean_zig_components() -> None:
    shutil.rmtree(PEXCZ_PACKAGE_DIR / "bin", ignore_errors=True)
    shutil.rmtree(PEXCZ_PACKAGE_DIR / "lib", ignore_errors=True)


def build_zig_components() -> None:
    targets = os.environ.get("PEXCZ_BUILD_TARGETS", "Current")
    release_mode = os.environ.get("PEXCZ_RELEASE_MODE", "off")
    subprocess.run(
        args=[
            sys.executable,
            "-m",
            "ziglang",
            "build",
            f"--release={release_mode}",
            "--prefix",
            PEXCZ_PACKAGE_DIR,
            f"-Dtargets={targets}",
        ],
        check=True,
    )


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
