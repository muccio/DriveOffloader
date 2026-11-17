import AppKit
import Foundation
import UniformTypeIdentifiers

struct VolumeSpaceSummary: Sendable {
    let totalBytes: Int64
    let availableBytes: Int64
    let availableImportantBytes: Int64

    var usedBytes: Int64 {
        max(0, totalBytes - availableBytes)
    }

    var usedFraction: Double {
        guard totalBytes > 0 else { return 0 }
        return min(1.0, max(0.0, Double(usedBytes) / Double(totalBytes)))
    }
}

struct MeasuredDirectoryStats: Sendable {
    let allocatedBytes: Int64
    let logicalBytes: Int64
    let fileCount: Int
    let latestModified: Date?
}

enum StorageUtilities {
    static func volumeSpaceSummary(for path: String = "/") -> VolumeSpaceSummary? {
        let url = URL(fileURLWithPath: path)
        guard let values = try? url.resourceValues(forKeys: [
            .volumeTotalCapacityKey,
            .volumeAvailableCapacityKey,
            .volumeAvailableCapacityForImportantUsageKey
        ]) else {
            return nil
        }
        let total = Int64(values.volumeTotalCapacity ?? 0)
        let avail = Int64(values.volumeAvailableCapacity ?? 0)
        let availImportant = values.volumeAvailableCapacityForImportantUsage ?? avail
        guard total > 0 else { return nil }
        return VolumeSpaceSummary(
            totalBytes: total,
            availableBytes: avail,
            availableImportantBytes: availImportant
        )
    }

    static func protectedSystemRoots() -> Set<String> {
        let home = FileManager.default.homeDirectoryForCurrentUser.resolvingSymlinksInPath().path
        let library = "\(home)/Library"
        return [
            "/",
            "/Applications",
            "/System",
            "/Library",
            "/Library/Caches",
            "/Library/Logs",
            "/Library/Application Support",
            "/Users",
            home,
            "\(home)/Applications",
            "\(home)/Desktop",
            "\(home)/Documents",
            "\(home)/Downloads",
            "\(home)/Movies",
            "\(home)/Music",
            "\(home)/Pictures",
            "\(home)/Public",
            "\(home)/.Trash",
            "\(home)/.cache",
            library,
            "\(library)/Application Support",
            "\(library)/Application Support/Google",
            "\(library)/Application Support/Google/DriveFS",
            "\(library)/Caches",
            "\(library)/CloudStorage",
            "\(library)/Containers",
            "\(library)/Developer",
            "\(library)/Group Containers",
            "\(library)/Logs"
        ]
    }

    static func isProtectedCloudPath(_ path: String) -> Bool {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let cloudStorage = "\(home)/Library/CloudStorage"
        let mobileDocs = "\(home)/Library/Mobile Documents"
        let driveFS = "\(home)/Library/Application Support/Google/DriveFS"
        return path == cloudStorage
            || path.hasPrefix(cloudStorage + "/")
            || path == mobileDocs
            || path.hasPrefix(mobileDocs + "/")
            || path == driveFS
            || path.hasPrefix(driveFS + "/")
    }

    static func isSymlinkOrAlias(_ url: URL) -> Bool {
        guard let values = try? url.resourceValues(forKeys: [.isSymbolicLinkKey, .isAliasFileKey]) else {
            return false
        }
        return values.isSymbolicLink == true || values.isAliasFile == true
    }

    /// Measures APFS physical allocation size recursively without following symlinks, aliases, or hydrating cloud placeholders.
    static func measureAllocatedSize(
        at url: URL,
        excludingCanonicalPaths: Set<String> = []
    ) -> MeasuredDirectoryStats {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: url.path, isDirectory: &isDir) else {
            return MeasuredDirectoryStats(allocatedBytes: 0, logicalBytes: 0, fileCount: 0, latestModified: nil)
        }

        let keys: [URLResourceKey] = [
            .totalFileAllocatedSizeKey,
            .fileSizeKey,
            .isRegularFileKey,
            .isDirectoryKey,
            .isPackageKey,
            .isSymbolicLinkKey,
            .isAliasFileKey,
            .contentModificationDateKey
        ]

        guard let rootValues = try? url.resourceValues(forKeys: Set(keys)) else {
            return MeasuredDirectoryStats(allocatedBytes: 0, logicalBytes: 0, fileCount: 0, latestModified: nil)
        }

        if rootValues.isSymbolicLink == true || rootValues.isAliasFile == true {
            return MeasuredDirectoryStats(allocatedBytes: 0, logicalBytes: 0, fileCount: 0, latestModified: nil)
        }

        if !isDir.boolValue {
            let alloc = Int64(rootValues.totalFileAllocatedSize ?? 0)
            let logical = Int64(rootValues.fileSize ?? 0)
            return MeasuredDirectoryStats(
                allocatedBytes: alloc,
                logicalBytes: logical,
                fileCount: 1,
                latestModified: rootValues.contentModificationDate
            )
        }

        var totalAlloc: Int64 = 0
        var totalLogical: Int64 = 0
        var fileCount = 0
        var latestModified: Date? = rootValues.contentModificationDate

