import AppKit
import SwiftUI

@MainActor
final class DriveOffloaderViewModel: ObservableObject {
    @Published var scanRoots: [URL] = [] {
        didSet { persistSettings() }
    }
    @Published var driveRoot: URL? {
        didSet { persistSettings() }
    }
    @Published var items: [ScannedItem] = [] {
        didSet {
            rebuildDisplayCache()
            if !isRestoringState {
                let snapshot = items
                Task.detached(priority: .utility) {
                    StorageEngine.saveLastScanSync(snapshot)
                }
            }
        }
    }
    @Published var selectedIDs: Set<UUID> = [] {
        didSet {
            if !isRestoringState {
                let idSet = selectedIDs
                let paths = items.filter { idSet.contains($0.id) }.map(\.path)
                UserDefaults.standard.set(paths, forKey: DefaultsKeys.selectedPaths)
            }
        }
    }

    @Published var dateMode: DateReferenceMode = .lastOpened {
        didSet {
            rebuildDisplayCache()
            persistSettings()
        }
    }
    @Published var thresholdDays: Int = 180 {
        didSet {
            rebuildDisplayCache()
            persistSettings()
        }
    }
    @Published var minSizeFilter: MinSizeFilter = .mb10 {
        didSet { persistSettings() }
    }
    @Published var linkMode: LinkCreationMode = .offlineStub {
        didSet { persistSettings() }
    }
    @Published var preferSymlinkForPackagesInAuto: Bool = false {
        didSet { persistSettings() }
    }
    @Published var waitForCloudSyncBeforeDelete: Bool = true {
        didSet { persistSettings() }
    }
    @Published var dryRun: Bool = true {
        didSet { persistSettings() }
    }
    @Published var searchQuery: String = "" {
        didSet { rebuildDisplayCache() }
    }

    @Published var viewDisplayMode: ViewDisplayMode = .folders {
        didSet {
            rebuildDisplayCache()
            persistSettings()
        }
    }
    @Published var expandedFolderIDs: Set<String> = [] {
        didSet {
            rebuildDisplayCache()
            persistSettings()
        }
    }
    @Published var sortField: SortField = .size {
        didSet {
            rebuildDisplayCache()
            persistSettings()
        }
    }
    @Published var sortAscending: Bool = false {
        didSet {
            rebuildDisplayCache()
            persistSettings()
        }
    }

    @Published private(set) var cachedFilteredItems: [ScannedItem] = []
    @Published private(set) var cachedTreeRows: [TreeRow] = []
    @Published private(set) var cachedAllFolderIDs: Set<String> = []

    @Published var isBusy: Bool = false
    @Published var progress: OperationProgress?
    @Published var statusBanner: String?
    @Published var showRestoreSheet: Bool = false
    @Published var manifestEntries: [ManifestEntry] = []
    @Published var archiveSyncStatuses: [UUID: CloudSyncStatus] = [:]
    @Published var isCheckingSyncStatuses: Bool = false
    @Published var pendingArchivePaths: Set<String> = []

    private let engine = StorageEngine()
    private var activeTask: Task<Void, Never>?
    private var syncCheckTask: Task<Void, Never>?
    private var lastClickedID: UUID?
    private var isRestoringState = false

    private enum DefaultsKeys {
        static let scanRoots = "DriveOffloader.scanRoots"
        static let driveRoot = "DriveOffloader.driveRoot"
        static let dateMode = "DriveOffloader.dateMode"
        static let thresholdDays = "DriveOffloader.thresholdDays"
        static let minSizeFilter = "DriveOffloader.minSizeFilter"
        static let linkMode = "DriveOffloader.linkModeV2"
        static let preferSymlink = "DriveOffloader.preferSymlinkForPackagesInAutoV2"
        static let waitForSync = "DriveOffloader.waitForCloudSyncBeforeDelete"
        static let dryRun = "DriveOffloader.dryRun"
        static let viewMode = "DriveOffloader.viewDisplayMode"
        static let expandedFolders = "DriveOffloader.expandedFolderIDs"
        static let sortField = "DriveOffloader.sortField"
        static let sortAscending = "DriveOffloader.sortAscending"
        static let selectedPaths = "DriveOffloader.selectedPaths"
    }

    init() {
        restoreSettings()
        manifestEntries = StorageEngine.loadManifestSync()
        let drive = driveRoot
        Task.detached(priority: .userInitiated) { [weak self] in
            let savedItems = StorageEngine.loadLastScanSync()
            let pending = StorageEngine.findPendingArchivePaths(items: savedItems, driveRoot: drive)
            await MainActor.run { [weak self] in
                guard let self else { return }
                if !savedItems.isEmpty && self.items.isEmpty {
                    let savedSelectedPaths = Set(UserDefaults.standard.stringArray(forKey: DefaultsKeys.selectedPaths) ?? [])
                    self.isRestoringState = true
                    self.items = savedItems
                    self.selectedIDs = Set(savedItems.filter { savedSelectedPaths.contains($0.path) }.map(\.id))
                    self.isRestoringState = false
                    self.rebuildDisplayCache()
                }
                self.pendingArchivePaths = pending
            }
        }
    }

    private func restoreSettings() {
        isRestoringState = true
        defer { isRestoringState = false }

        let defaults = UserDefaults.standard
        if let rootPaths = defaults.stringArray(forKey: DefaultsKeys.scanRoots) {
            scanRoots = rootPaths.compactMap { path in
                var isDir: ObjCBool = false
                let url = URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
                return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) && isDir.boolValue ? url : nil
            }
        }

        if let savedDrive = defaults.string(forKey: DefaultsKeys.driveRoot),
           FileManager.default.fileExists(atPath: savedDrive) {
            driveRoot = URL(fileURLWithPath: savedDrive, isDirectory: true).standardizedFileURL
        } else {
            driveRoot = StorageEngine.discoverGoogleDriveRoot()
        }

