// Installed-model bookkeeping over the on-disk models directory.
//
// A model is "installed" when `<modelsDirectory>/<assetName>` exists as an
// `.aimodel` directory. `ModelStore` enumerates what's present, resolves paths
// for the dictation controller, reports on-disk sizes, and deletes assets.
// `@Observable` so the Models page reflects installs/deletes live.

import Foundation
import Observation

@MainActor
@Observable
public final class ModelStore {
    /// Set of catalog ids currently installed. Recomputed by `refresh()`.
    public private(set) var installedIDs: Set<String> = []
    /// On-disk byte size per installed id (best-effort; 0 if unknown).
    public private(set) var sizes: [String: Int64] = [:]

    private var settings: AppSettings

    public init(settings: AppSettings) {
        self.settings = settings
        refresh()
    }

    /// Absolute `.aimodel` path a spec installs to under the current models dir.
    public func installURL(for spec: ModelSpec) -> URL {
        settings.modelsDirectory.appending(path: spec.assetName, directoryHint: .isDirectory)
    }

    public func isInstalled(_ spec: ModelSpec) -> Bool {
        installedIDs.contains(spec.id)
    }

    /// Re-scan the models directory. Cheap; call after install/delete or when the
    /// directory setting changes.
    public func refresh() {
        var present: Set<String> = []
        var newSizes: [String: Int64] = [:]
        let fm = FileManager.default
        for spec in ModelCatalog.all {
            let url = installURL(for: spec)
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue, Self.looksValid(url) {
                present.insert(spec.id)
                newSizes[spec.id] = Self.directorySize(url)
            }
        }
        installedIDs = present
        sizes = newSizes
    }

    /// Remove an installed asset from disk.
    public func delete(_ spec: ModelSpec) throws {
        let url = installURL(for: spec)
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
        refresh()
    }

    /// Human-readable installed size, or `nil` if not installed.
    public func formattedSize(for spec: ModelSpec) -> String? {
        guard let bytes = sizes[spec.id] else { return nil }
        return ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    // MARK: Validation / sizing

    /// A converted `.aimodel` is a non-empty directory. We don't hard-require a
    /// specific inner file (the layout varies per backend); a directory with any
    /// contents is treated as a candidate and the engine validates on load.
    private static func looksValid(_ url: URL) -> Bool {
        let contents = try? FileManager.default.contentsOfDirectory(atPath: url.path)
        return (contents?.isEmpty == false)
    }

    private static func directorySize(_ url: URL) -> Int64 {
        var total: Int64 = 0
        let keys: [URLResourceKey] = [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey, .isRegularFileKey]
        guard let e = FileManager.default.enumerator(at: url, includingPropertiesForKeys: keys) else { return 0 }
        for case let fileURL as URL in e {
            let values = try? fileURL.resourceValues(forKeys: Set(keys))
            if values?.isRegularFile == true {
                total += Int64(values?.totalFileAllocatedSize ?? values?.fileAllocatedSize ?? 0)
            }
        }
        return total
    }
}
