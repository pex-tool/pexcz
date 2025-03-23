import subprocess
import sys
import time
from pathlib import Path


def test_boot(tmp_path: Path) -> None:
    pex = tmp_path / "cowsay.pex"
    subprocess.run(
        args=["pex", "cowsay", "-c", "cowsay", "-o", pex, "--venv", "prepend"], check=True
    )

    start = time.time()
    try:
        from pexcz import boot

        boot(str(pex))
    except SystemExit as e:
        assert e.code == 0, f"Unexpected boot failure: {e}"
    finally:
        print(
            f"pexcz.boot import and run took {(time.time() - start) * 1_000:.3}ms",
            file=sys.stderr,
        )
