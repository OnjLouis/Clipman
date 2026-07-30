#!/usr/bin/env python3
import json
import html
import base64
import binascii
import os
import pathlib
import re
import shutil
import subprocess
import sys
import threading
import time
import urllib.parse
from html.parser import HTMLParser

import gi

gi.require_version("Gtk", "4.0")
gi.require_version("Gdk", "4.0")
gi.require_version("Pango", "1.0")
from gi.repository import Gdk, Gio, GLib, Gtk, Pango
from update_service import UpdateError, find_update, stage_update


APP_ID = "me.onj.clipman.linux"
VERSION_FILE = pathlib.Path(__file__).resolve().parent / "VERSION"
BUILD_STAMP_FILE = pathlib.Path(__file__).resolve().parent / "BUILD_STAMP"
try:
    VERSION = VERSION_FILE.read_text(encoding="utf-8").strip()
except OSError:
    VERSION = "unknown"
try:
    BUILD_STAMP = BUILD_STAMP_FILE.read_text(encoding="utf-8").strip()
except OSError:
    BUILD_STAMP = "unknown"
DEFAULT_SHOW_HOTKEY = "<Control><Alt>backslash"
DEFAULT_TOGGLE_HOTKEY = "<Control><Alt>grave"
DEFAULT_HISTORY_TAB_ORDER = ["text", "links", "rich", "files"]
FILE_MANAGER_CLIPBOARD_PREFIXES = {
    "x-special/nautilus-clipboard",
    "x-special/gnome-copied-files",
    "x-special/mate-copied-files",
}
FILE_CLIPBOARD_MIME_TYPES = (
    "x-special/gnome-copied-files",
    "x-special/nautilus-clipboard",
    "x-special/mate-copied-files",
    "text/uri-list",
)
RICH_HTML_MIME_TYPES = ("text/html",)
RICH_RTF_MIME_TYPES = ("text/rtf", "application/rtf")
MAX_RICH_HTML_BYTES = 768 * 1024
MAX_RICH_RTF_BYTES = 1024 * 1024
MAX_RICH_COMBINED_BYTES = 1792 * 1024


def normalize_history_tab_order(values):
    result = []
    for value in values if isinstance(values, list) else []:
        normalized = str(value).strip().lower()
        if normalized in DEFAULT_HISTORY_TAB_ORDER and normalized not in result:
            result.append(normalized)
    result.extend(section for section in DEFAULT_HISTORY_TAB_ORDER if section not in result)
    return result


def move_history_tab_order(values, selected, direction, links_enabled, rich_text_enabled):
    order = normalize_history_tab_order(values)
    visible = [
        section for section in order
        if (section != "links" or links_enabled) and (section != "rich" or rich_text_enabled)
    ]
    try:
        selected_index = visible.index(selected)
    except ValueError:
        return None
    target_index = selected_index + (-1 if direction < 0 else 1)
    if direction == 0 or target_index < 0 or target_index >= len(visible):
        return None
    first, second = order.index(visible[selected_index]), order.index(visible[target_index])
    order[first], order[second] = order[second], order[first]
    return order


TRACKING_PARAMETERS = {
    "fbclid", "gclid", "dclid", "msclkid", "gbraid", "wbraid", "igshid", "mc_cid", "mc_eid",
    "mkt_tok", "vero_id", "_hsenc", "_hsmi", "yclid", "twclid", "li_fat_id", "sc_cid",
    "oly_anon_id", "oly_enc_id", "rb_clickid", "spm", "ref", "ref_src",
}
TEMPLATE_PRESETS = [
    ("Date, year/month/day", "{{year_full}}/{{month_num_padded}}/{{day_of_month_padded}}"),
    ("Date, day short-month year", "{{day_of_month_padded}} {{month_name_short}} {{year_full}}"),
    ("Date, short-month day, year", "{{month_name_short}} {{day_of_month_padded}}, {{year_full}}"),
    ("Today sentence", "Today is {{day_name_full}}, {{month_name_full}} {{day_of_month}}, {{year_full}}"),
    ("Operating system version", "{{os_name}} version {{os_version}}"),
]
TEMPLATE_VARIABLES = [
    ("Year, four digits", "{{year_full}}"), ("Year, two digits", "{{year_short}}"),
    ("Month name", "{{month_name_full}}"), ("Month name, short", "{{month_name_short}}"),
    ("Month number", "{{month_num}}"), ("Month number, two digits", "{{month_num_padded}}"),
    ("Day of month", "{{day_of_month}}"), ("Day of month, two digits", "{{day_of_month_padded}}"),
    ("Day name", "{{day_name_full}}"), ("Day name, short", "{{day_name_short}}"),
    ("Hour, 24-hour clock", "{{hour_24}}"), ("Hour, 24-hour clock, two digits", "{{hour_24_padded}}"),
    ("Hour, 12-hour clock", "{{hour_12}}"), ("Hour, 12-hour clock, two digits", "{{hour_12_padded}}"),
    ("Minute", "{{minute}}"), ("Minute, two digits", "{{minute_padded}}"),
    ("Second", "{{second}}"), ("Second, two digits", "{{second_padded}}"),
    ("UTC offset", "{{utc_offset}}"), ("Time zone", "{{time_zone}}"),
    ("Time zone, short", "{{time_zone_short}}"), ("Operating system name", "{{os_name}}"),
    ("Operating system version", "{{os_version}}"), ("User name", "{{username}}"),
]
PLAIN_URL = re.compile(r"https?://[^\s<>'\"]+", re.IGNORECASE)
SENSITIVE_PRESETS = (
    ("credit-card", "Credit card number"),
    ("us-ssn", "US Social Security number"),
    ("international-phone", "International phone number"),
    ("api-token", "Long API key or token"),
    ("software-license-key", "Software license key"),
    ("us-drivers-license", "US driver license, approximate"),
)
GLib.set_prgname("Clipman")
GLib.set_application_name("Clipman")


def config_home():
    value = os.environ.get("XDG_CONFIG_HOME")
    return pathlib.Path(value) if value else pathlib.Path.home() / ".config"


def data_home():
    value = os.environ.get("XDG_DATA_HOME")
    return pathlib.Path(value) if value else pathlib.Path.home() / ".local" / "share"


def entry_summary(entry, limit=240):
    text = " ".join(str(entry.get("text", "")).split())
    if len(text) > limit:
        text = text[:limit]
    name = str(entry.get("name", "")).strip()
    if name and text:
        return f"{name}: {text}"
    return name or text or str(entry.get("display", "Empty entry"))


def normalize_rich_text(value):
    if not isinstance(value, dict):
        return None
    html_fragment = str(value.get("html_fragment") or "")
    if len(html_fragment.encode("utf-8")) > MAX_RICH_HTML_BYTES:
        html_fragment = ""
    rtf_base64 = str(value.get("rtf_base64") or "")
    try:
        rtf = base64.b64decode(rtf_base64, validate=True) if rtf_base64 else b""
    except (binascii.Error, ValueError, TypeError):
        rtf, rtf_base64 = b"", ""
    if len(rtf) > MAX_RICH_RTF_BYTES:
        rtf, rtf_base64 = b"", ""
    if len(html_fragment.encode("utf-8")) + len(rtf) > MAX_RICH_COMBINED_BYTES:
        if html_fragment:
            rtf, rtf_base64 = b"", ""
        else:
            return None
    if not html_fragment and not rtf:
        return None
    preferred = str(value.get("preferred_format") or "").casefold()
    if ((preferred == "html" and not html_fragment) or
            (preferred == "rtf" and not rtf) or
            preferred not in ("html", "rtf")):
        preferred = "html" if html_fragment else "rtf"
    return {
        "version": 1,
        "html_fragment": html_fragment,
        "rtf_base64": rtf_base64,
        "preferred_format": preferred.title(),
    }


class SafeHTMLBufferParser(HTMLParser):
    TAGS = {
        "b": "bold", "strong": "bold", "i": "italic", "em": "italic",
        "u": "underline", "s": "strike", "del": "strike", "code": "code",
        "pre": "code", "h1": "heading", "h2": "heading", "h3": "heading",
    }
    BLOCK_START = {"p", "div", "section", "article", "blockquote", "pre", "h1", "h2", "h3", "h4", "h5", "h6", "ul", "ol", "table", "tr"}
    BLOCK_END = BLOCK_START | {"li"}

    def __init__(self, buffer):
        super().__init__(convert_charrefs=True)
        self.buffer = buffer
        self.active = []
        self.ignored_depth = 0

    def _insert(self, text):
        if not text:
            return
        iterator = self.buffer.get_end_iter()
        tags = [self.buffer.get_tag_table().lookup(name) for name in self.active]
        tags = [tag for tag in tags if tag is not None]
        if tags:
            self.buffer.insert_with_tags(iterator, text, *tags)
        else:
            self.buffer.insert(iterator, text)

    def _newline(self):
        text = self.buffer.get_text(self.buffer.get_start_iter(), self.buffer.get_end_iter(), True)
        if text and not text.endswith("\n"):
            self._insert("\n")

    def handle_starttag(self, tag, _attrs):
        tag = tag.casefold()
        if tag in ("script", "style", "noscript"):
            self.ignored_depth += 1
            return
        if self.ignored_depth:
            return
        if tag in self.BLOCK_START:
            self._newline()
        if tag == "br":
            self._insert("\n")
        elif tag == "li":
            self._newline(); self._insert("- ")
        elif tag in ("td", "th"):
            text = self.buffer.get_text(self.buffer.get_start_iter(), self.buffer.get_end_iter(), True)
            if text and not text.endswith(("\n", "\t")):
                self._insert("\t")
        mapped = self.TAGS.get(tag)
        if mapped:
            self.active.append(mapped)

    def handle_endtag(self, tag):
        tag = tag.casefold()
        if tag in ("script", "style", "noscript"):
            self.ignored_depth = max(0, self.ignored_depth - 1)
            return
        if self.ignored_depth:
            return
        mapped = self.TAGS.get(tag)
        if mapped and mapped in self.active:
            index = len(self.active) - 1 - self.active[::-1].index(mapped)
            self.active.pop(index)
        if tag in self.BLOCK_END:
            self._newline()

    def handle_data(self, data):
        if not self.ignored_depth:
            self._insert(data)


def populate_safe_rich_buffer(buffer, rich_text, fallback):
    rich_text = normalize_rich_text(rich_text)
    if not rich_text or not rich_text.get("html_fragment"):
        buffer.set_text(fallback)
        return False
    buffer.create_tag("bold", weight=Pango.Weight.BOLD)
    buffer.create_tag("italic", style=Pango.Style.ITALIC)
    buffer.create_tag("underline", underline=Pango.Underline.SINGLE)
    buffer.create_tag("strike", strikethrough=True)
    buffer.create_tag("code", family="monospace")
    buffer.create_tag("heading", weight=Pango.Weight.BOLD, scale=1.2)
    try:
        SafeHTMLBufferParser(buffer).feed(rich_text["html_fragment"])
    except (ValueError, TypeError):
        buffer.set_text(fallback)
        return False
    rendered = buffer.get_text(buffer.get_start_iter(), buffer.get_end_iter(), True).strip()
    if not rendered:
        buffer.set_text(fallback)
        return False
    return True


def file_event_summary(event):
    files = event.get("files") or []
    fallback = pathlib.Path(files[0]).name if files else "File event"
    parts = [str(event.get("display") or fallback)]
    if event.get("operation"):
        parts.append("Operation: " + str(event["operation"]))
    parts.append(f"Files: {event.get('file_count', len(event.get('files', [])))}")
    if event.get("source"):
        parts.append("Source: " + str(event["source"]))
    if event.get("device"):
        parts.append("Device: " + str(event["device"]))
    return "; ".join(parts)


def is_file_manager_clipboard_payload(text):
    lines = [line.strip() for line in text.replace("\r\n", "\n").replace("\r", "\n").split("\n") if line.strip()]
    if not lines:
        return False
    first_line = lines[0].casefold()
    if first_line in FILE_MANAGER_CLIPBOARD_PREFIXES:
        return True
    return first_line in ("copy", "cut") and len(lines) > 1 and all(line.casefold().startswith("file://") for line in lines[1:])


def is_companion_file_clipboard_text(text, file_signature):
    if not file_signature or file_signature[0] != "files":
        return False
    lines = [line.strip() for line in str(text).replace("\r\n", "\n").replace("\r", "\n").split("\n") if line.strip()]
    expected = list(file_signature[1])
    return bool(lines) and sorted(lines, key=str.casefold) == sorted(expected, key=str.casefold)


def parse_file_clipboard_payload(text, mime_type="text/uri-list"):
    lines = text.replace("\r\n", "\n").replace("\r", "\n").split("\n")
    operation = "Copy"
    if lines and lines[0].strip().casefold() in FILE_MANAGER_CLIPBOARD_PREFIXES:
        mime_type = lines.pop(0).strip().casefold()
    marker_payload = lines and lines[0].strip().casefold() in ("copy", "cut") and any(line.strip().casefold().startswith("file://") for line in lines[1:])
    if (mime_type in FILE_MANAGER_CLIPBOARD_PREFIXES or marker_payload) and lines and lines[0].strip().casefold() in ("copy", "cut"):
        marker = lines.pop(0).strip().casefold()
        operation = "Move" if marker == "cut" else "Copy"
    paths = []
    for line in lines:
        value = line.strip()
        if not value or value.startswith("#"):
            continue
        file = Gio.File.new_for_uri(value)
        path = file.get_path()
        if path and path not in paths:
            paths.append(path)
    return paths, operation


def is_standalone_link(text):
    value = str(text or "").strip()
    if not value or any(character.isspace() for character in value):
        return False
    candidate = value if "://" in value else "https://" + value
    parsed = urllib.parse.urlsplit(candidate)
    return parsed.scheme.casefold() in ("http", "https", "clipman") and bool(parsed.netloc)


def active_application_info():
    if os.environ.get("XDG_SESSION_TYPE", "").casefold() == "wayland":
        return "", ""
    try:
        root = subprocess.run(
            ["xprop", "-root", "_NET_ACTIVE_WINDOW"], capture_output=True, text=True,
            timeout=1, check=False,
        ).stdout
        match = re.search(r"0x[0-9a-fA-F]+", root)
        if not match or match.group(0) == "0x0":
            return "", ""
        window_id = match.group(0)
        details = subprocess.run(
            ["xprop", "-id", window_id, "_NET_WM_PID", "WM_CLASS"],
            capture_output=True, text=True, timeout=1, check=False,
        ).stdout
        pid_match = re.search(r"_NET_WM_PID\([^)]*\)\s*=\s*(\d+)", details)
        class_match = re.search(r'WM_CLASS\([^)]*\)\s*=\s*(?:"[^"]*",\s*)?"([^"]+)"', details)
        process = ""
        if pid_match:
            process = subprocess.run(
                ["ps", "-p", pid_match.group(1), "-o", "comm="],
                capture_output=True, text=True, timeout=1, check=False,
            ).stdout.strip()
        return process or (class_match.group(1) if class_match else ""), window_id
    except (OSError, subprocess.SubprocessError):
        return "", ""


def passes_luhn(value):
    digits = [int(character) for character in value if character.isdigit()]
    if not 13 <= len(digits) <= 19:
        return False
    total = 0
    parity = len(digits) % 2
    for index, digit in enumerate(digits):
        if index % 2 == parity:
            digit *= 2
            if digit > 9:
                digit -= 9
        total += digit
    return total % 10 == 0


def sensitive_data_match(text, enabled_ids):
    value = str(text or "")
    if not value or not enabled_ids:
        return ""
    stripped = value.strip()
    if is_standalone_link(stripped) and urllib.parse.urlsplit(stripped).scheme.casefold() in ("http", "https"):
        return ""
    enabled = set(enabled_ids)
    if "credit-card" in enabled:
        for match in re.finditer(r"(?<![A-Za-z0-9])(?:\d[ -]?){12,18}\d(?![A-Za-z0-9])", value):
            if passes_luhn(match.group(0)):
                return "Credit card number"
    if "us-ssn" in enabled and re.search(r"(?<!\d)\d{3}[ -]?\d{2}[ -]?\d{4}(?!\d)", value):
        return "US Social Security number"
    if "international-phone" in enabled:
        for match in re.finditer(r"(?<![A-Za-z0-9])\+\d[\d\s().-]{6,20}\d(?![A-Za-z0-9])", value):
            count = sum(character.isdigit() for character in match.group(0))
            if 8 <= count <= 15:
                return "International phone number"
    if "api-token" in enabled and re.search(r"(?<![A-Za-z0-9])[A-Za-z0-9]{32,}(?![A-Za-z0-9])", value):
        return "Long API key or token"
    if "software-license-key" in enabled and re.search(r"(?<![A-Za-z0-9])(?:[A-Za-z0-9]{5}-){4}[A-Za-z0-9]{5}(?![A-Za-z0-9])", value):
        return "Software license key"
    if "us-drivers-license" in enabled and re.search(r"(?<![A-Za-z0-9])[A-Za-z]\d{6,13}(?![A-Za-z0-9])", value):
        return "US driver license, approximate"
    return ""


def normalize_line_endings(text, target):
    return text.replace("\r\n", "\n").replace("\r", "\n").replace("\u0085", "\n").replace("\u2028", "\n").replace("\u2029", "\n").replace("\n", target)


def single_line_text(text):
    return " ".join(text.replace("\r", " ").replace("\n", " ").replace("\t", " ").split())


def remove_blank_lines(text):
    return "\r\n".join(line for line in normalize_line_endings(text, "\n").split("\n") if line.strip())


def html_to_text(text):
    value = re.sub(r"(?is)<(script|style|head|noscript)\b[^>]*>.*?</\1>", " ", text)
    value = re.sub(r"(?i)<\s*br\s*/?\s*>", "\n", value)
    value = re.sub(r"(?i)</\s*(p|div|h[1-6]|li|tr|table|section|article|header|footer|blockquote)\s*>", "\n", value)
    value = html.unescape(re.sub(r"<[^>]+>", " ", value))
    value = re.sub(r"[ \t\f\v]+", " ", value)
    value = re.sub(r" *\n *", "\n", value)
    return re.sub(r"\n{3,}", "\n\n", value).strip()


def clean_tracking_url(value, sharing=False):
    try:
        parsed = urllib.parse.urlsplit(value.replace("&amp;", "&"))
    except ValueError:
        return value
    if parsed.scheme.casefold() not in ("http", "https") or not parsed.query:
        return value
    host = (parsed.hostname or "").casefold()
    kept = []
    changed = False
    for part in parsed.query.split("&"):
        name = urllib.parse.unquote(part.split("=", 1)[0]).strip().casefold()
        remove = name.startswith(("utm_", "hsa_")) or name in TRACKING_PARAMETERS
        if sharing and (name == "si" or ((host == "youtu.be" or host == "youtube.com" or host.endswith(".youtube.com")) and name in {"t", "time_continue", "start", "pp", "feature"})):
            remove = True
        if remove:
            changed = True
        elif part:
            kept.append(part)
    if not changed:
        return value
    return urllib.parse.urlunsplit((parsed.scheme, parsed.netloc, parsed.path, "&".join(kept), parsed.fragment))


def clean_tracking_text(text, sharing=False):
    def replace(match):
        value = match.group(0)
        trailing = ""
        while value and value[-1] in ".,);]!?":
            trailing = value[-1] + trailing
            value = value[:-1]
        return clean_tracking_url(value, sharing) + trailing
    return PLAIN_URL.sub(replace, text)


class HotkeyEntry(Gtk.Entry):
    MODIFIERS = (
        Gdk.ModifierType.CONTROL_MASK | Gdk.ModifierType.ALT_MASK |
        Gdk.ModifierType.SHIFT_MASK | Gdk.ModifierType.SUPER_MASK |
        Gdk.ModifierType.META_MASK | Gdk.ModifierType.HYPER_MASK
    )
    MODIFIER_KEYS = {
        Gdk.KEY_Control_L, Gdk.KEY_Control_R, Gdk.KEY_Alt_L, Gdk.KEY_Alt_R,
        Gdk.KEY_Shift_L, Gdk.KEY_Shift_R, Gdk.KEY_Super_L, Gdk.KEY_Super_R,
        Gdk.KEY_Meta_L, Gdk.KEY_Meta_R, Gdk.KEY_Hyper_L, Gdk.KEY_Hyper_R,
    }
    BLOCKED_KEYS = {
        Gdk.KEY_Escape, Gdk.KEY_Tab, Gdk.KEY_ISO_Left_Tab, Gdk.KEY_Return,
        Gdk.KEY_KP_Enter, Gdk.KEY_space, Gdk.KEY_BackSpace, Gdk.KEY_Delete,
    }

    def __init__(self, accelerator, label):
        super().__init__()
        self.accelerator = ""
        self.update_property(
            [Gtk.AccessibleProperty.LABEL, Gtk.AccessibleProperty.DESCRIPTION],
            [label, "Press a shortcut. Delete or Backspace clears it. Two modifiers are required except with F1 through F12, Grave, or Backslash."],
        )
        controller = Gtk.EventControllerKey()
        controller.connect("key-pressed", self._key_pressed)
        self.add_controller(controller)
        self.set_accelerator(accelerator)

    def set_accelerator(self, accelerator):
        valid, keyval, modifiers = Gtk.accelerator_parse(accelerator) if accelerator else (False, 0, 0)
        if not valid:
            self.accelerator = ""
            self.set_text("")
            return
        self.accelerator = Gtk.accelerator_name(keyval, modifiers)
        self.set_text(Gtk.accelerator_get_label(keyval, modifiers))

    def get_accelerator(self):
        return self.accelerator

    @classmethod
    def is_safe(cls, keyval, modifiers):
        keyval = Gdk.keyval_to_lower(keyval)
        if keyval in cls.BLOCKED_KEYS or keyval in cls.MODIFIER_KEYS:
            return False
        masks = (
            Gdk.ModifierType.CONTROL_MASK, Gdk.ModifierType.ALT_MASK,
            Gdk.ModifierType.SHIFT_MASK, Gdk.ModifierType.SUPER_MASK,
            Gdk.ModifierType.META_MASK, Gdk.ModifierType.HYPER_MASK,
        )
        count = sum(1 for mask in masks if modifiers & mask)
        if count >= 2:
            return True
        special = Gdk.KEY_F1 <= keyval <= Gdk.KEY_F12 or keyval in (Gdk.KEY_grave, Gdk.KEY_backslash)
        return count == 1 and special

    def _key_pressed(self, _controller, keyval, _keycode, state):
        modifiers = state & self.MODIFIERS
        if keyval in (Gdk.KEY_Tab, Gdk.KEY_ISO_Left_Tab, Gdk.KEY_Escape):
            return False
        if keyval in (Gdk.KEY_Delete, Gdk.KEY_BackSpace) and not modifiers:
            self.set_accelerator("")
            return True
        if keyval in self.MODIFIER_KEYS:
            return True
        if not self.is_safe(keyval, modifiers):
            self.error_bell()
            return True
        keyval = Gdk.keyval_to_lower(keyval)
        self.set_accelerator(Gtk.accelerator_name(keyval, modifiers))
        return True


