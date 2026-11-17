import AppKit
import Foundation
import SwiftUI

enum LargeFileCategory: String, CaseIterable, Identifiable, Sendable {
    case videos = "Videos"
    case diskImages = "Disk Images"
    case archives = "Archives"
    case aiModels = "AI Models"
    case vmContainers = "VMs & Disks"
    case audioSamples = "Audio & Samples"
    case appsBundles = "Apps & Bundles"
    case projectsDocs = "Projects & Docs"
    case other = "Other"

    var id: String { rawValue }

    var systemImage: String {
        switch self {
        case .videos: return "film.fill"
        case .diskImages: return "opticaldisc.fill"
        case .archives: return "doc.zipper"
        case .aiModels: return "cpu.fill"
        case .vmContainers: return "desktopcomputer"
        case .audioSamples: return "waveform"
        case .appsBundles: return "app.badge.fill"
        case .projectsDocs: return "doc.richtext.fill"
        case .other: return "doc.fill"
        }
    }

    var color: Color {
        switch self {
        case .videos: return Color(red: 0.64, green: 0.34, blue: 0.96)
        case .diskImages: return Color(red: 0.14, green: 0.68, blue: 0.88)
        case .archives: return Color(red: 0.96, green: 0.72, blue: 0.14)
        case .aiModels: return Color(red: 0.08, green: 0.80, blue: 0.56)
        case .vmContainers: return Color(red: 0.94, green: 0.34, blue: 0.30)
        case .audioSamples: return Color(red: 0.90, green: 0.24, blue: 0.64)
        case .appsBundles: return Color(red: 0.18, green: 0.56, blue: 0.96)
        case .projectsDocs: return Color(red: 0.98, green: 0.54, blue: 0.18)
        case .other: return Color(red: 0.56, green: 0.62, blue: 0.72)
        }
    }

    static func classify(url: URL, isPackage: Bool) -> LargeFileCategory {
        let ext = url.pathExtension.lowercased()
        if isPackage {
            switch ext {
            case "pvm", "vmwarevm", "utm", "vbox":
                return .vmContainers
            case "logicx", "fcpbundle", "band", "imovielibrary", "photoslibrary":
                return .projectsDocs
            default:
                return .appsBundles
            }
        }
        switch ext {
        case "mp4", "mov", "mkv", "avi", "m4v", "webm", "prores", "mts", "m2ts", "flv", "wmv", "mpg", "mpeg":
            return .videos
        case "dmg", "iso", "pkg", "mpkg", "ipsw":
            return .diskImages
        case "zip", "tar", "gz", "tgz", "bz2", "xz", "zst", "7z", "rar", "xar", "cab":
            return .archives
        case "gguf", "safetensors", "onnx", "pt", "pth", "ckpt", "mlmodel", "mlpackage", "bin", "tflite":
            return .aiModels
        case "vmdk", "qcow2", "vdi", "vhdx", "vhd", "hdd", "img", "sparseimage", "sparsebundle":
            return .vmContainers
        case "wav", "aif", "aiff", "flac", "mp3", "m4a", "caf", "ogg", "nkx", "nki", "nkc", "rex", "rx2", "sf2":
            return .audioSamples
        case "pdf", "psd", "psb", "ai", "sketch", "fig", "key", "pages", "numbers", "als", "alp", "cpr", "prproj", "aep", "blend", "c4d", "uasset", "umap":
            return .projectsDocs
        case "app", "ipa", "apk", "exe", "msi":
            return .appsBundles
        default:
            return .other
        }
    }
}

enum LargeFileMinSize: Int64, CaseIterable, Identifiable {
    case mb25 = 26_214_400
    case mb50 = 52_428_800
    case mb100 = 104_857_600
    case mb250 = 262_144_000
    case mb500 = 524_288_000
    case gb1 = 1_073_741_824

    var id: Int64 { rawValue }

