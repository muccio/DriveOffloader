import AppKit
import Foundation
import SwiftUI

enum DiskUsageCategory: String, CaseIterable, Identifiable, Sendable {
    case applications = "Applications"
    case documents = "Documents"
    case downloads = "Downloads"
    case desktop = "Desktop"
    case movies = "Movies"
    case music = "Music & Audio"
    case pictures = "Pictures"
    case developer = "Developer & Tools"
    case libraryData = "App Data (Library)"
    case otherHome = "Other Home Folders"
    case cloudLocal = "Cloud Local Cache"
    case trash = "Trash"
    case custom = "Custom Folder"

    var id: String { rawValue }

    var systemImage: String {
        switch self {
        case .applications: return "app.badge.fill"
        case .documents: return "doc.text.fill"
        case .downloads: return "arrow.down.circle.fill"
        case .desktop: return "menubar.dock.rectangle"
        case .movies: return "film.fill"
        case .music: return "music.note"
        case .pictures: return "photo.on.rectangle.angled"
        case .developer: return "hammer.fill"
        case .libraryData: return "books.vertical.fill"
        case .otherHome: return "folder.fill"
        case .cloudLocal: return "icloud.fill"
        case .trash: return "trash.fill"
        case .custom: return "externaldrive.fill"
        }
    }

    var color: Color {
        switch self {
        case .applications: return Color(red: 0.08, green: 0.78, blue: 0.56)
        case .documents: return Color(red: 0.18, green: 0.56, blue: 0.96)
        case .downloads: return Color(red: 0.10, green: 0.76, blue: 0.88)
        case .desktop: return Color(red: 0.38, green: 0.44, blue: 0.96)
        case .movies: return Color(red: 0.64, green: 0.34, blue: 0.96)
        case .music: return Color(red: 0.90, green: 0.24, blue: 0.64)
        case .pictures: return Color(red: 0.98, green: 0.54, blue: 0.18)
        case .developer: return Color(red: 0.20, green: 0.74, blue: 0.42)
        case .libraryData: return Color(red: 0.96, green: 0.72, blue: 0.14)
        case .otherHome: return Color(red: 0.16, green: 0.66, blue: 0.68)
        case .cloudLocal: return Color(red: 0.35, green: 0.74, blue: 0.98)
        case .trash: return Color(red: 0.90, green: 0.24, blue: 0.30)
        case .custom: return Color(red: 0.56, green: 0.62, blue: 0.72)
        }
    }
}

enum DiskUsageSortField: String, CaseIterable {
    case name
    case category
    case files
    case modified
    case size
}

struct DiskUsageCategorySummary: Identifiable, Hashable, Sendable {
    var id: DiskUsageCategory { category }
    let category: DiskUsageCategory
    let rootPaths: [String]
    let allocatedBytes: Int64
    let fileCount: Int
}

struct DiskUsageEntry: Identifiable, Hashable, Sendable {
    let id: String
    let path: String
    let url: URL
    let name: String
    let subtitle: String
    let category: DiskUsageCategory
    let isDirectory: Bool
    let isPackage: Bool
    let allocatedBytes: Int64
    let fileCount: Int
    let lastModified: Date?
    let canDelete: Bool

    var canDrillDown: Bool {
        isDirectory && !isPackage
    }
}

struct DiskUsageScanResult: Sendable {
    let volumeSummary: VolumeSpaceSummary?
    let categorySummaries: [DiskUsageCategorySummary]
    let topLevelEntries: [DiskUsageEntry]
    let totalMeasuredBytes: Int64
}

private struct UsageRootSpec: Sendable {
    let url: URL
    let category: DiskUsageCategory
    let excludedCanonicalPaths: Set<String>
}

