from __future__ import absolute_import, print_function

import os
import sys

import zig

TYPING = False
if TYPING:
    # Ruff doesn't understand Python 2 and thus the type comment usages.
    from typing import Any  # noqa: F401


def main():
    # type: () -> Any

    if len(sys.argv) != 2:
        return "Usage: {prog} [SITE_PACKAGES_PATH]".format(prog=sys.argv[0])

    site_packages = sys.argv[1]
    zig.build_components()

    with open(os.path.join(site_packages, "__editable__.pexcz.pth"), "w") as fp:
        print(os.path.abspath(os.path.join("python")), file=fp)


if __name__ == "__main__":
    sys.exit(main())
