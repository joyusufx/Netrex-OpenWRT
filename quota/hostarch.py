"""Host architecture and platform facts for the portable install paths.

OpenWrt routers are MIPS/MIPSel/ARM machines with musl libc, no systemd and
no compiler. The parts of the gateway that must behave differently there —
which release asset to download, whether a bundled binary can run at all,
which init system to talk to — read the answers from this module instead of
assuming a Debian/Kali host.
"""

from __future__ import annotations

import os
import platform
import shutil
import struct
import subprocess
from functools import lru_cache
from pathlib import Path

#: OpenWrt marks every install with this file; ``/etc/rc.common`` is the
#: procd/rc.common base and is present on the same systems.
_OPENWRT_RELEASE = Path("/etc/openwrt_release")
_RC_COMMON = Path("/etc/rc.common")

_MACHINE_ALIASES = {
    "amd64": "x86_64",
    "x64": "x86_64",
    "arm64": "aarch64",
    "armv8l": "aarch64",
    "armv7l": "armv7",
    "armv6l": "armv6",
    "mips64el": "mips64le",
}

#: 32-bit OpenWrt targets without an FPU. A soft-float build runs on every
#: MIPS o32 system, so anything unknown is treated as soft-float.
_MIPS_HARD_FLOAT_ARCH = ("24kc", "24kec", "74kc", "1004kc", "octeon", "mips64r2")


def normalize_machine(machine: str | None = None) -> str:
    """Return the CPU name in the spelling this project uses everywhere."""
    raw = (machine if machine is not None else platform.machine()).strip().lower()
    return _MACHINE_ALIASES.get(raw, raw)


@lru_cache(maxsize=1)
def is_openwrt() -> bool:
    """True when the gateway runs on an OpenWrt router (opkg or apk)."""
    override = os.environ.get("QUOTA_PLATFORM", "").strip().lower()
    if override:
        return override == "openwrt"
    return _OPENWRT_RELEASE.is_file() or (_RC_COMMON.is_file() and shutil.which("ubus") is not None)


def openwrt_release() -> dict[str, str]:
    """Read ``/etc/openwrt_release`` into a dict (empty when not OpenWrt)."""
    data: dict[str, str] = {}
    try:
        for line in _OPENWRT_RELEASE.read_text(encoding="utf-8").splitlines():
            key, sep, value = line.partition("=")
            if sep:
                data[key.strip()] = value.strip().strip("'\"")
    except OSError:
        pass
    return data


def apk_based() -> bool:
    """OpenWrt 25.12+ uses apk; older releases use opkg."""
    return is_openwrt() and shutil.which("apk") is not None and shutil.which("opkg") is None


def openwrt_arch() -> str:
    """The router's package architecture (``mipsel_24kc``, ``x86_64``, …).

    ``opkg print-architecture`` lists every architecture the router accepts
    (``arch all 1``, ``arch noarch 1``, ``arch mipsel_24kc 10``…) and the
    concrete one is the highest-priority line; ``apk --print-arch`` prints a
    single name. Empty when neither tool answers.
    """
    try:
        out = subprocess.run(["opkg", "print-architecture"], capture_output=True,
                             text=True, timeout=5).stdout
    except (OSError, subprocess.TimeoutExpired):
        out = ""
    best_name, best_priority = "", -1
    for line in out.splitlines():
        parts = line.split()
        if len(parts) >= 2 and parts[0] == "arch":
            name = parts[1]
            if name in ("all", "noarch", "src", "*"):
                continue
            try:
                priority = int(parts[2]) if len(parts) > 2 else 0
            except ValueError:
                priority = 0
            if priority > best_priority:
                best_name, best_priority = name, priority
    if best_name:
        return best_name
    try:
        out = subprocess.run(["apk", "--print-arch"], capture_output=True,
                             text=True, timeout=5).stdout
    except (OSError, subprocess.TimeoutExpired):
        return ""
    return out.strip().splitlines()[0] if out.strip() else ""


@lru_cache(maxsize=1)
def mips_float_abi() -> str:
    """``hard``/``soft`` float ABI on MIPS, empty on other CPUs.

    OpenWrt encodes the FPU in its package architecture (``mipsel_24kc`` has
    one, ``mipsel_mips32`` does not); when that is not conclusive the CPU
    flags in ``/proc/cpuinfo`` decide, and soft-float is the safe default
    because such a binary also runs on hard-float systems.
    """
    if not normalize_machine().startswith("mips"):
        return ""
    arch = openwrt_arch().lower()
    if arch:
        if arch.endswith("mips32") or "_4kec" in arch:
            return "soft"
        if any(tag in arch for tag in _MIPS_HARD_FLOAT_ARCH):
            return "hard"
    try:
        cpuinfo = Path("/proc/cpuinfo").read_text(encoding="utf-8", errors="ignore")
    except OSError:
        return "soft"
    return "hard" if "fpu" in cpuinfo.lower() else "soft"


