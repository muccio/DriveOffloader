import AppKit
import CoreServices
import Foundation

actor StorageEngine {
    static let archiveFolderName = "DriveOffloader_Archive"

    enum EngineError: LocalizedError {
        case invalidDestination(String)
        case verificationFailed(String)
        case privilegedOperationFailed(String)
        case cancelled

        var errorDescription: String? {
            switch self {
            case .invalidDestination(let msg): return msg
            case .verificationFailed(let msg): return msg
            case .privilegedOperationFailed(let msg): return msg
            case .cancelled: return "Operation cancelled."
            }
        }
    }

    nonisolated private static var appSupportDir: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support", isDirectory: true)
        let dir = appSupport.appendingPathComponent("DriveOffloader", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    nonisolated private static var manifestURL: URL {
        appSupportDir.appendingPathComponent("manifest.json")
    }

    nonisolated private static var lastScanURL: URL {
        appSupportDir.appendingPathComponent("last_scan.json")
    }

    nonisolated static func saveLastScanSync(_ items: [ScannedItem]) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(items) else { return }
        try? data.write(to: lastScanURL, options: [.atomic])
    }

    nonisolated static func loadLastScanSync() -> [ScannedItem] {
        guard let data = try? Data(contentsOf: lastScanURL) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let decoded = try? decoder.decode([ScannedItem].self, from: data) else { return [] }
        let fm = FileManager.default
        return decoded.filter { item in
            guard fm.fileExists(atPath: item.url.path) else { return false }
            let vals = try? item.url.resourceValues(forKeys: [.isAliasFileKey, .isSymbolicLinkKey])
            return vals?.isAliasFile != true && vals?.isSymbolicLink != true && !isOfflineStubBundle(at: item.url)
        }
    }

    nonisolated static func findPendingArchivePaths(items: [ScannedItem], driveRoot: URL?) -> Set<String> {
        guard let driveRoot else { return [] }
        let archiveRoot = driveRoot.appendingPathComponent(archiveFolderName, isDirectory: true)
        let fm = FileManager.default
        var found = Set<String>()
        for item in items {
            let destURL = archiveRoot.appendingPathComponent(item.relativeSubpath, isDirectory: item.isPackage)
            if fm.fileExists(atPath: destURL.path) {
                found.insert(item.path)
            }
        }
        return found
    }

    // MARK: - Google Drive Auto-Discovery

    nonisolated static func discoverGoogleDriveRoot() -> URL? {
        let cloudStorage = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/CloudStorage", isDirectory: true)
        guard let children = try? FileManager.default.contentsOfDirectory(
            at: cloudStorage,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return nil
        }

        let driveFolders = children.filter { $0.lastPathComponent.hasPrefix("GoogleDrive-") }
        let candidateNames = ["My Drive", "Il mio Drive", "MyDrive"]

        for folder in driveFolders {
            for name in candidateNames {
                let candidate = folder.appendingPathComponent(name, isDirectory: true)
                var isDir: ObjCBool = false
                if FileManager.default.fileExists(atPath: candidate.path, isDirectory: &isDir), isDir.boolValue {
                    return candidate
                }
            }
            if let sub = try? FileManager.default.contentsOfDirectory(
                at: folder,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            ) {
                for item in sub where (try? item.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                    let lower = item.lastPathComponent.lowercased()
                    if lower.contains("drive") {
                        return item
                    }
                }
            }
        }
        return nil
    }

    // MARK: - Scanning

    func scan(
        roots: [URL],
        minSizeBytes: Int64,
        driveRoot: URL?,
        onProgress: @Sendable (OperationProgress) -> Void
    ) async throws -> [ScannedItem] {
        var results: [ScannedItem] = []
        var totalBytesDiscovered: Int64 = 0
        var processedCount = 0

        let normalizedDrivePath = driveRoot?.standardizedFileURL.path
        let selfAppPath = Bundle.main.bundleURL.standardizedFileURL.path

        let keys: [URLResourceKey] = [
            .isDirectoryKey,
            .isPackageKey,
            .isAliasFileKey,
            .isSymbolicLinkKey,
            .totalFileAllocatedSizeKey,
            .fileSizeKey,
            .contentAccessDateKey,
            .contentModificationDateKey
        ]

        for root in roots {
            try Task.checkCancellation()
            let standardizedRoot = root.standardizedFileURL
            let rootName = standardizedRoot.lastPathComponent.isEmpty ? "Root" : standardizedRoot.lastPathComponent

            guard let enumerator = FileManager.default.enumerator(
                at: standardizedRoot,
                includingPropertiesForKeys: keys,
                options: [.skipsPackageDescendants, .skipsHiddenFiles],
                errorHandler: { _, _ in true }
            ) else {
                continue
            }

            while let rawURL = enumerator.nextObject() as? URL {
                try Task.checkCancellation()
                let url = rawURL.standardizedFileURL
                let path = url.path

                if path == "/System" || path.hasPrefix("/System/") {
                    enumerator.skipDescendants()
                    continue
                }
                if let drivePath = normalizedDrivePath, path == drivePath || path.hasPrefix(drivePath + "/") {
                    enumerator.skipDescendants()
                    continue
                }
                if path == selfAppPath || url.lastPathComponent == "DriveOffloader.app" {
                    enumerator.skipDescendants()
                    continue
                }

                guard let values = try? url.resourceValues(forKeys: Set(keys)) else {
                    continue
                }

                if values.isAliasFile == true || values.isSymbolicLink == true || url.lastPathComponent.hasSuffix(".driveoffloader.command") {
                    continue
                }

                let isPackage = values.isPackage == true
                let isDirectory = values.isDirectory == true

                if isPackage {
                    if let bundleID = Self.readBundleIdentifier(at: url),
                       bundleID.hasPrefix("com.apple.") || bundleID.hasPrefix("com.driveoffloader.stub.") {
                        continue
                    }
                    let sizeBytes = Self.computePackageSize(at: url)
                    guard sizeBytes >= minSizeBytes else { continue }

                    let lastOpened = Self.spotlightLastUsedDate(for: url)
                    let lastModified = values.contentModificationDate ?? Date.distantPast
                    let lastAccessed = values.contentAccessDate
                    let relative = Self.relativeSubpath(itemURL: url, scanRoot: standardizedRoot, rootName: rootName)
                    let kind: ItemKind = url.pathExtension.lowercased() == "app" ? .app : .package

                    let item = ScannedItem(
                        id: UUID(),
                        url: url,
                        scanRootURL: standardizedRoot,
                        relativeSubpath: relative,
                        name: url.lastPathComponent,
                        kind: kind,
                        isPackage: true,
                        sizeBytes: sizeBytes,
                        lastOpenedDate: lastOpened,
                        lastModifiedDate: lastModified,
                        lastAccessedDate: lastAccessed,
                        bundleIdentifier: Self.readBundleIdentifier(at: url)
                    )
                    results.append(item)
                    processedCount += 1
                    totalBytesDiscovered += sizeBytes

                    if processedCount % 15 == 0 {
                        onProgress(OperationProgress(
                            phase: "Scanning packages & files…",
                            processedItems: processedCount,
                            totalItems: max(processedCount, results.count),
                            processedBytes: totalBytesDiscovered,
                            totalBytes: totalBytesDiscovered,
                            currentSubpath: relative
                        ))
                    }
                    continue
                }

                if isDirectory {
                    continue
                }

                let sizeBytes = Int64(values.totalFileAllocatedSize ?? values.fileSize ?? 0)
                guard sizeBytes >= minSizeBytes else { continue }

                let lastOpened = Self.spotlightLastUsedDate(for: url)
                let lastModified = values.contentModificationDate ?? Date.distantPast
                let lastAccessed = values.contentAccessDate
                let relative = Self.relativeSubpath(itemURL: url, scanRoot: standardizedRoot, rootName: rootName)

                let item = ScannedItem(
                    id: UUID(),
                    url: url,
                    scanRootURL: standardizedRoot,
                    relativeSubpath: relative,
                    name: url.lastPathComponent,
                    kind: .file,
                    isPackage: false,
                    sizeBytes: sizeBytes,
                    lastOpenedDate: lastOpened,
                    lastModifiedDate: lastModified,
                    lastAccessedDate: lastAccessed,
                    bundleIdentifier: nil
                )
                results.append(item)
                processedCount += 1
                totalBytesDiscovered += sizeBytes

                if processedCount % 40 == 0 {
                    onProgress(OperationProgress(
                        phase: "Scanning files…",
                        processedItems: processedCount,
                        totalItems: processedCount,
                        processedBytes: totalBytesDiscovered,
                        totalBytes: totalBytesDiscovered,
                        currentSubpath: relative
                    ))
                }
            }
        }

        onProgress(OperationProgress(
            phase: "Scan complete",
            processedItems: results.count,
            totalItems: results.count,
            processedBytes: totalBytesDiscovered,
            totalBytes: totalBytesDiscovered,
            currentSubpath: ""
        ))

        return results
    }

    // MARK: - Metadata & Package Size Helpers

    private static func relativeSubpath(itemURL: URL, scanRoot: URL, rootName: String) -> String {
        let itemPath = itemURL.standardizedFileURL.path
        let rootPath = scanRoot.standardizedFileURL.path
        if itemPath.hasPrefix(rootPath + "/") {
            let suffix = String(itemPath.dropFirst(rootPath.count + 1))
            return rootName + "/" + suffix
        }
        return rootName + "/" + itemURL.lastPathComponent
    }

    private static func readBundleIdentifier(at packageURL: URL) -> String? {
        if let bundle = Bundle(url: packageURL), let id = bundle.bundleIdentifier {
            return id
        }
        let infoPlist = packageURL.appendingPathComponent("Contents/Info.plist")
        if let dict = NSDictionary(contentsOf: infoPlist), let id = dict["CFBundleIdentifier"] as? String {
            return id
        }
        return nil
    }

    private static func spotlightLastUsedDate(for url: URL) -> Date? {
        guard let mdItem = MDItemCreateWithURL(kCFAllocatorDefault, url as CFURL) else {
            return nil
        }
        guard let attr = MDItemCopyAttribute(mdItem, kMDItemLastUsedDate) else {
            return nil
        }
        return attr as? Date
    }

    private static func computePackageSize(at packageURL: URL) -> Int64 {
        let keys: Set<URLResourceKey> = [
            .isRegularFileKey,
            .totalFileAllocatedSizeKey,
            .fileSizeKey
        ]
        guard let enumerator = FileManager.default.enumerator(
            at: packageURL,
            includingPropertiesForKeys: Array(keys),
            options: [],
            errorHandler: { _, _ in true }
        ) else {
            return 0
        }

        var total: Int64 = 0
        while let fileURL = enumerator.nextObject() as? URL {
            guard let values = try? fileURL.resourceValues(forKeys: keys) else { continue }
            if values.isRegularFile == true {
                total += Int64(values.totalFileAllocatedSize ?? values.fileSize ?? 0)
            }
        }
        return total
    }

    // MARK: - Offloading

    private struct PendingPrivilegedOffload {
        let item: ScannedItem
        let destURL: URL
        let linkTypeLabel: String
        let tempArtifactURL: URL?
        let shellCommand: String
    }

    private struct PendingPrivilegedRestore {
        let entry: ManifestEntry
        let sourceArchiveURL: URL
        let originalURL: URL
        let tempRestoreURL: URL
        let shellCommand: String
    }

    func offload(
        items: [ScannedItem],
        driveRoot: URL,
        linkMode: LinkCreationMode,
        preferSymlinkForPackagesInAuto: Bool,
        waitForCloudSyncBeforeDelete: Bool,
        dryRun: Bool,
        onProgress: @Sendable (OperationProgress) -> Void
    ) async throws -> OperationSummary {
        let archiveRoot = driveRoot.appendingPathComponent(Self.archiveFolderName, isDirectory: true)
        if !dryRun {
            try FileManager.default.createDirectory(at: archiveRoot, withIntermediateDirectories: true)
        }

        let totalBytes = items.reduce(Int64(0)) { $0 + $1.sizeBytes }
        var processedBytes: Int64 = 0
        var processedCount = 0
        var succeeded = 0
        var failed = 0
        var freedBytes: Int64 = 0
        var errors: [String] = []
        var manifest = loadManifest()
        var pendingPrivileged: [PendingPrivilegedOffload] = []

        for item in items {
            if Task.isCancelled {
                throw EngineError.cancelled
            }

            onProgress(OperationProgress(
                phase: dryRun ? "Simulating offload…" : "Offloading to Google Drive…",
                processedItems: processedCount,
                totalItems: items.count,
                processedBytes: processedBytes,
                totalBytes: totalBytes,
                currentSubpath: item.relativeSubpath
            ))

            let destURL = archiveRoot.appendingPathComponent(item.relativeSubpath, isDirectory: item.isPackage)
            let effectiveLinkType = resolveLinkType(
                mode: linkMode,
                isPackage: item.isPackage,
                preferSymlinkForPackagesInAuto: preferSymlinkForPackagesInAuto
            )
            let linkTypeLabel = effectiveLinkType.label

            if dryRun {
                try? await Task.sleep(for: .milliseconds(30))
                succeeded += 1
                freedBytes += item.sizeBytes
            } else {
                do {
                    let snapshotCount = processedCount
                    let snapshotBytes = processedBytes
                    let totalCount = items.count

                    if let pending = try await performSingleOffload(
                        item: item,
                        destURL: destURL,
                        linkType: effectiveLinkType,
                        linkTypeLabel: linkTypeLabel,
                        waitForCloudSync: waitForCloudSyncBeforeDelete,
                        onSyncWaitProgress: { syncDetail, fraction in
                            let partialBytes = snapshotBytes + Int64(Double(item.sizeBytes) * fraction)
                            onProgress(OperationProgress(
                                phase: "Waiting for Google Drive upload (\(syncDetail))…",
                                processedItems: snapshotCount,
                                totalItems: totalCount,
                                processedBytes: partialBytes,
                                totalBytes: totalBytes,
                                currentSubpath: item.relativeSubpath
                            ))
                        }
                    ) {
                        pendingPrivileged.append(pending)
                    } else {
                        let entry = ManifestEntry(
                            id: UUID(),
                            originalPath: item.url.path,
                            driveArchivePath: destURL.path,
                            scanRootPath: item.scanRootURL.path,
                            sizeBytes: item.sizeBytes,
                            isApplicationBundle: item.kind == .app,
                            offloadDate: Date(),
                            linkType: linkTypeLabel
                        )
                        manifest.insert(entry, at: 0)
                        try saveManifest(manifest)

                        succeeded += 1
                        freedBytes += item.sizeBytes
                    }
                } catch is CancellationError {
                    for p in pendingPrivileged {
                        if let tmp = p.tempArtifactURL { try? FileManager.default.removeItem(at: tmp) }
                    }
                    throw EngineError.cancelled
                } catch {
                    failed += 1
                    errors.append("\(item.relativeSubpath): \(error.localizedDescription)")
                }
            }

            processedCount += 1
            processedBytes += item.sizeBytes

            onProgress(OperationProgress(
                phase: dryRun ? "Simulating offload…" : "Offloading to Google Drive…",
                processedItems: processedCount,
                totalItems: items.count,
                processedBytes: processedBytes,
                totalBytes: totalBytes,
                currentSubpath: item.relativeSubpath
            ))
        }

        if !pendingPrivileged.isEmpty {
            defer {
                for p in pendingPrivileged {
                    if let tmp = p.tempArtifactURL { try? FileManager.default.removeItem(at: tmp) }
                }
            }
            onProgress(OperationProgress(
                phase: "Authorizing replacement for \(pendingPrivileged.count) protected item(s)…",
                processedItems: processedCount,
                totalItems: items.count,
                processedBytes: processedBytes,
                totalBytes: totalBytes,
                currentSubpath: ""
            ))
            do {
                try await Self.runPrivilegedBatchScript(pendingPrivileged.map(\.shellCommand))
                for p in pendingPrivileged {
                    let entry = ManifestEntry(
                        id: UUID(),
                        originalPath: p.item.url.path,
                        driveArchivePath: p.destURL.path,
                        scanRootPath: p.item.scanRootURL.path,
                        sizeBytes: p.item.sizeBytes,
                        isApplicationBundle: p.item.kind == .app,
                        offloadDate: Date(),
                        linkType: p.linkTypeLabel
                    )
                    manifest.insert(entry, at: 0)
                    succeeded += 1
                    freedBytes += p.item.sizeBytes
                }
                try saveManifest(manifest)
            } catch {
                failed += pendingPrivileged.count
                errors.append("Administrator authorization failed: \(error.localizedDescription)")
            }
        }

        return OperationSummary(
            succeededCount: succeeded,
            failedCount: failed,
            bytesAffected: freedBytes,
            dryRun: dryRun,
            errors: errors
        )
    }

    private enum ResolvedLinkType {
        case offlineStub
        case noLink
        case finderAlias
        case posixSymlink

        var label: String {
            switch self {
            case .offlineStub: return "Offline Stub"
            case .noLink: return "Archive Only"
            case .finderAlias: return "Finder Alias"
            case .posixSymlink: return "POSIX Symlink"
            }
        }
    }

    private func resolveLinkType(
        mode: LinkCreationMode,
        isPackage: Bool,
        preferSymlinkForPackagesInAuto: Bool
    ) -> ResolvedLinkType {
        switch mode {
        case .offlineStub:
            return .offlineStub
        case .noLink:
            return .noLink
        case .finderAlias:
            return .finderAlias
        case .posixSymlink:
            return .posixSymlink
        case .autoSmart:
            if isPackage && preferSymlinkForPackagesInAuto {
                return .posixSymlink
            }
            return .offlineStub
        }
    }

    private func performSingleOffload(
        item: ScannedItem,
        destURL: URL,
        linkType: ResolvedLinkType,
        linkTypeLabel: String,
        waitForCloudSync: Bool,
        onSyncWaitProgress: @Sendable (String, Double) -> Void
    ) async throws -> PendingPrivilegedOffload? {
        let fm = FileManager.default
        let destParent = destURL.deletingLastPathComponent()
        try fm.createDirectory(at: destParent, withIntermediateDirectories: true)

        var reusedExistingCopy = false
        if fm.fileExists(atPath: destURL.path) {
            if Self.existingArchiveMatches(sourceURL: item.url, destURL: destURL, isPackage: item.isPackage, expectedSizeBytes: item.sizeBytes) {
                reusedExistingCopy = true
                onSyncWaitProgress("reusing existing archive copy…", 0.5)
            } else {
                try fm.removeItem(at: destURL)
            }
        }

        if !reusedExistingCopy {
            try fm.copyItem(at: item.url, to: destURL)

            if item.isPackage {
                Self.preserveBundleExecutablePermissions(at: destURL)
            }
        }

        // Verify destination exists before deleting local source
        guard fm.fileExists(atPath: destURL.path) else {
            throw EngineError.verificationFailed("Destination copy verification failed at \(destURL.path)")
        }
        if item.isPackage && !reusedExistingCopy {
            let destSize = Self.computePackageSize(at: destURL)
            if item.sizeBytes > 0 && destSize == 0 {
                throw EngineError.verificationFailed("Copied package appears empty at \(destURL.path)")
            }
        }

        if waitForCloudSync {
            try await waitForFileProviderUpload(
                at: destURL,
                isDirectoryOrPackage: item.isPackage,
                onProgressDetail: onSyncWaitProgress
            )
            onSyncWaitProgress("finalizing stub…", 1.0)
            if linkType == .offlineStub || linkType == .noLink {
                Task.detached(priority: .utility) {
                    try? FileManager.default.evictUbiquitousItem(at: destURL)
                }
            }
        }

        // Prepare offline stub (grabbing icon/version from local item BEFORE deletion so CloudStorage is never read)
        let staged = try Self.stageReplacementArtifact(
            originalURL: item.url,
            archiveURL: destURL,
            isPackage: item.isPackage,
            linkType: linkType,
            metadataSourceBundle: item.isPackage ? item.url : nil
        )

        do {
            try Self.applyReplacement(
                removingURL: item.url,
                staged: staged,
                linkType: linkType,
                archiveURL: destURL
            )
            return nil
        } catch let error as NSError where Self.isPermissionError(error) {
            let cmd = Self.privilegedReplaceCommand(
                removingPath: item.url.path,
                staged: staged,
                linkType: linkType,
                archivePath: destURL.path
            )
            return PendingPrivilegedOffload(
                item: item,
                destURL: destURL,
                linkTypeLabel: linkTypeLabel,
                tempArtifactURL: staged?.tempURL,
                shellCommand: cmd
            )
        } catch {
            if let tmp = staged?.tempURL { try? fm.removeItem(at: tmp) }
            throw error
        }
    }

    // MARK: - Google Drive / FileProvider Cloud Sync Verification

    private func waitForFileProviderUpload(
        at url: URL,
        isDirectoryOrPackage: Bool,
        onProgressDetail: @Sendable (String, Double) -> Void
    ) async throws {
        let isInCloudStorage = url.path.contains("/Library/CloudStorage/")
        let keys: Set<URLResourceKey> = [
            .isUbiquitousItemKey,
            .ubiquitousItemIsUploadedKey,
            .ubiquitousItemIsUploadingKey,
            .ubiquitousItemUploadingErrorKey,
            .isRegularFileKey,
            .isDirectoryKey
        ]

        if !isDirectoryOrPackage {
            var probeCount = 0
            while true {
                try Task.checkCancellation()
                var fileURL = URL(fileURLWithPath: url.path)
                fileURL.removeAllCachedResourceValues()
                guard FileManager.default.fileExists(atPath: fileURL.path) else {
                    throw EngineError.verificationFailed("Destination disappeared from Google Drive before sync completed.")
                }
                let values = try? fileURL.resourceValues(forKeys: keys)
                if values?.isUbiquitousItem != true {
                    if !isInCloudStorage || probeCount >= 10 { return }
                    onProgressDetail("registering with File Provider…", 0.0)
                } else if let err = values?.ubiquitousItemUploadingError {
                    throw EngineError.verificationFailed("Google Drive sync error (local file preserved): \(err.localizedDescription)")
                } else if values?.ubiquitousItemIsUploaded == true && values?.ubiquitousItemIsUploading != true {
                    onProgressDetail("upload complete", 1.0)
                    return
                } else {
                    onProgressDetail("uploading to cloud", 0.25)
                }
                probeCount += 1
                try await Task.sleep(for: .milliseconds(900))
            }
        }

        // Package / directory: collect regular files once (ignoring Finder metadata), then only re-poll remaining pending files
        var allFiles: [URL] = []
        if let enumerator = FileManager.default.enumerator(
            at: url,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [],
            errorHandler: { _, _ in true }
        ) {
            while let rawFile = enumerator.nextObject() as? URL {
                try Task.checkCancellation()
                if Self.isIgnoredCloudMetadataFile(rawFile) { continue }
                if (try? rawFile.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true {
                    allFiles.append(URL(fileURLWithPath: rawFile.path))
                }
            }
        }

        if allFiles.isEmpty {
            return
        }

        var pendingFiles = allFiles
        var confirmedUploadedCount = 0
        var probeCount = 0
        var stableAllNonUbiqPolls = 0
        var idleNoUploadingPolls = 0
        var lastConfirmedCount = -1

        while !pendingFiles.isEmpty {
            try Task.checkCancellation()
            var nextPending: [URL] = []
            var ubiquitousSeenInPass = 0
            var stillUploadingInPass = 0

            for fileURL in pendingFiles {
                try Task.checkCancellation()
                var mutable = fileURL
                mutable.removeAllCachedResourceValues()
                guard let values = try? mutable.resourceValues(forKeys: keys) else { continue }
                if values.isUbiquitousItem == true {
                    ubiquitousSeenInPass += 1
                    if let err = values.ubiquitousItemUploadingError {
                        throw EngineError.verificationFailed("Google Drive sync error (local file preserved): \(err.localizedDescription)")
                    }
                    let isUp = values.ubiquitousItemIsUploaded == true
                    let isIng = values.ubiquitousItemIsUploading == true
                    if isUp && !isIng {
                        confirmedUploadedCount += 1
                    } else {
                        if isIng { stillUploadingInPass += 1 }
                        nextPending.append(fileURL)
                    }
                } else {
                    nextPending.append(fileURL)
                }
            }

            pendingFiles = nextPending
            let totalTracked = max(1, confirmedUploadedCount + pendingFiles.count)
            let frac = min(0.98, Double(confirmedUploadedCount) / Double(totalTracked))
            onProgressDetail("\(confirmedUploadedCount)/\(totalTracked) files uploaded", frac)

            if pendingFiles.isEmpty {
                break
            }

            // If all remaining pending files are non-ubiquitous (skipped by Google Drive, e.g. symlinked framework duplicates)
            if ubiquitousSeenInPass == 0 {
                if confirmedUploadedCount > 0 {
                    stableAllNonUbiqPolls += 1
                    if stableAllNonUbiqPolls >= 2 {
                        break
                    }
                } else if !isInCloudStorage || probeCount >= 10 {
                    break
                }
            } else {
                stableAllNonUbiqPolls = 0
            }

            // If Google Drive is no longer actively uploading any file and uploaded count stopped changing
            if stillUploadingInPass == 0 && confirmedUploadedCount > 0 {
                if confirmedUploadedCount == lastConfirmedCount {
                    idleNoUploadingPolls += 1
                    if idleNoUploadingPolls >= 6 {
                        break
                    }
                } else {
                    idleNoUploadingPolls = 0
                }
            } else {
                idleNoUploadingPolls = 0
            }
            lastConfirmedCount = confirmedUploadedCount

            probeCount += 1
            try await Task.sleep(for: .milliseconds(900))
        }

        onProgressDetail("upload complete", 1.0)
    }

    private static func isIgnoredCloudMetadataFile(_ url: URL) -> Bool {
        let name = url.lastPathComponent
        if name == ".DS_Store" || name == ".localized" || name == ".Spotlight-V100" || name == ".Trashes" || name.hasPrefix("._") || name.hasPrefix("Icon\r") {
            return true
        }
        return false
    }

    private static func existingArchiveMatches(
        sourceURL: URL,
        destURL: URL,
        isPackage: Bool,
        expectedSizeBytes: Int64
    ) -> Bool {
        if !isPackage {
            let srcLogical = Int64((try? sourceURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
            let dstLogical = Int64((try? destURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
            if srcLogical > 0 {
                return dstLogical == srcLogical
            }
            return dstLogical == expectedSizeBytes
        }

        let keys: Set<URLResourceKey> = [.isRegularFileKey, .fileSizeKey]
        guard let en = FileManager.default.enumerator(
            at: destURL,
            includingPropertiesForKeys: Array(keys),
            options: [],
            errorHandler: { _, _ in true }
        ) else {
            return false
        }
        var logicalTotal: Int64 = 0
        while let fileURL = en.nextObject() as? URL {
            guard let vals = try? fileURL.resourceValues(forKeys: keys), vals.isRegularFile == true else { continue }
            logicalTotal += Int64(vals.fileSize ?? 0)
        }
        if expectedSizeBytes == 0 {
            return FileManager.default.fileExists(atPath: destURL.path)
        }
        return logicalTotal >= Int64(Double(expectedSizeBytes) * 0.85)
    }

    nonisolated static func checkCloudSyncStatus(for entry: ManifestEntry) -> CloudSyncStatus {
        let url = URL(fileURLWithPath: entry.driveArchivePath)
        return inspectCloudSyncMetrics(at: url, isDirectoryOrPackage: entry.isApplicationBundle).status
    }

    private struct CloudSyncMetrics {
        let status: CloudSyncStatus
        let totalFiles: Int
        let ubiquitousFiles: Int
        let uploadedFiles: Int
        var nonUbiquitousFiles: Int { max(0, totalFiles - ubiquitousFiles) }
    }

    private static func inspectCloudSyncMetrics(at url: URL, isDirectoryOrPackage: Bool) -> CloudSyncMetrics {
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else {
            return CloudSyncMetrics(status: .missingFromDrive, totalFiles: 0, ubiquitousFiles: 0, uploadedFiles: 0)
        }

        let keys: Set<URLResourceKey> = [
            .isUbiquitousItemKey,
            .ubiquitousItemIsUploadedKey,
            .ubiquitousItemIsUploadingKey,
            .ubiquitousItemUploadingErrorKey,
            .ubiquitousItemDownloadingStatusKey,
            .isRegularFileKey,
            .isDirectoryKey
        ]

        var rootURL = URL(fileURLWithPath: url.path)
        rootURL.removeAllCachedResourceValues()
        let rootValues = try? rootURL.resourceValues(forKeys: keys)
        let isDir = rootValues?.isDirectory == true

        if !isDirectoryOrPackage && !isDir {
            guard let values = rootValues, values.isUbiquitousItem == true else {
                return CloudSyncMetrics(status: .notCloudProvider, totalFiles: 1, ubiquitousFiles: 0, uploadedFiles: 0)
            }
            if let err = values.ubiquitousItemUploadingError {
                return CloudSyncMetrics(status: .error(err.localizedDescription), totalFiles: 1, ubiquitousFiles: 1, uploadedFiles: 0)
            }
            let uploaded = values.ubiquitousItemIsUploaded == true
            let uploading = values.ubiquitousItemIsUploading == true
            if uploaded && !uploading {
                let st: CloudSyncStatus = values.ubiquitousItemDownloadingStatus == .notDownloaded ? .syncedOnlineOnly : .syncedCachedLocally
                return CloudSyncMetrics(status: st, totalFiles: 1, ubiquitousFiles: 1, uploadedFiles: 1)
            }
            return CloudSyncMetrics(status: .uploading(uploadedFiles: 0, totalFiles: 1), totalFiles: 1, ubiquitousFiles: 1, uploadedFiles: 0)
        }

        guard let enumerator = fm.enumerator(
            at: url,
            includingPropertiesForKeys: Array(keys),
            options: [],
            errorHandler: { _, _ in true }
        ) else {
            return CloudSyncMetrics(status: .notCloudProvider, totalFiles: 0, ubiquitousFiles: 0, uploadedFiles: 0)
        }

        var totalFiles = 0
        var uploadedFiles = 0
        var onlineOnlyFiles = 0
        var ubiquitousCount = 0

        while let rawFile = enumerator.nextObject() as? URL {
            if Task.isCancelled {
                return CloudSyncMetrics(status: .checking, totalFiles: totalFiles, ubiquitousFiles: ubiquitousCount, uploadedFiles: uploadedFiles)
            }
            if Self.isIgnoredCloudMetadataFile(rawFile) { continue }
            var fileURL = URL(fileURLWithPath: rawFile.path)
            fileURL.removeAllCachedResourceValues()
            guard let values = try? fileURL.resourceValues(forKeys: keys) else { continue }
            guard values.isRegularFile == true else { continue }

            totalFiles += 1
            if values.isUbiquitousItem == true {
                ubiquitousCount += 1
                if let err = values.ubiquitousItemUploadingError {
                    return CloudSyncMetrics(status: .error(err.localizedDescription), totalFiles: totalFiles, ubiquitousFiles: ubiquitousCount, uploadedFiles: uploadedFiles)
                }
                if values.ubiquitousItemIsUploaded == true && values.ubiquitousItemIsUploading != true {
                    uploadedFiles += 1
                    if values.ubiquitousItemDownloadingStatus == .notDownloaded {
                        onlineOnlyFiles += 1
                    }
                }
            }
        }

        if totalFiles == 0 {
            if rootValues?.isUbiquitousItem == true {
                if rootValues?.ubiquitousItemIsUploaded == true && rootValues?.ubiquitousItemIsUploading != true {
                    let st: CloudSyncStatus = rootValues?.ubiquitousItemDownloadingStatus == .notDownloaded ? .syncedOnlineOnly : .syncedCachedLocally
                    return CloudSyncMetrics(status: st, totalFiles: 0, ubiquitousFiles: 1, uploadedFiles: 1)
                }
                return CloudSyncMetrics(status: .uploading(uploadedFiles: 0, totalFiles: 1), totalFiles: 0, ubiquitousFiles: 1, uploadedFiles: 0)
            }
            return CloudSyncMetrics(status: .notCloudProvider, totalFiles: 0, ubiquitousFiles: 0, uploadedFiles: 0)
        }

        if ubiquitousCount == 0 {
            return CloudSyncMetrics(status: .notCloudProvider, totalFiles: totalFiles, ubiquitousFiles: 0, uploadedFiles: 0)
        }
        if uploadedFiles == ubiquitousCount {
            let st: CloudSyncStatus = onlineOnlyFiles == ubiquitousCount ? .syncedOnlineOnly : .syncedCachedLocally
            return CloudSyncMetrics(status: st, totalFiles: totalFiles, ubiquitousFiles: ubiquitousCount, uploadedFiles: uploadedFiles)
        }
        return CloudSyncMetrics(
            status: .uploading(uploadedFiles: uploadedFiles, totalFiles: ubiquitousCount),
            totalFiles: totalFiles,
            ubiquitousFiles: ubiquitousCount,
            uploadedFiles: uploadedFiles
        )
    }

    // MARK: - Link & Offline Stub Creation

    private struct StagedReplacement {
        let destURL: URL
        let tempURL: URL?
        var destPath: String { destURL.path }
    }

    nonisolated static func isOfflineStubBundle(at url: URL) -> Bool {
        readBundleIdentifier(at: url)?.hasPrefix("com.driveoffloader.stub.") == true
    }

    private static func readStubSourceMetadata(from bundleURL: URL?) -> (displayName: String?, version: String?, iconURL: URL?) {
        guard let bundleURL else { return (nil, nil, nil) }
        let plistURL = bundleURL.appendingPathComponent("Contents/Info.plist")
        guard isSafeToReadWithoutHydration(plistURL),
              let data = try? Data(contentsOf: plistURL),
              let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any] else {
            return (nil, nil, nil)
        }

        let displayName = (plist["CFBundleDisplayName"] as? String) ?? (plist["CFBundleName"] as? String)
        let version = plist["CFBundleShortVersionString"] as? String
        var iconURL: URL?
        if let rawIcon = plist["CFBundleIconFile"] as? String, !rawIcon.isEmpty {
            let iconName = rawIcon.lowercased().hasSuffix(".icns") ? rawIcon : rawIcon + ".icns"
            let candidate = bundleURL.appendingPathComponent("Contents/Resources/\(iconName)")
            if isSafeToReadWithoutHydration(candidate),
               let size = (try? candidate.resourceValues(forKeys: [.fileSizeKey]).fileSize),
               size <= 8 * 1024 * 1024 {
                iconURL = candidate
            }
        }
        return (displayName, version, iconURL)
    }

    private static func isSafeToReadWithoutHydration(_ url: URL) -> Bool {
        guard FileManager.default.fileExists(atPath: url.path) else { return false }
        var check = URL(fileURLWithPath: url.path)
        check.removeAllCachedResourceValues()
        let vals = try? check.resourceValues(forKeys: [.isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey])
        if vals?.isUbiquitousItem == true && vals?.ubiquitousItemDownloadingStatus == .notDownloaded {
            return false
        }
        return true
    }

    private static func buildOfflineAppStub(
        at tempStubURL: URL,
        fallbackAppName: String,
        archiveURL: URL,
        metadataSourceBundle: URL?
    ) throws {
        let fm = FileManager.default
        let contentsURL = tempStubURL.appendingPathComponent("Contents", isDirectory: true)
        let macOSURL = contentsURL.appendingPathComponent("MacOS", isDirectory: true)
        let resourcesURL = contentsURL.appendingPathComponent("Resources", isDirectory: true)
        try fm.createDirectory(at: macOSURL, withIntermediateDirectories: true)
        try fm.createDirectory(at: resourcesURL, withIntermediateDirectories: true)

        let meta = readStubSourceMetadata(from: metadataSourceBundle)
        let baseName = fallbackAppName.lowercased().hasSuffix(".app")
            ? String(fallbackAppName.dropLast(4))
            : fallbackAppName
        let displayName = (meta.displayName?.isEmpty == false) ? meta.displayName! : baseName

        var plist: [String: Any] = [
            "CFBundleName": displayName,
            "CFBundleDisplayName": displayName,
            "CFBundleIdentifier": "com.driveoffloader.stub.\(UUID().uuidString.prefix(8))",
            "CFBundleExecutable": "DriveOffloaderStubLauncher",
            "CFBundlePackageType": "APPL",
            "CFBundleVersion": "1.0",
            "CFBundleShortVersionString": meta.version ?? "Cloud Stub",
            "LSMinimumSystemVersion": "14.0",
            "NSHighResolutionCapable": true,
            "DriveOffloaderStub": true,
            "DriveOffloaderArchivePath": archiveURL.path
        ]

        if let iconURL = meta.iconURL {
            let destIcon = resourcesURL.appendingPathComponent(iconURL.lastPathComponent)
            try? fm.copyItem(at: iconURL, to: destIcon)
            if fm.fileExists(atPath: destIcon.path) {
                plist["CFBundleIconFile"] = iconURL.lastPathComponent
            }
        }

        let plistData = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try plistData.write(to: contentsURL.appendingPathComponent("Info.plist"), options: [.atomic])

        let launcherScript = """
        #!/bin/bash
        ARCHIVE=\(shellEscaped(archiveURL.path))
        APP_NAME=\(shellEscaped(fallbackAppName))
        if [ ! -e "$ARCHIVE" ]; then
            /usr/bin/osascript -e 'on run argv' -e 'display alert "Archive Not Found" message ("The archived copy of " & (item 1 of argv) & " could not be found at:" & return & (item 2 of argv)) as warning' -e 'end run' -- "$APP_NAME" "$ARCHIVE"
            exit 1
        fi
        CHOICE=$(/usr/bin/osascript -e 'on run argv' -e 'button returned of (display dialog ((item 1 of argv) & " is offloaded to Google Drive (Online Only)." & return & return & "Download it from Google Drive and launch now?") buttons {"Cancel", "Download & Launch"} default button "Download & Launch" with title "DriveOffloader Cloud Stub")' -e 'end run' -- "$APP_NAME" 2>/dev/null)
        if [ "$CHOICE" = "Download & Launch" ]; then
            /usr/bin/open "$ARCHIVE"
        fi
        """
        let launcherURL = macOSURL.appendingPathComponent("DriveOffloaderStubLauncher")
        try launcherScript.write(to: launcherURL, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: launcherURL.path)
    }

    private static func buildOfflineCommandStub(
        at tempStubURL: URL,
        itemName: String,
        archiveURL: URL
    ) throws {
        let script = """
        #!/bin/bash
        ARCHIVE=\(shellEscaped(archiveURL.path))
        ITEM_NAME=\(shellEscaped(itemName))
        if [ ! -e "$ARCHIVE" ]; then
            /usr/bin/osascript -e 'on run argv' -e 'display alert "Archive Not Found" message ("The archived copy of " & (item 1 of argv) & " could not be found at:" & return & (item 2 of argv)) as warning' -e 'end run' -- "$ITEM_NAME" "$ARCHIVE"
            exit 1
        fi
        CHOICE=$(/usr/bin/osascript -e 'on run argv' -e 'button returned of (display dialog ((item 1 of argv) & " is archived in Google Drive (Online Only)." & return & return & "Download and open it now?") buttons {"Cancel", "Download & Open"} default button "Download & Open" with title "DriveOffloader Cloud Stub")' -e 'end run' -- "$ITEM_NAME" 2>/dev/null)
        if [ "$CHOICE" = "Download & Open" ]; then
            /usr/bin/open "$ARCHIVE"
        fi
        """
        try script.write(to: tempStubURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tempStubURL.path)
    }

    private static func stageReplacementArtifact(
        originalURL: URL,
        archiveURL: URL,
        isPackage: Bool,
        linkType: ResolvedLinkType,
        metadataSourceBundle: URL?
    ) throws -> StagedReplacement? {
        let fm = FileManager.default
        switch linkType {
        case .noLink:
            return nil
        case .posixSymlink:
            return StagedReplacement(destURL: originalURL, tempURL: nil)
        case .finderAlias:
            let tempAliasURL = fm.temporaryDirectory.appendingPathComponent("DriveOffloader_\(UUID().uuidString)")
            let bookmark = try archiveURL.bookmarkData(
                options: [.suitableForBookmarkFile],
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
            try URL.writeBookmarkData(bookmark, to: tempAliasURL)
            return StagedReplacement(destURL: originalURL, tempURL: tempAliasURL)
        case .offlineStub:
            if isPackage {
                let tempStubURL = fm.temporaryDirectory.appendingPathComponent("DriveOffloaderStub_\(UUID().uuidString).app")
                try buildOfflineAppStub(
                    at: tempStubURL,
                    fallbackAppName: originalURL.lastPathComponent,
                    archiveURL: archiveURL,
                    metadataSourceBundle: metadataSourceBundle
                )
                return StagedReplacement(destURL: originalURL, tempURL: tempStubURL)
            } else {
                let commandURL = URL(fileURLWithPath: originalURL.path + ".driveoffloader.command")
                let tempCmdURL = fm.temporaryDirectory.appendingPathComponent("DriveOffloaderStub_\(UUID().uuidString).command")
                try buildOfflineCommandStub(
                    at: tempCmdURL,
                    itemName: originalURL.lastPathComponent,
                    archiveURL: archiveURL
                )
                return StagedReplacement(destURL: commandURL, tempURL: tempCmdURL)
            }
        }
    }

    private static func applyReplacement(
        removingURL: URL,
        staged: StagedReplacement?,
        linkType: ResolvedLinkType,
        archiveURL: URL
    ) throws {
        let fm = FileManager.default
        try fm.removeItem(at: removingURL)
        switch linkType {
        case .noLink:
            return
        case .posixSymlink:
            try fm.createSymbolicLink(at: removingURL, withDestinationURL: archiveURL)
        case .finderAlias, .offlineStub:
            guard let staged, let tempURL = staged.tempURL else { return }
            if fm.fileExists(atPath: staged.destURL.path) || symlinkExists(atPath: staged.destURL.path) {
                try fm.removeItem(at: staged.destURL)
            }
            try fm.moveItem(at: tempURL, to: staged.destURL)
        }
    }

    private static func privilegedReplaceCommand(
        removingPath: String,
        staged: StagedReplacement?,
        linkType: ResolvedLinkType,
        archivePath: String
    ) -> String {
        let rmCmd = "rm -rf \(shellEscaped(removingPath))"
        switch linkType {
        case .noLink:
            return rmCmd
        case .posixSymlink:
            return "\(rmCmd) && ln -s \(shellEscaped(archivePath)) \(shellEscaped(removingPath))"
        case .finderAlias, .offlineStub:
            guard let staged, let tempPath = staged.tempURL?.path else { return rmCmd }
            return "\(rmCmd) && rm -rf \(shellEscaped(staged.destPath)) && ditto \(shellEscaped(tempPath)) \(shellEscaped(staged.destPath))"
        }
    }

    // MARK: - Convert Existing Symlinks / Aliases to Safe Offline Stubs

    private struct LinkConversionTarget {
        let linkURL: URL
        let archiveURL: URL
        let isPackage: Bool
        let matchedEntryID: UUID?
    }

    private struct PendingPrivilegedConversion {
        let target: LinkConversionTarget
        let staged: StagedReplacement
        let shellCommand: String
    }

    func convertLinksToSafeStubs(
        searchRoots: [URL],
        driveRoot: URL?,
        onProgress: @Sendable (OperationProgress) -> Void
    ) async throws -> OperationSummary {
        var manifest = loadManifest()
        let targets = Self.collectLinkConversionTargets(
            manifest: manifest,
            searchRoots: searchRoots,
            driveRoot: driveRoot
        )

        guard !targets.isEmpty else {
            return OperationSummary(succeededCount: 0, failedCount: 0, bytesAffected: 0, dryRun: false, errors: [])
        }

        let fm = FileManager.default
        var processed = 0
        var succeeded = 0
        var failed = 0
        var errors: [String] = []
        var pendingPrivileged: [PendingPrivilegedConversion] = []

        for target in targets {
            if Task.isCancelled {
                for p in pendingPrivileged {
                    if let tmp = p.staged.tempURL { try? fm.removeItem(at: tmp) }
                }
                throw EngineError.cancelled
            }

            onProgress(OperationProgress(
                phase: "Converting links to Safe Offline Stubs…",
                processedItems: processed,
                totalItems: targets.count,
                processedBytes: Int64(processed),
                totalBytes: Int64(targets.count),
                currentSubpath: target.linkURL.lastPathComponent
            ))

            do {
                guard let staged = try Self.stageReplacementArtifact(
                    originalURL: target.linkURL,
                    archiveURL: target.archiveURL,
                    isPackage: target.isPackage,
                    linkType: .offlineStub,
                    metadataSourceBundle: target.isPackage ? target.archiveURL : nil
                ) else {
                    continue
                }

                do {
                    try Self.applyReplacement(
                        removingURL: target.linkURL,
                        staged: staged,
                        linkType: .offlineStub,
                        archiveURL: target.archiveURL
                    )
                    if let entryID = target.matchedEntryID,
                       let idx = manifest.firstIndex(where: { $0.id == entryID }) {
                        manifest[idx] = Self.withUpdatedLinkType(manifest[idx], linkType: "Offline Stub")
                    }
                    succeeded += 1
                } catch let error as NSError where Self.isPermissionError(error) {
                    let cmd = Self.privilegedReplaceCommand(
                        removingPath: target.linkURL.path,
                        staged: staged,
                        linkType: .offlineStub,
                        archivePath: target.archiveURL.path
                    )
                    pendingPrivileged.append(PendingPrivilegedConversion(
                        target: target,
                        staged: staged,
                        shellCommand: cmd
                    ))
                } catch {
                    if let tmp = staged.tempURL { try? fm.removeItem(at: tmp) }
                    throw error
                }
            } catch {
                failed += 1
                errors.append("\(target.linkURL.lastPathComponent): \(error.localizedDescription)")
            }

            processed += 1
        }

        if !pendingPrivileged.isEmpty {
            defer {
                for p in pendingPrivileged {
                    if let tmp = p.staged.tempURL { try? fm.removeItem(at: tmp) }
                }
            }
            onProgress(OperationProgress(
                phase: "Authorizing stub conversion for \(pendingPrivileged.count) item(s)…",
                processedItems: processed,
                totalItems: targets.count,
                processedBytes: Int64(processed),
                totalBytes: Int64(targets.count),
                currentSubpath: ""
            ))
            do {
                try await Self.runPrivilegedBatchScript(pendingPrivileged.map(\.shellCommand))
                for p in pendingPrivileged {
                    if let entryID = p.target.matchedEntryID,
                       let idx = manifest.firstIndex(where: { $0.id == entryID }) {
                        manifest[idx] = Self.withUpdatedLinkType(manifest[idx], linkType: "Offline Stub")
                    }
                    succeeded += 1
                }
            } catch {
                failed += pendingPrivileged.count
                errors.append("Administrator authorization failed: \(error.localizedDescription)")
            }
        }

        try? saveManifest(manifest)

        return OperationSummary(
            succeededCount: succeeded,
            failedCount: failed,
            bytesAffected: 0,
            dryRun: false,
            errors: errors
        )
    }

    private static func withUpdatedLinkType(_ entry: ManifestEntry, linkType: String) -> ManifestEntry {
        ManifestEntry(
            id: entry.id,
            originalPath: entry.originalPath,
            driveArchivePath: entry.driveArchivePath,
            scanRootPath: entry.scanRootPath,
            sizeBytes: entry.sizeBytes,
            isApplicationBundle: entry.isApplicationBundle,
            offloadDate: entry.offloadDate,
            linkType: linkType
        )
    }

    private static func collectLinkConversionTargets(
        manifest: [ManifestEntry],
        searchRoots: [URL],
        driveRoot: URL?
    ) -> [LinkConversionTarget] {
        let fm = FileManager.default
        let archivePrefix: String? = driveRoot.map {
            $0.appendingPathComponent(archiveFolderName, isDirectory: true).standardizedFileURL.path + "/"
        }
        var entryByArchivePath: [String: ManifestEntry] = [:]
        var entryByOriginalPath: [String: ManifestEntry] = [:]
        for entry in manifest {
            entryByArchivePath[URL(fileURLWithPath: entry.driveArchivePath).standardizedFileURL.path] = entry
            entryByOriginalPath[URL(fileURLWithPath: entry.originalPath).standardizedFileURL.path] = entry
        }

        var seenLinks = Set<String>()
        var targets: [LinkConversionTarget] = []

        func considerLink(at url: URL) {
            let linkPath = url.path
            guard !seenLinks.contains(linkPath) else { return }
            guard let vals = try? url.resourceValues(forKeys: [.isSymbolicLinkKey, .isAliasFileKey]) else { return }
            let isSym = vals.isSymbolicLink == true
            let isAlias = vals.isAliasFile == true
            guard isSym || isAlias else { return }

            var resolvedDestPath: String?
            if isSym, let rawDest = try? fm.destinationOfSymbolicLink(atPath: linkPath) {
                resolvedDestPath = URL(fileURLWithPath: rawDest, relativeTo: url.deletingLastPathComponent()).standardizedFileURL.path
            } else if isAlias,
                      let bookmark = try? URL.bookmarkData(withContentsOf: url),
                      let path = URL.resourceValues(forKeys: [.pathKey], fromBookmarkData: bookmark)?.path {
                resolvedDestPath = URL(fileURLWithPath: path).standardizedFileURL.path
            }

            let matchedEntry = resolvedDestPath.flatMap { entryByArchivePath[$0] } ?? entryByOriginalPath[linkPath]
            let pointsToArchive: Bool = {
                if matchedEntry != nil { return true }
                guard let dest = resolvedDestPath else { return false }
                if let archivePrefix, dest.hasPrefix(archivePrefix) { return true }
                return dest.contains("/" + archiveFolderName + "/")
            }()
            guard pointsToArchive else { return }

            let finalDestPath = resolvedDestPath ?? matchedEntry?.driveArchivePath
            guard let finalDestPath else { return }
            let archiveURL = URL(fileURLWithPath: finalDestPath)
            let ext = url.pathExtension.lowercased()
            let archiveExt = archiveURL.pathExtension.lowercased()
            let isPkg = (matchedEntry?.isApplicationBundle == true)
                || ["app", "bundle", "pkg", "framework"].contains(ext)
                || ["app", "bundle", "pkg", "framework"].contains(archiveExt)

            seenLinks.insert(linkPath)
            targets.append(LinkConversionTarget(
                linkURL: url,
                archiveURL: archiveURL,
                isPackage: isPkg,
                matchedEntryID: matchedEntry?.id
            ))
        }

        for entry in manifest {
            considerLink(at: URL(fileURLWithPath: entry.originalPath))
        }

        var rootDirs: [URL] = searchRoots
        for entry in manifest {
            rootDirs.append(URL(fileURLWithPath: entry.scanRootPath))
        }
        var uniqueRoots: [URL] = []
        var seenRoots = Set<String>()
        for r in rootDirs {
            let p = r.standardizedFileURL.path
            if seenRoots.insert(p).inserted, fm.fileExists(atPath: p) {
                uniqueRoots.append(r.standardizedFileURL)
            }
        }

        // Depth-2 scan catches links moved into subfolders such as /Applications/GDRIVE/
        for root in uniqueRoots {
            guard let topChildren = try? fm.contentsOfDirectory(
                at: root,
                includingPropertiesForKeys: [.isDirectoryKey, .isPackageKey, .isSymbolicLinkKey, .isAliasFileKey],
                options: [.skipsHiddenFiles]
            ) else { continue }

            for child in topChildren {
                considerLink(at: child)
                if let vals = try? child.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey, .isSymbolicLinkKey]),
                   vals.isDirectory == true,
                   vals.isPackage != true,
                   vals.isSymbolicLink != true,
                   let nested = try? fm.contentsOfDirectory(
                       at: child,
                       includingPropertiesForKeys: [.isSymbolicLinkKey, .isAliasFileKey],
                       options: [.skipsHiddenFiles]
                   ) {
                    for sub in nested {
                        considerLink(at: sub)
                    }
                }
            }
        }

        return targets
    }

    // MARK: - Local Cloud Cache Eviction

    private struct LocalCacheTree: Sendable {
        let rootPath: String
        let beforeAllocatedBytes: Int64
        let totalEvictableFiles: Int
        let totalEvictableBytes: Int64
        let pendingDirs: Set<String>
        let evictableDirs: Set<String>
        let dirEvictableBytes: [String: Int64]
        let childDirs: [String: [String]]
        let evictableFilesByParent: [String: [(url: URL, bytes: Int64)]]
        let hasPendingUpload: Bool
    }

    private struct CacheEvictionTarget: Sendable {
        let name: String
        let url: URL
        let isDirectoryOrPackage: Bool
        let estimatedBytes: Int64
    }

    private final class EvictionProgressCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var completedBytes: Int64 = 0
        private var completedOps: Int = 0
        private let totalBytes: Int64
        private var lastReportedOps: Int = -1

        init(totalBytes: Int64) {
            self.totalBytes = max(1, totalBytes)
        }

        func advance(bytes: Int64, ops: Int = 1) -> (fraction: Double, ops: Int)? {
            lock.lock()
            completedBytes += max(0, bytes)
            completedOps += ops
            let shouldReport = (completedOps - lastReportedOps >= 8) || completedBytes >= totalBytes
            if shouldReport {
                lastReportedOps = completedOps
            }
            let frac = min(0.98, Double(completedBytes) / Double(totalBytes))
            let opsSnapshot = completedOps
            lock.unlock()
            return shouldReport ? (frac, opsSnapshot) : nil
        }
    }

    private final class ResumeOnceGate: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<Void, Error>?

        init(_ continuation: CheckedContinuation<Void, Error>) {
            self.continuation = continuation
        }

        func resume(throwing error: Error? = nil) {
            lock.lock()
            let cont = continuation
            continuation = nil
            lock.unlock()
            guard let cont else { return }
            if let error {
                cont.resume(throwing: error)
            } else {
                cont.resume()
            }
        }
    }

    private final class LockedGateBox: @unchecked Sendable {
        private let lock = NSLock()
        private var gate: ResumeOnceGate?
        private var cancelledError: Error?

        func set(_ gate: ResumeOnceGate) {
            lock.lock()
            let err = cancelledError
            if err == nil {
                self.gate = gate
            }
            lock.unlock()
            if let err {
                gate.resume(throwing: err)
            }
        }

        func cancel(throwing error: Error) {
            lock.lock()
            cancelledError = error
            let current = gate
            gate = nil
            lock.unlock()
            current?.resume(throwing: error)
        }
    }

    func evictLocalCache(
        entries: [ManifestEntry],
        driveRoot: URL?,
        includeAllInArchiveRoot: Bool,
        onProgress: @escaping @Sendable (OperationProgress) -> Void
    ) async throws -> OperationSummary {
        let targets = Self.collectCacheTargets(
            entries: entries,
            driveRoot: driveRoot,
            includeAllInArchiveRoot: includeAllInArchiveRoot
        )
        let targetWeights = targets.map { max(Int64(10_485_760), $0.estimatedBytes) }
        let totalWeightBytes = targetWeights.reduce(Int64(0), +)
        var completedWeightBytes: Int64 = 0
        var processedCount = 0
        var succeeded = 0
        var failed = 0
        var freedBytes: Int64 = 0
        var skippedPendingCount = 0
        var errors: [String] = []

        for (index, target) in targets.enumerated() {
            if Task.isCancelled {
                throw EngineError.cancelled
            }

            let weight = targetWeights[index]
            let currentFreed = freedBytes
            let baseWeight = completedWeightBytes
            let totalTargets = max(1, targets.count)
            let itemIndex = processedCount

            onProgress(OperationProgress(
                phase: "Evicting local cache (\(ByteFormatting.string(from: currentFreed)) freed)…",
                processedItems: itemIndex,
                totalItems: totalTargets,
                processedBytes: baseWeight,
                totalBytes: totalWeightBytes,
                currentSubpath: "Scanning \(target.name)…"
            ))

            do {
                let result = try await Self.evictTargetCache(target) { subFraction, detail in
                    let partialWeight = baseWeight + Int64(Double(weight) * subFraction)
                    onProgress(OperationProgress(
                        phase: "Evicting local cache (\(ByteFormatting.string(from: currentFreed)) freed)…",
                        processedItems: itemIndex,
                        totalItems: totalTargets,
                        processedBytes: partialWeight,
                        totalBytes: totalWeightBytes,
                        currentSubpath: "\(target.name) · \(detail)"
                    ))
                }
                freedBytes += result.freedBytes
                if result.hadPendingUploads {
                    skippedPendingCount += 1
                }
                succeeded += 1
            } catch is CancellationError {
                throw EngineError.cancelled
            } catch {
                failed += 1
                errors.append("\(target.name): \(error.localizedDescription)")
            }

            processedCount += 1
            completedWeightBytes += weight
            onProgress(OperationProgress(
                phase: "Evicting local cache (\(ByteFormatting.string(from: freedBytes)) freed)…",
                processedItems: processedCount,
                totalItems: totalTargets,
                processedBytes: completedWeightBytes,
                totalBytes: totalWeightBytes,
                currentSubpath: target.name
            ))
        }

        if skippedPendingCount > 0 {
            errors.append("\(skippedPendingCount) item(s) had files still uploading and were kept safely.")
        }

        return OperationSummary(
            succeededCount: succeeded,
            failedCount: failed,
            bytesAffected: freedBytes,
            dryRun: false,
            errors: errors
        )
    }

    private static func evictTargetCache(
        _ target: CacheEvictionTarget,
        onSubProgress: @escaping @Sendable (Double, String) -> Void
    ) async throws -> (freedBytes: Int64, hadPendingUploads: Bool) {
        let tree = inspectLocalCacheTree(at: target.url, isDirectoryOrPackage: target.isDirectoryOrPackage)
        guard tree.totalEvictableFiles > 0 else {
            return (0, tree.hasPendingUpload)
        }

        let counter = EvictionProgressCounter(totalBytes: tree.totalEvictableBytes)
        if !target.isDirectoryOrPackage {
            if let fileURL = tree.evictableFilesByParent[tree.rootPath]?.first?.url {
                try await evictItemWithTimeout(at: fileURL, timeoutSeconds: 15)
            }
        } else {
            _ = try await evictDirectoryNode(
                dirPath: tree.rootPath,
                tree: tree,
                counter: counter,
                onSubProgress: onSubProgress
            )
        }

        let afterAllocated = measureAllocatedBytes(at: target.url, isDirectoryOrPackage: target.isDirectoryOrPackage)
        let freed = max(0, tree.beforeAllocatedBytes - afterAllocated)
        return (freed, tree.hasPendingUpload)
    }

    @discardableResult
    private static func evictDirectoryNode(
        dirPath: String,
        tree: LocalCacheTree,
        counter: EvictionProgressCounter,
        onSubProgress: @escaping @Sendable (Double, String) -> Void
    ) async throws -> Error? {
        try Task.checkCancellation()
        guard tree.evictableDirs.contains(dirPath) else { return nil }

        let dirURL = URL(fileURLWithPath: dirPath)
        if !tree.pendingDirs.contains(dirPath) {
            do {
                try await evictItemWithTimeout(at: dirURL, timeoutSeconds: 25)
                let bytes = tree.dirEvictableBytes[dirPath] ?? 0
                if let step = counter.advance(bytes: bytes) {
                    onSubProgress(step.fraction, dirURL.lastPathComponent)
                }
                return nil
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                // Fall back to child directories/files if root or intermediate directory call failed or timed out
            }
        }

        let children = tree.childDirs[dirPath] ?? []
        let childStats = try await runBounded(children, maxConcurrent: 4) { childPath in
            try await evictDirectoryNode(
                dirPath: childPath,
                tree: tree,
                counter: counter,
                onSubProgress: onSubProgress
            )
        }

        let looseFiles = tree.evictableFilesByParent[dirPath] ?? []
        let fileStats = try await runBounded(looseFiles, maxConcurrent: 6) { entry in
            do {
                try await evictItemWithTimeout(at: entry.url, timeoutSeconds: 12)
                if let step = counter.advance(bytes: entry.bytes) {
                    onSubProgress(step.fraction, "\(step.ops) ops")
                }
                return nil
            } catch is CancellationError {
                throw EngineError.cancelled
            } catch {
                return error
            }
        }

        return childStats.firstError ?? fileStats.firstError
    }

    @discardableResult
    private static func runBounded<T: Sendable>(
        _ items: [T],
        maxConcurrent: Int,
        operation: @escaping @Sendable (T) async throws -> Error?
    ) async throws -> (succeeded: Int, firstError: Error?) {
        guard !items.isEmpty else { return (0, nil) }
        return try await withThrowingTaskGroup(of: Error?.self) { group in
            defer { group.cancelAll() }
            var iterator = items.makeIterator()
            var inFlight = 0
            var succeeded = 0
            var firstError: Error?

            while inFlight < maxConcurrent, let next = iterator.next() {
                try Task.checkCancellation()
                group.addTask { try await operation(next) }
                inFlight += 1
            }

            while let err = try await group.next() {
                inFlight -= 1
                if let err {
                    if firstError == nil { firstError = err }
                } else {
                    succeeded += 1
                }
                try Task.checkCancellation()
                if let next = iterator.next() {
                    group.addTask { try await operation(next) }
                    inFlight += 1
                }
            }
            return (succeeded, firstError)
        }
    }

    private static func evictItemWithTimeout(at url: URL, timeoutSeconds: Double) async throws {
        try Task.checkCancellation()
        let box = LockedGateBox()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { cont in
                let gate = ResumeOnceGate(cont)
                box.set(gate)

                DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeoutSeconds) {
                    gate.resume(throwing: EngineError.verificationFailed("Timed out evicting \(url.lastPathComponent)"))
                }

                DispatchQueue.global(qos: .utility).async {
                    do {
                        try FileManager.default.evictUbiquitousItem(at: url)
                        gate.resume()
                    } catch {
                        gate.resume(throwing: error)
                    }
                }
            }
        } onCancel: {
            box.cancel(throwing: CancellationError())
        }
    }

    private static func collectCacheTargets(
        entries: [ManifestEntry],
        driveRoot: URL?,
        includeAllInArchiveRoot: Bool
    ) -> [CacheEvictionTarget] {
        let fm = FileManager.default
        var seenPaths = Set<String>()
        var targets: [CacheEvictionTarget] = []

        for entry in entries {
            let url = URL(fileURLWithPath: entry.driveArchivePath)
            let stdPath = url.standardizedFileURL.path
            guard fm.fileExists(atPath: stdPath), !seenPaths.contains(stdPath) else { continue }
            seenPaths.insert(stdPath)
            targets.append(CacheEvictionTarget(
                name: entry.itemName,
                url: url,
                isDirectoryOrPackage: entry.isApplicationBundle || directoryExists(atPath: stdPath),
                estimatedBytes: entry.sizeBytes
            ))
        }

        if includeAllInArchiveRoot, let driveRoot {
            let archiveRoot = driveRoot.appendingPathComponent(archiveFolderName, isDirectory: true)
            if fm.fileExists(atPath: archiveRoot.path) {
                let entryPaths = Set(targets.map { $0.url.standardizedFileURL.path })
                appendArchiveChildren(
                    under: archiveRoot,
                    knownEntryPaths: entryPaths,
                    seenPaths: &seenPaths,
                    into: &targets
                )
            }
        }

        return targets
    }

    private static func appendArchiveChildren(
        under directory: URL,
        knownEntryPaths: Set<String>,
        seenPaths: inout Set<String>,
        into targets: inout [CacheEvictionTarget]
    ) {
        let keys: [URLResourceKey] = [.isDirectoryKey, .isPackageKey, .isSymbolicLinkKey, .fileSizeKey]
        guard let children = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles]
        ) else {
            return
        }

        for child in children {
            guard let vals = try? child.resourceValues(forKeys: Set(keys)),
                  vals.isSymbolicLink != true else {
                continue
            }
            let stdPath = child.standardizedFileURL.path
            if seenPaths.contains(stdPath) { continue }

            let isDir = vals.isDirectory == true
            let isPkg = vals.isPackage == true
            if isDir && !isPkg && knownEntryPaths.contains(where: { $0.hasPrefix(stdPath + "/") }) {
                appendArchiveChildren(under: child, knownEntryPaths: knownEntryPaths, seenPaths: &seenPaths, into: &targets)
                continue
            }

            if isDir && !isPkg && child.deletingLastPathComponent().lastPathComponent == archiveFolderName {
                // Scan-root level folder (e.g., DriveOffloader_Archive/Applications) — expand one level into items inside it
                appendArchiveChildren(under: child, knownEntryPaths: knownEntryPaths, seenPaths: &seenPaths, into: &targets)
                continue
            }

            seenPaths.insert(stdPath)
            targets.append(CacheEvictionTarget(
                name: child.lastPathComponent,
                url: child,
                isDirectoryOrPackage: isDir || isPkg,
                estimatedBytes: Int64(vals.fileSize ?? 0)
            ))
        }
    }

    private static func directoryExists(atPath path: String) -> Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDir) && isDir.boolValue
    }

    private static func markAncestors(
        from startDirPath: String,
        rootPath: String,
        into set: inout Set<String>
    ) {
        var current = URL(fileURLWithPath: startDirPath).standardizedFileURL.path
        while true {
            if !set.insert(current).inserted { break }
            if current == rootPath { break }
            let parent = URL(fileURLWithPath: current).deletingLastPathComponent().standardizedFileURL.path
            if parent == current || parent.count < rootPath.count { break }
            current = parent
        }
    }

    private static func inspectLocalCacheTree(at url: URL, isDirectoryOrPackage: Bool) -> LocalCacheTree {
        let fm = FileManager.default
        let rootPath = url.standardizedFileURL.path
        guard fm.fileExists(atPath: rootPath) else {
            return LocalCacheTree(
                rootPath: rootPath,
                beforeAllocatedBytes: 0,
                totalEvictableFiles: 0,
                totalEvictableBytes: 0,
                pendingDirs: [],
                evictableDirs: [],
                dirEvictableBytes: [:],
                childDirs: [:],
                evictableFilesByParent: [:],
                hasPendingUpload: false
            )
        }

        let keys: Set<URLResourceKey> = [
            .isRegularFileKey,
            .isDirectoryKey,
            .isSymbolicLinkKey,
            .totalFileAllocatedSizeKey,
            .isUbiquitousItemKey,
            .ubiquitousItemIsUploadedKey,
            .ubiquitousItemIsUploadingKey,
            .ubiquitousItemDownloadingStatusKey
        ]

        if !isDirectoryOrPackage {
            var fileURL = URL(fileURLWithPath: rootPath)
            fileURL.removeAllCachedResourceValues()
            guard let vals = try? fileURL.resourceValues(forKeys: keys),
                  vals.isSymbolicLink != true else {
                return LocalCacheTree(
                    rootPath: rootPath,
                    beforeAllocatedBytes: 0,
                    totalEvictableFiles: 0,
                    totalEvictableBytes: 0,
                    pendingDirs: [],
                    evictableDirs: [],
                    dirEvictableBytes: [:],
                    childDirs: [:],
                    evictableFilesByParent: [:],
                    hasPendingUpload: false
                )
            }
            let alloc = Int64(vals.totalFileAllocatedSize ?? 0)
            guard vals.isUbiquitousItem == true else {
                return LocalCacheTree(
                    rootPath: rootPath,
                    beforeAllocatedBytes: alloc,
                    totalEvictableFiles: 0,
                    totalEvictableBytes: 0,
                    pendingDirs: [],
                    evictableDirs: [],
                    dirEvictableBytes: [:],
                    childDirs: [:],
                    evictableFilesByParent: [:],
                    hasPendingUpload: false
                )
            }
            let uploaded = vals.ubiquitousItemIsUploaded == true && vals.ubiquitousItemIsUploading != true
            if !uploaded {
                return LocalCacheTree(
                    rootPath: rootPath,
                    beforeAllocatedBytes: alloc,
                    totalEvictableFiles: 0,
                    totalEvictableBytes: 0,
                    pendingDirs: [],
                    evictableDirs: [],
                    dirEvictableBytes: [:],
                    childDirs: [:],
                    evictableFilesByParent: [:],
                    hasPendingUpload: true
                )
            }
            let isCached = vals.ubiquitousItemDownloadingStatus != .notDownloaded
            return LocalCacheTree(
                rootPath: rootPath,
                beforeAllocatedBytes: alloc,
                totalEvictableFiles: isCached ? 1 : 0,
                totalEvictableBytes: isCached ? alloc : 0,
                pendingDirs: [],
                evictableDirs: [],
                dirEvictableBytes: [:],
                childDirs: [:],
                evictableFilesByParent: isCached ? [rootPath: [(fileURL, alloc)]] : [:],
                hasPendingUpload: false
            )
        }

        guard let enumerator = fm.enumerator(
            at: URL(fileURLWithPath: rootPath),
            includingPropertiesForKeys: Array(keys),
            options: [],
            errorHandler: { _, _ in true }
        ) else {
            return LocalCacheTree(
                rootPath: rootPath,
                beforeAllocatedBytes: 0,
                totalEvictableFiles: 0,
                totalEvictableBytes: 0,
                pendingDirs: [],
                evictableDirs: [],
                dirEvictableBytes: [:],
                childDirs: [:],
                evictableFilesByParent: [:],
                hasPendingUpload: false
            )
        }

        var beforeAlloc: Int64 = 0
        var totalEvictableFiles = 0
        var totalEvictableBytes: Int64 = 0
        var pendingDirs = Set<String>()
        var evictableDirs = Set<String>()
        var dirEvictableBytes: [String: Int64] = [:]
        var childDirs: [String: [String]] = [:]
        var evictableFilesByParent: [String: [(url: URL, bytes: Int64)]] = [:]
        var hasPendingUpload = false

        while let rawItem = enumerator.nextObject() as? URL {
            if Task.isCancelled { break }
            if isIgnoredCloudMetadataFile(rawItem) { continue }
            var itemURL = URL(fileURLWithPath: rawItem.path)
            itemURL.removeAllCachedResourceValues()
            guard let vals = try? itemURL.resourceValues(forKeys: keys),
                  vals.isSymbolicLink != true else {
                continue
            }

            let stdPath = itemURL.standardizedFileURL.path
            let parentPath = itemURL.deletingLastPathComponent().standardizedFileURL.path

            if vals.isDirectory == true {
                childDirs[parentPath, default: []].append(stdPath)
                continue
            }

            guard vals.isRegularFile == true else { continue }
            let alloc = Int64(vals.totalFileAllocatedSize ?? 0)
            beforeAlloc += alloc
            guard vals.isUbiquitousItem == true else { continue }

            if vals.ubiquitousItemIsUploaded == true && vals.ubiquitousItemIsUploading != true {
                if vals.ubiquitousItemDownloadingStatus != .notDownloaded {
                    totalEvictableFiles += 1
                    totalEvictableBytes += alloc
                    evictableFilesByParent[parentPath, default: []].append((itemURL, alloc))
                    markAncestors(from: parentPath, rootPath: rootPath, into: &evictableDirs)
                    var cur = parentPath
                    while true {
                        dirEvictableBytes[cur, default: 0] += alloc
                        if cur == rootPath { break }
                        let p = URL(fileURLWithPath: cur).deletingLastPathComponent().standardizedFileURL.path
                        if p == cur || p.count < rootPath.count { break }
                        cur = p
                    }
                }
            } else {
                hasPendingUpload = true
                markAncestors(from: parentPath, rootPath: rootPath, into: &pendingDirs)
            }
        }

        return LocalCacheTree(
            rootPath: rootPath,
            beforeAllocatedBytes: beforeAlloc,
            totalEvictableFiles: totalEvictableFiles,
            totalEvictableBytes: totalEvictableBytes,
            pendingDirs: pendingDirs,
            evictableDirs: evictableDirs,
            dirEvictableBytes: dirEvictableBytes,
            childDirs: childDirs,
            evictableFilesByParent: evictableFilesByParent,
            hasPendingUpload: hasPendingUpload
        )
    }

    private static func measureAllocatedBytes(at url: URL, isDirectoryOrPackage: Bool) -> Int64 {
        let fm = FileManager.default
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .isSymbolicLinkKey, .totalFileAllocatedSizeKey]
        if !isDirectoryOrPackage {
            var fileURL = URL(fileURLWithPath: url.path)
            fileURL.removeAllCachedResourceValues()
            guard let vals = try? fileURL.resourceValues(forKeys: keys), vals.isSymbolicLink != true else { return 0 }
            return Int64(vals.totalFileAllocatedSize ?? 0)
        }
        guard let enumerator = fm.enumerator(
            at: url,
            includingPropertiesForKeys: Array(keys),
            options: [],
            errorHandler: { _, _ in true }
        ) else {
            return 0
        }
        var total: Int64 = 0
        while let rawFile = enumerator.nextObject() as? URL {
            if Task.isCancelled { break }
            if isIgnoredCloudMetadataFile(rawFile) { continue }
            var fileURL = URL(fileURLWithPath: rawFile.path)
            fileURL.removeAllCachedResourceValues()
            guard let vals = try? fileURL.resourceValues(forKeys: keys),
                  vals.isRegularFile == true,
                  vals.isSymbolicLink != true else {
                continue
            }
            total += Int64(vals.totalFileAllocatedSize ?? 0)
        }
        return total
    }

    // MARK: - Manifest & Restore

    nonisolated static func loadManifestSync() -> [ManifestEntry] {
        guard let data = try? Data(contentsOf: manifestURL) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([ManifestEntry].self, from: data)) ?? []
    }

    func loadManifest() -> [ManifestEntry] {
        Self.loadManifestSync()
    }

    private func saveManifest(_ entries: [ManifestEntry]) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(entries)
        try data.write(to: Self.manifestURL, options: [.atomic])
    }

    func restore(
        entries: [ManifestEntry],
        onProgress: @Sendable (OperationProgress) -> Void
    ) async throws -> OperationSummary {
        let totalBytes = entries.reduce(Int64(0)) { $0 + $1.sizeBytes }
        var processedBytes: Int64 = 0
        var processedCount = 0
        var succeeded = 0
        var failed = 0
        var restoredBytes: Int64 = 0
        var errors: [String] = []
        var manifest = loadManifest()
        let fm = FileManager.default
        var pendingPrivileged: [PendingPrivilegedRestore] = []

        for entry in entries {
            if Task.isCancelled {
                for p in pendingPrivileged {
                    try? fm.removeItem(at: p.tempRestoreURL)
                }
                throw EngineError.cancelled
            }

            let sourceArchiveURL = URL(fileURLWithPath: entry.driveArchivePath)
            let originalURL = URL(fileURLWithPath: entry.originalPath)

            onProgress(OperationProgress(
                phase: "Restoring from Google Drive…",
                processedItems: processedCount,
                totalItems: entries.count,
                processedBytes: processedBytes,
                totalBytes: totalBytes,
                currentSubpath: originalURL.lastPathComponent
            ))

            do {
                guard fm.fileExists(atPath: sourceArchiveURL.path) else {
                    throw EngineError.verificationFailed("Archive item not found at \(sourceArchiveURL.path)")
                }

                let parentDir = originalURL.deletingLastPathComponent()
                try? fm.createDirectory(at: parentDir, withIntermediateDirectories: true)

                let tempRestoreURL = fm.temporaryDirectory
                    .appendingPathComponent("DriveOffloaderRestore_\(UUID().uuidString)_\(originalURL.lastPathComponent)")

                try fm.copyItem(at: sourceArchiveURL, to: tempRestoreURL)
                if entry.isApplicationBundle {
                    Self.preserveBundleExecutablePermissions(at: tempRestoreURL)
                }

                let cmdStubURL = URL(fileURLWithPath: originalURL.path + ".driveoffloader.command")
                do {
                    if fm.fileExists(atPath: originalURL.path) || Self.symlinkExists(atPath: originalURL.path) {
                        try fm.removeItem(at: originalURL)
                    }
                    if fm.fileExists(atPath: cmdStubURL.path) {
                        try? fm.removeItem(at: cmdStubURL)
                    }
                    try fm.moveItem(at: tempRestoreURL, to: originalURL)

                    guard fm.fileExists(atPath: originalURL.path) else {
                        throw EngineError.verificationFailed("Restored item missing at \(originalURL.path)")
                    }

                    try? fm.removeItem(at: sourceArchiveURL)
                    manifest.removeAll { $0.id == entry.id }
                    try saveManifest(manifest)

                    succeeded += 1
                    restoredBytes += entry.sizeBytes
                } catch let error as NSError where Self.isPermissionError(error) {
                    let cmd = "rm -rf \(Self.shellEscaped(originalURL.path)) \(Self.shellEscaped(cmdStubURL.path)) && ditto \(Self.shellEscaped(tempRestoreURL.path)) \(Self.shellEscaped(originalURL.path))"
                    pendingPrivileged.append(PendingPrivilegedRestore(
                        entry: entry,
                        sourceArchiveURL: sourceArchiveURL,
                        originalURL: originalURL,
                        tempRestoreURL: tempRestoreURL,
                        shellCommand: cmd
                    ))
                } catch {
                    try? fm.removeItem(at: tempRestoreURL)
                    throw error
                }
            } catch {
                failed += 1
                errors.append("\(entry.itemName): \(error.localizedDescription)")
            }

            processedCount += 1
            processedBytes += entry.sizeBytes

            onProgress(OperationProgress(
                phase: "Restoring from Google Drive…",
                processedItems: processedCount,
                totalItems: entries.count,
                processedBytes: processedBytes,
                totalBytes: totalBytes,
                currentSubpath: originalURL.lastPathComponent
            ))
        }

        if !pendingPrivileged.isEmpty {
            defer {
                for p in pendingPrivileged {
                    try? fm.removeItem(at: p.tempRestoreURL)
                }
            }
            onProgress(OperationProgress(
                phase: "Authorizing restore for \(pendingPrivileged.count) protected item(s)…",
                processedItems: processedCount,
                totalItems: entries.count,
                processedBytes: processedBytes,
                totalBytes: totalBytes,
                currentSubpath: ""
            ))
            do {
                try await Self.runPrivilegedBatchScript(pendingPrivileged.map(\.shellCommand))
                for p in pendingPrivileged {
                    guard fm.fileExists(atPath: p.originalURL.path) else {
                        failed += 1
                        errors.append("\(p.entry.itemName): Restored item missing at \(p.originalURL.path)")
                        continue
                    }
                    try? fm.removeItem(at: p.sourceArchiveURL)
                    manifest.removeAll { $0.id == p.entry.id }
                    succeeded += 1
                    restoredBytes += p.entry.sizeBytes
                }
                try saveManifest(manifest)
            } catch {
                failed += pendingPrivileged.count
                errors.append("Administrator authorization failed: \(error.localizedDescription)")
            }
        }

        return OperationSummary(
            succeededCount: succeeded,
            failedCount: failed,
            bytesAffected: restoredBytes,
            dryRun: false,
            errors: errors
        )
    }

    // MARK: - Permissions & Shell Utilities

    private static func preserveBundleExecutablePermissions(at bundleURL: URL) {
        let macOSDir = bundleURL.appendingPathComponent("Contents/MacOS", isDirectory: true)
        guard let binaries = try? FileManager.default.contentsOfDirectory(
            at: macOSDir,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: []
        ) else {
            return
        }
        for bin in binaries {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: bin.path)
        }
    }

    private static func symlinkExists(atPath path: String) -> Bool {
        (try? FileManager.default.attributesOfItem(atPath: path)) != nil
    }

    static func isPermissionError(_ error: NSError) -> Bool {
        if error.domain == NSCocoaErrorDomain && (error.code == NSFileWriteNoPermissionError || error.code == NSFileReadNoPermissionError) {
            return true
        }
        if error.domain == NSPOSIXErrorDomain && (error.code == Int(EACCES) || error.code == Int(EPERM)) {
            return true
        }
        if let underlying = error.userInfo[NSUnderlyingErrorKey] as? NSError {
            return isPermissionError(underlying)
        }
        return false
    }

    static func shellEscaped(_ path: String) -> String {
        "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    @MainActor
    static func runPrivilegedBatchScript(_ commands: [String]) throws {
        guard !commands.isEmpty else { return }
        let scriptURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("DriveOffloaderBatch_\(UUID().uuidString).sh")
        let body = "#!/bin/bash\nset -e\n" + commands.joined(separator: "\n") + "\n"
        try body.write(to: scriptURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: scriptURL.path)
        defer { try? FileManager.default.removeItem(at: scriptURL) }

        let escapedScript = scriptURL.path
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let source = "do shell script \"/bin/bash \\\"\(escapedScript)\\\"\" with administrator privileges"
        guard let script = NSAppleScript(source: source) else {
            throw EngineError.privilegedOperationFailed("Could not construct administrator prompt.")
        }
        var errorInfo: NSDictionary?
        script.executeAndReturnError(&errorInfo)
        if let err = errorInfo {
            let message = (err[NSAppleScript.errorMessage] as? String) ?? "Administrator privileges denied or failed."
            throw EngineError.privilegedOperationFailed(message)
        }
    }
}