actor DiskUsageEngine {
    func scanOverview(
        customRoots: [URL] = [],
        onProgress: @Sendable (OperationProgress) -> Void
    ) async throws -> DiskUsageScanResult {
        let specs = buildRootSpecs(customRoots: customRoots)
        let fm = FileManager.default
        let protected = StorageUtilities.protectedSystemRoots()

        struct ChildTarget: Sendable {
            let url: URL
            let category: DiskUsageCategory
            let parentLabel: String
            let excluded: Set<String>
        }

        var childTargets: [ChildTarget] = []
        for spec in specs {
            guard fm.fileExists(atPath: spec.url.path),
                  !StorageUtilities.isSymlinkOrAlias(spec.url)
            else { continue }

            // Single directory outside Home top-level child enumeration (e.g. direct remaining home item)
            if spec.category == .otherHome && spec.url.deletingLastPathComponent().resolvingSymlinksInPath().path == fm.homeDirectoryForCurrentUser.resolvingSymlinksInPath().path {
                childTargets.append(
                    ChildTarget(
                        url: spec.url,
                        category: .otherHome,
                        parentLabel: "~/",
                        excluded: spec.excludedCanonicalPaths
                    )
                )
                continue
            }

            if let children = try? fm.contentsOfDirectory(
                at: spec.url,
                includingPropertiesForKeys: [.isSymbolicLinkKey, .isAliasFileKey],
                options: []
            ) {
                for child in children {
                    let name = child.lastPathComponent
                    if name == ".DS_Store" || name == ".localized" { continue }
                    let resolved = child.resolvingSymlinksInPath().path
                    if spec.excludedCanonicalPaths.contains(resolved) { continue }
                    if StorageUtilities.isSymlinkOrAlias(child) { continue }

                    childTargets.append(
                        ChildTarget(
                            url: child,
                            category: spec.category,
                            parentLabel: Self.friendlyPath(spec.url.path),
                            excluded: spec.excludedCanonicalPaths
                        )
                    )
                }
            }
        }

        let totalCount = max(1, childTargets.count)
        onProgress(
            OperationProgress(
                phase: "Measuring Applications, Documents & Disk Areas…",
                processedItems: 0,
                totalItems: totalCount,
                processedBytes: 0,
                totalBytes: 1,
                currentSubpath: ""
            )
        )

        var entries: [DiskUsageEntry] = []
        entries.reserveCapacity(childTargets.count)
        var categoryBytes: [DiskUsageCategory: Int64] = [:]
        var categoryFiles: [DiskUsageCategory: Int] = [:]
        var categoryRoots: [DiskUsageCategory: Set<String>] = [:]
        for spec in specs {
            categoryRoots[spec.category, default: []].insert(spec.url.path)
        }

        var processed = 0
        var runningTotalBytes: Int64 = 0
        let maxWorkers = 6
        var nextIdx = 0

        try await withThrowingTaskGroup(of: DiskUsageEntry?.self) { group in
            let initial = min(maxWorkers, childTargets.count)
            for _ in 0..<initial {
                let target = childTargets[nextIdx]
                nextIdx += 1
                group.addTask {
                    try Task.checkCancellation()
                    return Self.measureEntry(
                        url: target.url,
                        category: target.category,
                        subtitle: target.parentLabel,
                        excluded: target.excluded,
                        protected: protected
                    )
                }
            }

            while let entry = try await group.next() {
                try Task.checkCancellation()
                processed += 1

                if let entry, entry.allocatedBytes > 0 {
                    entries.append(entry)
                    runningTotalBytes += entry.allocatedBytes
                    categoryBytes[entry.category, default: 0] += entry.allocatedBytes
                    categoryFiles[entry.category, default: 0] += entry.fileCount
                }

                if processed == childTargets.count || processed % 6 == 0 {
                    onProgress(
                        OperationProgress(
                            phase: "Measuring disk occupancy (\(processed)/\(childTargets.count))…",
                            processedItems: processed,
                            totalItems: totalCount,
                            processedBytes: runningTotalBytes,
                            totalBytes: max(1, runningTotalBytes),
                            currentSubpath: entry?.name ?? ""
                        )
                    )
                }

                if nextIdx < childTargets.count {
                    let target = childTargets[nextIdx]
                    nextIdx += 1
                    group.addTask {
                        try Task.checkCancellation()
                        return Self.measureEntry(
                            url: target.url,
                            category: target.category,
                            subtitle: target.parentLabel,
                            excluded: target.excluded,
                            protected: protected
                        )
                    }
                }
            }
        }

        let summaries = DiskUsageCategory.allCases.compactMap { category -> DiskUsageCategorySummary? in
            let bytes = categoryBytes[category] ?? 0
            let files = categoryFiles[category] ?? 0
            let roots = Array(categoryRoots[category] ?? []).sorted()
            guard bytes > 0 || !roots.isEmpty && bytes > 0 else { return nil }
            return DiskUsageCategorySummary(
                category: category,
                rootPaths: roots,
                allocatedBytes: bytes,
                fileCount: files
            )
        }
        .sorted { $0.allocatedBytes > $1.allocatedBytes }

        entries.sort { $0.allocatedBytes > $1.allocatedBytes }

        return DiskUsageScanResult(
            volumeSummary: StorageUtilities.volumeSpaceSummary(),
            categorySummaries: summaries,
            topLevelEntries: entries,
            totalMeasuredBytes: runningTotalBytes
        )
    }

    func scanDirectoryChildren(
        at directoryURL: URL,
        category: DiskUsageCategory,
        onProgress: @Sendable (OperationProgress) -> Void
    ) async throws -> [DiskUsageEntry] {
        let fm = FileManager.default
        let protected = StorageUtilities.protectedSystemRoots()
        guard let children = try? fm.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: [.isSymbolicLinkKey, .isAliasFileKey],
            options: []
        ) else {
            return []
        }

        let filteredChildren = children.filter { url in
            let name = url.lastPathComponent
            return name != ".DS_Store" && name != ".localized" && !StorageUtilities.isSymlinkOrAlias(url)
        }

        let total = max(1, filteredChildren.count)
        let parentLabel = Self.friendlyPath(directoryURL.path)
        var results: [DiskUsageEntry] = []
        results.reserveCapacity(filteredChildren.count)
        var processed = 0
        var totalBytes: Int64 = 0
        var nextIdx = 0
        let maxWorkers = 6

        try await withThrowingTaskGroup(of: DiskUsageEntry?.self) { group in
            let initial = min(maxWorkers, filteredChildren.count)
            for _ in 0..<initial {
                let child = filteredChildren[nextIdx]
                nextIdx += 1
                group.addTask {
                    try Task.checkCancellation()
                    return Self.measureEntry(
                        url: child,
                        category: category,
                        subtitle: parentLabel,
                        excluded: [],
                        protected: protected
                    )
                }
            }

            while let entry = try await group.next() {
                try Task.checkCancellation()
                processed += 1
                if let entry, entry.allocatedBytes > 0 {
                    results.append(entry)
                    totalBytes += entry.allocatedBytes
                }

                if processed == filteredChildren.count || processed % 8 == 0 {
                    onProgress(
                        OperationProgress(
                            phase: "Inspecting \(directoryURL.lastPathComponent) (\(processed)/\(filteredChildren.count))…",
                            processedItems: processed,
                            totalItems: total,
                            processedBytes: totalBytes,
                            totalBytes: max(1, totalBytes),
                            currentSubpath: entry?.name ?? ""
                        )
                    )
                }

                if nextIdx < filteredChildren.count {
                    let child = filteredChildren[nextIdx]
                    nextIdx += 1
                    group.addTask {
                        try Task.checkCancellation()
                        return Self.measureEntry(
                            url: child,
                            category: category,
                            subtitle: parentLabel,
                            excluded: [],
                            protected: protected
                        )
                    }
                }
            }
        }

        return results.sorted { $0.allocatedBytes > $1.allocatedBytes }
    }

    // MARK: - Root Construction

    private func buildRootSpecs(customRoots: [URL]) -> [UsageRootSpec] {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser
        let library = home.appendingPathComponent("Library", isDirectory: true)

        var claimedCanonicalPaths = Set<String>()
        func claim(_ url: URL) -> URL {
            claimedCanonicalPaths.insert(url.resolvingSymlinksInPath().path)
            return url
        }

        let cloudPaths: [URL] = [
            claim(library.appendingPathComponent("CloudStorage", isDirectory: true)),
            claim(library.appendingPathComponent("Mobile Documents", isDirectory: true)),
            claim(library.appendingPathComponent("Application Support/Google/DriveFS", isDirectory: true))
        ]

        let devPaths: [URL] = [
            claim(library.appendingPathComponent("Developer", isDirectory: true)),
            claim(home.appendingPathComponent("Developer", isDirectory: true)),
            claim(home.appendingPathComponent(".gradle", isDirectory: true)),
            claim(home.appendingPathComponent(".npm", isDirectory: true)),
            claim(home.appendingPathComponent(".cache", isDirectory: true)),
            claim(home.appendingPathComponent(".cargo", isDirectory: true)),
            claim(home.appendingPathComponent(".rustup", isDirectory: true)),
            claim(home.appendingPathComponent(".pub-cache", isDirectory: true)),
            claim(home.appendingPathComponent(".android", isDirectory: true)),
            claim(home.appendingPathComponent("Android", isDirectory: true)),
            claim(home.appendingPathComponent("UnrealEngine", isDirectory: true))
        ]

        var libraryExcluded = Set<String>()
        libraryExcluded.formUnion(cloudPaths.map { $0.resolvingSymlinksInPath().path })
        libraryExcluded.insert(library.appendingPathComponent("Developer", isDirectory: true).resolvingSymlinksInPath().path)

        var specs: [UsageRootSpec] = [
            UsageRootSpec(url: claim(URL(fileURLWithPath: "/Applications", isDirectory: true)), category: .applications, excludedCanonicalPaths: []),
            UsageRootSpec(url: claim(home.appendingPathComponent("Applications", isDirectory: true)), category: .applications, excludedCanonicalPaths: []),
            UsageRootSpec(url: claim(home.appendingPathComponent("Documents", isDirectory: true)), category: .documents, excludedCanonicalPaths: []),
            UsageRootSpec(url: claim(home.appendingPathComponent("Downloads", isDirectory: true)), category: .downloads, excludedCanonicalPaths: []),
            UsageRootSpec(url: claim(home.appendingPathComponent("Desktop", isDirectory: true)), category: .desktop, excludedCanonicalPaths: []),
            UsageRootSpec(url: claim(home.appendingPathComponent("Movies", isDirectory: true)), category: .movies, excludedCanonicalPaths: []),
            UsageRootSpec(url: claim(home.appendingPathComponent("Music", isDirectory: true)), category: .music, excludedCanonicalPaths: []),
            UsageRootSpec(url: claim(home.appendingPathComponent("Pictures", isDirectory: true)), category: .pictures, excludedCanonicalPaths: []),
            UsageRootSpec(url: claim(library), category: .libraryData, excludedCanonicalPaths: libraryExcluded),
            UsageRootSpec(url: claim(home.appendingPathComponent(".Trash", isDirectory: true)), category: .trash, excludedCanonicalPaths: [])
        ]

        for dev in devPaths where fm.fileExists(atPath: dev.path) {
            specs.append(UsageRootSpec(url: dev, category: .developer, excludedCanonicalPaths: []))
        }
        for cloud in cloudPaths where fm.fileExists(atPath: cloud.path) {
            specs.append(UsageRootSpec(url: cloud, category: .cloudLocal, excludedCanonicalPaths: []))
        }

        // Remaining top-level folders in Home so hidden disk hogs (e.g. Parallels, Spitfire, Kontakt caches, VMs) show up automatically
        if let homeChildren = try? fm.contentsOfDirectory(at: home, includingPropertiesForKeys: nil, options: []) {
            for child in homeChildren {
                let resolved = child.resolvingSymlinksInPath().path
                if claimedCanonicalPaths.contains(resolved) { continue }
                let name = child.lastPathComponent
                if name == ".DS_Store" || name == ".localized" || name == ".CFUserTextEncoding" { continue }
                if StorageUtilities.isSymlinkOrAlias(child) { continue }
                claimedCanonicalPaths.insert(resolved)
                specs.append(UsageRootSpec(url: child, category: .otherHome, excludedCanonicalPaths: []))
            }
        }

        for custom in customRoots {
            let resolved = custom.resolvingSymlinksInPath().path
            if !claimedCanonicalPaths.contains(resolved) {
                specs.append(UsageRootSpec(url: custom, category: .custom, excludedCanonicalPaths: []))
            }
        }

        return specs
    }

    private static func measureEntry(
        url: URL,
        category: DiskUsageCategory,
        subtitle: String,
        excluded: Set<String>,
        protected: Set<String>
    ) -> DiskUsageEntry? {
        let keys: Set<URLResourceKey> = [
            .isDirectoryKey,
            .isPackageKey,
            .isSymbolicLinkKey,
            .isAliasFileKey
        ]
        guard let values = try? url.resourceValues(forKeys: keys) else { return nil }
        if values.isSymbolicLink == true || values.isAliasFile == true { return nil }

        let stats = StorageUtilities.measureAllocatedSize(at: url, excludingCanonicalPaths: excluded)
        guard stats.allocatedBytes > 0 else { return nil }

        let canonical = url.resolvingSymlinksInPath().path
        return DiskUsageEntry(
            id: url.path,
            path: url.path,
            url: url,
            name: url.lastPathComponent,
            subtitle: subtitle,
            category: category,
            isDirectory: values.isDirectory == true,
            isPackage: values.isPackage == true,
            allocatedBytes: stats.allocatedBytes,
            fileCount: max(1, stats.fileCount),
            lastModified: stats.latestModified,
            canDelete: !protected.contains(canonical)
        )
    }

    private static func friendlyPath(_ path: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if path.hasPrefix(home) {
            return "~" + String(path.dropFirst(home.count))
        }
        return path
    }
}

