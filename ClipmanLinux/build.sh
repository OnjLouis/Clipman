#!/bin/sh
set -eu
export PYTHONDONTWRITEBYTECODE=1

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
repo=$(CDPATH= cd -- "$script_dir/.." && pwd)
output=${1:-"${TMPDIR:-/tmp}/clipman-linux-build"}
case "$output" in
    /*) ;;
    *) output="$(pwd -P)/$output" ;;
esac
stage="$output/Clipman-Linux-GUI"
architecture=$(uname -m)
version=$(tr -d '\r\n' < "$script_dir/VERSION")
shared_version=$(sed -nE 's/.*AssemblyInformationalVersion\("([^"]+)"\).*/\1/p' "$repo/src/AssemblyInfo.cs" | head -n 1)
build_stamp=$(sed -nE 's/.*BuildStampUtcMs = ([0-9]+)L;.*/\1/p' "$repo/src/BuildInfo.cs" | head -n 1)
if [ -z "$shared_version" ] || [ "$version" != "$shared_version" ]; then
    printf 'Linux version %s does not match shared desktop version %s.\n' "$version" "${shared_version:-missing}" >&2
    exit 1
fi
if [ -z "$build_stamp" ]; then
    printf 'Could not read the shared Clipman build stamp.\n' >&2
    exit 1
fi
archive="Clipman-Linux-GUI-$version-linux-$architecture.tar.gz"

rm -rf "$output"
mkdir -p "$stage/libexec" "$stage/sounds"
cd "$repo/ClipmanLinuxBackend"
go test ./...
CGO_ENABLED=0 go build -trimpath -ldflags="-s -w -X main.version=$version" -o "$stage/libexec/clipman-gui-backend" ./cmd/clipman-gui-backend
cd "$repo"
python3 -c 'import pathlib; source=pathlib.Path("ClipmanLinux/clipman.py"); compile(source.read_text(encoding="utf-8"), str(source), "exec")'
python3 -c 'import pathlib; source=pathlib.Path("ClipmanLinux/clipman-hotkeys.py"); compile(source.read_text(encoding="utf-8"), str(source), "exec")'
python3 -c 'import pathlib; source=pathlib.Path("ClipmanLinux/update_service.py"); compile(source.read_text(encoding="utf-8"), str(source), "exec")'
python3 -c 'import pathlib; source=pathlib.Path("ClipmanLinux/clipman-updater.py"); compile(source.read_text(encoding="utf-8"), str(source), "exec")'
python3 - <<'PY'
import hashlib
import io
import importlib.util
import inspect
import json
import os
import pathlib
import shutil
import shlex
import subprocess
import sys
import tarfile
import tempfile
import time
import types

path = pathlib.Path("ClipmanLinux/clipman.py")
source = path.read_text(encoding="utf-8")
for accessible_label in (
    '["Formatted clipboard text" if rendered_html else "Clipboard text"]',
):
    assert accessible_label in source