        if let rawDate = defaults.string(forKey: DefaultsKeys.dateMode),
           let mode = DateReferenceMode(rawValue: rawDate) {
            dateMode = mode
        }
        if defaults.object(forKey: DefaultsKeys.thresholdDays) != nil {
            let days = defaults.integer(forKey: DefaultsKeys.thresholdDays)
            thresholdDays = min(730, max(7, days))
        }
        if defaults.object(forKey: DefaultsKeys.minSizeFilter) != nil,
           let filter = MinSizeFilter(rawValue: Int64(defaults.integer(forKey: DefaultsKeys.minSizeFilter))) {
            minSizeFilter = filter
        }
        if let rawLink = defaults.string(forKey: DefaultsKeys.linkMode),
           let mode = LinkCreationMode(rawValue: rawLink) {
            linkMode = mode
        }
        if defaults.object(forKey: DefaultsKeys.preferSymlink) != nil {
            preferSymlinkForPackagesInAuto = defaults.bool(forKey: DefaultsKeys.preferSymlink)
        }
        if defaults.object(forKey: DefaultsKeys.waitForSync) != nil {
            waitForCloudSyncBeforeDelete = defaults.bool(forKey: DefaultsKeys.waitForSync)
        }
        if defaults.object(forKey: DefaultsKeys.dryRun) != nil {
            dryRun = defaults.bool(forKey: DefaultsKeys.dryRun)
        }
        if let rawView = defaults.string(forKey: DefaultsKeys.viewMode),
           let mode = ViewDisplayMode(rawValue: rawView) {
            viewDisplayMode = mode
        }
        if let expanded = defaults.stringArray(forKey: DefaultsKeys.expandedFolders) {
            expandedFolderIDs = Set(expanded)
        }
        if let rawSort = defaults.string(forKey: DefaultsKeys.sortField),
           let field = SortField(rawValue: rawSort) {
            sortField = field
        }
        if defaults.object(forKey: DefaultsKeys.sortAscending) != nil {
            sortAscending = defaults.bool(forKey: DefaultsKeys.sortAscending)
        }
    }

    private func persistSettings() {
        guard !isRestoringState else { return }
        let defaults = UserDefaults.standard
        defaults.set(scanRoots.map(\.path), forKey: DefaultsKeys.scanRoots)
        defaults.set(driveRoot?.path, forKey: DefaultsKeys.driveRoot)
        defaults.set(dateMode.rawValue, forKey: DefaultsKeys.dateMode)
        defaults.set(thresholdDays, forKey: DefaultsKeys.thresholdDays)
        defaults.set(Int(minSizeFilter.rawValue), forKey: DefaultsKeys.minSizeFilter)
        defaults.set(linkMode.rawValue, forKey: DefaultsKeys.linkMode)
        defaults.set(preferSymlinkForPackagesInAuto, forKey: DefaultsKeys.preferSymlink)
        defaults.set(waitForCloudSyncBeforeDelete, forKey: DefaultsKeys.waitForSync)
        defaults.set(dryRun, forKey: DefaultsKeys.dryRun)
        defaults.set(viewDisplayMode.rawValue, forKey: DefaultsKeys.viewMode)
        defaults.set(Array(expandedFolderIDs), forKey: DefaultsKeys.expandedFolders)
        defaults.set(sortField.rawValue, forKey: DefaultsKeys.sortField)
        defaults.set(sortAscending, forKey: DefaultsKeys.sortAscending)
    }

    // MARK: - Filtering, Sorting & Folder Tree

    var filteredItems: [ScannedItem] { cachedFilteredItems }
    var treeRows: [TreeRow] { cachedTreeRows }
    var allFolderIDs: Set<String> { cachedAllFolderIDs }

    private func rebuildDisplayCache() {
        let base: [ScannedItem]
        let trimmed = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            base = items
        } else {
            let q = trimmed.lowercased()
            base = items.filter {
                $0.name.lowercased().contains(q) || $0.relativeSubpath.lowercased().contains(q)
            }
        }
        let sorted = sortItems(base)
        cachedFilteredItems = sorted

        if viewDisplayMode == .flat {
            cachedTreeRows = sorted.map { .item($0, depth: 0) }
            cachedAllFolderIDs = []
            return
        }

        let roots = buildFolderTree(from: sorted)
        var flattened: [TreeRow] = []
        var folderIDs = Set<String>()
        func appendRows(_ folder: FolderNode, depth: Int) {
            folderIDs.insert(folder.id)
            flattened.append(.folder(folder, depth: depth))
            let isExpanded = expandedFolderIDs.contains(folder.id)
            if isExpanded {
                for child in folder.childFolders {
                    appendRows(child, depth: depth + 1)
                }
                for item in folder.items {
                    flattened.append(.item(item, depth: depth + 1))
                }
            } else {
                func collectHidden(_ f: FolderNode) {
                    for c in f.childFolders {
                        folderIDs.insert(c.id)
                        collectHidden(c)
                    }
                }
                collectHidden(folder)
            }
        }
        for root in roots {
            appendRows(root, depth: 0)
        }
        cachedTreeRows = flattened
        cachedAllFolderIDs = folderIDs
    }

    func toggleSort(_ field: SortField) {
        if sortField == field {
            sortAscending.toggle()
        } else {
            sortField = field
            sortAscending = (field == .name)
        }
    }

    private func sortItems(_ list: [ScannedItem]) -> [ScannedItem] {
        let now = Date()
        return list.sorted { lhs, rhs in
            let asc: Bool
            switch sortField {
            case .heat:
                let ls = lhs.coldnessScore(for: dateMode, thresholdDays: thresholdDays, relativeTo: now)
                let rs = rhs.coldnessScore(for: dateMode, thresholdDays: thresholdDays, relativeTo: now)
                if ls != rs {
                    asc = ls < rs
                } else {
                    asc = lhs.sizeBytes < rhs.sizeBytes
                }
            case .name:
                let cmp = lhs.name.localizedStandardCompare(rhs.name)
                if cmp != .orderedSame {
                    asc = cmp == .orderedAscending
                } else {
                    asc = lhs.relativeSubpath.localizedStandardCompare(rhs.relativeSubpath) == .orderedAscending
                }
            case .lastOpened:
                let ld = lhs.lastOpenedDate ?? .distantPast
                let rd = rhs.lastOpenedDate ?? .distantPast
                if ld != rd {
                    asc = ld < rd
                } else {
                    asc = lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
                }
            case .lastModified:
                if lhs.lastModifiedDate != rhs.lastModifiedDate {
                    asc = lhs.lastModifiedDate < rhs.lastModifiedDate
                } else {
                    asc = lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
                }
            case .inactive:
                let li = lhs.inactiveDays(for: dateMode, relativeTo: now)
                let ri = rhs.inactiveDays(for: dateMode, relativeTo: now)
                if li != ri {
                    asc = li < ri
                } else {
                    asc = lhs.sizeBytes < rhs.sizeBytes
                }
            case .size:
                if lhs.sizeBytes != rhs.sizeBytes {
                    asc = lhs.sizeBytes < rhs.sizeBytes
                } else {
                    asc = lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
                }
            }
            return sortAscending ? asc : !asc
        }
    }

    private func sortFolders(_ list: [FolderNode]) -> [FolderNode] {
        list.sorted { lhs, rhs in
            let asc: Bool
            switch sortField {
            case .heat:
                if lhs.maxColdnessScore != rhs.maxColdnessScore {
                    asc = lhs.maxColdnessScore < rhs.maxColdnessScore
                } else {
                    asc = lhs.totalSizeBytes < rhs.totalSizeBytes
                }
            case .name:
                asc = lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
            case .lastOpened:
                let ld = lhs.latestOpenedDate ?? .distantPast
                let rd = rhs.latestOpenedDate ?? .distantPast
                if ld != rd {
                    asc = ld < rd
                } else {
                    asc = lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
                }
            case .lastModified:
                if lhs.latestModifiedDate != rhs.latestModifiedDate {
                    asc = lhs.latestModifiedDate < rhs.latestModifiedDate
                } else {
                    asc = lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
                }
            case .inactive:
                if lhs.maxInactiveDays != rhs.maxInactiveDays {
                    asc = lhs.maxInactiveDays < rhs.maxInactiveDays
                } else {
                    asc = lhs.totalSizeBytes < rhs.totalSizeBytes
                }
            case .size:
                if lhs.totalSizeBytes != rhs.totalSizeBytes {
                    asc = lhs.totalSizeBytes < rhs.totalSizeBytes
                } else {
                    asc = lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
                }
            }
            return sortAscending ? asc : !asc
        }
    }

    private func buildFolderTree(from sourceItems: [ScannedItem]) -> [FolderNode] {
        final class MutableFolder {
            let id: String
            let name: String
            let fullPath: String
            let isRoot: Bool
            var children: [String: MutableFolder] = [:]
            var directItems: [ScannedItem] = []

            init(id: String, name: String, fullPath: String, isRoot: Bool) {
                self.id = id
                self.name = name
                self.fullPath = fullPath
                self.isRoot = isRoot
            }
        }

        var rootBuckets: [String: MutableFolder] = [:]
        for item in sourceItems {
            let rootPath = item.scanRootURL.standardizedFileURL.path
            let rootName = item.scanRootURL.lastPathComponent.isEmpty ? rootPath : item.scanRootURL.lastPathComponent
            let rootFolder: MutableFolder
            if let existing = rootBuckets[rootPath] {
                rootFolder = existing
            } else {
                let created = MutableFolder(id: rootPath, name: rootName, fullPath: rootPath, isRoot: true)
                rootBuckets[rootPath] = created
                rootFolder = created
            }

            let dirComponents = item.relativeDirectoryComponents
            // Drop first component because it equals rootName
            let subComponents = dirComponents.count > 1 ? Array(dirComponents.dropFirst()) : []
            var current = rootFolder
            var runningPath = rootPath
            for comp in subComponents {
                runningPath += "/" + comp
                if let next = current.children[comp] {
                    current = next
                } else {
                    let created = MutableFolder(id: runningPath, name: comp, fullPath: runningPath, isRoot: false)
                    current.children[comp] = created
                    current = created
                }
            }
            current.directItems.append(item)
        }

        let now = Date()
        func freeze(_ node: MutableFolder) -> FolderNode {
            let frozenChildren = sortFolders(node.children.values.map(freeze))
            let sortedDirectItems = sortItems(node.directItems)

            var totalCount = sortedDirectItems.count
            var totalBytes: Int64 = sortedDirectItems.reduce(0) { $0 + $1.sizeBytes }
            var maxCold: Double = 0
            var maxDays: Int = 0
            var latestOpened: Date? = nil
            var latestModified: Date = .distantPast
            var ids = Set(sortedDirectItems.map(\.id))

            for item in sortedDirectItems {
                let score = item.coldnessScore(for: dateMode, thresholdDays: thresholdDays, relativeTo: now)
                let days = item.inactiveDays(for: dateMode, relativeTo: now)
                maxCold = max(maxCold, score)
                maxDays = max(maxDays, days)
                if let opened = item.lastOpenedDate {
                    latestOpened = max(latestOpened ?? .distantPast, opened)
                }
                latestModified = max(latestModified, item.lastModifiedDate)
            }

            for child in frozenChildren {
                totalCount += child.itemCount
                totalBytes += child.totalSizeBytes
                maxCold = max(maxCold, child.maxColdnessScore)
                maxDays = max(maxDays, child.maxInactiveDays)
                if let opened = child.latestOpenedDate {
                    latestOpened = max(latestOpened ?? .distantPast, opened)
                }
                latestModified = max(latestModified, child.latestModifiedDate)
                ids.formUnion(child.descendantItemIDs)
            }

            return FolderNode(
                id: node.id,
                name: node.name,
                fullPath: node.fullPath,
                isRoot: node.isRoot,
                childFolders: frozenChildren,
                items: sortedDirectItems,
                itemCount: totalCount,
                totalSizeBytes: totalBytes,
                maxColdnessScore: maxCold,
                maxInactiveDays: maxDays,
                latestOpenedDate: latestOpened,
                latestModifiedDate: latestModified,
                descendantItemIDs: ids
            )
        }

        return sortFolders(rootBuckets.values.map(freeze))
    }

    // MARK: - Computed Properties

    var driveArchiveDisplayPath: String {
        guard let driveRoot else { return "Not configured — click Choose…" }
        return driveRoot.appendingPathComponent(StorageEngine.archiveFolderName).path
    }

    var totalScannedBytes: Int64 {
        items.reduce(0) { $0 + $1.sizeBytes }
    }

    var selectedItems: [ScannedItem] {
        items.filter { selectedIDs.contains($0.id) }
    }

    var selectedCount: Int {
        selectedItems.count
    }

    var estimatedReclaimBytes: Int64 {
        selectedItems.reduce(0) { $0 + $1.sizeBytes }
    }

    var reclaimPercentage: Double {
        guard totalScannedBytes > 0 else { return 0 }
        return (Double(estimatedReclaimBytes) / Double(totalScannedBytes)) * 100.0
    }

    var cutoffDate: Date {
        get {
            Calendar.current.date(byAdding: .day, value: -thresholdDays, to: Date()) ?? Date()
        }
        set {
            let days = Calendar.current.dateComponents([.day], from: newValue, to: Date()).day ?? 180
            thresholdDays = min(730, max(1, days))
        }
    }

    // MARK: - Folder Pickers

    func addScanRootsViaPanel() {
        NSApp.activate(ignoringOtherApps: true)
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.prompt = "Add Folder(s)"
        panel.message = "Select folders to scan for cold files and applications."

        let handler: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard response == .OK else { return }
            Task { @MainActor in
                guard let self else { return }
                for url in panel.urls {
                    let standardized = url.standardizedFileURL
                    if !self.scanRoots.contains(where: { $0.standardizedFileURL == standardized }) {
                        self.scanRoots.append(standardized)
                    }
                }
            }
        }

        if let window = NSApp.keyWindow ?? NSApp.mainWindow {
            panel.beginSheetModal(for: window, completionHandler: handler)
        } else {
            panel.begin(completionHandler: handler)
        }
    }

    func addApplicationsPreset() {
        let appsURL = URL(fileURLWithPath: "/Applications", isDirectory: true).standardizedFileURL
        if !scanRoots.contains(where: { $0.standardizedFileURL == appsURL }) {
            scanRoots.append(appsURL)
        }
    }

    func removeScanRoot(_ url: URL) {
        let target = url.standardizedFileURL
        scanRoots.removeAll { $0.standardizedFileURL == target }
    }

    func clearScanRoots() {
        scanRoots.removeAll()
    }

    func chooseDriveRootViaPanel() {
        NSApp.activate(ignoringOtherApps: true)
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Select Google Drive Root"
        panel.message = "DriveOffloader will create DriveOffloader_Archive inside this folder."

        let handler: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            Task { @MainActor in
                self?.driveRoot = url.standardizedFileURL
            }
        }

        if let window = NSApp.keyWindow ?? NSApp.mainWindow {
            panel.beginSheetModal(for: window, completionHandler: handler)
        } else {
            panel.begin(completionHandler: handler)
        }
    }

    // MARK: - Selection & Folder Expand/Collapse

    func toggleSelection(for item: ScannedItem, isShiftPressed: Bool) {
        let visibleItems = treeRows.compactMap { row -> ScannedItem? in
            if case .item(let it, _) = row { return it }
            return nil
        }

        if isShiftPressed, let anchorID = lastClickedID,
           let anchorIdx = visibleItems.firstIndex(where: { $0.id == anchorID }),
           let targetIdx = visibleItems.firstIndex(where: { $0.id == item.id }) {
            let range = min(anchorIdx, targetIdx)...max(anchorIdx, targetIdx)
            for idx in range {
                selectedIDs.insert(visibleItems[idx].id)
            }
        } else {
            if selectedIDs.contains(item.id) {
                selectedIDs.remove(item.id)
            } else {
                selectedIDs.insert(item.id)
            }
            lastClickedID = item.id
        }
    }

    enum FolderSelectionState {
        case none, partial, all

        var nativeState: NativeCheckState {
            switch self {
            case .none: return .off
            case .partial: return .mixed
            case .all: return .on
            }
        }
    }

    func selectionState(for folder: FolderNode) -> FolderSelectionState {
        guard !folder.descendantItemIDs.isEmpty else { return .none }
        let selectedCount = folder.descendantItemIDs.intersection(selectedIDs).count
        if selectedCount == 0 { return .none }
        if selectedCount == folder.descendantItemIDs.count { return .all }
        return .partial
    }

    func toggleFolderSelection(_ folder: FolderNode) {
        switch selectionState(for: folder) {
        case .all:
            selectedIDs.subtract(folder.descendantItemIDs)
        case .none, .partial:
            selectedIDs.formUnion(folder.descendantItemIDs)
        }
    }

    func toggleFolderExpanded(_ folderID: String) {
        if expandedFolderIDs.contains(folderID) {
            expandedFolderIDs.remove(folderID)
        } else {
            expandedFolderIDs.insert(folderID)
        }
    }

    func expandAllFolders() {
        expandedFolderIDs = allFolderIDs
    }

    func collapseAllFolders() {
        expandedFolderIDs.removeAll()
    }

    func toggleSelectAllFiltered() {
        let visibleIDs = Set(filteredItems.map(\.id))
        guard !visibleIDs.isEmpty else { return }
        if visibleIDs.isSubset(of: selectedIDs) {
            selectedIDs.subtract(visibleIDs)
        } else {
            selectedIDs.formUnion(visibleIDs)
        }
    }

    func selectAllColdest() {
        let matching = items.filter { $0.inactiveDays(for: dateMode) >= thresholdDays }
        selectedIDs = Set(matching.map(\.id))
    }

    func selectUnusedApps() {
        let matching = items.filter {
            ($0.kind == .app || $0.kind == .package) && $0.inactiveDays(for: dateMode) > thresholdDays
        }
        selectedIDs = Set(matching.map(\.id))
    }

    func selectTop20Largest() {
        let top = items.sorted { $0.sizeBytes > $1.sizeBytes }.prefix(20)
        selectedIDs = Set(top.map(\.id))
    }

    func selectPendingInterrupted() {
        let matching = items.filter { pendingArchivePaths.contains($0.path) }
        selectedIDs = Set(matching.map(\.id))
    }

    func refreshPendingArchivePaths() {
        let currentItems = items
        let drive = driveRoot
        Task.detached(priority: .utility) { [weak self] in
            let pending = StorageEngine.findPendingArchivePaths(items: currentItems, driveRoot: drive)
            await MainActor.run { [weak self] in
                self?.pendingArchivePaths = pending
            }
        }
    }

    func clearSelection() {
        selectedIDs.removeAll()
        lastClickedID = nil
    }

    // MARK: - Async Engine Actions

    func startScan() {
        guard !scanRoots.isEmpty else {
            statusBanner = "Add at least one folder to scan."
            return
        }
        cancelCurrentTask()
        isBusy = true
        statusBanner = nil
        selectedIDs.removeAll()
        progress = OperationProgress(
            phase: "Starting scan…",
            processedItems: 0,
            totalItems: 0,
            processedBytes: 0,
            totalBytes: 0,
            currentSubpath: ""
        )

        let roots = scanRoots
        let minSize = minSizeFilter.rawValue
        let drive = driveRoot

        activeTask = Task {
            do {
                let scanned = try await engine.scan(
                    roots: roots,
                    minSizeBytes: minSize,
                    driveRoot: drive
                ) { [weak self] prog in
                    Task { @MainActor in
                        self?.progress = prog
                    }
                }
                self.items = scanned
                self.expandedFolderIDs = Set(roots.map { $0.standardizedFileURL.path })
                self.refreshPendingArchivePaths()
                self.statusBanner = "Scanned \(scanned.count) items (\(ByteFormatting.string(from: scanned.reduce(0) { $0 + $1.sizeBytes })))."
            } catch is CancellationError {
                self.statusBanner = "Scan cancelled."
            } catch {
                self.statusBanner = "Scan error: \(error.localizedDescription)"
            }
            self.isBusy = false
            self.progress = nil
        }
    }

    func startOffload() {
        guard let driveRoot else {
            statusBanner = "Please select a Google Drive root folder first."
            return
        }
        let targets = selectedItems
        guard !targets.isEmpty else {
            statusBanner = "Select at least one item to offload."
            return
        }

        cancelCurrentTask()
        isBusy = true
        statusBanner = nil

        let totalBytes = targets.reduce(Int64(0)) { $0 + $1.sizeBytes }
        progress = OperationProgress(
            phase: dryRun ? "Simulating offload…" : "Offloading to Google Drive…",
            processedItems: 0,
            totalItems: targets.count,
            processedBytes: 0,
            totalBytes: totalBytes,
            currentSubpath: ""
        )

        let linkMode = self.linkMode
        let preferSymlink = self.preferSymlinkForPackagesInAuto
        let waitForSync = self.waitForCloudSyncBeforeDelete
        let isDryRun = self.dryRun

        activeTask = Task {
            do {
                let summary = try await engine.offload(
                    items: targets,
                    driveRoot: driveRoot,
                    linkMode: linkMode,
                    preferSymlinkForPackagesInAuto: preferSymlink,
                    waitForCloudSyncBeforeDelete: waitForSync,
                    dryRun: isDryRun
                ) { [weak self] prog in
                    Task { @MainActor in
                        self?.progress = prog
                    }
                }

                if !isDryRun {
                    self.items.removeAll { item in
                        let vals = try? item.url.resourceValues(forKeys: [.isAliasFileKey, .isSymbolicLinkKey])
                        let isLink = vals?.isAliasFile == true || vals?.isSymbolicLink == true
                        let isStub = StorageEngine.isOfflineStubBundle(at: item.url)
                            || FileManager.default.fileExists(atPath: item.url.path + ".driveoffloader.command")
                        return isLink || isStub || !FileManager.default.fileExists(atPath: item.path)
                    }
                    self.selectedIDs = self.selectedIDs.intersection(Set(self.items.map(\.id)))
                    self.refreshManifest()
                    self.refreshPendingArchivePaths()
                }

                let prefix = summary.dryRun ? "[Dry Run] Simulated" : "Offloaded"
                var msg = "\(prefix) \(summary.succeededCount) item(s) (\(ByteFormatting.string(from: summary.bytesAffected)))."
                if summary.failedCount > 0 {
                    msg += " \(summary.failedCount) failed: \(summary.errors.first ?? "")"
                }
                self.statusBanner = msg
            } catch is CancellationError {
                self.statusBanner = "Offload cancelled."
            } catch {
                self.statusBanner = "Offload error: \(error.localizedDescription)"
            }
            self.isBusy = false
            self.progress = nil
        }
    }

    func refreshManifest() {
        manifestEntries = StorageEngine.loadManifestSync()
    }

    func cancelSyncCheck() {
        syncCheckTask?.cancel()
        syncCheckTask = nil
        isCheckingSyncStatuses = false
    }

    func refreshSyncStatuses() async {
        let entries = manifestEntries
        syncCheckTask?.cancel()
        guard !entries.isEmpty else {
            archiveSyncStatuses = [:]
            isCheckingSyncStatuses = false
            return
        }
        isCheckingSyncStatuses = true
        let task = Task.detached(priority: .utility) { [weak self] in
            await withTaskGroup(of: (UUID, CloudSyncStatus).self) { group in
                for entry in entries {
                    group.addTask {
                        if Task.isCancelled {
                            return (entry.id, .checking)
                        }
                        let status = StorageEngine.checkCloudSyncStatus(for: entry)
                        return (entry.id, status)
                    }
                }
                for await (id, status) in group {
                    if Task.isCancelled { break }
                    await MainActor.run { [weak self] in
                        self?.archiveSyncStatuses[id] = status
                    }
                }
            }
            await MainActor.run { [weak self] in
                guard !Task.isCancelled else { return }
                self?.isCheckingSyncStatuses = false
            }
        }
        syncCheckTask = task
        await task.value
    }

    func restoreEntries(_ entries: [ManifestEntry]) {
        guard !entries.isEmpty else { return }
        cancelCurrentTask()
        isBusy = true
        let totalBytes = entries.reduce(Int64(0)) { $0 + $1.sizeBytes }
        progress = OperationProgress(
            phase: "Restoring from Google Drive…",
            processedItems: 0,
            totalItems: entries.count,
            processedBytes: 0,
            totalBytes: totalBytes,
            currentSubpath: ""
        )

        activeTask = Task {
            do {
                let summary = try await engine.restore(entries: entries) { [weak self] prog in
                    Task { @MainActor in
                        self?.progress = prog
                    }
                }
                self.refreshManifest()
                self.refreshPendingArchivePaths()
                var msg = "Restored \(summary.succeededCount) item(s) (\(ByteFormatting.string(from: summary.bytesAffected)))."
                if summary.failedCount > 0 {
                    msg += " \(summary.failedCount) failed: \(summary.errors.first ?? "")"
                }
                self.statusBanner = msg
            } catch is CancellationError {
                self.statusBanner = "Restore cancelled."
            } catch {
                self.statusBanner = "Restore error: \(error.localizedDescription)"
            }
            self.isBusy = false
            self.progress = nil
        }
    }

    func clearLocalCache(
        entries: [ManifestEntry]? = nil,
        includeAllArchive: Bool = true,
        refreshSheetSync: Bool = false
    ) {
        let targetEntries = entries ?? manifestEntries
        guard driveRoot != nil || !targetEntries.isEmpty else {
            statusBanner = "Select a Google Drive root or offload items first."
            return
        }

        cancelCurrentTask()
        isBusy = true
        statusBanner = nil
        let estimatedTotal = targetEntries.reduce(Int64(0)) { $0 + $1.sizeBytes }
        progress = OperationProgress(
            phase: "Checking Google Drive local cache…",
            processedItems: 0,
            totalItems: max(1, targetEntries.count),
            processedBytes: 0,
            totalBytes: estimatedTotal,
            currentSubpath: ""
        )

        let drive = driveRoot
        activeTask = Task { [weak self] in
            guard let self else { return }
            do {
                let summary = try await engine.evictLocalCache(
                    entries: targetEntries,
                    driveRoot: drive,
                    includeAllInArchiveRoot: includeAllArchive
                ) { [weak self] prog in
                    Task { @MainActor in
                        self?.progress = prog
                    }
                }

                var msg: String
                if summary.bytesAffected > 0 {
                    msg = "Freed \(ByteFormatting.string(from: summary.bytesAffected)) of local Google Drive cache across \(summary.succeededCount) item(s)."
                } else if summary.failedCount == 0 {
                    msg = "Local Google Drive cache is already clear (all uploaded files are Online Only)."
                } else {
                    msg = "Local cache cleanup finished with \(summary.failedCount) error(s)."
                }
                if !summary.errors.isEmpty {
                    msg += " " + summary.errors.joined(separator: " ")
                }
                self.statusBanner = msg

                self.progress = nil
                if refreshSheetSync && !self.manifestEntries.isEmpty {
                    await self.refreshSyncStatuses()
                }
            } catch is CancellationError {
                self.statusBanner = "Local cache cleanup cancelled."
                self.progress = nil
            } catch {
                self.statusBanner = "Local cache cleanup error: \(error.localizedDescription)"
                self.progress = nil
            }
            self.isBusy = false
        }
    }

    func convertLinksToSafeStubs(refreshSheetSync: Bool = false) {
        cancelCurrentTask()
        isBusy = true
        statusBanner = nil
        progress = OperationProgress(
            phase: "Scanning for symlinks / aliases…",
            processedItems: 0,
            totalItems: max(1, manifestEntries.count),
            processedBytes: 0,
            totalBytes: Int64(max(1, manifestEntries.count)),
            currentSubpath: ""
        )

        let roots = scanRoots
        let drive = driveRoot

        activeTask = Task { [weak self] in
            guard let self else { return }
            do {
                let summary = try await engine.convertLinksToSafeStubs(
                    searchRoots: roots,
                    driveRoot: drive
                ) { [weak self] prog in
                    Task { @MainActor in
                        self?.progress = prog
                    }
                }
                self.refreshManifest()
                if summary.succeededCount > 0 {
                    var msg = "Converted \(summary.succeededCount) link(s) to Safe Offline Stubs (Finder hover will not trigger Google Drive downloads)."
                    if summary.failedCount > 0 {
                        msg += " \(summary.failedCount) failed: \(summary.errors.first ?? "")"
                    }
                    self.statusBanner = msg
                } else if summary.failedCount > 0 {
                    self.statusBanner = "Stub conversion error: \(summary.errors.first ?? "Unknown error")"
                } else {
                    self.statusBanner = "No Google Drive symlinks or aliases found to convert."
                }
                self.progress = nil
                if refreshSheetSync && !self.manifestEntries.isEmpty {
                    await self.refreshSyncStatuses()
                }
            } catch is CancellationError {
                self.statusBanner = "Link conversion cancelled."
                self.progress = nil
            } catch {
                self.statusBanner = "Link conversion error: \(error.localizedDescription)"
                self.progress = nil
            }
            self.isBusy = false
        }
    }

    func cancelCurrentTask() {
        activeTask?.cancel()
        activeTask = nil
    }
}

