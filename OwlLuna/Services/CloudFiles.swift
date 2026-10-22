import Foundation
import os

/// The synced copy of the library: the app's iCloud container on a device, or any folder in tests.
/// The library the app works in always stays on the device; syncing copies whole notebooks to and from this folder.
struct CloudFolder: Sendable, Hashable {
    let url: URL
    /// True for a real iCloud container, whose files may still need downloading before they can be read.
    var isUbiquitous = false

    var library: URL { url.appending(path: "Library", directoryHint: .isDirectory) }
    var stickers: URL { url.appending(path: "Stickers", directoryHint: .isDirectory) }
    var papers: URL { url.appending(path: "Papers", directoryHint: .isDirectory) }
    var tombstones: URL { url.appending(path: "Deleted", directoryHint: .isDirectory) }
    var foldersFile: URL { library.appending(path: "folders.json") }
    var smartShelvesFile: URL { library.appending(path: "smart-shelves.json") }
    /// The pens in the tray, which every device shares.
    var pensFile: URL { url.appending(path: "pens.json") }
    /// A random ID naming this synced copy, so a device can tell an erased or different copy from the one it knows.
    var copyFile: URL { url.appending(path: "copy-id") }

    func package(_ id: UUID) -> URL {
        library.appending(path: "\(id.uuidString).\(StorageRoot.packageExtension)", directoryHint: .isDirectory)
    }

    func tombstone(_ id: UUID) -> URL { tombstones.appending(path: id.uuidString) }

    static let uploadExtension = "uploading"

    /// Where a notebook new to the synced copy is assembled before it is moved into place. No listing takes it for a notebook.
    func upload(_ id: UUID) -> URL {
        library.appending(path: "\(id.uuidString)-\(UUID().uuidString).\(Self.uploadExtension)", directoryHint: .isDirectory)
    }
}

/// How a pass asks iCloud for files and gives them back. A test stands in for iCloud here.
struct CloudAccess: Sendable {
    /// Asks for files to be brought down and waits for them, up to the limit. Returns those still not on the device.
    var fetch: @Sendable (_ files: [URL], _ limit: Duration) async -> [URL]
    /// Takes a file's copy off the device once iCloud holds all of it. True when it did.
    var evict: @Sendable (URL) -> Bool
    /// Whether iCloud has a newer version of a file than the one on the device, still to come down.
    var isBehind: @Sendable (URL) -> Bool = { _ in false }

    static func live(_ cloud: CloudFolder) -> CloudAccess {
        guard cloud.isUbiquitous else { return CloudAccess(fetch: { files, _ in files.filter(CloudFiles.isPending) }, evict: { _ in false }) }
        return CloudAccess(fetch: { await CloudFiles.download($0, within: $1) }, evict: CloudFiles.evict, isBehind: CloudFiles.isBehind)
    }
}

/// Getting files in an iCloud container onto the device before they are read.
enum CloudFiles {
    /// The real name of a file iCloud lists as ".<name>.icloud" until it is downloaded, nil for any other file.
    static func placeholderTarget(_ name: String) -> String? {
        name.hasPrefix(".") && name.hasSuffix(".icloud") && name.count > 8 ? String(name.dropFirst().dropLast(7)) : nil
    }

    /// Where iCloud lists a file it hasn't downloaded: ".<name>.icloud" beside it.
    static func placeholder(of url: URL) -> URL {
        url.deletingLastPathComponent().appending(path: ".\(url.lastPathComponent).icloud")
    }

    /// What a folder holds, each placeholder under the name of the file it stands for.
    static func names(in directory: URL) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: directory.path(percentEncoded: false))) ?? []).map { placeholderTarget($0) ?? $0 }
    }

    /// Whether a file in an iCloud container isn't on the device yet: a placeholder, or an item iCloud says isn't downloaded.
    static func isPending(_ url: URL) -> Bool {
        if FileManager.default.fileExists(atPath: placeholder(of: url).path(percentEncoded: false)) { return true }
        return values(url, [.ubiquitousItemDownloadingStatusKey])?.ubiquitousItemDownloadingStatus == .notDownloaded
    }

    /// Read afresh each time, as a URL keeps what it was told.
    private static func values(_ url: URL, _ keys: Set<URLResourceKey>) -> URLResourceValues? {
        var url = url
        url.removeAllCachedResourceValues()
        return try? url.resourceValues(forKeys: keys)
    }

    /// Asks for files to be downloaded, an older version too, and waits up to `limit` for those not on the device.
    /// It stops sooner once nothing has come for `quiet`, or iCloud has given a reason for each, as it does with no
    /// network, so a pass isn't held up for what can't come. Returns what hadn't arrived.
    static func download(_ files: [URL], within limit: Duration, quiet: Duration = .seconds(10)) async -> [URL] {
        let clock = ContinuousClock(), deadline = clock.now + limit
        for file in files where isPending(file) || downloadingStatus(file) == .downloaded {
            try? FileManager.default.startDownloadingUbiquitousItem(at: file)
        }
        var waiting = files.filter(isPending), lastArrival = clock.now
        while !waiting.isEmpty, clock.now < deadline, clock.now - lastArrival < quiet, !Task.isCancelled, !waiting.allSatisfy(cannotDownload) {
            try? await Task.sleep(for: .milliseconds(500))
            for file in waiting { try? FileManager.default.startDownloadingUbiquitousItem(at: file) }
            let still = waiting.filter(isPending)
            if still.count < waiting.count { lastArrival = clock.now }
            waiting = still
        }
        return waiting
    }

    /// Whether iCloud has a newer version of a file on the device than the one here.
    static func isBehind(_ url: URL) -> Bool {
        downloadingStatus(url) == .downloaded
    }

    private static func downloadingStatus(_ url: URL) -> URLUbiquitousItemDownloadingStatus? {
        values(url, [.ubiquitousItemDownloadingStatusKey])?.ubiquitousItemDownloadingStatus
    }

    private static func cannotDownload(_ url: URL) -> Bool {
        values(url, [.ubiquitousItemDownloadingErrorKey])?.ubiquitousItemDownloadingError != nil
    }

    /// Takes a file's copy off the device, once iCloud has all of it and nothing more is on its way up.
    static func evict(_ url: URL) -> Bool {
        let keys: Set<URLResourceKey> = [.ubiquitousItemIsUploadedKey, .ubiquitousItemIsUploadingKey]
        guard let state = values(url, keys), state.ubiquitousItemIsUploaded == true, state.ubiquitousItemIsUploading != true else { return false }
        do {
            try FileManager.default.evictUbiquitousItem(at: url)
            return true
        } catch {
            Logger(category: "sync").error("couldn't evict \(url.lastPathComponent): \(error.localizedDescription)")
            return false
        }
    }
}
