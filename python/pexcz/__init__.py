# -*- coding: utf-8 -*-
from __future__ import print_function

import atexit
import ctypes
import functools
import gc
import os.path
import pkgutil
import platform
import shutil
import sys
import tempfile
import time
import warnings
from ctypes import cdll

TYPING = False

if TYPING:
    from typing import Callable, Optional, Protocol  # noqa
else:

    class Protocol(object):  # type: ignore[no-redef]
        pass


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
        multiplier,  # type: int
    ):
        # type: (...) -> None
        self._name = name
        self._multiplier = multiplier

    def elapsed(self, start):
        # type: (float) -> float
        return (time.time() - start) * self._multiplier

    def __str__(self):
        # type: () -> str
        return self._name


MS = TimeUnit("ms", 1_000)
US = TimeUnit("µs", 1_000_000)


def timed(unit):
    # type: (TimeUnit) -> Callable[[Callable], Callable]
    def wrapper(func):
        @functools.wraps(func)
        def wrapped(*args, **kwargs):
            start = time.time()
            try:
                return func(*args, **kwargs)
            finally:
                print(
                    f"{func.__name__}(*{args!r}, **{kwargs!r}) took {unit.elapsed(start):.4}{unit}",
                    file=sys.stderr,
                )

        return wrapped

    return wrapper


GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS = 0x00000004
MAX_UNLOAD_WAIT_SECS = 0.05


def _unload_dll(
    path,  # type: str
    dll,  # type: Optional[Pexcz]
):
    handle = None  # type: Optional[ctypes.wintypes.HMODULE]  # type: ignore[name-defined]
    if dll is not None:
        module_handle = ctypes.wintypes.HMODULE()  # type: ignore[attr-defined]
        if not ctypes.windll.kernel32.GetModuleHandleExW(  # type: ignore[attr-defined]
            GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS, dll.boot, ctypes.pointer(module_handle)
        ):
            warnings.warn(
                "Failed to clean up extracted dll resource at {path}: {err}".format(
                    path=path,
                    err=ctypes.WinError(),  # type: ignore[attr-defined]
                )
            )
        else:
            handle = module_handle
        del dll

    count = 0
    freed = False
    start = time.time()
    while os.path.exists(path):
        if handle is not None:
            if ctypes.windll.kernel32.FreeLibrary(handle):  # type: ignore[attr-defined]
                freed = True
            elif not freed:
                raise ctypes.WinError()  # type: ignore[attr-defined]
            else:
                gc.collect()
        shutil.rmtree(os.path.dirname(path), ignore_errors=True)
        if not handle:
            break
        elapsed = time.time() - start
        if elapsed > MAX_UNLOAD_WAIT_SECS:
            warnings.warn(
                "Failed to clean up extracted dll resource at {path} after {count} attempts "
                "spanning {elapsed:.2}s".format(path=path, count=count, elapsed=elapsed)
            )
            break
        count += 1


class Pexcz(Protocol):
    def boot(
        self,
        python_exe,  # type: bytes
        pex_file,  # type: bytes
    ):
        # type: (...) -> None
        pass


@timed(MS)
def _load_pexcz():
    # type: () -> Pexcz

    operating_system = OperatingSystem.current()
    arch = Arch.current()

    dll = None  # type: Optional[Pexcz]
    library_file_name = operating_system.library_file_name("pexcz")
    tmp_dir = tempfile.mkdtemp()
    library_file_path = os.path.join(tmp_dir, os.path.basename(library_file_name))
    try:
        platform_id = "{arch}-{os}".format(arch=arch, os=operating_system)
        try:
            # N.B.: This is the production resource.
            pexcz_data = pkgutil.get_data(
                __name__, os.path.join("lib", platform_id, library_file_name)
            )
        except FileNotFoundError:
            # And this is the development resource.
            pexcz_data = pkgutil.get_data(
                __name__, os.path.join("lib", "native", library_file_name)
            )
        if pexcz_data is None:
            raise RuntimeError(f"Pexcz is not supported on {platform}: no pexcz library found.")
        with open(library_file_path, "wb") as fp:
            fp.write(pexcz_data)
        pexcz = cdll.LoadLibrary(library_file_path)  # type: Pexcz
        dll = pexcz
        return pexcz
    finally:
        if operating_system is WINDOWS:
            # N.B.: Once the library is loaded on Windows, it can't be deleted without jumping
            # through extra hoops:
            # PermissionError: [WinError 5] Access is denied: 'C:...\\Temp\\tmpbyxvw46f\\pexcz.dll'
            atexit.register(_unload_dll, library_file_path, dll)
        else:

            def warn_extracted_lib_leak(err):
                warnings.warn(
                    "Failed to clean up extracted library resource at {path}: {err}".format(
                        path=library_file_path, err=err
                    )
                )

            if sys.version_info[:2] < (2, 12):

                def onerror(_func, _path, exec_info):
                    _, err, _ = exec_info
                    warn_extracted_lib_leak(err)

                shutil.rmtree(tmp_dir, ignore_errors=False, onerror=onerror)
            else:

                def onexc(_func, _path, err):
                    warn_extracted_lib_leak(err)

                shutil.rmtree(tmp_dir, ignore_errors=False, onexc=onexc)  # type: ignore[call-arg]


_pexcz = _load_pexcz()


@timed(MS)
def boot(pex):
    # type: (str) -> None

    python_exe = sys.executable.encode("utf-8") + b"\x00"
    pex_file = pex.encode("utf-8") + b"\x00"

    array_of_strings_type = ctypes.c_char_p * (len(os.environ) + 1)
    array_of_strings = array_of_strings_type()
    for index, (name, value) in enumerate(os.environ.items()):
        array_of_strings[index] = (
            "{name}={value}".format(name=name, value=value).encode("utf-8") + b"\x00"
        )
    array_of_strings[len(os.environ)] = None

    _pexcz.boot(
        python_exe, pex_file, ctypes.cast(array_of_strings, ctypes.POINTER(array_of_strings_type))
    )
