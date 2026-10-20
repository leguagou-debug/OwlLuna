import UIKit

/// Keeps the iPad from locking while anything holds it: a notebook being presented, or a recording being made.
@MainActor
final class IdleTimer {
    static let shared = IdleTimer()

    private struct Holder { weak var object: AnyObject? }

    private var holders: [ObjectIdentifier: Holder] = [:]
    private let apply: @MainActor (Bool) -> Void

    init(apply: @escaping @MainActor (Bool) -> Void = { UIApplication.shared.isIdleTimerDisabled = $0 }) {
        self.apply = apply
    }

    var isHeld: Bool { holders.values.contains { $0.object != nil } }

    func hold(_ held: Bool, by holder: AnyObject) {
        holders[ObjectIdentifier(holder)] = held ? Holder(object: holder) : nil
        refresh()
    }

    /// Lets go for holders that are gone, so a hold never outlives what took it.
    func refresh() {
        holders = holders.filter { $0.value.object != nil }
        apply(isHeld)
    }
}
