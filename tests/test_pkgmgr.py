"""quota/pkgmgr.py — package-manager detection and install argv."""

from quota import pkgmgr


def _which(names):
    return lambda name: "/usr/bin/" + name if name in names else None


def test_apt_get_wins_on_glibc_hosts():
    # Kali/Debian hosts may carry opkg from tests; apt stays byte-identical
    assert pkgmgr.manager(_which({"apt-get", "opkg", "apk"})) == "apt-get"


def test_apk_wins_on_new_openwrt():
    assert pkgmgr.manager(_which({"apk"})) == "apk"


def test_opkg_on_old_openwrt():
    assert pkgmgr.manager(_which({"opkg"})) == "opkg"


def test_no_manager_is_empty_string():
    assert pkgmgr.manager(lambda name: None) == ""


def test_install_argv_per_manager():
    assert pkgmgr.install_argv(["tc", "nftables"], _which({"apt-get"})) == [
        "apt-get", "install", "-y", "--no-install-recommends", "tc", "nftables"]
    assert pkgmgr.install_argv(["tc"], _which({"apk"})) == ["apk", "add", "--no-cache", "tc"]
    assert pkgmgr.install_argv(["tc"], _which({"opkg"})) == ["opkg", "install", "tc"]
    assert pkgmgr.install_argv(["tc"], _which({"dnf"})) == ["dnf", "install", "-y", "tc"]
    assert pkgmgr.install_argv(["tc"], _which({"pacman"})) == ["pacman", "-S", "--noconfirm", "--needed", "tc"]


def test_install_argv_none_without_manager_or_packages():
    assert pkgmgr.install_argv(["tc"], lambda name: None) is None
    assert pkgmgr.install_argv([], _which({"opkg"})) is None


def test_install_shell_opkg_refreshes_index_first():
    assert pkgmgr.install_shell(["tc"], _which({"opkg"})) == "opkg update && opkg install tc"


def test_install_shell_quotes_and_skips_update_elsewhere():
    assert pkgmgr.install_shell(["tc"], _which({"apk"})) == "apk add --no-cache tc"
    assert "update" not in pkgmgr.install_shell(["tc"], _which({"apt-get"}))
    weird = pkgmgr.install_shell(["weird pkg"], _which({"opkg"}))
    assert "weird' 'pkg" in weird or "'weird pkg'" in weird  # shlex-quoted