    var label: String {
        switch self {
        case .mb25: return "≥ 25 MB"
        case .mb50: return "≥ 50 MB"
        case .mb100: return "≥ 100 MB"
        case .mb250: return "≥ 250 MB"
        case .mb500: return "≥ 500 MB"
        case .gb1: return "≥ 1 GB"
        }
    }
}

enum LargeFileSortField: String, CaseIterable {
    case name
    case category
    case folder
    case modified
    case size
}

struct LargeFileItem: Identifiable, Hashable, Sendable {
    let id: String
    let path: String
    let url: URL
    let name: String
    let parentPath: String
    let category: LargeFileCategory
    let isPackage: Bool
    let allocatedBytes: Int64
    let logicalBytes: Int64
    let modifiedDate: Date?
    let lastOpenedDate: Date?
}

actor LargeFilesEngine {
    func scanLargeFiles(
        roots: [URL],
        minThresholdBytes: Int64,
        includeAppBundles: Bool,
        skipDeveloperAndSystemLibraries: Bool,
        onProgress: @Sendable (OperationProgress) -> Void
    ) async throws -> [LargeFileItem] {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser.resolvingSymlinksInPath().path
        let protected = StorageUtilities.protectedSystemRoots()

        let keys: [URLResourceKey] = [
            .totalFileAllocatedSizeKey,
            .fileSizeKey,
            .isRegularFileKey,
            .isDirectoryKey,
            .isPackageKey,
            .isSymbolicLinkKey,
            .isAliasFileKey,
            .contentModificationDateKey,
            .contentAccessDateKey
        ]

        onProgress(
            OperationProgress(
                phase: "Scanning for heaviest files…",
                processedItems: 0,
                totalItems: max(1, roots.count),
                processedBytes: 0,
                totalBytes: 1,
                currentSubpath: ""
            )
        )

        var seenPaths = Set<String>()
        var foundFiles: [LargeFileItem] = []
        var packageCandidates: [URL] = []
        var scannedCount = 0

        for root in roots {
            try Task.checkCancellation()
            guard fm.fileExists(atPath: root.path) else { continue }

            guard let enumerator = fm.enumerator(
                at: root,
                includingPropertiesForKeys: keys,
                options: [.skipsPackageDescendants],
                errorHandler: { _, _ in true }
            ) else {
                continue
            }

            while let next = enumerator.nextObject() as? URL {
                try Task.checkCancellation()
                scannedCount += 1

                let path = next.path
                if StorageUtilities.isProtectedCloudPath(path) {
                    enumerator.skipDescendants()
                    continue
                }

                let name = next.lastPathComponent
                if name == ".Trash" || name == ".git" || name == "node_modules" {
                    enumerator.skipDescendants()
                    continue
                }

                if skipDeveloperAndSystemLibraries {
                    if path == "\(home)/Library" || path.hasPrefix("\(home)/Library/") {
                        enumerator.skipDescendants()
                        continue
                    }
                }

                guard let values = try? next.resourceValues(forKeys: Set(keys)) else { continue }
                if values.isSymbolicLink == true || values.isAliasFile == true {
                    enumerator.skipDescendants()
                    continue
                }

                if values.isPackage == true {
                    enumerator.skipDescendants()
                    if includeAppBundles {
                        let resolved = next.resolvingSymlinksInPath().path
                        if !protected.contains(resolved) && seenPaths.insert(resolved).inserted {
                            packageCandidates.append(next)
                        }
                    }
                    continue
                }

                if values.isRegularFile == true {
                    let alloc = Int64(values.totalFileAllocatedSize ?? 0)
                    let logical = Int64(values.fileSize ?? 0)
                    guard alloc >= minThresholdBytes else { continue }
                    let resolved = next.resolvingSymlinksInPath().path
                    guard !protected.contains(resolved), seenPaths.insert(resolved).inserted else { continue }

                    foundFiles.append(
                        LargeFileItem(
                            id: path,
                            path: path,
                            url: next,
                            name: name,
                            parentPath: Self.friendlyParent(of: next, home: home),
                            category: LargeFileCategory.classify(url: next, isPackage: false),
                            isPackage: false,
                            allocatedBytes: alloc,
                            logicalBytes: logical,
                            modifiedDate: values.contentModificationDate,
                            lastOpenedDate: values.contentAccessDate
                        )
                    )
                }

                if scannedCount % 1500 == 0 {
                    onProgress(
                        OperationProgress(
                            phase: "Scanned \(scannedCount) filesystem entries (\(foundFiles.count) large files)…",
                            processedItems: scannedCount,
                            totalItems: max(scannedCount + 1000, scannedCount),
                            processedBytes: foundFiles.reduce(0) { $0 + $1.allocatedBytes },
                            totalBytes: max(1, foundFiles.reduce(0) { $0 + $1.allocatedBytes }),
                            currentSubpath: name
                        )
                    )
                }
            }
        }

        // Measure discovered packages concurrently
        if !packageCandidates.isEmpty {
            let maxWorkers = 6
            var idx = 0
            var donePkgs = 0
            try await withThrowingTaskGroup(of: LargeFileItem?.self) { group in
                let initial = min(maxWorkers, packageCandidates.count)
                for _ in 0..<initial {
                    let pkgURL = packageCandidates[idx]
                    idx += 1
                    group.addTask {
                        try Task.checkCancellation()
                        return Self.measurePackageItem(pkgURL, minThresholdBytes: minThresholdBytes, home: home)
                    }
                }

                while let item = try await group.next() {
                    try Task.checkCancellation()
                    donePkgs += 1
                    if let item {
                        foundFiles.append(item)
                    }
                    if donePkgs % 8 == 0 || donePkgs == packageCandidates.count {
                        onProgress(
                            OperationProgress(
                                phase: "Measuring bundles & packages (\(donePkgs)/\(packageCandidates.count))…",
                                processedItems: donePkgs,
                                totalItems: max(1, packageCandidates.count),
                                processedBytes: Int64(donePkgs),
                                totalBytes: Int64(max(1, packageCandidates.count)),
                                currentSubpath: item?.name ?? ""
                            )
                        )
                    }
                    if idx < packageCandidates.count {
                        let pkgURL = packageCandidates[idx]
                        idx += 1
                        group.addTask {
                            try Task.checkCancellation()
                            return Self.measurePackageItem(pkgURL, minThresholdBytes: minThresholdBytes, home: home)
                        }
                    }
                }
            }
        }

        return foundFiles.sorted { $0.allocatedBytes > $1.allocatedBytes }
    }

    private static func measurePackageItem(_ url: URL, minThresholdBytes: Int64, home: String) -> LargeFileItem? {
        let stats = StorageUtilities.measureAllocatedSize(at: url)
        guard stats.allocatedBytes >= minThresholdBytes else { return nil }
        let mod = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? stats.latestModified
        let acc = (try? url.resourceValues(forKeys: [.contentAccessDateKey]))?.contentAccessDate
        return LargeFileItem(
            id: url.path,
            path: url.path,
            url: url,
            name: url.lastPathComponent,
            parentPath: friendlyParent(of: url, home: home),
            category: LargeFileCategory.classify(url: url, isPackage: true),
            isPackage: true,
            allocatedBytes: stats.allocatedBytes,
            logicalBytes: stats.logicalBytes,
            modifiedDate: mod,
            lastOpenedDate: acc
        )
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
final class LargeFilesViewModel: ObservableObject {
    @Published var scanRoots: [URL] = [
        FileManager.default.homeDirectoryForCurrentUser,
        URL(fileURLWithPath: "/Applications", isDirectory: true)
    ]
    @Published private(set) var items: [LargeFileItem] = []
    @Published private(set) var visibleItems: [LargeFileItem] = []
    @Published private(set) var categoryTotals: [(category: LargeFileCategory, count: Int, bytes: Int64)] = []

    @Published var selectedIDs: Set<String> = []
    @Published var selectedCategory: LargeFileCategory? = nil { didSet { rebuildVisibleItems() } }
    @Published var minSize: LargeFileMinSize = .mb100 { didSet { rebuildVisibleItems() } }
    @Published var includeAppBundles: Bool = true
    @Published var skipLibraryFolder: Bool = false
    @Published var moveToTrash: Bool = true
    @Published var searchQuery: String = "" { didSet { rebuildVisibleItems() } }
    @Published var sortField: LargeFileSortField = .size { didSet { rebuildVisibleItems() } }
    @Published var sortAscending: Bool = false { didSet { rebuildVisibleItems() } }

    @Published var isBusy: Bool = false
    @Published var progress: OperationProgress? = nil
    @Published var statusBanner: String? = nil
    @Published var showDeleteConfirm: Bool = false

    private let engine = LargeFilesEngine()
    private var activeTask: Task<Void, Never>?
    private var lastAnchorID: String?

    var totalBytes: Int64 {
        visibleItems.reduce(0) { $0 + $1.allocatedBytes }
    }

    var selectedItems: [LargeFileItem] {
        items.filter { selectedIDs.contains($0.id) }
    }

    var selectedBytes: Int64 {
        selectedItems.reduce(0) { $0 + $1.allocatedBytes }
    }

    var largestFileBytes: Int64 {
        visibleItems.map(\.allocatedBytes).max() ?? 1
    }

    var headerCheckState: NativeCheckState {
        let vis = visibleItems.map(\.id)
        guard !vis.isEmpty else { return .off }
        let selected = vis.filter { selectedIDs.contains($0) }.count
        if selected == 0 { return .off }
        if selected == vis.count { return .on }
        return .mixed
    }

    func addRootViaPanel() {
        let urls = StorageUtilities.chooseFolders(prompt: "Add Scan Root")
        for url in urls where !scanRoots.contains(url) {
            scanRoots.append(url)
        }
    }

    func removeRoot(_ url: URL) {
        scanRoots.removeAll { $0 == url }
    }

    func resetDefaultRoots() {
        scanRoots = [
            FileManager.default.homeDirectoryForCurrentUser,
            URL(fileURLWithPath: "/Applications", isDirectory: true)
        ]
    }

    func startScan() {
        guard !scanRoots.isEmpty else { return }
        cancelCurrentTask()
        isBusy = true
        statusBanner = nil
        selectedIDs.removeAll()
        progress = OperationProgress(
            phase: "Searching for largest files…",
            processedItems: 0,
            totalItems: max(1, scanRoots.count),
            processedBytes: 0,
            totalBytes: 1,
            currentSubpath: ""
        )

        let roots = scanRoots
        let includeBundles = includeAppBundles
        let skipLib = skipLibraryFolder
        // Scan down to 25 MB once so threshold switches (50/100/250/500MB/1GB) are instant
        activeTask = Task { [weak self] in
            guard let self else { return }
            do {
                let found = try await engine.scanLargeFiles(
                    roots: roots,
                    minThresholdBytes: LargeFileMinSize.mb25.rawValue,
                    includeAppBundles: includeBundles,
                    skipDeveloperAndSystemLibraries: skipLib
                ) { [weak self] prog in
                    Task { @MainActor in
                        self?.progress = prog
                    }
                }
                self.items = found
                self.rebuildCategoryTotals()
                self.rebuildVisibleItems()
                self.progress = nil
                self.statusBanner = "Found \(found.count) large file(s) ≥ 25 MB totaling \(ByteFormatting.string(from: found.reduce(0) { $0 + $1.allocatedBytes }))."
            } catch is CancellationError {
                self.progress = nil
                self.statusBanner = "Large files scan cancelled."
            } catch {
                self.progress = nil
                self.statusBanner = "Scan error: \(error.localizedDescription)"
            }
            self.isBusy = false
        }
    }

    func toggleHeaderSelection() {
        let vis = Set(visibleItems.map(\.id))
        guard !vis.isEmpty else { return }
        if vis.isSubset(of: selectedIDs) {
            selectedIDs.subtract(vis)
        } else {
            selectedIDs.formUnion(vis)
        }
    }

    func toggleSelection(for item: LargeFileItem, shiftPressed: Bool) {
        if shiftPressed, let anchorID = lastAnchorID,
           let start = visibleItems.firstIndex(where: { $0.id == anchorID }),
           let end = visibleItems.firstIndex(where: { $0.id == item.id }) {
            let lower = min(start, end)
            let upper = max(start, end)
            let shouldSelect = !selectedIDs.contains(item.id)
            for idx in lower...upper {
                let id = visibleItems[idx].id
                if shouldSelect {
                    selectedIDs.insert(id)
                } else {
                    selectedIDs.remove(id)
                }
            }
            return
        }

        if selectedIDs.contains(item.id) {
            selectedIDs.remove(item.id)
        } else {
            selectedIDs.insert(item.id)
        }
        lastAnchorID = item.id
    }

    func selectTop(_ count: Int) {
        selectedIDs.formUnion(visibleItems.prefix(count).map(\.id))
    }

    func clearSelection() {
        selectedIDs.removeAll()
        lastAnchorID = nil
    }

    func setSort(field: LargeFileSortField) {
        if sortField == field {
            sortAscending.toggle()
        } else {
            sortField = field
            sortAscending = (field == .name || field == .category || field == .folder)
        }
    }

    func revealInFinder(_ item: LargeFileItem) {
        NSWorkspace.shared.activateFileViewerSelecting([item.url])
    }

    func deleteSelected() {
        let targets = selectedItems
        guard !targets.isEmpty else { return }

        cancelCurrentTask()
        isBusy = true
        statusBanner = nil
        progress = OperationProgress(
            phase: moveToTrash ? "Moving selected files to Trash…" : "Deleting selected files…",
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
                let deleted = Set(targets.filter { !FileManager.default.fileExists(atPath: $0.path) }.map(\.id))
                self.items.removeAll { deleted.contains($0.id) }
                self.selectedIDs.subtract(deleted)
                self.rebuildCategoryTotals()
                self.rebuildVisibleItems()
                self.progress = nil

                var msg = "\(useTrash ? "Trashed" : "Deleted") \(summary.succeededCount) file(s), freeing \(ByteFormatting.string(from: summary.bytesAffected))."
                if summary.failedCount > 0 {
                    msg += " \(summary.failedCount) failed: \(summary.errors.first ?? "")"
                }
                self.statusBanner = msg
            } catch is CancellationError {
                self.progress = nil
                self.statusBanner = "Deletion cancelled."
            } catch {
                self.progress = nil
                self.statusBanner = "Deletion error: \(error.localizedDescription)"
            }
            self.isBusy = false
        }
    }

    func cancelCurrentTask() {
        activeTask?.cancel()
        activeTask = nil
    }

    private func rebuildCategoryTotals() {
        let thresholdFiltered = items.filter { $0.allocatedBytes >= minSize.rawValue }
        var grouped: [LargeFileCategory: (count: Int, bytes: Int64)] = [:]
        for item in thresholdFiltered {
            let cur = grouped[item.category] ?? (0, 0)
            grouped[item.category] = (cur.count + 1, cur.bytes + item.allocatedBytes)
        }
        categoryTotals = LargeFileCategory.allCases.compactMap { cat in
            let stats = grouped[cat] ?? (0, 0)
            guard stats.count > 0 else { return nil }
            return (cat, stats.count, stats.bytes)
        }
        .sorted { $0.bytes > $1.bytes }
    }

    private func rebuildVisibleItems() {
        rebuildCategoryTotalsIfNeeded()
        let q = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let filtered = items.filter { item in
            if item.allocatedBytes < minSize.rawValue { return false }
            if let selectedCategory, item.category != selectedCategory { return false }
            if !q.isEmpty {
                let hay = "\(item.name) \(item.path)".lowercased()
                if !hay.contains(q) { return false }
            }
            return true
        }

        visibleItems = filtered.sorted { lhs, rhs in
            let asc = sortAscending
            switch sortField {
            case .name:
                let cmp = lhs.name.localizedCaseInsensitiveCompare(rhs.name)
                if cmp != .orderedSame { return asc ? (cmp == .orderedAscending) : (cmp == .orderedDescending) }
            case .category:
                let cmp = lhs.category.rawValue.localizedCaseInsensitiveCompare(rhs.category.rawValue)
                if cmp != .orderedSame { return asc ? (cmp == .orderedAscending) : (cmp == .orderedDescending) }
            case .folder:
                let cmp = lhs.parentPath.localizedCaseInsensitiveCompare(rhs.parentPath)
                if cmp != .orderedSame { return asc ? (cmp == .orderedAscending) : (cmp == .orderedDescending) }
            case .modified:
                let l = lhs.modifiedDate ?? .distantPast
                let r = rhs.modifiedDate ?? .distantPast
                if l != r { return asc ? (l < r) : (l > r) }
            case .size:
                if lhs.allocatedBytes != rhs.allocatedBytes { return asc ? (lhs.allocatedBytes < rhs.allocatedBytes) : (lhs.allocatedBytes > rhs.allocatedBytes) }
            }
            return lhs.allocatedBytes > rhs.allocatedBytes
        }
    }

    private func rebuildCategoryTotalsIfNeeded() {
        let thresholdFiltered = items.filter { $0.allocatedBytes >= minSize.rawValue }
        var grouped: [LargeFileCategory: (count: Int, bytes: Int64)] = [:]
        for item in thresholdFiltered {
            let cur = grouped[item.category] ?? (0, 0)
            grouped[item.category] = (cur.count + 1, cur.bytes + item.allocatedBytes)
        }
        categoryTotals = LargeFileCategory.allCases.compactMap { cat in
            let stats = grouped[cat] ?? (0, 0)
            guard stats.count > 0 else { return nil }
            return (cat, stats.count, stats.bytes)
        }
        .sorted { $0.bytes > $1.bytes }
    }
}

// MARK: - View

struct LargeFilesWorkspace: View {
    @ObservedObject var vm: LargeFilesViewModel

    var body: some View {
        HSplitView {
            sidebar
                .frame(minWidth: 295, idealWidth: 320, maxWidth: 375)
                .background(Color(nsColor: .windowBackgroundColor))
            detailPane
                .frame(minWidth: 660, maxWidth: .infinity, maxHeight: .infinity)
        }
        .alert("Delete \(vm.selectedItems.count) Large File(s)?", isPresented: $vm.showDeleteConfirm) {
            Button("Cancel", role: .cancel) {}
            Button(vm.moveToTrash ? "Move to Trash" : "Delete Permanently", role: .destructive) {
                vm.deleteSelected()
            }
        } message: {
            Text("This will reclaim \(ByteFormatting.string(from: vm.selectedBytes)).")
        }
    }

    private var sidebar: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                GroupBox("Scan Roots") {
                    VStack(alignment: .leading, spacing: 8) {
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

                        HStack(spacing: 8) {
                            Button("Add Folder…") {
                                vm.addRootViaPanel()
                            }
                            .buttonStyle(.bordered)
                            Button("Defaults") {
                                vm.resetDefaultRoots()
                            }
                            .buttonStyle(.bordered)
                        }
                        .controlSize(.small)

                        Button {
                            vm.startScan()
                        } label: {
                            Label(vm.items.isEmpty ? "Find Largest Files" : "Re-Scan Largest Files", systemImage: "arrow.up.doc.fill")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(vm.isBusy || vm.scanRoots.isEmpty)
                    }
                    .padding(4)
                }

                GroupBox("File Categories") {
                    VStack(alignment: .leading, spacing: 4) {
                        categoryButton(
                            title: "All Types",
                            icon: "square.stack.3d.up.fill",
                            color: .accentColor,
                            bytes: vm.categoryTotals.reduce(0) { $0 + $1.bytes },
                            isSelected: vm.selectedCategory == nil
                        ) {
                            vm.selectedCategory = nil
                        }

                        if vm.items.isEmpty {
                            Text("Scan to group heavy Videos, Disk Images, AI Models, VMs, Samples & Apps.")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .padding(.top, 4)
                        } else {
                            ForEach(vm.categoryTotals, id: \.category) { entry in
                                categoryButton(
                                    title: "\(entry.category.rawValue) (\(entry.count))",
                                    icon: entry.category.systemImage,
                                    color: entry.category.color,
                                    bytes: entry.bytes,
                                    isSelected: vm.selectedCategory == entry.category
                                ) {
                                    vm.selectedCategory = (vm.selectedCategory == entry.category) ? nil : entry.category
                                }
                            }
                        }
                    }
                    .padding(4)
                }

                GroupBox("Filter & Options") {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Text("Min File Size")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Spacer()
                            Picker("Min Size", selection: $vm.minSize) {
                                ForEach(LargeFileMinSize.allCases) { sz in
                                    Text(sz.label).tag(sz)
                                }
                            }
                            .labelsHidden()
                            .frame(width: 120)
                        }

                        Toggle("Include .app & project bundles", isOn: $vm.includeAppBundles)
                            .font(.caption)
                        Toggle("Skip ~/Library folder", isOn: $vm.skipLibraryFolder)
                            .font(.caption)
                        Toggle("Move deleted items to Trash", isOn: $vm.moveToTrash)
                            .font(.caption)
                    }
                    .padding(4)
                }
            }
            .padding(12)
        }
        .clipped()
    }

    private func categoryButton(
        title: String,
        icon: String,
        color: Color,
        bytes: Int64,
        isSelected: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 12))
                    .foregroundStyle(color)
                    .frame(width: 16)
                Text(title)
                    .font(.caption)
                    .fontWeight(isSelected ? .semibold : .regular)
                    .lineLimit(1)
                Spacer()
                if bytes > 0 {
                    Text(ByteFormatting.compactMBGB(from: bytes))
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(isSelected ? color.opacity(0.18) : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
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

            sortableHeader
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(Color(nsColor: .controlBackgroundColor))
                .zIndex(2)

            Divider()

            itemsListView
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
                Text("Heaviest Files (\(vm.minSize.label)) · \(vm.visibleItems.count) shown")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text(ByteFormatting.string(from: vm.totalBytes))
                        .font(.title2.bold())
                    if !vm.selectedItems.isEmpty {
                        Text("\(vm.selectedItems.count) selected · \(ByteFormatting.string(from: vm.selectedBytes))")
                            .font(.callout.weight(.semibold))
                            .foregroundStyle(Color.accentColor)
                    }
                }
            }

            Spacer()

            Button {
                vm.showDeleteConfirm = true
            } label: {
                Label(vm.moveToTrash ? "Move Selected to Trash" : "Delete Selected", systemImage: "trash.fill")
            }
            .buttonStyle(.borderedProminent)
            .tint(Color(red: 0.90, green: 0.24, blue: 0.30))
            .controlSize(.large)
            .disabled(vm.isBusy || vm.selectedItems.isEmpty)
        }
    }

    private var quickToolbar: some View {
        HStack(spacing: 8) {
            Button("Select Top 10") {
                vm.selectTop(10)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(vm.visibleItems.isEmpty || vm.isBusy)

            Button("Clear") {
                vm.clearSelection()
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(vm.selectedIDs.isEmpty || vm.isBusy)

            Spacer()

            TextField("Filter by filename or path…", text: $vm.searchQuery)
                .textFieldStyle(.roundedBorder)
                .frame(width: 240)
        }
    }

    private var sortableHeader: some View {
        HStack(spacing: 10) {
            NativeCheckbox(state: vm.headerCheckState) { _ in
                vm.toggleHeaderSelection()
            }
            .frame(width: 20, height: 20)

            sortButton("File / Bundle", field: .name)
            Spacer()
            sortButton("Location", field: .folder)
                .frame(width: 190, alignment: .leading)
            sortButton("Type", field: .category)
                .frame(width: 112, alignment: .leading)
            sortButton("Modified", field: .modified)
                .frame(width: 92, alignment: .trailing)
            sortButton("Size", field: .size)
                .frame(width: 88, alignment: .trailing)
            Text("Finder")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(width: 44, alignment: .center)
        }
    }

    private func sortButton(_ title: String, field: LargeFileSortField) -> some View {
        Button {
            vm.setSort(field: field)
        } label: {
            HStack(spacing: 3) {
                Text(title)
                    .font(.caption.weight(.semibold))
                if vm.sortField == field {
                    Image(systemName: vm.sortAscending ? "chevron.up" : "chevron.down")
                        .font(.system(size: 9, weight: .bold))
                }
            }
            .foregroundStyle(vm.sortField == field ? Color.primary : Color.secondary)
            .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
    }

    private var itemsListView: some View {
        Group {
            if vm.items.isEmpty && !vm.isBusy {
                VStack(spacing: 14) {
                    Image(systemName: "arrow.up.doc.fill")
                        .font(.system(size: 46))
                        .foregroundStyle(.secondary)
                    Text("Find the Heaviest Files on Your Mac")
                        .font(.title3.bold())
                    Text("Click \"Find Largest Files\" to locate oversized videos, disk images, archives, AI models, sample libraries, VMs, and app bundles.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 480)
                    Button("Find Largest Files") {
                        vm.startScan()
                    }
                    .buttonStyle(.borderedProminent)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                let maxBytes = max(1, Double(vm.largestFileBytes))
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(vm.visibleItems) { item in
                            fileRow(item, maxBytes: maxBytes)
                            Divider().opacity(0.35)
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
        }
    }

    private func fileRow(_ item: LargeFileItem, maxBytes: Double) -> some View {
        let isSelected = vm.selectedIDs.contains(item.id)
        let ratio = min(1.0, max(0.02, Double(item.allocatedBytes) / maxBytes))
        return HStack(spacing: 10) {
            NativeCheckbox(state: isSelected ? .on : .off) { shiftPressed in
                vm.toggleSelection(for: item, shiftPressed: shiftPressed)
            }
            .frame(width: 20, height: 20)

            Image(nsImage: IconCache.shared.icon(forPath: item.path))
                .resizable()
                .frame(width: 22, height: 22)

            VStack(alignment: .leading, spacing: 3) {
                Text(item.name)
                    .font(.callout.weight(.medium))
                    .lineLimit(1)
                GeometryReader { geo in
                    RoundedRectangle(cornerRadius: 2)
                        .fill(item.category.color.opacity(0.75))
                        .frame(width: max(4, geo.size.width * ratio), height: 3)
                }
                .frame(height: 3)
            }
            .help(item.path)

            Spacer(minLength: 8)

            Text(item.parentPath)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(width: 190, alignment: .leading)
                .help(item.parentPath)

            HStack(spacing: 5) {
                Circle()
                    .fill(item.category.color)
                    .frame(width: 7, height: 7)
                Text(item.category.rawValue)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .frame(width: 112, alignment: .leading)

            Text(Self.formatDate(item.modifiedDate))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 92, alignment: .trailing)

            Text(ByteFormatting.string(from: item.allocatedBytes))
                .font(.callout.monospacedDigit().weight(.medium))
                .frame(width: 88, alignment: .trailing)

            Button {
                vm.revealInFinder(item)
            } label: {
                Image(systemName: "folder")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .frame(width: 28, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .help("Reveal in Finder")
            .frame(width: 44, alignment: .center)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(isSelected ? Color.accentColor.opacity(0.10) : Color.clear)
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

    private static func formatDate(_ date: Date?) -> String {
        guard let date else { return "—" }
        return dateFormatter.string(from: date)
    }
}
