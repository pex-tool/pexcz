import collections
import json
import os
import platform
import re
import sys
import sysconfig
from argparse import ArgumentParser
from contextlib import contextmanager

TYPING = False
if TYPING:
    # Ruff doesn't understand Python 2 and thus the type comment usages.
    from typing import (  # noqa: F401
        Any,
        Dict,
        Iterable,
        Iterator,
        List,
        Optional,
        Sequence,
        TextIO,
        Tuple,
        Union,
    )


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


def identify(supported_tags):
    # type: (Iterable[Tuple[str, str, str]]) -> Dict[str, Any]

    implementation_name, implementation_version = implementation_name_and_version()
    return {
        "path": sys.executable,
        "realpath": os.path.realpath(sys.executable),
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
        "supported_tags": ["-".join(tag) for tag in supported_tags],
    }


def iter_generic_platform_tags():
    # type: () -> Iterator[str]

    return iter(())


def iter_macos_platform_tags():
    # type: () -> Iterator[str]

    return iter(())


def current_arch():
    # type: () -> str

    plat = sysconfig.get_platform()
    return re.sub(r"[.-]", "_", plat.split("-", 1)[-1])


def glibc_version_string_confstr():
    # type: () -> Optional[str]
    """
    Primary implementation of glibc_version_string using os.confstr.
    """
    # os.confstr is quite a bit faster than ctypes.DLL. It's also less likely
    # to be broken or missing. This strategy is used in the standard library
    # platform module.
    # https://github.com/python/cpython/blob/fcf1d003bf4f0100c/Lib/platform.py#L175-L183
    try:
        # Should be a string like "glibc 2.17".
        version_string = os.confstr("CS_GNU_LIBC_VERSION")
        assert version_string is not None
        _, version = version_string.rsplit()
    except (AssertionError, AttributeError, OSError, ValueError):
        # os.confstr() or CS_GNU_LIBC_VERSION not available (or a bad value)...
        return None
    return version


def glibc_version_string_ctypes():
    # type: () -> Optional[str]
    """
    Fallback implementation of glibc_version_string using ctypes.
    """
    try:
        import ctypes
    except ImportError:
        return None

    # ctypes.CDLL(None) internally calls dlopen(NULL), and as the dlopen
    # manpage says, "If filename is NULL, then the returned handle is for the
    # main program". This way we can let the linker do the work to figure out
    # which libc our process is actually using.
    #
    # We must also handle the special case where the executable is not a
    # dynamically linked executable. This can occur when using musl libc,
    # for example. In this situation, dlopen() will error, leading to an
    # OSError. Interestingly, at least in the case of musl, there is no
    # errno set on the OSError. The single string argument used to construct
    # OSError comes from libc itself and is therefore not portable to
    # hard code here. In any case, failure to call dlopen() means we
    # can proceed, so we bail on our attempt.
    try:
        process_namespace = ctypes.CDLL(None)
    except OSError:
        return None

    try:
        gnu_get_libc_version = process_namespace.gnu_get_libc_version
    except AttributeError:
        # Symbol doesn't exist -> therefore, we are not linked to
        # glibc.
        return None

    # Call gnu_get_libc_version, which returns a string like "2.5"
    gnu_get_libc_version.restype = ctypes.c_char_p
    version_str = gnu_get_libc_version()
    # py2 / py3 compatibility:
    if not isinstance(version_str, str):
        version_str = version_str.decode("ascii")

    return version_str


def glibc_version_string():
    # type: () -> Optional[str]
    """Returns glibc version string, or None if not using glibc."""
    return glibc_version_string_confstr() or glibc_version_string_ctypes()


def parse_glibc_version(version_str):
    # type: (str) -> Tuple[int, int]
    """Parse glibc version.

    We use a regexp instead of str.split because we want to discard any
    random junk that might come after the minor version -- this might happen
    in patched/forked versions of glibc (e.g. Linaro's version of glibc
    uses version strings like "2.20-2014.11"). See gh-3588.
    """
    m = re.match(r"(?P<major>[0-9]+)\.(?P<minor>[0-9]+)", version_str)
    if not m:
        return -1, -1
    return int(m.group("major")), int(m.group("minor"))


def get_glibc_version():
    # type: () -> Tuple[int, int]

    version_str = glibc_version_string()
    if version_str is None:
        return -1, -1
    return parse_glibc_version(version_str)