assert "GLib.timeout_add_seconds(2, self._poll)" in source
assert 'self.clipboard.connect("changed", self._clipboard_changed)' in source
assert '"x-special/mate-copied-files"' in source
assert "GLib.timeout_add(100, self._poll_changed_clipboard)" in source
assert "if self.clipboard_change_source:\n            return GLib.SOURCE_CONTINUE" in source
assert "GLib.timeout_add_seconds(1, self._poll_clipboard)" not in source
assert "self.refresh(False)\n        self._poll_clipboard()" in source
assert "stream.read_bytes_async(" in source
assert "stream.read_bytes(1024 * 1024" not in source
assert "self.clipboard_baseline_ready = False" in source
assert "first = not self.clipboard_baseline_ready" in source
assert "not formats.get_mime_types() and not formats.get_gtypes()" in source
assert "poll_seconds" not in source
assert '"last_group"' not in source
assert '"app.refresh"' not in source
assert '"save_current_clipboard_hotkey": ""' in source
assert 'elif action == "save":\n            self.add_clipboard()' in source
assert 'Save Current Clip_board to History' in source
assert 'self.preferences.values["save_current_clipboard_hotkey"]' in source
assert "self.status.set_selectable(True)" not in source
assert "controller.set_propagation_phase(Gtk.PropagationPhase.CAPTURE)" in source
assert "self.cycle_section(-1 if state & Gdk.ModifierType.SHIFT_MASK else 1)" in source
assert "Gtk.AccessibleRole.TAB_LIST" in source
assert "Gtk.AccessibleRole.TAB" in source
assert "Gtk.AccessibleState.SELECTED" in source
assert "def _section_tab_key_pressed" in source
assert 'self.switch_section(section, focus_history=False)' in source
assert 'self.section_button =' not in source
assert '"move-tab-left": lambda *_: self.move_history_tab(-1)' in source
assert '"app.move-tab-left": ["<Alt>Left"], "app.move-tab-right": ["<Alt>Right"]' in source
assert 'self.preferences.values["history_tab_order"] = order' in source
assert 'Gdk.KEY_t: "text", Gdk.KEY_l: "links", Gdk.KEY_r: "rich", Gdk.KEY_i: "files"' in source
assert '"rich_text_history_enabled": False' in source
assert '"app.rich": ["<Alt>r"]' in source
assert 'RICH_HTML_MIME_TYPES = ("text/html",)' in source
assert 'self._set_clipboard(text, rich_text)' in source
assert 'populate_safe_rich_buffer(text.get_buffer(), rich_text, entry["text"])' in source
assert "self.move_tab_focus(-1 if keyval == Gdk.KEY_ISO_Left_Tab" in source
assert "Gtk.PopoverMenuBar.new_from_model(self._menu_model())" in source
assert "Gtk.SelectionMode.MULTIPLE" in source
assert 'Gtk.Label(label="_Filter:", use_underline=True)' in source
assert 'self.group_picker.set_enable_search(True)' in source
assert 'updated_filters.append(("divider", "", "Devices"))' in source
assert '("group", value, "Group: " + value)' not in source
assert '("device", value, "Device: " + value)' not in source
assert 'entry.get("group", "").casefold() != filter_value.casefold()' in source
assert 'menu.append_submenu("Grou_ps", self.groups_menu)' in source
assert '"app.diagnostics": ["<Alt>F1"]' in source

backend_source = pathlib.Path("ClipmanLinuxBackend/cmd/clipman-gui-backend/main.go").read_text(encoding="utf-8")
assert '`json:"rich_text,omitempty"`' in backend_source
assert 'clearRichText(e, now)' in backend_source
assert '("_Source application", "source")' in source
assert '("Set as _quick-paste target", "quick-assign")' in source
assert "GLib.idle_add(quick_hotkey.grab_focus)" not in source
assert '"text", "group", "device")' in source
assert '"operation", "source")' in source
assert "Delete {secret.get('name', 'this secret')}?" in source
assert '"update_many"' not in source or 'self.backend.call("update_many"' in source
assert '"quick_paste_bindings": {}' in source
assert '"secret_hotkeys": {}' in source
assert '"sensitive_data_mode": "off"' in source
assert '"paste_after_enter": False' in source
assert "Gtk.MenuButton" not in source
assert "if not command_modifiers and keyval == Gdk.KEY_F4:" in source
assert "keyval == Gdk.KEY_Delete and self._focus_is_in_history()" in source
assert 'separator.clipman_separator = True' in source
assert 'separator.set_activatable(False)' in source
assert 'row.set_header(header)' not in source
assert 'def _row_for_entry_id(self, entry_id):' in source
assert "unicode_value = Gdk.keyval_to_unicode(keyval)" in source
assert "keyval in (Gdk.KEY_Return, Gdk.KEY_KP_Enter) and self._focus_is_in_history()" in source
assert "chr(keyval)" not in source
assert "text_view.set_accepts_tab(False)" in source
assert "text.set_accepts_tab(False)" in source
assert '"check-updates": lambda *_: self.check_for_updates(True)' in source
assert '"update_check_frequency": "never"' in source
assert '"install_updates_silently": False' in source
assert "if not self._open_pending_connection(configuring=True):" in source
assert 'def show_connection_settings(self, parent):' in source
assert '(initial or {}).get("machine") or self.machine_name or os.uname().nodename' in source
assert 'Leave blank to keep the stored server token' in source
assert 'Leave blank to keep the stored history password' in source
assert 'set_placeholder_text("Stored' not in source
assert "if self.backend_is_ready:\n            self._open_pending_connection(configuring=not self.backend_configured)" in source
assert 'lambda message: self._open_connection_response(message, configuring)' in source
assert 'rm -f "$config/autostart/me.onj.clipman.linux.desktop"' in pathlib.Path("ClipmanLinux/uninstall.sh").read_text(encoding="utf-8")
manual = pathlib.Path("ClipmanLinux/Manual.html").read_text(encoding="utf-8")
for required in (
    "checks the server every two seconds", "File History", "Groups", "Import and export",
    "Ctrl+Shift+1", "Alt+I", "Alt+R", "Rich Text history", "Storage and Password", "Clipman project on GitHub",
    "Quick Paste", "Secrets", "Sensitive Data", "Ctrl+A", "six tabs", "tab list", "Left Arrow",
):
    assert required in manual, required
