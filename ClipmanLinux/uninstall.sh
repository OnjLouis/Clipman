#!/bin/sh
set -eu

data="${XDG_DATA_HOME:-$HOME/.local/share}"
config="${XDG_CONFIG_HOME:-$HOME/.config}"
rm -rf "$data/clipman-linux"
rm -f "$HOME/.local/bin/clipman-linux"
rm -f "$config/autostart/me.onj.clipman.linux.desktop"
rm -f "$data/applications/me.onj.clipman.linux.desktop"
rm -f "$data/icons/hicolor/256x256/apps/me.onj.clipman.linux.png"
rm -f "$data/metainfo/me.onj.clipman.linux.metainfo.xml"
rm -f "$data/mime/packages/me.onj.clipman.linux.xml"
command -v update-desktop-database >/dev/null 2>&1 && update-desktop-database "$data/applications" >/dev/null 2>&1 || true
command -v update-mime-database >/dev/null 2>&1 && update-mime-database "$data/mime" >/dev/null 2>&1 || true
command -v gtk-update-icon-cache >/dev/null 2>&1 && gtk-update-icon-cache -f -t "$data/icons/hicolor" >/dev/null 2>&1 || true
printf 'Clipman was removed. Your private configuration and encrypted cache were kept in ~/.clipman and ~/.config/clipman-linux.\n'
