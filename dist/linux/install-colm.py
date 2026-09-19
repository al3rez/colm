#!/usr/bin/env python3
"""Register an already-built Colm prefix without stopping any running application."""

import argparse
import os
from pathlib import Path
import shlex
import stat
import subprocess
import sys
import uuid

APP_ID = "io.github.al3rez.Colm"
OLD_ID = "io.github.al3rez.Column"
DIRECTORY_FLAGS = os.O_RDONLY | os.O_DIRECTORY | os.O_CLOEXEC | os.O_NOFOLLOW


def directory(path, create=False):
    """Open every component without following links; callers own the returned fd."""
    path = Path(os.path.abspath(path))
    fd = os.open("/", DIRECTORY_FLAGS)
    try:
        for part in path.parts[1:]:
            if create:
                try:
                    os.mkdir(part, 0o755, dir_fd=fd)
                except FileExistsError:
                    pass
            child = os.open(part, DIRECTORY_FLAGS, dir_fd=fd)
            os.close(fd)
            fd = child
        return fd
    except BaseException:
        os.close(fd)
        raise


def metadata(path):
    try:
        fd = directory(path.parent)
    except FileNotFoundError:
        return None
    try:
        try:
            return os.stat(path.name, dir_fd=fd, follow_symlinks=False)
        except FileNotFoundError:
            return None
    finally:
        os.close(fd)


def contents(path):
    parent = directory(path.parent)
    try:
        fd = os.open(path.name, os.O_RDONLY | os.O_CLOEXEC | os.O_NOFOLLOW | os.O_NONBLOCK, dir_fd=parent)
        with os.fdopen(fd, "rb") as stream:
            info = os.fstat(stream.fileno())
            if not stat.S_ISREG(info.st_mode) or info.st_size > 16 * 1024 * 1024:
                raise RuntimeError(f"not a small regular registration file: {path}")
            return stream.read()
    finally:
        os.close(parent)


def target(path):
    parent = directory(path.parent)
    try:
        value = os.readlink(path.name, dir_fd=parent)
    finally:
        os.close(parent)
    return Path(os.path.abspath(path.parent / value))


def fingerprint(info):
    return None if info is None else (info.st_dev, info.st_ino, info.st_mtime_ns, info.st_size)


def register(source, destination, dry_run, allow_copy=True):
    before = metadata(destination)
    if before is not None:
        if stat.S_ISLNK(before.st_mode) and target(destination) == source:
            return
        if not allow_copy or not stat.S_ISREG(before.st_mode) or contents(destination) != contents(source):
            raise RuntimeError(f"refusing unrelated destination: {destination}")
    print(f"link {destination} -> {source}")
    if dry_run:
        return
    parent = directory(destination.parent, create=True)
    temporary = f".colm-install-{uuid.uuid4().hex}"
    try:
        if fingerprint(metadata(destination)) != fingerprint(before):
            raise RuntimeError(f"destination changed during installation: {destination}")
        if before is None:
            os.symlink(str(source), destination.name, dir_fd=parent)
        else:
            os.symlink(str(source), temporary, dir_fd=parent)
            os.replace(temporary, destination.name, src_dir_fd=parent, dst_dir_fd=parent)
    finally:
        try:
            os.unlink(temporary, dir_fd=parent)
        except FileNotFoundError:
            pass
        os.close(parent)


def old_registration(path, old_source, old_prefix):
    info = metadata(path)
    if info is None:
        return False
    if stat.S_ISLNK(info.st_mode):
        return target(path) == old_source
    if not stat.S_ISREG(info.st_mode):
        return False
    # Byte-identical copies of old icons/metainfo/activation artifacts are ours.
    if metadata(old_source) is not None and contents(path) == contents(old_source):
        return True
    if path.suffix not in (".desktop", ".service"):
        return False
    text = contents(path).decode("utf-8", errors="strict")
    commands = [line.split("=", 1)[1] for line in text.splitlines()
                if line.startswith(("Exec=", "ExecStart=", "TryExec="))]
    expected = str(old_prefix / "bin/column")
    return OLD_ID in text and bool(commands) and all(
        shlex.split(command) and shlex.split(command)[0] == expected
        for command in commands
    )