for stale in ("early Linux preview", "Preview limitations", "Ctrl+R", "File history, Secrets"):
    assert stale not in manual, stale
helper_source = pathlib.Path("ClipmanLinux/clipman-hotkeys.py").read_text(encoding="utf-8")
assert 'gi.require_version("Gtk", "3.0")' in helper_source
assert 'gi.require_version("Keybinder", "3.0")' in helper_source
assert 'gi.require_version("Gtk", "4.0")' not in helper_source
assert "while sys.stdin.buffer.read(1):" in helper_source
assert 'parser.add_argument("--binding", action="append", default=[])' in helper_source
spec = importlib.util.spec_from_file_location("clipman_linux_build_test", path)
sys.path.insert(0, str(path.parent.resolve()))
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
import update_service

def validate_menu_mnemonics(model):
    mnemonics = set()
    for index in range(model.get_n_items()):
        value = model.get_item_attribute_value(index, "label", None)
        label = value.unpack() if value else ""
        assert label.count("_") == 1, f"Menu item must have one mnemonic: {label!r}"
        marker = label.index("_")
        assert marker + 1 < len(label), f"Menu mnemonic is incomplete: {label!r}"
        mnemonic = label[marker + 1].casefold()
        assert mnemonic not in mnemonics, f"Duplicate menu mnemonic {mnemonic!r} in {label!r}"
        mnemonics.add(mnemonic)
        submenu = model.get_item_link(index, "submenu")
        if submenu:
            validate_menu_mnemonics(submenu)

menu_harness = types.SimpleNamespace(section="text")
menu_harness._populate_section_menus = types.MethodType(module.ClipmanApplication._populate_section_menus, menu_harness)
menu_harness._populate_text_actions = types.MethodType(module.ClipmanApplication._populate_text_actions, menu_harness)
menu_harness._populate_quick_paste_menu = types.MethodType(module.ClipmanApplication._populate_quick_paste_menu, menu_harness)
menu_harness.entries = []
menu_harness.preferences = types.SimpleNamespace(values={"quick_paste_bindings": {}})
top_menu = module.ClipmanApplication._menu_model(menu_harness)
validate_menu_mnemonics(top_menu)
assert isinstance(menu_harness.groups_menu, module.Gio.Menu)
menu_harness.section = "files"
menu_harness._populate_section_menus()
validate_menu_mnemonics(top_menu)
assert menu_harness.actions_menu.get_n_items() == 0

assert list(inspect.signature(module.ClipmanApplication.do_open).parameters) == ["self", "files", "_n_files", "_hint"]

assert module.is_file_manager_clipboard_payload("x-special/nautilus-clipboard\ncopy\nfile:///tmp/test")
assert module.is_file_manager_clipboard_payload("x-special/gnome-copied-files\ncut\nfile:///tmp/test")
assert module.is_file_manager_clipboard_payload("x-special/mate-copied-files\ncopy\nfile:///tmp/test")
assert module.is_file_manager_clipboard_payload("copy\nfile:///tmp/test")
assert module.is_file_manager_clipboard_payload("cut\nfile:///tmp/one\nfile:///tmp/two")
assert not module.is_file_manager_clipboard_payload("copy\nordinary text")
assert not module.is_file_manager_clipboard_payload("ordinary clipboard text")
file_signature = ("files", ("/tmp/one.txt", "/tmp/two.txt"), "Copy")
assert module.is_companion_file_clipboard_text("/tmp/one.txt\n/tmp/two.txt", file_signature)
assert module.is_companion_file_clipboard_text("/tmp/two.txt\n/tmp/one.txt", file_signature)
assert not module.is_companion_file_clipboard_text("/tmp/one.txt", file_signature)
assert not module.is_companion_file_clipboard_text("ordinary text", file_signature)
assert module.HotkeyEntry.is_safe(module.Gdk.KEY_backslash, module.Gdk.ModifierType.CONTROL_MASK | module.Gdk.ModifierType.ALT_MASK)
assert module.HotkeyEntry.is_safe(module.Gdk.KEY_grave, module.Gdk.ModifierType.CONTROL_MASK)
assert module.HotkeyEntry.is_safe(module.Gdk.KEY_F1, module.Gdk.ModifierType.ALT_MASK)
assert not module.HotkeyEntry.is_safe(module.Gdk.KEY_a, module.Gdk.ModifierType.CONTROL_MASK)
assert not module.HotkeyEntry.is_safe(module.Gdk.KEY_comma, module.Gdk.ModifierType.CONTROL_MASK)
assert not module.HotkeyEntry.is_safe(module.Gdk.KEY_space, module.Gdk.ModifierType.CONTROL_MASK | module.Gdk.ModifierType.ALT_MASK)
assert module.Gdk.keyval_to_unicode(module.Gdk.KEY_F4) == 0
assert module.Gdk.keyval_to_unicode(module.Gdk.KEY_a) == ord("a")
assert module.entry_summary({"text": "Multiline Linux capture\nLine two\nLine three"}) == "Multiline Linux capture Line two Line three"
assert module.entry_summary({"name": "Named", "text": "Line one\nLine two"}) == "Named: Line one Line two"
assert module.is_standalone_link("https://example.com/path")
assert module.is_standalone_link("clipman://server.example:1234")
assert not module.is_standalone_link("Some text https://example.com/path")
copied_with_enter = []
enter_harness = types.SimpleNamespace(
    _focus_is_in_history=lambda: True,
    copy_selected=lambda *args, **kwargs: copied_with_enter.append(kwargs.get("close")),
)
assert module.ClipmanApplication._key_pressed(enter_harness, None, module.Gdk.KEY_Return, 0, 0)
assert module.ClipmanApplication._key_pressed(enter_harness, None, module.Gdk.KEY_KP_Enter, 0, 0)
assert copied_with_enter == [True, True]

