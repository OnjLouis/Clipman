import SwiftUI
import UIKit

struct EntryEditView: View {
    @EnvironmentObject private var app: ClipmanAppModel
    @Environment(\.dismiss) private var dismiss
    @State private var draft: ClipEntry
    @FocusState private var focusedField: Field?
    @AccessibilityFocusState(for: .voiceOver) private var accessibilityFocusedField: Field?
    @State private var requestedInitialFocus = false
    private let isNew: Bool

    private var hasEmbeddedImage: Bool {
        !isNew && EmbeddedImageCodec.recognize(draft.RichText) != nil
    }

    private enum Field {
        case text
    }

    init(entryEditDraft: ClipEntry) {
        _draft = State(initialValue: entryEditDraft)
        isNew = false
    }

    init(quickClipDraft: ClipEntry) {
        _draft = State(initialValue: quickClipDraft)
        isNew = true
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Details") {
                    TextField("Name", text: draftBinding(\.Name))
                        .accessibilityLabel("Name")
                        .accessibilityHint("Edits the optional name shown for this entry.")
                    TextField("Group", text: draftBinding(\.Group))
                        .accessibilityLabel("Group")
                        .accessibilityHint("Edits the group assigned to this entry.")
                    Toggle("Pinned", isOn: draftBinding(\.Pinned))
                    Toggle("Template", isOn: draftBinding(\.IsTemplate))
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
                        clipboardTextEditor
                    }
                }
            }
            .navigationTitle(isNew ? "Quick Clip" : "Edit Entry")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        if isNew {
                            app.discardQuickClipDraft()
                        } else {
                            app.discardEntryEditDraft()
                        }
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        if isNew {
                            app.saveQuickClipDraft(draft)
                        } else {
                            app.saveEntryEditDraft(draft)
                        }
                        dismiss()
                    }
                    .disabled(draft.Text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .background(EditorPresentationObserver {
            guard isNew, !requestedInitialFocus else { return }
            requestedInitialFocus = true
            focusedField = .text
            if #unavailable(iOS 26.0) {
                accessibilityFocusedField = .text
            }
        }.allowsHitTesting(false))
    }

    @ViewBuilder
    private var clipboardTextEditor: some View {
        if #available(iOS 26.0, *), isNew {
            textEditor
                .accessibilityDefaultFocus($accessibilityFocusedField, .text)
        } else {
            textEditor
                .accessibilityFocused($accessibilityFocusedField, equals: .text)
        }
    }

    private var textEditor: some View {
        TextEditor(text: draftBinding(\.Text))
            .frame(minHeight: 180)
            .focused($focusedField, equals: .text)
            .accessibilityLabel("Clipboard text")
            .accessibilityHint(isNew ? "Enter the text for the new clip." : "Edits the clipboard text stored in this entry.")
    }

    private func draftBinding<Value>(_ keyPath: WritableKeyPath<ClipEntry, Value>) -> Binding<Value> {
        Binding(
            get: { draft[keyPath: keyPath] },
            set: { value in
                draft[keyPath: keyPath] = value
                if isNew {
                    app.updateQuickClipDraft(draft)
                } else {
                    app.updateEntryEditDraft(draft)
                }
            }
        )
    }
}

private struct EditorPresentationObserver: UIViewControllerRepresentable {
    let didAppear: () -> Void

    func makeUIViewController(context: Context) -> Controller {
        Controller(didAppear: didAppear)
    }

    func updateUIViewController(_ controller: Controller, context: Context) {
        controller.didAppear = didAppear
    }

    final class Controller: UIViewController {
        var didAppear: () -> Void

        init(didAppear: @escaping () -> Void) {
            self.didAppear = didAppear
            super.init(nibName: nil, bundle: nil)
        }

        required init?(coder: NSCoder) {
            fatalError("init(coder:) is not supported")
        }

        override func loadView() {
            view = UIView()
            view.isUserInteractionEnabled = false
        }

        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            // SwiftUI onAppear runs before the sheet's presentation has finished.
            didAppear()
        }
    }
}