enum AppWorkspaceTab: String, CaseIterable, Identifiable {
    case offloader = "Drive Offloader"
    case systemCaches = "System Caches"

    var id: String { rawValue }
}

struct ContentView: View {
    @StateObject private var vm = DriveOffloaderViewModel()
    @StateObject private var cacheVM = SystemCacheViewModel()
    @State private var activeWorkspace: AppWorkspaceTab = .offloader

    var body: some View {
        VStack(spacing: 0) {
            workspaceSwitcherBar
                .zIndex(10)

            Divider()

            Group {
                switch activeWorkspace {
                case .offloader:
                    HSplitView {
                        sidebar
                            .frame(minWidth: 295, idealWidth: 320, maxWidth: 375)
                            .background(Color(nsColor: .windowBackgroundColor))
                        detailPane
                            .frame(minWidth: 660, maxWidth: .infinity, maxHeight: .infinity)
                    }
                case .systemCaches:
                    SystemCacheWorkspace(vm: cacheVM)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .sheet(isPresented: $vm.showRestoreSheet) {
            RestoreManagerSheet(vm: vm)
        }
    }

    private var workspaceSwitcherBar: some View {
        HStack(spacing: 12) {
            Picker("Workspace", selection: $activeWorkspace) {
                Label("Drive Offloader", systemImage: "icloud.and.arrow.up")
                    .tag(AppWorkspaceTab.offloader)
                Label("System Caches", systemImage: "internaldrive.fill")
                    .tag(AppWorkspaceTab.systemCaches)
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .frame(width: 320)

            Text(
                activeWorkspace == .offloader
                    ? "Offload cold apps & folders to Google Drive with local cache cleanup"
                    : "Inspect & safely clean macOS app, IDE, developer, log & Trash caches"
            )
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)

            Spacer()

            if activeWorkspace == .systemCaches && !cacheVM.items.isEmpty {
                Text("Total analyzed: \(ByteFormatting.string(from: cacheVM.totalBytes))")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.bar)
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                GroupBox("Scan Roots") {
                    VStack(alignment: .leading, spacing: 8) {
                        if vm.scanRoots.isEmpty {
                            Text("No folders selected. Add folders or /Applications.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        } else {
                            ForEach(vm.scanRoots, id: \.self) { root in
                                HStack(spacing: 6) {
                                    Image(systemName: root.path == "/Applications" ? "app.badge" : "folder.fill")
                                        .foregroundStyle(.secondary)
                                    Text(root.path)
                                        .font(.caption)
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                    Spacer()
                                    Button {
                                        vm.removeScanRoot(root)
                                    } label: {
                                        Image(systemName: "xmark.circle.fill")
                                            .font(.system(size: 14))
                                            .foregroundStyle(.secondary)
                                            .frame(width: 24, height: 24)
                                            .background(Color.black.opacity(0.001))
                                            .contentShape(Rectangle())
                                    }
                                    .buttonStyle(.borderless)
                                    .help("Remove folder")
                                }
                            }
                        }

                        HStack(spacing: 8) {
                            Button("Add Folder…") {
                                vm.addScanRootsViaPanel()
                            }
                            .buttonStyle(.bordered)
                            Button("/Applications") {
                                vm.addApplicationsPreset()
                            }
                            .buttonStyle(.bordered)
                            if !vm.scanRoots.isEmpty {
                                Button("Clear") {
                                    vm.clearScanRoots()
                                }
                                .buttonStyle(.bordered)
                            }
                        }
                        .controlSize(.small)

                        Button {
                            vm.startScan()
                        } label: {
                            Label("Scan Selected Roots", systemImage: "magnifyingglass")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(vm.isBusy || vm.scanRoots.isEmpty)
                    }
                    .padding(4)
                }

                GroupBox("Google Drive Archive") {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(vm.driveArchiveDisplayPath)
                            .font(.caption)
                            .foregroundStyle(vm.driveRoot == nil ? .orange : .secondary)
                            .lineLimit(3)
                            .truncationMode(.middle)

                        HStack(spacing: 8) {
                            Button("Choose Drive Root…") {
                                vm.chooseDriveRootViaPanel()
                            }
                            .buttonStyle(.bordered)

                            Button {
                                vm.clearLocalCache(entries: vm.manifestEntries, includeAllArchive: true)
                            } label: {
                                Label("Clear Cache", systemImage: "icloud.slash")
                            }
                            .buttonStyle(.bordered)
                            .disabled(vm.isBusy || (vm.driveRoot == nil && vm.manifestEntries.isEmpty))
                            .help("Evict local cached copies of files already uploaded to Google Drive (keeps cloud copies Online Only and frees disk space).")
                        }
                        .controlSize(.small)

                        Button {
                            vm.convertLinksToSafeStubs()
                        } label: {
                            Label("Links → Safe Stubs", systemImage: "shield.checkmark")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .disabled(vm.isBusy || (vm.manifestEntries.isEmpty && vm.driveRoot == nil))
                        .help("Replace existing POSIX symlinks / aliases (including in subfolders like /Applications/GDRIVE) with local Safe Offline Stubs so Finder never re-downloads on hover.")
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(4)
                }

                GroupBox("Thermal & Filter Rules") {
                    VStack(alignment: .leading, spacing: 10) {
                        Picker("Date Mode", selection: $vm.dateMode) {
                            ForEach(DateReferenceMode.allCases) { mode in
                                Text(mode.rawValue).tag(mode)
                            }
                        }
                        .pickerStyle(.menu)

                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text("Inactivity Threshold")
                                    .font(.caption)
                                Spacer()
                                Text("\(vm.thresholdDays) days")
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(.secondary)
                            }
                            Slider(
                                value: Binding(
                                    get: { Double(vm.thresholdDays) },
                                    set: { vm.thresholdDays = Int($0.rounded()) }
                                ),
                                in: 7...730,
                                step: 1
                            )
                            DatePicker(
                                "Cutoff",
                                selection: Binding(
                                    get: { vm.cutoffDate },
                                    set: { vm.cutoffDate = $0 }
                                ),
                                in: ...Date(),
                                displayedComponents: .date
                            )
                            .font(.caption)
                        }

                        Picker("Min Size", selection: $vm.minSizeFilter) {
                            ForEach(MinSizeFilter.allCases) { filter in
                                Text(filter.label).tag(filter)
                            }
                        }
                        .pickerStyle(.menu)
                    }
                    .padding(4)
                }

                GroupBox("Offload Link & Safety") {
                    VStack(alignment: .leading, spacing: 8) {
                        Picker("Link Mode", selection: $vm.linkMode) {
                            ForEach(LinkCreationMode.allCases) { mode in
                                Text(mode.rawValue).tag(mode)
                            }
                        }
                        .pickerStyle(.menu)

                        if vm.linkMode == .autoSmart {
                            Toggle("Use POSIX Symlink for .app (auto-downloads on hover)", isOn: $vm.preferSymlinkForPackagesInAuto)
                                .font(.caption)
                        }

                        Toggle("Wait for Google Drive upload", isOn: $vm.waitForCloudSyncBeforeDelete)
                            .font(.caption)
                            .help("Verify Google Drive File Provider finished uploading to the cloud before removing the local source file.")

                        Toggle("Dry Run (Simulate Only)", isOn: $vm.dryRun)
                            .font(.caption.weight(.semibold))
                            .tint(.orange)
                    }
                    .padding(4)
                }

                Button {
                    vm.refreshManifest()
                    vm.showRestoreSheet = true
                } label: {
                    Label("Restore Manager (\(vm.manifestEntries.count))", systemImage: "arrow.uturn.backward.circle")
                        .frame(maxWidth: .infinity)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
            }
            .padding(12)
        }
        .clipped()
    }

    // MARK: - Detail Pane

    private var detailPane: some View {
        VStack(spacing: 0) {
            topSummaryHeader
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .background(.bar)
                .zIndex(3)

            Divider()

            quickSelectionToolbar
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(.background)
                .zIndex(2)

            Divider()

            sortableTreeHeader
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
                    .foregroundStyle(.secondary)
                    .contentShape(Rectangle())
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(.bar)
                .zIndex(3)
            }
        }
    }

    private var topSummaryHeader: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 20) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Live Space Reclaim Estimator")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    HStack(alignment: .firstTextBaseline, spacing: 12) {
                        Text("\(vm.selectedCount) selected")
                            .font(.title3.bold().monospacedDigit())
                            .contentTransition(.numericText())
                        Text(ByteFormatting.string(from: vm.estimatedReclaimBytes))
                            .font(.title2.bold().monospacedDigit())
                            .foregroundStyle(vm.selectedCount > 0 ? Color.accentColor : Color.secondary)
                            .contentTransition(.numericText())
                        Text(String(format: "(%.1f%% of scanned)", vm.reclaimPercentage))
                            .font(.callout.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .contentTransition(.numericText())
                    }
                    .animation(.easeInOut(duration: 0.2), value: vm.selectedCount)
                    .animation(.easeInOut(duration: 0.2), value: vm.estimatedReclaimBytes)
                }

                Spacer()

                Button {
                    vm.startOffload()
                } label: {
                    Label(
                        vm.dryRun ? "Simulate Offload" : "Offload to Google Drive",
                        systemImage: vm.dryRun ? "wand.and.stars" : "icloud.and.arrow.up"
                    )
                }
                .buttonStyle(.borderedProminent)
                .tint(vm.dryRun ? .orange : .accentColor)
                .disabled(vm.isBusy || vm.selectedCount == 0 || vm.driveRoot == nil)
                .controlSize(.large)
            }

