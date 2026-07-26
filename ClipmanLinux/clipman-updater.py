#!/usr/bin/env python3
import argparse
import json
import os
import pathlib
import shutil
import subprocess
import time
import uuid


def process_exists(pid):
    try:
        os.kill(pid, 0)
        return True
    except ProcessLookupError:
        return False
    except PermissionError:
        return True


def write_result(path, value):
    path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    temporary = path.with_suffix(".tmp")
    temporary.write_text(json.dumps(value) + "\n", encoding="utf-8")
    temporary.chmod(0o600)
    temporary.replace(path)


def relaunch(executable):
    systemd_run = shutil.which("systemd-run")
    if systemd_run and os.environ.get("DBUS_SESSION_BUS_ADDRESS"):
        unit = "clipman-linux-restart-" + uuid.uuid4().hex
        result = subprocess.run(
            [systemd_run, "--user", "--unit=" + unit, "--collect", executable],
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, check=False,
        )
        if result.returncode == 0:
            return
    subprocess.Popen(
        [executable], stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL, start_new_session=True,
    )


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--wait-pid", type=int, required=True)
    parser.add_argument("--package", type=pathlib.Path, required=True)
    parser.add_argument("--temporary", type=pathlib.Path, required=True)
    parser.add_argument("--launcher", required=True)
    parser.add_argument("--result", type=pathlib.Path, required=True)
    parser.add_argument("--version", required=True)
    args = parser.parse_args()
    deadline = time.monotonic() + 60
    while process_exists(args.wait_pid) and time.monotonic() < deadline:
        time.sleep(0.2)
    success = False
    error = ""
    try:
        if process_exists(args.wait_pid):
            raise RuntimeError("Clipman did not close before the update timeout.")
        completed = subprocess.run(
            [str(args.package / "install.sh")], cwd=args.package,
            text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
            timeout=120, check=False,
        )
        if completed.returncode != 0:
            raise RuntimeError((completed.stdout or "The installer failed.").strip()[-2000:])
        success = True
    except Exception as exception:
        error = str(exception)
    try:
        write_result(args.result, {"ok": success, "version": args.version, "error": error})
    except OSError:
        # A damaged result path must not strand Clipman in a closed state.
        pass
    try:
        relaunch(args.launcher)
    finally:
        shutil.rmtree(args.temporary, ignore_errors=True)
    return 0 if success else 1


if __name__ == "__main__":
    raise SystemExit(main())
