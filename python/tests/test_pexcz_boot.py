import subprocess
import sys
import time
from pathlib import Path

import pexcz


def test_boot(tmp_path: Path) -> None:
    pex = tmp_path / "cowsay.pex"
    subprocess.run(
        args=["pex", "cowsay", "-c", "cowsay", "-o", pex, "--venv", "prepend"], check=True
    )

    start = time.time()
    subprocess.run(args=[sys.executable, pex, "-t", "Moo!"], check=True)
    print(
        f"Traditional PEX run took {(time.time() - start) * 1_000:.5}ms",
        file=sys.stderr,
    )

    python_source_root = Path(pexcz.__file__).parent.parent

    start = time.time()
    subprocess.run(
        args=[sys.executable, "-c", f"import sys, pexcz; pexcz.boot('{pex}', args=['-t', 'Moo!'])"],
        check=True,
        cwd=python_source_root,
    )
    print(
        f"pexcz.boot import and run took {(time.time() - start) * 1_000:.3}ms",
        file=sys.stderr,
    )
