from __future__ import absolute_import, print_function

import os.path
import subprocess
import sys
import time

import pexcz

TYPING = False
if TYPING:
    # Ruff doesn't understand Python 2 and thus the type comment usages.
    from typing import Any  # noqa: F401


def test_boot(tmpdir):
    # type: (Any) -> None

    pex = os.path.join(str(tmpdir), "cowsay.pex")
    subprocess.check_call(args=["pex", "cowsay", "-c", "cowsay", "-o", pex, "--venv", "prepend"])

    start = time.time()
    subprocess.check_call(args=[sys.executable, pex, "-t", "Moo!"])
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
            "import sys, pexcz; pexcz.boot(r'{pex}', args=['-t', 'Moo!'])".format(pex=pex),
        ],
        cwd=python_source_root,
    )
    print(
        "pexcz.boot import and run took {elapsed:.5}ms".format(
            elapsed=(time.time() - start) * 1000
        ),
        file=sys.stderr,
    )
