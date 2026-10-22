import UIKit
import os

/// A small least-recently-used cache that is safe to use from any thread. A memory warning empties it.
final class LRUCache<Value: Sendable>: Sendable {
    private struct State {
        var values: [String: Value] = [:]
        var order: [String] = []
    }

    private let state = OSAllocatedUnfairLock(initialState: State())
    private let capacity: Int
    nonisolated(unsafe) private var relief: (any NSObjectProtocol)?

    init(capacity: Int) {
        self.capacity = capacity
        relief = NotificationCenter.default.addObserver(forName: UIApplication.didReceiveMemoryWarningNotification, object: nil, queue: nil) { [weak self] _ in
            self?.removeAll()
        }
    }

    deinit {
        if let relief { NotificationCenter.default.removeObserver(relief) }
    }

    func value(_ key: String, create: () -> Value?) -> Value? {
        if let hit = state.withLock({ state -> Value? in
            guard let value = state.values[key] else { return nil }
            state.order.removeAll { $0 == key }
            state.order.append(key)
            return value
        }) { return hit }
        guard let created = create() else { return nil }
        state.withLock { state in
            state.values[key] = created
            state.order.removeAll { $0 == key }
            state.order.append(key)
            while state.order.count > capacity {
                state.values.removeValue(forKey: state.order.removeFirst())
            }
        }
        return created
    }

    var count: Int { state.withLock { $0.values.count } }

    func removeAll() { state.withLock { $0 = State() } }
}
