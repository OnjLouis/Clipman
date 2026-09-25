import AppKit

let pasteboard = NSPasteboard.withUniqueName()
defer { pasteboard.releaseGlobally() }
let urlType = NSPasteboard.PasteboardType("public.url")
let link = "https://example.com/article?from=browser"

pasteboard.clearContents()
precondition(pasteboard.setString(link, forType: urlType))
precondition(pasteboard.string(forType: .string) == nil)
precondition(PasteboardLinkText.read(from: pasteboard) == link)

pasteboard.clearContents()
precondition(pasteboard.setData(Data(link.utf8), forType: urlType))
precondition(PasteboardLinkText.read(from: pasteboard) == link)

pasteboard.clearContents()
precondition(pasteboard.setString("file:///private/example.txt", forType: urlType))
precondition(PasteboardLinkText.read(from: pasteboard) == nil)

pasteboard.clearContents()
precondition(pasteboard.setString(link, forType: urlType))
precondition(pasteboard.setString("Selected page title", forType: .string))
precondition(PasteboardLinkText.read(from: pasteboard) == "Selected page title")

print("Mac URL-only pasteboard smoke passed.")