            ThermalDistributionBar(
                items: vm.items,
                dateMode: vm.dateMode,
                thresholdDays: vm.thresholdDays
            )
        }
    }

    private var quickSelectionToolbar: some View {
        HStack(spacing: 8) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    Picker("", selection: $vm.viewDisplayMode) {
                        ForEach(ViewDisplayMode.allCases) { mode in
                            Text(mode.rawValue).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 155)

                    if vm.viewDisplayMode == .folders && !vm.items.isEmpty {
                        Button("Expand All") {
                            vm.expandAllFolders()
                        }
                        Button("Collapse All") {
                            vm.collapseAllFolders()
                        }
                    }

                    Divider()
                        .frame(height: 16)

                    if !vm.pendingArchivePaths.isEmpty {
                        Button("Select Interrupted (\(vm.pendingArchivePaths.count))") {
                            vm.selectPendingInterrupted()
                        }
                        .tint(.orange)
                    }
                    Button("Select Coldest (≥ \(vm.thresholdDays)d)") {
                        vm.selectAllColdest()
                    }
                    Button("Unused Apps (> \(vm.thresholdDays)d)") {
                        vm.selectUnusedApps()
                    }
                    Button("Top 20 Largest") {
                        vm.selectTop20Largest()
                    }
                    Button("Clear") {
                        vm.clearSelection()
                    }
                    .disabled(vm.selectedIDs.isEmpty)
                }
            }
            .clipped()

            TextField("Filter by name or path…", text: $vm.searchQuery)
                .textFieldStyle(.roundedBorder)
                .frame(width: 195)
        }
        .controlSize(.small)
    }

    private var sortableTreeHeader: some View {
        let visibleIDs = Set(vm.filteredItems.map(\.id))
        let selectedInVisible = visibleIDs.intersection(vm.selectedIDs).count
        let headerCheckState: NativeCheckState = {
            if visibleIDs.isEmpty || selectedInVisible == 0 { return .off }
            if selectedInVisible == visibleIDs.count { return .on }
            return .mixed
        }()

        return HStack(spacing: 10) {
            NativeCheckbox(state: headerCheckState) { _ in
                vm.toggleSelectAllFiltered()
            }
            .frame(width: 26, height: 20)
            .help("Select / Deselect all visible")

            sortHeaderButton("Heat", field: .heat, width: 46, alignment: .leading)
            sortHeaderButton("Item & Folder", field: .name, width: nil, alignment: .leading)
            sortHeaderButton("Last Opened", field: .lastOpened, width: 105, alignment: .leading)
            sortHeaderButton("Last Modified", field: .lastModified, width: 105, alignment: .leading)
            sortHeaderButton("Inactive", field: .inactive, width: 72, alignment: .trailing)
            sortHeaderButton("Size", field: .size, width: 92, alignment: .trailing)
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(.secondary)
    }

    @ViewBuilder
    private func sortHeaderButton(
        _ title: String,
        field: SortField,
        width: CGFloat?,
        alignment: Alignment
    ) -> some View {
        let isActive = vm.sortField == field
        Button {
            vm.toggleSort(field)
        } label: {
            HStack(spacing: 4) {
                if alignment == .trailing { Spacer(minLength: 0) }
                Text(title)
                    .foregroundStyle(isActive ? Color.primary : Color.secondary)
                if isActive {
                    Image(systemName: vm.sortAscending ? "chevron.up" : "chevron.down")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(Color.accentColor)
                }
                if alignment == .leading { Spacer(minLength: 0) }
            }
            .frame(maxWidth: width == nil ? .infinity : width, alignment: alignment)
            .frame(height: 22)
            .background(Color.black.opacity(0.001))
            .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
    }

    private var itemsListView: some View {
        let rows = vm.treeRows
        return Group {
            if rows.isEmpty {
                ContentUnavailableView(
                    vm.items.isEmpty ? "Ready to Scan" : "No Matching Items",
                    systemImage: vm.items.isEmpty ? "externaldrive.badge.icloud" : "magnifyingglass",
                    description: Text(vm.items.isEmpty
                        ? "Add one or more folders in the sidebar and click Scan Selected Roots."
                        : "Try clearing the search filter or adjusting Min Size.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(rows) { row in
                            switch row {
                            case .folder(let folder, let depth):
                                FolderRowView(
                                    folder: folder,
                                    depth: depth,
                                    isExpanded: vm.expandedFolderIDs.contains(folder.id),
                                    selectionState: vm.selectionState(for: folder),
                                    onToggleExpand: { vm.toggleFolderExpanded(folder.id) },
                                    onToggleSelect: { vm.toggleFolderSelection(folder) }
                                )
                            case .item(let item, let depth):
                                ItemRowView(
                                    item: item,
                                    depth: depth,
                                    showSubpath: vm.viewDisplayMode == .flat,
                                    isSelected: vm.selectedIDs.contains(item.id),
                                    dateMode: vm.dateMode,
                                    thresholdDays: vm.thresholdDays,
                                    onToggleSelect: { shift in
                                        vm.toggleSelection(for: item, isShiftPressed: shift)
                                    }
                                )
                            }
                            Divider()
                                .opacity(0.4)
                        }
                    }
                }
                .clipped()
            }
        }
    }

    private func progressFooter(_ prog: OperationProgress) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(prog.phase)
                    .font(.caption.weight(.semibold))
                Spacer()
                Text("\(prog.percentageInt)%")
                    .font(.caption.monospacedDigit().weight(.bold))
                Button("Cancel") {
                    vm.cancelCurrentTask()
                }
                .controlSize(.small)
            }

            ProgressView(value: prog.fractionCompleted, total: 1.0)
                .progressViewStyle(.linear)

            HStack {
                Text("Processed \(prog.processedItems) of \(prog.totalItems) items")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
                Text("•")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                Text("Transferred \(ByteFormatting.compactMBGB(from: prog.processedBytes)) of \(ByteFormatting.compactMBGB(from: prog.totalBytes))")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
                Spacer()
                Text(prog.currentSubpath)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
    }
}

