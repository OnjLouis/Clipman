import pathlib
import hashlib
import io
import shutil
import tarfile
import tempfile
import unittest
import ast
from unittest import mock

import gi
gi.require_version("Gtk", "4.0")
gi.require_version("Gdk", "4.0")
from gi.repository import Gdk, GLib, Gtk

import clipman
import context_help
import update_service
from test_content_features import image_rich_text, small_png


class ContextHelpTests(unittest.TestCase):
    def test_open_link_hides_history_only_after_success(self):
        app = mock.Mock()
        app.section = "links"
        app.selected_entry.return_value = {"text": "https://example.com/test"}
        app.selected_entries.return_value = [app.selected_entry.return_value]
        clipman.ClipmanApplication.open_selected_link(app)
        app._open_uri.assert_called_once_with("https://example.com/test")
        app.window.set_visible.assert_called_once_with(False)
        app.reset_mock()
        app._open_uri.side_effect = OSError("no default browser")
        clipman.ClipmanApplication.open_selected_link(app)
        app.window.set_visible.assert_not_called()
        app.sounds.play.assert_called_once_with("skip")

    def test_open_files_reveals_location_without_executing_content(self):
        app = mock.Mock()
        app.section = "files"
        app.selected_entries.return_value = [{"files": ["test.txt"]}]
        app.go_to_selected_file.return_value = True
        clipman.ClipmanApplication.open_selected_link(app)
        app.go_to_selected_file.assert_called_once()
        app._open_uri.assert_not_called()
        app.window.set_visible.assert_called_once_with(False)
        app.reset_mock()
        app.go_to_selected_file.return_value = False
        clipman.ClipmanApplication.open_selected_link(app)
        app.window.set_visible.assert_not_called()

    def test_open_image_preserves_bytes_history_and_clipboard(self):
        with tempfile.TemporaryDirectory() as scratch:
            entry = {"text": "original image", "rich_text": image_rich_text(),
                     "created_unix_ms": 1700000000000, "source_machine": "Test device"}
            app = mock.Mock()
            app.section = "rich"
            app.selected_entries.return_value = [entry]
            app.selected_entry.return_value = entry
            app.image_viewer_cache = clipman.ClipboardImageFileCache(pathlib.Path(scratch))
            clipman.ClipmanApplication.open_selected_link(app)
            path = app.image_viewer_cache.current
            self.assertEqual(path.read_bytes(), small_png())
            self.assertEqual(path.stat().st_mtime, 1700000000)
            self.assertEqual(entry["text"], "original image")
            app._set_clipboard.assert_not_called()
            app._open_uri.assert_called_once_with(path.as_uri())
            app.window.set_visible.assert_called_once_with(False)
            app.reset_mock()
            app._open_uri.side_effect = OSError("no image viewer")
            clipman.ClipmanApplication.open_selected_link(app)
            app.window.set_visible.assert_not_called()

    def test_open_multiple_items_keeps_history_open(self):
        app = mock.Mock()
        app.section = "links"
        app.selected_entries.return_value = [{"text": "https://example.com/a"}, {"text": "https://example.com/b"}]
        clipman.ClipmanApplication.open_selected_link(app)
        app._open_uri.assert_not_called()
        app.window.set_visible.assert_not_called()

    def test_quick_clip_restores_hidden_history_on_cancel(self):
        with tempfile.TemporaryDirectory() as scratch, mock.patch("clipman.config_home", return_value=pathlib.Path(scratch)):
            app = clipman.ClipmanApplication()
            app.window = Gtk.Window()
            self.assertFalse(app.window.get_visible())
            app.handle_global_hotkey("quick-clip")
            self.pump()
            dialog = next(window for window in Gtk.Window.get_toplevels() if window.get_title() == "Quick Clip")
            self.assertTrue(app.window.get_visible())
            dialog.response(Gtk.ResponseType.CANCEL)
            self.assertFalse(app.window.get_visible())
            app.window.present()
            app.handle_global_hotkey("quick-clip")
            self.pump()
            dialog = next(window for window in Gtk.Window.get_toplevels() if window.get_title() == "Quick Clip")
            dialog.response(Gtk.ResponseType.CANCEL)
            self.assertTrue(app.window.get_visible())

    def test_explanatory_descriptions_use_retained_help_in_all_dialogs(self):
        source = ast.parse(pathlib.Path(clipman.__file__).read_text())
        bypasses = []
        for node in ast.walk(source):
            if isinstance(node, ast.Call) and isinstance(node.func, ast.Attribute):
                if node.func.attr == "update_property" and any(
                    isinstance(value, ast.Attribute) and value.attr == "DESCRIPTION"
                    for value in ast.walk(node)
                ):
                    bypasses.append(node.lineno)
        self.assertEqual(bypasses, [], "Descriptions bypass the retained-help helper")

    def test_dynamic_help_clears_automatic_speech_and_preserves_states(self):
        widget = mock.Mock()
        context_help.set_properties(widget,
            [Gtk.AccessibleProperty.LABEL, Gtk.AccessibleProperty.DESCRIPTION],
            ["Remove channel", "Select a channel to remove."])
        widget.update_property.assert_called_with(
            [Gtk.AccessibleProperty.LABEL, Gtk.AccessibleProperty.DESCRIPTION],
            ["Remove channel", ""])
        context_help.set_properties(widget, [Gtk.AccessibleProperty.DESCRIPTION],
            ["Remove this channel without deleting its clips."])
        widget.update_property.assert_called_with([Gtk.AccessibleProperty.DESCRIPTION], [""])
        self.assertEqual(widget._clipman_help_name, "Remove channel")
        self.assertEqual(widget._clipman_help, "Remove this channel without deleting its clips.")
        widget.update_state.assert_not_called()

    def tearDown(self):
        for window in Gtk.Window.get_toplevels():
            window.destroy()
        self.pump()

    @staticmethod
    def pump():
        context = GLib.MainContext.default()
        for _ in range(30):
            if not context.pending():
                break
            context.iteration(False)

    def test_help_uses_metadata_not_private_values(self):
        field = Gtk.PasswordEntry()
        field.set_text("private-value-not-help")
        context_help.set_properties(field,
            [Gtk.AccessibleProperty.LABEL, Gtk.AccessibleProperty.DESCRIPTION],
            ["History password", "Unlock this device's encrypted history."])
        name, text = context_help.focused_content(field)
        self.assertEqual(name, "History password")
        self.assertEqual(text, "Unlock this device's encrypted history.")
        self.assertNotIn(field.get_text(), text)

    def test_private_history_row_uses_its_list_help(self):
        listing = Gtk.ListBox()
        listing._clipman_help_name = "Text history"
        row = Gtk.ListBoxRow()
        context_help.set_properties(row, [Gtk.AccessibleProperty.LABEL], ["private clip contents"])
        listing.append(row)
        self.assertEqual(context_help.focused_content(row)[0], "Text history")

    def test_help_is_read_only_closes_and_restores_focus(self):
        owner = Gtk.Window()
        field = Gtk.Entry()
        context_help.set_properties(field, [Gtk.AccessibleProperty.LABEL], ["Device name"])
        owner.set_child(field)
        owner.present()
        field.grab_focus()
        self.pump()
        focused = owner.get_focus()
        manual = mock.Mock()
        context_help.attach(owner, manual)
        controller = owner._clipman_help_controller
        self.assertTrue(controller.emit("key-pressed", Gdk.KEY_F1, 0, Gdk.ModifierType(0)))
        dialog = owner._clipman_active_help
        self.assertEqual(dialog.get_title(), "Help: Device name")
        view = dialog.get_content_area().get_first_child().get_child()
        self.assertFalse(view.get_editable())
        self.assertFalse(view.get_accepts_tab())
        context_help.show(owner, manual)
        self.assertIs(owner._clipman_active_help, dialog)
        dialog.response(Gtk.ResponseType.HELP)
        manual.assert_called_once()
        dialog.close()
        self.pump()
        self.assertIsNone(owner._clipman_active_help)
        self.assertIs(owner.get_focus(), focused)
        self.assertFalse(controller.emit("key-pressed", Gdk.KEY_F1, 0, Gdk.ModifierType.SHIFT_MASK))
        context_help.show(owner, manual)
        owner._clipman_active_help.response(Gtk.ResponseType.CLOSE)
        self.assertIsNone(owner._clipman_active_help)

    def test_plain_f1_is_not_a_shortcut(self):
        field = clipman.HotkeyEntry("<Control><Alt>h", "Show history hotkey")
        original = field.get_accelerator()
        self.assertFalse(field._key_pressed(None, Gdk.KEY_F1, 0, Gdk.ModifierType(0)))
        self.assertEqual(field.get_accelerator(), original)
        self.assertTrue(field._key_pressed(None, Gdk.KEY_F1, 0, Gdk.ModifierType.CONTROL_MASK | Gdk.ModifierType.ALT_MASK))
        self.assertNotEqual(field.get_accelerator(), original)

    def test_every_preference_control_has_tailored_help(self):
        with tempfile.TemporaryDirectory() as scratch, mock.patch("clipman.config_home", return_value=pathlib.Path(scratch)):
            application = clipman.ClipmanApplication()
            application.window = Gtk.Window()
            application.show_preferences()
            dialog = next(window for window in Gtk.Window.get_toplevels() if window.get_title() == "Clipman Preferences")
            missing = []
            def inspect(widget):
                if isinstance(widget, (Gtk.Entry, Gtk.TextView, Gtk.DropDown, Gtk.SpinButton, Gtk.CheckButton, Gtk.Button, Gtk.Notebook)):
                    name, text = context_help.focused_content(widget)
                    if text.startswith("Use the focused control"):
                        missing.append(name)
                child = widget.get_first_child()
                while child:
                    inspect(child)
                    child = child.get_next_sibling()
            inspect(dialog.get_content_area())
            self.assertEqual(sorted(set(missing)), [])
            dialog.destroy()

    def test_every_application_dialog_uses_the_help_presenter(self):
        source = pathlib.Path(clipman.__file__).read_text()
        # The only direct presentation is inside the central presenter itself.
        self.assertEqual(source.count(".present()"), 1)
        for filename in ("install.sh", "build.sh"):
            self.assertIn("context_help.py", pathlib.Path(clipman.__file__).with_name(filename).read_text())

    def test_update_rejects_a_package_without_context_help(self):
        files = ("clipman.py", "clipman-hotkeys.py", "clipman-updater.py", "update_service.py",
                 "install.sh", "libexec/clipman-gui-backend", "Manual.html", "LICENSE.txt", "BUILD_STAMP")
        for include_help in (False, True):
            payload = io.BytesIO()
            with tarfile.open(fileobj=payload, mode="w:gz") as archive:
                for name in (*files, "VERSION", *(("context_help.py",) if include_help else ())):
                    data = b"3.1.9\n" if name == "VERSION" else b"test\n"
                    member = tarfile.TarInfo("Clipman-Linux-GUI/" + name)
                    member.size = len(data)
                    archive.addfile(member, io.BytesIO(data))
            data = payload.getvalue()
            candidate = update_service.UpdateCandidate("3.1.9", "https://github.com/OnjLouis/Clipman",
                "https://github.com/OnjLouis/Clipman/update.tar.gz", "update.tar.gz",
                "sha256:" + hashlib.sha256(data).hexdigest(), len(data))
            opener = lambda *_args, **_kwargs: io.BytesIO(data)
            if not include_help:
                with self.assertRaisesRegex(update_service.UpdateError, "incomplete"):
                    update_service.stage_update(candidate, opener)
            else:
                package, temporary = update_service.stage_update(candidate, opener)
                try:
                    self.assertTrue((package / "context_help.py").is_file())
                finally:
                    shutil.rmtree(temporary)


if __name__ == "__main__":
    unittest.main()
