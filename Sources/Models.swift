import Foundation

enum DateReferenceMode: String, CaseIterable, Identifiable, Codable, Sendable {
    case lastOpened = "Last Opened"
    case lastModified = "Last Modified"
    case oldestOfBoth = "Oldest of Both"

    var id: String { rawValue }
}

enum LinkCreationMode: String, CaseIterable, Identifiable, Codable, Sendable {
    case offlineStub = "Offline Stub (Safe in Finder)"
    case noLink = "No Link (Archive Only)"
    case autoSmart = "Auto (Smart)"
    case finderAlias = "Finder Alias (May Re-download)"
    case posixSymlink = "POSIX Symlink (May Re-download)"

    var id: String { rawValue }
}

enum ViewDisplayMode: String, CaseIterable, Identifiable, Codable, Sendable {
    case folders = "Folders"
    case flat = "Flat List"

    var id: String { rawValue }
}

enum SortField: String, CaseIterable, Codable, Sendable {
    case heat
    case name
    case lastOpened
    case lastModified
    case inactive
    case size
}

enum ItemKind: String, Codable, Sendable, Comparable {
    case app = "APP"
    case package = "PKG"
    case file = "FILE"

    static func < (lhs: ItemKind, rhs: ItemKind) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

struct ScannedItem: Identifiable, Hashable, Codable, Sendable {
    let id: UUID
    let url: URL
    let scanRootURL: URL
    let relativeSubpath: String
    let name: String
    let kind: ItemKind
    let isPackage: Bool
    let sizeBytes: Int64
    let lastOpenedDate: Date?
    let lastModifiedDate: Date
    let lastAccessedDate: Date?
    let bundleIdentifier: String?

    var path: String { url.path }

    var relativeDirectoryComponents: [String] {
        let parts = relativeSubpath.split(separator: "/").map(String.init)
        guard parts.count > 1 else { return parts }
        return Array(parts.dropLast())
    }

    func referenceDate(for mode: DateReferenceMode) -> Date {
        switch mode {
        case .lastOpened:
            return lastOpenedDate ?? lastAccessedDate ?? lastModifiedDate
        case .lastModified:
            return lastModifiedDate
        case .oldestOfBoth:
            let opened = lastOpenedDate ?? lastAccessedDate ?? lastModifiedDate
            return min(opened, lastModifiedDate)
        }
    }

    func inactiveDays(for mode: DateReferenceMode, relativeTo now: Date = Date()) -> Int {
        let ref = referenceDate(for: mode)
        let days = Calendar.current.dateComponents([.day], from: ref, to: now).day ?? 0
        return max(0, days)
    }

    func coldnessScore(for mode: DateReferenceMode, thresholdDays: Int, relativeTo now: Date = Date()) -> Double {
        let days = Double(inactiveDays(for: mode, relativeTo: now))
        let threshold = max(1.0, Double(thresholdDays))
        let normalized = (days / threshold) * 0.85
        return min(1.0, max(0.0, normalized))
    }
}

struct FolderNode: Identifiable, Sendable {
    let id: String
    let name: String
    let fullPath: String
    let isRoot: Bool
    var childFolders: [FolderNode]
    var items: [ScannedItem]
    var itemCount: Int
    var totalSizeBytes: Int64
    var maxColdnessScore: Double
    var maxInactiveDays: Int
    var latestOpenedDate: Date?
    var latestModifiedDate: Date
    var descendantItemIDs: Set<UUID>
}

enum TreeRow: Identifiable, Sendable {
    case folder(FolderNode, depth: Int)
    case item(ScannedItem, depth: Int)

    var id: String {
        switch self {
        case .folder(let node, _): return "folder:\(node.id)"
        case .item(let item, _): return "item:\(item.id.uuidString)"
        }
    }
}

struct OperationProgress: Sendable {
    var phase: String
    var processedItems: Int
    var totalItems: Int
    var processedBytes: Int64
    var totalBytes: Int64
    var currentSubpath: String

    var fractionCompleted: Double {
        if totalBytes > 0 {
            return min(1.0, max(0.0, Double(processedBytes) / Double(totalBytes)))
        }
        if totalItems > 0 {
            return min(1.0, max(0.0, Double(processedItems) / Double(totalItems)))
        }
        return 0.0
    }

    var percentageInt: Int {
        Int((fractionCompleted * 100.0).rounded())
    }
}

struct ManifestEntry: Codable, Identifiable, Hashable, Sendable {
    let id: UUID
    let originalPath: String
    let driveArchivePath: String
    let scanRootPath: String
    let sizeBytes: Int64
    let isApplicationBundle: Bool
    let offloadDate: Date
    let linkType: String

    var itemName: String {
        URL(fileURLWithPath: originalPath).lastPathComponent
    }
}

enum CloudSyncStatus: Hashable, Sendable {
    case checking
    case syncedOnlineOnly
    case syncedCachedLocally
    case uploading(uploadedFiles: Int, totalFiles: Int)
    case error(String)
    case missingFromDrive
    case notCloudProvider

    var label: String {
        switch self {
        case .checking:
            return "Checking…"
        case .syncedOnlineOnly:
            return "Synced · Online Only"
        case .syncedCachedLocally:
            return "Synced · Local Cache"
        case .uploading(let done, let total):
            if total > 1 {
                return "Uploading (\(done)/\(total))"
            }
            return "Uploading…"
        case .error(let msg):
            return "Error: \(msg)"
        case .missingFromDrive:
            return "Missing in Drive"
        case .notCloudProvider:
            return "Local Folder"
        }
    }

    var isSynced: Bool {
        switch self {
        case .syncedOnlineOnly, .syncedCachedLocally:
            return true
        default:
            return false
        }
    }
}

struct OperationSummary: Sendable {
    let succeededCount: Int
    let failedCount: Int
    let bytesAffected: Int64
    let dryRun: Bool
    let errors: [String]
}

enum MinSizeFilter: Int64, CaseIterable, Identifiable, Sendable {
    case all = 0
    case mb10 = 10_485_760
    case mb50 = 52_428_800
    case mb100 = 104_857_600
    case mb500 = 524_288_000
    case gb1 = 1_073_741_824

    var id: Int64 { rawValue }

    var label: String {
        switch self {
        case .all: return "Any Size"
        case .mb10: return "≥ 10 MB"
        case .mb50: return "≥ 50 MB"
        case .mb100: return "≥ 100 MB"
        case .mb500: return "≥ 500 MB"
        case .gb1: return "≥ 1 GB"
        }
    }
}