# If glibc ever changes its major version, we need to know what the last
# minor version was, so we can build the complete list of all versions.
# For now, guess what the highest minor version might be, assume it will
# be 50 for testing. Once this actually happens, update the dictionary
# with the actual value.
_LAST_GLIBC_MINOR = collections.defaultdict(lambda: 50)


# From PEP 513, PEP 600
def is_glibc_version_compatible(
    arch,  # type: str
    sys_glibc,  # type: Tuple[int, int]
    version,  # type: Tuple[int, int]
):
    # type: (...) -> bool

    if sys_glibc < version:
        return False
    # Check for presence of _manylinux module.
    try:
        import _manylinux
    except ImportError:
        return True
    if hasattr(_manylinux, "manylinux_compatible"):
        result = _manylinux.manylinux_compatible(version[0], version[1], arch)
        if result is not None:
            return bool(result)
        return True
    if version == (2, 5):
        if hasattr(_manylinux, "manylinux1_compatible"):
            return bool(_manylinux.manylinux1_compatible)
    if version == (2, 12):
        if hasattr(_manylinux, "manylinux2010_compatible"):
            return bool(_manylinux.manylinux2010_compatible)
    if version == (2, 17):
        if hasattr(_manylinux, "manylinux2014_compatible"):
            return bool(_manylinux.manylinux2014_compatible)
    return True


_LEGACY_MANYLINUX_MAP = {
    # CentOS 7 w/ glibc 2.17 (PEP 599)
    (2, 17): "manylinux2014",
    # CentOS 6 w/ glibc 2.12 (PEP 571)
    (2, 12): "manylinux2010",
    # CentOS 5 w/ glibc 2.5 (PEP 513)
    (2, 5): "manylinux1",
}

_MAJOR = 0
_MINOR = 1


def iter_manylinux_platform_tags(
    current_glibc,  # type: Tuple[int, int]
    armhf,  # type: bool
    i686,  # type: bool
):
    # type: (...) -> Iterator[str]

    arch = current_arch()

    if armhf and arch != "armv7l":
        return

    if i686 and arch != "i686":
        return

    if arch not in (
        "aarch64",
        "armv7li686",
        "loongarch64",
        "ppc64",
        "ppc64le",
        "riscv64",
        "s390x",
        "x86_64",
    ):
        return

    # Oldest glibc to be supported regardless of architecture is (2, 17).
    # On x86/i686 also oldest glibc to be supported is (2, 5).
    too_old_glibc2 = 2, 4 if arch in ("x86_64", "i686") else 16

    glibc_max_list = [current_glibc]
    # We can assume compatibility across glibc major versions.
    # https://sourceware.org/bugzilla/show_bug.cgi?id=24636
    #
    # Build a list of maximum glibc versions so that we can
    # output the canonical list of all glibc from current_glibc
    # down to too_old_glibc2, including all intermediary versions.
    for glibc_major in range(current_glibc[_MAJOR] - 1, 1, -1):
        glibc_minor = _LAST_GLIBC_MINOR[glibc_major]
        glibc_max_list.append((glibc_major, glibc_minor))
    for glibc_max in glibc_max_list:
        if glibc_max[_MAJOR] == too_old_glibc2[_MAJOR]:
            min_minor = too_old_glibc2[_MINOR]
        else:
            # For other glibc major versions the oldest supported is (x, 0).
            min_minor = -1
        for glibc_minor in range(glibc_max[_MINOR], min_minor, -1):
            glibc_version = (glibc_max[_MAJOR], glibc_minor)
            tag = "manylinux_{}_{}".format(*glibc_version)
            if is_glibc_version_compatible(arch, current_glibc, glibc_version):
                yield "{tag}_{arch}".format(tag=tag, arch=arch)
            # Handle the legacy manylinux1, manylinux2010, manylinux2014 tags.
            if glibc_version in _LEGACY_MANYLINUX_MAP:
                legacy_tag = _LEGACY_MANYLINUX_MAP[glibc_version]
                if is_glibc_version_compatible(arch, current_glibc, glibc_version):
                    yield "{legacy_tag}_{arch}".format(legacy_tag=legacy_tag, arch=arch)


def iter_musllinux_platform_tags(version):
    # type: (Tuple[int, int]) -> Iterator[str]

    major, minor = version
    arch = current_arch()
    for minor in range(minor, -1, -1):
        yield "musllinux_{major}_{minor}_{arch}".format(major=major, minor=minor, arch=arch)


INTERPRETER_SHORT_NAMES = {
    "python": "py",  # Generic.
    "cpython": "cp",
    "pypy": "pp",
    "ironpython": "ip",
    "jython": "jy",
}


