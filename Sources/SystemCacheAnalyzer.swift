import AppKit
import Foundation
import SwiftUI

enum SystemCacheCategory: String, CaseIterable, Identifiable, Codable, Sendable {
    case userCaches = "App Caches"
    case appSupportCaches = "App & IDE Caches"
    case developerCaches = "Dev & Package Caches"
    case logsAndDiagnostics = "Logs & Reports"
    case systemCaches = "System Caches"
    case trash = "Trash"

    var id: String { rawValue }

    var systemImage: String {
        switch self {
        case .userCaches: return "square.stack.3d.up.fill"
        case .appSupportCaches: return "app.dashed"
        case .developerCaches: return "hammer.fill"
        case .logsAndDiagnostics: return "doc.text.magnifyingglass"
        case .systemCaches: return "gearshape.2.fill"
        case .trash: return "trash.fill"
        }
    }

    var color: Color {
        switch self {
        case .userCaches: return Color(red: 0.14, green: 0.68, blue: 0.88)
        case .appSupportCaches: return Color(red: 0.48, green: 0.45, blue: 0.96)
        case .developerCaches: return Color(red: 0.08, green: 0.78, blue: 0.56)
        case .logsAndDiagnostics: return Color(red: 0.96, green: 0.68, blue: 0.16)
        case .systemCaches: return Color(red: 0.95, green: 0.40, blue: 0.28)
        case .trash: return Color(red: 0.84, green: 0.18, blue: 0.56)
        }
    }

    var shortDescription: String {
        switch self {
        case .userCaches: return "macOS & sandboxed app caches"
        case .appSupportCaches: return "Electron, IDE & browser data caches"
        case .developerCaches: return "npm, gradle, uv, Xcode & model caches"
        case .logsAndDiagnostics: return "Diagnostic logs & crash reports"
        case .systemCaches: return "Root-level /Library caches"
        case .trash: return "Items currently in your Trash"
        }
    }
}

enum CacheSafetyLevel: String, CaseIterable, Sendable {
    case safe = "Safe"
    case review = "Review"

    var color: Color {
        switch self {
        case .safe: return Color(red: 0.08, green: 0.78, blue: 0.54)
        case .review: return Color(red: 0.96, green: 0.66, blue: 0.14)
        }
    }

    var sortRank: Int {
        switch self {
        case .safe: return 0
        case .review: return 1
        }
    }
}

enum CacheSafetyFilter: String, CaseIterable, Identifiable {
    case all = "All Safety"
    case safeOnly = "Safe Only"
    case reviewOnly = "Review Only"

    var id: String { rawValue }
}

enum CacheMinSizeFilter: Int64, CaseIterable, Identifiable {
    case all = 0
    case mb1 = 1_048_576
    case mb10 = 10_485_760
    case mb50 = 52_428_800
    case mb100 = 104_857_600

    var id: Int64 { rawValue }

    var label: String {
        switch self {
        case .all: return "All Sizes"
        case .mb1: return "≥ 1 MB"
        case .mb10: return "≥ 10 MB"
        case .mb50: return "≥ 50 MB"
        case .mb100: return "≥ 100 MB"
        }
    }
}

enum CacheSortField: String, CaseIterable {
    case name
    case category
    case safety
    case modified
    case size
}

struct SystemCacheItem: Identifiable, Hashable, Sendable {
    let id: String
    let path: String
    let url: URL
    let name: String
    let detail: String
    let category: SystemCacheCategory
    let safety: CacheSafetyLevel
    let safetyNote: String
    let sizeBytes: Int64
    let fileCount: Int
    let lastModified: Date?
    let isDirectory: Bool
    let requiresAdminHint: Bool
}

private struct CacheTargetCandidate: Sendable {
    let url: URL
    let name: String
    let detail: String
    let category: SystemCacheCategory
    let safety: CacheSafetyLevel
    let safetyNote: String
    let requiresAdminHint: Bool
}