fake_release = {
    "tag_name": "v9.8.7", "html_url": "https://github.com/OnjLouis/Clipman/releases/tag/v9.8.7",
    "draft": False, "prerelease": False,
    "assets": [{
        "name": "Clipman-Linux-GUI-9.8.7-linux-x86_64.tar.gz",
        "browser_download_url": "https://github.com/OnjLouis/Clipman/releases/download/v9.8.7/Clipman-Linux-GUI-9.8.7-linux-x86_64.tar.gz",
        "digest": "sha256:" + "a" * 64, "size": 100,
    }],
}
candidate = update_service.find_update("1.0.0", [fake_release], "x86_64")
assert candidate and candidate.version == "9.8.7"
assert update_service.find_update("9.8.7", [fake_release], "x86_64") is None
assert update_service.find_update("1.0.0", [fake_release], "aarch64") is None
assert update_service.trusted_download_url("https://release-assets.githubusercontent.com/example")
assert not update_service.trusted_download_url("http://github.com/example")
assert not update_service.trusted_download_url("https://github.com.example.invalid/update")

with tempfile.TemporaryDirectory() as directory:
    package = pathlib.Path(directory) / "Clipman-Linux-GUI-9.8.7"
    package.mkdir()
    for name in (
        "clipman.py", "clipman-hotkeys.py", "clipman-updater.py", "update_service.py",
        "install.sh", "Manual.html", "LICENSE.txt",
    ):
        (package / name).write_text("test\n", encoding="utf-8")
    (package / "VERSION").write_text("9.8.7\n", encoding="utf-8")
    (package / "BUILD_STAMP").write_text("1785011869882\n", encoding="utf-8")
    backend = package / "libexec" / "clipman-gui-backend"
    backend.parent.mkdir(); backend.write_text("test\n", encoding="utf-8")
    payload_file = pathlib.Path(directory) / "update.tar.gz"
    with tarfile.open(payload_file, "w:gz") as archive:
        archive.add(package, arcname=package.name)
    payload = payload_file.read_bytes()
    staged_candidate = update_service.UpdateCandidate(
        "9.8.7", "https://github.com/OnjLouis/Clipman/releases/tag/v9.8.7",
        "https://github.com/OnjLouis/Clipman/releases/download/v9.8.7/update.tar.gz",
        "update.tar.gz", "sha256:" + hashlib.sha256(payload).hexdigest(), len(payload),
    )
    staged, temporary = update_service.stage_update(
        staged_candidate, opener=lambda *_args, **_kwargs: io.BytesIO(payload),
    )
    assert (staged / "VERSION").read_text(encoding="utf-8").strip() == "9.8.7"
    shutil.rmtree(temporary)

unsafe = tarfile.TarInfo("../outside")
try:
    update_service._safe_members(types.SimpleNamespace(getmembers=lambda: [unsafe]))
    raise AssertionError("Unsafe update path was accepted")
except update_service.UpdateError:
    pass