private struct FolderRowView: View {
    let folder: FolderNode
    let depth: Int
    let isExpanded: Bool
    let selectionState: DriveOffloaderViewModel.FolderSelectionState
    let onToggleExpand: () -> Void
    let onToggleSelect: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            NativeCheckbox(state: selectionState.nativeState) { _ in
                onToggleSelect()
            }
            .frame(width: 26, height: 28)

            ThermalColorBar(score: folder.maxColdnessScore)
                .frame(width: 46, alignment: .leading)

            Button(action: onToggleExpand) {
                HStack(spacing: 6) {
                    Color.clear
                        .frame(width: CGFloat(depth) * 18, height: 1)

                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(.secondary)
                        .frame(width: 20, height: 26)

                    Image(systemName: folder.isRoot ? "externaldrive.fill.badge.checkmark" : "folder.fill")
                        .font(.system(size: 15))
                        .foregroundStyle(folder.isRoot ? Color.accentColor : Color.blue)

                    VStack(alignment: .leading, spacing: 1) {
                        HStack(spacing: 6) {
                            Text(folder.name)
                                .font(.body.weight(.semibold))
                                .foregroundStyle(.primary)
                                .lineLimit(1)
                            Text("\(folder.itemCount) items")
                                .font(.caption2.monospacedDigit())
                                .padding(.horizontal, 6)
                                .padding(.vertical, 1)
                                .background(Color.secondary.opacity(0.14), in: Capsule())
                                .foregroundStyle(.secondary)
                        }
                        if folder.isRoot {
                            Text(folder.fullPath)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                    }

                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.black.opacity(0.001))
                .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)

            Group {
                if let opened = folder.latestOpenedDate {
                    Text(opened, format: .dateTime.year().month().day())
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                } else {
                    Text("—")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
            .frame(width: 105, alignment: .leading)

            Text(folder.latestModifiedDate, format: .dateTime.year().month().day())
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 105, alignment: .leading)

            Text("\(folder.maxInactiveDays) d")
                .font(.callout.monospacedDigit().weight(.medium))
                .foregroundStyle(ThermalGradient.color(for: folder.maxColdnessScore))
                .frame(width: 72, alignment: .trailing)

            Text(ByteFormatting.string(from: folder.totalSizeBytes))
                .font(.callout.monospacedDigit().weight(.semibold))
                .frame(width: 92, alignment: .trailing)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
        .background(folder.isRoot ? Color.accentColor.opacity(0.06) : Color.secondary.opacity(0.03))
    }
}

private struct ItemRowView: View {
    let item: ScannedItem
    let depth: Int
    let showSubpath: Bool
    let isSelected: Bool
    let dateMode: DateReferenceMode
    let thresholdDays: Int
    let onToggleSelect: (Bool) -> Void

