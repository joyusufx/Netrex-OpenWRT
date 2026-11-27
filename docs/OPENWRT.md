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
wget -qO- https://raw.githubusercontent.com/joyusufx/Netrex-OpenWRT/openwrt-mips-port/scripts/get.sh | NETREX_REPO=joyusufx/Netrex-OpenWRT NETREX_REF=openwrt-mips-port sh
```

`scripts/get.sh` detects OpenWrt and runs this installer; on a fork or branch,
`NETREX_REPO=OWNER/NAME NETREX_REF=branch get.sh` clones that instead.

The installer detects the package manager (apk on OpenWrt 25.12+, opkg on
22.03-24.10), installs the dependencies (python3, python3-pip, nftables,
kmod-nft-core, kmod-tun, kmod-ifb, tc, ip-full, dnsmasq-full, git-http,
ca-bundle, python3-yaml, python3-websockets, conntrack), puts the code in
`/opt/quota-manager` (the on-disk path is deliberately unchanged for existing
installs and the self-updater), installs the Python deps and registers the
procd service `/etc/init.d/quota-manager` (enabled, respawned by procd).

If `/opt/quota-manager` already holds the code — a git checkout, or a tree
copied over by hand — the installer keeps it and skips the download, so a
re-run works offline. Re-running the installer, the in-app self-update
(`quota/updater.py`) or `--upgrade` pulls only a git checkout; an existing
`/etc/quota-gateway/config.yaml` is never overwritten.

A router install updates from this fork, not from upstream release assets (that
pipeline builds no MIPS packages): `python3 run.py --self-update` shallow-fetches
`joyusufx/Netrex-OpenWRT` (`openwrt-mips-port`), fast-forwards the checkout only
when it is clean, and schedules a service restart when the commit changed. Local
edits or a diverged branch refuse instead of being overwritten.

### Install-path migration notes (for maintainers)

The installer defaults to the fork that carries the port, `joyusufx/Netrex-OpenWRT`
(branch `openwrt-mips-port`). Upstream `UserJoo9/Netrex` has no port branch, so
defaulting there made every bare run fail on the wrong-branch heal. Overrides:
`NETREX_GIT_URL` / `NETREX_REF` (installer), `NETREX_REPO` / `NETREX_REF` (get.sh).

Phases, each leaving installs working:

1. **Heal a stale checkout** (`scripts/install_openwrt.sh` ~line 55): a
   `/opt/quota-manager` checkout without the port files gets origin repointed at
   the install repo, `openwrt-mips-port` fetched and checked out, upstream set —
   so `--upgrade`'s `git pull --ff-only` keeps tracking the port branch. Only
   **tracked** modifications count as "local changes": every finished install
   leaves pip's `pylib/` inside the app dir (now git-ignored), so a plain
   `git status --porcelain` test made the heal refuse on every router.
2. **Preserve, then replace**: if the checkout has tracked edits, or the fetch
   fails, the unusable tree is moved aside to `/opt/quota-manager.old.<ts>`
   (never deleted, never overwritten) and a fresh clone takes its place, so the
   run cannot stop on a manual `mv` the user has to repeat on the router.
3. **Clone defaults** (this change): bare runs clone the port repo/branch
   directly; phases 1 and 2 remain for checkouts made before this default.

`scripts/get.sh` now fetches the installer from the same repo/branch it will
clone from (the fork's `openwrt-mips-port`). Before, a bare `get.sh | sh` on
`UserJoo9/Netrex@main` downloaded the *pre-port* installer from upstream, which
does not match the port at all. `--repo`/`--ref` still override both.

Preserved exactly: `/opt/quota-manager`, `/etc/quota-gateway/*` (config and DB
never overwritten), the skip-download-on-existing-install behaviour, and
`NETREX_REPO`/`NETREX_REF` overrides. Rollback for the current phase: revert
commit `e57072c` (defaults return to upstream, phase 1/2 heal still applies).

## Seeded network settings (why quota accounting works at all)

`config.yaml` ships the Debian laptop gateway's values: clients on a separate
`192.168.2.0/24` and dnsmasq's lease file at `/var/lib/misc/dnsmasq.leases`.
On a router neither is true — the box **is** the LAN gateway and OpenWrt starts
dnsmasq with `--dhcp-leasefile=/tmp/dhcp.leases`. With the Debian values the
lease sync found no file, no MAC↔IP binding reached the engine, no
`q_up_/q_down_` counter was installed, and every device showed up in the
dashboard while nothing it transferred was ever charged or cut.

Two layers now prevent that:

- **Installer seed (fresh installs).** Before the first start it seeds the
  `dhcp` block from UCI: `gateway_ip` and `router_ip` = `network.lan.ipaddr`,
  `subnet` = `network.lan.netmask`, `pool_start`/`pool_end` from
  `dhcp.lan.start`/`dhcp.lan.limit` (default `.100`–`.200`), and
  `lease_file: /tmp/dhcp.leases`. An existing `config.yaml` is never touched.
- **App fallback (updates and hand-edited boxes).** `Gateway._lease_file_path`
  (`run.py`) uses the configured lease file; if it is missing on an OpenWrt
  host (`quota/hostarch.py`) it falls back to `/tmp/dhcp.leases` and logs a
  warning once. On a Debian box the fallback is never used, so a stray
  `/tmp/dhcp.leases` cannot be mistaken for this gateway's leases.
- **Static-IP clients.** A client with a fixed address never gets a DHCP lease,
  so its `ip` was empty. The tick now completes it from the kernel neighbour
  table (`ip neigh`, non-`FAILED`/`INCOMPLETE` rows), so static clients are
  counted and blocked like everyone else.

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
| Database (`db_path`) | `/var/lib/quota-gateway/quota.db` | `/etc/quota-gateway/quota.db` (on flash — `/var` is a tmpfs symlink wiped at reboot) |
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