with tempfile.TemporaryDirectory() as directory:
    root = pathlib.Path(directory)
    temporary = root / "update-work"
    package = temporary / "package"
    package.mkdir(parents=True)
    installed = root / "installed"
    launched = root / "launched"
    result_path = root / "result.json"
    installer = package / "install.sh"
    installer.write_text(f"#!/bin/sh\nprintf installed > {shlex.quote(str(installed))}\n", encoding="utf-8")
    installer.chmod(0o755)
    launcher = root / "launcher.sh"
    launcher.write_text(f"#!/bin/sh\nprintf launched > {shlex.quote(str(launched))}\n", encoding="utf-8")
    launcher.chmod(0o755)
    environment = os.environ.copy()
    environment.pop("DBUS_SESSION_BUS_ADDRESS", None)
    completed = subprocess.run([
        sys.executable, "ClipmanLinux/clipman-updater.py",
        "--wait-pid", "99999999", "--package", str(package),
        "--temporary", str(temporary), "--launcher", str(launcher),
        "--result", str(result_path), "--version", "9.8.7",
    ], env=environment, timeout=15, check=False)
    assert completed.returncode == 0
    for _ in range(30):
        if launched.exists(): break
        time.sleep(0.1)
    assert installed.read_text(encoding="utf-8") == "installed"
    assert launched.read_text(encoding="utf-8") == "launched"
    assert json.loads(result_path.read_text(encoding="utf-8")) == {"ok": True, "version": "9.8.7", "error": ""}
    assert not temporary.exists()

with tempfile.TemporaryDirectory() as directory:
    root = pathlib.Path(directory)
    temporary = root / "update-work"
    package = temporary / "package"
    package.mkdir(parents=True)
    (package / "install.sh").write_text("#!/bin/sh\nexit 0\n", encoding="utf-8")
    (package / "install.sh").chmod(0o755)
    launched = root / "launched"
    launcher = root / "launcher.sh"
    launcher.write_text(f"#!/bin/sh\nprintf launched > {shlex.quote(str(launched))}\n", encoding="utf-8")
    launcher.chmod(0o755)
    blocked_result = root / "result.json"
    blocked_result.mkdir()
    environment = os.environ.copy()
    environment.pop("DBUS_SESSION_BUS_ADDRESS", None)
    completed = subprocess.run([
        sys.executable, "ClipmanLinux/clipman-updater.py",
        "--wait-pid", "99999999", "--package", str(package),
        "--temporary", str(temporary), "--launcher", str(launcher),
        "--result", str(blocked_result), "--version", "9.8.7",
    ], env=environment, timeout=15, check=False)
    assert completed.returncode == 0
    for _ in range(30):
        if launched.exists(): break
        time.sleep(0.1)
    assert launched.read_text(encoding="utf-8") == "launched"
    assert not temporary.exists()

assert module.normalize_history_tab_order(["FILES", "text", "files", "unknown"]) == ["files", "text", "links", "rich"]
assert module.move_history_tab_order(["text", "links", "rich", "files"], "text", 1, True, True) == ["links", "text", "rich", "files"]
assert module.move_history_tab_order(["text", "links", "rich", "files"], "text", 1, False, True) == ["rich", "links", "text", "files"]
assert module.move_history_tab_order(["text", "links", "rich", "files"], "text", -1, True, True) is None
section_harness = types.SimpleNamespace(section="text", switched=[], preferences=types.SimpleNamespace(values={"links_history_enabled": True, "rich_text_history_enabled": True, "history_tab_order": ["text", "links", "rich", "files"]}))
section_harness.switch_section = lambda section: section_harness.switched.append(section)
section_harness._available_sections = lambda: module.ClipmanApplication._available_sections(section_harness)
module.ClipmanApplication.cycle_section(section_harness, 1)
assert section_harness.switched == ["links"]
section_harness.section = "links"
module.ClipmanApplication.cycle_section(section_harness, 1)
assert section_harness.switched == ["links", "rich"]
section_harness.section = "rich"
module.ClipmanApplication.cycle_section(section_harness, 1)
assert section_harness.switched == ["links", "rich", "files"]
section_harness.section = "files"
module.ClipmanApplication.cycle_section(section_harness, 1)
assert section_harness.switched == ["links", "rich", "files", "text"]
module.ClipmanApplication.cycle_section(section_harness, -1)
assert section_harness.switched == ["links", "rich", "files", "text", "rich"]
for links_enabled, rich_enabled, expected in (
    (False, False, ["text", "files"]),
    (True, False, ["text", "links", "files"]),
    (False, True, ["text", "rich", "files"]),
    (True, True, ["text", "links", "rich", "files"]),
):
    section_harness.preferences.values.update({
        "links_history_enabled": links_enabled,
        "rich_text_history_enabled": rich_enabled,
        "history_tab_order": ["text", "links", "rich", "files"],
    })
    assert section_harness._available_sections() == expected