class Preferences:
    def __init__(self):
        self.path = config_home() / "clipman-linux" / "settings.json"
        defaults = {
            "monitor_clipboard": True,
            "capture_on_start": False,
            "play_sounds": True,
            "last_section": "text",
            "history_tab_order": DEFAULT_HISTORY_TAB_ORDER.copy(),
            "last_received_section": "text",
            "last_preferences_tab": 0,
            "sort_mode": "manual",
            "file_sort_mode": "manual",
            "file_sort_descending": False,
            "auto_remove_unavailable_file_history": False,
            "auto_copy_remote_text": False,
            "dynamic_history_mode": False,
            "paste_after_enter": False,
            "links_history_enabled": True,
            "rich_text_history_enabled": False,
            "save_list_position": True,
            "auto_group_by_app": False,
            "auto_remove_url_tracking": False,
            "keep_duplicate_entries": False,
            "confirm_deletions": True,
            "ignored_applications": [],
            "sensitive_data_mode": "off",
            "sensitive_data_presets": [],
            "quick_paste_bindings": {},
            "secret_hotkeys": {},
            "run_at_startup": False,
            "show_history_hotkey": DEFAULT_SHOW_HOTKEY,
            "toggle_monitoring_hotkey": DEFAULT_TOGGLE_HOTKEY,
            "update_check_frequency": "never",
            "install_updates_silently": False,
            "last_update_check_unix_ms": 0,
        }
        self.values = defaults.copy()
        try:
            loaded = json.loads(self.path.read_text(encoding="utf-8"))
            if isinstance(loaded, dict):
                for key in defaults:
                    if key in loaded:
                        self.values[key] = loaded[key]
        except (OSError, ValueError):
            pass
        for key in ("monitor_clipboard", "capture_on_start", "play_sounds", "run_at_startup", "install_updates_silently", "file_sort_descending", "auto_remove_unavailable_file_history", "auto_copy_remote_text", "dynamic_history_mode", "paste_after_enter", "links_history_enabled", "rich_text_history_enabled", "save_list_position", "auto_group_by_app", "auto_remove_url_tracking", "keep_duplicate_entries", "confirm_deletions"):
            if not isinstance(self.values[key], bool):
                self.values[key] = defaults[key]
        if self.values["last_section"] not in ("text", "links", "rich", "files"):
            self.values["last_section"] = defaults["last_section"]
        self.values["history_tab_order"] = normalize_history_tab_order(self.values["history_tab_order"])
        if self.values["last_received_section"] not in ("text", "links", "rich", "files"):
            self.values["last_received_section"] = defaults["last_received_section"]
        if not isinstance(self.values["last_preferences_tab"], int) or not 0 <= self.values["last_preferences_tab"] <= 5:
            self.values["last_preferences_tab"] = 0
        if self.values["sort_mode"] not in ("manual", "newest", "oldest", "text", "group", "device"):
            self.values["sort_mode"] = defaults["sort_mode"]
        if self.values["file_sort_mode"] not in ("manual", "time", "files", "name", "operation", "source"):
            self.values["file_sort_mode"] = defaults["file_sort_mode"]
        if self.values["update_check_frequency"] not in ("never", "startup", "hourly", "daily"):
            self.values["update_check_frequency"] = defaults["update_check_frequency"]
        if not isinstance(self.values["last_update_check_unix_ms"], int) or self.values["last_update_check_unix_ms"] < 0:
            self.values["last_update_check_unix_ms"] = 0
        if not isinstance(self.values["ignored_applications"], list):
            self.values["ignored_applications"] = []
        self.values["ignored_applications"] = [str(value).strip() for value in self.values["ignored_applications"] if str(value).strip()]
        if self.values["sensitive_data_mode"] not in ("off", "exclude"):
            self.values["sensitive_data_mode"] = "off"
        valid_presets = {item[0] for item in SENSITIVE_PRESETS}
        if not isinstance(self.values["sensitive_data_presets"], list):
            self.values["sensitive_data_presets"] = []
        self.values["sensitive_data_presets"] = [value for value in self.values["sensitive_data_presets"] if value in valid_presets]
        if not isinstance(self.values["quick_paste_bindings"], dict):
            self.values["quick_paste_bindings"] = {}
        cleaned_bindings = {}
        for entry_id, binding in self.values["quick_paste_bindings"].items():
            if not isinstance(entry_id, str) or not isinstance(binding, dict):
                continue
            hotkey, mode = binding.get("hotkey"), binding.get("mode")
            valid, keyval, modifiers = Gtk.accelerator_parse(hotkey) if isinstance(hotkey, str) else (False, 0, 0)
            if valid and HotkeyEntry.is_safe(keyval, modifiers) and mode in ("restore", "keep", "copy"):
                cleaned_bindings[entry_id] = {"hotkey": Gtk.accelerator_name(keyval, modifiers), "mode": mode}
        self.values["quick_paste_bindings"] = cleaned_bindings
        if not isinstance(self.values["secret_hotkeys"], dict):
            self.values["secret_hotkeys"] = {}
        cleaned_secret_hotkeys = {}
        for secret_id, hotkey in self.values["secret_hotkeys"].items():
            valid, keyval, modifiers = Gtk.accelerator_parse(hotkey) if isinstance(hotkey, str) else (False, 0, 0)
            if isinstance(secret_id, str) and valid and HotkeyEntry.is_safe(keyval, modifiers):
                cleaned_secret_hotkeys[secret_id] = Gtk.accelerator_name(keyval, modifiers)
        self.values["secret_hotkeys"] = cleaned_secret_hotkeys
        for key in ("show_history_hotkey", "toggle_monitoring_hotkey"):
            valid, _keyval, _modifiers = Gtk.accelerator_parse(self.values[key]) if isinstance(self.values[key], str) else (False, 0, 0)
            if not valid:
                self.values[key] = defaults[key]

    def save(self):
        self.path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
        temp = self.path.with_suffix(".tmp")
        temp.write_text(json.dumps(self.values, indent=2) + "\n", encoding="utf-8")
        temp.chmod(0o600)
        temp.replace(self.path)


class Backend:
    def __init__(self, on_ready, on_failure):
        self.on_ready = on_ready
        self.on_failure = on_failure
        self.next_id = 1
        self.callbacks = {}
        self.lock = threading.Lock()
        executable = os.environ.get("CLIPMAN_GUI_BACKEND")
        if not executable:
            adjacent = pathlib.Path(__file__).resolve().parent / "libexec" / "clipman-gui-backend"
            executable = str(adjacent if adjacent.exists() else "clipman-gui-backend")
        try:
            self.process = subprocess.Popen(
                [executable], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                stderr=subprocess.PIPE, text=True, encoding="utf-8", bufsize=1,
            )
        except OSError as error:
            self.process = None
            GLib.idle_add(self.on_failure, f"Could not start Clipman's history service: {error}")
            return
        threading.Thread(target=self._read_stdout, daemon=True).start()
        threading.Thread(target=self._read_stderr, daemon=True).start()

    def _read_stdout(self):
        try:
            for line in self.process.stdout:
                try:
                    message = json.loads(line)
                except ValueError:
                    continue
                GLib.idle_add(self._deliver, message)
        finally:
            if self.process.poll() not in (0, None):
                GLib.idle_add(self.on_failure, "Clipman's history service stopped unexpectedly.")

    def _read_stderr(self):
        for _line in self.process.stderr:
            pass

    def _deliver(self, message):
        request_id = message.get("id", 0)
        if request_id == 0 and message.get("ok"):
            self.on_ready(message.get("result", {}))
            return False
        callback = self.callbacks.pop(request_id, None)
        if callback:
            callback(message)
        return False

    def call(self, action, params=None, callback=None):
        if not self.process or self.process.poll() is not None:
            if callback:
                callback({"ok": False, "error": "Clipman's history service is not running."})
            return
        with self.lock:
            request_id = self.next_id
            self.next_id += 1
            if callback:
                self.callbacks[request_id] = callback
            message = {"id": request_id, "action": action, "params": params or {}}
            try:
                self.process.stdin.write(json.dumps(message) + "\n")
                self.process.stdin.flush()
            except OSError:
                self.callbacks.pop(request_id, None)
                if callback:
                    callback({"ok": False, "error": "Clipman's history service is unavailable."})

    def close(self):
        if self.process and self.process.poll() is None:
            self.call("shutdown")


class GlobalHotkeys:
    def __init__(self, application):
        self.application = application
        self.process = None
        self.generation = 0
        self.show_registered = False
        self.toggle_registered = False
        self.quick_registered = {}

    def register(self, show_accelerator, toggle_accelerator, quick_bindings=None, secret_bindings=None):
        self.stop()
        self.generation += 1
        generation = self.generation
        helper = pathlib.Path(__file__).resolve().parent / "clipman-hotkeys.py"
        command = [sys.executable, str(helper), "--show", show_accelerator, "--toggle", toggle_accelerator]
        for entry_id, accelerator in (quick_bindings or {}).items():
            command.extend(["--binding", "quick:" + entry_id + "\t" + accelerator])
        for secret_id, accelerator in (secret_bindings or {}).items():
            command.extend(["--binding", "secret:" + secret_id + "\t" + accelerator])
        try:
            self.process = subprocess.Popen(
                command,
                stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                text=True, encoding="utf-8", bufsize=1,
            )
        except OSError as error:
            self.application.hotkey_service_failed(f"Global hotkeys could not start: {error}")
            return
        process = self.process
        threading.Thread(target=self._read_stdout, args=(process, generation), daemon=True).start()
        threading.Thread(target=self._read_stderr, args=(process,), daemon=True).start()

    def _read_stdout(self, process, generation):
        try:
            for line in process.stdout:
                try: message = json.loads(line)
                except ValueError: continue
                GLib.idle_add(self._deliver, message, generation)
        finally:
            if generation == self.generation and process.poll() not in (0, None):
                GLib.idle_add(self.application.hotkey_service_failed, "Global hotkeys stopped unexpectedly.")

    @staticmethod
    def _read_stderr(process):
        for _line in process.stderr:
            pass

    def _deliver(self, message, generation):
        if generation != self.generation:
            return False
        event = message.get("event")
        if event == "ready":
            registered = message.get("registered", {})
            self.show_registered = bool(registered.get("show"))
            self.toggle_registered = bool(registered.get("toggle"))
            self.quick_registered = {key[6:]: bool(value) for key, value in registered.items() if key.startswith("quick:")}
            self.application.hotkey_registration_changed()
        elif event == "activated":
            self.application.handle_global_hotkey(message.get("action"))
        return False

    def summary(self):
        if self.show_registered and self.toggle_registered:
            return "Both global hotkeys are registered."
        missing = []
        if not self.show_registered: missing.append("Show History")
        if not self.toggle_registered: missing.append("Toggle Monitoring")
        return "Not registered: " + ", ".join(missing) + "."

    def stop(self):
        self.generation += 1
        self.show_registered = False
        self.toggle_registered = False
        self.quick_registered = {}
        process, self.process = self.process, None
        if process and process.poll() is None:
            try: process.stdin.close()
            except OSError: pass
            try: process.wait(timeout=2)
            except subprocess.TimeoutExpired:
                process.terminate()
                try: process.wait(timeout=2)
                except subprocess.TimeoutExpired:
                    process.kill()
                    process.wait(timeout=2)


class SoundPlayer:
    def __init__(self, preferences):
        self.preferences = preferences
        self.root = pathlib.Path(__file__).resolve().parent

    def play(self, name):
        if not self.preferences.values["play_sounds"]:
            return
        override = config_home() / "clipman-linux" / "sounds" / f"{name}.wav"
        bundled = self.root / "sounds" / f"{name}.wav"
        sound = override if override.exists() else bundled
        if not sound.exists() and name != "skip":
            sound = override.with_name("skip.wav") if override.with_name("skip.wav").exists() else bundled.with_name("skip.wav")
        player = shutil.which("pw-play") or shutil.which("paplay") or shutil.which("aplay")
        if player and sound.exists():
            subprocess.Popen([player, str(sound)], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)


