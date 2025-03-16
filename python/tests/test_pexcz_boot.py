import subprocess
import sys
import time
from pathlib import Path


def test_boot(tmp_path: Path) -> None:
    pex = tmp_path / "cowsay.pex"
    subprocess.run(
        args=["pex", "cowsay", "-c", "cowsay", "-o", pex, "--venv", "prepend"], check=True
    )

    start = time.perf_counter_ns()
    try:
        from pexcz import boot

        boot(str(pex))
    finally:
        print(
            f"pexcz.boot import and run took {(time.perf_counter_ns() - start) / 1_000_000.0:.3}ms",
            file=sys.stderr,
        )
