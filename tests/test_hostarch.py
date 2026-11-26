"""quota/hostarch.py — arch facts, ELF guards and release-asset selection."""

import struct

import pytest

from quota import hostarch


@pytest.fixture(autouse=True)
def _clear_caches():
    hostarch.is_openwrt.cache_clear()
    hostarch.mips_float_abi.cache_clear()
    yield
    hostarch.is_openwrt.cache_clear()
    hostarch.mips_float_abi.cache_clear()


def _elf(machine: int, bits: int = 32, endian: str = "little") -> bytes:
    """A minimal ELF header elf_identity can read (e_ident + e_type + e_machine)."""
    e = "<" if endian == "little" else ">"
    ident = b"\x7fELF" + bytes([2 if bits == 64 else 1,
                                1 if endian == "little" else 2, 1]) + b"\0" * 9
    return ident + struct.pack(e + "HH", 2, machine)


# ---- normalize_machine -------------------------------------------------------

def test_normalize_machine_aliases():
    assert hostarch.normalize_machine("AMD64") == "x86_64"
    assert hostarch.normalize_machine(" arm64 ") == "aarch64"
    assert hostarch.normalize_machine("armv7l") == "armv7"
    assert hostarch.normalize_machine("mips64el") == "mips64le"


def test_normalize_machine_passthrough_and_default():
    assert hostarch.normalize_machine("mipsel") == "mipsel"
    assert hostarch.normalize_machine() == hostarch.normalize_machine(
        __import__("platform").machine())


# ---- is_openwrt --------------------------------------------------------------

def test_is_openwrt_env_override(monkeypatch):
    monkeypatch.setenv("QUOTA_PLATFORM", "openwrt")
    assert hostarch.is_openwrt() is True
    hostarch.is_openwrt.cache_clear()
    monkeypatch.setenv("QUOTA_PLATFORM", "linux")
    assert hostarch.is_openwrt() is False


def test_is_openwrt_detects_release_file(monkeypatch, tmp_path):
    monkeypatch.delenv("QUOTA_PLATFORM", raising=False)
    release = tmp_path / "openwrt_release"
    monkeypatch.setattr(hostarch, "_OPENWRT_RELEASE", release)
    monkeypatch.setattr(hostarch, "_RC_COMMON", tmp_path / "rc.common")
    assert hostarch.is_openwrt() is False
    hostarch.is_openwrt.cache_clear()
    release.write_text("DISTRIB_ID='OpenWrt'\nDISTRIB_ARCH='mipsel_24kc'\n")
    assert hostarch.is_openwrt() is True
    assert hostarch.openwrt_release()["DISTRIB_ARCH"] == "mipsel_24kc"


# ---- elf_identity / binary_runs_here ----------------------------------------

def test_elf_identity_reads_class_endian_cpu(tmp_path):
    f = tmp_path / "mips-bin"
    f.write_bytes(_elf(8, bits=32, endian="big"))
    assert hostarch.elf_identity(f) == (32, "big", "mips")
    f64 = tmp_path / "amd64-bin"
    f64.write_bytes(_elf(62, bits=64))
    assert hostarch.elf_identity(f64) == (64, "little", "x86_64")


def test_elf_identity_rejects_non_elf_and_missing(tmp_path):
    f = tmp_path / "script"
    f.write_text("#!/bin/sh\n")
    assert hostarch.elf_identity(f) is None
    assert hostarch.elf_identity(tmp_path / "nope") is None


_MACHINE_CODES = {"x86_64": 62, "aarch64": 183, "mips": 8, "mipsle": 8,
                  "x86": 3, "armv7": 40, "riscv": 243}


def test_binary_runs_here_accepts_scripts_and_matching_elf(tmp_path, monkeypatch):
    script = tmp_path / "script"
    script.write_text("#!/bin/sh\nexit 0\n")
    assert hostarch.binary_runs_here(script) is True
    # pin a known host identity so the test never skips on an exotic CPU
    monkeypatch.setattr(hostarch, "_host_identity",
                        lambda: (64, "little", "x86_64"))
    good = tmp_path / "native"
    good.write_bytes(_elf(_MACHINE_CODES["x86_64"], bits=64, endian="little"))
    assert hostarch.binary_runs_here(good) is True


def test_binary_runs_here_rejects_foreign_elf(tmp_path, monkeypatch):
    # a MIPS big-endian ELF cannot run on the pinned x86_64 host
    monkeypatch.setattr(hostarch, "_host_identity",
                        lambda: (64, "little", "x86_64"))
    foreign = tmp_path / "mips"
    foreign.write_bytes(_elf(8, bits=32, endian="big"))
    assert hostarch.binary_runs_here(foreign) is False


def test_binary_runs_here_rejects_missing_and_pe_on_linux(tmp_path):
    assert hostarch.binary_runs_here(tmp_path / "nope") is False
    pe = tmp_path / "sing-box.exe"
    pe.write_bytes(b"MZ" + b"\0" * 30)
    assert hostarch.binary_runs_here(pe) is (os_name() == "nt")


def os_name():
    import os
    return os.name


# ---- openwrt_arch ------------------------------------------------------------

class _Out:
    def __init__(self, stdout):
        self.stdout = stdout


def _fake_run(outs):
    """Fake subprocess.run returning one stdout per call, OSError afterwards."""
    calls = []

    def fake(argv, **kwargs):
        i = len(calls)
        calls.append(argv[0])
        if i >= len(outs):
            raise OSError("not installed")
        return _Out(outs[i])

    fake.calls = calls
    return fake


