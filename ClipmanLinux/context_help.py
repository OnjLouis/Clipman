"""Focused-control help. Field values are never used as help content."""

INSTRUCTIONS = {
    "history sections": "Switch between enabled history sections. Left and Right select a section; Alt+Left and Alt+Right reorder its tab.",
    "search clipboard history": "Filter visible clips by their text. Clear the search to show all clips in the current section and group or device filter.",
    "filter by group or device": "Show clips belonging to one group or device. All removes this filter; the search and selected history section still apply.",
    "enable clipmerge": "Copy the same selection twice within the merge window to start appending. Formatted text becomes plain text; file copies and cuts only merge with matching operations.",
    "custom clipmerge text separator": "Text inserted between appended selections when Custom is selected. Backslash n, backslash r backslash n, backslash r and backslash t are supported.",
    "custom multiple-entry separator": "Text inserted between selected clips copied together when Custom is selected. This is independent of ClipMerge; backslash escape sequences are supported.",
    "after enter, paste into the previous application": "Enter copies the selected clip, closes history, returns to the previous application and pastes. This requires the desktop session to allow simulated keyboard input.",
    "keep duplicate text entries": "Retain separate copies when captured text already exists. When disabled, Clipman reuses the existing entry.",
    "confirm before deleting entries": "Ask before removing history entries. Removing file-history records never deletes the original files.",
    "run clipman when this desktop session starts": "Start the background clipboard manager when you sign into this desktop session; history stays hidden until requested.",
    "automatically remove unavailable file-history events": "Remove unpinned file events whose original paths no longer exist. The original files are never deleted.",
    "install updates silently": "Install available Linux-client updates without asking. Settings and history are preserved and Clipman restarts afterward.",
    "change server connection and device name": "Review this device's identity, storage folder, server address, token and history password in the connection dialog.",
    "sync rules": "Route clips into named channels and choose which channels each device receives. Enable only after every device supports sync rules.",
    "preference sections": "Choose a preference section. Control+1 through Control+6 select sections directly; Tab moves into their controls.",
    "save and close": "Apply the pending preferences and close this dialog. Cancel discards changes that have not been saved.",
    "save and connect": "Save reviewed connection details and connect using the history password. A new password selects a separate server bucket.",
    "server address": "Enter the reachable server address and port. Use HTTPS for a remote connection; 0.0.0.0 is a listen address, not a client destination.",
    "enable sync rules": "Route new clips into channels using the saved rules. Unchecked restores main-history behavior without deleting the rule definitions.",
    "add channel": "Create a routing channel. The first matching rule receives each clip; unmatched clips stay in main history.",
    "edit channel": "Change the selected channel's routing conditions. Saving may relocate matching clips.",
    "remove channel": "Remove the channel and relocate its clips back to another matching channel or main history, without deleting them.",
    "edit device subscriptions": "Select which channels the chosen device receives. Unsubscribing hides clips locally without deleting shared history.",
    "channel name": "Use 1 to 32 letters, digits, spaces, hyphens or underscores. Reserved names cannot be used.",
    "groups, comma-separated": "Match any of these group names. Leave blank to match every group. Group and device conditions must both match.",
    "source devices, comma-separated": "Match any of these source device names. Leave blank to match every device.",
    "match rich text containing embedded images": "Require the clip to contain an embedded image as well as meeting any group and source-device conditions.",
    "pinned": "Protect this entry from normal history limits and bulk clearing. Unpin it to let those rules apply again.",
    "resolve template fields when copied": "Expand supported template fields when this clip is copied. Use Preview Template to inspect the result without changing the saved text.",
    "use as a quick paste target": "Assign a global shortcut to this entry. The Quick Paste mode determines how that shortcut affects the clipboard.",
    "quick paste mode": "Choose whether the shortcut pastes and restores the previous clipboard, pastes and keeps this clip, or copies without pasting.",
    "insert sample": "Insert the selected sample template into the editor at its cursor.",
    "insert field": "Insert the selected template field into the editor at its cursor.",
    "template sample": "Select a sample, then use Insert Sample to put it into the editor.",
    "template field": "Select a variable, then use Insert Field to put it into the editor.",
    "preview template": "Show the text after template fields are resolved without changing the saved template.",
    "resolved template preview": "Read the resolved template output. This preview is not editable and does not change the saved clip.",
    "formatted clipboard text": "Read the selected formatted clip. Copying the history entry preserves supported formatting.",
    "file paths": "Read the original paths referenced by this device-local file event. Viewing or clearing the event does not change the files.",
    "saved secrets": "Device-local secret names, with values hidden. Select a secret to edit, delete or paste it.",
    "secret name": "Visible label for a device-local secret. Its value is kept out of shared history.",
    "secret value": "Private value kept in this device's encrypted secrets database. Help never reads its contents.",
    "confirm secret value": "Retype the private value to catch mistakes before saving.",
    "remember on this device": "Protect and retain the history password for this Linux user so it need not be entered each session.",
    "remember history password on this device": "Protect and retain the history password for this Linux user so it need not be entered each session.",
    "import private authority": "Import the public certificate of a private authority for this HTTPS server. Verify its fingerprint with the server owner.",
    "remove private authority": "Remove Clipman's app-specific private authority without changing the server address or token.",
    "import clipman server connection file": "Import server connection details, review them, set your history password and save before syncing.",
    "import file password": "Password used to decrypt the selected history export. It need not match the current history password.",
    "current history password": "Unlock the history before exporting. The export can use its own separate encryption password.",
    "export password choice": "Keep the history password, choose a different export password, or export without encryption after confirmation.",
    "new export password": "Encrypt this export with a separate password. It does not change the live history password.",
    "confirm new export password": "Retype the export password to catch mistakes before the export is written.",
    "do not show this again": "Skip future website-title confirmations. Explicit requests still make network contact; unsafe destinations remain blocked.",
    "do not ask again before deleting entries": "Turn off future deletion confirmations. You can turn them back on in Preferences.",
    "add": "Create a new device-local secret with a name, private value and optional shortcut.",
    "edit": "Edit the selected secret's name, private value and optional shortcut.",
    "delete": "Remove the selected secret after confirmation without altering shared history.",
    "paste": "Paste the selected secret using its configured mode, without adding its value to shared history.",
    "device name": "Name recorded on newly captured clips. Existing clips keep their original device name.",
    "history storage type": "Local or shared folder uses your data folder. Clipman Server exchanges encrypted history; file events and secrets remain device-local.",
    "server host": "Enter the reachable server address and port. Use HTTPS for a remote connection. A wildcard listen address is not a client destination.",
    "server token": "Private server access credential. The token lets you connect; the history password selects and encrypts your separate history bucket.",
    "history password": "Unlock encrypted history. Use the same password only on devices that should share that history. The server never receives this password.",
    "confirm password": "Retype the new history password to catch mistakes before saving.",
    "data folder": "Use a dedicated folder for settings and history. For sharing, the chosen provider must actually synchronize its files.",
    "settings folder": "Use a dedicated folder for settings and history. For sharing, the chosen provider must actually synchronize its files.",
    "monitor clipboard text, links and files while clipman is running": "Record new clipboard events automatically. Turning this off does not remove history; deliberate capture remains separate.",
    "add current clipboard item when clipman starts": "Capture the clipboard once at startup, following monitoring, exclusion and privacy settings. Off by default.",
    "play sounds": "Play sounds for accepted copy, sync and monitoring events without changing capture behavior.",
    "clipmerge window in milliseconds": "Time allowed for a deliberate second copy to start appending, from 200 to 2000 milliseconds. Shorter windows reduce accidental merges.",
    "clipmerge text separator": "Choose what goes between appended clipboard selections. This is independent of copying several selected history entries.",
    "multiple selected entries separator": "Choose what goes between entries copied together from history. No separator joins them directly; this does not change ClipMerge.",
    "automatically group new clips by source application": "Use the source application as the group for newly captured clips. Existing groups are unchanged.",
    "put new text received from another device on the clipboard": "Copy newly created remote text onto this device's clipboard. Reusing an older remote entry does not trigger this.",
    "open history to the section that most recently received an item": "Select the history section for the most recent accepted clipboard type when opening history.",
    "automatically remove tracking from copied links": "Remove recognized tracking parameters from new links. Disable this to keep the original destination unchanged.",
    "show links history": "Show standalone HTTP and HTTPS links separately. When disabled, they remain in Text history.",
    "save list position": "Remember your place in each history section after closing and reopening it.",
    "duplicate handling": "Move to top reuses an existing entry; Ignore leaves it in place; Keep both retains separate copies.",
    "maximum entries": "Limit normal history by count. Zero means no limit; pinned entries are retained.",
    "maximum age in days": "Limit normal history by age. Zero means no limit; pinned entries are retained.",
    "check for updates": "Choose when automatic Linux-client update checks run. Never still permits manual checks.",
    "ignored applications": "One application or process name per line. Automatic capture ignores these apps; explicit imports remain separate.",
    "sensitive data mode": "Exclude selected detected patterns from automatic capture. Existing history, the system clipboard and deliberate imports are unchanged.",
    "entry name": "Give this clip a descriptive name without changing its text or image content.",
    "name": "Give this clip a descriptive name without changing its text or image content.",
    "group": "Organize this entry under a group. Group names differing only by case are treated as the same group.",
    "clipboard text": "Edit the stored text. Enter inserts a new line; Control+Enter saves. Tab leaves the editor rather than inserting a tab.",
    "text history": "Select clips with the arrow keys. Enter copies and closes, optionally pasting according to Preferences. F2 edits; F4 views.",
    "links history": "Select links with the arrow keys. Control+Enter copies name and destination; Alt+Enter opens the link and closes History.",
    "rich text history": "Formatted clips and embedded images. Copy preserves supported formatting. Alt+Enter opens a selected image in its default application.",
    "file history": "Device-local file events, not uploaded files. Enter restores the file selection to the clipboard. Alt+Enter reveals one selected file or folder and closes History. Clearing history does not delete original files.",
    "sync channels": "Rules are evaluated in order. The first matching channel receives an entry; unmatched entries stay in main history.",
    "devices": "Choose a device and edit the channels it receives. Unsubscribing hides clips locally without deleting them from shared history.",
    "cancel": "Dismiss this dialog without accepting pending changes.",
    "save": "Save pending changes. In a clip editor, Enter inserts a new line and Control+Enter saves.",
    "close": "Close this window and return to the previous control.",
}