section_harness.preferences.values.update({
    "links_history_enabled": True,
    "rich_text_history_enabled": True,
    "history_tab_order": ["files", "rich", "text", "links"],
})
assert section_harness._available_sections() == ["files", "rich", "text", "links"]

rich_payload = module.normalize_rich_text({
    "html_fragment": "<p><b>Bold</b><script>hidden()</script></p>",
    "rtf_base64": "e1xccnRmMSBCb2xkfQ==",
    "preferred_format": "Html",
})
assert rich_payload and rich_payload["preferred_format"] == "Html"
rich_buffer = module.Gtk.TextBuffer()
assert module.populate_safe_rich_buffer(rich_buffer, rich_payload, "fallback")
rich_preview = rich_buffer.get_text(rich_buffer.get_start_iter(), rich_buffer.get_end_iter(), True)
assert "Bold" in rich_preview and "hidden" not in rich_preview
assert module.normalize_rich_text({"html_fragment": "x" * (module.MAX_RICH_HTML_BYTES + 1)}) is None

hotkey_events = []
hotkey_application = types.SimpleNamespace(
    hotkey_registration_changed=lambda: hotkey_events.append("ready"),
    handle_global_hotkey=lambda action: hotkey_events.append(action),
)
hotkey_manager = types.SimpleNamespace(
    generation=7, show_registered=False, toggle_registered=False,
    save_configured=True, save_registered=False, quick_registered={},
    application=hotkey_application,
)
assert module.GlobalHotkeys._deliver(hotkey_manager, {"event": "ready", "registered": {"show": True, "toggle": True, "save": True, "quick:entry": True}}, 7) is False
assert hotkey_manager.show_registered and hotkey_manager.toggle_registered
assert hotkey_manager.save_registered
assert hotkey_manager.quick_registered == {"entry": True}
assert module.GlobalHotkeys._deliver(hotkey_manager, {"event": "activated", "action": "show"}, 7) is False
assert module.GlobalHotkeys._deliver(hotkey_manager, {"event": "activated", "action": "toggle"}, 7) is False
assert hotkey_events == ["ready", "show", "toggle"]

pending = types.SimpleNamespace(pending_open_file="/tmp/example.clpconf", opened=[])
pending._open_connection_path = lambda path, configuring=False: pending.opened.append((path, configuring))
assert module.ClipmanApplication._open_pending_connection(pending, True)
assert pending.opened == [("/tmp/example.clpconf", True)]
assert pending.pending_open_file is None
assert not module.ClipmanApplication._open_pending_connection(pending)

description = module.ClipmanApplication.entry_description(
    types.SimpleNamespace(section="text"),
    {"display": "Example", "pinned": True, "is_template": True, "group": "Tests", "device": "Fedora"},
    2,
    5,
)
assert description == "Group: Tests; Device: Fedora; 2 of 5"

with tempfile.TemporaryDirectory() as directory:
    old_config_home = os.environ.get("XDG_CONFIG_HOME")
    os.environ["XDG_CONFIG_HOME"] = directory
    settings = pathlib.Path(directory) / "clipman-linux" / "settings.json"
    settings.parent.mkdir(parents=True)
    settings.write_text(json.dumps({
        "monitor_clipboard": "not-a-boolean",
        "last_section": "files",
        "last_received_section": "invalid",
        "last_preferences_tab": 99,
        "sort_mode": "invalid",
        "poll_seconds": 99,
    }), encoding="utf-8")
    preferences = module.Preferences()
    assert preferences.values["monitor_clipboard"] is True
    assert preferences.values["last_section"] == "files"
    assert preferences.values["last_received_section"] == "text"
    assert preferences.values["last_preferences_tab"] == 0
    assert preferences.values["sort_mode"] == "manual"
    assert "poll_seconds" not in preferences.values
    settings.write_text(json.dumps({"sort_mode": "group", "file_sort_mode": "source"}), encoding="utf-8")
    preferences = module.Preferences()
    assert preferences.values["sort_mode"] == "group"
    assert preferences.values["file_sort_mode"] == "source"
    if old_config_home is None:
        del os.environ["XDG_CONFIG_HOME"]
    else:
        os.environ["XDG_CONFIG_HOME"] = old_config_home

class Clipboard:
    def __init__(self, text): self.text = text
    def read_text_finish(self, _result): return self.text

class Formats:
    def __init__(self, mime_types=(), gtypes=()): self.mime_types, self.gtypes = mime_types, gtypes
    def get_mime_types(self): return self.mime_types
    def get_gtypes(self): return self.gtypes
    def contain_mime_type(self, mime_type): return mime_type in self.mime_types

