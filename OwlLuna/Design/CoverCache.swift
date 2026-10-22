import UIKit
import os

/// Covers rendered once per request, kept in a bounded in-memory LRU and on disk in Caches.
final class CoverCache: Sendable {
    static let shared = CoverCache()

    private struct Memory {
        var images: [String: UIImage] = [:]
        var order: [String] = []
        var cost = 0
    }

    private let memory = OSAllocatedUnfairLock(initialState: Memory())
    private let limit = 80 * 1_048_576
    private let directory = URL.cachesDirectory.appending(path: "Covers", directoryHint: .isDirectory)
    private let signposter = OSSignposter(category: "covers")

    /// A memory warning empties the memory cache. The disk keeps every cover.
    init() {
        NotificationCenter.default.addObserver(forName: UIApplication.didReceiveMemoryWarningNotification, object: nil, queue: nil) { [weak self] _ in
            self?.memory.withLock { $0 = Memory() }
        }
    }

    func cached(_ key: String) -> UIImage? {
        memory.withLock { state in
            guard let image = state.images[key] else { return nil }
            if let index = state.order.lastIndex(of: key) { state.order.remove(at: index) }
            state.order.append(key)
            return image
        }
    }

    /// Loads or renders a cover off the main thread. The work stops if the caller is cancelled (a cell scrolled
    /// away, a preview re-keyed), and returns nil then. Disk hits are decoded before they reach the main thread.
    /// `persist: false`, for the live preview, skips the disk and the shared memory cache.
    func image(for request: CoverRequest, persist: Bool = true) async -> UIImage? {
        let key = request.key
        if let image = cached(key) { return image }
        let directory = directory
        let signposter = signposter
        let work = Task.detached(priority: Task.currentPriority) { () -> UIImage? in
            let file = directory.appending(path: "\(key).png")
            if persist, let data = try? Data(contentsOf: file), let image = UIImage(data: data, scale: request.scale) {
                Self.markUsed(file)
                return image.preparingForDisplay() ?? image
            }
            if Task.isCancelled { return nil }
            let interval = signposter.beginInterval("Cover render")
            var firstPage: CGImage?
            if let url = request.firstPage, let data = try? Data(contentsOf: url) {
                firstPage = UIImage(data: data)?.cgImage
            }
            if Task.isCancelled { return nil }
            let image = CoverRenderer.render(request, firstPage: firstPage)
            signposter.endInterval("Cover render", interval)
            if persist, !Task.isCancelled {
                try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                if let png = image.pngData() { try? png.write(to: file, options: .atomic) }
            }
            return image
        }
        let image = await withTaskCancellationHandler { await work.value } onCancel: { work.cancel() }
        if let image, persist { store(image, key: key) }
        return image
    }

    /// Dates a file on use (at most daily), so the disk sweep removes covers nobody has looked at in a while.
    private static func markUsed(_ file: URL) {
        let modified = file.contentModificationDate ?? .distantPast
        guard modified < Date.now.addingTimeInterval(-86_400) else { return }
        try? FileManager.default.setAttributes([.modificationDate: Date.now], ofItemAtPath: file.path(percentEncoded: false))
    }

    /// Keeps the disk cache under `limit` bytes, removing the least recently used covers first.
    func sweepDisk(limit: Int = 150 * 1_048_576) {
        let keys: [URLResourceKey] = [.contentModificationDateKey, .fileSizeKey]
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: keys)) ?? []
        let entries = files.compactMap { file -> (URL, Date, Int)? in
            guard let values = try? file.resourceValues(forKeys: Set(keys)) else { return nil }
            return (file, values.contentModificationDate ?? .distantPast, values.fileSize ?? 0)
        }.sorted { $0.1 > $1.1 }
        var total = 0
        for (file, _, size) in entries {
            total += size
            if total > limit { try? FileManager.default.removeItem(at: file) }
        }
    }

    private func store(_ image: UIImage, key: String) {
        let cost = Int(image.size.width * image.scale * image.size.height * image.scale * 4)
        memory.withLock { state in
            if state.images[key] == nil { state.cost += cost }
            state.images[key] = image
            state.order.removeAll { $0 == key }
            state.order.append(key)
            while state.cost > limit, let oldest = state.order.first {
                state.order.removeFirst()
                if let evicted = state.images.removeValue(forKey: oldest) {
                    state.cost -= Int(evicted.size.width * evicted.scale * evicted.size.height * evicted.scale * 4)
                }
            }
        }
    }

    func removeAll() {
        memory.withLock { $0 = Memory() }
        try? FileManager.default.removeItem(at: directory)
    }
}
