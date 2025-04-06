from __future__ import absolute_import

import setuptools.build_meta
import zig
from setuptools.build_meta import *  # noqa: F403

TYPING = False
if TYPING:
    # Ruff doesn't understand Python 2 and thus the type comment usages.
    from typing import List, Mapping, Optional, Union  # noqa: F401

    from typing_extensions import Protocol  # noqa: F401
else:

    class Protocol(object):
        pass


class PathLike(Protocol):
    def __fspath__(self):
        # type: () -> str
        pass


if TYPING:
    StrPath = Union[str, PathLike]
    ConfigSettings = Mapping[str, Union[str, List[str], None]]


def build_sdist(
    sdist_directory,  # type: StrPath,
    config_settings=None,  # type: Optional[ConfigSettings]
):
    # type: (...) -> str

    zig.clean_components()
    return setuptools.build_meta.build_sdist(sdist_directory, config_settings=config_settings)


def build_wheel(
    wheel_directory,  # type: StrPath,
    config_settings=None,  # type: Optional[ConfigSettings]
    metadata_directory=None,  # type: Optional[StrPath]
):
    # type: (...) -> str

    zig.build_components()
    return setuptools.build_meta.build_wheel(
        wheel_directory, config_settings=config_settings, metadata_directory=metadata_directory
    )


def build_editable(
    wheel_directory,  # type: StrPath,
    config_settings=None,  # type: Optional[ConfigSettings]
    metadata_directory=None,  # type: Optional[StrPath]
):
    # type: (...) -> str

    zig.build_components()
    return setuptools.build_meta.build_editable(
        wheel_directory, config_settings=config_settings, metadata_directory=metadata_directory
    )
