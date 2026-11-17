import AppKit
import CryptoKit
import Darwin
import Foundation
import SwiftUI

enum DuplicateMinSize: Int64, CaseIterable, Identifiable {
    case kb100 = 102_400
    case mb1 = 1_048_576
    case mb10 = 10_485_760
    case mb50 = 52_428_800
    case mb100 = 104_857_600

    var id: Int64 { rawValue }

    var label: String {
        switch self {
        case .kb100: return "≥ 100 KB"
        case .mb1: return "≥ 1 MB"
        case .mb10: return "≥ 10 MB"
        case .mb50: return "≥ 50 MB"
        case .mb100: return "≥ 100 MB"
        }
    }
}

enum DuplicateKeepStrategy {
    case oldest
    case newest
    case shortestPath
}

struct DuplicateFileEntry: Identifiable, Hashable, Sendable {
    let id: String
    let path: String
    let url: URL
    let name: String
    let parentPath: String
    let allocatedBytes: Int64
    let logicalBytes: Int64
    let modifiedDate: Date
    let createdDate: Date?
}

struct DuplicateGroup: Identifiable, Hashable, Sendable {
    let id: String
    let sha256: String
    let fileSizeBytes: Int64
    let allocatedPerCopyBytes: Int64
    let files: [DuplicateFileEntry]

    var wastedBytes: Int64 {
        Int64(max(0, files.count - 1)) * allocatedPerCopyBytes
    }

    var shortHash: String {
        String(sha256.prefix(12))
    }

    var primaryName: String {
        files.first?.name ?? "Duplicate Group"
    }
}

private struct DuplicateCandidateFile: Sendable {
    let url: URL
    let path: String
    let name: String
    let parentPath: String
    let allocatedBytes: Int64
    let logicalBytes: Int64
    let modifiedDate: Date
    let createdDate: Date?
    let inodeKey: String
}

