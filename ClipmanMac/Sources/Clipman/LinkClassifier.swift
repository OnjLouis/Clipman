import Foundation
import ClipmanCore

enum LinkClassifier {
    static func isLinkOnlyText(_ text: String) -> Bool {
        LinkPresentation.linkOnlyURLText(text) != nil
    }
}