def test_openwrt_arch_takes_highest_priority_opkg_line(monkeypatch):
    monkeypatch.setattr(hostarch.subprocess, "run", _fake_run([
        "arch all 1\narch noarch 1\narch mipsel_24kc 10\narch mips 5\n"]))
    assert hostarch.openwrt_arch() == "mipsel_24kc"


def test_openwrt_arch_ignores_bad_priority_and_generic_names(monkeypatch):
    monkeypatch.setattr(hostarch.subprocess, "run", _fake_run([
        "arch all 1\narch noarch 1\narch mipsel_24kc notanumber\n"]))
    assert hostarch.openwrt_arch() == "mipsel_24kc"


def test_openwrt_arch_falls_back_to_apk(monkeypatch):
    fake = _fake_run(["", "mipsel_24kc\n"])
    monkeypatch.setattr(hostarch.subprocess, "run", fake)
    assert hostarch.openwrt_arch() == "mipsel_24kc"
    assert fake.calls == ["opkg", "apk"]


def test_openwrt_arch_empty_when_neither_answers(monkeypatch):
    monkeypatch.setattr(hostarch.subprocess, "run", _fake_run([]))
    assert hostarch.openwrt_arch() == ""


# ---- mips_float_abi ----------------------------------------------------------

def test_mips_float_abi_empty_off_mips(monkeypatch):
    monkeypatch.setattr(hostarch, "normalize_machine",
                        lambda machine=None: "x86_64")
    assert hostarch.mips_float_abi() == ""


@pytest.mark.parametrize("arch,expected", [
    ("mipsel_24kc", "hard"),
    ("mips_74kc", "hard"),
    ("mipsel_mips32", "soft"),
    ("mips_4kec", "soft"),
])
def test_mips_float_abi_from_openwrt_arch(monkeypatch, arch, expected):
    monkeypatch.setattr(hostarch, "normalize_machine",
                        lambda machine=None: "mipsel" if arch.startswith("mipsel") else "mips")
    monkeypatch.setattr(hostarch, "openwrt_arch", lambda: arch)
    assert hostarch.mips_float_abi() == expected


@pytest.mark.parametrize("cpuinfo,expected", [
    ("cpu : MIPS 24Kc V4.12\nfpu : MIPS FPU\n", "hard"),
    ("cpu : MIPS 4KEc V4.8\n", "soft"),
])
def test_mips_float_abi_from_proc_cpuinfo(monkeypatch, cpuinfo, expected):
    monkeypatch.setattr(hostarch, "normalize_machine", lambda machine=None: "mips")
    monkeypatch.setattr(hostarch, "openwrt_arch", lambda: "")

    class _FakePath:
        def __init__(self, p):
            self._p = str(p)

        def read_text(self, *a, **k):
            if "cpuinfo" in self._p:
                return cpuinfo
            raise OSError(self._p)

    monkeypatch.setattr(hostarch, "Path", _FakePath)
    assert hostarch.mips_float_abi() == expected


# ---- tun2socks_asset ---------------------------------------------------------

def test_tun2socks_asset_non_mips():
    assert hostarch.tun2socks_asset("x86_64") == "linux-amd64"
    assert hostarch.tun2socks_asset("aarch64") == "linux-arm64"
    assert hostarch.tun2socks_asset("armv7") == "linux-armv7"


def test_tun2socks_asset_mips_soft_is_the_safe_default():
    # soft-float runs on every MIPS o32 system; without an ABI hint it wins
    assert hostarch.tun2socks_asset("mips") == "linux-mips-softfloat"
    assert hostarch.tun2socks_asset("mipsel") == "linux-mipsle-softfloat"
    assert hostarch.tun2socks_asset("mips", abi="hard") == "linux-mips-hardfloat"
    assert hostarch.tun2socks_asset("mipsel", abi="hard") == "linux-mipsle-hardfloat"
    assert hostarch.tun2socks_asset("mips64le") == "linux-mips64le"


def test_tun2socks_asset_unknown_machine_is_empty():
    assert hostarch.tun2socks_asset("sparc") == ""
    assert hostarch.tun2socks_asset("powerpc") == ""


# ---- sing_box_openwrt_target -------------------------------------------------

def test_sing_box_target_exact_match():
    assert hostarch.sing_box_openwrt_target("mipsel_24kc") == "mipsel_24kc"
    assert hostarch.sing_box_openwrt_target("mips_4kec") == "mips_4kec"


def test_sing_box_target_mipsel_soft_falls_back_to_mips32(monkeypatch):
    # a soft-float build is the only one that also runs on hard-float routers
    monkeypatch.setattr(hostarch, "normalize_machine", lambda machine=None: "mipsel")
    monkeypatch.setattr(hostarch, "mips_float_abi", lambda: "soft")
    assert hostarch.sing_box_openwrt_target("mipsel_unknowntag") == "mipsel_mips32"


def test_sing_box_target_mips_hard_falls_back_to_24kc(monkeypatch):
    monkeypatch.setattr(hostarch, "normalize_machine", lambda machine=None: "mips")
    monkeypatch.setattr(hostarch, "mips_float_abi", lambda: "hard")
    assert hostarch.sing_box_openwrt_target("") == "mips_24kc"


def test_sing_box_target_non_mips_is_empty(monkeypatch):
    monkeypatch.setattr(hostarch, "openwrt_arch", lambda: "x86_64")
    assert hostarch.sing_box_openwrt_target() == ""
