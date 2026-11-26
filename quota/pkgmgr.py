"""Package installation for glibc distros and OpenWrt routers.

Debian/Kali hosts keep using ``apt-get`` exactly as before. A router has no
dpkg: OpenWrt 24.10 and older ship ``opkg``, 25.12+ ships ``apk``. Callers ask
this module for the command instead of hard-coding a package manager.

``None`` means "no supported package manager here" so callers can report an
honest error instead of running a command that cannot exist.
"""

from __future__ import annotations

import shlex
import shutil
from typing import Callable, Sequence

Which = Callable[[str], str | None]

#: managers we can drive, in the order they are probed. ``apt-get`` first is
#: what keeps the glibc hosts (Kali/Debian) byte-identical to before.
_ORDER = ("apt-get", "apk", "opkg", "dnf", "pacman")

#: binary -> the argv prefix that installs packages with it.
_PREFIX = {
    "apt-get": ["apt-get", "install", "-y", "--no-install-recommends"],
    "apk": ["apk", "add", "--no-cache"],
    "opkg": ["opkg", "install"],
    "dnf": ["dnf", "install", "-y"],
    "pacman": ["pacman", "-S", "--noconfirm", "--needed"],
}

#: managers whose index must be refreshed before a package can be found.
_NEEDS_UPDATE = {"opkg": ["opkg", "update"]}


def manager(which: Which | None = None) -> str:
    """Name of the package manager binary this host has ('' when none)."""
    which = which or shutil.which
    for name in _ORDER:
        if which(name):
            return name
    return ""


def install_argv(packages: Sequence[str], which: Which | None = None,
                 manager_name: str | None = None) -> list[str] | None:
    """argv that installs ``packages`` (None when there is no manager)."""
    name = manager_name if manager_name is not None else manager(which)
    prefix = _PREFIX.get(name)
    if prefix is None or not packages:
        return None
    return [*prefix, *packages]


def install_shell(packages: Sequence[str], which: Which | None = None,
                  manager_name: str | None = None) -> str:
    """One shell command that installs ``packages`` ('' when not possible).

    ``opkg`` needs its index refreshed first; the other managers either do it
    themselves (``apk --no-cache``) or already have a usable index (apt).
    """
    argv = install_argv(packages, which, manager_name)
    if argv is None:
        return ""
    command = " ".join(shlex.quote(part) for part in argv)
    name = manager_name if manager_name is not None else manager(which)
    update = _NEEDS_UPDATE.get(name)
    if update:
        return " ".join(shlex.quote(part) for part in update) + " && " + command
    return command