// MARK: - ViewModel

struct DiskUsageBreadcrumb: Identifiable, Hashable {
    let id: String
    let title: String
    let url: URL?
    let category: DiskUsageCategory?
}

@MainActor
final class DiskUsageViewModel: ObservableObject {
    @Published private(set) var volumeSummary: VolumeSpaceSummary? = StorageUtilities.volumeSpaceSummary()
    @Published private(set) var categorySummaries: [DiskUsageCategorySummary] = []
    @Published private(set) var allTopEntries: [DiskUsageEntry] = []
    @Published private(set) var displayedEntries: [DiskUsageEntry] = []
    @Published private(set) var totalMeasuredBytes: Int64 = 0

    @Published var customRoots: [URL] = []
    @Published var selectedCategory: DiskUsageCategory? = nil {
        didSet {
            if drillStack.count <= 1 {
                rebuildDisplayedEntries()
            }
        }
    }
    @Published private(set) var drillStack: [DiskUsageBreadcrumb] = [
        DiskUsageBreadcrumb(id: "root", title: "All Areas", url: nil, category: nil)
    ]
    @Published var selectedIDs: Set<String> = []
    @Published var searchQuery: String = "" { didSet { rebuildDisplayedEntries() } }
    @Published var sortField: DiskUsageSortField = .size { didSet { rebuildDisplayedEntries() } }
    @Published var sortAscending: Bool = false { didSet { rebuildDisplayedEntries() } }
    @Published var moveToTrash: Bool = true

