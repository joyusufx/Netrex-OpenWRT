# Netrex on OpenWrt (MIPS / mipsel / arm)

Netrex runs on an OpenWrt router as well as on a Kali/Debian box. A router is a
different world: musl libc, no systemd (procd instead), no compiler, often only
8-16 MB of flash and 64-128 MB of RAM. This page is the port map; user-level
setup is one command.

## Install

```sh
# on the router (ash, root):
sh install_openwrt.sh          # from the release tarball root, or scripts/

# or in one line, without the tarball (POSIX sh, runs under ash):
wget -qO- https://raw.githubusercontent.com/joyusufx/Netrex-OpenWRT/openwrt-mips-port/scripts/get.sh | sh
```

`scripts/get.sh` detects OpenWrt and runs this installer; on a fork or branch,
`NETREX_REPO=OWNER/NAME NETREX_REF=branch get.sh` clones that instead.

The installer detects the package manager (apk on OpenWrt 25.12+, opkg on
22.03-24.10), installs the dependencies (python3, python3-pip, nftables,
kmod-nft-core, kmod-tun, kmod-ifb, tc, ip-full, dnsmasq-full, git-http,
ca-bundle, python3-yaml, python3-websockets, conntrack), clones the code to
`/opt/quota-manager` (the on-disk path is deliberately unchanged for existing
installs and the self-updater), installs the Python deps and registers the
procd service `/etc/init.d/quota-manager` (enabled, respawned by procd).

Re-running the installer, or the in-app self-update (`quota/updater.py`), runs
it again with `--upgrade`: it pulls the repo and restarts the service. An
existing `/etc/quota-gateway/config.yaml` is never overwritten.

## Python stack on a router

MIPS routers have no Rust/C toolchain, so wheels that need one do not exist
there. `requirements-openwrt.txt` pins a pure-Python stack:

| Package | Debian box | Router |
|---|---|---|
| fastapi | 0.141 (pydantic v2 / pydantic-core) | 0.115 + **pydantic 1.10** (pure Python) |
| uvicorn | 0.52 `[standard]` (uvloop/httptools) | plain uvicorn (workers = threads) |
| PyYAML | pip wheel (C) | opkg/apk `python3-yaml` (pre-compiled) |
| websockets | pip wheel | opkg/apk `python3-websockets` |
| webauthn | pip | not installed; passkeys answer "server support missing" |

Deps are installed with `python3 -m pip install --target /opt/quota-manager/pylib`
because OpenWrt's python3 has no `ensurepip` — a virtualenv is not an option.
The procd script exports `PYTHONPATH=/opt/quota-manager/pylib`.

`api/pydantic_compat.py` hides the v1/v2 difference from the rest of the code;
the full test suite runs on both stacks in CI.

## Service manager and packages: svcmgr / pkgmgr

Nothing in the app calls `systemctl` or `apt-get` directly any more:

- `quota/svcmgr.py` — every start/stop/restart/is-active goes through
  `service_argv()`/`is_active_argv()`. On systemd hosts the argv is
  byte-identical to before. On a router it runs `/etc/init.d/<unit>`, with a
  unit→script map (`smbd` → `samba4`) and `None` for units a router cannot
  have (`quota-wan-ppp` is owned by netifd — callers must treat `None` as an
  honest error, not fall back). Detached work uses `spawn_detached()` (new
  session) instead of `systemd-run`.
- `quota/pkgmgr.py` — package installs through `install_argv()`:
  apt-get / apk / opkg / dnf / pacman, `None` when unknown.

## Binaries on MIPS

`quota/hostarch.py` is the single source of arch truth: machine aliases
(`armv7l`→`armv7`, `mips64el`→`mips64le`), the router's opkg/apk arch
(`mipsel_24kc`…), the MIPS float ABI (arch tag first, `/proc/cpuinfo` FPU flag
second, **soft-float as the safe default**), and an ELF guard
(`elf_identity`/`binary_runs_here`) so a foreign binary is refused before
exec. Asset selection:

- tun2socks (`quota/tun2socks.py`): `linux-mips-softfloat` /
  `linux-mips-hardfloat` / `linux-mipsle-*` / `linux-mips64le`, pinned SHA-256;
  soft-float is the default because it also runs on hard-float CPUs.
- sing-box (`quota/vpn_manager.py`): refuses to exec an ELF that does not match
  the host (`binary_runs_here`) and picks the OpenWrt package target from
  `_SING_BOX_OPENWRT`, falling back to `mipsel_mips32`/`mips_24kc` by ABI.

## What is different at runtime on a router

| Area | Debian | OpenWrt |
|---|---|---|
| Service control | systemd units | procd init scripts (`svcmgr`) |
| dnsmasq config | `/etc/dnsmasq.d/` | `/tmp/dnsmasq.d/` (not flash-backed) |
| WAN control | `systemctl restart networking` | `ifup wan` via ubus/netifd |
| samba (file share) | `smbd` unit, `samba` package | `samba4` init script + package |
| Tailscale | systemd unit | `tailscale` init script, `pidof tailscaled` |
| Firewall geo | IPv4 nft sets, unchanged | same (no IPv6 geo on either) |

Everything else — nftables tables, tc shaping, quota math, the dashboard — is
the same code on both. See `Structure_README.md` for the full architecture.

## Development

- Full test suite on the router stack: CI installs fastapi 0.115 +
  pydantic 1.10 and runs the same pytest suite (both stacks).
- `tests/test_hostarch.py`, `tests/test_svcmgr.py`, `tests/test_pkgmgr.py`
  cover arch/ABI detection, ELF guards, asset selection, argvs and procd
  mapping. `tests/test_packaging.py` asserts the installer stays POSIX sh,
  apk+opkg aware and venv-free.