class PollClipboard:
    def __init__(self, mime_types): self.formats, self.calls = Formats(mime_types), []
    def get_formats(self): return self.formats
    def read_async(self, mime_types, *_args): self.calls.append(("files", tuple(mime_types)))
    def read_text_async(self, *_args): self.calls.append(("text", ()))

poll_clipboard = PollClipboard(("x-special/mate-copied-files", "text/uri-list", "text/plain"))
poll = types.SimpleNamespace(
    ready_for_history=True,
    preferences=types.SimpleNamespace(values={"monitor_clipboard": True}),
    window=types.SimpleNamespace(get_display=lambda: types.SimpleNamespace(get_clipboard=lambda: poll_clipboard)),
    clipboard_read_busy=False,
    clipboard_change_source=0,
    clipboard_source_application="",
    _clipboard_files_read=lambda *_args: None,
    _clipboard_read=lambda *_args: None,
)
module.ClipmanApplication._poll_clipboard(poll)
assert poll_clipboard.calls == [("files", ("x-special/mate-copied-files",))]

pending_clipboard = PollClipboard(("text/plain",))
pending = types.SimpleNamespace(
    ready_for_history=True,
    preferences=types.SimpleNamespace(values={"monitor_clipboard": True}),
    window=types.SimpleNamespace(get_display=lambda: types.SimpleNamespace(get_clipboard=lambda: pending_clipboard)),
    clipboard_read_busy=False,
    clipboard_change_source=123,
)
module.ClipmanApplication._poll_clipboard(pending)
assert pending_clipboard.calls == []

initial = types.SimpleNamespace(
    clipboard=types.SimpleNamespace(get_formats=lambda: Formats()),
    clipboard_baseline_ready=False, capture_current_clipboard=True, polls=0,
)
initial._poll_clipboard = lambda: setattr(initial, "polls", initial.polls + 1)
assert module.ClipmanApplication._initial_clipboard_read(initial) == module.GLib.SOURCE_REMOVE
assert initial.clipboard_baseline_ready and not initial.capture_current_clipboard and initial.polls == 0

initial = types.SimpleNamespace(
    clipboard=types.SimpleNamespace(get_formats=lambda: Formats(("text/plain",))),
    clipboard_baseline_ready=False, capture_current_clipboard=False, polls=0,
)
initial._poll_clipboard = lambda: setattr(initial, "polls", initial.polls + 1)
module.ClipmanApplication._initial_clipboard_read(initial)
assert not initial.clipboard_baseline_ready and initial.polls == 1

def harness(capture_on_start):
    value = types.SimpleNamespace(
        preferences=types.SimpleNamespace(values={
            "capture_on_start": capture_on_start, "ignored_applications": [],
            "sensitive_data_mode": "off", "sensitive_data_presets": [],
            "rich_text_history_enabled": False,
            "auto_remove_url_tracking": False,
            "clipmerge_enabled": False, "clipmerge_window_ms": 500,
            "clipmerge_separator_mode": "NewLine", "clipmerge_custom_separator": "",
            "auto_group_by_app": False,
        }),
        last_clipboard_text=None,
        last_clipboard_files=None,
        last_file_clipboard_monotonic=0.0,
        last_clipboard_signature=None,
        clipboard_baseline_ready=False,
        own_clipboard_text=None,
        clipboard_source_application="",
        capture_current_clipboard=capture_on_start,
        clipboard_read_busy=True,
        clipmerge=module.ClipMergeDetector(),
        captured=[],
        sounds=types.SimpleNamespace(play=lambda _name: None),
    )
    value._put_text = lambda text, quiet=False, automatic=False, source="", rich_text=None, capture_observation=None: value.captured.append((text, quiet, automatic, source))
    value._capture_file_paths = lambda *_args: None
    value._standalone_image_mime = lambda _clipboard: None
    value._clear_clipboard_image_file = lambda: None
    value._process_clipboard_text = lambda clipboard, text, rich: module.ClipmanApplication._process_clipboard_text(value, clipboard, text, rich)
    value._read_rich_clipboard = lambda clipboard, text, callback: callback(clipboard, text, None)
    return value

value = harness(False)
module.ClipmanApplication._clipboard_read(value, Clipboard("baseline"), None, None)
assert value.captured == []
module.ClipmanApplication._clipboard_read(value, Clipboard("next"), None, None)
assert value.captured == [("next", True, True, "")]