    @Published var isBusy: Bool = false
    @Published var progress: OperationProgress? = nil
    @Published var statusBanner: String? = nil
    @Published var showDeleteConfirm: Bool = false

    private let engine = DiskUsageEngine()
    private var directoryCache: [String: [DiskUsageEntry]] = [:]
    private var activeTask: Task<Void, Never>?
    private var lastAnchorID: String?

    var currentDirectoryTitle: String {
        drillStack.last?.title ?? "All Areas"
    }

    var currentViewTotalBytes: Int64 {
        let source = currentRawEntries
        return source.reduce(0) { $0 + $1.allocatedBytes }
    }

    private var currentRawEntries: [DiskUsageEntry] {
        if let currentURL = drillStack.last?.url {
            return directoryCache[currentURL.path] ?? []
        }
        if let selectedCategory {
            return allTopEntries.filter { $0.category == selectedCategory }
        }
        return allTopEntries
    }

    var selectedEntries: [DiskUsageEntry] {
        displayedEntries.filter { selectedIDs.contains($0.id) && $0.canDelete }
    }

    var selectedBytes: Int64 {
        selectedEntries.reduce(0) { $0 + $1.allocatedBytes }
    }

    var headerCheckState: NativeCheckState {
        let deletable = displayedEntries.filter(\.canDelete)
        guard !deletable.isEmpty else { return .off }
        let count = deletable.filter { selectedIDs.contains($0.id) }.count
        if count == 0 { return .off }
        if count == deletable.count { return .on }
        return .mixed
    }

