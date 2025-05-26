from __future__ import absolute_import, print_function

import os.path
import subprocess
import sys
import time

import pexcz

TYPE_CHECKING = False
if TYPE_CHECKING:
    # Ruff doesn't understand Python 2 and thus the type comment usages.
    from typing import Any  # noqa: F401


def test_boot(tmpdir):
    # type: (Any) -> None

    pex = os.path.join(str(tmpdir), "cowsay.pex")
    pex_root = os.path.join(str(tmpdir), "pex_root")
    subprocess.check_call(
        args=[
            "pex",
            "cowsay<6",
            # "requests", # medium size:
            # "ansible",  # ~6x faster cold, ~7x faster cold but just interpreter cache warm.
            "-c",
            "cowsay",
            "-o",
            pex,
            "--venv",
            "prepend",
            "--sh-boot",
            "--pex-root",
            pex_root,
            "--runtime-pex-root",
            pex_root,
        ]
    )  # small size:
    # ~12x faster cold, ~17x faster cold but just interpreter cache warm.

    # subprocess.check_call(
    #     args=[
    #         "pex",
    #         "torch",
    #         "-o",
    #         pex,
    #         "--venv",
    #         "prepend",
    #         "--sh-boot",
    #         "--venv-site-packages-copies -",
    #         "--runtime-pex-root",
    #         pex_root,
    #     ]
    # )  # large size:
    # # ~3.5x faster

    start = time.time()
    subprocess.check_call(args=[pex, "Moo!"])
    # subprocess.check_call(args=[pex, "-c", "import torch; print(torch.__file__)"])
    print(
        "Traditional PEX run took {elapsed:.5}ms".format(elapsed=(time.time() - start) * 1000),
        file=sys.stderr,
    )

    python_source_root = os.path.abspath(os.path.join(pexcz.__file__, "..", ".."))

    start = time.time()
    subprocess.check_call(
        args=[
            sys.executable,
            "-c",
            "import sys, pexcz; pexcz.boot(r'{pex}', args=['Moo!'])".format(pex=pex),
            # "import sys, pexcz; pexcz.boot(r'{pex}', args=['-c', 'import torch; print(torch.__file__)'])".format(
            #     pex=pex
            # ),
        ],
        cwd=python_source_root,
    )
    print(
        "pexcz.boot import and run took {elapsed:.5}ms".format(
            elapsed=(time.time() - start) * 1000
        ),
        file=sys.stderr,
    )