actor SystemCacheEngine {
    func scanSystemCaches(
        minSizeBytes: Int64 = 0,
        onProgress: @Sendable (OperationProgress) -> Void
    ) async throws -> [SystemCacheItem] {
        let candidates = discoverCandidates()
        let total = max(1, candidates.count)

        onProgress(
            OperationProgress(
                phase: "Discovering system & developer caches…",
                processedItems: 0,
                totalItems: total,
                processedBytes: 0,
                totalBytes: Int64(total),
                currentSubpath: ""
            )
        )

        var results: [SystemCacheItem] = []
        results.reserveCapacity(candidates.count)
        var processed = 0
        var totalFoundBytes: Int64 = 0

        let maxWorkers = 6
        var nextIndex = 0

        try await withThrowingTaskGroup(of: SystemCacheItem?.self) { group in
            let initialBatch = min(maxWorkers, candidates.count)
            for _ in 0..<initialBatch {
                let candidate = candidates[nextIndex]
                nextIndex += 1
                group.addTask {
                    try Task.checkCancellation()
                    return Self.measureCandidate(candidate, minSizeBytes: minSizeBytes)
                }
            }

            while let item = try await group.next() {
                try Task.checkCancellation()
                processed += 1

                if let item {
                    results.append(item)
                    totalFoundBytes += item.sizeBytes
                }

                if processed == candidates.count || processed % 6 == 0 {
                    let currentLabel = item?.name ?? ""
                    onProgress(
                        OperationProgress(
                            phase: "Measuring cache sizes (\(processed)/\(candidates.count))…",
                            processedItems: processed,
                            totalItems: total,
                            processedBytes: totalFoundBytes,
                            totalBytes: max(1, totalFoundBytes),
                            currentSubpath: currentLabel
                        )
                    )
                }

                if nextIndex < candidates.count {
                    let candidate = candidates[nextIndex]
                    nextIndex += 1
                    group.addTask {
                        try Task.checkCancellation()
                        return Self.measureCandidate(candidate, minSizeBytes: minSizeBytes)
                    }
                }
            }
        }

        return results.sorted { lhs, rhs in
            if lhs.sizeBytes != rhs.sizeBytes {
                return lhs.sizeBytes > rhs.sizeBytes
            }
            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
    }

    func deleteCacheItems(
        _ items: [SystemCacheItem],
        moveToTrash: Bool,
        onProgress: @Sendable (OperationProgress) -> Void
    ) async throws -> OperationSummary {
        let totalBytes = max(1, items.reduce(Int64(0)) { $0 + $1.sizeBytes })
        var processedItems = 0
        var processedBytes: Int64 = 0
        var succeeded = 0
        var failed = 0
        var freedBytes: Int64 = 0
        var errors: [String] = []
        var privilegedPending: [SystemCacheItem] = []

        let fm = FileManager.default
        let protectedRoots = Self.protectedRootPaths()

        for item in items {
            try Task.checkCancellation()

            onProgress(
                OperationProgress(
                    phase: moveToTrash && item.category != .trash ? "Moving cache to Trash…" : "Cleaning cache…",
                    processedItems: processedItems,
                    totalItems: max(1, items.count),
                    processedBytes: processedBytes,
                    totalBytes: totalBytes,
                    currentSubpath: item.name
                )
            )

            let canonical = item.url.resolvingSymlinksInPath().path
            if protectedRoots.contains(canonical) {
                failed += 1
                errors.append("Refused to delete protected path: \(item.path)")
                processedItems += 1
                processedBytes += item.sizeBytes
                continue
            }

            if !fm.fileExists(atPath: item.path) {
                succeeded += 1
                freedBytes += item.sizeBytes
                processedItems += 1
                processedBytes += item.sizeBytes
                continue
            }

            do {
                if moveToTrash && item.category != .trash && !item.requiresAdminHint {
                    var trashedURL: NSURL?
                    try fm.trashItem(at: item.url, resultingItemURL: &trashedURL)
                } else {
                    try fm.removeItem(at: item.url)
                }
                succeeded += 1
                freedBytes += item.sizeBytes
            } catch {
                let nsErr = error as NSError
                if StorageEngine.isPermissionError(nsErr) {
                    privilegedPending.append(item)
                } else {
                    failed += 1
                    errors.append("\(item.name): \(error.localizedDescription)")
                }
            }

            processedItems += 1
            processedBytes += item.sizeBytes
        }

        if !privilegedPending.isEmpty {
            try Task.checkCancellation()
            onProgress(
                OperationProgress(
                    phase: "Requesting admin authorization for protected caches…",
                    processedItems: processedItems,
                    totalItems: max(1, items.count),
                    processedBytes: processedBytes,
                    totalBytes: totalBytes,
                    currentSubpath: "\(privilegedPending.count) system/protected item(s)"
                )
            )

            let commands = privilegedPending.map { "rm -rf \(StorageEngine.shellEscaped($0.path))" }
            do {
                try await StorageEngine.runPrivilegedBatchScript(commands)
                for item in privilegedPending {
                    if fm.fileExists(atPath: item.path) {
                        failed += 1
                        errors.append("\(item.name): item still exists after admin removal.")
                    } else {
                        succeeded += 1
                        freedBytes += item.sizeBytes
                    }
                }
            } catch {
                failed += privilegedPending.count
                errors.append("Admin cleanup cancelled or failed: \(error.localizedDescription)")
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

    // MARK: - Candidate Discovery

    private func discoverCandidates() -> [CacheTargetCandidate] {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser
        let library = home.appendingPathComponent("Library", isDirectory: true)

        var candidates: [CacheTargetCandidate] = []
        var seenPaths = Set<String>()

        func appendCandidate(_ candidate: CacheTargetCandidate) {
            let resolved = candidate.url.resolvingSymlinksInPath().path
            guard seenPaths.insert(resolved).inserted else { return }
            guard fm.fileExists(atPath: candidate.url.path) else { return }
            guard !Self.isSymlinkOrAlias(candidate.url) else { return }
            candidates.append(candidate)
        }

        func appendChildren(
            of directoryURL: URL,
            detail: String,
            category: SystemCacheCategory,
            safety: CacheSafetyLevel,
            safetyNote: String,
            requiresAdminHint: Bool = false,
            excludedNames: Set<String> = [".DS_Store", ".localized"],
            safetyOverride: ((String) -> (CacheSafetyLevel, String))? = nil
        ) {
            guard fm.fileExists(atPath: directoryURL.path),
                  !Self.isSymlinkOrAlias(directoryURL),
                  let children = try? fm.contentsOfDirectory(
                    at: directoryURL,
                    includingPropertiesForKeys: [.isSymbolicLinkKey, .isAliasFileKey],
                    options: []
                  )
            else { return }

            for child in children {
                let name = child.lastPathComponent
                if excludedNames.contains(name) { continue }
                let (effectiveSafety, effectiveNote) = safetyOverride?(name) ?? (safety, safetyNote)
                appendCandidate(
                    CacheTargetCandidate(
                        url: child,
                        name: name,
                        detail: detail,
                        category: category,
                        safety: effectiveSafety,
                        safetyNote: effectiveNote,
                        requiresAdminHint: requiresAdminHint
                    )
                )
            }
        }

        // 1. User Caches (~/Library/Caches/*)
        let userCachesURL = library.appendingPathComponent("Caches", isDirectory: true)
        appendChildren(
            of: userCachesURL,
            detail: "~/Library/Caches",
            category: .userCaches,
            safety: .safe,
            safetyNote: "Standard macOS app cache. Applications recreate this automatically when needed.",
            excludedNames: [".DS_Store", ".localized", "CloudKit"]
        )

        // Sandboxed Container Caches (~/Library/Containers/<id>/Data/Library/Caches/*)
        let containersURL = library.appendingPathComponent("Containers", isDirectory: true)
        if let containers = try? fm.contentsOfDirectory(at: containersURL, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) {
            for container in containers {
                let cachesDir = container
                    .appendingPathComponent("Data", isDirectory: true)
                    .appendingPathComponent("Library", isDirectory: true)
                    .appendingPathComponent("Caches", isDirectory: true)
                appendChildren(
                    of: cachesDir,
                    detail: "Container · \(container.lastPathComponent)",
                    category: .userCaches,
                    safety: .safe,
                    safetyNote: "Sandboxed app container cache. Safely regenerated on next app launch."
                )
            }
        }

        // Group Container Caches (~/Library/Group Containers/<id>/Library/Caches/*)
        let groupContainersURL = library.appendingPathComponent("Group Containers", isDirectory: true)
        if let groups = try? fm.contentsOfDirectory(at: groupContainersURL, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) {
            for group in groups {
                let cachesDir = group
                    .appendingPathComponent("Library", isDirectory: true)
                    .appendingPathComponent("Caches", isDirectory: true)
                appendChildren(
                    of: cachesDir,
                    detail: "Group Container · \(group.lastPathComponent)",
                    category: .userCaches,
                    safety: .safe,
                    safetyNote: "Shared app group cache. Safely recreated by the owning apps."
                )
            }
        }

        // 2. App & IDE Caches under ~/Library/Application Support (strict cache-folder names only; NEVER touches DriveFS DBs!)
        let appSupportURL = library.appendingPathComponent("Application Support", isDirectory: true)
        let knownAppCacheSubpaths: [(subpath: String, displaySuffix: String, safety: CacheSafetyLevel, note: String)] = [
            ("CachedData", "V8/Electron CachedData", .safe, "Compiled bytecode cache recreated automatically on app launch."),
            ("Code Cache", "Chromium Code Cache", .safe, "JS/Wasm compilation cache recreated on demand."),
            ("GPUCache", "GPU Shader Cache", .safe, "GPU shader cache recreated automatically."),
            ("DawnCache", "WebGPU Dawn Cache", .safe, "WebGPU pipeline cache recreated automatically."),
            ("DawnGraphiteCache", "Graphite Shader Cache", .safe, "Renderer shader cache recreated automatically."),
            ("DawnWebGPUCache", "WebGPU Shader Cache", .safe, "WebGPU shader cache recreated automatically."),
            ("Cache", "App Disk Cache", .safe, "Application HTTP/disk cache recreated automatically."),
            ("Cache_Data", "Disk Cache Data", .safe, "Application disk cache recreated automatically."),
            ("Service Worker/CacheStorage", "Service Worker CacheStorage", .safe, "Offline webview cache storage recreated on use."),
            ("Service Worker/ScriptCache", "Service Worker ScriptCache", .safe, "Cached worker scripts recreated on use."),
            ("Crashpad", "Crashpad Dumps", .safe, "Crash reporter dump storage.")
        ]

        if let apps = try? fm.contentsOfDirectory(at: appSupportURL, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) {
            let protectedAppSupportRoots: Set<String> = [
                "Google", "MobileSync", "CloudDocs", "AddressBook", "CallHistoryDB",
                "Dock", "Knowledge", "com.apple.TCC", "FileProvider"
            ]
            for appDir in apps {
                let appName = appDir.lastPathComponent
                if protectedAppSupportRoots.contains(appName) { continue }
                for entry in knownAppCacheSubpaths {
                    let target = appDir.appendingPathComponent(entry.subpath, isDirectory: true)
                    appendCandidate(
                        CacheTargetCandidate(
                            url: target,
                            name: "\(appName) · \(entry.displaySuffix)",
                            detail: "~/Library/Application Support/\(appName)/\(entry.subpath)",
                            category: .appSupportCaches,
                            safety: entry.safety,
                            safetyNote: entry.note,
                            requiresAdminHint: false
                        )
                    )
                }
            }
        }

        // Explicit safe Google caches (NEVER scanning ~/Library/Application Support/Google/DriveFS/<account_id> DBs or content_cache)
        let explicitSafeTargets: [(relPath: String, name: String, detail: String, category: SystemCacheCategory, safety: CacheSafetyLevel, note: String)] = [
            ("Library/Application Support/Google/DriveFS/Logs", "Google Drive Logs", "~/Library/Application Support/Google/DriveFS/Logs", .logsAndDiagnostics, .safe, "Diagnostic text logs for Google Drive Desktop. Safe to clear; does not touch synced files or DB."),
            ("Library/Application Support/Google/DriveFS/cef_cache", "Google Drive Web Cache (cef_cache)", "~/Library/Application Support/Google/DriveFS/cef_cache", .appSupportCaches, .safe, "Embedded Chromium UI cache for Google Drive menu window. Recreated on launch."),
            ("Library/Application Support/Google/DriveFS/Crashpad", "Google Drive Crashpad", "~/Library/Application Support/Google/DriveFS/Crashpad", .logsAndDiagnostics, .safe, "Google Drive crash dump reports."),
            ("Library/Application Support/Google/DriveFS/canceled_uploads", "Google Drive Canceled Uploads", "~/Library/Application Support/Google/DriveFS/canceled_uploads", .appSupportCaches, .review, "Leftover canceled upload fragments in Google DriveFS."),
            ("Library/Application Support/Google/Chrome/Default/Service Worker/CacheStorage", "Chrome Service Worker Cache", "Chrome Default profile Service Worker CacheStorage", .appSupportCaches, .safe, "Web app cache storage in Chrome; does not delete bookmarks, history, or logins."),
            ("Library/Application Support/Google/Chrome/Default/Code Cache", "Chrome Code Cache", "Chrome JS/Wasm Code Cache", .appSupportCaches, .safe, "Chrome compiled script cache."),
            ("Library/Application Support/Google/Chrome/Default/GPUCache", "Chrome GPU Cache", "Chrome GPU shader cache", .appSupportCaches, .safe, "Chrome shader cache."),
            // Developer & Package Manager Caches
            (".npm", "npm Cache (~/.npm)", "Node.js npm package & _npx cache", .developerCaches, .safe, "Downloaded tarballs & _npx cache. Re-fetched automatically on next npm install."),
            (".gradle/caches", "Gradle Caches (~/.gradle/caches)", "Android / Java Gradle build & dependency caches", .developerCaches, .safe, "Gradle build artifacts & dependency jars. Re-downloaded when building Gradle projects."),
            (".gradle/wrapper/dists", "Gradle Wrapper Dists", "~/.gradle/wrapper/dists", .developerCaches, .safe, "Cached Gradle distributions re-downloaded on demand."),
            (".m2/repository", "Maven Repository (~/.m2/repository)", "Local Maven dependency cache", .developerCaches, .review, "Local Maven artifacts. Safe to delete, though projects will re-download dependencies."),
            (".cargo/registry/cache", "Rust Cargo Registry Cache", "~/.cargo/registry/cache", .developerCaches, .safe, "Compressed crate archives cached by Cargo."),
            (".cargo/registry/src", "Rust Cargo Extracted Sources", "~/.cargo/registry/src", .developerCaches, .safe, "Extracted crate sources unpacked by Cargo."),
            (".pub-cache", "Dart / Flutter Pub Cache", "~/.pub-cache", .developerCaches, .safe, "Downloaded Dart/Flutter packages. Re-downloaded via pub get."),
            (".yarn/cache", "Yarn Cache", "~/.yarn/cache", .developerCaches, .safe, "Yarn package archive cache."),
            (".pnpm-store", "pnpm Content-Addressable Store", "~/.pnpm-store", .developerCaches, .review, "Shared pnpm package store. Clearing reclaims disk space; pnpm will re-fetch packages on install."),
            (".cocoapods/repos", "CocoaPods Spec Repos", "~/.cocoapods/repos", .developerCaches, .safe, "Local CocoaPods spec clones."),
            ("Library/Caches/Homebrew", "Homebrew Download Cache", "~/Library/Caches/Homebrew", .developerCaches, .safe, "Old Homebrew bottles and installer downloads."),
            ("Library/Caches/pip", "pip HTTP Cache", "~/Library/Caches/pip", .developerCaches, .safe, "Python pip wheel & HTTP cache."),
            ("Library/Caches/CocoaPods", "CocoaPods Cache", "~/Library/Caches/CocoaPods", .developerCaches, .safe, "Downloaded iOS/macOS CocoaPods archives."),
            ("Library/Developer/CoreSimulator/Caches", "Xcode CoreSimulator Caches", "~/Library/Developer/CoreSimulator/Caches", .developerCaches, .safe, "Xcode Simulator dyld/runtime caches rebuilt automatically.")
        ]

        for spec in explicitSafeTargets {
            let url = home.appendingPathComponent(spec.relPath)
            appendCandidate(
                CacheTargetCandidate(
                    url: url,
                    name: spec.name,
                    detail: spec.detail,
                    category: spec.category,
                    safety: spec.safety,
                    safetyNote: spec.note,
                    requiresAdminHint: false
                )
            )
        }

        // ~/.cache/* (uv, puppeteer, huggingface, lm-studio, pip, etc.)
        let dotCacheURL = home.appendingPathComponent(".cache", isDirectory: true)
        appendChildren(
            of: dotCacheURL,
            detail: "~/.cache",
            category: .developerCaches,
            safety: .safe,
            safetyNote: "XDG cache directory recreated automatically on demand.",
            safetyOverride: { name in
                let lower = name.lowercased()
                let reviewMatches = ["huggingface", "lm-studio", "lmstudio", "ollama", "torch", "whisper", "puppeteer", "playwright", "ms-playwright", "models"]
                if reviewMatches.contains(where: { lower.contains($0) }) {
                    return (.review, "Large downloaded AI model or headless browser cache (~/.cache/\(name)). Deleting frees major space, but the tool will re-download it if needed.")
                }
                return (.safe, "Developer / CLI tool cache (~/.cache/\(name)). Safely regenerated automatically.")
            }
        )

        // Xcode DerivedData & iOS DeviceSupport children
        appendChildren(
            of: library.appendingPathComponent("Developer/Xcode/DerivedData", isDirectory: true),
            detail: "Xcode DerivedData",
            category: .developerCaches,
            safety: .safe,
            safetyNote: "Xcode intermediate build artifacts & indexes. Completely safe to delete; Xcode rebuilds on next build."
        )
        appendChildren(
            of: library.appendingPathComponent("Developer/Xcode/iOS DeviceSupport", isDirectory: true),
            detail: "Xcode iOS DeviceSupport",
            category: .developerCaches,
            safety: .review,
            safetyNote: "Debug symbols for connected iOS versions. Safe to delete for old iOS versions you no longer debug."
        )
        appendChildren(
            of: library.appendingPathComponent("Developer/Xcode/Archives", isDirectory: true),
            detail: "Xcode Archives",
            category: .developerCaches,
            safety: .review,
            safetyNote: "Built .xcarchive bundles. Review before deleting if you still need old App Store builds or dSYMs."
        )

        // 3. Logs & Diagnostics
        appendChildren(
            of: library.appendingPathComponent("Logs", isDirectory: true),
            detail: "~/Library/Logs",
            category: .logsAndDiagnostics,
            safety: .safe,
            safetyNote: "User application logs and diagnostic reports. Safe to remove."
        )

        // 4. System-wide Caches & Logs (/Library/Caches/*, /Library/Logs/*)
        appendChildren(
            of: URL(fileURLWithPath: "/Library/Caches", isDirectory: true),
            detail: "/Library/Caches",
            category: .systemCaches,
            safety: .review,
            safetyNote: "System-wide /Library cache. Usually safe to clear, and may prompt once for Administrator password.",
            requiresAdminHint: true
        )
        appendChildren(
            of: URL(fileURLWithPath: "/Library/Logs/DiagnosticReports", isDirectory: true),
            detail: "/Library/Logs/DiagnosticReports",
            category: .logsAndDiagnostics,
            safety: .safe,
            safetyNote: "System crash and diagnostic reports. Deleting may require Administrator authorization.",
            requiresAdminHint: true
        )

        // 5. Trash (~/.Trash/*)
        appendChildren(
            of: home.appendingPathComponent(".Trash", isDirectory: true),
            detail: "~/.Trash",
            category: .trash,
            safety: .review,
            safetyNote: "Already in your Trash. Cleaning permanently deletes this item and cannot be undone."
        )

        return candidates
    }

    // MARK: - Measurement Helpers

    private static func measureCandidate(_ candidate: CacheTargetCandidate, minSizeBytes: Int64) -> SystemCacheItem? {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: candidate.url.path, isDirectory: &isDir) else { return nil }

        let keys: [URLResourceKey] = [
            .totalFileAllocatedSizeKey,
            .isRegularFileKey,
            .isSymbolicLinkKey,
            .isAliasFileKey,
            .contentModificationDateKey
        ]

        var totalBytes: Int64 = 0
        var fileCount = 0
        var latestModified: Date?

        if let rootValues = try? candidate.url.resourceValues(forKeys: Set(keys)) {
            if rootValues.isSymbolicLink == true || rootValues.isAliasFile == true {
                return nil
            }
            if !isDir.boolValue {
                let bytes = Int64(rootValues.totalFileAllocatedSize ?? 0)
                totalBytes = bytes
                fileCount = 1
                latestModified = rootValues.contentModificationDate
            } else {
                latestModified = rootValues.contentModificationDate
            }
        }

        if isDir.boolValue {
            guard let enumerator = fm.enumerator(
                at: candidate.url,
                includingPropertiesForKeys: keys,
                options: [.skipsPackageDescendants],
                errorHandler: { _, _ in true }
            ) else {
                return nil
            }

            while let next = enumerator.nextObject() as? URL {
                guard let values = try? next.resourceValues(forKeys: Set(keys)) else { continue }
                if values.isSymbolicLink == true || values.isAliasFile == true {
                    enumerator.skipDescendants()
                    continue
                }
                if values.isRegularFile == true {
                    fileCount += 1
                    totalBytes += Int64(values.totalFileAllocatedSize ?? 0)
                    if let mod = values.contentModificationDate {
                        if let existing = latestModified {
                            if mod > existing { latestModified = mod }
                        } else {
                            latestModified = mod
                        }
                    }
                }
            }
        }

        guard totalBytes >= minSizeBytes, totalBytes > 0 else { return nil }

        return SystemCacheItem(
            id: candidate.url.path,
            path: candidate.url.path,
            url: candidate.url,
            name: candidate.name,
            detail: candidate.detail,
            category: candidate.category,
            safety: candidate.safety,
            safetyNote: candidate.safetyNote,
            sizeBytes: totalBytes,
            fileCount: max(1, fileCount),
            lastModified: latestModified,
            isDirectory: isDir.boolValue,
            requiresAdminHint: candidate.requiresAdminHint
        )
    }

    private static func isSymlinkOrAlias(_ url: URL) -> Bool {
        guard let values = try? url.resourceValues(forKeys: [.isSymbolicLinkKey, .isAliasFileKey]) else {
            return false
        }
        return values.isSymbolicLink == true || values.isAliasFile == true
    }

    private static func protectedRootPaths() -> Set<String> {
        let home = FileManager.default.homeDirectoryForCurrentUser.resolvingSymlinksInPath().path
        let library = "\(home)/Library"
        return [
            "/",
            "/Users",
            "/Library",
            "/Library/Caches",
            "/Library/Logs",
            "/Library/Application Support",
            home,
            library,
            "\(library)/Caches",
            "\(library)/Logs",
            "\(library)/Application Support",
            "\(library)/Application Support/Google",
            "\(library)/Application Support/Google/DriveFS",
            "\(home)/.Trash",
            "\(home)/.cache"
        ]
    }
}

// MARK: - ViewModel

@MainActor
final class SystemCacheViewModel: ObservableObject {
    @Published private(set) var items: [SystemCacheItem] = []
    @Published private(set) var visibleItems: [SystemCacheItem] = []
    @Published private(set) var categoryTotals: [(category: SystemCacheCategory, count: Int, bytes: Int64)] = []
    @Published var selectedIDs: Set<String> = []
    @Published var selectedCategory: SystemCacheCategory? = nil { didSet { rebuildVisibleItems() } }
    @Published var safetyFilter: CacheSafetyFilter = .all { didSet { rebuildVisibleItems() } }
    @Published var minSizeFilter: CacheMinSizeFilter = .mb1 { didSet { rebuildVisibleItems() } }
    @Published var searchQuery: String = "" { didSet { rebuildVisibleItems() } }
    @Published var sortField: CacheSortField = .size { didSet { rebuildVisibleItems() } }
    @Published var sortAscending: Bool = false { didSet { rebuildVisibleItems() } }
    @Published var moveToTrash: Bool = false

    @Published var isBusy: Bool = false
    @Published var progress: OperationProgress? = nil
    @Published var statusBanner: String? = nil
    @Published var showDeleteConfirm: Bool = false

    private let engine = SystemCacheEngine()
    private var activeTask: Task<Void, Never>?
    private var lastAnchorID: String?

    var totalBytes: Int64 {
        items.reduce(0) { $0 + $1.sizeBytes }
    }

    var selectedItems: [SystemCacheItem] {
        items.filter { selectedIDs.contains($0.id) }
    }

    var selectedBytes: Int64 {
        selectedItems.reduce(0) { $0 + $1.sizeBytes }
    }

    var safeBytes: Int64 {
        items.filter { $0.safety == .safe }.reduce(0) { $0 + $1.sizeBytes }
    }

    var reviewBytes: Int64 {
        items.filter { $0.safety == .review }.reduce(0) { $0 + $1.sizeBytes }
    }

    var headerCheckState: NativeCheckState {
        let visibleIDs = visibleItems.map(\.id)
        guard !visibleIDs.isEmpty else { return .off }
        let selectedCount = visibleIDs.filter { selectedIDs.contains($0) }.count
        if selectedCount == 0 { return .off }
        if selectedCount == visibleIDs.count { return .on }
        return .mixed
    }

    func toggleHeaderSelection() {
        let visibleIDs = Set(visibleItems.map(\.id))
        guard !visibleIDs.isEmpty else { return }
        if visibleIDs.isSubset(of: selectedIDs) {
            selectedIDs.subtract(visibleIDs)
        } else {
            selectedIDs.formUnion(visibleIDs)
        }
    }

    func toggleSelection(for item: SystemCacheItem, shiftPressed: Bool) {
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

    func selectAllSafe() {
        let safeIDs = visibleItems.filter { $0.safety == .safe }.map(\.id)
        selectedIDs.formUnion(safeIDs)
    }

    func selectAllVisible() {
        selectedIDs.formUnion(visibleItems.map(\.id))
    }

    func clearSelection() {
        selectedIDs.removeAll()
        lastAnchorID = nil
    }

    func setSort(field: CacheSortField) {
        if sortField == field {
            sortAscending.toggle()
        } else {
            sortField = field
            sortAscending = (field == .name || field == .category || field == .safety)
        }
    }

    func revealInFinder(_ item: SystemCacheItem) {
        NSWorkspace.shared.activateFileViewerSelecting([item.url])
    }

    func startScan() {
        cancelCurrentTask()
        isBusy = true
        statusBanner = nil
        progress = OperationProgress(
            phase: "Preparing system cache scan…",
            processedItems: 0,
            totalItems: 1,
            processedBytes: 0,
            totalBytes: 1,
            currentSubpath: ""
        )

        activeTask = Task { [weak self] in
            guard let self else { return }
            do {
                // Scan everything >= 512 KB so user can adjust Min Size filter live without re-scanning
                let scanned = try await engine.scanSystemCaches(minSizeBytes: 512_000) { [weak self] prog in
                    Task { @MainActor in
                        self?.progress = prog
                    }
                }
                self.items = scanned
                let validIDs = Set(scanned.map(\.id))
                self.selectedIDs.formIntersection(validIDs)
                self.rebuildCategoryTotals()
                self.rebuildVisibleItems()
                self.progress = nil
                self.statusBanner = "Analyzed \(scanned.count) cache target(s) totaling \(ByteFormatting.string(from: self.totalBytes)) on disk."
            } catch is CancellationError {
                self.progress = nil
                self.statusBanner = "System cache scan cancelled."
            } catch {
                self.progress = nil
                self.statusBanner = "Cache scan failed: \(error.localizedDescription)"
            }
            self.isBusy = false
        }
    }

    func cleanSelected() {
        let targets = selectedItems
        guard !targets.isEmpty else { return }

        cancelCurrentTask()
        isBusy = true
        statusBanner = nil
        progress = OperationProgress(
            phase: moveToTrash ? "Moving selected caches to Trash…" : "Cleaning selected caches…",
            processedItems: 0,
            totalItems: max(1, targets.count),
            processedBytes: 0,
            totalBytes: max(1, selectedBytes),
            currentSubpath: ""
        )

        let useTrash = moveToTrash
        activeTask = Task { [weak self] in
            guard let self else { return }
            do {
                let summary = try await engine.deleteCacheItems(targets, moveToTrash: useTrash) { [weak self] prog in
                    Task { @MainActor in
                        self?.progress = prog
                    }
                }

                let deletedSet = Set(targets.filter { !FileManager.default.fileExists(atPath: $0.path) }.map(\.id))
                self.items.removeAll { deletedSet.contains($0.id) }
                self.selectedIDs.subtract(deletedSet)
                self.rebuildCategoryTotals()
                self.rebuildVisibleItems()
                self.progress = nil

                var msg = "Cleaned \(summary.succeededCount) cache item(s), freeing \(ByteFormatting.string(from: summary.bytesAffected))."
                if summary.failedCount > 0 {
                    msg += " \(summary.failedCount) failed: \(summary.errors.first ?? "Unknown error")"
                }
                self.statusBanner = msg
            } catch is CancellationError {
                self.progress = nil
                self.statusBanner = "Cache cleanup cancelled."
            } catch {
                self.progress = nil
                self.statusBanner = "Cache cleanup error: \(error.localizedDescription)"
            }
            self.isBusy = false
        }
    }

    func cancelCurrentTask() {
        activeTask?.cancel()
        activeTask = nil
    }

    private func rebuildCategoryTotals() {
        var grouped: [SystemCacheCategory: (count: Int, bytes: Int64)] = [:]
        for item in items {
            let existing = grouped[item.category] ?? (0, 0)
            grouped[item.category] = (existing.count + 1, existing.bytes + item.sizeBytes)
        }
        categoryTotals = SystemCacheCategory.allCases.compactMap { category in
            let stats = grouped[category] ?? (0, 0)
            guard stats.count > 0 else { return nil }
            return (category, stats.count, stats.bytes)
        }
        .sorted { $0.bytes > $1.bytes }
    }

    private func rebuildVisibleItems() {
        let q = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let filtered = items.filter { item in
            if let selectedCategory, item.category != selectedCategory {
                return false
            }
            switch safetyFilter {
            case .all: break
            case .safeOnly:
                if item.safety != .safe { return false }
            case .reviewOnly:
                if item.safety != .review { return false }
            }
            if item.sizeBytes < minSizeFilter.rawValue {
                return false
            }
            if !q.isEmpty {
                let hay = "\(item.name) \(item.detail) \(item.path)".lowercased()
                if !hay.contains(q) { return false }
            }
            return true
        }

        visibleItems = filtered.sorted { lhs, rhs in
            let ascending = sortAscending
            switch sortField {
            case .name:
                let cmp = lhs.name.localizedCaseInsensitiveCompare(rhs.name)
                if cmp != .orderedSame {
                    return ascending ? (cmp == .orderedAscending) : (cmp == .orderedDescending)
                }
            case .category:
                let cmp = lhs.category.rawValue.localizedCaseInsensitiveCompare(rhs.category.rawValue)
                if cmp != .orderedSame {
                    return ascending ? (cmp == .orderedAscending) : (cmp == .orderedDescending)
                }
            case .safety:
                if lhs.safety.sortRank != rhs.safety.sortRank {
                    return ascending ? (lhs.safety.sortRank < rhs.safety.sortRank) : (lhs.safety.sortRank > rhs.safety.sortRank)
                }
            case .modified:
                let lDate = lhs.lastModified ?? .distantPast
                let rDate = rhs.lastModified ?? .distantPast
                if lDate != rDate {
                    return ascending ? (lDate < rDate) : (lDate > rDate)
                }
            case .size:
                if lhs.sizeBytes != rhs.sizeBytes {
                    return ascending ? (lhs.sizeBytes < rhs.sizeBytes) : (lhs.sizeBytes > rhs.sizeBytes)
                }
            }
            return lhs.sizeBytes > rhs.sizeBytes
        }
    }
}

// MARK: - Workspace View

struct SystemCacheWorkspace: View {
    @ObservedObject var vm: SystemCacheViewModel

    var body: some View {
        HSplitView {
            sidebar
                .frame(minWidth: 295, idealWidth: 320, maxWidth: 375)
                .background(Color(nsColor: .windowBackgroundColor))
            detailPane
                .frame(minWidth: 660, maxWidth: .infinity, maxHeight: .infinity)
        }
        .alert("Clean \(vm.selectedItems.count) Selected Cache Item(s)?", isPresented: $vm.showDeleteConfirm) {
            Button("Cancel", role: .cancel) {}
            Button(vm.moveToTrash ? "Move to Trash & Clean" : "Clean Permanently", role: .destructive) {
                vm.cleanSelected()
            }
        } message: {
            Text("This will reclaim up to \(ByteFormatting.string(from: vm.selectedBytes)). Active Google Drive sync databases and app preferences are excluded.")
        }
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                GroupBox("System Cache Scanner") {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Inspects macOS app caches, Electron/IDE caches, npm/Gradle/uv/Xcode caches, logs, and Trash using physical APFS allocation size.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)

                        Button {
                            vm.startScan()
                        } label: {
                            Label(vm.items.isEmpty ? "Analyze System Caches" : "Re-Scan System Caches", systemImage: "sparkles.rectangle.stack")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(vm.isBusy)

                        Text("Protected: Google Drive sync DB & content cache, Keychains, Preferences, and non-cache App Support files.")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(4)
                }

                GroupBox("Categories") {
                    VStack(alignment: .leading, spacing: 4) {
                        categoryFilterButton(
                            title: "All Categories",
                            icon: "tray.full.fill",
                            color: .accentColor,
                            count: vm.items.count,
                            bytes: vm.totalBytes,
                            isSelected: vm.selectedCategory == nil
                        ) {
                            vm.selectedCategory = nil
                        }

                        if vm.items.isEmpty {
                            Text("Run Analyze System Caches to inspect category breakdown.")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .padding(.top, 4)
                        } else {
                            ForEach(vm.categoryTotals, id: \.category) { entry in
                                categoryFilterButton(
                                    title: entry.category.rawValue,
                                    icon: entry.category.systemImage,
                                    color: entry.category.color,
                                    count: entry.count,
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

                GroupBox("Filters & Deletion Mode") {
                    VStack(alignment: .leading, spacing: 10) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Safety Filter")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Picker("Safety", selection: $vm.safetyFilter) {
                                ForEach(CacheSafetyFilter.allCases) { f in
                                    Text(f.rawValue).tag(f)
                                }
                            }
                            .labelsHidden()
                            .pickerStyle(.segmented)
                        }

                        HStack {
                            Text("Min Size")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Spacer()
                            Picker("Min Size", selection: $vm.minSizeFilter) {
                                ForEach(CacheMinSizeFilter.allCases) { f in
                                    Text(f.label).tag(f)
                                }
                            }
                            .labelsHidden()
                            .frame(width: 130)
                        }

                        Toggle("Move to Trash (when possible)", isOn: $vm.moveToTrash)
                            .font(.caption)
                            .help("Unchecked permanently removes selected caches to reclaim disk space immediately. Trash & /Library/Caches are always removed directly.")
                    }
                    .padding(4)
                }
            }
            .padding(12)
        }
        .clipped()
    }

    private func categoryFilterButton(
        title: String,
        icon: String,
        color: Color,
        count: Int,
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
                if count > 0 {
                    Text("\(ByteFormatting.compactMBGB(from: bytes))")
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

    // MARK: - Detail Pane

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
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("System & Developer Cache Reclaimable Space")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("\(vm.selectedItems.count) selected")
                            .font(.headline)
                        Text(ByteFormatting.string(from: vm.selectedBytes))
                            .font(.title2.bold())
                            .foregroundStyle(vm.selectedBytes > 0 ? Color.accentColor : Color.secondary)
                        if vm.totalBytes > 0 {
                            let pct = Double(vm.selectedBytes) / Double(max(1, vm.totalBytes)) * 100.0
                            Text(String(format: "(%.1f%% of %@)", pct, ByteFormatting.string(from: vm.totalBytes)))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                Spacer()

                Button {
                    vm.showDeleteConfirm = true
                } label: {
                    Label(vm.moveToTrash ? "Trash Selected Caches" : "Clean Selected Caches", systemImage: "trash.slash.fill")
                }
                .buttonStyle(.borderedProminent)
                .tint(Color(red: 0.90, green: 0.24, blue: 0.30))
                .controlSize(.large)
                .disabled(vm.isBusy || vm.selectedItems.isEmpty)
            }

            categoryDistributionBar
        }
    }

    private var categoryDistributionBar: some View {
        VStack(alignment: .leading, spacing: 6) {
            GeometryReader { geo in
                let total = max(1, Double(vm.totalBytes))
                HStack(spacing: 2) {
                    if vm.totalBytes == 0 {
                        RoundedRectangle(cornerRadius: 4)
                            .fill(Color.secondary.opacity(0.18))
                    } else {
                        ForEach(vm.categoryTotals, id: \.category) { entry in
                            let width = max(4, (Double(entry.bytes) / total) * geo.size.width)
                            RoundedRectangle(cornerRadius: 3)
                                .fill(entry.category.color)
                                .frame(width: width)
                        }
                    }
                }
            }
            .frame(height: 10)
            .clipShape(RoundedRectangle(cornerRadius: 5))

            HStack(spacing: 14) {
                legendBadge(color: CacheSafetyLevel.safe.color, title: "Safe: \(ByteFormatting.string(from: vm.safeBytes))")
                legendBadge(color: CacheSafetyLevel.review.color, title: "Review: \(ByteFormatting.string(from: vm.reviewBytes))")
                Spacer()
                Text("Showing \(vm.visibleItems.count) of \(vm.items.count) items")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func legendBadge(color: Color, title: String) -> some View {
        HStack(spacing: 5) {
            Circle()
                .fill(color)
                .frame(width: 8, height: 8)
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var quickToolbar: some View {
        HStack(spacing: 8) {
            Button("Select All Safe") {
                vm.selectAllSafe()
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(vm.visibleItems.isEmpty || vm.isBusy)

            Button("Select All Visible") {
                vm.selectAllVisible()
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

            TextField("Filter caches by name or path…", text: $vm.searchQuery)
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

            sortButton("Cache Item", field: .name)
            Spacer()
            sortButton("Category", field: .category)
                .frame(width: 140, alignment: .leading)
            sortButton("Safety", field: .safety)
                .frame(width: 72, alignment: .center)
            sortButton("Modified", field: .modified)
                .frame(width: 96, alignment: .trailing)
            sortButton("Size", field: .size)
                .frame(width: 88, alignment: .trailing)
            Text("Finder")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(width: 44, alignment: .center)
        }
    }

    private func sortButton(_ title: String, field: CacheSortField) -> some View {
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
                    Image(systemName: "externaldrive.badge.checkmark")
                        .font(.system(size: 46))
                        .foregroundStyle(.secondary)
                    Text("No System Caches Analyzed Yet")
                        .font(.title3.bold())
                    Text("Click \"Analyze System Caches\" in the sidebar to inspect macOS user caches, Electron/IDE caches, npm/Gradle/uv/Xcode caches, logs, and Trash.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 480)
                    Button("Analyze System Caches") {
                        vm.startScan()
                    }
                    .buttonStyle(.borderedProminent)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if vm.visibleItems.isEmpty && !vm.isBusy {
                VStack(spacing: 10) {
                    Image(systemName: "line.3.horizontal.decrease.circle")
                        .font(.system(size: 36))
                        .foregroundStyle(.secondary)
                    Text("No caches match your current filters")
                        .font(.headline)
                    Text("Try lowering the Min Size filter, choosing All Categories, or clearing the search query.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(vm.visibleItems) { item in
                            cacheRow(item)
                            Divider().opacity(0.35)
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
        }
    }

    private func cacheRow(_ item: SystemCacheItem) -> some View {
        let isSelected = vm.selectedIDs.contains(item.id)
        return HStack(spacing: 10) {
            NativeCheckbox(state: isSelected ? .on : .off) { shiftPressed in
                vm.toggleSelection(for: item, shiftPressed: shiftPressed)
            }
            .frame(width: 20, height: 20)

            Image(nsImage: IconCache.shared.icon(forPath: item.path))
                .resizable()
                .frame(width: 22, height: 22)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(item.name)
                        .font(.callout.weight(.medium))
                        .lineLimit(1)
                    if item.requiresAdminHint {
                        Image(systemName: "lock.fill")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .help("Requires Administrator authorization to delete.")
                    }
                }
                Text("\(item.detail) · \(item.fileCount) file(s)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .help(item.path)

            Spacer(minLength: 8)

            HStack(spacing: 5) {
                Circle()
                    .fill(item.category.color)
                    .frame(width: 7, height: 7)
                Text(item.category.rawValue)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .frame(width: 140, alignment: .leading)

            Text(item.safety.rawValue)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(item.safety.color)
                .padding(.horizontal, 8)
                .padding(.vertical, 2)
                .background(
                    Capsule()
                        .fill(item.safety.color.opacity(0.15))
                )
                .frame(width: 72, alignment: .center)
                .help(item.safetyNote)

            Text(Self.formatDate(item.lastModified))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 96, alignment: .trailing)

            Text(ByteFormatting.string(from: item.sizeBytes))
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