    func addCustomFolderViaPanel() {
        let urls = StorageUtilities.chooseFolders(prompt: "Inspect Folder")
        for url in urls where !customRoots.contains(url) {
            customRoots.append(url)
        }
        if !urls.isEmpty {
            startOverviewScan()
        }
    }

    func startOverviewScan() {
        cancelCurrentTask()
        isBusy = true
        statusBanner = nil
        selectedIDs.removeAll()
        directoryCache.removeAll()
        drillStack = [DiskUsageBreadcrumb(id: "root", title: "All Areas", url: nil, category: nil)]
        progress = OperationProgress(
            phase: "Preparing disk space breakdown…",
            processedItems: 0,
            totalItems: 1,
            processedBytes: 0,
            totalBytes: 1,
            currentSubpath: ""
        )

        let roots = customRoots
        activeTask = Task { [weak self] in
            guard let self else { return }
            do {
                let result = try await engine.scanOverview(customRoots: roots) { [weak self] prog in
                    Task { @MainActor in
                        self?.progress = prog
                    }
                }
                self.volumeSummary = result.volumeSummary
                self.categorySummaries = result.categorySummaries
                self.allTopEntries = result.topLevelEntries
                self.totalMeasuredBytes = result.totalMeasuredBytes
                self.rebuildDisplayedEntries()
                self.progress = nil
                self.statusBanner = "Measured \(ByteFormatting.string(from: result.totalMeasuredBytes)) across \(result.topLevelEntries.count) top-level item(s)."
            } catch is CancellationError {
                self.progress = nil
                self.statusBanner = "Disk usage scan cancelled."
            } catch {
                self.progress = nil
                self.statusBanner = "Disk usage scan error: \(error.localizedDescription)"
            }
            self.isBusy = false
        }
    }

    func selectCategory(_ category: DiskUsageCategory?) {
        selectedCategory = category
        selectedIDs.removeAll()
        drillStack = [DiskUsageBreadcrumb(id: "root", title: "All Areas", url: nil, category: nil)]
        rebuildDisplayedEntries()
    }

    func drillInto(_ entry: DiskUsageEntry) {
        guard entry.canDrillDown else { return }
        selectedIDs.removeAll()
        let crumb = DiskUsageBreadcrumb(
            id: entry.path,
            title: entry.name,
            url: entry.url,
            category: entry.category
        )

        if let cached = directoryCache[entry.path] {
            drillStack.append(crumb)
            rebuildDisplayedEntries()
            if cached.isEmpty {
                statusBanner = "\(entry.name) contains no measurable non-symlink items."
            }
            return
        }

        cancelCurrentTask()
        isBusy = true
        progress = OperationProgress(
            phase: "Scanning \(entry.name)…",
            processedItems: 0,
            totalItems: 1,
            processedBytes: 0,
            totalBytes: 1,
            currentSubpath: entry.name
        )

        activeTask = Task { [weak self] in
            guard let self else { return }
            do {
                let children = try await engine.scanDirectoryChildren(at: entry.url, category: entry.category) { [weak self] prog in
                    Task { @MainActor in
                        self?.progress = prog
                    }
                }
                self.directoryCache[entry.path] = children
                self.drillStack.append(crumb)
                self.rebuildDisplayedEntries()
                self.progress = nil
            } catch is CancellationError {
                self.progress = nil
            } catch {
                self.progress = nil
                self.statusBanner = "Failed to inspect \(entry.name): \(error.localizedDescription)"
            }
            self.isBusy = false
        }
    }

    func navigateToBreadcrumb(_ crumb: DiskUsageBreadcrumb) {
        guard let idx = drillStack.firstIndex(of: crumb) else { return }
        selectedIDs.removeAll()
        drillStack = Array(drillStack.prefix(idx + 1))
        rebuildDisplayedEntries()
    }

    func toggleHeaderSelection() {
        let deletableIDs = Set(displayedEntries.filter(\.canDelete).map(\.id))
        guard !deletableIDs.isEmpty else { return }
        if deletableIDs.isSubset(of: selectedIDs) {
            selectedIDs.subtract(deletableIDs)
        } else {
            selectedIDs.formUnion(deletableIDs)
        }
    }