def description_for(name, hint=None):
    if hint:
        return hint
    return INSTRUCTIONS.get(name.strip().rstrip(".").casefold(), "Use the focused control in this window. Tab moves forward; Shift+Tab moves backward. The manual covers the complete workflow.")


def set_properties(widget, properties, values):
    from gi.repository import Gtk
    forwarded, content = [], []
    for prop, value in zip(properties, values):
        if prop == Gtk.AccessibleProperty.DESCRIPTION:
            widget._clipman_help = value
            value = ""
        elif prop == Gtk.AccessibleProperty.LABEL:
            widget._clipman_help_name = value
        forwarded.append(prop)
        content.append(value)
    widget.update_property(forwarded, content)


def focused_content(widget):
    from gi.repository import Gtk
    current = widget
    while current is not None:
        # Row labels can contain the full clip or a secret name; use their list.
        if not isinstance(current, (Gtk.ListBoxRow, Gtk.Label)):
            name = getattr(current, "_clipman_help_name", None)
            if not name and isinstance(current, Gtk.Button):
                name = current.get_label()
            if not name and isinstance(current, Gtk.CheckButton):
                name = current.get_label()
            if name:
                name = name.replace("_", "").strip()
                return name, description_for(name, getattr(current, "_clipman_help", None))
        current = current.get_parent()
    return "Current window", description_for("Current window")


