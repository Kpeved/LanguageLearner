import Foundation
import EPUBKit

/// A simple LRU cache for `EPUBChapter` values keyed by `ChapterRef`.
///
/// Not thread-safe on its own; callers must ensure serialised access.
/// The `LibraryStoreImpl` is `@MainActor`-isolated so access is always serialised.
final class ChapterLRU {
    private let capacity: Int
    /// Ordered from least-recently-used (front) to most-recently-used (back).
    private var order: [ChapterRef] = []
    private var store: [ChapterRef: EPUBChapter] = [:]

    init(capacity: Int = 16) {
        self.capacity = max(1, capacity)
        order.reserveCapacity(capacity)
        store.reserveCapacity(capacity)
    }

    func get(_ key: ChapterRef) -> EPUBChapter? {
        guard let value = store[key] else { return nil }
        touch(key)
        return value
    }

    func set(_ key: ChapterRef, value: EPUBChapter) {
        if store[key] != nil {
            touch(key)
            store[key] = value
            return
        }
        if store.count >= capacity, let lru = order.first {
            order.removeFirst()
            store.removeValue(forKey: lru)
        }
        store[key] = value
        order.append(key)
    }

    func removeAll(where predicate: (ChapterRef) -> Bool) {
        let removed = order.filter { predicate($0) }
        for key in removed {
            store.removeValue(forKey: key)
        }
        order.removeAll { predicate($0) }
    }

    private func touch(_ key: ChapterRef) {
        if let idx = order.firstIndex(of: key) {
            order.remove(at: idx)
            order.append(key)
        }
    }
}