    func toggleSelection(for entry: DiskUsageEntry, shiftPressed: Bool) {
        guard entry.canDelete else { return }
        if shiftPressed, let anchorID = lastAnchorID,
           let start = displayedEntries.firstIndex(where: { $0.id == anchorID }),
           let end = displayedEntries.firstIndex(where: { $0.id == entry.id }) {
            let lower = min(start, end)
            let upper = max(start, end)
            let shouldSelect = !selectedIDs.contains(entry.id)
            for idx in lower...upper {
                let item = displayedEntries[idx]
                guard item.canDelete else { continue }
                if shouldSelect {
                    selectedIDs.insert(item.id)
                } else {
                    selectedIDs.remove(item.id)
                }
            }
            return
        }

        if selectedIDs.contains(entry.id) {
            selectedIDs.remove(entry.id)
        } else {
            selectedIDs.insert(entry.id)
        }
        lastAnchorID = entry.id
    }

    func clearSelection() {
        selectedIDs.removeAll()
        lastAnchorID = nil
    }

    func setSort(field: DiskUsageSortField) {
        if sortField == field {
            sortAscending.toggle()
        } else {
            sortField = field
            sortAscending = (field == .name || field == .category)
        }
    }

    func revealInFinder(_ entry: DiskUsageEntry) {
        NSWorkspace.shared.activateFileViewerSelecting([entry.url])
    }

