import Foundation

public enum VisibleEntryOrder {
    public static func moving(visibleIDs: [String], selectedIDs: [String], direction: Int) -> [String]? {
        let selected = Set(selectedIDs)
        guard !visibleIDs.isEmpty, !selected.isEmpty, direction != 0 else { return nil }

        let indexes = visibleIDs.indices.filter { selected.contains(visibleIDs[$0]) }
        guard indexes.count == selected.count,
              let first = indexes.first,
              let last = indexes.last else {
            return nil
        }
        if direction < 0, first == visibleIDs.startIndex { return nil }
        if direction > 0, last == visibleIDs.index(before: visibleIDs.endIndex) { return nil }

        let moving = visibleIDs.filter { selected.contains($0) }
        var reordered = visibleIDs.filter { !selected.contains($0) }
        let insertionIndex = direction < 0
            ? max(0, first - 1)
            : min(reordered.count, last + 1 - moving.count + 1)
        reordered.insert(contentsOf: moving, at: insertionIndex)
        return reordered
    }
}
