"""Turn the whole gateway off from the dashboard (System > Power).

The work is done by ``scripts/gateway_off.sh``; this only schedules it a few
seconds out, so the API can answer first and the script keeps running after
it stops ``quota-gateway.service`` (this very process). systemd hosts use
``systemd-run``; OpenWrt detaches the child itself (see quota/svcmgr.py).
"""

from __future__ import annotations

import logging
import sys
from pathlib import Path
from typing import Callable

from quota import svcmgr

log = logging.getLogger("quota.power")

RunCommand = Callable[[list[str]], tuple[int, str]]

SCRIPT = Path(__file__).resolve().parent.parent / "scripts" / "gateway_off.sh"
DELAY_S = 3


def schedule_gateway_off(poweroff: bool = False,
                         script: Path = SCRIPT,
                         run_command: RunCommand | None = None) -> dict[str, object]:
    """Schedule the gateway shutdown. Raises RuntimeError when it cannot."""
    if not script.exists():
        raise RuntimeError(f"shutdown script not found: {script}")
    argv = ["/bin/bash", str(script)]
    if poweroff:
        argv.append("poweroff")
    svcmgr.schedule("quota-gateway-off", argv, DELAY_S, run_command)
    log.warning("gateway turn-off scheduled in %d s (poweroff=%s)", DELAY_S, poweroff)
    return {"scheduled": True, "poweroff": poweroff, "delay_s": DELAY_S}


FACTORY_RESET = Path(__file__).resolve().parent / "factory_reset.py"


def _systemd_run(unit: str, cmd: list[str],
                 run_command: RunCommand | None) -> None:
    svcmgr.schedule(unit, cmd, DELAY_S, run_command)


def schedule_restart(machine: bool = False,
                     run_command: RunCommand | None = None) -> dict[str, object]:
    """Restart the gateway service, or reboot the whole machine."""
    cmd = svcmgr.reboot_argv() if machine else svcmgr.service_argv("restart", "quota-gateway")
    if cmd is None:
        raise RuntimeError("quota-gateway: no service manager entry on this platform")
    _systemd_run("quota-gateway-restart", cmd, run_command)
    log.warning("%s scheduled in %d s", "reboot" if machine else "gateway restart", DELAY_S)
    return {"scheduled": True, "machine": machine, "delay_s": DELAY_S}


def schedule_factory_reset(db_path: str, keep_users: bool = False,
                           script: Path = FACTORY_RESET,
                           run_command: RunCommand | None = None) -> dict[str, object]:
    """Back the database up, wipe it and restart the gateway (see
    quota/factory_reset.py for what survives)."""
    if not script.exists():
        raise RuntimeError(f"factory reset script not found: {script}")
    if not db_path or not Path(db_path).exists():
        raise RuntimeError(f"database not found: {db_path}")
    # sys.executable: the venv python on OpenWrt, /usr/bin/pythonN elsewhere.
    cmd = [sys.executable, str(script), "--db", str(Path(db_path).resolve())]
    if keep_users:
        cmd.append("--keep-users")
    _systemd_run("quota-factory-reset", cmd, run_command)
    log.warning("factory reset scheduled in %d s (keep_users=%s)", DELAY_S, keep_users)
    return {"scheduled": True, "keep_users": keep_users, "delay_s": DELAY_S}
