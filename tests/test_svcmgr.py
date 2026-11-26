"""quota/svcmgr.py — systemd argvs stay exact, procd gets the init script."""

import pytest

from quota import svcmgr


@pytest.fixture
def systemd(monkeypatch):
    monkeypatch.setattr(svcmgr.hostarch, "is_openwrt", lambda: False)
    return "systemd"


@pytest.fixture
def openwrt(monkeypatch, tmp_path):
    monkeypatch.setattr(svcmgr.hostarch, "is_openwrt", lambda: True)
    scripts = tmp_path / "init.d"
    scripts.mkdir()
    for name in ("quota-manager", "dnsmasq", "samba4", "tailscale"):
        (scripts / name).write_text("#!/bin/sh /etc/rc.common\n")
    return scripts


def _with_scripts(monkeypatch, base):
    """Point init_script() at tmp init.d; missing scripts stay None."""
    def fake(unit):
        name = svcmgr._OPENWRT_SERVICES.get(unit, unit)
        if not name:
            return None
        script = base / name
        return script if script.is_file() else None

    monkeypatch.setattr(svcmgr, "init_script", fake)


# ---- backend -----------------------------------------------------------------

def test_backend_follows_platform(monkeypatch):
    monkeypatch.setattr(svcmgr.hostarch, "is_openwrt", lambda: True)
    assert svcmgr.backend() == "openwrt"
    monkeypatch.setattr(svcmgr.hostarch, "is_openwrt", lambda: False)
    assert svcmgr.backend() == "systemd"


# ---- service_argv ------------------------------------------------------------

def test_systemd_argv_unchanged(systemd):
    assert svcmgr.service_argv("restart", "quota-gateway") == [
        "systemctl", "restart", "quota-gateway"]
    assert svcmgr.service_argv("enable --now", "quota-gateway") == [
        "systemctl", "enable", "--now", "quota-gateway"]


def test_openwrt_runs_the_init_script(openwrt, monkeypatch):
    _with_scripts(monkeypatch, openwrt)
    assert svcmgr.service_argv("restart", "quota-gateway") == [
        str(openwrt / "quota-manager"), "restart"]


def test_openwrt_action_aliases(openwrt, monkeypatch):
    _with_scripts(monkeypatch, openwrt)
    assert svcmgr.service_argv("try-restart", "dnsmasq") == [
        str(openwrt / "dnsmasq"), "restart"]


def test_openwrt_enable_now_enables_then_starts(openwrt, monkeypatch):
    _with_scripts(monkeypatch, openwrt)
    argv = svcmgr.service_argv("enable --now", "quota-gateway")
    assert argv[0] == "/bin/sh" and argv[1] == "-c"
    assert f"{openwrt / 'quota-manager'} enable" in argv[2]
    assert f"exec {openwrt / 'quota-manager'} start" in argv[2]


def test_openwrt_smbd_maps_to_samba4_package_script(openwrt, monkeypatch):
    _with_scripts(monkeypatch, openwrt)
    assert svcmgr.service_argv("restart", "smbd") == [str(openwrt / "samba4"), "restart"]


def test_openwrt_quota_wan_ppp_has_no_service(openwrt, monkeypatch):
    _with_scripts(monkeypatch, openwrt)
    # netifd owns the WAN; spawning an init script that cannot exist is the bug
    assert svcmgr.service_argv("restart", "quota-wan-ppp") is None


def test_openwrt_missing_script_is_none(openwrt, monkeypatch):
    _with_scripts(monkeypatch, openwrt)
    assert svcmgr.service_argv("restart", "cron") is None


# ---- is_active_argv ----------------------------------------------------------

def test_is_active_argv_systemd(systemd):
    assert svcmgr.is_active_argv("dnsmasq") == ["systemctl", "is-active", "--quiet", "dnsmasq"]


def test_is_active_argv_openwrt_uses_pidof(openwrt):
    assert svcmgr.is_active_argv("dnsmasq") == ["pidof", "dnsmasq"]
    assert svcmgr.is_active_argv("tailscaled") == ["pidof", "tailscaled"]
    # no process name mapped -> None (caller answers "unknown", not "stopped")
    assert svcmgr.is_active_argv("quota-gateway") is None
    assert svcmgr.is_active_argv("smbd") is None


# ---- restart_shell_command ---------------------------------------------------

def test_restart_command_delay_and_quoting(openwrt, monkeypatch):
    _with_scripts(monkeypatch, openwrt)
    argv = svcmgr.restart_shell_command("quota-gateway", delay_s=3)
    assert argv[:2] == ["/bin/sh", "-c"]
    assert argv[2].startswith("sleep 3 && ")
    assert str(openwrt / "quota-manager") in argv[2]  # shlex-quoted parts joined


def test_restart_command_without_delay(openwrt, monkeypatch):
    _with_scripts(monkeypatch, openwrt)
    argv = svcmgr.restart_shell_command("quota-gateway")
    assert argv[:2] == ["/bin/sh", "-c"]
    assert not argv[2].startswith("sleep")


def test_restart_command_raises_when_no_service(openwrt, monkeypatch):
    _with_scripts(monkeypatch, openwrt)
    with pytest.raises(RuntimeError):
        svcmgr.restart_shell_command("quota-wan-ppp")


# ---- reboot_argv / schedule --------------------------------------------------

def test_reboot_argv_systemd(systemd):
    assert svcmgr.reboot_argv() == ["systemctl", "reboot"]


def test_reboot_argv_openwrt(openwrt):
    assert svcmgr.reboot_argv() == ["reboot"]


def test_schedule_systemd_uses_systemd_run(systemd):
    seen = {}

    def run(argv):
        seen["argv"] = argv
        return 0, ""

    svcmgr.schedule("quota-update", ["/bin/true", "--flag"], 7, run_command=run)
    assert seen["argv"][:4] == ["systemd-run", "--unit=quota-update", "--collect", "--on-active=7"]
    assert seen["argv"][4:] == ["/bin/true", "--flag"]


def test_schedule_systemd_failure_raises(systemd):
    def run(argv):
        return 1, "boom"
    with pytest.raises(RuntimeError):
        svcmgr.schedule("quota-update", ["/bin/true"], 5, run_command=run)


def test_schedule_openwrt_detaches_itself(monkeypatch):
    monkeypatch.setattr(svcmgr.hostarch, "is_openwrt", lambda: True)
    seen = {}

    def fake_spawn(argv, delay_s=0):
        seen["argv"], seen["delay"] = argv, delay_s

    monkeypatch.setattr(svcmgr, "spawn_detached", fake_spawn)
    svcmgr.schedule("quota-update", ["/bin/sh", "x y"], 9)
    assert seen == {"argv": ["/bin/sh", "x y"], "delay": 9}
    # no systemd-run call may be attempted on a router
    assert "systemd-run" not in str(seen)
