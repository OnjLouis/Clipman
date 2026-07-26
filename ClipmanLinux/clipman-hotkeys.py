#!/usr/bin/env python3
import argparse
import json
import signal
import sys
import threading

import gi

gi.require_version("Gtk", "3.0")
gi.require_version("Keybinder", "3.0")
from gi.repository import GLib, Gtk, Keybinder


def emit(value):
    print(json.dumps(value, separators=(",", ":")), flush=True)


def main():
    parser = argparse.ArgumentParser(add_help=False)
    parser.add_argument("--show", required=True)
    parser.add_argument("--toggle", required=True)
    parser.add_argument("--binding", action="append", default=[])
    args = parser.parse_args()

    Gtk.init([])
    Keybinder.init()
    loop = GLib.MainLoop()

    def activated(_keystring, action):
        emit({"event": "activated", "action": action})

    requested = [("show", args.show), ("toggle", args.toggle)]
    for value in args.binding:
        try:
            action, accelerator = value.split("\t", 1)
        except ValueError:
            continue
        if action and accelerator:
            requested.append((action, accelerator))
    registered = {}
    used = set()
    for action, accelerator in requested:
        success = accelerator not in used and bool(Keybinder.bind(accelerator, activated, action))
        registered[action] = success
        if success:
            used.add(accelerator)
    emit({"event": "ready", "registered": registered})

    def stop(_signum, _frame):
        GLib.idle_add(loop.quit)

    signal.signal(signal.SIGTERM, stop)
    signal.signal(signal.SIGINT, stop)

    def watch_parent():
        while sys.stdin.buffer.read(1):
            pass
        GLib.idle_add(loop.quit)

    threading.Thread(target=watch_parent, daemon=True).start()
    try:
        loop.run()
    finally:
        for action, accelerator in requested:
            if registered.get(action):
                Keybinder.unbind(accelerator)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
