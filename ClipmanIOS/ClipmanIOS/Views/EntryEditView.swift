import SwiftUI

struct EntryEditView: View {
    @EnvironmentObject private var app: ClipmanAppModel
    @Environment(\.dismiss) private var dismiss
    @State private var draft: ClipEntry

    init(entry: ClipEntry) {
        _draft = State(initialValue: entry)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Details") {
                    TextField("Name", text: $draft.Name)
                    TextField("Group", text: $draft.Group)
                    Toggle("Pinned", isOn: $draft.Pinned)
                    Toggle("Template", isOn: $draft.IsTemplate)
                }
                Section("Clipboard text") {
                    TextEditor(text: $draft.Text)
                        .frame(minHeight: 180)
                        .accessibilityLabel("Clipboard text")
                }
            }
            .navigationTitle("Edit Entry")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        app.update(draft)
                        dismiss()
                    }
                }
            }
        }
    }
}