actor DuplicatesEngine {
    func scanDuplicates(
        roots: [URL],
        minSizeBytes: Int64,
        skipPackagesAndSystem: Bool,
        onProgress: @Sendable (OperationProgress) -> Void
    ) async throws -> [DuplicateGroup] {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser.resolvingSymlinksInPath().path
        let protected = StorageUtilities.protectedSystemRoots()

        let keys: [URLResourceKey] = [
            .totalFileAllocatedSizeKey,
            .fileSizeKey,
            .isRegularFileKey,
            .isPackageKey,
            .isSymbolicLinkKey,
            .isAliasFileKey,
            .contentModificationDateKey,
            .creationDateKey
        ]

        onProgress(
            OperationProgress(
                phase: "Stage 1/3: Grouping files by exact byte size…",
                processedItems: 0,
                totalItems: max(1, roots.count),
                processedBytes: 0,
                totalBytes: 1,
                currentSubpath: ""
            )
        )

        var seenPaths = Set<String>()
        var sizeBuckets: [Int64: [DuplicateCandidateFile]] = [:]
        var scannedFiles = 0

        let options: FileManager.DirectoryEnumerationOptions = skipPackagesAndSystem ? [.skipsPackageDescendants] : []

        for root in roots {
            try Task.checkCancellation()
            guard fm.fileExists(atPath: root.path) else { continue }

            guard let enumerator = fm.enumerator(
                at: root,
                includingPropertiesForKeys: keys,
                options: options,
                errorHandler: { _, _ in true }
            ) else {
                continue
            }

            while let next = enumerator.nextObject() as? URL {
                try Task.checkCancellation()
                let path = next.path
                if StorageUtilities.isProtectedCloudPath(path) {
                    enumerator.skipDescendants()
                    continue
                }

                let name = next.lastPathComponent
                if name == ".Trash" || name == ".git" || name == "node_modules" || name == ".build" {
                    enumerator.skipDescendants()
                    continue
                }

                if skipPackagesAndSystem && (path == "\(home)/Library" || path.hasPrefix("\(home)/Library/")) {
                    enumerator.skipDescendants()
                    continue
                }

                guard let values = try? next.resourceValues(forKeys: Set(keys)) else { continue }
                if values.isSymbolicLink == true || values.isAliasFile == true {
                    enumerator.skipDescendants()
                    continue
                }
                if skipPackagesAndSystem && values.isPackage == true {
                    enumerator.skipDescendants()
                    continue
                }

                guard values.isRegularFile == true else { continue }

                let alloc = Int64(values.totalFileAllocatedSize ?? 0)
                let logical = Int64(values.fileSize ?? 0)
                // Require non-zero allocated disk usage so dataless cloud placeholders are never opened for hashing
                guard logical >= minSizeBytes, alloc > 0 else { continue }

                let resolved = next.resolvingSymlinksInPath().path
                guard !protected.contains(resolved), seenPaths.insert(resolved).inserted else { continue }

                let inodeKey = Self.inodeIdentifier(forPath: path) ?? path
                let candidate = DuplicateCandidateFile(
                    url: next,
                    path: path,
                    name: name,
                    parentPath: Self.friendlyParent(of: next, home: home),
                    allocatedBytes: alloc,
                    logicalBytes: logical,
                    modifiedDate: values.contentModificationDate ?? .distantPast,
                    createdDate: values.creationDate,
                    inodeKey: inodeKey
                )
                sizeBuckets[logical, default: []].append(candidate)

                scannedFiles += 1
                if scannedFiles % 1500 == 0 {
                    onProgress(
                        OperationProgress(
                            phase: "Stage 1/3: Indexing \(scannedFiles) file(s)…",
                            processedItems: scannedFiles,
                            totalItems: scannedFiles + 1000,
                            processedBytes: 0,
                            totalBytes: 1,
                            currentSubpath: name
                        )
                    )
                }
            }
        }

        // Filter out buckets without >=2 distinct inodes (skipping pure APFS/POSIX hardlinks)
        var preHashCandidates: [DuplicateCandidateFile] = []
        for (_, bucket) in sizeBuckets where bucket.count >= 2 {
            var uniqueByInode: [String: DuplicateCandidateFile] = [:]
            for file in bucket where uniqueByInode[file.inodeKey] == nil {
                uniqueByInode[file.inodeKey] = file
            }
            if uniqueByInode.count >= 2 {
                preHashCandidates.append(contentsOf: uniqueByInode.values)
            }
        }

        guard !preHashCandidates.isEmpty else { return [] }

        // Stage 2: Partial pre-hash (Head + Mid + Tail 4 KB slices)
        var partialBuckets: [String: [DuplicateCandidateFile]] = [:]
        let totalPre = preHashCandidates.count
        var donePre = 0
        var idxPre = 0
        let maxWorkers = 6

        try await withThrowingTaskGroup(of: (DuplicateCandidateFile, String?)?.self) { group in
            let initial = min(maxWorkers, totalPre)
            for _ in 0..<initial {
                let c = preHashCandidates[idxPre]
                idxPre += 1
                group.addTask {
                    try Task.checkCancellation()
                    let hash = Self.partialHashHex(for: c)
                    return (c, hash)
                }
            }

            while let result = try await group.next() {
                try Task.checkCancellation()
                donePre += 1
                if let (candidate, maybeHash) = result, let partial = maybeHash {
                    let key = "\(candidate.logicalBytes):\(partial)"
                    partialBuckets[key, default: []].append(candidate)
                }

                if donePre == totalPre || donePre % 12 == 0 {
                    onProgress(
                        OperationProgress(
                            phase: "Stage 2/3: Fast partial fingerprinting (\(donePre)/\(totalPre))…",
                            processedItems: donePre,
                            totalItems: max(1, totalPre),
                            processedBytes: Int64(donePre),
                            totalBytes: Int64(max(1, totalPre)),
                            currentSubpath: result?.0.name ?? ""
                        )
                    )
                }

                if idxPre < totalPre {
                    let c = preHashCandidates[idxPre]
                    idxPre += 1
                    group.addTask {
                        try Task.checkCancellation()
                        let hash = Self.partialHashHex(for: c)
                        return (c, hash)
                    }
                }
            }
        }

        let fullHashCandidates = partialBuckets.values.filter { $0.count >= 2 }.flatMap { $0 }
        guard !fullHashCandidates.isEmpty else { return [] }

        // Stage 3: Full streaming SHA-256 verification
        let totalFullBytes = max(1, fullHashCandidates.reduce(Int64(0)) { $0 + $1.logicalBytes })
        var processedFullBytes: Int64 = 0
        var fullBuckets: [String: [DuplicateCandidateFile]] = [:]
        var doneFull = 0
        var idxFull = 0

        try await withThrowingTaskGroup(of: (DuplicateCandidateFile, String?)?.self) { group in
            let initial = min(maxWorkers, fullHashCandidates.count)
            for _ in 0..<initial {
                let c = fullHashCandidates[idxFull]
                idxFull += 1
                group.addTask {
                    try Task.checkCancellation()
                    let hash = try Self.fullSHA256Hex(for: c)
                    return (c, hash)
                }
            }

            while let result = try await group.next() {
                try Task.checkCancellation()
                doneFull += 1
                if let (candidate, maybeHash) = result, let fullHash = maybeHash {
                    processedFullBytes += candidate.logicalBytes
                    fullBuckets[fullHash, default: []].append(candidate)
                }

                onProgress(
                    OperationProgress(
                        phase: "Stage 3/3: Full SHA-256 verification (\(doneFull)/\(fullHashCandidates.count))…",
                        processedItems: doneFull,
                        totalItems: max(1, fullHashCandidates.count),
                        processedBytes: processedFullBytes,
                        totalBytes: totalFullBytes,
                        currentSubpath: result?.0.name ?? ""
                    )
                )

                if idxFull < fullHashCandidates.count {
                    let c = fullHashCandidates[idxFull]
                    idxFull += 1
                    group.addTask {
                        try Task.checkCancellation()
                        let hash = try Self.fullSHA256Hex(for: c)
                        return (c, hash)
                    }
                }
            }
        }

        let groups: [DuplicateGroup] = fullBuckets.compactMap { hash, rawFiles in
            guard rawFiles.count >= 2 else { return nil }
            let entries = rawFiles
                .map {
                    DuplicateFileEntry(
                        id: $0.path,
                        path: $0.path,
                        url: $0.url,
                        name: $0.name,
                        parentPath: $0.parentPath,
                        allocatedBytes: $0.allocatedBytes,
                        logicalBytes: $0.logicalBytes,
                        modifiedDate: $0.modifiedDate,
                        createdDate: $0.createdDate
                    )
                }
                .sorted { lhs, rhs in
                    if lhs.modifiedDate != rhs.modifiedDate {
                        return lhs.modifiedDate < rhs.modifiedDate
                    }
                    return lhs.path.count < rhs.path.count
                }

            let perCopySize = entries.first?.logicalBytes ?? 0
            let allocPerCopy = entries.first?.allocatedBytes ?? perCopySize
            return DuplicateGroup(
                id: hash,
                sha256: hash,
                fileSizeBytes: perCopySize,
                allocatedPerCopyBytes: allocPerCopy,
                files: entries
            )
        }

        return groups.sorted { lhs, rhs in
            if lhs.wastedBytes != rhs.wastedBytes {
                return lhs.wastedBytes > rhs.wastedBytes
            }
            return lhs.primaryName.localizedCaseInsensitiveCompare(rhs.primaryName) == .orderedAscending
        }
    }

    // MARK: - Hashing & Inode Helpers

    private static func inodeIdentifier(forPath path: String) -> String? {
        var st = Darwin.stat()
        guard Darwin.lstat(path, &st) == 0 else { return nil }
        return "\(st.st_dev):\(st.st_ino)"
    }

    private static func partialHashHex(for candidate: DuplicateCandidateFile) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: candidate.url) else { return nil }
        defer { try? handle.close() }

        let sliceSize = 4096
        let size = candidate.logicalBytes
        var hasher = SHA256()

        do {
            if size <= Int64(sliceSize * 3) {
                while true {
                    let chunk = try handle.read(upToCount: 65_536) ?? Data()
                    if chunk.isEmpty { break }
                    hasher.update(data: chunk)
                }
            } else {
                let offsets: [UInt64] = [
                    0,
                    UInt64((size / 2) - Int64(sliceSize / 2)),
                    UInt64(size - Int64(sliceSize))
                ]
                for offset in offsets {
                    try handle.seek(toOffset: offset)
                    if let chunk = try handle.read(upToCount: sliceSize), !chunk.isEmpty {
                        hasher.update(data: chunk)
                    }
                }
            }
        } catch {
            return nil
        }

        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func fullSHA256Hex(for candidate: DuplicateCandidateFile) throws -> String? {
        guard let handle = try? FileHandle(forReadingFrom: candidate.url) else { return nil }
        defer { try? handle.close() }

        var hasher = SHA256()
        let chunkSize = 1_048_576
        while true {
            try Task.checkCancellation()
            let data = try handle.read(upToCount: chunkSize) ?? Data()
            if data.isEmpty { break }
            hasher.update(data: data)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func friendlyParent(of url: URL, home: String) -> String {
        let parent = url.deletingLastPathComponent().path
        if parent == home { return "~" }
        if parent.hasPrefix(home + "/") {
            return "~" + String(parent.dropFirst(home.count))
        }
        return parent
    }
}

// MARK: - ViewModel

@MainActor
final class DuplicatesViewModel: ObservableObject {
    @Published var scanRoots: [URL] = DuplicatesViewModel.defaultPersonalRoots()
    @Published private(set) var groups: [DuplicateGroup] = []
    @Published private(set) var visibleGroups: [DuplicateGroup] = []
    @Published var expandedGroupIDs: Set<String> = []
    @Published var selectedFileIDs: Set<String> = []

    @Published var minSize: DuplicateMinSize = .mb1
    @Published var skipPackagesAndLibrary: Bool = true
    @Published var moveToTrash: Bool = true
    @Published var searchQuery: String = "" { didSet { rebuildVisibleGroups() } }

    @Published var isBusy: Bool = false
    @Published var progress: OperationProgress? = nil
    @Published var statusBanner: String? = nil
    @Published var showDeleteConfirm: Bool = false

    private let engine = DuplicatesEngine()
    private var activeTask: Task<Void, Never>?

    static func defaultPersonalRoots() -> [URL] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let names = ["Documents", "Downloads", "Desktop", "Pictures", "Music", "Movies"]
        return names
            .map { home.appendingPathComponent($0, isDirectory: true) }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    var totalWastedBytes: Int64 {
        visibleGroups.reduce(0) { $0 + $1.wastedBytes }
    }

    var totalDuplicateCopiesCount: Int {
        visibleGroups.reduce(0) { $0 + max(0, $1.files.count - 1) }
    }

    var selectedFiles: [DuplicateFileEntry] {
        groups.flatMap(\.files).filter { selectedFileIDs.contains($0.id) }
    }

    var selectedBytes: Int64 {
        selectedFiles.reduce(0) { $0 + $1.allocatedBytes }
    }

    var allCopiesSelectedGroupCount: Int {
        groups.filter { group in
            !group.files.isEmpty && group.files.allSatisfy { selectedFileIDs.contains($0.id) }
        }.count
    }

    func addRootViaPanel() {
        let urls = StorageUtilities.chooseFolders(prompt: "Add Folder to Check")
        for url in urls where !scanRoots.contains(url) {
            scanRoots.append(url)
        }
    }

    func removeRoot(_ url: URL) {
        scanRoots.removeAll { $0 == url }
    }

    func setPersonalPresets() {
        scanRoots = Self.defaultPersonalRoots()
    }

    func setHomePreset() {
        scanRoots = [FileManager.default.homeDirectoryForCurrentUser]
    }

    func startScan() {
        guard !scanRoots.isEmpty else { return }
        cancelCurrentTask()
        isBusy = true
        statusBanner = nil
        selectedFileIDs.removeAll()
        progress = OperationProgress(
            phase: "Starting duplicate scan…",
            processedItems: 0,
            totalItems: max(1, scanRoots.count),
            processedBytes: 0,
            totalBytes: 1,
            currentSubpath: ""
        )

        let roots = scanRoots
        let minBytes = minSize.rawValue
        let skipSys = skipPackagesAndLibrary

        activeTask = Task { [weak self] in
            guard let self else { return }
            do {
                let foundGroups = try await engine.scanDuplicates(
                    roots: roots,
                    minSizeBytes: minBytes,
                    skipPackagesAndSystem: skipSys
                ) { [weak self] prog in
                    Task { @MainActor in
                        self?.progress = prog
                    }
                }
                self.groups = foundGroups
                self.expandedGroupIDs = Set(foundGroups.prefix(40).map(\.id))
                self.rebuildVisibleGroups()
                self.progress = nil
                if foundGroups.isEmpty {
                    self.statusBanner = "No duplicate files ≥ \(self.minSize.label) found."
                } else {
                    self.statusBanner = "Found \(foundGroups.count) duplicate group(s) wasting \(ByteFormatting.string(from: self.totalWastedBytes))."
                }
            } catch is CancellationError {
                self.progress = nil
                self.statusBanner = "Duplicate scan cancelled."
            } catch {
                self.progress = nil
                self.statusBanner = "Duplicate scan error: \(error.localizedDescription)"
            }
            self.isBusy = false
        }
    }

    func toggleExpanded(_ group: DuplicateGroup) {
        if expandedGroupIDs.contains(group.id) {
            expandedGroupIDs.remove(group.id)
        } else {
            expandedGroupIDs.insert(group.id)
        }
    }

    func expandAll() {
        expandedGroupIDs = Set(visibleGroups.map(\.id))
    }

    func collapseAll() {
        expandedGroupIDs.removeAll()
    }

    func toggleFileSelection(_ file: DuplicateFileEntry) {
        if selectedFileIDs.contains(file.id) {
            selectedFileIDs.remove(file.id)
        } else {
            selectedFileIDs.insert(file.id)
        }
    }

    func autoSelectDuplicates(keeping strategy: DuplicateKeepStrategy) {
        var nextSelected = selectedFileIDs
        for group in visibleGroups where group.files.count >= 2 {
            // Clear existing selections in this group before applying rule so every group keeps exactly 1 copy
            for file in group.files {
                nextSelected.remove(file.id)
            }

            let keeper: DuplicateFileEntry
            switch strategy {
            case .oldest:
                keeper = group.files.min(by: { lhs, rhs in
                    if lhs.modifiedDate != rhs.modifiedDate { return lhs.modifiedDate < rhs.modifiedDate }
                    return lhs.path.count < rhs.path.count
                }) ?? group.files[0]
            case .newest:
                keeper = group.files.max(by: { lhs, rhs in
                    if lhs.modifiedDate != rhs.modifiedDate { return lhs.modifiedDate < rhs.modifiedDate }
                    return lhs.path.count > rhs.path.count
                }) ?? group.files[0]
            case .shortestPath:
                keeper = group.files.min(by: { lhs, rhs in
                    if lhs.path.count != rhs.path.count { return lhs.path.count < rhs.path.count }
                    return lhs.modifiedDate < rhs.modifiedDate
                }) ?? group.files[0]
            }

            for file in group.files where file.id != keeper.id {
                nextSelected.insert(file.id)
            }
        }
        selectedFileIDs = nextSelected
    }

    func clearSelection() {
        selectedFileIDs.removeAll()
    }

    func revealInFinder(_ file: DuplicateFileEntry) {
        NSWorkspace.shared.activateFileViewerSelecting([file.url])
    }

    func deleteSelected() {
        let targets = selectedFiles
        guard !targets.isEmpty else { return }

        cancelCurrentTask()
        isBusy = true
        statusBanner = nil
        progress = OperationProgress(
            phase: moveToTrash ? "Moving duplicates to Trash…" : "Deleting duplicates…",
            processedItems: 0,
            totalItems: max(1, targets.count),
            processedBytes: 0,
            totalBytes: max(1, selectedBytes),
            currentSubpath: ""
        )

        let payload = targets.map { ($0.url, $0.name, $0.allocatedBytes) }
        let useTrash = moveToTrash
        activeTask = Task { [weak self] in
            guard let self else { return }
            do {
                let summary = try await StorageUtilities.deleteURLs(payload, moveToTrash: useTrash) { [weak self] prog in
                    Task { @MainActor in
                        self?.progress = prog
                    }
                }

                let deletedPaths = Set(targets.filter { !FileManager.default.fileExists(atPath: $0.path) }.map(\.id))
                self.groups = self.groups.compactMap { group in
                    let remaining = group.files.filter { !deletedPaths.contains($0.id) }
                    guard remaining.count >= 2 else { return nil }
                    return DuplicateGroup(
                        id: group.id,
                        sha256: group.sha256,
                        fileSizeBytes: group.fileSizeBytes,
                        allocatedPerCopyBytes: group.allocatedPerCopyBytes,
                        files: remaining
                    )
                }
                self.selectedFileIDs.subtract(deletedPaths)
                self.rebuildVisibleGroups()
                self.progress = nil

                var msg = "\(useTrash ? "Trashed" : "Deleted") \(summary.succeededCount) duplicate copy/copies, freeing \(ByteFormatting.string(from: summary.bytesAffected))."
                if summary.failedCount > 0 {
                    msg += " \(summary.failedCount) failed: \(summary.errors.first ?? "")"
                }
                self.statusBanner = msg
            } catch is CancellationError {
                self.progress = nil
                self.statusBanner = "Duplicate cleanup cancelled."
            } catch {
                self.progress = nil
                self.statusBanner = "Duplicate cleanup error: \(error.localizedDescription)"
            }
            self.isBusy = false
        }
    }

    func cancelCurrentTask() {
        activeTask?.cancel()
        activeTask = nil
    }

    private func rebuildVisibleGroups() {
        let q = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else {
            visibleGroups = groups
            return
        }
        visibleGroups = groups.filter { group in
            group.files.contains { file in
                file.name.lowercased().contains(q) || file.path.lowercased().contains(q)
            }
        }
    }
}

// MARK: - View

struct DuplicatesWorkspace: View {
    @ObservedObject var vm: DuplicatesViewModel

    var body: some View {
        HSplitView {
            sidebar
                .frame(minWidth: 295, idealWidth: 320, maxWidth: 375)
                .background(Color(nsColor: .windowBackgroundColor))
            detailPane
                .frame(minWidth: 660, maxWidth: .infinity, maxHeight: .infinity)
        }
        .alert("Delete \(vm.selectedFiles.count) Selected File(s)?", isPresented: $vm.showDeleteConfirm) {
            Button("Cancel", role: .cancel) {}
            Button(vm.moveToTrash ? "Move to Trash" : "Delete Permanently", role: .destructive) {
                vm.deleteSelected()
            }
        } message: {
            if vm.allCopiesSelectedGroupCount > 0 {
                Text("⚠️ WARNING: All copies are selected in \(vm.allCopiesSelectedGroupCount) group(s)! Uncheck at least one copy per group unless you intend to delete every copy. Total to reclaim: \(ByteFormatting.string(from: vm.selectedBytes)).")
            } else {
                Text("This will remove \(vm.selectedFiles.count) duplicate copy/copies and free \(ByteFormatting.string(from: vm.selectedBytes)), keeping the remaining original copy in each group.")
            }
        }
    }

    private var sidebar: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                GroupBox("Folders to Scan") {
                    VStack(alignment: .leading, spacing: 8) {
                        if vm.scanRoots.isEmpty {
                            Text("No folders selected.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        } else {
                            ForEach(vm.scanRoots, id: \.self) { root in
                                HStack(spacing: 6) {
                                    Image(systemName: "folder.fill")
                                        .foregroundStyle(.secondary)
                                    Text(root.path)
                                        .font(.caption)
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                    Spacer()
                                    Button {
                                        vm.removeRoot(root)
                                    } label: {
                                        Image(systemName: "xmark.circle.fill")
                                            .font(.system(size: 13))
                                            .foregroundStyle(.secondary)
                                            .frame(width: 22, height: 22)
                                            .contentShape(Rectangle())
                                    }
                                    .buttonStyle(.borderless)
                                }
                            }
                        }

                        HStack(spacing: 6) {
                            Button("Add Folder…") {
                                vm.addRootViaPanel()
                            }
                            .buttonStyle(.bordered)
                            Button("Personal") {
                                vm.setPersonalPresets()
                            }
                            .buttonStyle(.bordered)
                            Button("All Home") {
                                vm.setHomePreset()
                            }
                            .buttonStyle(.bordered)
                        }
                        .controlSize(.small)

                        Button {
                            vm.startScan()
                        } label: {
                            Label(vm.groups.isEmpty ? "Find Duplicate Files" : "Re-Scan Duplicates", systemImage: "doc.on.doc.fill")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(vm.isBusy || vm.scanRoots.isEmpty)
                    }
                    .padding(4)
                }

                GroupBox("Detection Rules") {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Text("Min File Size")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Spacer()
                            Picker("Min Size", selection: $vm.minSize) {
                                ForEach(DuplicateMinSize.allCases) { sz in
                                    Text(sz.label).tag(sz)
                                }
                            }
                            .labelsHidden()
                            .frame(width: 120)
                        }

                        Toggle("Skip .app bundles & ~/Library", isOn: $vm.skipPackagesAndLibrary)
                            .font(.caption)
                            .help("Recommended: prevents modifying internal app bundle resources or system caches.")

                        Toggle("Move deleted copies to Trash", isOn: $vm.moveToTrash)
                            .font(.caption)

                        Text("Uses 3-stage verification (byte size → head/mid/tail hash → full SHA-256) and ignores APFS hardlinks & cloud placeholders.")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(4)
                }

                if vm.allCopiesSelectedGroupCount > 0 {
                    GroupBox("Safety Warning") {
                        HStack(alignment: .top, spacing: 8) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(.orange)
                            Text("Every copy is selected in \(vm.allCopiesSelectedGroupCount) group(s). Keep at least one copy unchecked per group to preserve your original file.")
                                .font(.caption2)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .padding(4)
                    }
                }
            }
            .padding(12)
        }
        .clipped()
    }

    private var detailPane: some View {
        VStack(spacing: 0) {
            topSummaryHeader
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .background(.bar)
                .zIndex(3)

            Divider()

            quickToolbar
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(.background)
                .zIndex(2)

            Divider()

            groupsListView
                .clipped()
                .zIndex(0)

            if let prog = vm.progress {
                Divider()
                progressFooter(prog)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(.regularMaterial)
                    .zIndex(3)
            } else if let banner = vm.statusBanner {
                Divider()
                HStack {
                    Image(systemName: "info.circle.fill")
                        .foregroundStyle(.blue)
                    Text(banner)
                        .font(.caption)
                        .lineLimit(2)
                    Spacer()
                    Button("Dismiss") {
                        vm.statusBanner = nil
                    }
                    .buttonStyle(.borderless)
                    .font(.caption)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(.bar)
                .zIndex(3)
            }
        }
    }

    private var topSummaryHeader: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("\(vm.visibleGroups.count) duplicate group(s) · \(vm.totalDuplicateCopiesCount) extra copy/copies")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text("Wasted: \(ByteFormatting.string(from: vm.totalWastedBytes))")
                        .font(.title2.bold())
                    if !vm.selectedFiles.isEmpty {
                        Text("\(vm.selectedFiles.count) selected · \(ByteFormatting.string(from: vm.selectedBytes))")
                            .font(.callout.weight(.semibold))
                            .foregroundStyle(Color.accentColor)
                    }
                }
            }

            Spacer()

            Button {
                vm.showDeleteConfirm = true
            } label: {
                Label(vm.moveToTrash ? "Trash Selected Duplicates" : "Delete Selected Duplicates", systemImage: "trash.fill")
            }
            .buttonStyle(.borderedProminent)
            .tint(Color(red: 0.90, green: 0.24, blue: 0.30))
            .controlSize(.large)
            .disabled(vm.isBusy || vm.selectedFiles.isEmpty)
        }
    }

    private var quickToolbar: some View {
        HStack(spacing: 8) {
            Button("Keep Oldest") {
                vm.autoSelectDuplicates(keeping: .oldest)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(vm.visibleGroups.isEmpty || vm.isBusy)

            Button("Keep Newest") {
                vm.autoSelectDuplicates(keeping: .newest)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(vm.visibleGroups.isEmpty || vm.isBusy)

            Button("Keep Shortest Path") {
                vm.autoSelectDuplicates(keeping: .shortestPath)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(vm.visibleGroups.isEmpty || vm.isBusy)

            Button("Clear") {
                vm.clearSelection()
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(vm.selectedFileIDs.isEmpty || vm.isBusy)

            Divider().frame(height: 16)

            Button("Expand All") {
                vm.expandAll()
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(vm.visibleGroups.isEmpty)

            Button("Collapse All") {
                vm.collapseAll()
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(vm.visibleGroups.isEmpty)

            Spacer()

            TextField("Filter duplicates…", text: $vm.searchQuery)
                .textFieldStyle(.roundedBorder)
                .frame(width: 200)
        }
    }

    private var groupsListView: some View {
        Group {
            if vm.groups.isEmpty && !vm.isBusy {
                VStack(spacing: 14) {
                    Image(systemName: "doc.on.doc.fill")
                        .font(.system(size: 46))
                        .foregroundStyle(.secondary)
                    Text("Find Byte-for-Byte Duplicate Files")
                        .font(.title3.bold())
                    Text("Identifies exact clones across Documents, Downloads, Desktop, Pictures, Music, Movies, or any custom folder using SHA-256 verification.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 480)
                    Button("Find Duplicate Files") {
                        vm.startScan()
                    }
                    .buttonStyle(.borderedProminent)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 10) {
                        ForEach(vm.visibleGroups) { group in
                            groupCard(group)
                        }
                    }
                    .padding(12)
                }
            }
        }
    }

    private func groupCard(_ group: DuplicateGroup) -> some View {
        let isExpanded = vm.expandedGroupIDs.contains(group.id)
        let selectedInGroup = group.files.filter { vm.selectedFileIDs.contains($0.id) }.count
        let allSelectedWarning = selectedInGroup == group.files.count

        return VStack(spacing: 0) {
            Button {
                vm.toggleExpanded(group)
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(.secondary)
                        .frame(width: 14)

                    if let first = group.files.first {
                        Image(nsImage: IconCache.shared.icon(forPath: first.path))
                            .resizable()
                            .frame(width: 22, height: 22)
                    }

                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 8) {
                            Text(group.primaryName)
                                .font(.callout.weight(.semibold))
                                .lineLimit(1)
                            Text("\(group.files.count) copies")
                                .font(.caption2.weight(.semibold))
                                .padding(.horizontal, 7)
                                .padding(.vertical, 2)
                                .background(Capsule().fill(Color.accentColor.opacity(0.16)))
                            if allSelectedWarning {
                                Text("ALL SELECTED")
                                    .font(.caption2.weight(.bold))
                                    .foregroundStyle(.orange)
                                    .padding(.horizontal, 7)
                                    .padding(.vertical, 2)
                                    .background(Capsule().fill(Color.orange.opacity(0.16)))
                            }
                        }
                        Text("Each: \(ByteFormatting.string(from: group.fileSizeBytes)) · SHA-256: \(group.shortHash)…")
                            .font(.caption2.monospaced())
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    VStack(alignment: .trailing, spacing: 2) {
                        Text("Wasted: \(ByteFormatting.string(from: group.wastedBytes))")
                            .font(.callout.monospacedDigit().weight(.semibold))
                            .foregroundStyle(Color(red: 0.95, green: 0.45, blue: 0.25))
                        if selectedInGroup > 0 {
                            Text("\(selectedInGroup) marked for removal")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .background(Color(nsColor: .controlBackgroundColor))

            if isExpanded {
                Divider()
                VStack(spacing: 0) {
                    ForEach(group.files) { file in
                        duplicateFileRow(file)
                        if file.id != group.files.last?.id {
                            Divider().opacity(0.35)
                        }
                    }
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(allSelectedWarning ? Color.orange.opacity(0.6) : Color.secondary.opacity(0.22), lineWidth: 1)
        )
    }

    private func duplicateFileRow(_ file: DuplicateFileEntry) -> some View {
        let isSelected = vm.selectedFileIDs.contains(file.id)
        return HStack(spacing: 10) {
            NativeCheckbox(state: isSelected ? .on : .off) { _ in
                vm.toggleFileSelection(file)
            }
            .frame(width: 20, height: 20)

            Text(isSelected ? "DELETE" : "KEEP")
                .font(.caption2.weight(.bold))
                .foregroundStyle(isSelected ? Color.red : Color.green)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(
                    Capsule().fill((isSelected ? Color.red : Color.green).opacity(0.14))
                )
                .frame(width: 60)

            VStack(alignment: .leading, spacing: 2) {
                Text(file.name)
                    .font(.callout)
                    .lineLimit(1)
                Text(file.parentPath)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .help(file.path)

            Spacer(minLength: 8)

            Text(Self.dateFormatter.string(from: file.modifiedDate))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 110, alignment: .trailing)

            Text(ByteFormatting.string(from: file.allocatedBytes))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 82, alignment: .trailing)

            Button {
                vm.revealInFinder(file)
            } label: {
                Image(systemName: "folder")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .frame(width: 28, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .help("Reveal in Finder")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(isSelected ? Color.red.opacity(0.06) : Color.clear)
    }

    private func progressFooter(_ prog: OperationProgress) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(prog.phase)
                    .font(.caption.weight(.medium))
                Spacer()
                Text(prog.currentSubpath)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Button("Cancel") {
                    vm.cancelCurrentTask()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
            ProgressView(value: Double(prog.processedItems), total: Double(max(1, prog.totalItems)))
        }
    }

    private static let dateFormatter: DateFormatter = {
        let df = DateFormatter()
        df.dateStyle = .medium
        df.timeStyle = .none
        return df
    }()
}