def attach(window, manual):
    from gi.repository import Gdk, Gtk
    if getattr(window, "_clipman_help_controller", None):
        return
    controller = Gtk.EventControllerKey()
    controller.set_propagation_phase(Gtk.PropagationPhase.CAPTURE)
    def pressed(_controller, keyval, _keycode, state):
        modifiers = state & (Gdk.ModifierType.CONTROL_MASK | Gdk.ModifierType.ALT_MASK |
                             Gdk.ModifierType.SHIFT_MASK | Gdk.ModifierType.SUPER_MASK |
                             Gdk.ModifierType.META_MASK | Gdk.ModifierType.HYPER_MASK)
        if keyval != Gdk.KEY_F1 or modifiers:
            return False
        show(window, manual)
        return True
    controller.connect("key-pressed", pressed)
    window.add_controller(controller)
    window._clipman_help_controller = controller


def show(owner, manual):
    from gi.repository import Gtk
    if owner is None or getattr(owner, "_clipman_help_dialog", False):
        return
    if getattr(owner, "_clipman_active_help", None):
        return
    focused = owner.get_focus()
    name, instructions = focused_content(focused)
    dialog = Gtk.Dialog(title="Help: " + name, transient_for=owner, modal=True)
    dialog._clipman_help_dialog = True
    owner._clipman_active_help = dialog
    dialog.set_default_size(580, 300)
    area = dialog.get_content_area()
    view = Gtk.TextView(editable=False, cursor_visible=True, wrap_mode=Gtk.WrapMode.WORD_CHAR)
    view.set_accepts_tab(False)
    view.get_buffer().set_text(instructions)
    view.update_property([Gtk.AccessibleProperty.LABEL], [name + " help"])
    scroll = Gtk.ScrolledWindow(vexpand=True, hexpand=True)
    scroll.set_child(view)
    area.append(scroll)
    dialog.add_button("Open _Manual", Gtk.ResponseType.HELP)
    dialog.add_button("_Close", Gtk.ResponseType.CLOSE)
    def finished(_dialog, code):
        if code == Gtk.ResponseType.HELP:
            manual()
            return
        dialog.destroy()
        owner._clipman_active_help = None
        if focused is not None and focused.get_root() is owner:
            focused.grab_focus()
    dialog.connect("response", finished)
    def close_requested(*_args):
        finished(dialog, Gtk.ResponseType.CLOSE)
        return True
    dialog.connect("close-request", close_requested)
    dialog.present()
    view.grab_focus()