def get_config_var(name):
    # type: (str) -> Optional[Union[int, str]]

    return sysconfig.get_config_vars().get(name)


def interpreter_version():
    # type: () -> str
    """
    Returns the version of the running interpreter.
    """
    version = get_config_var("py_version_nodot")
    if version:
        version = str(version)
    else:
        version = version_nodot(sys.version_info[:2])
    return version


def normalize_string(string):
    # type: (str) -> str

    return string.replace(".", "_").replace("-", "_").replace(" ", "_")


def cpython_abis(py_version):
    # type: (Sequence[int]) -> List[str]

    # TODO: XXX: Not available in older Pythons.
    from importlib.machinery import EXTENSION_SUFFIXES

    py_version = tuple(py_version)  # To allow for version comparison.
    abis = []
    version = version_nodot(py_version[:2])
    threading = debug = pymalloc = ucs4 = ""
    with_debug = get_config_var("Py_DEBUG")
    has_refcount = hasattr(sys, "gettotalrefcount")
    # Windows doesn't set Py_DEBUG, so checking for support of debug-compiled
    # extension modules is the best option.
    # https://github.com/pypa/pip/issues/3383#issuecomment-173267692
    has_ext = "_d.pyd" in EXTENSION_SUFFIXES
    if with_debug or (with_debug is None and (has_refcount or has_ext)):
        debug = "d"
    if py_version >= (3, 13) and get_config_var("Py_GIL_DISABLED"):
        threading = "t"
    if py_version < (3, 8):
        with_pymalloc = get_config_var("WITH_PYMALLOC")
        if with_pymalloc or with_pymalloc is None:
            pymalloc = "m"
        if py_version < (3, 3):
            unicode_size = get_config_var("Py_UNICODE_SIZE")
            if unicode_size == 4 or (unicode_size is None and sys.maxunicode == 0x10FFFF):
                ucs4 = "u"
    elif debug:
        # Debug builds can also load "normal" extension modules.
        # We can also assume no UCS-4 or pymalloc requirement.
        abis.append("cp{version}{threading}".format(version=version, threading=threading))
    abis.insert(
        0,
        "cp{version}{threading}{debug}{pymalloc}{ucs4}".format(
            version=version, threading=threading, debug=debug, pymalloc=pymalloc, ucs4=ucs4
        ),
    )
    return abis


def generic_abi():
    # type: () -> List[str]
    """
    Return the ABI tag based on EXT_SUFFIX.
    """
    # The following are examples of `EXT_SUFFIX`.
    # We want to keep the parts which are related to the ABI and remove the
    # parts which are related to the platform:
    # - linux:   '.cpython-310-x86_64-linux-gnu.so' => cp310
    # - mac:     '.cpython-310-darwin.so'           => cp310
    # - win:     '.cp310-win_amd64.pyd'             => cp310
    # - win:     '.pyd'                             => cp37 (uses cpython_abis())
    # - pypy:    '.pypy38-pp73-x86_64-linux-gnu.so' => pypy38_pp73
    # - graalpy: '.graalpy-38-native-x86_64-darwin.dylib'
    #                                               => graalpy_38_native

    ext_suffix = get_config_var("EXT_SUFFIX") or get_config_var("SO")
    if not isinstance(ext_suffix, str) or ext_suffix[0] != ".":
        raise SystemError("invalid sysconfig.get_config_var('EXT_SUFFIX')")
    parts = ext_suffix.split(".")
    if len(parts) < 3:
        # CPython3.7 and earlier uses ".pyd" on Windows.
        return cpython_abis(sys.version_info[:2])
    soabi = parts[1]
    if soabi.startswith("cpython"):
        # non-windows
        abi = "cp" + soabi.split("-")[1]
    elif soabi.startswith("cp"):
        # windows
        abi = soabi.split("-")[0]
    elif soabi.startswith("pypy"):
        abi = "-".join(soabi.split("-")[:2])
    elif soabi.startswith("graalpy"):
        abi = "-".join(soabi.split("-")[:3])
    elif soabi:
        # pyston, ironpython, others?
        abi = soabi
    else:
        return []
    return [normalize_string(abi)]


def interpreter_name():
    # type: () -> str
    """
    Returns the name of the running interpreter.

    Some implementations have a reserved, two-letter abbreviation which will
    be returned when appropriate.
    """
    return INTERPRETER_SHORT_NAMES.get(
        sys.implementation.name
        if hasattr(sys, "implementation")
        else platform.python_implementation().lower()
    )