#: ELF e_machine values this project ships/runs binaries for.
_ELF_TYPES = {3: "x86", 8: "mips", 20: "ppc", 21: "ppc64", 22: "s390",
              40: "arm", 43: "sparc", 62: "x86_64", 183: "aarch64", 243: "riscv"}


def elf_identity(path: str | os.PathLike[str]) -> tuple[int, str, str] | None:
    """Return ``(bits, endianness, cpu)`` for an ELF file, None otherwise."""
    try:
        with open(path, "rb") as fh:
            header = fh.read(20)
    except OSError:
        return None
    if len(header) < 20 or header[:4] != b"\x7fELF":
        return None
    bits = 64 if header[4] == 2 else 32
    endian = "little" if header[5] == 1 else "big"
    machine = struct.unpack("<H" if endian == "little" else ">H", header[18:20])[0]
    return bits, endian, _ELF_TYPES.get(machine, f"machine-{machine}")


def _host_identity() -> tuple[int, str, str]:
    machine = normalize_machine()
    cpu = {"mipsel": "mips", "mips64le": "mips", "mips64": "mips",
           "x86_64": "x86_64", "aarch64": "aarch64", "armv7": "arm",
           "armv6": "arm", "riscv64": "riscv"}.get(machine, machine)
    # struct.calcsize instead of platform.architecture(): the latter shells out
    # to `file`, which busybox does not provide (and costs a fork per call).
    return (struct.calcsize("P") * 8,
            "little" if machine not in ("mips", "mips64") else "big",
            cpu)


def binary_runs_here(path: str | os.PathLike[str]) -> bool:
    """Can the current CPU execute ``path``?

    Scripts are assumed runnable, ELF files must match the host class,
    endianness and CPU (the failure this prevents is exec of the bundled
    x86-64 sing-box on a MIPS router, which reports ENOEXEC much later).
    """
    try:
        with open(path, "rb") as fh:
            head = fh.read(4)
    except OSError:
        return False
    if head[:2] == b"#!":
        return True
    if head[:2] == b"MZ":
        return os.name == "nt"
    if head[:4] != b"\x7fELF":
        return True
    return elf_identity(path) == _host_identity()


#: tun2socks release asset suffix (the tag is pinned in quota/tun2socks.py).
def tun2socks_asset(machine: str | None = None, abi: str | None = None) -> str:
    """Release asset suffix for ``machine`` (empty when no build exists).

    ``abi`` ("hard"/"soft") is only meaningful on MIPS and defaults to the
    host's own ABI, so passing a machine name in tests still yields the
    soft-float build unless the caller says otherwise.
    """
    machine = normalize_machine(machine)
    if machine == "mips":
        return f"linux-mips-{abi or mips_float_abi() or 'soft'}float"
    if machine == "mipsel":
        return f"linux-mipsle-{abi or mips_float_abi() or 'soft'}float"
    if machine == "mips64":
        return "linux-mips64"
    if machine == "mips64le":
        return "linux-mips64le"
    return _TUN2SOCKS_PLAIN.get(machine, "")


#: non-MIPS machines tun2socks publishes a linux build for (v2.7.0 assets).
_TUN2SOCKS_PLAIN = {
    "x86_64": "linux-amd64",
    "386": "linux-386",
    "aarch64": "linux-arm64",
    "armv7": "linux-armv7",
    "armv6": "linux-armv6",
    "armv5": "linux-armv5",
    "riscv64": "linux-riscv64",
    "loongarch64": "linux-loong64",
    "ppc64": "linux-ppc64",
    "ppc64le": "linux-ppc64le",
    "s390x": "linux-s390x",
}


#: sing-box publishes OpenWrt packages per package architecture.
_SING_BOX_OPENWRT = {
    "mipsel_24kc": "mipsel_24kc",
    "mipsel_24kc_24kf": "mipsel_24kc_24kf",
    "mipsel_74kc": "mipsel_74kc",
    "mipsel_mips32": "mipsel_mips32",
    "mips_24kc": "mips_24kc",
    "mips_4kec": "mips_4kec",
    "mips_mips32": "mips_mips32",
    "mips64_mips64r2": "mips64_mips64r2",
    "mips64_octeonplus": "mips64_octeonplus",
    "mips64el_mips64r2": "mips64el_mips64r2",
}


def sing_box_openwrt_target(arch: str | None = None) -> str:
    """sing-box OpenWrt package target for this router, empty when none.

    Falls back to the closest published target when the router's exact
    OpenWrt architecture is not one sing-box builds for.
    """
    arch = (arch if arch is not None else openwrt_arch()).strip().lower()
    if arch in _SING_BOX_OPENWRT:
        return _SING_BOX_OPENWRT[arch]
    machine = normalize_machine()
    abi = mips_float_abi()
    if machine == "mipsel":
        return "mipsel_mips32" if abi == "soft" else "mipsel_24kc"
    if machine == "mips":
        return "mips_mips32" if abi == "soft" else "mips_24kc"
    if machine == "mips64":
        return "mips64_mips64r2"
    if machine == "mips64le":
        return "mips64el_mips64r2"
    return ""