class ClipmanApplication(Gtk.Application):
    def __init__(self):
        super().__init__(application_id=APP_ID, flags=Gio.ApplicationFlags.HANDLES_OPEN)
        self.preferences = Preferences()
        self.sounds = SoundPlayer(self.preferences)
        self.backend = None
        self.window = None
        self.entries = []
        self.file_events = []
        self.groups = []
        self.history_filters = []
        self.active_history_filter = ("group", "All")
        self.section = self.preferences.values["last_section"]
        self.current_revision = ""
        self.machine_name = ""
        self.remote_entry_stamps = {}
        self.remote_baseline_ready = False
        self.offline = False
        self.busy = False
        self.last_clipboard_text = None
        self.last_clipboard_files = None
        self.last_file_clipboard_monotonic = 0.0
        self.last_clipboard_signature = None
        self.clipboard_baseline_ready = False
        self.own_clipboard_text = None
        self.own_clipboard_files = None
        self.clipboard_read_busy = False
        self.clipboard_change_source = 0
        self.poll_source = 0
        self.clipboard = None
        self.clipboard_changed_handler = 0
        self.update_poll_source = 0
        self.startup_update_source = 0
        self.update_busy = False
        self.pending_open_file = None
        self.backend_is_ready = False
        self.backend_configured = False
        self.ready_for_history = False
        self.capture_current_clipboard = self.preferences.values["capture_on_start"]
        self.clipboard_source_application = ""
        self.previous_window_id = ""
        self.type_buffer = ""
        self.type_deadline = 0.0
        self.received_history_section_pending = False
        self.hotkeys = GlobalHotkeys(self)

    def do_startup(self):
        Gtk.Application.do_startup(self)
        self._install_actions()

    def do_activate(self):
        if not self.window or not self.window.get_visible():
            _application, self.previous_window_id = active_application_info()
        if not self.window:
            self._build_window()
            self.backend = Backend(self._backend_ready, self._fatal_error)
            self._register_hotkeys()
            self._consume_update_result()
        self.window.present()

    def do_open(self, files, _n_files, _hint):
        if files:
            self.pending_open_file = files[0].get_path()
        self.activate()
        if self.backend_is_ready:
            self._open_pending_connection(configuring=not self.backend_configured)

    def do_shutdown(self):
        for source in (self.poll_source, self.clipboard_change_source, self.update_poll_source, self.startup_update_source):
            if source:
                GLib.source_remove(source)
        if self.backend:
            self.backend.close()
        if self.clipboard and self.clipboard_changed_handler:
            self.clipboard.disconnect(self.clipboard_changed_handler)
            self.clipboard_changed_handler = 0
        self.hotkeys.stop()
        self.preferences.save()
        Gtk.Application.do_shutdown(self)

    def _install_actions(self):
        actions = {
            "import": lambda *_: self.import_history(False),
            "import-replace": lambda *_: self.import_history(True),
            "export": self.export_history,
            "clear-history": self.clear_text_history,
            "add-clipboard": self.add_clipboard,
            "new": self.new_entry,
            "copy": self.copy_selected,
            "copy-close": lambda *_: self.copy_selected(close=True),
            "select-all": self.select_all,
            "cut": self.cut_selected,
            "paste-after": self.paste_after_selected,
            "push": self.push_selected,
            "find": lambda *_: self.search.grab_focus(),
            "find-next": lambda *_: self.repeat_find(False),
            "find-previous": lambda *_: self.repeat_find(True),
            "close": lambda *_: self.window.set_visible(False),
            "properties": self.edit_selected,
            "quick-assign": self.edit_selected_quick_paste,
            "group-entry": self.group_selected_entry,
            "details": self.view_selected,
            "go-to-file": self.go_to_selected_file,
            "copy-paths": self.copy_selected_file_paths,
            "delete": self.delete_selected,
            "pin": self.toggle_pin,
            "move-up": lambda *_: self.move_entry(-1),
            "move-down": lambda *_: self.move_entry(1),
            "move-tab-left": lambda *_: self.move_history_tab(-1),
            "move-tab-right": lambda *_: self.move_history_tab(1),
            "text": lambda *_: self.switch_section("text"),
            "links": lambda *_: self.switch_section("links"),
            "rich": lambda *_: self.switch_section("rich"),
            "files": lambda *_: self.switch_section("files"),
            "clear-file-history": self.clear_file_history,
            "remove-unavailable-files": self.remove_unavailable_file_history,
            "plain-text": lambda *_: self.copy_selected(close=False),
            "trim": lambda *_: self.transform_selected(lambda value: value.strip(), "Trimmed selected entry."),
            "single-line": lambda *_: self.transform_selected(single_line_text, "Converted selected entry to one line."),
            "remove-blank-lines": lambda *_: self.transform_selected(remove_blank_lines, "Removed blank lines from selected entry."),
            "remove-tracking": lambda *_: self.transform_selected(lambda value: clean_tracking_text(value, False), "Removed URL tracking from selected entry."),
            "clean-sharing": lambda *_: self.transform_selected(lambda value: clean_tracking_text(value, True), "Cleaned selected link for sharing."),
            "line-crlf": lambda *_: self.transform_selected(lambda value: normalize_line_endings(value, "\r\n"), "Converted selected entry to Windows CRLF line endings."),
            "line-lf": lambda *_: self.transform_selected(lambda value: normalize_line_endings(value, "\n"), "Converted selected entry to Unix LF line endings."),
            "line-cr": lambda *_: self.transform_selected(lambda value: normalize_line_endings(value, "\r"), "Converted selected entry to old Mac CR line endings."),
            "uppercase": lambda *_: self.transform_selected(str.upper, "Uppercased selected entry."),
            "lowercase": lambda *_: self.transform_selected(str.lower, "Lowercased selected entry."),
            "html-encode": lambda *_: self.transform_selected(html.escape, "HTML-encoded selected entry."),
            "html-decode": lambda *_: self.transform_selected(html.unescape, "HTML-decoded selected entry."),
            "html-text": lambda *_: self.transform_selected(html_to_text, "Converted selected HTML to readable text."),
            "url-encode": lambda *_: self.transform_selected(lambda value: urllib.parse.quote(value, safe=""), "URL-encoded selected entry."),
            "url-decode": lambda *_: self.transform_selected(urllib.parse.unquote, "URL-decoded selected entry."),
            "top": lambda *_: self.select_edge(True),
            "bottom": lambda *_: self.select_edge(False),
            "preferences": self.show_preferences,
            "open-settings": self.open_settings_folder,
            "toggle-monitoring": self.toggle_monitoring,
            "manual": self.open_manual,
            "check-updates": lambda *_: self.check_for_updates(True),
            "version-history": self.open_version_history,
            "project": self.open_project,
            "contact": lambda *_: self.open_uri("https://onj.me/contact"),
            "donate": lambda *_: self.open_uri("https://onj.me/donate"),
            "diagnostics": self.show_diagnostics,
            "secrets": self.show_secrets,
            "about": self.show_about,
            "quit": lambda *_: self.quit(),
        }
        self.action_objects = {}
        for name, handler in actions.items():
            action = Gio.SimpleAction.new(name, None)
            action.connect("activate", handler)
            self.add_action(action)
            self.action_objects[name] = action
        group_action = Gio.SimpleAction.new("group", GLib.VariantType.new("s"))
        group_action.connect("activate", self._select_group_action)
        self.add_action(group_action)
        device_filter_action = Gio.SimpleAction.new("device-filter", GLib.VariantType.new("s"))
        device_filter_action.connect("activate", self._select_device_filter_action)
        self.add_action(device_filter_action)
        quick_target_action = Gio.SimpleAction.new("quick-target", GLib.VariantType.new("s"))
        quick_target_action.connect("activate", self._select_quick_paste_target)
        self.add_action(quick_target_action)
        for mode in ("manual", "newest", "oldest", "text", "group", "device", "time", "files", "name", "operation", "source"):
            action = Gio.SimpleAction.new("sort-" + mode, None)
            action.connect("activate", lambda _action, _parameter, value=mode: self.set_sort(value))
            self.add_action(action)
        accelerators = {
            "app.import": ["<Control>i"], "app.export": ["<Control>e"],
            "app.new": ["<Control>n"],
            "app.select-all": ["<Control>a"],
            "app.copy-close": ["Return"], "app.close": ["Escape"],
            "app.copy": ["<Control>c"], "app.cut": ["<Control>x"],
            "app.paste-after": ["<Control>v"], "app.push": ["<Control>p"],
            "app.find": ["<Control>f"], "app.find-next": ["F3"], "app.find-previous": ["<Shift>F3"],
            "app.properties": ["F2"],
            "app.group-entry": ["<Control>g"],
            "app.details": ["F4"], "app.delete": ["Delete"],
            "app.pin": ["<Shift>Return"], "app.go-to-file": ["<Control>Return"],
            "app.clear-file-history": ["<Control>Delete"], "app.remove-unavailable-files": ["<Alt>Delete"],
            "app.move-up": ["<Alt>Up"], "app.move-down": ["<Alt>Down"],
            "app.move-tab-left": ["<Alt>Left"], "app.move-tab-right": ["<Alt>Right"],
            "app.text": ["<Alt>t"], "app.links": ["<Alt>l"], "app.rich": ["<Alt>r"], "app.files": ["<Alt>i"],
            "app.top": ["<Control>Home"], "app.bottom": ["<Control>End"],
            "app.preferences": ["<Control>comma"], "app.quit": ["<Control>q"],
            "app.secrets": ["<Control><Shift>e"],
            "app.manual": ["F1"], "app.check-updates": ["<Shift>F1"], "app.project": ["<Control>F1"],
            "app.diagnostics": ["<Alt>F1"],
            "app.plain-text": ["<Control><Shift>c"], "app.trim": ["<Control><Shift>t"],
            "app.single-line": ["<Control><Shift>l"], "app.remove-blank-lines": ["<Control><Shift>b"],
            "app.remove-tracking": ["<Control><Shift>r"], "app.clean-sharing": ["<Control><Shift>s"],
            "app.html-text": ["<Control><Shift>h"], "app.url-encode": ["<Control><Shift>u"],
        }
        for action, keys in accelerators.items():
            self.set_accels_for_action(action, keys)

    def _build_window(self):
        self.window = Gtk.ApplicationWindow(application=self, title="Clipman")
        self.window.set_default_size(780, 620)
        self.window.connect("close-request", self._hide_window)

        root = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=6)
        root.set_margin_top(8); root.set_margin_bottom(8); root.set_margin_start(8); root.set_margin_end(8)
        self.window.set_child(root)

        self.menu_bar = Gtk.PopoverMenuBar.new_from_model(self._menu_model())
        root.append(self.menu_bar)

        self.section_tabs = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=0)
        self.section_tabs.add_css_class("linked")
        self.section_tabs.set_accessible_role(Gtk.AccessibleRole.TAB_LIST)
        self.section_tabs.update_property([Gtk.AccessibleProperty.LABEL], ["History sections"])
        root.append(self.section_tabs)
        self.section_buttons = {}
        self.updating_section_tabs = False
        section_labels = {
            "text": ("Text", "Alt+T"),
            "links": ("Links", "Alt+L"),
            "rich": ("Rich Text", "Alt+R"),
            "files": ("Files", "Alt+I"),
        }
        first_button = None
        for section, (label, shortcut) in section_labels.items():
            button = Gtk.ToggleButton(label=label)
            button.set_accessible_role(Gtk.AccessibleRole.TAB)
            button.update_property([Gtk.AccessibleProperty.LABEL], [label + " history"])
            button.set_tooltip_text(label + " history (" + shortcut + ")")
            if first_button is None:
                first_button = button
            else:
                button.set_group(first_button)
            button.connect("toggled", self._section_tab_toggled, section)
            key_controller = Gtk.EventControllerKey()
            key_controller.connect("key-pressed", self._section_tab_key_pressed)
            button.add_controller(key_controller)
            self.section_tabs.append(button)
            self.section_buttons[section] = button

        toolbar = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=6)
        root.append(toolbar)
        self.search = Gtk.SearchEntry(placeholder_text="Search clipboard history")
        self.search.update_property([Gtk.AccessibleProperty.LABEL], ["Search clipboard history"])
        self.search.set_hexpand(True)
        self.search.connect("search-changed", lambda *_: self.rebuild_list())
        self.search.connect("next-match", lambda *_: self.move_selection(1))
        self.search.connect("previous-match", lambda *_: self.move_selection(-1))
        toolbar.append(self.search)
        self.group_model = Gtk.StringList.new(["All"])
        self.group_picker = Gtk.DropDown(model=self.group_model)
        self.group_picker.set_enable_search(True)
        self.group_picker.set_tooltip_text("Filter by group or device")
        self.group_picker.update_property([Gtk.AccessibleProperty.LABEL], ["Filter by group or device"])
        self.group_picker.connect("notify::selected", self._history_filter_changed)
        self.group_label = Gtk.Label(label="_Filter:", use_underline=True)
        self.group_label.set_mnemonic_widget(self.group_picker)
        toolbar.append(self.group_label)
        toolbar.append(self.group_picker)
        self.scroller = Gtk.ScrolledWindow(vexpand=True, hexpand=True)
        self.scroller.set_policy(Gtk.PolicyType.AUTOMATIC, Gtk.PolicyType.AUTOMATIC)
        root.append(self.scroller)
        self.listbox = Gtk.ListBox(selection_mode=Gtk.SelectionMode.MULTIPLE, activate_on_single_click=False)
        self.listbox.set_show_separators(True)
        self.listbox.connect("row-activated", lambda *_: self.copy_selected(close=True))
        self.listbox.connect("selected-rows-changed", lambda *_: self._update_action_states())
        self.scroller.set_child(self.listbox)

        self.status = Gtk.Label(label="Starting Clipman...", xalign=0, accessible_role=Gtk.AccessibleRole.STATUS)
        self.status.set_wrap(True)
        root.append(self.status)
        self._add_key_controller()

    def _menu_model(self):
        menu = Gio.Menu()
        file_menu = Gio.Menu(); file_menu.append("_Import...", "app.import"); file_menu.append("Import and _replace...", "app.import-replace"); file_menu.append("_Export...", "app.export"); file_menu.append("_Add Clipboard", "app.add-clipboard"); file_menu.append("_New Entry", "app.new"); file_menu.append("Clear text _history...", "app.clear-history"); file_menu.append("_Close", "app.close"); file_menu.append("_Quit", "app.quit")
        self.edit_menu = Gio.Menu()
        self.groups_menu = Gio.Menu()
        self.actions_menu = Gio.Menu()
        self.quick_paste_menu = Gio.Menu()
        view = Gio.Menu(); view.append("_Text History", "app.text"); view.append("_Links History", "app.links"); view.append("_Rich Text History", "app.rich"); view.append("File H_istory", "app.files"); view.append("Move tab l_eft", "app.move-tab-left"); view.append("Move tab ri_ght", "app.move-tab-right"); view.append("Go to T_op", "app.top"); view.append("Go to _Bottom", "app.bottom")
        self.sort_menu = Gio.Menu(); view.append_submenu("_Sort", self.sort_menu)
        options = Gio.Menu(); options.append("_Preferences", "app.preferences"); options.append("S_ecrets", "app.secrets"); options.append("_Open settings folder", "app.open-settings"); options.append("_Toggle monitoring", "app.toggle-monitoring")
        help_menu = Gio.Menu(); help_menu.append("_Manual", "app.manual"); help_menu.append("_Check for Updates...", "app.check-updates"); help_menu.append("_Version History", "app.version-history"); help_menu.append("_Project page", "app.project"); help_menu.append("Con_tact", "app.contact"); help_menu.append("_Donate", "app.donate"); help_menu.append("Dia_gnostics", "app.diagnostics"); help_menu.append("_About Clipman", "app.about")
        menu.append_submenu("_File", file_menu); menu.append_submenu("_Edit", self.edit_menu); menu.append_submenu("Grou_ps", self.groups_menu); menu.append_submenu("_Quick Paste", self.quick_paste_menu); menu.append_submenu("_Actions", self.actions_menu); menu.append_submenu("_View", view); menu.append_submenu("_Options", options); menu.append_submenu("_Help", help_menu)
        self._populate_section_menus()
        self._populate_quick_paste_menu()
        return menu

    def _populate_quick_paste_menu(self):
        if not hasattr(self, "quick_paste_menu"):
            return
        self.quick_paste_menu.remove_all()
        entries = {entry.get("id"): entry for entry in self.entries}
        bindings = self.preferences.values["quick_paste_bindings"]
        assigned = [(entry_id, binding, entries.get(entry_id)) for entry_id, binding in bindings.items() if entries.get(entry_id)]
        assigned.sort(key=lambda item: entry_summary(item[2]).casefold())
        if not assigned:
            item = Gio.MenuItem.new("_No targets assigned", None); self.quick_paste_menu.append_item(item); return
        for entry_id, binding, entry in assigned:
            label = entry_summary(entry, 80).replace("_", "__") + " - " + Gtk.accelerator_get_label(*Gtk.accelerator_parse(binding["hotkey"])[1:])
            item = Gio.MenuItem.new(label, "app.quick-target")
            item.set_attribute_value("target", GLib.Variant("s", entry_id))
            self.quick_paste_menu.append_item(item)

    def _populate_section_menus(self):
        self.edit_menu.remove_all(); self.actions_menu.remove_all(); self.sort_menu.remove_all()
        if getattr(self, "section", "text") == "files":
            for label, action in (
                ("_Restore files to clipboard", "copy-close"), ("Copy file _paths", "copy-paths"),
                ("Pin or unp_in", "pin"), ("Go to _file", "go-to-file"),
                ("_View event details", "details"), ("S_elect all", "select-all"), ("_Delete selected", "delete"),
                ("Remove _unavailable events", "remove-unavailable-files"),
                ("Clear file _history", "clear-file-history"),
            ):
                self.edit_menu.append(label, "app." + action)
            sort_items = (("_Manual Order", "manual"), ("_Newest First", "newest"), ("_Oldest First", "oldest"), ("_File count", "files"), ("N_ame", "name"), ("O_peration", "operation"), ("_Source application", "source"))
        else:
            for label, action in (
                ("Copy and c_lose", "copy-close"), ("_Copy", "copy"), ("Cu_t", "cut"),
                ("Paste _after selected", "paste-after"), ("_Group entry", "group-entry"),
                ("Entry _properties", "properties"), ("Set as _quick-paste target", "quick-assign"),
                ("P_ush to other devices", "push"),
                ("_View full text", "details"), ("Pin or unp_in", "pin"),
                ("_Delete selected", "delete"), ("S_elect all", "select-all"), ("_Find...", "find"),
                ("Find _next", "find-next"), ("Find previou_s", "find-previous"),
            ):
                self.edit_menu.append(label, "app." + action)
            self._populate_text_actions()
            sort_items = (("_Manual Order", "manual"), ("_Newest First", "newest"), ("_Oldest First", "oldest"), ("_Text", "text"), ("_Group", "group"), ("_Device", "device"))
        for label, mode in sort_items:
            self.sort_menu.append(label, "app.sort-" + mode)

    def _populate_text_actions(self):
        for label, action in (
            ("Copy as plain _text", "plain-text"), ("T_rim whitespace", "trim"),
            ("Convert to _single line", "single-line"), ("Remove _blank lines", "remove-blank-lines"),
            ("Remove URL trac_king", "remove-tracking"), ("Clean link for sharin_g", "clean-sharing"),
        ):
            self.actions_menu.append(label, "app." + action)
        line_endings = Gio.Menu(); line_endings.append("_Windows CRLF", "app.line-crlf"); line_endings.append("_Unix LF", "app.line-lf"); line_endings.append("_Old Mac CR", "app.line-cr")
        self.actions_menu.append_submenu("Line _endings", line_endings)
        for label, action in (
            ("_Uppercase", "uppercase"), ("_Lowercase", "lowercase"),
            ("HTML enc_ode", "html-encode"), ("_HTML decode", "html-decode"),
            ("HTML to readable te_xt", "html-text"), ("URL e_ncode", "url-encode"),
            ("URL _decode", "url-decode"),
        ):
            self.actions_menu.append(label, "app." + action)

    def _update_action_states(self):
        if not hasattr(self, "action_objects"):
            return
        entries = self.selected_entries()
        entry = entries[0] if entries else None
        selected = bool(entries)
        one_selected = len(entries) == 1
        files = self.section == "files"
        writable_text = not files and not self.offline
        available_files = any(pathlib.Path(path).exists() for item in entries for path in item.get("files", []))
        one_available_file = bool(entry and len([path for path in entry.get("files", []) if pathlib.Path(path).exists()]) == 1)
        any_pinned = any(item.get("pinned", False) for item in entries)
        states = {
            "copy": selected and not files, "copy-close": selected and (not files or available_files),
            "copy-paths": files and selected, "cut": selected and writable_text and not any_pinned,
            "paste-after": writable_text and one_selected, "push": selected and writable_text,
            "properties": one_selected and not files, "quick-assign": one_selected and writable_text,
            "group-entry": selected and writable_text,
            "details": one_selected, "go-to-file": files and one_selected and one_available_file,
            "delete": selected and (files or writable_text) and not any_pinned,
            "pin": selected and (files or writable_text), "move-up": one_selected and (files or writable_text),
            "move-down": one_selected and (files or writable_text), "new": writable_text,
            "add-clipboard": files or writable_text, "clear-history": writable_text,
            "import": writable_text, "import-replace": writable_text, "export": not files,
            "select-all": bool(self.visible_entries()), "find": True, "find-next": True, "find-previous": True,
            "clear-file-history": files, "remove-unavailable-files": files,
        }
        for name in (
            "plain-text", "trim", "single-line", "remove-blank-lines", "remove-tracking", "clean-sharing",
            "line-crlf", "line-lf", "line-cr", "uppercase", "lowercase", "html-encode", "html-decode",
            "html-text", "url-encode", "url-decode",
        ):
            states[name] = selected and writable_text
        for name, enabled in states.items():
            action = self.action_objects.get(name)
            if action:
                action.set_enabled(bool(enabled))
        links_action = self.action_objects.get("links")
        if links_action:
            links_action.set_enabled(self.preferences.values["links_history_enabled"])
        rich_action = self.action_objects.get("rich")
        if rich_action:
            rich_action.set_enabled(self.preferences.values["rich_text_history_enabled"])
        group_action = self.lookup_action("group")
        if group_action:
            group_action.set_enabled(writable_text)

    def _add_key_controller(self):
        controller = Gtk.EventControllerKey()
        controller.set_propagation_phase(Gtk.PropagationPhase.CAPTURE)
        controller.connect("key-pressed", self._key_pressed)
        self.window.add_controller(controller)

    def _key_pressed(self, _controller, keyval, _keycode, state):
        if keyval in (Gdk.KEY_Tab, Gdk.KEY_ISO_Left_Tab) and state & Gdk.ModifierType.CONTROL_MASK:
            self.cycle_section(-1 if state & Gdk.ModifierType.SHIFT_MASK else 1)
            return True
        direct_modifiers = state & (
            Gdk.ModifierType.CONTROL_MASK | Gdk.ModifierType.ALT_MASK |
            Gdk.ModifierType.SHIFT_MASK | Gdk.ModifierType.SUPER_MASK
        )
        if direct_modifiers == Gdk.ModifierType.ALT_MASK:
            key = Gdk.keyval_to_lower(keyval)
            if key in (Gdk.KEY_t, Gdk.KEY_l, Gdk.KEY_r, Gdk.KEY_i):
                self.switch_section({Gdk.KEY_t: "text", Gdk.KEY_l: "links", Gdk.KEY_r: "rich", Gdk.KEY_i: "files"}[key])
                return True
            if key == Gdk.KEY_g and self.section != "files":
                self.group_picker.grab_focus()
                return True
        if keyval in (Gdk.KEY_Tab, Gdk.KEY_ISO_Left_Tab):
            self.move_tab_focus(-1 if keyval == Gdk.KEY_ISO_Left_Tab or state & Gdk.ModifierType.SHIFT_MASK else 1)
            return True
        command_modifiers = state & (
            Gdk.ModifierType.CONTROL_MASK | Gdk.ModifierType.ALT_MASK |
            Gdk.ModifierType.SHIFT_MASK | Gdk.ModifierType.SUPER_MASK
        )
        if not command_modifiers and keyval == Gdk.KEY_F2:
            self.edit_selected(); return True
        if not command_modifiers and keyval == Gdk.KEY_F4:
            self.view_selected(); return True
        if not command_modifiers and keyval == Gdk.KEY_Delete and self._focus_is_in_history():
            self.delete_selected(); return True
        if keyval in (Gdk.KEY_Return, Gdk.KEY_KP_Enter) and self._focus_is_in_history():
            primary = state & (Gdk.ModifierType.CONTROL_MASK | Gdk.ModifierType.ALT_MASK | Gdk.ModifierType.SHIFT_MASK | Gdk.ModifierType.SUPER_MASK)
            if primary == Gdk.ModifierType.SHIFT_MASK:
                self.toggle_pin(); return True
            if primary == Gdk.ModifierType.CONTROL_MASK and self.section == "files":
                self.go_to_selected_file(); return True
            if not primary:
                self.copy_selected(close=True); return True
        if keyval == Gdk.KEY_Escape:
            self.window.set_visible(False)
            return True
        if keyval == Gdk.KEY_f and state & Gdk.ModifierType.CONTROL_MASK:
            self.search.grab_focus(); return True
        if keyval in (Gdk.KEY_F3,) and not self.search.has_focus():
            if not self.search.get_text(): self.search.grab_focus()
            else: self.move_selection(-1 if state & Gdk.ModifierType.SHIFT_MASK else 1)
            return True
        if keyval == Gdk.KEY_Menu or (keyval == Gdk.KEY_F10 and state & Gdk.ModifierType.SHIFT_MASK):
            row = self.selected_row()
            if row:
                self._show_context_menu(None, 1, 12, 12, row)
            return True
        if keyval == Gdk.KEY_BackSpace and self._focus_is_in_history():
            self.select_first_normal(); return True
        if keyval in (Gdk.KEY_Up, Gdk.KEY_Down) and not state & (
            Gdk.ModifierType.CONTROL_MASK | Gdk.ModifierType.ALT_MASK |
            Gdk.ModifierType.SHIFT_MASK | Gdk.ModifierType.SUPER_MASK
        ) and self._focus_is_in_history():
            self.move_selection(-1 if keyval == Gdk.KEY_Up else 1)
            return True
        if keyval in (Gdk.KEY_Home, Gdk.KEY_End, Gdk.KEY_Page_Up, Gdk.KEY_Page_Down) and self._focus_is_in_history():
            if keyval == Gdk.KEY_Home: self.select_edge(True)
            elif keyval == Gdk.KEY_End: self.select_edge(False)
            else: self.move_selection(-10 if keyval == Gdk.KEY_Page_Up else 10)
            return True
        if state & Gdk.ModifierType.CONTROL_MASK and Gdk.KEY_0 <= keyval <= Gdk.KEY_9:
            number = 10 if keyval == Gdk.KEY_0 else keyval - Gdk.KEY_0
            self.copy_pinned_number(number, bool(state & Gdk.ModifierType.SHIFT_MASK))
            return True
        if state & Gdk.ModifierType.ALT_MASK and Gdk.KEY_0 <= keyval <= Gdk.KEY_9:
            position = 9 if keyval == Gdk.KEY_0 else keyval - Gdk.KEY_1
            if 0 <= position < len(self.groups):
                try: index = [(item[0], item[1]) for item in self.history_filters].index(("group", self.groups[position]))
                except ValueError: return True
                self.group_picker.set_selected(index)
            return True
        focus = self.window.get_focus()
        editable = isinstance(focus, (Gtk.Entry, Gtk.SearchEntry, Gtk.PasswordEntry, Gtk.TextView))
        blocked = state & (Gdk.ModifierType.CONTROL_MASK | Gdk.ModifierType.ALT_MASK | Gdk.ModifierType.SUPER_MASK)
        unicode_value = Gdk.keyval_to_unicode(keyval)
        character = chr(unicode_value) if unicode_value else ""
        if character and not blocked and not editable:
            self.type_to_entry(character)
            return True
        return False

    def _focus_is_in_history(self):
        focus = self.window.get_focus()
        while focus:
            if focus is self.listbox:
                return True
            focus = focus.get_parent()
        return False

    def move_tab_focus(self, direction):
        controls = [
            self.section_buttons[self.section], self.search, self.group_picker,
            self.listbox,
        ]
        if self.section == "files":
            controls.remove(self.group_picker)
        focus = self.window.get_focus()
        current = -1
        while focus:
            if focus in controls:
                current = controls.index(focus)
                break
            focus = focus.get_parent()
        target = controls[(current + direction) % len(controls)]
        if target is self.listbox:
            self.focus_history()
        else:
            target.grab_focus()

    def _backend_ready(self, state):
        self.backend_is_ready = True
        self.backend_configured = bool(state.get("configured"))
        if not state.get("configured"):
            if not self._open_pending_connection(configuring=True):
                self.show_setup()
        elif state.get("needs_password"):
            self.show_unlock()
        else:
            self.refresh(True)
            self._open_pending_connection()
        self._start_timers()
        self._schedule_update_checks()

    def _start_timers(self):
        if self.poll_source: GLib.source_remove(self.poll_source)
        self.poll_source = GLib.timeout_add_seconds(2, self._poll)
        if self.clipboard and self.clipboard_changed_handler:
            self.clipboard.disconnect(self.clipboard_changed_handler)
        self.clipboard = self.window.get_display().get_clipboard()
        self.clipboard_changed_handler = self.clipboard.connect("changed", self._clipboard_changed)
        GLib.idle_add(self._initial_clipboard_read)

    def _poll(self):
        if self.ready_for_history and not self.busy and self.backend:
            self.refresh(False)
        self._poll_clipboard()
        return GLib.SOURCE_CONTINUE

    def _initial_clipboard_read(self):
        formats = self.clipboard.get_formats()
        if not formats.get_mime_types() and not formats.get_gtypes():
            self.clipboard_baseline_ready = True
            self.capture_current_clipboard = False
            return GLib.SOURCE_REMOVE
        self._poll_clipboard()
        return GLib.SOURCE_REMOVE

    def _clipboard_changed(self, *_args):
        if self.clipboard_change_source:
            GLib.source_remove(self.clipboard_change_source)
        self.clipboard_change_source = GLib.timeout_add(100, self._poll_changed_clipboard)

    def _poll_changed_clipboard(self):
        self.clipboard_change_source = 0
        self._poll_clipboard()
        return GLib.SOURCE_REMOVE

    def _poll_clipboard(self):
        if not self.ready_for_history or not self.preferences.values["monitor_clipboard"] or not self.window:
            return GLib.SOURCE_CONTINUE
        if self.clipboard_change_source:
            return GLib.SOURCE_CONTINUE
        clipboard = self.window.get_display().get_clipboard()
        if self.clipboard_read_busy:
            return GLib.SOURCE_CONTINUE
        self.clipboard_read_busy = True
        self.clipboard_source_application, _window_id = active_application_info()
        mime_type = next((mime for mime in FILE_CLIPBOARD_MIME_TYPES if clipboard.get_formats().contain_mime_type(mime)), None)
        if mime_type:
            clipboard.read_async([mime_type], GLib.PRIORITY_DEFAULT, None, self._clipboard_files_read, False)
        else:
            clipboard.read_text_async(None, self._clipboard_read, None)
        return GLib.SOURCE_CONTINUE

    def _clipboard_read(self, clipboard, result, _data):
        try: text = clipboard.read_text_finish(result)
        except GLib.Error:
            self.clipboard_read_busy = False
            return
        if text is not None and is_file_manager_clipboard_payload(text):
            self.clipboard_read_busy = False
            mime_type = text.replace("\r\n", "\n").split("\n", 1)[0].strip().casefold()
            paths, operation = parse_file_clipboard_payload(text, mime_type)
            self._capture_file_paths(clipboard, paths, operation, mime_type, False)
            return
        self._read_rich_clipboard(clipboard, text, self._process_clipboard_text)

    def _read_rich_clipboard(self, clipboard, text, callback):
        if not self.preferences.values["rich_text_history_enabled"]:
            callback(clipboard, text, None)
            return
        formats = clipboard.get_formats()
        mime_types = []
        html_type = next((value for value in RICH_HTML_MIME_TYPES if formats.contain_mime_type(value)), None)
        rtf_type = next((value for value in RICH_RTF_MIME_TYPES if formats.contain_mime_type(value)), None)
        if html_type: mime_types.append(("html", html_type, MAX_RICH_HTML_BYTES))
        if rtf_type: mime_types.append(("rtf", rtf_type, MAX_RICH_RTF_BYTES))
        if not mime_types:
            callback(clipboard, text, None)
            return
        state = {"clipboard": clipboard, "text": text, "callback": callback, "pending": mime_types, "html": "", "rtf": b""}
        self._read_next_rich_format(state)

    def _read_next_rich_format(self, state):
        if not state["pending"]:
            payload = normalize_rich_text({
                "html_fragment": state["html"],
                "rtf_base64": base64.b64encode(state["rtf"]).decode("ascii") if state["rtf"] else "",
                "preferred_format": "Html" if state["html"] else "Rtf",
            })
            state["callback"](state["clipboard"], state["text"], payload)
            return
        kind, mime_type, limit = state["pending"].pop(0)
        state["current"] = (kind, limit)
        state["clipboard"].read_async([mime_type], GLib.PRIORITY_DEFAULT, None, self._rich_stream_ready, state)

    def _rich_stream_ready(self, clipboard, result, state):
        try:
            stream, _mime_type = clipboard.read_finish(result)
            if stream is None:
                raise ValueError("Clipboard returned no rich-text stream")
            kind, limit = state["current"]
            stream.read_bytes_async(limit + 1, GLib.PRIORITY_DEFAULT, None, self._rich_bytes_ready, (stream, state, kind, limit))
            return
        except (GLib.Error, ValueError):
            self._read_next_rich_format(state)

    def _rich_bytes_ready(self, stream, result, rich_state):
        _stream, state, kind, limit = rich_state
        try:
            data = bytes(stream.read_bytes_finish(result).get_data())
            if len(data) <= limit:
                if kind == "html":
                    state["html"] = data.rstrip(b"\x00").decode("utf-8", errors="replace")
                else:
                    state["rtf"] = data.rstrip(b"\x00")
        except (GLib.Error, ValueError):
            pass
        finally:
            try: stream.close(None)
            except GLib.Error: pass
        self._read_next_rich_format(state)

    def _process_clipboard_text(self, clipboard, text, rich_text):
        self.clipboard_read_busy = False
        first = not self.clipboard_baseline_ready
        self.clipboard_baseline_ready = True
        if text is None:
            if first: self.capture_current_clipboard = False
            return
        if (
            time.monotonic() - self.last_file_clipboard_monotonic <= 3.0
            and is_companion_file_clipboard_text(text, self.last_clipboard_files)
        ):
            return
        normalized_rich = normalize_rich_text(rich_text)
        signature = (
            "text", text,
            normalized_rich.get("html_fragment", "") if normalized_rich else "",
            normalized_rich.get("rtf_base64", "") if normalized_rich else "",
        )
        if signature == self.last_clipboard_signature:
            return
        self.last_clipboard_signature = signature
        self.last_clipboard_text = text
        if first:
            capture = self.capture_current_clipboard
            self.capture_current_clipboard = False
            if not capture:
                return
        if text == self.own_clipboard_text:
            self.own_clipboard_text = None
            return
        if text.strip():
            source = self.clipboard_source_application
            ignored = {value.casefold() for value in self.preferences.values["ignored_applications"]}
            if source and source.casefold() in ignored:
                self.sounds.play("skip")
                return
            if self.preferences.values["sensitive_data_mode"] == "exclude":
                match = sensitive_data_match(text, self.preferences.values["sensitive_data_presets"])
                if match:
                    self.sounds.play("exclude")
                    return
            self._put_text(text, quiet=True, automatic=True, source=source, rich_text=normalized_rich)

    def _clipboard_files_read(self, clipboard, result, force=False):
        try:
            stream, mime_type = clipboard.read_finish(result)
            if stream is None:
                raise ValueError("Clipboard returned no file-data stream")
            stream.read_bytes_async(
                1024 * 1024, GLib.PRIORITY_DEFAULT, None,
                self._clipboard_file_payload_read,
                (clipboard, mime_type, force),
            )
            return
        except (GLib.Error, ValueError):
            self.clipboard_read_busy = False
            if force: self.sounds.play("skip"); self.set_status("Clipboard file data could not be read.", True)
        return

    def _clipboard_file_payload_read(self, stream, result, state):
        clipboard, mime_type, force = state
        self.clipboard_read_busy = False
        try:
            payload = stream.read_bytes_finish(result).get_data().decode("utf-8", errors="strict")
        except (GLib.Error, UnicodeError, ValueError):
            if force: self.sounds.play("skip"); self.set_status("Clipboard file data could not be read.", True)
            return
        finally:
            try: stream.close(None)
            except GLib.Error: pass
        paths, operation = parse_file_clipboard_payload(payload, mime_type)
        self._capture_file_paths(clipboard, paths, operation, mime_type, force)

    def _capture_file_paths(self, clipboard, paths, operation, mime_type, force):
        if not paths:
            if force: self.sounds.play("skip"); self.set_status("Clipboard does not contain local files.", True)
            return
        signature = ("files", tuple(sorted(paths, key=str.casefold)), operation)
        self.last_clipboard_files = signature
        self.last_file_clipboard_monotonic = time.monotonic()
        if not force and signature == self.last_clipboard_signature:
            return
        first = not self.clipboard_baseline_ready
        self.clipboard_baseline_ready = True
        self.last_clipboard_signature = signature
        if first and not force:
            capture = self.capture_current_clipboard
            self.capture_current_clipboard = False
            if not capture:
                return
        if not force and signature == self.own_clipboard_files:
            self.own_clipboard_files = None
            return
        params = {
            "files": paths, "formats": [mime_type], "operation": operation,
            "source": ("Files" if force else self.clipboard_source_application) or "Files", "contains_text": clipboard.get_formats().contain_mime_type("text/plain"),
        }
        self.backend.call("file_add", params, lambda message: self._file_capture_response(message, force))

    def _file_capture_response(self, message, announce):
        if not message.get("ok"):
            if announce: self.show_error(message.get("error"))
            return
        self._history_response(message, False)
        self._remember_received_section("files")
        if self.preferences.values["auto_remove_unavailable_file_history"]:
            self.backend.call("file_remove_unavailable", {}, self._history_response)
        self.sounds.play("copy")
        if announce: self.set_status("Clipboard files added to file history.", True)

    def refresh(self, announce=False):
        if self.busy or not self.backend: return
        self.busy = True
        if announce: self.set_status("Refreshing clipboard history...")
        self.backend.call("refresh", {"force": announce}, lambda message: self._history_response(message, announce))

    def _history_response(self, message, announce=False):
        self.busy = False
        if not message.get("ok"):
            self.show_error(message.get("error", "History could not be loaded.")); return
        result = message.get("result", {})
        if "history" in result: result = result["history"]
        self.ready_for_history = True
        changed = result.get("changed", result.get("file_history_changed", False)) or ("revision" in result and result.get("revision") != self.current_revision)
        self.current_revision = result.get("revision", self.current_revision)
        if "offline" in result:
            self.offline = bool(result.get("offline"))
        history_changed = False
        if "entries" in result:
            incoming_entries = result.get("entries", [])
            self.machine_name = result.get("machine", self.machine_name)
            self._maybe_copy_remote_entry(incoming_entries)
            history_changed = incoming_entries != self.entries
            self.entries = incoming_entries
            self._set_groups(result.get("groups", []))
            valid_ids = {entry.get("id") for entry in incoming_entries}
            bindings = self.preferences.values["quick_paste_bindings"]
            cleaned = {entry_id: binding for entry_id, binding in bindings.items() if entry_id in valid_ids}
            if cleaned != bindings:
                self.preferences.values["quick_paste_bindings"] = cleaned
                self.preferences.save(); self._register_hotkeys()
            self._populate_quick_paste_menu()
        if "file_events" in result:
            incoming_file_events = result.get("file_events", [])
            history_changed = incoming_file_events != self.file_events or history_changed
            self.file_events = incoming_file_events
        if changed or history_changed or (not self.entries and not self.file_events):
            self.rebuild_list()
        rich_count = sum(1 for entry in self.entries if entry.get("rich_text"))
        plain_entries = [entry for entry in self.entries if not entry.get("rich_text")]
        text_count = sum(1 for entry in plain_entries if entry["section"] == "text")
        link_count = sum(1 for entry in plain_entries if entry["section"] == "links")
        prefix = "Offline read-only cache" if self.offline else "Updated"
        self.set_status(f"{prefix}: {len(self.entries)} entries, {text_count} text, {link_count} links, {rich_count} rich text, {len(self.file_events)} file events.", announce)

    def _maybe_copy_remote_entry(self, entries):
        stamps = {entry.get("id", ""): entry.get("created_unix_ms", 0) for entry in entries if entry.get("id")}
        if not self.remote_baseline_ready:
            self.remote_entry_stamps = stamps
            self.remote_baseline_ready = True
            return
        previous = self.remote_entry_stamps
        self.remote_entry_stamps = stamps
        if not self.preferences.values["auto_copy_remote_text"]:
            return
        candidates = [
            entry for entry in entries
            if entry.get("device") and entry.get("device") != self.machine_name
            and entry.get("created_unix_ms", 0) > previous.get(entry.get("id", ""), 0)
        ]
        if not candidates:
            return
        entry = max(candidates, key=lambda item: item.get("created_unix_ms", 0))
        if entry.get("is_template"):
            self.backend.call("resolve_template", {"id": entry["id"]}, lambda message: self._remote_template_result(message, entry))
        else:
            self._copy_remote_text(entry.get("text", ""), entry.get("device", "another device"), entry.get("rich_text"))

    def _remote_template_result(self, message, entry):
        if message.get("ok"):
            self._copy_remote_text(message["result"]["text"], entry.get("device", "another device"))

    def _copy_remote_text(self, text, device, rich_text=None):
        self._set_clipboard(text, rich_text)
        self.sounds.play("remote")
        self.set_status("Clipboard updated by " + device + ".", True)

    def _set_groups(self, groups):
        selected = self.selected_history_filter()
        reserved = ["All", "Pinned", "Normal", "Ungrouped"]
        reserved_keys = {value.casefold() for value in reserved}
        updated_groups = reserved + [group for group in groups if group.casefold() not in reserved_keys]
        devices = self._canonical_entry_labels("device")
        updated_filters = [("group", value, value) for value in reserved]
        updated_filters.extend(("group", value, value) for value in updated_groups[4:])
        if devices:
            updated_filters.append(("divider", "", "Devices"))
            updated_filters.extend(("device", value, value) for value in devices)
        if updated_groups == self.groups and updated_filters == self.history_filters:
            return
        self.groups = updated_groups
        self.history_filters = updated_filters
        self.group_model.splice(0, self.group_model.get_n_items(), [item[2] for item in self.history_filters])
        try: index = [(item[0], item[1]) for item in self.history_filters].index(selected)
        except ValueError: index = 0
        self.group_picker.set_selected(index)
        if hasattr(self, "groups_menu"):
            self.groups_menu.remove_all()
            for position, group in enumerate(self.groups):
                number = "0" if position == 9 else str(position + 1)
                escaped = group.replace("_", "__")
                label = f"_{number} {escaped}" if position < 10 else escaped
                item = Gio.MenuItem.new(label, "app.group")
                item.set_attribute_value("target", GLib.Variant("s", group))
                self.groups_menu.append_item(item)
            if devices:
                self.groups_menu.append("Devices", None)
                for device in devices:
                    item = Gio.MenuItem.new(device.replace("_", "__"), "app.device-filter")
                    item.set_attribute_value("target", GLib.Variant("s", device))
                    self.groups_menu.append_item(item)

    def _canonical_entry_labels(self, field):
        clusters = {}
        for entry in self.entries:
            label = entry.get(field, "").strip()
            if not label:
                continue
            spellings = clusters.setdefault(label.casefold(), {})
            stats = spellings.setdefault(label, {"count": 0, "latest": 0})
            stats["count"] += 1
            stats["latest"] = max(
                stats["latest"],
                entry.get("modified_unix_ms", 0),
                entry.get("last_used_unix_ms", 0),
                entry.get("created_unix_ms", 0),
            )
        result = []
        for spellings in clusters.values():
            result.append(sorted(
                spellings,
                key=lambda label: (-spellings[label]["count"], -spellings[label]["latest"], label),
            )[0])
        return sorted(result, key=str.casefold)

    def _history_filter_changed(self, *_args):
        index = self.group_picker.get_selected()
        if not self.history_filters or index >= len(self.history_filters):
            return
        item = self.history_filters[index]
        if item[0] == "divider":
            try:
                previous = [(choice[0], choice[1]) for choice in self.history_filters].index(self.active_history_filter)
            except ValueError:
                previous = 0
            self.group_picker.set_selected(previous)
            return
        self.active_history_filter = (item[0], item[1])
        self.rebuild_list()

    def _select_group_action(self, _action, parameter):
        if self.section == "files":
            self.sounds.play("skip"); self.set_status("Groups do not apply to file history.", True); return
        group = parameter.get_string()
        try: index = [(item[0], item[1]) for item in self.history_filters].index(("group", group))
        except ValueError: return
        self.group_picker.set_selected(index)
        self.rebuild_list(); self.focus_history()

    def _select_device_filter_action(self, _action, parameter):
        if self.section == "files":
            self.sounds.play("skip"); self.set_status("Device filters do not apply to file history.", True); return
        device = parameter.get_string()
        try: index = [(item[0], item[1]) for item in self.history_filters].index(("device", device))
        except ValueError: return
        self.group_picker.set_selected(index)
        self.rebuild_list(); self.focus_history()

    def _select_quick_paste_target(self, _action, parameter):
        entry_id = parameter.get_string()
        entry = next((item for item in self.entries if item.get("id") == entry_id), None)
        if not entry:
            self.sounds.play("skip"); return
        target = entry.get("section", "text")
        if entry.get("rich_text") and self.preferences.values["rich_text_history_enabled"]:
            target = "rich"
        if target == "links" and not self.preferences.values["links_history_enabled"]:
            target = "text"
        self.section = target
        self.group_picker.set_selected(0)
        self.search.set_text("")
        self.rebuild_list()
        row = self._row_for_entry_id(entry_id)
        if row:
            self.listbox.unselect_all(); self.listbox.select_row(row); row.grab_focus()
            self.set_status("Selected Quick Paste target. Press F2 to edit or remove its hotkey.", True)
            return

    def selected_history_filter(self):
        index = self.group_picker.get_selected() if hasattr(self, "group_picker") else 0
        if self.history_filters and index < len(self.history_filters):
            item = self.history_filters[index]
            if item[0] == "divider":
                return self.active_history_filter
            return item[0], item[1]
        return "group", "All"

    def visible_entries(self):
        query = self.search.get_text().casefold().strip()
        if self.section == "files":
            result = []
            for event in self.file_events:
                haystack = " ".join(event.get("files", []) + [event.get("display", ""), event.get("operation", ""), event.get("source", ""), event.get("device", "")]).casefold()
                if not query or query in haystack:
                    result.append(event)
            pinned = [event for event in result if event.get("pinned")]
            normal = [event for event in result if not event.get("pinned")]
            pinned.sort(key=lambda event: (event.get("manual_order", 0), -event.get("captured_unix_ms", 0)))
            mode = self.preferences.values["file_sort_mode"]
            descending = self.preferences.values["file_sort_descending"]
            if mode == "time": normal.sort(key=lambda event: event.get("captured_unix_ms", 0), reverse=descending)
            elif mode == "files": normal.sort(key=lambda event: (event.get("file_count", 0), event.get("display", "").casefold()), reverse=descending)
            elif mode == "name": normal.sort(key=lambda event: event.get("display", "").casefold(), reverse=descending)
            elif mode == "operation": normal.sort(key=lambda event: (event.get("operation", "").casefold(), event.get("display", "").casefold()), reverse=descending)
            elif mode == "source": normal.sort(key=lambda event: (event.get("source", "").casefold(), event.get("display", "").casefold()), reverse=descending)
            else: normal.sort(key=lambda event: (event.get("manual_order", 0), -event.get("captured_unix_ms", 0)), reverse=descending)
            return pinned + normal
        filter_kind, filter_value = self.selected_history_filter()
        result = []
        for entry in self.entries:
            entry_section = entry["section"]
            has_rich_text = bool(entry.get("rich_text"))
            if self.preferences.values["rich_text_history_enabled"]:
                if self.section == "rich":
                    if not has_rich_text: continue
                    entry_section = "rich"
                elif has_rich_text:
                    continue
            if entry_section == "links" and not self.preferences.values["links_history_enabled"]:
                entry_section = "text"
            if entry_section != self.section: continue
            if filter_kind == "device":
                if entry.get("device", "").casefold() != filter_value.casefold(): continue
            else:
                if filter_value == "Pinned" and not entry.get("pinned"): continue
                if filter_value == "Normal" and entry.get("pinned"): continue
                if filter_value == "Ungrouped" and entry.get("group"): continue
                if filter_value not in ("All", "Pinned", "Normal", "Ungrouped") and entry.get("group", "").casefold() != filter_value.casefold(): continue
            haystack = " ".join([entry.get("text", ""), entry.get("name", ""), entry.get("group", ""), entry.get("device", "")]).casefold()
            if query and query not in haystack: continue
            result.append(entry)
        pinned = [entry for entry in result if entry.get("pinned")]
        normal = [entry for entry in result if not entry.get("pinned")]
        mode = self.preferences.values["sort_mode"]
        if mode == "newest": normal.sort(key=lambda entry: entry.get("last_used_unix_ms", 0), reverse=True)
        elif mode == "oldest": normal.sort(key=lambda entry: entry.get("last_used_unix_ms", 0))
        elif mode == "text": normal.sort(key=lambda entry: entry.get("display", "").casefold())
        elif mode == "group": normal.sort(key=lambda entry: (entry.get("group", "").casefold(), entry.get("display", "").casefold()))
        elif mode == "device": normal.sort(key=lambda entry: (entry.get("device", "").casefold(), entry.get("display", "").casefold()))
        else: normal.sort(key=lambda entry: (entry.get("manual_order", 0), entry.get("created_unix_ms", 0)))
        pinned.sort(key=lambda entry: (entry.get("manual_order", 0), entry.get("created_unix_ms", 0)))
        return pinned + normal

    def rebuild_list(self):
        if not hasattr(self, "listbox"): return
        if self.section == "links" and not self.preferences.values["links_history_enabled"]:
            self.section = "text"
        if self.section == "rich" and not self.preferences.values["rich_text_history_enabled"]:
            self.section = "text"
        selected_ids = {entry.get("id") for entry in self.selected_entries()}
        child = self.listbox.get_first_child()
        while child:
            following = child.get_next_sibling(); self.listbox.remove(child); child = following
        rows = self.visible_entries()
        pinned_position = 0
        normal_header_added = False
        has_pinned = any(item.get("pinned") for item in rows)
        for index, entry in enumerate(rows, 1):
            if has_pinned and not entry.get("pinned") and not normal_header_added:
                separator = Gtk.ListBoxRow()
                separator.clipman_separator = True
                separator.set_activatable(False)
                header = Gtk.Label(label="Normal Entries", xalign=0)
                header.add_css_class("heading")
                header.set_margin_top(8); header.set_margin_bottom(8)
                header.set_margin_start(8); header.set_margin_end(8)
                separator.set_child(header)
                separator.update_property(
                    [Gtk.AccessibleProperty.LABEL, Gtk.AccessibleProperty.DESCRIPTION],
                    ["Normal Entries", "Separator between pinned and normal entries"],
                )
                self.listbox.append(separator)
                normal_header_added = True
            row = Gtk.ListBoxRow()
            row.clipman_entry = entry
            box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=2)
            box.set_margin_top(6); box.set_margin_bottom(6); box.set_margin_start(8); box.set_margin_end(8)
            title = entry["display"]
            state = []
            if entry.get("pinned"):
                pinned_position += 1
                state.append(f"Pinned {pinned_position}")
            if entry.get("is_template"): state.append("Template")
            quick_binding = self.preferences.values["quick_paste_bindings"].get(entry.get("id"), {}) if self.section != "files" else {}
            if quick_binding:
                valid, keyval, modifiers = Gtk.accelerator_parse(quick_binding.get("hotkey", ""))
                hotkey_label = Gtk.accelerator_get_label(keyval, modifiers) if valid else quick_binding.get("hotkey", "")
                mode_label = {"restore": "paste and restore clipboard", "keep": "paste and keep target", "copy": "copy only"}.get(quick_binding.get("mode"), "")
                state.append("Quick Paste " + hotkey_label + ", " + mode_label)
            primary_text = (f"{pinned_position}. " if entry.get("pinned") else "") + title
            primary = Gtk.Label(label=primary_text, xalign=0)
            primary.set_ellipsize(3)
            metadata = []
            if self.section == "files":
                if entry.get("operation"): metadata.append("Operation: " + entry["operation"])
                metadata.append(f"Files: {entry.get('file_count', len(entry.get('files', [])))}")
                if entry.get("source"): metadata.append("Source: " + entry["source"])
                if entry.get("device"): metadata.append("Device: " + entry["device"])
            else:
                if entry.get("group"): metadata.append("Group: " + entry["group"])
                if entry.get("device"): metadata.append("Device: " + entry["device"])
                if quick_binding: metadata.append(state[-1])
            secondary = Gtk.Label(label="; ".join(metadata), xalign=0)
            secondary.add_css_class("dim-label")
            secondary.set_ellipsize(3)
            box.append(primary)
            if metadata: box.append(secondary)
            row.set_child(box)
            description = self.entry_description(entry, index, len(rows))
            if self.section == "files":
                accessible_label = (", ".join(state) + ". " if state else "") + file_event_summary(entry)
            else:
                accessible_label = (", ".join(state) + ". " if state else "") + entry_summary(entry)
            row.set_tooltip_text(description)
            row.update_property(
                [Gtk.AccessibleProperty.LABEL, Gtk.AccessibleProperty.DESCRIPTION],
                [accessible_label, description],
            )
            click = Gtk.GestureClick(button=3)
            click.connect("pressed", self._show_context_menu, row)
            row.add_controller(click)
            self.listbox.append(row)
            if entry["id"] in selected_ids: self.listbox.select_row(row)
        if rows and not self.listbox.get_selected_rows(): self.listbox.select_row(self.listbox.get_row_at_index(0))
        self._update_section_tabs()
        titles = {"text": "Text History", "links": "Links History", "rich": "Rich Text History", "files": "File History"}
        self.window.set_title("Clipman - " + titles[self.section])
        self.group_picker.set_visible(self.section != "files")
        self.group_label.set_visible(self.section != "files")
        if hasattr(self, "edit_menu"):
            self._populate_section_menus()
        self._update_action_states()

    def entry_description(self, entry, index, count):
        parts = []
        if self.section == "files":
            if entry.get("operation"): parts.append("Operation: " + entry["operation"])
            parts.append(f"Files: {entry.get('file_count', len(entry.get('files', [])))}")
            if entry.get("source"): parts.append("Source: " + entry["source"])
        else:
            if entry.get("group"): parts.append("Group: " + entry["group"])
        if entry.get("device"): parts.append("Device: " + entry["device"])
        parts.append(f"{index} of {count}")
        return "; ".join(parts)

    def selected_entry(self):
        entries = self.selected_entries()
        return entries[0] if entries else None

    def _entry_rows(self):
        rows = []
        child = self.listbox.get_first_child() if hasattr(self, "listbox") else None
        while child:
            if hasattr(child, "clipman_entry"):
                rows.append(child)
            child = child.get_next_sibling()
        return rows

    def _row_for_entry_id(self, entry_id):
        return next((row for row in self._entry_rows() if row.clipman_entry.get("id") == entry_id), None)

    def selected_row(self):
        if not hasattr(self, "listbox"):
            return None
        focus = self.window.get_focus() if self.window else None
        while focus and not isinstance(focus, Gtk.ListBoxRow):
            focus = focus.get_parent()
        rows = list(self.listbox.get_selected_rows())
        return focus if focus in rows else (rows[0] if rows else None)

    def selected_entries(self):
        if not hasattr(self, "listbox"): return []
        focus = self.window.get_focus() if self.window else None
        while focus and not isinstance(focus, Gtk.ListBoxRow):
            focus = focus.get_parent()
        rows = list(self.listbox.get_selected_rows())
        rows.sort(key=lambda row: row.get_index())
        if focus in rows:
            rows.remove(focus)
            rows.insert(0, focus)
        return [row.clipman_entry for row in rows if hasattr(row, "clipman_entry")]

    def select_all(self, *_args):
        if not hasattr(self, "listbox"):
            return
        self.listbox.select_all()
        self.focus_history()
        self.set_status(f"Selected {len(self.selected_entries())} entries.", True)

    def _show_context_menu(self, _gesture, _presses, x, y, row):
        if row not in self.listbox.get_selected_rows():
            self.listbox.unselect_all()
            self.listbox.select_row(row)
        menu = Gio.Menu()
        if self.section == "files":
            menu.append("Restore Files to Clipboard", "app.copy-close")
            menu.append("Copy File Paths", "app.copy-paths")
            menu.append("Go to File", "app.go-to-file")
            menu.append("View Event Details", "app.details")
            menu.append("Pin or Unpin", "app.pin")
            menu.append("Move Up", "app.move-up")
            menu.append("Move Down", "app.move-down")
            menu.append("Delete", "app.delete")
            menu.append("Remove Unavailable Events", "app.remove-unavailable-files")
            menu.append("Clear File History", "app.clear-file-history")
        else:
            menu.append("Copy and Close", "app.copy-close")
            menu.append("Copy", "app.copy")
            menu.append("Cut", "app.cut")
            menu.append("Paste After Selected", "app.paste-after")
            menu.append("Group Entry", "app.group-entry")
            menu.append("Entry Properties", "app.properties")
            menu.append("Set as Quick Paste Target", "app.quick-assign")
            menu.append("Push to Other Devices", "app.push")
            menu.append("Entry Details", "app.details")
            menu.append("Pin or Unpin", "app.pin")
            menu.append("Move Up", "app.move-up")
            menu.append("Move Down", "app.move-down")
            menu.append("Delete", "app.delete")
        popover = Gtk.PopoverMenu.new_from_model(menu)
        popover.set_parent(row)
        popover.set_pointing_to(Gdk.Rectangle(x=int(x), y=int(y), width=1, height=1))
        popover.connect("closed", lambda widget: widget.unparent())
        popover.popup()

    def _available_sections(self):
        return [
            section for section in normalize_history_tab_order(self.preferences.values["history_tab_order"])
            if (section != "links" or self.preferences.values["links_history_enabled"])
            and (section != "rich" or self.preferences.values["rich_text_history_enabled"])
        ]

    def _update_section_tabs(self):
        available = self._available_sections()
        if self.section not in available:
            self.section = "text"
        self.updating_section_tabs = True
        try:
            previous = None
            for section in normalize_history_tab_order(self.preferences.values["history_tab_order"]):
                button = self.section_buttons[section]
                self.section_tabs.reorder_child_after(button, previous)
                previous = button
            for section, button in self.section_buttons.items():
                visible = section in available
                button.set_visible(visible)
                button.set_focusable(visible and section == self.section)
                button.set_active(section == self.section)
                button.update_state([Gtk.AccessibleState.SELECTED], [1 if section == self.section else 0])
        finally:
            self.updating_section_tabs = False

    def move_history_tab(self, direction):
        order = move_history_tab_order(
            self.preferences.values["history_tab_order"],
            self.section,
            direction,
            self.preferences.values["links_history_enabled"],
            self.preferences.values["rich_text_history_enabled"],
        )
        if order is None:
            self.sounds.play("skip")
            self.set_status("The current history tab cannot move any farther " + ("left." if direction < 0 else "right."), True)
            return
        tab_had_focus = self.window.get_focus() in self.section_buttons.values()
        self.preferences.values["history_tab_order"] = order
        self.preferences.save()
        self._update_section_tabs()
        if tab_had_focus:
            self.section_buttons[self.section].grab_focus()
        else:
            self.focus_history()
        names = {"text": "Text", "links": "Links", "rich": "Rich Text", "files": "File"}
        self.set_status("Moved " + names[self.section] + " history tab " + ("left." if direction < 0 else "right."), True)

    def _section_tab_toggled(self, button, section):
        if self.updating_section_tabs or not button.get_active() or section == self.section:
            return
        self.switch_section(section, focus_history=False)
        self.section_buttons[section].grab_focus()

    def _section_tab_key_pressed(self, _controller, keyval, _keycode, state):
        modifiers = state & (
            Gdk.ModifierType.CONTROL_MASK | Gdk.ModifierType.ALT_MASK |
            Gdk.ModifierType.SHIFT_MASK | Gdk.ModifierType.SUPER_MASK
        )
        if modifiers:
            return False
        sections = self._available_sections()
        if keyval in (Gdk.KEY_Left, Gdk.KEY_KP_Left):
            target = sections[(sections.index(self.section) - 1) % len(sections)]
        elif keyval in (Gdk.KEY_Right, Gdk.KEY_KP_Right):
            target = sections[(sections.index(self.section) + 1) % len(sections)]
        elif keyval in (Gdk.KEY_Home, Gdk.KEY_KP_Home):
            target = sections[0]
        elif keyval in (Gdk.KEY_End, Gdk.KEY_KP_End):
            target = sections[-1]
        else:
            return False
        self.switch_section(target, focus_history=False)
        self.section_buttons[target].grab_focus()
        return True

    def switch_section(self, section, focus_history=True):
        if section not in ("text", "links", "rich", "files"):
            return
        if section == "links" and not self.preferences.values["links_history_enabled"]:
            self.sounds.play("skip"); self.set_status("Links History is disabled in Preferences.", True); return
        if section == "rich" and not self.preferences.values["rich_text_history_enabled"]:
            self.sounds.play("skip"); self.set_status("Rich Text History is disabled in Preferences.", True); return
        self.section = section
        self.preferences.values["last_section"] = section
        self.preferences.save()
        self.rebuild_list()
        names = {"text": "Text", "links": "Links", "rich": "Rich Text", "files": "File"}
        self.set_status(names[section] + " clipboard history.", True)
        if focus_history:
            self.focus_history()

    def cycle_section(self, direction):
        sections = self._available_sections()
        try:
            index = sections.index(self.section)
        except ValueError:
            index = 0
        self.switch_section(sections[(index + direction) % len(sections)])

    def focus_history(self):
        rows = self.listbox.get_selected_rows()
        row = rows[0] if rows else None
        if not row:
            row = self.listbox.get_row_at_index(0)
            if row:
                self.listbox.select_row(row)
        (row or self.listbox).grab_focus()

    def move_selection(self, offset):
        rows = self.listbox.get_selected_rows()
        row = rows[0] if rows else None
        index = row.get_index() if row else 0
        target = self.listbox.get_row_at_index(max(0, index + offset))
        if target:
            self.listbox.unselect_all(); self.listbox.select_row(target); target.grab_focus()

    def repeat_find(self, previous=False):
        if not self.search.get_text():
            self.search.grab_focus(); return
        self.move_selection(-1 if previous else 1)

    def select_edge(self, first):
        rows = self._entry_rows()
        row = rows[0 if first else -1] if rows else None
        if row: self.listbox.unselect_all(); self.listbox.select_row(row); row.grab_focus()

    def select_first_normal(self):
        for row in self._entry_rows():
            entry = row.clipman_entry
            if not entry.get("pinned"):
                self.listbox.unselect_all(); self.listbox.select_row(row); row.grab_focus(); return

    def type_to_entry(self, character):
        now = time.monotonic()
        if now > self.type_deadline: self.type_buffer = ""
        self.type_deadline = now + 1.25
        self.type_buffer += character.casefold()
        for row in self._entry_rows():
            entry = row.clipman_entry
            if entry.get("display", "").casefold().startswith(self.type_buffer):
                self.listbox.unselect_all(); self.listbox.select_row(row); row.grab_focus(); return

    def copy_pinned_number(self, number, paths_only=False):
        pinned = [entry for entry in self.visible_entries() if entry.get("pinned")]
        if 1 <= number <= len(pinned):
            row = self._row_for_entry_id(pinned[number - 1]["id"])
            if row:
                self.listbox.unselect_all(); self.listbox.select_row(row)
                if self.section == "files" and paths_only:
                    self.copy_selected_file_paths(); self.window.set_visible(False)
                else:
                    self.copy_selected(close=True)
                return
        self.sounds.play("skip"); self.set_status(f"Pinned item {number} is not available in this section.", True)

    def move_entry(self, direction):
        sort_mode = self.preferences.values["file_sort_mode"] if self.section == "files" else self.preferences.values["sort_mode"]
        if sort_mode != "manual":
            self.sounds.play("skip"); self.set_status("Switch to Manual Order before moving entries.", True); return
        if len(self.selected_entries()) != 1:
            self.sounds.play("skip"); self.set_status("Select one entry before moving it.", True); return
        row = self.selected_row()
        if not row: return
        target = self.listbox.get_row_at_index(row.get_index() + direction)
        if not target or not hasattr(target, "clipman_entry"):
            self.sounds.play("skip"); return
        entry, other = row.clipman_entry, target.clipman_entry
        if entry.get("pinned") != other.get("pinned"):
            self.sounds.play("skip"); return
        action = "file_swap" if self.section == "files" else "swap"
        self.backend.call(action, {"id": entry["id"], "other_id": other["id"]}, self._history_response)

    def copy_selected(self, *_args, close=False):
        entries = self.selected_entries()
        if not entries: self.sounds.play("skip"); return
        if self.section == "files":
            paths = []
            for entry in entries:
                for path in entry.get("files", []):
                    if pathlib.Path(path).exists() and path not in paths:
                        paths.append(path)
            if not paths:
                self.sounds.play("skip"); self.set_status("The selected files are no longer available.", True); return
            operations = {entry.get("operation", "Copy") for entry in entries}
            self._set_file_clipboard(paths, operations.pop() if len(operations) == 1 else "Copy")
            self.sounds.play("copy"); self.set_status("Files restored to clipboard.", True)
            if close: self.window.set_visible(False)
            return
        if any(entry.get("is_template") for entry in entries):
            self.backend.call("resolve_many", {"ids": [entry["id"] for entry in entries]}, lambda message: self._copy_result(message, entries, close))
        else:
            text = "\n".join(entry.get("text", "") for entry in entries)
            rich_text = entries[0].get("rich_text") if len(entries) == 1 else None
            self._set_clipboard(text, rich_text); self._after_copy(entries, close)

    def _copy_result(self, message, entries, close):
        if not message.get("ok"): self.show_error(message.get("error")); return
        result = message["result"]
        text = "\n".join(result.get("texts", [])) if "texts" in result else result.get("text", "")
        self._set_clipboard(text); self._after_copy(entries, close)

    def _set_clipboard(self, text, rich_text=None):
        self.own_clipboard_text = text
        rich_text = normalize_rich_text(rich_text)
        if not rich_text:
            self.window.get_display().get_clipboard().set(text)
            return
        encoded = text.encode("utf-8")
        providers = [
            Gdk.ContentProvider.new_for_bytes("text/plain;charset=utf-8", GLib.Bytes.new(encoded)),
            Gdk.ContentProvider.new_for_bytes("text/plain", GLib.Bytes.new(encoded)),
        ]
        if rich_text.get("html_fragment"):
            providers.append(Gdk.ContentProvider.new_for_bytes("text/html", GLib.Bytes.new(rich_text["html_fragment"].encode("utf-8"))))
        if rich_text.get("rtf_base64"):
            providers.append(Gdk.ContentProvider.new_for_bytes("text/rtf", GLib.Bytes.new(base64.b64decode(rich_text["rtf_base64"]))))
            providers.append(Gdk.ContentProvider.new_for_bytes("application/rtf", GLib.Bytes.new(base64.b64decode(rich_text["rtf_base64"]))))
        self.window.get_display().get_clipboard().set_content(Gdk.ContentProvider.new_union(providers))

    def _set_file_clipboard(self, paths, operation="Copy"):
        uris = [Gio.File.new_for_path(path).get_uri() for path in paths]
        marker = "cut" if str(operation).casefold() in ("move", "cut") else "copy"
        providers = [
            Gdk.ContentProvider.new_for_bytes("x-special/gnome-copied-files", GLib.Bytes.new((marker + "\n" + "\n".join(uris)).encode("utf-8"))),
            Gdk.ContentProvider.new_for_bytes("text/uri-list", GLib.Bytes.new(("\r\n".join(uris) + "\r\n").encode("utf-8"))),
            Gdk.ContentProvider.new_for_bytes("text/plain;charset=utf-8", GLib.Bytes.new("\n".join(paths).encode("utf-8"))),
        ]
        self.own_clipboard_files = ("files", tuple(sorted(paths, key=str.casefold)), "Move" if marker == "cut" else "Copy")
        self.window.get_display().get_clipboard().set_content(Gdk.ContentProvider.new_union(providers))

    def copy_selected_file_paths(self, *_args):
        if self.section != "files":
            self.copy_selected(close=False); return
        entries = self.selected_entries()
        paths = []
        for entry in entries:
            for path in entry.get("files", []):
                if path not in paths:
                    paths.append(path)
        if not paths:
            self.sounds.play("skip"); return
        self._set_clipboard("\n".join(paths))
        self.sounds.play("copy"); self.set_status("File paths copied to clipboard.", True)

    def _after_copy(self, entries, close):
        if isinstance(entries, dict):
            entries = [entries]
        self.backend.call("touch_many", {"ids": [entry["id"] for entry in entries]}, self._history_response)
        self.sounds.play("copy"); self.set_status("Copied to clipboard.", True)
        if close:
            self.window.set_visible(False)
            if self.preferences.values["paste_after_enter"] and self.section != "files":
                GLib.timeout_add(120, self._paste_into_previous_window)

    def _paste_into_previous_window(self):
        if not self.previous_window_id or not shutil.which("xdotool"):
            self.sounds.play("skip")
            return GLib.SOURCE_REMOVE
        try:
            completed = subprocess.run(
                ["xdotool", "windowactivate", "--sync", self.previous_window_id, "key", "--clearmodifiers", "ctrl+v"],
                capture_output=True, timeout=3, check=False,
            )
            if completed.returncode != 0:
                self.sounds.play("skip")
        except (OSError, subprocess.SubprocessError):
            self.sounds.play("skip")
        return GLib.SOURCE_REMOVE

    def add_clipboard(self, *_args):
        clipboard = self.window.get_display().get_clipboard()
        mime_type = next((mime for mime in FILE_CLIPBOARD_MIME_TYPES if clipboard.get_formats().contain_mime_type(mime)), None)
        if mime_type:
            clipboard.read_async([mime_type], GLib.PRIORITY_DEFAULT, None, self._clipboard_files_read, True)
        else:
            clipboard.read_text_async(None, self._add_clipboard_read, None)

    def _add_clipboard_read(self, clipboard, result, _data):
        try: text = clipboard.read_text_finish(result)
        except GLib.Error as error: self.show_error(str(error)); return
        if not text or not text.strip(): self.sounds.play("skip"); self.set_status("Clipboard does not contain text.", True); return
        if is_file_manager_clipboard_payload(text):
            mime_type = text.replace("\r\n", "\n").split("\n", 1)[0].strip().casefold()
            paths, operation = parse_file_clipboard_payload(text, mime_type)
            self._capture_file_paths(clipboard, paths, operation, mime_type, True); return
        self._read_rich_clipboard(clipboard, text, lambda _clipboard, value, rich: self._put_text(value, rich_text=rich))

    def cut_selected(self, *_args):
        if self.section == "files":
            self.sounds.play("skip"); return
        entries = self.selected_entries()
        if not entries or any(entry.get("pinned") for entry in entries):
            self.sounds.play("skip"); self.set_status("Pinned entries must be unpinned before cutting.", True); return
        if self.preferences.values["confirm_deletions"]:
            self._confirm_entry_removal(entries, self._cut_entries, "Cut")
            return
        self._cut_entries(entries)

    def _cut_entries(self, entries):
        rich_text = entries[0].get("rich_text") if len(entries) == 1 else None
        self._set_clipboard("\n".join(entry.get("text", "") for entry in entries), rich_text)
        self.backend.call("delete_many", {"ids": [entry["id"] for entry in entries]}, self._cut_response)

    def _cut_response(self, message):
        if not message.get("ok"):
            self.show_error(message.get("error")); return
        self._history_response(message)
        self.sounds.play("copy"); self.set_status("Cut entry to the clipboard.", True)

    def paste_after_selected(self, *_args):
        if self.section == "files":
            self.sounds.play("skip"); return
        entry = self.selected_entry()
        after_id = entry.get("id", "") if entry else ""
        clipboard = self.window.get_display().get_clipboard()
        clipboard.read_text_async(None, lambda c, result, _data: self._paste_after_read(c, result, after_id), None)

    def _paste_after_read(self, clipboard, result, after_id):
        try:
            text = clipboard.read_text_finish(result)
        except GLib.Error as error:
            self.show_error(str(error)); return
        if not text or not text.strip():
            self.sounds.play("skip"); self.set_status("Clipboard does not contain text.", True); return
        self._read_rich_clipboard(clipboard, text, lambda _clipboard, value, rich: self._paste_after_rich(after_id, value, rich))

    def _paste_after_rich(self, after_id, text, rich_text):
        self.backend.call("put_after", {"after_id": after_id, "text": text, "rich_text": normalize_rich_text(rich_text)}, lambda message: self._operation_response(message, "Pasted clipboard text after the selected entry."))

    def push_selected(self, *_args):
        if self.section == "files":
            self.sounds.play("skip"); return
        entries = self.selected_entries()
        if not entries:
            self.sounds.play("skip"); return
        if any(entry.get("is_template") for entry in entries):
            self.backend.call("resolve_many", {"ids": [entry["id"] for entry in entries]}, lambda message: self._push_resolved(message, entries))
        else:
            self._push_entries(entries, [entry.get("text", "") for entry in entries])

    def _push_resolved(self, message, entries):
        if not message.get("ok"):
            self.show_error(message.get("error")); return
        self._push_entries(entries, message["result"].get("texts", []))

    def _push_entries(self, entries, texts):
        rich_text = entries[0].get("rich_text") if len(entries) == 1 and not entries[0].get("is_template") else None
        self._set_clipboard("\n".join(texts), rich_text)
        self.backend.call("push", {"ids": [entry["id"] for entry in entries]}, lambda message: self._operation_response(message, "Pushed selected entries to other devices and copied them to this clipboard."))

    def _operation_response(self, message, status):
        if not message.get("ok"):
            self.show_error(message.get("error")); return
        self._history_response(message)
        self.sounds.play("copy"); self.set_status(status, True)

    def import_history(self, replace=False):
        chooser = self._clipdb_file_dialog("Import and Replace Clipboard History" if replace else "Import Clipboard History")
        chooser.open(self.window, None, lambda dialog, result: self._import_file_chosen(dialog, result, replace))

    def _import_file_chosen(self, dialog, result, replace):
        try:
            file = dialog.open_finish(result)
        except GLib.Error:
            return
        self._show_import_password(file.get_path(), replace)

    def _show_import_password(self, path, replace):
        dialog = Gtk.Dialog(title="Import Clipboard History", transient_for=self.window, modal=True)
        dialog.add_button("Cancel", Gtk.ResponseType.CANCEL); dialog.add_button("Import", Gtk.ResponseType.OK)
        area = dialog.get_content_area(); area.set_spacing(8); area.set_margin_top(12); area.set_margin_bottom(12); area.set_margin_start(12); area.set_margin_end(12)
        message = "Enter the password used by this clipboard history file. Leave it blank if the file has no password."
        if replace:
            message += " Import and Replace removes the current text history before importing this file."
        area.append(Gtk.Label(label=message, wrap=True, xalign=0))
        password = Gtk.PasswordEntry(show_peek_icon=True); password.update_property([Gtk.AccessibleProperty.LABEL], ["Import file password"]); area.append(password)
        def response(_dialog, code):
            if code == Gtk.ResponseType.OK:
                self.backend.call("import", {"path": path, "password": password.get_text(), "replace": replace}, lambda result: self._operation_response(result, "Imported clipboard history."))
            dialog.destroy()
        dialog.connect("response", response); dialog.present(); password.grab_focus()

    def export_history(self, *_args):
        chooser = self._clipdb_file_dialog("Export Clipboard History")
        chooser.set_initial_name("clipman-export.clipdb")
        chooser.save(self.window, None, self._export_file_chosen)

    def _export_file_chosen(self, dialog, result):
        try:
            file = dialog.save_finish(result)
        except GLib.Error:
            return
        self._show_export_password(file.get_path())

    def _show_export_password(self, path):
        dialog = Gtk.Dialog(title="Export Clipboard History", transient_for=self.window, modal=True)
        dialog.add_button("Cancel", Gtk.ResponseType.CANCEL); dialog.add_button("Export", Gtk.ResponseType.OK)
        area = dialog.get_content_area(); area.set_spacing(8); area.set_margin_top(12); area.set_margin_bottom(12); area.set_margin_start(12); area.set_margin_end(12)
        area.append(Gtk.Label(label="Confirm the current history password, then choose how to protect the exported file.", wrap=True, xalign=0))
        current = Gtk.PasswordEntry(show_peek_icon=True); current.update_property([Gtk.AccessibleProperty.LABEL], ["Current history password"]); area.append(current)
        modes = ["Use current history password", "Use a new password", "Use no password"]
        mode = Gtk.DropDown(model=Gtk.StringList.new(modes)); mode.update_property([Gtk.AccessibleProperty.LABEL], ["Export password choice"]); area.append(mode)
        new_password = Gtk.PasswordEntry(show_peek_icon=True); new_password.update_property([Gtk.AccessibleProperty.LABEL], ["New export password"]); area.append(new_password)
        confirm = Gtk.PasswordEntry(show_peek_icon=True); confirm.update_property([Gtk.AccessibleProperty.LABEL], ["Confirm new export password"]); area.append(confirm)
        def update_fields(*_args):
            visible = mode.get_selected() == 1
            new_password.set_visible(visible); confirm.set_visible(visible)
        mode.connect("notify::selected", update_fields); update_fields()
        error = Gtk.Label(label="", wrap=True, xalign=0, accessible_role=Gtk.AccessibleRole.STATUS); area.append(error)
        def response(_dialog, code):
            if code != Gtk.ResponseType.OK:
                dialog.destroy(); return
            if mode.get_selected() == 1 and (not new_password.get_text() or new_password.get_text() != confirm.get_text()):
                error.set_text("Enter the same non-empty new password in both fields."); return
            mode_key = ("current", "new", "none")[mode.get_selected()]
            self.backend.call("export", {"path": path, "current_password": current.get_text(), "mode": mode_key, "export_password": new_password.get_text()}, lambda result: self._export_response(result, path))
            dialog.destroy()
        dialog.connect("response", response); dialog.present(); current.grab_focus()

    def _export_response(self, message, path):
        if not message.get("ok"):
            self.show_error(message.get("error")); return
        self.set_status("Exported clipboard history to " + path, True)

    def _clipdb_file_dialog(self, title):
        chooser = Gtk.FileDialog(title=title)
        file_filter = Gtk.FileFilter(); file_filter.set_name("Clipman clipboard history (*.clipdb)"); file_filter.add_pattern("*.clipdb")
        filters = Gio.ListStore.new(Gtk.FileFilter); filters.append(file_filter)
        chooser.set_filters(filters); chooser.set_default_filter(file_filter)
        return chooser

    def clear_text_history(self, *_args):
        if self.section == "files":
            self.sounds.play("skip"); return
        dialog = Gtk.Dialog(title="Clear Clipboard History", transient_for=self.window, modal=True)
        dialog.add_button("Cancel", Gtk.ResponseType.CANCEL); dialog.add_button("Clear History", Gtk.ResponseType.OK)
        area = dialog.get_content_area(); area.set_spacing(8); area.set_margin_top(12); area.set_margin_bottom(12); area.set_margin_start(12); area.set_margin_end(12)
        area.append(Gtk.Label(label="This removes every text and link entry from the shared Clipman database. Enter the history password to confirm.", wrap=True, xalign=0))
        password = Gtk.PasswordEntry(show_peek_icon=True); password.update_property([Gtk.AccessibleProperty.LABEL], ["History password"]); area.append(password)
        def response(_dialog, code):
            if code == Gtk.ResponseType.OK:
                self.backend.call("clear_history", {"password": password.get_text()}, lambda result: self._operation_response(result, "Cleared text and link clipboard history."))
            dialog.destroy()
        dialog.connect("response", response); dialog.present(); password.grab_focus()

    def _put_text(self, text, quiet=False, automatic=False, source="", rich_text=None):
        original_text = text
        if self.preferences.values["auto_remove_url_tracking"]:
            text = clean_tracking_text(text, False)
        if text != original_text:
            rich_text = None
        duplicate = "keep" if self.preferences.values["keep_duplicate_entries"] else "move"
        group = source if automatic and source and self.preferences.values["auto_group_by_app"] else ""
        normalized_rich = normalize_rich_text(rich_text) if self.preferences.values["rich_text_history_enabled"] else None
        self.backend.call("put", {"text": text, "group": group, "duplicate": duplicate, "rich_text": normalized_rich}, lambda m: self._put_response(m, quiet, text, normalized_rich))

    def _put_response(self, message, quiet, text, rich_text=None):
        if not message.get("ok"):
            if not quiet: self.show_error(message.get("error"))
            return
        self._history_response(message)
        self._remember_received_section("rich" if rich_text else "links" if is_standalone_link(text) else "text")
        if not quiet: self.sounds.play("copy"); self.set_status("Clipboard text added to history.", True)

    def _remember_received_section(self, section):
        if not self.preferences.values["dynamic_history_mode"]:
            return
        self.preferences.values["last_received_section"] = section
        self.received_history_section_pending = True

    def new_entry(self, *_args): self.show_entry_dialog(None)
    def edit_selected(self, *_args):
        entry = self.selected_entry()
        if self.section == "files":
            self.sounds.play("skip"); self.set_status("File events do not have editable clipboard text.", True); return
        if entry: self.show_entry_dialog(entry)

    def edit_selected_quick_paste(self, *_args):
        entry = self.selected_entry()
        if self.section == "files" or not entry:
            self.sounds.play("skip")
            return
        self.show_entry_dialog(entry, focus_quick_paste=True)

    def group_selected_entry(self, *_args):
        if self.section == "files":
            self.sounds.play("skip"); self.set_status("Groups do not apply to file history.", True); return
        entries = self.selected_entries()
        if not entries: return
        dialog = Gtk.Dialog(title="Group Clipboard Entries", transient_for=self.window, modal=True)
        dialog.add_button("Cancel", Gtk.ResponseType.CANCEL); dialog.add_button("Save", Gtk.ResponseType.OK)
        area = dialog.get_content_area(); area.set_spacing(8); area.set_margin_top(12); area.set_margin_bottom(12); area.set_margin_start(12); area.set_margin_end(12)
        area.append(Gtk.Label(label="Group", xalign=0))
        initial_groups = {entry.get("group", "") for entry in entries}
        field = Gtk.Entry(text=initial_groups.pop() if len(initial_groups) == 1 else ""); field.update_property([Gtk.AccessibleProperty.LABEL], ["Group"]); area.append(field)
        if len(self.groups) > 4:
            area.append(Gtk.Label(label="Existing groups: " + ", ".join(self.groups[4:]), wrap=True, xalign=0))
        def response(_dialog, code):
            if code == Gtk.ResponseType.OK:
                updates = [{"id": entry["id"], "text": entry["text"], "name": entry.get("name", ""), "group": field.get_text(), "pinned": entry.get("pinned", False), "is_template": entry.get("is_template", False)} for entry in entries]
                self.backend.call("update_many", {"entries": updates}, self._history_response)
            dialog.destroy()
        dialog.connect("response", response); dialog.present(); field.grab_focus()
    def view_selected(self, *_args):
        entry = self.selected_entry()
        if not entry: return
        if self.section == "files": self.show_file_details(entry)
        else: self.show_details(entry)

    def show_entry_dialog(self, entry, focus_quick_paste=False):
        dialog = Gtk.Dialog(title="Clipboard Entry Properties", transient_for=self.window, modal=True)
        dialog.add_button("Cancel", Gtk.ResponseType.CANCEL); dialog.add_button("Save", Gtk.ResponseType.OK)
        content = dialog.get_content_area(); content.set_spacing(8); content.set_margin_top(12); content.set_margin_bottom(12); content.set_margin_start(12); content.set_margin_end(12)
        name = Gtk.Entry(text=entry.get("name", "") if entry else "", placeholder_text="Optional name")
        group = Gtk.Entry(text=entry.get("group", "") if entry else "", placeholder_text="Optional group")
        pinned = Gtk.CheckButton(label="Pinned", active=bool(entry and entry.get("pinned")))
        template = Gtk.CheckButton(label="Resolve template fields when copied", active=bool(entry and entry.get("is_template")))
        existing_binding = self.preferences.values["quick_paste_bindings"].get(entry.get("id"), {}) if entry else {}
        quick_paste = Gtk.CheckButton(label="Use as a Quick Paste target", active=bool(existing_binding))
        quick_paste.set_sensitive(entry is not None)
        if focus_quick_paste and entry is not None:
            quick_paste.set_active(True)
        quick_hotkey = HotkeyEntry(existing_binding.get("hotkey", ""), "Quick Paste hotkey")
        quick_hotkey.set_sensitive(entry is not None and quick_paste.get_active())
        quick_modes = ["Paste and restore previous clipboard", "Paste and keep target on clipboard", "Copy to clipboard only"]
        quick_mode_keys = ["restore", "keep", "copy"]
        quick_mode = Gtk.DropDown(model=Gtk.StringList.new(quick_modes))
        quick_mode.set_selected(quick_mode_keys.index(existing_binding.get("mode", "restore")) if existing_binding.get("mode", "restore") in quick_mode_keys else 0)
        quick_mode.set_sensitive(entry is not None and quick_paste.get_active())
        quick_mode.update_property([Gtk.AccessibleProperty.LABEL], ["Quick Paste mode"])
        quick_paste.connect("toggled", lambda control: (quick_hotkey.set_sensitive(entry is not None and control.get_active()), quick_mode.set_sensitive(entry is not None and control.get_active())))
        text_view = Gtk.TextView(wrap_mode=Gtk.WrapMode.WORD_CHAR); text_view.set_accepts_tab(False); text_view.set_vexpand(True); text_view.get_buffer().set_text(entry.get("text", "") if entry else "")
        for label_text, widget in (("Name", name), ("Group", group), ("Clipboard text", text_view)):
            label = Gtk.Label(label=label_text, xalign=0); label.set_mnemonic_widget(widget); content.append(label); content.append(widget)
            widget.update_property([Gtk.AccessibleProperty.LABEL], [label_text])
        content.append(pinned); content.append(template)
        content.append(quick_paste)
        quick_label = Gtk.Label(label="Quick Paste hotkey", xalign=0); quick_label.set_mnemonic_widget(quick_hotkey)
        content.append(quick_label); content.append(quick_hotkey)
        mode_label = Gtk.Label(label="Quick Paste mode", xalign=0); mode_label.set_mnemonic_widget(quick_mode)
        content.append(mode_label); content.append(quick_mode)
        if entry is None:
            content.append(Gtk.Label(label="Save the new entry once, then reopen Entry Properties to assign a Quick Paste hotkey.", wrap=True, xalign=0))
        template_tools = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=6)
        preset_row = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=6)
        preset = Gtk.DropDown(model=Gtk.StringList.new([item[0] for item in TEMPLATE_PRESETS])); preset.set_hexpand(True)
        preset.update_property([Gtk.AccessibleProperty.LABEL], ["Template sample"])
        insert_preset = Gtk.Button(label="Insert Sample")
        insert_preset.connect("clicked", lambda *_: self._insert_template_text(text_view, template, TEMPLATE_PRESETS[preset.get_selected()][1]))
        preset_row.append(preset); preset_row.append(insert_preset); template_tools.append(preset_row)
        variable_row = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=6)
        variable = Gtk.DropDown(model=Gtk.StringList.new([item[0] for item in TEMPLATE_VARIABLES])); variable.set_hexpand(True)
        variable.update_property([Gtk.AccessibleProperty.LABEL], ["Template field"])
        insert_variable = Gtk.Button(label="Insert Field")
        insert_variable.connect("clicked", lambda *_: self._insert_template_text(text_view, template, TEMPLATE_VARIABLES[variable.get_selected()][1]))
        variable_row.append(variable); variable_row.append(insert_variable); template_tools.append(variable_row)
        preview = Gtk.Button(label="Preview Template")
        preview.connect("clicked", lambda *_: self._preview_template(text_view)); template_tools.append(preview)
        content.append(template_tools)
        dialog.set_default_size(620, 470)
        def response(_dialog, code):
            if code == Gtk.ResponseType.OK:
                if entry and quick_paste.get_active():
                    accelerator = quick_hotkey.get_accelerator()
                    if not accelerator:
                        self.set_status("Choose a valid Quick Paste hotkey before saving.", True); return
                    reserved = {self.preferences.values["show_history_hotkey"], self.preferences.values["toggle_monitoring_hotkey"]}
                    used = {binding.get("hotkey") for entry_id, binding in self.preferences.values["quick_paste_bindings"].items() if entry_id != entry.get("id")}
                    if accelerator in reserved or accelerator in used:
                        self.set_status("That hotkey is already assigned.", True); return
                buffer = text_view.get_buffer(); text = buffer.get_text(buffer.get_start_iter(), buffer.get_end_iter(), True)
                params = {"text": text, "name": name.get_text(), "group": group.get_text(), "pinned": pinned.get_active(), "is_template": template.get_active()}
                action = "update" if entry else "put"
                if entry: params["id"] = entry["id"]
                else: params["duplicate"] = "move"
                if entry:
                    bindings = self.preferences.values["quick_paste_bindings"]
                    if quick_paste.get_active():
                        bindings[entry["id"]] = {"hotkey": quick_hotkey.get_accelerator(), "mode": quick_mode_keys[quick_mode.get_selected()]}
                    else:
                        bindings.pop(entry["id"], None)
                    self.preferences.save(); self._register_hotkeys(); self._populate_quick_paste_menu()
                self.backend.call(action, params, self._history_response)
            dialog.destroy()
        dialog.connect("response", response); dialog.present()
        if focus_quick_paste:
            GLib.idle_add(lambda: (quick_hotkey.grab_focus(), False)[1])

    def _insert_template_text(self, text_view, template_checkbox, value):
        text_view.get_buffer().insert_at_cursor(value)
        template_checkbox.set_active(True)
        text_view.grab_focus()

    def _preview_template(self, text_view):
        buffer = text_view.get_buffer()
        text = buffer.get_text(buffer.get_start_iter(), buffer.get_end_iter(), True)
        self.backend.call("resolve_template_text", {"text": text}, self._preview_template_response)

    def _preview_template_response(self, message):
        if not message.get("ok"):
            self.show_error(message.get("error")); return
        dialog = Gtk.Dialog(title="Template Preview", transient_for=self.window, modal=True)
        dialog.add_button("Close", Gtk.ResponseType.CLOSE)
        area = dialog.get_content_area(); area.set_margin_top(12); area.set_margin_bottom(12); area.set_margin_start(12); area.set_margin_end(12)
        text = Gtk.TextView(editable=False, cursor_visible=True, wrap_mode=Gtk.WrapMode.WORD_CHAR)
        text.set_accepts_tab(False); text.update_property([Gtk.AccessibleProperty.LABEL], ["Resolved template preview"])
        text.get_buffer().set_text(message["result"]["text"]); area.append(text)
        dialog.set_default_size(600, 360); dialog.connect("response", lambda d, _r: d.destroy()); dialog.present()

    def show_details(self, entry):
        dialog = Gtk.Dialog(title="Clipboard Entry Details", transient_for=self.window, modal=True)
        dialog.add_button("Close", Gtk.ResponseType.CLOSE)
        content = dialog.get_content_area(); content.set_spacing(8); content.set_margin_top(12); content.set_margin_bottom(12); content.set_margin_start(12); content.set_margin_end(12)
        text = Gtk.TextView(editable=False, cursor_visible=True, wrap_mode=Gtk.WrapMode.WORD_CHAR, vexpand=True)
        text.set_accepts_tab(False)
        rich_text = normalize_rich_text(entry.get("rich_text"))
        rendered_html = populate_safe_rich_buffer(text.get_buffer(), rich_text, entry["text"])
        text.update_property([Gtk.AccessibleProperty.LABEL], ["Formatted clipboard text" if rendered_html else "Clipboard text"])
        content.append(text)
        details = Gtk.ListBox(selection_mode=Gtk.SelectionMode.NONE)
        values = [
            ("Name", entry.get("name") or "Not named"), ("Group", entry.get("group") or "No group"),
            ("Device", entry.get("device") or "Unknown"), ("Characters", str(len(entry["text"]))),
            ("Words", str(len(entry["text"].split()))), ("Pinned", "Yes" if entry.get("pinned") else "No"),
            ("Template", "Yes" if entry.get("is_template") else "No"),
            ("Added", self.format_date(entry.get("created_unix_ms"))), ("Last used", self.format_date(entry.get("last_used_unix_ms"))),
        ]
        if rich_text:
            formats = []
            if rich_text.get("html_fragment"): formats.append("HTML")
            if rich_text.get("rtf_base64"): formats.append("RTF")
            values.insert(5, ("Formatting", " and ".join(formats)))
        for key, value in values:
            row = Gtk.Label(label=f"{key}: {value}", xalign=0); row.set_margin_top(3); row.set_margin_bottom(3); details.append(row)
        content.append(details); dialog.set_default_size(650, 540)
        dialog.connect("response", lambda d, _r: d.destroy()); dialog.present()

    def show_file_details(self, event):
        dialog = Gtk.Dialog(title="File History Event Details", transient_for=self.window, modal=True)
        dialog.add_button("Close", Gtk.ResponseType.CLOSE)
        content = dialog.get_content_area(); content.set_spacing(8); content.set_margin_top(12); content.set_margin_bottom(12); content.set_margin_start(12); content.set_margin_end(12)
        files = Gtk.TextView(editable=False, cursor_visible=True, wrap_mode=Gtk.WrapMode.WORD_CHAR, vexpand=True)
        files.set_accepts_tab(False); files.update_property([Gtk.AccessibleProperty.LABEL], ["File paths"])
        files.get_buffer().set_text("\n".join(event.get("files", [])))
        content.append(files)
        details = Gtk.ListBox(selection_mode=Gtk.SelectionMode.NONE)
        values = [
            ("Operation", event.get("operation") or "Copy"), ("Files", str(event.get("file_count", 0))),
            ("Source", event.get("source") or "Unknown"), ("Device", event.get("device") or "Unknown"),
            ("Pinned", "Yes" if event.get("pinned") else "No"),
            ("Available", "Yes" if any(pathlib.Path(path).exists() for path in event.get("files", [])) else "No"),
            ("Captured", self.format_date(event.get("captured_unix_ms"))),
            ("Formats", ", ".join(event.get("formats", [])) or "Not reported"),
        ]
        for key, value in values:
            details.append(Gtk.Label(label=f"{key}: {value}", xalign=0))
        content.append(details); dialog.set_default_size(680, 540)
        dialog.connect("response", lambda d, _r: d.destroy()); dialog.present()

    def go_to_selected_file(self, *_args):
        if self.section != "files":
            self.sounds.play("skip"); return
        event = self.selected_entry()
        paths = [path for path in (event or {}).get("files", []) if pathlib.Path(path).exists()]
        if len(paths) != 1:
            self.sounds.play("skip"); self.set_status("Go to File requires one available file or folder.", True); return
        uri = Gio.File.new_for_path(paths[0]).get_uri()
        try:
            proxy = Gio.DBusProxy.new_for_bus_sync(Gio.BusType.SESSION, Gio.DBusProxyFlags.NONE, None, "org.freedesktop.FileManager1", "/org/freedesktop/FileManager1", "org.freedesktop.FileManager1", None)
            proxy.call_sync("ShowItems", GLib.Variant("(ass)", ([uri], "")), Gio.DBusCallFlags.NONE, 5000, None)
        except GLib.Error:
            target = paths[0] if pathlib.Path(paths[0]).is_dir() else str(pathlib.Path(paths[0]).parent)
            try: subprocess.Popen(["xdg-open", target], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            except OSError as error: self.show_error(str(error)); return
        self.set_status("Opened the selected file location.", True)

    def clear_file_history(self, *_args):
        if self.section != "files":
            self.sounds.play("skip"); return
        dialog = Gtk.AlertDialog(message="Clear normal file history?", detail="Pinned file events are kept. No files are deleted from disk.", buttons=["Cancel", "Clear"], cancel_button=0, default_button=0)
        dialog.choose(self.window, None, self._clear_file_history_choice)

    def _clear_file_history_choice(self, dialog, result):
        try: choice = dialog.choose_finish(result)
        except GLib.Error: return
        if choice == 1: self.backend.call("file_clear", {}, self._history_response)

    def remove_unavailable_file_history(self, *_args):
        if self.section != "files":
            self.sounds.play("skip"); return
        self.backend.call("file_remove_unavailable", {}, self._history_response)

    def transform_selected(self, transform, status):
        if self.section == "files":
            self.sounds.play("skip"); self.set_status("Text actions do not apply to file history.", True); return
        entries = self.selected_entries()
        if not entries: return
        try: transformed = [transform(entry.get("text", "")) for entry in entries]
        except (ValueError, TypeError) as error: self.show_error(str(error)); return
        updates = [{
            "id": entry["id"], "text": text, "name": entry.get("name", ""),
            "group": entry.get("group", ""), "pinned": entry.get("pinned", False),
            "is_template": entry.get("is_template", False),
        } for entry, text in zip(entries, transformed)]
        self.backend.call("update_many", {"entries": updates}, lambda message: self._transform_response(message, transformed, status))

    def _transform_response(self, message, transformed, status):
        if not message.get("ok"): self.show_error(message.get("error")); return
        self._history_response(message)
        self._set_clipboard("\n".join(transformed)); self.sounds.play("copy")
        self.set_status(status + " Copied transformed text to the clipboard.", True)

    def delete_selected(self, *_args):
        entries = self.selected_entries()
        if not entries: return
        if any(entry.get("pinned") for entry in entries): self.sounds.play("skip"); self.set_status("Pinned entries must be unpinned before deletion.", True); return
        if self.preferences.values["confirm_deletions"]:
            self._confirm_entry_removal(entries, self._delete_entries, "Delete")
            return
        self._delete_entries(entries)

    def _delete_entries(self, entries):
        action = "file_delete_many" if self.section == "files" else "delete_many"
        self.backend.call(action, {"ids": [entry["id"] for entry in entries]}, self._history_response)

    def _confirm_entry_removal(self, entries, callback, verb):
        noun = "file-history event" if self.section == "files" else "clipboard entry"
        message = f"{verb} this {noun}?" if len(entries) == 1 else f"{verb} these {len(entries)} {noun}s?"
        detail = entries[0]["display"] if len(entries) == 1 else "This cannot be undone."
        dialog = Gtk.Dialog(title=message, transient_for=self.window, modal=True)
        dialog.add_button("Cancel", Gtk.ResponseType.CANCEL)
        dialog.add_button(verb, Gtk.ResponseType.OK)
        dialog.set_default_response(Gtk.ResponseType.CANCEL)
        area = dialog.get_content_area()
        area.set_spacing(10); area.set_margin_top(12); area.set_margin_bottom(12); area.set_margin_start(12); area.set_margin_end(12)
        area.append(Gtk.Label(label=detail, wrap=True, xalign=0, selectable=True))
        do_not_ask = Gtk.CheckButton(label="Do not ask again before deleting entries")
        area.append(do_not_ask)
        def response(_dialog, code):
            if code == Gtk.ResponseType.OK:
                if do_not_ask.get_active():
                    self.preferences.values["confirm_deletions"] = False
                    self.preferences.save()
                callback(entries)
            dialog.destroy()
        dialog.connect("response", response)
        dialog.present()

    def toggle_pin(self, *_args):
        entries = self.selected_entries()
        if entries:
            pinned = not all(entry.get("pinned") for entry in entries)
            action = "file_pin_many" if self.section == "files" else "pin_many"
            self.backend.call(action, {"ids": [entry["id"] for entry in entries], "pinned": pinned}, self._history_response)

    def show_secrets(self, *_args):
        dialog = Gtk.Dialog(title="Unlock Clipman Secrets", transient_for=self.window, modal=True)
        dialog.add_button("Cancel", Gtk.ResponseType.CANCEL); dialog.add_button("Unlock", Gtk.ResponseType.OK)
        area = dialog.get_content_area(); area.set_spacing(8); area.set_margin_top(12); area.set_margin_bottom(12); area.set_margin_start(12); area.set_margin_end(12)
        area.append(Gtk.Label(label="Enter the current history password to show secret names and hotkeys.", wrap=True, xalign=0))
        password = Gtk.PasswordEntry(show_peek_icon=True); password.update_property([Gtk.AccessibleProperty.LABEL], ["History password"]); area.append(password)
        def response(_dialog, code):
            if code == Gtk.ResponseType.OK:
                self.backend.call("secrets_list", {"password": password.get_text()}, self._secrets_unlocked)
            dialog.destroy()
        dialog.connect("response", response); dialog.present(); password.grab_focus()

    def _secrets_unlocked(self, message):
        if not message.get("ok"):
            self.show_error(message.get("error")); return
        self._open_secrets_manager(message["result"].get("secrets", []))

    def _open_secrets_manager(self, secrets):
        dialog = Gtk.Dialog(title="Clipman Secrets", transient_for=self.window, modal=True)
        dialog.add_button("Close", Gtk.ResponseType.CLOSE)
        dialog.set_default_size(620, 430)
        area = dialog.get_content_area(); area.set_spacing(8); area.set_margin_top(12); area.set_margin_bottom(12); area.set_margin_start(12); area.set_margin_end(12)
        secret_list = Gtk.ListBox(selection_mode=Gtk.SelectionMode.SINGLE, activate_on_single_click=False)
        secret_list.update_property([Gtk.AccessibleProperty.LABEL], ["Saved secrets"])
        scroll = Gtk.ScrolledWindow(vexpand=True); scroll.set_child(secret_list); area.append(scroll)
        buttons = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=6)
        add_button = Gtk.Button(label="Add"); edit_button = Gtk.Button(label="Edit"); delete_button = Gtk.Button(label="Delete"); paste_button = Gtk.Button(label="Paste")
        for button in (add_button, edit_button, delete_button, paste_button): buttons.append(button)
        area.append(buttons)
        state = {"secrets": secrets}
        def rebuild():
            child = secret_list.get_first_child()
            while child:
                following = child.get_next_sibling(); secret_list.remove(child); child = following
            valid_ids = {secret.get("id") for secret in state["secrets"]}
            hotkeys = self.preferences.values["secret_hotkeys"]
            removed = [secret_id for secret_id in hotkeys if secret_id not in valid_ids]
            for secret_id in removed: hotkeys.pop(secret_id, None)
            if removed: self.preferences.save(); self._register_hotkeys()
            for secret in state["secrets"]:
                row = Gtk.ListBoxRow(); row.clipman_secret = secret
                hotkey = hotkeys.get(secret.get("id"), "")
                valid, keyval, modifiers = Gtk.accelerator_parse(hotkey) if hotkey else (False, 0, 0)
                label = secret.get("name", "Unnamed secret")
                if valid: label += "; Hotkey: " + Gtk.accelerator_get_label(keyval, modifiers)
                row.set_child(Gtk.Label(label=label, xalign=0, margin_top=7, margin_bottom=7, margin_start=7, margin_end=7))
                row.update_property([Gtk.AccessibleProperty.LABEL], [label]); secret_list.append(row)
            if state["secrets"]: secret_list.select_row(secret_list.get_row_at_index(0))
        def selected():
            row = secret_list.get_selected_row(); return getattr(row, "clipman_secret", None) if row else None
        add_button.connect("clicked", lambda *_: self._show_secret_editor(None, "", dialog, state, rebuild))
        edit_button.connect("clicked", lambda *_: self._request_secret_edit(selected(), dialog, state, rebuild))
        delete_button.connect("clicked", lambda *_: self._delete_secret(selected(), dialog, state, rebuild))
        paste_button.connect("clicked", lambda *_: self._paste_secret_from_manager(selected(), dialog))
        secret_list.connect("row-activated", lambda *_: self._paste_secret_from_manager(selected(), dialog))
        rebuild(); dialog.connect("response", lambda d, _r: d.destroy()); dialog.present(); secret_list.grab_focus()

    def _request_secret_edit(self, secret, parent, state, rebuild):
        if not secret: return
        self.backend.call("secret_get", {"id": secret["id"]}, lambda message: self._secret_for_edit(message, parent, state, rebuild))

    def _secret_for_edit(self, message, parent, state, rebuild):
        if not message.get("ok"): self.show_error(message.get("error")); return
        result = message["result"]
        self._show_secret_editor({"id": result["id"], "name": result["name"]}, result["value"], parent, state, rebuild)

    def _show_secret_editor(self, secret, current_value, parent, state, rebuild):
        dialog = Gtk.Dialog(title="Edit Secret" if secret else "Add Secret", transient_for=parent, modal=True)
        dialog.add_button("Cancel", Gtk.ResponseType.CANCEL); dialog.add_button("Save", Gtk.ResponseType.OK)
        area = dialog.get_content_area(); area.set_spacing(8); area.set_margin_top(12); area.set_margin_bottom(12); area.set_margin_start(12); area.set_margin_end(12)
        name = Gtk.Entry(text=secret.get("name", "") if secret else ""); name.update_property([Gtk.AccessibleProperty.LABEL], ["Secret name"])
        value = Gtk.PasswordEntry(show_peek_icon=True); value.set_text(current_value); value.update_property([Gtk.AccessibleProperty.LABEL], ["Secret value"])
        confirm = Gtk.PasswordEntry(show_peek_icon=True); confirm.set_text(current_value); confirm.update_property([Gtk.AccessibleProperty.LABEL], ["Confirm secret value"])
        current_hotkey = self.preferences.values["secret_hotkeys"].get(secret.get("id"), "") if secret else ""
        hotkey = HotkeyEntry(current_hotkey, "Secret Quick Paste hotkey")
        for label, field in (("Name", name), ("Secret value", value), ("Confirm secret value", confirm), ("Quick Paste hotkey, optional", hotkey)):
            visible = Gtk.Label(label=label, xalign=0); visible.set_mnemonic_widget(field); area.append(visible); area.append(field)
        error = Gtk.Label(label="", wrap=True, xalign=0, accessible_role=Gtk.AccessibleRole.STATUS); area.append(error)
        def response(_dialog, code):
            if code != Gtk.ResponseType.OK: dialog.destroy(); return
            if not name.get_text().strip() or not value.get_text(): error.set_text("Name and secret value are required."); return
            if value.get_text() != confirm.get_text(): error.set_text("Secret values do not match."); return
            accelerator = hotkey.get_accelerator()
            used = {self.preferences.values["show_history_hotkey"], self.preferences.values["toggle_monitoring_hotkey"]}
            used.update(binding.get("hotkey") for binding in self.preferences.values["quick_paste_bindings"].values())
            used.update(value for secret_id, value in self.preferences.values["secret_hotkeys"].items() if not secret or secret_id != secret.get("id"))
            if accelerator and accelerator in used: error.set_text("That hotkey is already assigned."); return
            params = {"id": secret.get("id", "") if secret else "", "name": name.get_text(), "value": value.get_text()}
            self.backend.call("secret_put", params, lambda message: self._secret_saved(message, accelerator, state, rebuild, dialog))
        dialog.connect("response", response); dialog.present(); name.grab_focus()

    def _secret_saved(self, message, accelerator, state, rebuild, dialog):
        if not message.get("ok"): self.show_error(message.get("error")); return
        result = message["result"]; secret_id = result.get("id")
        if accelerator: self.preferences.values["secret_hotkeys"][secret_id] = accelerator
        else: self.preferences.values["secret_hotkeys"].pop(secret_id, None)
        self.preferences.save(); self._register_hotkeys()
        state["secrets"] = result.get("secrets", []); rebuild(); dialog.destroy()

    def _delete_secret(self, secret, parent, state, rebuild):
        if not secret: return
        dialog = Gtk.AlertDialog(
            message=f"Delete {secret.get('name', 'this secret')}?",
            detail="The stored value and its Quick Paste hotkey will be removed. This cannot be undone.",
            buttons=["Cancel", "Delete"], cancel_button=0, default_button=0,
        )
        dialog.choose(parent, None, lambda prompt, result: self._delete_secret_choice(prompt, result, secret, state, rebuild))

    def _delete_secret_choice(self, dialog, result, secret, state, rebuild):
        try: choice = dialog.choose_finish(result)
        except GLib.Error: return
        if choice == 1:
            self.backend.call("secret_delete", {"id": secret["id"]}, lambda message: self._secret_deleted(message, secret["id"], state, rebuild))

    def _secret_deleted(self, message, secret_id, state, rebuild):
        if not message.get("ok"): self.show_error(message.get("error")); return
        self.preferences.values["secret_hotkeys"].pop(secret_id, None)
        self.preferences.save(); self._register_hotkeys(); state["secrets"] = message["result"].get("secrets", []); rebuild()

    def _paste_secret_from_manager(self, secret, dialog):
        if not secret: return
        self.backend.call("secret_get", {"id": secret["id"]}, lambda message: self._secret_manager_value(message, dialog))

    def _secret_manager_value(self, message, dialog):
        if not message.get("ok"): self.show_error(message.get("error")); return
        value = message["result"].get("value", "")
        clipboard = self.window.get_display().get_clipboard()
        clipboard.read_text_async(None, lambda source, result, _data: self._secret_manager_previous(source, result, value, dialog), None)

    def _secret_manager_previous(self, clipboard, result, value, dialog):
        try: previous = clipboard.read_text_finish(result)
        except GLib.Error: previous = None
        self._read_rich_clipboard(clipboard, previous, lambda _clipboard, old_text, old_rich: self._secret_manager_with_previous(value, dialog, old_text, old_rich))

    def _secret_manager_with_previous(self, value, dialog, previous, previous_rich):
        self._set_clipboard(value); dialog.destroy(); self.window.set_visible(False); self.sounds.play("copy")
        GLib.timeout_add(120, self._paste_secret_to_previous, {"text": previous, "rich_text": previous_rich})

    def _paste_secret_to_previous(self, restore):
        if not self.previous_window_id or not shutil.which("xdotool"):
            self.sounds.play("skip"); return GLib.SOURCE_REMOVE
        try:
            completed = subprocess.run(["xdotool", "windowactivate", "--sync", self.previous_window_id, "key", "--clearmodifiers", "ctrl+v"], capture_output=True, timeout=3, check=False)
            if completed.returncode != 0: self.sounds.play("skip"); return GLib.SOURCE_REMOVE
        except (OSError, subprocess.SubprocessError): self.sounds.play("skip"); return GLib.SOURCE_REMOVE
        GLib.timeout_add(350, self._restore_quick_paste_clipboard, restore)
        return GLib.SOURCE_REMOVE

    def _secret_hotkey_result(self, message):
        if not message.get("ok"):
            self.sounds.play("skip"); return
        value = message["result"].get("value", "")
        clipboard = self.window.get_display().get_clipboard()
        clipboard.read_text_async(None, lambda source, result, _data: self._secret_hotkey_previous(source, result, value), None)

    def _secret_hotkey_previous(self, clipboard, result, value):
        try: previous = clipboard.read_text_finish(result)
        except GLib.Error: previous = None
        self._read_rich_clipboard(clipboard, previous, lambda _clipboard, old_text, old_rich: self._secret_hotkey_with_previous(value, old_text, old_rich))

    def _secret_hotkey_with_previous(self, value, previous, previous_rich):
        self._set_clipboard(value); self.sounds.play("copy")
        GLib.timeout_add(100, self._quick_paste_send, {"text": previous, "rich_text": previous_rich})

    def show_setup(self):
        self._connection_dialog("Set Up Clipman Server", configuring=True)

    def show_connection_settings(self, parent):
        self.backend.call("configuration", {}, lambda message: self._connection_settings_response(message, parent))

    def _connection_settings_response(self, message, parent):
        if not message.get("ok"):
            self.show_error(message.get("error")); return
        self._connection_dialog("Change Clipman Server", initial=message.get("result", {}), parent=parent)

    def show_unlock(self):
        dialog = Gtk.Dialog(title="Unlock Clipman History", transient_for=self.window, modal=True)
        dialog.add_button("Quit", Gtk.ResponseType.CANCEL); dialog.add_button("Unlock", Gtk.ResponseType.OK)
        area = dialog.get_content_area(); area.set_spacing(8); area.set_margin_top(12); area.set_margin_bottom(12); area.set_margin_start(12); area.set_margin_end(12)
        area.append(Gtk.Label(label="Enter the history password for this Clipman Server database.", wrap=True, xalign=0))
        password = Gtk.PasswordEntry(show_peek_icon=True, placeholder_text="History password"); area.append(password)
        password.update_property([Gtk.AccessibleProperty.LABEL], ["History password"])
        remember = Gtk.CheckButton(label="Remember on this device"); area.append(remember)
        def response(_dialog, code):
            if code == Gtk.ResponseType.OK:
                self.backend.call("unlock", {"password": password.get_text(), "remember": remember.get_active()}, self._setup_response)
            else: self.quit()
            dialog.destroy()
        dialog.connect("response", response); dialog.present(); password.grab_focus()

    def _connection_dialog(self, title, configuring=False, initial=None, parent=None):
        dialog = Gtk.Dialog(title=title, transient_for=parent or self.window, modal=True)
        dialog.add_button("Cancel", Gtk.ResponseType.CANCEL); dialog.add_button("Save and Connect", Gtk.ResponseType.OK)
        area = dialog.get_content_area(); area.set_spacing(7); area.set_margin_top(12); area.set_margin_bottom(12); area.set_margin_start(12); area.set_margin_end(12)
        fields = {}
        for key, label, secret in (("server", "Server address", False), ("token", "Server token", True), ("password", "History password", True), ("machine", "Device name", False)):
            area.append(Gtk.Label(label=label, xalign=0))
            widget = Gtk.PasswordEntry(show_peek_icon=True) if secret else Gtk.Entry()
            widget.update_property([Gtk.AccessibleProperty.LABEL], [label])
            fields[key] = widget; area.append(widget)
        fields["machine"].set_text((initial or {}).get("machine") or self.machine_name or os.uname().nodename)
        if initial:
            fields["server"].set_text(initial.get("server", ""))
            fields["token"].set_text(initial.get("token", ""))
            if initial.get("token_present") and not initial.get("token"):
                fields["token"].update_property(
                    [Gtk.AccessibleProperty.DESCRIPTION], ["Leave blank to keep the stored server token"],
                )
            if initial.get("password_saved"):
                fields["password"].update_property(
                    [Gtk.AccessibleProperty.DESCRIPTION], ["Leave blank to keep the stored history password"],
                )
            if initial.get("token_present") or initial.get("password_saved"):
                area.append(Gtk.Label(
                    label="Leave a protected field blank to keep its stored value.",
                    wrap=True, xalign=0,
                ))
        authority = {
            "ca_cert_pem": (initial or {}).get("ca_cert_pem", ""),
            "ca_host": (initial or {}).get("ca_host", ""),
            "ca_subject": (initial or {}).get("ca_subject", ""),
            "ca_expires": (initial or {}).get("ca_expires", ""),
            "ca_fingerprint": (initial or {}).get("ca_fingerprint", ""),
        }
        authority_status = Gtk.Label(label=self._authority_status_text(authority), wrap=True, xalign=0, selectable=True)
        authority_status.update_property([Gtk.AccessibleProperty.LABEL], ["Private certificate authority status"])
        area.append(authority_status)
        authority_buttons = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=8)
        import_authority = Gtk.Button(label="Import Private Authority")
        import_authority.connect("clicked", lambda *_: self._choose_authority_file(fields, authority, authority_status))
        remove_authority = Gtk.Button(label="Remove Private Authority")
        def remove_private_authority(*_args):
            authority.update({"ca_cert_pem": "", "ca_host": "", "ca_subject": "", "ca_expires": "", "ca_fingerprint": ""})
            authority_status.set_text(self._authority_status_text(authority))
        remove_authority.connect("clicked", remove_private_authority)
        authority_buttons.append(import_authority); authority_buttons.append(remove_authority); area.append(authority_buttons)
        remember = Gtk.CheckButton(label="Remember history password on this device", active=(initial or {}).get("password_saved", True)); area.append(remember)
        import_button = Gtk.Button(label="Import Clipman Server Connection File")
        import_button.connect("clicked", lambda *_: self._choose_connection_file(fields, authority, authority_status)); area.append(import_button)
        def response(_dialog, code):
            if code == Gtk.ResponseType.OK:
                params = {key: widget.get_text() for key, widget in fields.items()}; params["remember"] = remember.get_active()
                params["ca_cert_pem"] = authority["ca_cert_pem"]; params["ca_host"] = authority["ca_host"]
                self.remote_baseline_ready = False; self.remote_entry_stamps = {}
                self.backend.call("configure", params, self._setup_response)
            elif configuring: self.quit()
            dialog.destroy()
        dialog.connect("response", response); dialog.present()

    def _choose_connection_file(self, fields, authority, authority_status):
        chooser = Gtk.FileDialog(title="Import Clipman Server Connection")
        chooser.open(self.window, None, lambda d, r: self._connection_file_chosen(d, r, fields, authority, authority_status))

    def _connection_file_chosen(self, dialog, result, fields, authority, authority_status):
        try: file = dialog.open_finish(result); text = pathlib.Path(file.get_path()).read_text(encoding="utf-8")
        except (GLib.Error, OSError, UnicodeError) as error: self.show_error(f"Could not read connection file: {error}"); return
        self.backend.call("connection_details", {"text": text}, lambda m: self._connection_details_response(m, fields, authority, authority_status))

    def _choose_authority_file(self, fields, authority, authority_status):
        chooser = Gtk.FileDialog(title="Import Private Certificate Authority")
        chooser.open(self.window, None, lambda d, r: self._authority_file_chosen(d, r, fields, authority, authority_status))

    def _authority_file_chosen(self, dialog, result, fields, authority, authority_status):
        try:
            file = dialog.open_finish(result)
            path = pathlib.Path(file.get_path())
            if path.stat().st_size > 32 * 1024: raise ValueError("The certificate authority file exceeds the 32 KiB limit.")
            text = path.read_text(encoding="utf-8")
        except (GLib.Error, OSError, UnicodeError, ValueError) as error:
            self.show_error(f"Could not read private authority: {error}"); return
        self.backend.call(
            "authority_details",
            {"text": text, "server": fields["server"].get_text()},
            lambda message: self._authority_details_response(message, authority, authority_status),
        )

    def _authority_details_response(self, message, authority, authority_status):
        if not message.get("ok"): self.show_error(message.get("error")); return
        details = message["result"]
        dialog = Gtk.AlertDialog(
            message="Import private authority for this server?",
            detail=(
                f"Host: {details.get('ca_host', '')}\n"
                f"Subject: {details.get('ca_subject', '')}\n"
                f"Expires: {details.get('ca_expires', '')}\n"
                f"SHA-256 fingerprint: {details.get('ca_fingerprint', '')}\n\n"
                "Clipman will trust this authority only for the displayed server host."
            ),
            buttons=["Cancel", "Import"],
            cancel_button=0,
            default_button=0,
        )
        dialog.choose(
            self.window,
            None,
            lambda current, result: self._authority_import_choice(
                current, result, details, authority, authority_status
            ),
        )

    def _authority_import_choice(self, dialog, result, details, authority, authority_status):
        try:
            choice = dialog.choose_finish(result)
        except GLib.Error:
            return
        if choice != 1:
            return
        authority.update(details)
        authority_status.set_text(self._authority_status_text(authority))

    @staticmethod
    def _authority_status_text(authority):
        if not authority.get("ca_cert_pem"):
            return "Private certificate authority: Not configured"
        return (
            f"Private certificate authority for {authority.get('ca_host', '')}. "
            f"Subject: {authority.get('ca_subject', '')}. Expires: {authority.get('ca_expires', '')}.\n"
            f"SHA-256 fingerprint: {authority.get('ca_fingerprint', '')}"
        )

    def _open_pending_connection(self, configuring=False):
        if not self.pending_open_file:
            return False
        path = self.pending_open_file
        self.pending_open_file = None
        self._open_connection_path(path, configuring)
        return True

    def _open_connection_path(self, path, configuring=False):
        try:
            text = pathlib.Path(path).read_text(encoding="utf-8")
        except (OSError, UnicodeError) as error:
            self.show_error(f"Could not read connection file: {error}")
            return
        self.backend.call("connection_details", {"text": text}, lambda message: self._open_connection_response(message, configuring))

    def _open_connection_response(self, message, configuring=False):
        if not message.get("ok"):
            self.show_error(message.get("error")); return
        self._connection_dialog("Import Clipman Server Connection", configuring=configuring, initial=message["result"])

    def _connection_details_response(self, message, fields, authority, authority_status):
        if not message.get("ok"): self.show_error(message.get("error")); return
        fields["server"].set_text(message["result"]["server"]); fields["token"].set_text(message["result"]["token"])
        imported = message["result"]
        if imported.get("ca_cert_pem"):
            authority.update(imported)
        elif authority.get("ca_cert_pem") and authority.get("ca_host", "").casefold() != (urllib.parse.urlparse(imported["server"].replace("clipman://", "http://", 1)).hostname or "").casefold():
            authority.update({"ca_cert_pem": "", "ca_host": "", "ca_subject": "", "ca_expires": "", "ca_fingerprint": ""})
        authority_status.set_text(self._authority_status_text(authority))

    def _setup_response(self, message):
        if not message.get("ok"): self.show_error(message.get("error")); return
        self.backend_configured = True
        self._history_response(message, True)
        self._open_pending_connection()

    def _register_hotkeys(self):
        quick_bindings = {
            entry_id: binding["hotkey"]
            for entry_id, binding in self.preferences.values["quick_paste_bindings"].items()
            if binding.get("hotkey")
        }
        self.hotkeys.register(
            self.preferences.values["show_history_hotkey"],
            self.preferences.values["toggle_monitoring_hotkey"],
            quick_bindings,
            self.preferences.values["secret_hotkeys"],
        )

    def hotkey_registration_changed(self):
        if not self.hotkeys.show_registered or not self.hotkeys.toggle_registered:
            self.set_status(self.hotkeys.summary(), True)

    def hotkey_service_failed(self, message):
        self.hotkeys.show_registered = False
        self.hotkeys.toggle_registered = False
        self.set_status(message, True)
        return False

    def handle_global_hotkey(self, action):
        if action == "show":
            self.toggle_history_window()
        elif action == "toggle":
            self.toggle_monitoring()
        elif isinstance(action, str) and action.startswith("quick:"):
            self._run_quick_paste(action[6:])
        elif isinstance(action, str) and action.startswith("secret:"):
            self.backend.call("secret_get", {"id": action[7:]}, self._secret_hotkey_result)

    def _run_quick_paste(self, entry_id):
        entry = next((item for item in self.entries if item.get("id") == entry_id), None)
        binding = self.preferences.values["quick_paste_bindings"].get(entry_id)
        if not entry or not binding:
            self.preferences.values["quick_paste_bindings"].pop(entry_id, None)
            self.preferences.save(); self._register_hotkeys(); self.sounds.play("skip"); return
        if entry.get("is_template"):
            self.backend.call("resolve_template", {"id": entry_id}, lambda message: self._quick_paste_resolved(message, entry, binding))
        else:
            self._quick_paste_text(entry, binding, entry.get("text", ""))

    def _quick_paste_resolved(self, message, entry, binding):
        if not message.get("ok"):
            self.sounds.play("skip"); return
        self._quick_paste_text(entry, binding, message["result"].get("text", ""))

    def _quick_paste_text(self, entry, binding, text):
        mode = binding.get("mode", "restore")
        clipboard = self.window.get_display().get_clipboard()
        if mode == "restore":
            clipboard.read_text_async(None, lambda source, result, _data: self._quick_paste_previous_read(source, result, entry, text), None)
            return
        rich_text = None if entry.get("is_template") else entry.get("rich_text")
        self._set_clipboard(text, rich_text)
        self.backend.call("touch", {"id": entry["id"]}, self._history_response)
        self.sounds.play("copy")
        if mode == "keep":
            GLib.timeout_add(100, self._quick_paste_send, None)

    def _quick_paste_previous_read(self, clipboard, result, entry, text):
        try:
            previous = clipboard.read_text_finish(result)
        except GLib.Error:
            previous = None
        self._read_rich_clipboard(clipboard, previous, lambda _clipboard, old_text, old_rich: self._quick_paste_with_previous(entry, text, old_text, old_rich))

    def _quick_paste_with_previous(self, entry, text, previous, previous_rich):
        self._set_clipboard(text, None if entry.get("is_template") else entry.get("rich_text"))
        self.backend.call("touch", {"id": entry["id"]}, self._history_response)
        self.sounds.play("copy")
        GLib.timeout_add(100, self._quick_paste_send, {"text": previous, "rich_text": previous_rich})

    def _quick_paste_send(self, restore):
        if not shutil.which("xdotool"):
            self.sounds.play("skip"); return GLib.SOURCE_REMOVE
        try:
            completed = subprocess.run(["xdotool", "key", "--clearmodifiers", "ctrl+v"], capture_output=True, timeout=3, check=False)
            if completed.returncode != 0:
                self.sounds.play("skip"); return GLib.SOURCE_REMOVE
        except (OSError, subprocess.SubprocessError):
            self.sounds.play("skip"); return GLib.SOURCE_REMOVE
        if restore is not None:
            GLib.timeout_add(350, self._restore_quick_paste_clipboard, restore)
        return GLib.SOURCE_REMOVE

    def _restore_quick_paste_clipboard(self, previous):
        text = previous.get("text") if isinstance(previous, dict) else previous
        if text is None:
            self.own_clipboard_text = ""
            self.window.get_display().get_clipboard().set_content(None)
        else:
            rich_text = previous.get("rich_text") if isinstance(previous, dict) else None
            self._set_clipboard(text, rich_text)
        return GLib.SOURCE_REMOVE

    def toggle_history_window(self):
        if self.window.get_visible():
            self.window.set_visible(False)
            return
        if self.preferences.values["dynamic_history_mode"] and self.received_history_section_pending:
            target = self.preferences.values["last_received_section"]
            if target == "links" and not self.preferences.values["links_history_enabled"]:
                target = "text"
            if target == "rich" and not self.preferences.values["rich_text_history_enabled"]:
                target = "text"
            if target != self.section:
                self.section = target
                self.preferences.values["last_section"] = target
                self.preferences.save()
                self.rebuild_list()
            self.received_history_section_pending = False
        _application, self.previous_window_id = active_application_info()
        if not self.preferences.values["save_list_position"]:
            self.select_first_normal()
        self.window.present()
        GLib.idle_add(self.focus_history)

    def _set_monitoring(self, enabled, announce=False):
        enabled = bool(enabled)
        previous = self.preferences.values["monitor_clipboard"]
        self.preferences.values["monitor_clipboard"] = enabled
        if enabled and not previous:
            self.last_clipboard_text = None; self.last_clipboard_files = None; self.last_clipboard_signature = None
            self.last_file_clipboard_monotonic = 0.0
            self.clipboard_baseline_ready = False
            self.capture_current_clipboard = False
            GLib.idle_add(self._initial_clipboard_read)
        if announce:
            self.sounds.play("on" if enabled else "off")
            self.set_status("Clipboard monitoring on." if enabled else "Clipboard monitoring off.", True)

    def toggle_monitoring(self, *_args):
        self._set_monitoring(not self.preferences.values["monitor_clipboard"], True)
        self.preferences.save()

    def show_preferences(self, *_args):
        dialog = Gtk.Dialog(title="Clipman Preferences", transient_for=self.window, modal=True)
        dialog.add_button("Cancel", Gtk.ResponseType.CANCEL); dialog.add_button("Save and Close", Gtk.ResponseType.OK)
        dialog.set_default_size(720, 620)
        area = dialog.get_content_area(); area.set_spacing(10); area.set_margin_top(10); area.set_margin_bottom(10); area.set_margin_start(10); area.set_margin_end(10)
        notebook = Gtk.Notebook(); notebook.set_vexpand(True); area.append(notebook)

        def add_page(title, shortcut):
            page = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=9)
            page.set_margin_top(12); page.set_margin_bottom(12); page.set_margin_start(12); page.set_margin_end(12)
            label = Gtk.Label(label=title)
            label.update_property([Gtk.AccessibleProperty.DESCRIPTION], [shortcut])
            notebook.append_page(page, label)
            return page

        general = add_page("General", "Ctrl+1")
        file_history = add_page("File History", "Ctrl+2")
        hotkeys = add_page("Hotkeys", "Ctrl+3")
        storage = add_page("Storage and Password", "Ctrl+4")
        startup_updates = add_page("Startup and Updates", "Ctrl+5")
        sensitive_data = add_page("Sensitive Data", "Ctrl+6")
        notebook.set_current_page(self.preferences.values["last_preferences_tab"])

        monitor = Gtk.CheckButton(label="Monitor clipboard text, links and files while Clipman is running", active=self.preferences.values["monitor_clipboard"])
        startup = Gtk.CheckButton(label="Add current clipboard item when Clipman starts", active=self.preferences.values["capture_on_start"])
        sounds = Gtk.CheckButton(label="Play sounds", active=self.preferences.values["play_sounds"])
        auto_group = Gtk.CheckButton(label="Automatically group new clips by source application", active=self.preferences.values["auto_group_by_app"])
        auto_remote = Gtk.CheckButton(label="Put new text received from another device on the clipboard", active=self.preferences.values["auto_copy_remote_text"])
        paste_enter = Gtk.CheckButton(label="After Enter, paste into the previous application", active=self.preferences.values["paste_after_enter"])
        paste_enter.set_sensitive(bool(shutil.which("xdotool")) and os.environ.get("XDG_SESSION_TYPE", "").casefold() != "wayland")
        paste_enter.update_property([Gtk.AccessibleProperty.DESCRIPTION], ["Available in X11 sessions when xdotool is installed. This is off by default."])
        dynamic = Gtk.CheckButton(label="Open history to the section that most recently received an item", active=self.preferences.values["dynamic_history_mode"])
        remove_tracking = Gtk.CheckButton(label="Automatically remove tracking from copied links", active=self.preferences.values["auto_remove_url_tracking"])
        links_enabled = Gtk.CheckButton(label="Show Links History", active=self.preferences.values["links_history_enabled"])
        rich_enabled = Gtk.CheckButton(label="Preserve copied formatting and show Rich Text history", active=self.preferences.values["rich_text_history_enabled"])
        rich_enabled.update_property([Gtk.AccessibleProperty.DESCRIPTION], ["When checked, Clipman preserves available HTML and RTF formatting alongside plain text and shows a separate Rich Text history section. Enable this before copying formatted content. This is off by default."])
        save_position = Gtk.CheckButton(label="Save list position", active=self.preferences.values["save_list_position"])
        duplicates = Gtk.CheckButton(label="Keep duplicate text entries", active=self.preferences.values["keep_duplicate_entries"])
        confirm_deletions = Gtk.CheckButton(label="Confirm before deleting entries", active=self.preferences.values["confirm_deletions"])
        for control in (monitor, sounds, auto_group, auto_remote, paste_enter, dynamic, remove_tracking, links_enabled, rich_enabled, save_position, duplicates, confirm_deletions):
            general.append(control)

        startup_run = Gtk.CheckButton(label="Run Clipman when this desktop session starts", active=self.preferences.values["run_at_startup"])
        remove_unavailable = Gtk.CheckButton(label="Automatically remove unavailable file-history events", active=self.preferences.values["auto_remove_unavailable_file_history"])
        file_history.append(remove_unavailable)
        file_history.append(Gtk.Label(label="File history is stored only on this device, encrypted with the history password. Pinned events survive clearing and automatic cleanup.", wrap=True, xalign=0))

        show_hotkey = HotkeyEntry(self.preferences.values["show_history_hotkey"], "Show history hotkey")
        toggle_hotkey = HotkeyEntry(self.preferences.values["toggle_monitoring_hotkey"], "Toggle monitoring hotkey")
        for label, field in (("Show history hotkey", show_hotkey), ("Toggle monitoring hotkey", toggle_hotkey)):
            visible_label = Gtk.Label(label=label, xalign=0)
            visible_label.set_mnemonic_widget(field)
            hotkeys.append(visible_label); hotkeys.append(field)
        hotkey_status = Gtk.Label(label=self.hotkeys.summary(), wrap=True, xalign=0, accessible_role=Gtk.AccessibleRole.STATUS)
        hotkeys.append(hotkey_status)
        hotkeys.append(Gtk.Label(label="Most global hotkeys should use at least two modifiers. One modifier is allowed only with F1 through F12, Grave, or Backslash.", wrap=True, xalign=0))

        startup_updates.append(startup_run)
        startup_updates.append(startup)
        startup_updates.append(Gtk.Label(label="Updates", xalign=0))
        update_keys = ["never", "startup", "hourly", "daily"]
        update_titles = ["Never", "At startup", "Hourly", "Daily"]
        update_frequency = Gtk.DropDown(model=Gtk.StringList.new(update_titles))
        update_frequency.set_selected(update_keys.index(self.preferences.values["update_check_frequency"]))
        update_frequency.update_property([Gtk.AccessibleProperty.LABEL], ["Check for updates"])
        update_label = Gtk.Label(label="Check for updates", xalign=0); update_label.set_mnemonic_widget(update_frequency)
        install_silently = Gtk.CheckButton(label="Install updates silently", active=self.preferences.values["install_updates_silently"])
        install_silently.set_sensitive(update_frequency.get_selected() != 0)
        update_frequency.connect("notify::selected", lambda *_: install_silently.set_sensitive(update_frequency.get_selected() != 0))
        startup_updates.append(update_label); startup_updates.append(update_frequency); startup_updates.append(install_silently)

        connection = Gtk.Button(label="Change Server Connection and Device Name")
        connection.connect("clicked", lambda *_: self.show_connection_settings(dialog))
        storage.append(Gtk.Label(label="Clipman Server connection", xalign=0)); storage.append(connection)
        storage.append(Gtk.Label(label="The server token and remembered history password are protected for this Linux user. Clipman Server stores only encrypted clipboard database blobs and cannot read the history password.", wrap=True, xalign=0))
        storage.append(Gtk.Label(label="Ignored applications, one process or application name per line", wrap=True, xalign=0))
        ignored = Gtk.TextView(wrap_mode=Gtk.WrapMode.WORD_CHAR, vexpand=True)
        ignored.set_accepts_tab(False)
        ignored.update_property([Gtk.AccessibleProperty.LABEL], ["Ignored applications"])
        ignored.get_buffer().set_text("\n".join(self.preferences.values["ignored_applications"]))
        ignored_scroll = Gtk.ScrolledWindow(vexpand=True); ignored_scroll.set_min_content_height(140); ignored_scroll.set_child(ignored); storage.append(ignored_scroll)
        note = Gtk.Label(label="Clipboard monitoring and global hotkeys work normally under X11. Wayland compositors may restrict background clipboard access and global shortcut registration.", wrap=True, xalign=0)
        storage.append(note)

        sensitive_mode = Gtk.DropDown(model=Gtk.StringList.new(["Off", "Exclude from history"]))
        sensitive_mode.set_selected(1 if self.preferences.values["sensitive_data_mode"] == "exclude" else 0)
        sensitive_mode.update_property([Gtk.AccessibleProperty.LABEL], ["Sensitive data mode"])
        mode_label = Gtk.Label(label="Sensitive data mode", xalign=0); mode_label.set_mnemonic_widget(sensitive_mode)
        sensitive_data.append(mode_label); sensitive_data.append(sensitive_mode)
        sensitive_checks = []
        enabled_sensitive = set(self.preferences.values["sensitive_data_presets"])
        for preset_id, title in SENSITIVE_PRESETS:
            control = Gtk.CheckButton(label=title, active=preset_id in enabled_sensitive)
            sensitive_data.append(control); sensitive_checks.append((preset_id, control))
        sensitive_data.append(Gtk.Label(label="Exclusions apply only to automatic clipboard capture. They do not remove text from the system clipboard, and manually adding clipboard content from the Clipman window still works.", wrap=True, xalign=0))

        controller = Gtk.EventControllerKey()
        def preference_key(_controller, keyval, _keycode, state):
            if state & Gdk.ModifierType.CONTROL_MASK and Gdk.KEY_1 <= keyval <= Gdk.KEY_6:
                notebook.set_current_page(keyval - Gdk.KEY_1); return True
            return False
        controller.connect("key-pressed", preference_key); dialog.add_controller(controller)

        def response(_dialog, code):
            self.preferences.values["last_preferences_tab"] = notebook.get_current_page()
            if code == Gtk.ResponseType.OK:
                show_accelerator = show_hotkey.get_accelerator()
                toggle_accelerator = toggle_hotkey.get_accelerator()
                if not show_accelerator or not toggle_accelerator:
                    hotkey_status.set_text("Both global hotkeys are required.")
                    return
                if show_accelerator == toggle_accelerator:
                    hotkey_status.set_text("Show History and Toggle Monitoring must use different hotkeys.")
                    return
                self._set_monitoring(monitor.get_active())
                self.preferences.values.update({
                    "capture_on_start": startup.get_active(), "play_sounds": sounds.get_active(),
                    "auto_group_by_app": auto_group.get_active(), "auto_copy_remote_text": auto_remote.get_active(),
                    "paste_after_enter": paste_enter.get_active(), "dynamic_history_mode": dynamic.get_active(),
                    "auto_remove_url_tracking": remove_tracking.get_active(), "keep_duplicate_entries": duplicates.get_active(),
                    "confirm_deletions": confirm_deletions.get_active(),
                    "links_history_enabled": links_enabled.get_active(), "rich_text_history_enabled": rich_enabled.get_active(), "save_list_position": save_position.get_active(),
                    "run_at_startup": startup_run.get_active(), "show_history_hotkey": show_accelerator,
                    "toggle_monitoring_hotkey": toggle_accelerator,
                    "update_check_frequency": update_keys[update_frequency.get_selected()],
                    "install_updates_silently": install_silently.get_active(),
                    "auto_remove_unavailable_file_history": remove_unavailable.get_active(),
                    "sensitive_data_mode": "exclude" if sensitive_mode.get_selected() == 1 else "off",
                    "sensitive_data_presets": [preset_id for preset_id, control in sensitive_checks if control.get_active()],
                })
                ignored_buffer = ignored.get_buffer()
                ignored_text = ignored_buffer.get_text(ignored_buffer.get_start_iter(), ignored_buffer.get_end_iter(), True)
                self.preferences.values["ignored_applications"] = [line.strip() for line in ignored_text.splitlines() if line.strip()]
                if not self.preferences.values["links_history_enabled"] and self.section == "links":
                    self.section = "text"
                if not self.preferences.values["rich_text_history_enabled"] and self.section == "rich":
                    self.section = "text"
                self.preferences.save(); self._set_startup(startup_run.get_active()); self._start_timers(); self._schedule_update_checks(); self._register_hotkeys(); self.rebuild_list()
            else:
                self.preferences.save()
            dialog.destroy()
        dialog.connect("response", response); dialog.present()

    def _schedule_update_checks(self):
        for name in ("update_poll_source", "startup_update_source"):
            source = getattr(self, name)
            if source:
                GLib.source_remove(source)
                setattr(self, name, 0)
        frequency = self.preferences.values["update_check_frequency"]
        if frequency == "startup":
            self.startup_update_source = GLib.timeout_add_seconds(10, self._startup_update_check)
        elif frequency in ("hourly", "daily"):
            self.startup_update_source = GLib.timeout_add_seconds(10, self._due_update_check)
            self.update_poll_source = GLib.timeout_add_seconds(15 * 60, self._due_update_check_repeating)

    def _startup_update_check(self):
        self.startup_update_source = 0
        self.check_for_updates(False)
        return False

    def _due_update_check(self):
        self.startup_update_source = 0
        self._check_update_if_due()
        return False

    def _due_update_check_repeating(self):
        self._check_update_if_due()
        return True

    def _check_update_if_due(self):
        frequency = self.preferences.values["update_check_frequency"]
        interval = 60 * 60 if frequency == "hourly" else 24 * 60 * 60
        elapsed = int(time.time() * 1000) - self.preferences.values["last_update_check_unix_ms"]
        if elapsed >= interval * 1000:
            self.check_for_updates(False)

    def check_for_updates(self, manual=True):
        if self.update_busy:
            if manual:
                self.set_status("An update check is already running.", True)
            return
        self.update_busy = True
        self.preferences.values["last_update_check_unix_ms"] = int(time.time() * 1000)
        self.preferences.save()
        if manual:
            self.set_status("Checking for Clipman updates...", True)
        threading.Thread(target=self._update_check_worker, args=(manual,), daemon=True).start()

    def _update_check_worker(self, manual):
        candidate = None
        error = ""
        try:
            candidate = find_update(VERSION)
        except UpdateError as exception:
            error = str(exception)
        except Exception as exception:
            error = f"The update check failed: {exception}"
        GLib.idle_add(self._update_check_finished, candidate, error, manual)

    def _update_check_finished(self, candidate, error, manual):
        self.update_busy = False
        if error:
            if manual:
                self.show_error(error)
            return False
        if not candidate:
            if manual:
                dialog = Gtk.AlertDialog(
                    message="Clipman is up to date",
                    detail=f"Installed Linux version: {VERSION}", buttons=["OK"],
                )
                dialog.show(self.window)
            return False
        if not manual and self.preferences.values["install_updates_silently"]:
            self._download_update(candidate)
            return False
        dialog = Gtk.AlertDialog(
            message=f"Clipman {candidate.version} is available",
            detail=f"Download and install {candidate.asset_name}, then relaunch Clipman?",
            buttons=["Install", "Version History", "Later"], cancel_button=2, default_button=0,
        )
        dialog.choose(self.window, None, lambda value, result: self._update_choice(value, result, candidate))
        return False

    def _update_choice(self, dialog, result, candidate):
        try:
            choice = dialog.choose_finish(result)
        except GLib.Error:
            return
        if choice == 0:
            self._download_update(candidate)
        elif choice == 1:
            self._open_uri(candidate.release_url)

    def _download_update(self, candidate):
        if self.update_busy:
            return
        self.update_busy = True
        self.set_status(f"Downloading Clipman {candidate.version}...", True)
        threading.Thread(target=self._download_update_worker, args=(candidate,), daemon=True).start()

    def _download_update_worker(self, candidate):
        package = temporary = None
        error = ""
        try:
            package, temporary = stage_update(candidate)
        except UpdateError as exception:
            error = str(exception)
        except Exception as exception:
            error = f"The update could not be prepared: {exception}"
        GLib.idle_add(self._update_staged, candidate, package, temporary, error)

    def _update_staged(self, candidate, package, temporary, error):
        self.update_busy = False
        if error:
            self.show_error(error)
            return False
        try:
            self._launch_update_installer(candidate, package, temporary)
        except Exception as exception:
            shutil.rmtree(temporary, ignore_errors=True)
            self.show_error(f"The update installer could not start: {exception}")
        return False

    def _launch_update_installer(self, candidate, package, temporary):
        helper = temporary / "clipman-updater.py"
        shutil.copy2(pathlib.Path(__file__).resolve().parent / "clipman-updater.py", helper)
        helper.chmod(0o700)
        launcher = str(pathlib.Path.home() / ".local" / "bin" / "clipman-linux")
        result_path = config_home() / "clipman-linux" / "update-result.json"
        command = [
            sys.executable, str(helper), "--wait-pid", str(os.getpid()),
            "--package", str(package), "--temporary", str(temporary),
            "--launcher", launcher, "--result", str(result_path),
            "--version", candidate.version,
        ]
        systemd_run = shutil.which("systemd-run")
        started = False
        if systemd_run and os.environ.get("DBUS_SESSION_BUS_ADDRESS"):
            unit = f"clipman-linux-updater-{os.getpid()}"
            completed = subprocess.run(
                [systemd_run, "--user", "--unit=" + unit, "--collect"] + command,
                stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL, check=False,
            )
            started = completed.returncode == 0
        if not started:
            subprocess.Popen(
                command, stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL, start_new_session=True,
            )
        self.quit()

    def _consume_update_result(self):
        path = config_home() / "clipman-linux" / "update-result.json"
        try:
            result = json.loads(path.read_text(encoding="utf-8"))
            path.unlink()
        except (OSError, ValueError):
            return
        if result.get("ok"):
            self.set_status(f"Clipman updated to {result.get('version', VERSION)}.", True)
        else:
            self.show_error("Clipman could not install the update. " + str(result.get("error") or "No error details were provided."))

    def show_about(self, *_args):
        about = Gtk.AboutDialog(transient_for=self.window, modal=True, program_name="Clipman for Linux", version=VERSION, comments="Accessible clipboard history for Linux, connected to Clipman Server.", website="https://github.com/OnjLouis/Clipman", license_type=Gtk.License.MIT_X11, authors=["Andre Louis", "Clipman contributors"])
        about.present()

    def _set_startup(self, enabled):
        target = config_home() / "autostart" / "me.onj.clipman.linux.desktop"
        if enabled:
            source = data_home() / "applications" / "me.onj.clipman.linux.desktop"
            target.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
            if source.exists(): shutil.copyfile(source, target)
        elif target.exists(): target.unlink()

    def set_sort(self, mode):
        if self.section == "files":
            if mode == "newest":
                self.preferences.values["file_sort_mode"], self.preferences.values["file_sort_descending"] = "time", True
            elif mode == "oldest":
                self.preferences.values["file_sort_mode"], self.preferences.values["file_sort_descending"] = "time", False
            elif mode in ("files", "name", "operation", "source", "manual"):
                self.preferences.values["file_sort_mode"] = mode
            elif mode == "text":
                self.preferences.values["file_sort_mode"] = "name"
            else:
                self.sounds.play("skip"); return
        else:
            if mode not in ("manual", "newest", "oldest", "text", "group", "device"):
                self.sounds.play("skip"); return
            self.preferences.values["sort_mode"] = mode
        self.preferences.save(); self.rebuild_list(); self.set_status("Sort: " + mode.replace("_", " ").title() + ".", True)

    def open_settings_folder(self, *_args):
        folder = pathlib.Path.home() / ".clipman"
        folder.mkdir(mode=0o700, parents=True, exist_ok=True)
        self._open_uri(folder.as_uri())

    def show_diagnostics(self, *_args):
        rich_entries = [normalize_rich_text(entry.get("rich_text")) for entry in self.entries]
        rich_entries = [value for value in rich_entries if value]
        rich_html = sum(1 for value in rich_entries if value.get("html_fragment"))
        rich_rtf = sum(1 for value in rich_entries if value.get("rtf_base64"))
        rich_bytes = sum(
            len(value.get("html_fragment", "").encode("utf-8")) +
            len(base64.b64decode(value.get("rtf_base64", "")))
            for value in rich_entries
        )
        text = "\n".join([
            f"Clipman for Linux: {VERSION}",
            f"Build: {VERSION}.0",
            f"Build stamp: {BUILD_STAMP}",
            f"Display backend: {os.environ.get('XDG_SESSION_TYPE', 'Unknown')}",
            f"Monitoring: {'On' if self.preferences.values['monitor_clipboard'] else 'Off'}",
            f"History state: {'Offline read-only cache' if self.offline else 'Connected'}",
            f"Text entries: {sum(1 for entry in self.entries if entry.get('section') == 'text' and not entry.get('rich_text'))}",
            f"Link entries: {sum(1 for entry in self.entries if entry.get('section') == 'links' and not entry.get('rich_text'))}",
            f"Rich-text entries: {len(rich_entries)} ({rich_html} HTML, {rich_rtf} RTF, {rich_bytes} stored bytes)",
            f"File-history events: {len(self.file_events)}",
            f"Global hotkeys: {self.hotkeys.summary()}",
            f"GUI preferences: {self.preferences.path}",
            f"Clipman data folder: {pathlib.Path.home() / '.clipman'}",
        ])
        dialog = Gtk.Dialog(title="Clipman Diagnostics", transient_for=self.window, modal=True)
        dialog.add_button("Close", Gtk.ResponseType.CLOSE)
        area = dialog.get_content_area(); area.set_margin_top(12); area.set_margin_bottom(12); area.set_margin_start(12); area.set_margin_end(12)
        view = Gtk.TextView(editable=False, cursor_visible=True, wrap_mode=Gtk.WrapMode.WORD_CHAR)
        view.set_accepts_tab(False); view.get_buffer().set_text(text); view.update_property([Gtk.AccessibleProperty.LABEL], ["Diagnostics"])
        area.append(view); dialog.set_default_size(680, 480)
        dialog.connect("response", lambda d, _r: d.destroy()); dialog.present()

    def open_uri(self, uri):
        self._open_uri(uri)

    def open_manual(self, *_args):
        manual = pathlib.Path(__file__).resolve().parent / "Manual.html"
        Gio.AppInfo.launch_default_for_uri(manual.as_uri(), None)

    def open_version_history(self, *_args):
        self._open_uri("https://github.com/OnjLouis/Clipman/releases")

    def open_project(self, *_args):
        self._open_uri("https://github.com/OnjLouis/Clipman")

    @staticmethod
    def _open_uri(uri):
        if uri:
            Gio.AppInfo.launch_default_for_uri(uri, None)

    def show_error(self, message):
        self.sounds.play("skip"); self.set_status(message, True)
        dialog = Gtk.AlertDialog(message="Clipman could not complete that action", detail=message, buttons=["OK"])
        dialog.show(self.window)

    def _fatal_error(self, message): self.show_error(message)

    def set_status(self, message, announce=False):
        if self.status.get_text() != message:
            self.status.set_text(message)
        if announce:
            self.status.update_property([Gtk.AccessibleProperty.LABEL], [message])

    def _hide_window(self, *_args):
        self.window.set_visible(False)
        return True

    @staticmethod
    def format_date(milliseconds):
        if not milliseconds: return "Unknown"
        return time.strftime("%Y-%m-%d %H:%M:%S", time.localtime(milliseconds / 1000))


if __name__ == "__main__":
    app = ClipmanApplication()
    raise SystemExit(app.run(sys.argv))