def cpython_tags(platforms):
    # type: (Iterable[str]) -> Iterator[Tuple[str, str, str]]

    return iter(())


def generic_tags(platforms):
    # type: (Iterable[str]) -> Iterator[Tuple[str, str, str]]
    """
    Yields the tags for a generic interpreter.

    The tags consist of:
    - <interpreter>-<abi>-<platform>

    The "none" ABI will be added if it was not explicitly provided.
    """

    interp_name = interpreter_name()
    interp_version = interpreter_version()
    interpreter = "".join([interp_name, interp_version])

    abis = generic_abi()
    if "none" not in abis:
        abis.append("none")

    for abi in abis:
        for platform_ in platforms:
            yield interpreter, abi, platform_


def version_nodot(version):
    # type: (Sequence[int]) -> str

    return "".join(map(str, version))


def py_interpreter_range(py_version):
    # type: (Sequence[int]) -> Iterator[str]
    """
    Yields Python versions in descending order.

    After the latest version, the major-only version will be yielded, and then
    all previous versions of that major version.
    """
    if len(py_version) > 1:
        yield "py{major_minor}".format(major_minor=version_nodot(py_version[:2]))
    yield "py{major}".format(major=py_version[0])
    if len(py_version) > 1:
        for minor in range(py_version[1] - 1, -1, -1):
            yield "py{major_minor}".format(major_minor=version_nodot((py_version[0], minor)))


def compatible_tags(
    platforms,  # type: Iterable[str]
    interpreter=None,  # type: Optional[str]
):
    # type: (...) -> Iterator[Tuple[str, str, str]]
    """
    Yields the sequence of tags that are compatible with a specific version of Python.

    The tags consist of:
    - py*-none-<platform>
    - <interpreter>-none-any  # ... if `interpreter` is provided.
    - py*-none-any
    """
    python_version = sys.version_info[:2]
    for version in py_interpreter_range(python_version):
        for platform_ in platforms:
            yield version, "none", platform_
    if interpreter:
        yield interpreter, "none", "any"
    for version in py_interpreter_range(python_version):
        yield version, "none", "any"


def iter_supported_tags(platforms):
    # type: (Tuple[str, ...]) -> Iterator[Tuple[str, str, str]]

    interp_name = interpreter_name()
    if interp_name == "cp":
        for tag in cpython_tags(platforms):
            yield tag
    else:
        for tag in generic_tags(platforms):
            yield tag

    if interp_name == "pp":
        interp = "pp3"
    elif interp_name == "cp":
        interp = "cp" + interpreter_version()
    else:
        interp = None
    for tag in compatible_tags(platforms, interpreter=interp):
        yield tag


OS = platform.system().lower()
IS_LINUX = OS == "linux"
IS_MAC = not IS_LINUX and OS == "darwin"


def main():
    # type: () -> None

    parser = ArgumentParser(prog="interpreter.py")
    parser.add_argument("output_path", nargs="?", default=None)
    if IS_LINUX:
        parser.add_argument("--linux-info", metavar="JSON", required=True)
    options = parser.parse_args()

    @contextmanager
    def output(file_path=None):
        # type: (Optional[str]) -> Iterator[TextIO]
        if path is None:
            yield sys.stdout
        else:
            with open(file_path, "w") as fp:
                yield fp

    path = options.output_path  # type: Optional[str]
    iter_supported_platform_tags = (
        iter_macos_platform_tags if IS_MAC else iter_generic_platform_tags
    )
    if IS_LINUX:
        linux_info = json.loads(options.linux_info)
        manylinux = linux_info.get("manylinux")
        if manylinux:
            glibc = manylinux["glibc"]
            glibc_version = (
                (int(glibc["major"]), int(glibc["minor"])) if glibc else get_glibc_version()
            )
            armhf = bool(manylinux["armhf"])
            i686 = bool(manylinux["i686"])
            iter_supported_platform_tags = lambda: iter_manylinux_platform_tags(  # noqa: E731
                current_glibc=glibc_version, armhf=armhf, i686=i686
            )
        else:
            musllinux = linux_info["musllinux"]
            musl_version = int(musllinux["major"]), int(musllinux["minor"])
            iter_supported_platform_tags = lambda: iter_musllinux_platform_tags(musl_version)  # noqa: E731

    with output(file_path=path) as out:
        json.dump(identify(list(iter_supported_tags(tuple(iter_supported_platform_tags())))), out)


if __name__ == "__main__":
    sys.exit(main())