        guard let enumerator = fm.enumerator(
            at: url,
            includingPropertiesForKeys: keys,
            options: [],
            errorHandler: { _, _ in true }
        ) else {
            return MeasuredDirectoryStats(allocatedBytes: 0, logicalBytes: 0, fileCount: 0, latestModified: nil)
        }

        while let next = enumerator.nextObject() as? URL {
            if !excludingCanonicalPaths.isEmpty {
                let resolved = next.resolvingSymlinksInPath().path
                if excludingCanonicalPaths.contains(resolved) {
                    enumerator.skipDescendants()
                    continue
                }
            }

            guard let values = try? next.resourceValues(forKeys: Set(keys)) else { continue }
            if values.isSymbolicLink == true || values.isAliasFile == true {
                enumerator.skipDescendants()
                continue
            }

            if values.isRegularFile == true {
                fileCount += 1
                totalAlloc += Int64(values.totalFileAllocatedSize ?? 0)
                totalLogical += Int64(values.fileSize ?? 0)
                if let mod = values.contentModificationDate {
                    if let current = latestModified {
                        if mod > current { latestModified = mod }
                    } else {
                        latestModified = mod
                    }
                }
            }
        }

        return MeasuredDirectoryStats(
            allocatedBytes: totalAlloc,
            logicalBytes: totalLogical,
            fileCount: fileCount,
            latestModified: latestModified
        )
    }

    static func deleteURLs(
        _ targets: [(url: URL, name: String, sizeBytes: Int64)],
        moveToTrash: Bool,
        onProgress: @Sendable (OperationProgress) -> Void
    ) async throws -> OperationSummary {
        let fm = FileManager.default
        let protected = protectedSystemRoots()
        let totalBytes = max(1, targets.reduce(Int64(0)) { $0 + $1.sizeBytes })

        var processedItems = 0
        var processedBytes: Int64 = 0
        var succeeded = 0
        var failed = 0
        var freedBytes: Int64 = 0
        var errors: [String] = []
        var privilegedPending: [(url: URL, name: String, sizeBytes: Int64)] = []

        for target in targets {
            try Task.checkCancellation()

            onProgress(
                OperationProgress(
                    phase: moveToTrash ? "Moving to Trash…" : "Deleting permanently…",
                    processedItems: processedItems,
                    totalItems: max(1, targets.count),
                    processedBytes: processedBytes,
                    totalBytes: totalBytes,
                    currentSubpath: target.name
                )
            )

            let canonical = target.url.resolvingSymlinksInPath().path
            if protected.contains(canonical) {
                failed += 1
                errors.append("Refused to delete protected system path: \(target.url.path)")
                processedItems += 1
                processedBytes += target.sizeBytes
                continue
            }

            if !fm.fileExists(atPath: target.url.path) {
                succeeded += 1
                freedBytes += target.sizeBytes
                processedItems += 1
                processedBytes += target.sizeBytes
                continue
            }

            do {
                if moveToTrash {
                    var resultingURL: NSURL?
                    try fm.trashItem(at: target.url, resultingItemURL: &resultingURL)
                } else {
                    try fm.removeItem(at: target.url)
                }
                succeeded += 1
                freedBytes += target.sizeBytes
            } catch {
                let nsErr = error as NSError
                if StorageEngine.isPermissionError(nsErr) {
                    privilegedPending.append(target)
                } else {
                    failed += 1
                    errors.append("\(target.name): \(error.localizedDescription)")
                }
            }

            processedItems += 1
            processedBytes += target.sizeBytes
        }

        if !privilegedPending.isEmpty {
            try Task.checkCancellation()
            onProgress(
                OperationProgress(
                    phase: "Requesting administrator permission…",
                    processedItems: processedItems,
                    totalItems: max(1, targets.count),
                    processedBytes: processedBytes,
                    totalBytes: totalBytes,
                    currentSubpath: "\(privilegedPending.count) protected item(s)"
                )
            )

            let commands = privilegedPending.map { "rm -rf \(StorageEngine.shellEscaped($0.url.path))" }
            do {
                try await StorageEngine.runPrivilegedBatchScript(commands)
                for target in privilegedPending {
                    if fm.fileExists(atPath: target.url.path) {
                        failed += 1
                        errors.append("\(target.name): still exists after admin removal.")
                    } else {
                        succeeded += 1
                        freedBytes += target.sizeBytes
                    }
                }
            } catch {
                failed += privilegedPending.count
                errors.append("Admin deletion cancelled or failed: \(error.localizedDescription)")
            }
        }

        return OperationSummary(
            succeededCount: succeeded,
            failedCount: failed,
            bytesAffected: freedBytes,
            dryRun: false,
            errors: errors
        )
    }

    @MainActor
    static func chooseFolders(prompt: String = "Select Folder", initialDirectory: URL? = nil) -> [URL] {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.canCreateDirectories = false
        panel.showsHiddenFiles = true
        panel.prompt = prompt
        if let initialDirectory {
            panel.directoryURL = initialDirectory
        }
        guard panel.runModal() == .OK else { return [] }
        return panel.urls
    }
}
