import SwiftUI

private struct ReadingRowFrames: PreferenceKey {
    static let defaultValue: [String: CGRect] = [:]
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, newest in newest })
    }
}

extension View {
    func readingPositionRow(_ id: String, in coordinateSpace: String) -> some View {
        self.id(id).background {
            GeometryReader { geometry in
                Color.clear.preference(key: ReadingRowFrames.self, value: [id: geometry.frame(in: .named(coordinateSpace))])
            }
        }
    }
}

struct RememberedList<Content: View>: View {
    let coordinateSpace: String
    let rowIDs: [String]
    let savedAnchor: String?
    var bottomRequest = 0
    let remember: (String) -> Void
    var onRestore: () -> Void = {}
    @ViewBuilder let content: () -> Content
    @State private var restored = false
    private let minimumVisibleRowHeight: CGFloat = 4

    var body: some View {
        GeometryReader { viewport in
            ScrollViewReader { proxy in
                List { content() }
                    .listStyle(.plain)
                    .coordinateSpace(name: coordinateSpace)
                    .onPreferenceChange(ReadingRowFrames.self) { frames in
                        // Exclude a preceding row's separator sliver so repeated restores cannot drift upward.
                        let visible = frames.filter {
                            min($0.value.maxY, viewport.size.height - viewport.safeAreaInsets.bottom)
                                - max($0.value.minY, viewport.safeAreaInsets.top) >= minimumVisibleRowHeight
                        }
                        if let first = visible.min(by: { $0.value.minY < $1.value.minY }) {
                            if !restored {
                                // Initial layout can report the top before scrollTo has taken effect.
                                if let savedAnchor, rowIDs.contains(savedAnchor), visible[savedAnchor] == nil {
                                    proxy.scrollTo(savedAnchor, anchor: .top)
                                    return
                                }
                                restored = true
                                onRestore()
                            }
                            remember(first.key)
                        }
                    }
                    .onChange(of: bottomRequest) { _ in
                        if let last = rowIDs.last { proxy.scrollTo(last, anchor: .bottom) }
                    }
            }
        }
    }
}