    func deleteSelected() {
        let targets = selectedEntries
        guard !targets.isEmpty else { return }

        cancelCurrentTask()
        isBusy = true
        statusBanner = nil
        progress = OperationProgress(
            phase: moveToTrash ? "Moving selected items to Trash…" : "Deleting selected items…",
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
                let deletedPaths = Set(targets.filter { !FileManager.default.fileExists(atPath: $0.path) }.map(\.path))
                self.allTopEntries.removeAll { deletedPaths.contains($0.path) }
                for key in Array(self.directoryCache.keys) {
                    self.directoryCache[key]?.removeAll { deletedPaths.contains($0.path) }
                }
                self.selectedIDs.subtract(deletedPaths)
                self.volumeSummary = StorageUtilities.volumeSpaceSummary()
                self.rebuildDisplayedEntries()
                self.progress = nil

                var msg = "\(useTrash ? "Trashed" : "Deleted") \(summary.succeededCount) item(s), reclaiming \(ByteFormatting.string(from: summary.bytesAffected))."
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

    private func rebuildDisplayedEntries() {
        let q = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let filtered = currentRawEntries.filter { entry in
            if !q.isEmpty {
                let hay = "\(entry.name) \(entry.path)".lowercased()
                if !hay.contains(q) { return false }
            }
            return true
        }

        displayedEntries = filtered.sorted { lhs, rhs in
            let asc = sortAscending
            switch sortField {
            case .name:
                let cmp = lhs.name.localizedCaseInsensitiveCompare(rhs.name)
                if cmp != .orderedSame { return asc ? (cmp == .orderedAscending) : (cmp == .orderedDescending) }
            case .category:
                let cmp = lhs.category.rawValue.localizedCaseInsensitiveCompare(rhs.category.rawValue)
                if cmp != .orderedSame { return asc ? (cmp == .orderedAscending) : (cmp == .orderedDescending) }
            case .files:
                if lhs.fileCount != rhs.fileCount { return asc ? (lhs.fileCount < rhs.fileCount) : (lhs.fileCount > rhs.fileCount) }
            case .modified:
                let l = lhs.lastModified ?? .distantPast
                let r = rhs.lastModified ?? .distantPast
                if l != r { return asc ? (l < r) : (l > r) }
            case .size:
                if lhs.allocatedBytes != rhs.allocatedBytes { return asc ? (lhs.allocatedBytes < rhs.allocatedBytes) : (lhs.allocatedBytes > rhs.allocatedBytes) }
            }
            return lhs.allocatedBytes > rhs.allocatedBytes
        }
    }
}

// MARK: - View

struct DiskUsageWorkspace: View {
    @ObservedObject var vm: DiskUsageViewModel

    var body: some View {
        HSplitView {
            sidebar
                .frame(minWidth: 295, idealWidth: 320, maxWidth: 375)
                .background(Color(nsColor: .windowBackgroundColor))
            detailPane
                .frame(minWidth: 660, maxWidth: .infinity, maxHeight: .infinity)
        }
        .alert("Delete \(vm.selectedEntries.count) Item(s)?", isPresented: $vm.showDeleteConfirm) {
            Button("Cancel", role: .cancel) {}
            Button(vm.moveToTrash ? "Move to Trash" : "Delete Permanently", role: .destructive) {
                vm.deleteSelected()
            }
        } message: {
            Text("This will free \(ByteFormatting.string(from: vm.selectedBytes)).")
        }
    }

    private var sidebar: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                GroupBox("Disk Space Analyzer") {
                    VStack(alignment: .leading, spacing: 8) {
                        if let vol = vm.volumeSummary {
                            VStack(alignment: .leading, spacing: 4) {
                                HStack {
                                    Text("Macintosh HD")
                                        .font(.caption.weight(.semibold))
                                    Spacer()
                                    Text("\(ByteFormatting.string(from: vol.availableBytes)) free")
                                        .font(.caption.monospacedDigit())
                                        .foregroundStyle(.secondary)
                                }
                                GeometryReader { geo in
                                    ZStack(alignment: .leading) {
                                        RoundedRectangle(cornerRadius: 4)
                                            .fill(Color.secondary.opacity(0.2))
                                        RoundedRectangle(cornerRadius: 4)
                                            .fill(vol.usedFraction > 0.85 ? Color.red : Color.accentColor)
                                            .frame(width: max(6, geo.size.width * vol.usedFraction))
                                    }
                                }
                                .frame(height: 8)
                                Text("\(ByteFormatting.string(from: vol.usedBytes)) used of \(ByteFormatting.string(from: vol.totalBytes))")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                            .padding(.bottom, 4)
                        }

                        Button {
                            vm.startOverviewScan()
                        } label: {
                            Label(vm.allTopEntries.isEmpty ? "Analyze Disk Usage" : "Re-Scan Disk Usage", systemImage: "chart.pie.fill")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(vm.isBusy)

                        Button {
                            vm.addCustomFolderViaPanel()
                        } label: {
                            Label("Add Custom Folder…", systemImage: "folder.badge.plus")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .disabled(vm.isBusy)

                        Text("Measures physical APFS blocks: cloud placeholders report 0 B locally and never trigger downloads.")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(4)
                }

                GroupBox("Space by Area") {
                    VStack(alignment: .leading, spacing: 4) {
                        areaButton(
                            title: "All Areas",
                            icon: "square.grid.2x2.fill",
                            color: .accentColor,
                            bytes: vm.totalMeasuredBytes,
                            isSelected: vm.selectedCategory == nil && vm.drillStack.count == 1
                        ) {
                            vm.selectCategory(nil)
                        }

                        if vm.categorySummaries.isEmpty {
                            Text("Run Analyze Disk Usage to compare Applications, Documents, Downloads, Library, Developer & more.")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .padding(.top, 4)
                        } else {
                            ForEach(vm.categorySummaries) { summary in
                                areaButton(
                                    title: summary.category.rawValue,
                                    icon: summary.category.systemImage,
                                    color: summary.category.color,
                                    bytes: summary.allocatedBytes,
                                    isSelected: vm.selectedCategory == summary.category
                                ) {
                                    vm.selectCategory(vm.selectedCategory == summary.category ? nil : summary.category)
                                }
                            }
                        }
                    }
                    .padding(4)
                }

                GroupBox("Actions") {
                    VStack(alignment: .leading, spacing: 8) {
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

    private func areaButton(
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

            breadcrumbToolbar
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
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Space Consumers · \(vm.currentDirectoryTitle)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Text(ByteFormatting.string(from: vm.currentViewTotalBytes))
                            .font(.title2.bold())
                        if !vm.selectedEntries.isEmpty {
                            Text("\(vm.selectedEntries.count) selected · \(ByteFormatting.string(from: vm.selectedBytes))")
                                .font(.callout.weight(.semibold))
                                .foregroundStyle(Color.accentColor)
                        }
                    }
                }

                Spacer()

                if !vm.selectedEntries.isEmpty {
                    Button("Clear") {
                        vm.clearSelection()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }

                Button {
                    vm.showDeleteConfirm = true
                } label: {
                    Label(vm.moveToTrash ? "Move Selected to Trash" : "Delete Selected", systemImage: "trash.fill")
                }
                .buttonStyle(.borderedProminent)
                .tint(Color(red: 0.90, green: 0.24, blue: 0.30))
                .disabled(vm.isBusy || vm.selectedEntries.isEmpty)
            }

            categoryDistributionBar
        }
    }

    private var categoryDistributionBar: some View {
        VStack(alignment: .leading, spacing: 6) {
            GeometryReader { geo in
                let total = max(1, Double(vm.totalMeasuredBytes))
                HStack(spacing: 2) {
                    if vm.totalMeasuredBytes == 0 {
                        RoundedRectangle(cornerRadius: 4)
                            .fill(Color.secondary.opacity(0.18))
                    } else {
                        ForEach(vm.categorySummaries) { summary in
                            let width = max(4, (Double(summary.allocatedBytes) / total) * geo.size.width)
                            RoundedRectangle(cornerRadius: 3)
                                .fill(summary.category.color)
                                .frame(width: width)
                                .help("\(summary.category.rawValue): \(ByteFormatting.string(from: summary.allocatedBytes))")
                        }
                    }
                }
            }
            .frame(height: 10)
            .clipShape(RoundedRectangle(cornerRadius: 5))

            HStack(spacing: 12) {
                ForEach(vm.categorySummaries.prefix(5)) { summary in
                    HStack(spacing: 5) {
                        Circle()
                            .fill(summary.category.color)
                            .frame(width: 8, height: 8)
                        Text("\(summary.category.rawValue): \(ByteFormatting.compactMBGB(from: summary.allocatedBytes))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Text("Double-click any folder to drill down")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var breadcrumbToolbar: some View {
        HStack(spacing: 6) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    ForEach(Array(vm.drillStack.enumerated()), id: \.element.id) { idx, crumb in
                        if idx > 0 {
                            Image(systemName: "chevron.right")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(.secondary)
                        }
                        Button(crumb.title) {
                            vm.navigateToBreadcrumb(crumb)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .disabled(idx == vm.drillStack.count - 1 && vm.selectedCategory == nil)
                    }
                    if let selectedCategory = vm.selectedCategory, vm.drillStack.count == 1 {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.secondary)
                        Text(selectedCategory.rawValue)
                            .font(.caption.weight(.semibold))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(Capsule().fill(selectedCategory.color.opacity(0.18)))
                    }
                }
            }

            Spacer(minLength: 12)

            TextField("Filter items…", text: $vm.searchQuery)
                .textFieldStyle(.roundedBorder)
                .frame(width: 220)
        }
    }

    private var sortableHeader: some View {
        HStack(spacing: 10) {
            NativeCheckbox(state: vm.headerCheckState) { _ in
                vm.toggleHeaderSelection()
            }
            .frame(width: 20, height: 20)

            sortButton("Item", field: .name)
            Spacer()
            sortButton("Area", field: .category)
                .frame(width: 130, alignment: .leading)
            Text("Share")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(width: 96, alignment: .leading)
            sortButton("Files", field: .files)
                .frame(width: 68, alignment: .trailing)
            sortButton("Modified", field: .modified)
                .frame(width: 92, alignment: .trailing)
            sortButton("Size", field: .size)
                .frame(width: 88, alignment: .trailing)
            Text("Actions")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(width: 58, alignment: .center)
        }
    }

    private func sortButton(_ title: String, field: DiskUsageSortField) -> some View {
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
            if vm.allTopEntries.isEmpty && !vm.isBusy {
                VStack(spacing: 14) {
                    Image(systemName: "chart.pie.fill")
                        .font(.system(size: 46))
                        .foregroundStyle(.secondary)
                    Text("Understand What Takes Up Your Disk")
                        .font(.title3.bold())
                    Text("Scan Applications, Documents, Downloads, Desktop, Movies, Music, Pictures, Library App Data, Developer SDKs, and Cloud local caches to see exact APFS disk usage.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 480)
                    Button("Analyze Disk Usage") {
                        vm.startOverviewScan()
                    }
                    .buttonStyle(.borderedProminent)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                let totalView = max(1, Double(vm.currentViewTotalBytes))
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(vm.displayedEntries) { entry in
                            entryRow(entry, viewTotal: totalView)
                            Divider().opacity(0.35)
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
        }
    }

    private func entryRow(_ entry: DiskUsageEntry, viewTotal: Double) -> some View {
        let isSelected = vm.selectedIDs.contains(entry.id)
        let ratio = min(1.0, max(0.0, Double(entry.allocatedBytes) / viewTotal))
        return HStack(spacing: 10) {
            if entry.canDelete {
                NativeCheckbox(state: isSelected ? .on : .off) { shiftPressed in
                    vm.toggleSelection(for: entry, shiftPressed: shiftPressed)
                }
                .frame(width: 20, height: 20)
            } else {
                Image(systemName: "lock.shield")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .frame(width: 20, height: 20)
                    .help("Protected system root folder; drill down to delete items inside.")
            }

            Image(nsImage: IconCache.shared.icon(forPath: entry.path))
                .resizable()
                .frame(width: 22, height: 22)

            VStack(alignment: .leading, spacing: 2) {
                Text(entry.name)
                    .font(.callout.weight(.medium))
                    .lineLimit(1)
                Text(entry.subtitle)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .help(entry.path)

            Spacer(minLength: 8)

            HStack(spacing: 5) {
                Circle()
                    .fill(entry.category.color)
                    .frame(width: 7, height: 7)
                Text(entry.category.rawValue)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .frame(width: 130, alignment: .leading)

            HStack(spacing: 5) {
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        RoundedRectangle(cornerRadius: 3)
                            .fill(Color.secondary.opacity(0.16))
                        RoundedRectangle(cornerRadius: 3)
                            .fill(entry.category.color)
                            .frame(width: max(3, geo.size.width * ratio))
                    }
                }
                .frame(width: 54, height: 7)
                Text(String(format: "%.0f%%", ratio * 100))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .frame(width: 96, alignment: .leading)

            Text("\(entry.fileCount)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 68, alignment: .trailing)

            Text(Self.formatDate(entry.lastModified))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 92, alignment: .trailing)

            Text(ByteFormatting.string(from: entry.allocatedBytes))
                .font(.callout.monospacedDigit().weight(.medium))
                .frame(width: 88, alignment: .trailing)

            HStack(spacing: 2) {
                if entry.canDrillDown {
                    Button {
                        vm.drillInto(entry)
                    } label: {
                        Image(systemName: "chevron.right.circle")
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)
                            .frame(width: 26, height: 22)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.borderless)
                    .help("Open folder contents")
                } else {
                    Spacer().frame(width: 26, height: 22)
                }

                Button {
                    vm.revealInFinder(entry)
                } label: {
                    Image(systemName: "folder")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                        .frame(width: 26, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .help("Reveal in Finder")
            }
            .frame(width: 58, alignment: .center)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(isSelected ? Color.accentColor.opacity(0.10) : Color.clear)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) {
            if entry.canDrillDown {
                vm.drillInto(entry)
            }
        }
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
