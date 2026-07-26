#!/bin/sh
set -eu

root="${XDG_DATA_HOME:-$HOME/.local/share}/clipman-linux"
applications="${XDG_DATA_HOME:-$HOME/.local/share}/applications"
icons="${XDG_DATA_HOME:-$HOME/.local/share}/icons/hicolor/256x256/apps"
metainfo="${XDG_DATA_HOME:-$HOME/.local/share}/metainfo"
mime="${XDG_DATA_HOME:-$HOME/.local/share}/mime/packages"
bin="$HOME/.local/bin"

missing=""
command -v python3 >/dev/null 2>&1 || missing="$missing python3"
command -v xdotool >/dev/null 2>&1 || missing="$missing xdotool"
python3 -c 'import gi; gi.require_version("Gtk", "4.0"); from gi.repository import Gtk' >/dev/null 2>&1 || missing="$missing GTK-4/PyGObject"
python3 -c 'import gi; gi.require_version("Gtk", "3.0"); gi.require_version("Keybinder", "3.0"); from gi.repository import Gtk, Keybinder' >/dev/null 2>&1 || missing="$missing Keybinder-3"
if [ -n "$missing" ]; then
    printf 'Clipman needs:%s\n' "$missing" >&2
    printf 'Arch: sudo pacman -S gtk4 python-gobject libkeybinder3 xdotool\n' >&2
    printf 'Debian/Ubuntu: sudo apt install gir1.2-gtk-4.0 gir1.2-keybinder-3.0 python3-gi xdotool\n' >&2
    printf 'Fedora: sudo dnf install gtk4 python3-gobject keybinder3 xdotool\n' >&2
    exit 1
fi

mkdir -p "$root/libexec" "$root/sounds" "$applications" "$icons" "$metainfo" "$mime" "$bin"
install -m 0755 clipman.py "$root/clipman.py"
install -m 0755 clipman-hotkeys.py "$root/clipman-hotkeys.py"
install -m 0755 clipman-updater.py "$root/clipman-updater.py"
install -m 0644 update_service.py VERSION BUILD_STAMP "$root/"
install -m 0755 clipman-linux "$bin/clipman-linux"
install -m 0755 libexec/clipman-gui-backend "$root/libexec/clipman-gui-backend"
install -m 0644 Manual.html LICENSE.txt "$root/"
install -m 0644 sounds/*.wav "$root/sounds/"
install -m 0644 me.onj.clipman.linux.desktop "$applications/"
install -m 0644 me.onj.clipman.linux.png "$icons/me.onj.clipman.linux.png"
install -m 0644 me.onj.clipman.linux.metainfo.xml "$metainfo/"
install -m 0644 me.onj.clipman.linux.xml "$mime/"

command -v update-desktop-database >/dev/null 2>&1 && update-desktop-database "$applications" >/dev/null 2>&1 || true
command -v update-mime-database >/dev/null 2>&1 && update-mime-database "${XDG_DATA_HOME:-$HOME/.local/share}/mime" >/dev/null 2>&1 || true
command -v gtk-update-icon-cache >/dev/null 2>&1 && gtk-update-icon-cache -f -t "${XDG_DATA_HOME:-$HOME/.local/share}/icons/hicolor" >/dev/null 2>&1 || true

printf 'Clipman installed. Open Clipman from the application menu or run: clipman-linux\n'
case ":$PATH:" in
    *":$bin:"*) ;;
    *) printf 'Your shell PATH does not include %s. The application-menu entry will still work.\n' "$bin" ;;
esac
