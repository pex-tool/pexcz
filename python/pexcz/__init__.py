import atexit
import functools
import os.path
import pkgutil
import platform
import shutil
import sys
import tempfile
import time
from ctypes import cdll
from typing import Callable  # noqa


class OperatingSystem(object):
    @classmethod
    def current(cls):
        # type: () -> OperatingSystem

        operating_system = platform.system().lower()
        if operating_system == "linux":
            return LINUX
        elif operating_system == "darwin":
            return MACOS
        elif operating_system == "windows":
            return WINDOWS
        else:
            raise ValueError("Unsupported OS: {os}".format(os=operating_system))

    def __init__(
        self,
        name,  # type: str
        lib_extension,  # type: str
        lib_prefix="",  # type: str
    ):
        # type: (...) -> None
        self.name = name
        self._lib_prefix = lib_prefix
        self._lib_extension = lib_extension

    def library_file_name(self, lib_name):
        # type: (str) -> str
        return "{lib_prefix}{name}.{lib_extension}".format(
            lib_prefix=self._lib_prefix, name=lib_name, lib_extension=self._lib_extension
        )

    def __str__(self):
        # type: () -> str
        return self.name


LINUX = OperatingSystem("linux", lib_prefix="lib", lib_extension="so")
MACOS = OperatingSystem("macos", lib_prefix="lib", lib_extension="dylib")
WINDOWS = OperatingSystem("windows", lib_extension="dll")


class Arch(object):
    @classmethod
    def current(cls):
        # type: () -> Arch

        machine = platform.machine().lower()
        if machine in ("aarch64", "arm64"):
            return ARM64
        elif machine in ("armv7l", "armv8l"):
            return ARM32
        elif machine == "ppc64le":
            return PPC64LE
        elif machine in ("amd64", "x86_64"):
            return X86_64
        else:
            raise ValueError("Unsupported chip architecture: {arch}".format(arch=machine))

    def __init__(self, name):
        # type: (str) -> None
        self.name = name

    def __str__(self):
        # type: () -> str
        return self.name


ARM64 = Arch("aarch64")
ARM32 = Arch("arm")
PPC64LE = Arch("powerpc64le")
X86_64 = Arch("x86_64")


class TimeUnit(object):
    def __init__(
        self,
        name,  # type: str
        divisor,  # type: int
    ):
        # type: (...) -> None
        self._name = name
        self._divisor = divisor * 1.0

    def elapsed(self, start):
        # type: (int) -> float
        return (time.perf_counter_ns() - start) / self._divisor

    def __str__(self):
        # type: () -> str
        return self._name


MS = TimeUnit("ms", 1_000_000)
US = TimeUnit("µs", 1_000)


def timed(unit):
    # type: (TimeUnit) -> Callable[[Callable], Callable]
    def wrapper(func):
        @functools.wraps(func)
        def wrapped(*args, **kwargs):
            start = time.perf_counter_ns()
            try:
                return func(*args, **kwargs)
            finally:
                print(
                    f"{func.__name__}(*{args!r}, **{kwargs!r}) took {unit.elapsed(start):.4}{unit}",
                    file=sys.stderr,
                )

        return wrapped

    return wrapper


@timed(MS)
def _load_pexcz():
    operating_system = OperatingSystem.current()
    arch = Arch.current()
    # TODO(John Sirois): Potentially introduce cache.
    tmd_dir = tempfile.mkdtemp()
    try:
        library_file_name = operating_system.library_file_name("pexcz")
        platform_id = "{arch}-{os}".format(arch=arch, os=operating_system)
        try:
            # N.B.: This is the production resource.
            pexcz = pkgutil.get_data(__name__, os.path.join("lib", platform_id, library_file_name))
        except FileNotFoundError:
            # And this is the development resource.
            pexcz = pkgutil.get_data(__name__, os.path.join("lib", "native", library_file_name))
        if pexcz is None:
            raise RuntimeError(f"Pexcz is not supported on {platform}: no pexcz library found.")
        with open(os.path.join(tmd_dir, os.path.basename(library_file_name)), "wb") as fp:
            fp.write(pexcz)
        return cdll.LoadLibrary(fp.name)
    finally:
        if WINDOWS:
            # N.B.: Once the library is loaded on Windows, it can't be deleted:
            # PermissionError: [WinError 5] Access is denied: 'C:...\\Temp\\tmpbyxvw46f\\pexcz.dll'
            atexit.register(shutil.rmtree, tmd_dir)
        else:
            shutil.rmtree(tmd_dir)


_pexcz = _load_pexcz()


@timed(MS)
def boot(pex):
    # type: (str) -> None

    python_exe = sys.executable.encode("utf-8") + b"\x00"
    pex_file = pex.encode("utf-8") + b"\x00"
    _pexcz.boot(python_exe, pex_file)
