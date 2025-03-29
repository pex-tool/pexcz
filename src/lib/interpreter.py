import json
import os
import platform
import sys
import sysconfig
from contextlib import contextmanager

TYPING = False

if TYPING:
    from typing import Any, Dict, Iterator, Optional, TextIO, Tuple  # noqa: F401


def implementation_name_and_version():
    # type: () -> Tuple[str, str]
    if hasattr(sys, "implementation"):
        implementation_version_info = sys.implementation.version
        version = "{0.major}.{0.minor}.{0.micro}".format(implementation_version_info)
        kind = implementation_version_info.releaselevel
        if kind != "final":
            version += kind[0] + str(implementation_version_info.serial)
        return sys.implementation.name, version
    return "", "0"


def identify():
    # type: () -> Dict[str, Any]
    implementation_name, implementation_version = implementation_name_and_version()
    return {
        "path": sys.executable,
        "prefix": sys.prefix,
        "base_prefix": getattr(sys, "base_prefix", None),
        "version": {
            "major": sys.version_info.major,
            "minor": sys.version_info.minor,
            "micro": sys.version_info.micro,
            "releaselevel": sys.version_info.releaselevel,
            "serial": sys.version_info.serial,
        },
        # See: https://packaging.python.org/en/latest/specifications/dependency-specifiers/#environment-markers
        "marker_env": {
            "os_name": os.name,
            "sys_platform": sys.platform,
            "platform_machine": platform.machine(),
            "platform_python_implementation": platform.python_implementation(),
            "platform_release": platform.release(),
            "platform_system": platform.system(),
            "platform_version": platform.version(),
            "python_version": ".".join(platform.python_version_tuple()[:2]),
            "python_full_version": platform.python_version(),
            "implementation_name": implementation_name,
            "implementation_version": implementation_version,
        },
        "macos_framework_build": bool(sysconfig.get_config_vars().get("PYTHONFRAMEWORK")),
        "supported_tags": [],  # TODO: XXX: record supported tags.
    }


USAGE = """Usage: python <these bytes> [OUTPUT_PATH]?

If OUTPUT_PATH is not specified, stdout is used.
"""


def main():
    # type: () -> None
    @contextmanager
    def output(file_path=None):
        # type: (Optional[str]) -> Iterator[TextIO]
        if path is None:
            yield sys.stdout
        else:
            with open(file_path, "w") as fp:
                yield fp

    if len(sys.argv) > 2:
        sys.exit(USAGE)

    path = sys.argv[1] if len(sys.argv) == 2 else None
    with output(file_path=path) as out:
        json.dump(identify(), out)


if __name__ == "__main__":
    sys.exit(main())
