from __future__ import absolute_import

import setuptools.build_meta
import zig

# The following `setuptools.build_meta` imports are all public hook exports used by build frontends.
from setuptools.build_meta import (  # noqa: F401
    get_requires_for_build_editable as get_requires_for_build_editable,
)
from setuptools.build_meta import (  # noqa: F401
    get_requires_for_build_wheel as get_requires_for_build_wheel,
)
from setuptools.build_meta import (  # noqa: F401
    prepare_metadata_for_build_editable as prepare_metadata_for_build_editable,
)
from setuptools.build_meta import (  # noqa: F401
    prepare_metadata_for_build_wheel as prepare_metadata_for_build_wheel,
)

TYPE_CHECKING = False
if TYPE_CHECKING:
    # Ruff doesn't understand Python 2 and thus the type comment usages.
    from typing import List, Mapping, Optional, Union  # noqa: F401


if TYPE_CHECKING:
    ConfigSettings = Mapping[str, Union[str, List[str], None]]


def build_sdist(
    sdist_directory,  # type: str
    config_settings=None,  # type: Optional[ConfigSettings]
):
    # type: (...) -> str

    zig.clean_components()
    return setuptools.build_meta.build_sdist(sdist_directory, config_settings=config_settings)


def build_wheel(
    wheel_directory,  # type: str
    config_settings=None,  # type: Optional[ConfigSettings]
    metadata_directory=None,  # type: Optional[str]
):
    # type: (...) -> str

    zig.build_components()
    return setuptools.build_meta.build_wheel(
        wheel_directory, config_settings=config_settings, metadata_directory=metadata_directory
    )


def build_editable(
    wheel_directory,  # type: str
    config_settings=None,  # type: Optional[ConfigSettings]
    metadata_directory=None,  # type: Optional[str]
):
    # type: (...) -> str

    zig.build_components()
    return setuptools.build_meta.build_editable(
        wheel_directory, config_settings=config_settings, metadata_directory=metadata_directory
    )