value = harness(False)
module.ClipmanApplication._clipboard_read(value, Clipboard(None), None, None)
assert value.clipboard_baseline_ready and value.captured == []
module.ClipmanApplication._clipboard_read(value, Clipboard("first copy after empty baseline"), None, None)
assert value.captured == [("first copy after empty baseline", True, True, "")]

value = harness(True)
module.ClipmanApplication._clipboard_read(value, Clipboard("capture at startup"), None, None)
assert value.captured == [("capture at startup", True, True, "")]

value = harness(True)
module.ClipmanApplication._clipboard_read(value, Clipboard("x-special/nautilus-clipboard\ncopy\nfile:///tmp/test"), None, None)
assert value.captured == []

value = harness(False)
value.clipboard_baseline_ready = True
value.last_clipboard_files = ("files", ("/tmp/one.txt", "/tmp/two.txt"), "Copy")
value.last_file_clipboard_monotonic = time.monotonic()
module.ClipmanApplication._clipboard_read(value, Clipboard("/tmp/one.txt\n/tmp/two.txt"), None, None)
assert value.captured == []

paths, operation = module.parse_file_clipboard_payload(
    "copy\nfile:///tmp/One%20File.txt\nfile:///tmp/two.txt\n",
    "x-special/gnome-copied-files",
)
assert paths == ["/tmp/One File.txt", "/tmp/two.txt"]
assert operation == "Copy"
paths, operation = module.parse_file_clipboard_payload(
    "x-special/nautilus-clipboard\ncut\nfile:///tmp/moved.txt\n",
    "text/plain",
)
assert paths == ["/tmp/moved.txt"] and operation == "Move"
paths, operation = module.parse_file_clipboard_payload(
    "cut\nfile:///tmp/raw-payload.txt\n",
    "text/plain",
)
assert paths == ["/tmp/raw-payload.txt"] and operation == "Move"
assert module.sensitive_data_match("4111 1111 1111 1111", ["credit-card"]) == "Credit card number"
assert module.sensitive_data_match("4111 1111 1111 1112", ["credit-card"]) == ""
assert module.sensitive_data_match("+447890123456", ["international-phone"]) == "International phone number"
assert module.sensitive_data_match("https://example.com/ABCDEFGHIJKLMNOPQRSTUVWXYZ123456", ["api-token"]) == ""
paths, operation = module.parse_file_clipboard_payload(
    "file:///tmp/one.txt\r\nfile:///tmp/two.txt\r\n",
    "text/uri-list",
)
assert paths == ["/tmp/one.txt", "/tmp/two.txt"]
assert operation == "Copy"
assert module.file_event_summary({
    "files": ["/tmp/example.txt"], "file_count": 1,
    "operation": "Copy", "source": "Files", "device": "Fedora",
}).startswith("example.txt; Operation: Copy; Files: 1; Source: Files; Device: Fedora")
PY
install -m 0755 ClipmanLinux/clipman.py ClipmanLinux/clipman-hotkeys.py ClipmanLinux/clipman-updater.py ClipmanLinux/clipman-linux ClipmanLinux/install.sh ClipmanLinux/uninstall.sh "$stage/"
install -m 0644 ClipmanLinux/update_service.py ClipmanLinux/VERSION ClipmanLinux/Manual.html LICENSE.txt ClipmanLinux/me.onj.clipman.linux.desktop ClipmanLinux/me.onj.clipman.linux.metainfo.xml ClipmanLinux/me.onj.clipman.linux.xml ClipmanLinux/me.onj.clipman.linux.png "$stage/"
printf '%s\n' "$build_stamp" > "$stage/BUILD_STAMP"
install -m 0644 Assets/sounds/*.wav "$stage/sounds/"

if command -v appstreamcli >/dev/null 2>&1; then appstreamcli validate --no-net "$stage/me.onj.clipman.linux.metainfo.xml"; fi
if command -v desktop-file-validate >/dev/null 2>&1; then desktop-file-validate "$stage/me.onj.clipman.linux.desktop"; fi
if [ ! -x "$stage/libexec/clipman-gui-backend" ]; then
    printf 'Linux package is missing the executable GUI backend.\n' >&2
    exit 1
fi
tar --sort=name --mtime='UTC 2020-01-01' --owner=0 --group=0 --numeric-owner -C "$output" -czf "$output/$archive" "$(basename "$stage")"
if ! tar -tzf "$output/$archive" | grep -qx 'Clipman-Linux-GUI/libexec/clipman-gui-backend'; then
    printf 'Linux archive is missing the GUI backend.\n' >&2
    exit 1
fi
printf 'Built %s\n' "$output/$archive"
