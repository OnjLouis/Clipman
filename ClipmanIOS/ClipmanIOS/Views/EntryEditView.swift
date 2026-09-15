import SwiftUI

struct EntryEditView: View {
    @EnvironmentObject private var app: ClipmanAppModel
    @Environment(\.dismiss) private var dismiss
    @State private var draft: ClipEntry
    @FocusState private var focusedField: Field?
    private let isNew: Bool

    private var hasEmbeddedImage: Bool {
        !isNew && EmbeddedImageCodec.recognize(draft.RichText) != nil
    }

    private enum Field {
        case text
    }

    init(entry: ClipEntry) {
        _draft = State(initialValue: entry)
        isNew = false
    }

    init() {
        _draft = State(initialValue: ClipEntry())
        isNew = true
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Details") {
                    TextField("Name", text: $draft.Name)
                        .accessibilityLabel("Name")
                        .accessibilityHint("Edits the optional name shown for this entry.")
                    TextField("Group", text: $draft.Group)
                        .accessibilityLabel("Group")
                        .accessibilityHint("Edits the group assigned to this entry.")
                    Toggle("Pinned", isOn: $draft.Pinned)
                    Toggle("Template", isOn: $draft.IsTemplate)
                        .disabled(hasEmbeddedImage)
                        .accessibilityHint(hasEmbeddedImage ? "Image content cannot be used as a template." : "Uses template fields when this entry is copied or pasted.")
                }
                if hasEmbeddedImage {
                    Section("Image content") {
                        Text(draft.Text)
                            .accessibilityLabel("Image content, \(draft.Text)")
                            .accessibilityHint("This image content cannot be edited. Use Name to rename how the image appears.")
                        Text("Image content cannot be edited. Use Name to rename how this image appears.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .accessibilityHidden(true)
                    }
                } else {
                    Section("Clipboard text") {
                        TextEditor(text: $draft.Text)
                            .frame(minHeight: 180)
                            .focused($focusedField, equals: .text)
                            .accessibilityLabel("Clipboard text")
                            .accessibilityHint(isNew ? "Enter the text for the new clip." : "Edits the clipboard text stored in this entry.")
                    }
                }
            }
            .navigationTitle(isNew ? "Quick Clip" : "Edit Entry")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        if isNew {
                            app.addQuickClip(draft)
                        } else {
                            app.update(draft)
                        }
                        dismiss()
                    }
                    .disabled(draft.Text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .onAppear {
                if isNew { focusedField = .text }
            }
        }
    }
}