def remove_old(path, old_source, old_prefix, dry_run):
    before = metadata(path)
    if before is None:
        return
    if not old_registration(path, old_source, old_prefix):
        print(f"retain unrecognized old entry: {path}", file=sys.stderr)
        return
    print(f"remove obsolete registration {path}")
    if dry_run:
        return
    parent = directory(path.parent)
    try:
        current = os.stat(path.name, dir_fd=parent, follow_symlinks=False)
        if fingerprint(current) != fingerprint(before):
            raise RuntimeError(f"old entry changed during installation: {path}")
        os.unlink(path.name, dir_fd=parent)
    finally:
        os.close(parent)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--prefix", type=Path, default=Path.home() / ".local/opt/colm")
    parser.add_argument("--dry-run", action="store_true", help="show changes without writing or refreshing registrations")
    options = parser.parse_args()
    prefix = Path(os.path.abspath(options.prefix.expanduser()))
    home = Path.home()
    old_prefix = home / ".local/opt/column"
    data = Path(os.environ.get("XDG_DATA_HOME") or home / ".local/share")
    config = Path(os.environ.get("XDG_CONFIG_HOME") or home / ".config")
    if not data.is_absolute() or not config.is_absolute():
        raise RuntimeError("XDG_DATA_HOME and XDG_CONFIG_HOME must be absolute")
    executable = prefix / "bin/clm"
    if not executable.is_file() or not os.access(executable, os.X_OK):
        raise RuntimeError(f"build and install Colm into the prefix first: {executable}")

    relative_files = [
        Path(f"applications/{APP_ID}.desktop"),
        Path(f"dbus-1/services/{APP_ID}.service"),
        Path(f"systemd/user/app-{APP_ID}.service"),
        Path(f"metainfo/{APP_ID}.metainfo.xml"),
    ]
    relative_files += sorted(path.relative_to(prefix / "share") for path in
                             (prefix / "share/icons/hicolor").glob(f"*/apps/{APP_ID}*.png"))
    if len(relative_files) == 4:
        raise RuntimeError("built Colm icons are missing")
    links = [(prefix / "share" / relative, data / relative) for relative in relative_files]
    links.append((executable, home / ".local/bin/clm"))
    # Preflight the whole new registration set before the first mutation.
    for source, destination in links:
        if metadata(source) is None or not stat.S_ISREG(metadata(source).st_mode):
            raise RuntimeError(f"missing regular build artifact: {source}")
        info = metadata(destination)
        if info is not None and not (
            stat.S_ISLNK(info.st_mode) and target(destination) == source
            or source != executable and stat.S_ISREG(info.st_mode) and contents(destination) == contents(source)
        ):
            raise RuntimeError(f"refusing unrelated destination: {destination}")
    for source, destination in links:
        register(source, destination, options.dry_run, allow_copy=source != executable)

    for relative in relative_files:
        old_relative = Path(str(relative).replace(APP_ID, OLD_ID))
        remove_old(data / old_relative, old_prefix / "share" / old_relative, old_prefix, options.dry_run)
    # Older local installations may have registered the unit in the config tree.
    old_unit = f"app-{OLD_ID}.service"
    old_unit_source = old_prefix / "share/systemd/user" / old_unit
    remove_old(config / "systemd/user" / old_unit, old_unit_source, old_prefix, options.dry_run)
    for base in (config, data):
        wants = base / "systemd/user/graphical-session.target.wants" / old_unit
        # Enablement links may target the user registration instead of the prefix.
        if metadata(wants) is not None and stat.S_ISLNK(metadata(wants).st_mode):
            registered = target(wants)
            if registered in (old_unit_source, config / "systemd/user" / old_unit,
                              data / "systemd/user" / old_unit):
                remove_old(wants, registered, old_prefix, options.dry_run)
    old_link = home / ".local/bin/column"
    info = metadata(old_link)
    if info is not None and stat.S_ISLNK(info.st_mode):
        remove_old(old_link, old_prefix / "bin/column", old_prefix, options.dry_run)

    # Retire only our previous PATH link, not its binary: live processes may
    # still use that inode. Never claim a regular file or another installation.
    old_cli = home / ".local/bin/colm-terminal"
    info = metadata(old_cli)
    if info is not None:
        if stat.S_ISLNK(info.st_mode):
            remove_old(old_cli, prefix / "bin/colm-terminal", prefix, options.dry_run)
        else:
            print(f"retain unrecognized old entry: {old_cli}", file=sys.stderr)

    if not options.dry_run:
        # Reload definitions only: never stop, restart, disable --now, or kill.
        failures = []
        for command in (
            ["systemctl", "--user", "daemon-reload"],
            ["busctl", "--user", "call", "org.freedesktop.DBus", "/org/freedesktop/DBus",
             "org.freedesktop.DBus", "ReloadConfig"],
            ["update-desktop-database", str(data / "applications")],
            ["gtk-update-icon-cache", "--force", "--ignore-theme-index", str(data / "icons/hicolor")],
        ):
            try:
                subprocess.run(command, check=True)
            except (OSError, subprocess.CalledProcessError) as error:
                failures.append(f"{' '.join(command)}: {error}")
        if failures:
            raise RuntimeError("registration installed; refresh failed (retry these commands):\n" + "\n".join(failures))
    print("Colm registration ready. Existing terminals, old settings, and Ghostty were not changed.")


if __name__ == "__main__":
    try:
        main()
    except (OSError, RuntimeError, ValueError) as error:
        sys.exit(f"install-colm: {error}")
