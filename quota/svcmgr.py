"""Service control for systemd hosts and OpenWrt's procd.

The dashboard normally talks to ``systemctl``; an OpenWrt router has no
systemd, only procd init scripts in ``/etc/init.d``. Everything that starts,
stops or restarts a service goes through this module so the systemd argv
stays exactly as before on hosts that have it, while routers get the init
script. ``None`` means "this platform has no such service": callers degrade
to an honest error instead of spawning a command that cannot exist.
"""

from __future__ import annotations

import shlex
import subprocess
from pathlib import Path
from typing import Callable

from quota import hostarch

RunCommand = Callable[[list[str]], tuple[int, str]]

#: systemd unit -> init script name on OpenWrt. ``None`` = no equivalent
#: (netifd owns the WAN, so there is no user-space quota-wan-ppp unit).
_OPENWRT_SERVICES: dict[str, str | None] = {
    "quota-gateway": "quota-manager",
    "quota-manager": "quota-manager",
    "dnsmasq": "dnsmasq",
    "smbd": "samba4",
    "tailscaled": "tailscale",
    "quota-wan-ppp": None,
}

#: process name used for "is it running?" on OpenWrt (procd services do not
#: answer ``systemctl is-active`` and ``running`` is not in every rc.common).
_OPENWRT_PROCESS = {"dnsmasq": "dnsmasq", "tailscaled": "tailscaled"}

#: systemctl actions that have a different name in rc.common.
_INITD_ACTIONS = {"try-restart": "restart", "is-active": "running"}


def backend() -> str:
    """``openwrt`` on a procd router, ``systemd`` everywhere else."""
    return "openwrt" if hostarch.is_openwrt() else "systemd"


def init_script(unit: str) -> Path | None:
    """Init script for ``unit`` on OpenWrt (None when not installed)."""
    name = _OPENWRT_SERVICES.get(unit, unit)
    if not name:
        return None
    script = Path("/etc/init.d") / name
    return script if script.is_file() else None


def service_argv(action: str, unit: str) -> list[str] | None:
    """argv for ``systemctl ACTION UNIT`` (or the procd init script).

    Argument order matches systemctl: action first, unit second.
    """
    if backend() == "systemd":
        # "enable --now" must reach systemctl as two words, not one argv
        return ["systemctl", *action.split(), unit]
    script = init_script(unit)
    if script is None:
        return None
    words = action.split()
    verb = _INITD_ACTIONS.get(words[0], words[0]) if words else action
    # systemctl's --now also starts (enable) or stops (disable) the unit;
    # rc.common has no such flag, so run the follow-up action explicitly
    follow = {"enable": "start", "disable": "stop"}.get(verb) if "--now" in words[1:] else None
    if follow:
        return ["/bin/sh", "-c", f"{script} {verb} >/dev/null 2>&1; exec {script} {follow}"]
    return [str(script), verb]


def is_active_argv(unit: str) -> list[str] | None:
    """argv whose exit status is 0 when ``unit`` is running, else None."""
    if backend() == "systemd":
        return ["systemctl", "is-active", "--quiet", unit]
    proc = _OPENWRT_PROCESS.get(unit)
    return ["pidof", proc] if proc else None


def restart_shell_command(unit: str, delay_s: int = 0) -> list[str]:
    """``sh -c`` argv that restarts ``unit`` after ``delay_s``.

    Used where the restart must outlive the process that asks for it (the
    API answers first, then the service it runs in is restarted). Returns a
    Popen-ready argv so the unit name is never re-parsed as shell code.
    """
    argv = service_argv("restart", unit)
    if argv is None:
        raise RuntimeError(f"{unit}: no service manager entry on this platform")
    command = " ".join(shlex.quote(part) for part in argv)
    return ["/bin/sh", "-c", f"sleep {int(delay_s)} && {command}" if delay_s else command]


def reboot_argv() -> list[str]:
    """argv that reboots the machine (BusyBox ``reboot`` on OpenWrt)."""
    return ["reboot"] if backend() == "openwrt" else ["systemctl", "reboot"]


def spawn_detached(argv: list[str], delay_s: int = 0) -> None:
    """Run ``argv`` after ``delay_s`` in its own session, without waiting.

    openwrt has no ``systemd-run``: the child gets a new session so it keeps
    running when procd restarts the gateway, and its output is discarded.
    """
    command = "sleep %d; exec %s" % (int(delay_s), " ".join(shlex.quote(p) for p in argv))
    subprocess.Popen(["/bin/sh", "-c", command],
                     stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
                     stderr=subprocess.DEVNULL, start_new_session=True)


def schedule(unit: str, argv: list[str], delay_s: int,
             run_command: RunCommand | None = None) -> None:
    """Run ``argv`` a few seconds from now, outliving the current process.

    systemd hosts use ``systemd-run`` exactly as before; OpenWrt detaches
    the child itself. Raises RuntimeError when it could not be scheduled.
    """
    if backend() == "systemd":
        full = ["systemd-run", f"--unit={unit}", "--collect",
                f"--on-active={int(delay_s)}", *argv]
        rc, out = (run_command or _default_run)(full)
        if rc != 0:
            raise RuntimeError(out or f"systemd-run exited {rc}")
        return
    spawn_detached(argv, delay_s)


def _default_run(argv: list[str]) -> tuple[int, str]:
    try:
        proc = subprocess.run(argv, capture_output=True, text=True, timeout=10)
    except FileNotFoundError:
        return 127, f"{argv[0]}: command not found"
    except subprocess.TimeoutExpired:
        return 124, "timed out"
    return proc.returncode, (proc.stdout or proc.stderr or "").strip()