    var body: some View {
        let score = item.coldnessScore(for: dateMode, thresholdDays: thresholdDays)
        let days = item.inactiveDays(for: dateMode)

        HStack(spacing: 10) {
            NativeCheckbox(state: isSelected ? .on : .off) { shift in
                onToggleSelect(shift)
            }
            .frame(width: 26, height: 28)

            ThermalColorBar(score: score)
                .frame(width: 46, alignment: .leading)

            HStack(spacing: 8) {
                if depth > 0 {
                    Color.clear
                        .frame(width: CGFloat(depth) * 18 + 20, height: 1)
                }

                Image(nsImage: IconCache.shared.icon(for: item))
                    .resizable()
                    .frame(width: 22, height: 22)

                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 5) {
                        Text(item.name)
                            .font(.body.weight(.medium))
                            .lineLimit(1)
                        ItemKindBadge(kind: item.kind)
                    }
                    if showSubpath {
                        Text(item.relativeSubpath)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Group {
                if let opened = item.lastOpenedDate {
                    Text(opened, format: .dateTime.year().month().day())
                        .font(.caption.monospacedDigit())
                } else {
                    Text("Never / Unknown")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
            .frame(width: 105, alignment: .leading)

            Text(item.lastModifiedDate, format: .dateTime.year().month().day())
                .font(.caption.monospacedDigit())
                .frame(width: 105, alignment: .leading)

            Text("\(days) d")
                .font(.callout.monospacedDigit().weight(.semibold))
                .foregroundStyle(ThermalGradient.color(for: score))
                .frame(width: 72, alignment: .trailing)

            Text(ByteFormatting.string(from: item.sizeBytes))
                .font(.callout.monospacedDigit())
                .frame(width: 92, alignment: .trailing)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
        .background(isSelected ? Color.accentColor.opacity(0.08) : Color.clear)
    }
}

struct RestoreManagerSheet: View {
    @ObservedObject var vm: DriveOffloaderViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var selectedEntryIDs: Set<UUID> = []

    private var syncSummaryText: String {
        guard !vm.manifestEntries.isEmpty else { return "No archived items." }
        var onlineOnly = 0
        var syncedLocal = 0
        var uploading = 0
        var issues = 0
        for entry in vm.manifestEntries {
            switch vm.archiveSyncStatuses[entry.id] ?? .checking {
            case .syncedOnlineOnly: onlineOnly += 1
            case .syncedCachedLocally: syncedLocal += 1
            case .uploading: uploading += 1
            case .error, .missingFromDrive: issues += 1
            case .checking, .notCloudProvider: break
            }
        }
        return "\(onlineOnly) online-only · \(syncedLocal) synced (cached) · \(uploading) uploading · \(issues) issues"
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Restore & Cloud Sync Manager")
                        .font(.title3.bold())
                    Text(syncSummaryText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if vm.isCheckingSyncStatuses {
                    ProgressView()
                        .controlSize(.small)
                }
                Button("Check Sync") {
                    vm.refreshManifest()
                    Task { await vm.refreshSyncStatuses() }
                }
                .controlSize(.small)
                .disabled(vm.isCheckingSyncStatuses)
                Button("Close") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
            }
            .padding(16)

            Divider()

            if vm.manifestEntries.isEmpty {
                ContentUnavailableView(
                    "No Offloaded Items",
                    systemImage: "tray",
                    description: Text("Items offloaded to Google Drive appear here with live cloud sync status and 1-click restore.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(vm.manifestEntries) { entry in
                            let selected = selectedEntryIDs.contains(entry.id)
                            let syncStatus = vm.archiveSyncStatuses[entry.id] ?? .checking
                            HStack(spacing: 10) {
                                NativeCheckbox(state: selected ? .on : .off) { _ in
                                    if selected {
                                        selectedEntryIDs.remove(entry.id)
                                    } else {
                                        selectedEntryIDs.insert(entry.id)
                                    }
                                }
                                .frame(width: 26, height: 28)

                                VStack(alignment: .leading, spacing: 2) {
                                    HStack(spacing: 6) {
                                        Text(entry.itemName)
                                            .font(.body.weight(.medium))
                                        Text(entry.isApplicationBundle ? "APP" : "ITEM")
                                            .font(.system(size: 9, weight: .bold))
                                            .padding(.horizontal, 5)
                                            .padding(.vertical, 1)
                                            .background(Color.blue.opacity(0.15), in: Capsule())
                                    }
                                    Text(entry.originalPath)
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)

                                CloudSyncBadge(status: syncStatus)
                                    .frame(width: 145, alignment: .leading)

                                Text(entry.linkType)
                                    .font(.caption)
                                    .frame(width: 90, alignment: .leading)

                                Text(entry.offloadDate, format: .dateTime.year().month().day())
                                    .font(.caption.monospacedDigit())
                                    .frame(width: 85, alignment: .leading)

                                Text(ByteFormatting.string(from: entry.sizeBytes))
                                    .font(.caption.monospacedDigit())
                                    .frame(width: 80, alignment: .trailing)
                            }
                            .padding(.horizontal, 14)
                            .padding(.vertical, 6)
                            Divider()
                                .opacity(0.4)
                        }
                    }
                }
                .clipped()
            }

            Divider()

            VStack(spacing: 8) {
                if let prog = vm.progress {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(prog.phase)
                                .font(.caption.weight(.medium))
                                .lineLimit(1)
                            Spacer()
                            Text("\(prog.processedItems)/\(prog.totalItems) · \(prog.currentSubpath)")
                                .font(.caption2.monospacedDigit())
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                            Button("Cancel") {
                                vm.cancelCurrentTask()
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.mini)
                        }
                        ProgressView(value: prog.fractionCompleted)
                            .progressViewStyle(.linear)
                    }
                    .padding(.horizontal, 14)
                    .padding(.top, 10)
                } else if let banner = vm.statusBanner {
                    HStack {
                        Image(systemName: "info.circle.fill")
                            .foregroundStyle(.blue)
                        Text(banner)
                            .font(.caption)
                            .lineLimit(2)
                        Spacer()
                    }
                    .padding(.horizontal, 14)
                    .padding(.top, 8)
                }

                HStack {
                    Button("Select All") {
                        selectedEntryIDs = Set(vm.manifestEntries.map(\.id))
                    }
                    .buttonStyle(.bordered)
                    .disabled(vm.manifestEntries.isEmpty)

                    Button("Clear") {
                        selectedEntryIDs.removeAll()
                    }
                    .buttonStyle(.bordered)
                    .disabled(selectedEntryIDs.isEmpty)

                    Spacer()

                    Button {
                        vm.convertLinksToSafeStubs(refreshSheetSync: true)
                    } label: {
                        Label("Links → Safe Stubs", systemImage: "shield.checkmark")
                    }
                    .buttonStyle(.bordered)
                    .disabled(vm.isBusy || (vm.manifestEntries.isEmpty && vm.driveRoot == nil))
                    .help("Replace existing symlinks / aliases with local Safe Offline Stubs so Finder hover never triggers Google Drive downloads.")

                    Button {
                        let targets = selectedEntryIDs.isEmpty
                            ? vm.manifestEntries
                            : vm.manifestEntries.filter { selectedEntryIDs.contains($0.id) }
                        vm.clearLocalCache(
                            entries: targets,
                            includeAllArchive: selectedEntryIDs.isEmpty,
                            refreshSheetSync: true
                        )
                    } label: {
                        Label(
                            selectedEntryIDs.isEmpty ? "Clear All Local Cache" : "Clear Cache (\(selectedEntryIDs.count))",
                            systemImage: "icloud.slash"
                        )
                    }
                    .buttonStyle(.bordered)
                    .disabled(vm.isBusy || (vm.manifestEntries.isEmpty && vm.driveRoot == nil))
                    .help("Evict local cached copies on Mac for uploaded items so they stay Online Only in Google Drive and free disk space.")

                    Button("Restore Selected (\(selectedEntryIDs.count))") {
                        let targets = vm.manifestEntries.filter { selectedEntryIDs.contains($0.id) }
                        vm.restoreEntries(targets)
                        selectedEntryIDs.removeAll()
                        dismiss()
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(vm.isBusy || selectedEntryIDs.isEmpty)
                }
                .padding(14)
            }
        }
        .frame(width: 900, height: 500)
        .task {
            await vm.refreshSyncStatuses()
        }
        .onDisappear {
            vm.cancelSyncCheck()
        }
    }
}

private struct CloudSyncBadge: View {
    let status: CloudSyncStatus

    private var color: Color {
        switch status {
        case .syncedOnlineOnly: return Color(red: 0.06, green: 0.78, blue: 0.58)
        case .syncedCachedLocally: return .blue
        case .uploading: return .orange
        case .error, .missingFromDrive: return .red
        case .checking, .notCloudProvider: return .secondary
        }
    }

    private var iconName: String {
        switch status {
        case .syncedOnlineOnly: return "icloud.fill"
        case .syncedCachedLocally: return "checkmark.icloud.fill"
        case .uploading: return "icloud.and.arrow.up"
        case .error, .missingFromDrive: return "exclamationmark.icloud.fill"
        case .checking: return "clock"
        case .notCloudProvider: return "folder"
        }
    }

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: iconName)
                .font(.system(size: 10))
            Text(status.label)
                .font(.caption2.weight(.semibold))
                .lineLimit(1)
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(color.opacity(0.14), in: Capsule())
        .foregroundStyle(color)
    }
}
