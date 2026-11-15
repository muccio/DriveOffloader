import AppKit
import SwiftUI
import UniformTypeIdentifiers

enum ThermalTier: String, CaseIterable {
    case hot = "Hot / Active"
    case warming = "Warming / Idle"
    case stale = "Stale"
    case cold = "Cold / Unused"

    static func from(score: Double) -> ThermalTier {
        switch score {
        case ..<0.25: return .hot
        case 0.25..<0.60: return .warming
        case 0.60..<0.85: return .stale
        default: return .cold
        }
    }

    var color: Color {
        switch self {
        case .hot: return Color(red: 0.06, green: 0.78, blue: 0.58)
        case .warming: return Color(red: 0.96, green: 0.74, blue: 0.14)
        case .stale: return Color(red: 0.96, green: 0.42, blue: 0.24)
        case .cold: return Color(red: 0.85, green: 0.12, blue: 0.56)
        }
    }
}

enum ThermalGradient {
    private static let stops: [(Double, (Double, Double, Double))] = [
        (0.00, (0.06, 0.78, 0.48)), // Emerald Green
        (0.25, (0.05, 0.78, 0.86)), // Cyan
        (0.42, (0.96, 0.78, 0.16)), // Amber / Yellow
        (0.60, (0.98, 0.56, 0.14)), // Orange
        (0.85, (0.94, 0.26, 0.28)), // Coral / Crimson
        (1.00, (0.82, 0.10, 0.62))  // Magenta Purple
    ]

    static func color(for score: Double) -> Color {
        let clamped = min(1.0, max(0.0, score))
        for index in 0..<(stops.count - 1) {
            let (p0, c0) = stops[index]
            let (p1, c1) = stops[index + 1]
            if clamped >= p0 && clamped <= p1 {
                let t = (clamped - p0) / max(0.0001, p1 - p0)
                let r = c0.0 + (c1.0 - c0.0) * t
                let g = c0.1 + (c1.1 - c0.1) * t
                let b = c0.2 + (c1.2 - c0.2) * t
                return Color(red: r, green: g, blue: b)
            }
        }
        return Color(red: 0.82, green: 0.10, blue: 0.62)
    }
}

enum ByteFormatting {
    static func string(from bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useMB, .useGB, .useTB, .useKB]
        formatter.countStyle = .file
        formatter.includesUnit = true
        formatter.isAdaptive = true
        return formatter.string(fromByteCount: bytes)
    }

    static func compactMBGB(from bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = bytes >= 1_073_741_824 ? [.useGB, .useTB] : [.useMB, .useKB]
        formatter.countStyle = .file
        formatter.includesUnit = true
        formatter.isAdaptive = true
        return formatter.string(fromByteCount: bytes)
    }
}

struct ThermalColorBar: View {
    let score: Double

    var body: some View {
        let barColor = ThermalGradient.color(for: score)
        RoundedRectangle(cornerRadius: 4, style: .continuous)
            .fill(
                LinearGradient(
                    colors: [barColor.opacity(0.85), barColor],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
            .frame(width: 8, height: 22)
            .overlay(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.18), lineWidth: 0.5)
            )
            .help("Coldness: \(Int((score * 100).rounded()))%")
    }
}

struct ItemKindBadge: View {
    let kind: ItemKind

    private var badgeColor: Color {
        switch kind {
        case .app: return .blue
        case .package: return .purple
        case .file: return .secondary
        }
    }

    var body: some View {
        Text(kind.rawValue)
            .font(.system(size: 9, weight: .bold, design: .rounded))
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(badgeColor.opacity(0.16), in: Capsule())
            .foregroundStyle(badgeColor)
    }
}

struct ThermalDistributionBar: View {
    let items: [ScannedItem]
    let dateMode: DateReferenceMode
    let thresholdDays: Int

    private var bucketCounts: [(ThermalTier, Int, Int64)] {
        var counts: [ThermalTier: (Int, Int64)] = [
            .hot: (0, 0),
            .warming: (0, 0),
            .stale: (0, 0),
            .cold: (0, 0)
        ]
        for item in items {
            let score = item.coldnessScore(for: dateMode, thresholdDays: thresholdDays)
            let tier = ThermalTier.from(score: score)
            let cur = counts[tier] ?? (0, 0)
            counts[tier] = (cur.0 + 1, cur.1 + item.sizeBytes)
        }
        return ThermalTier.allCases.map { tier in
            let v = counts[tier] ?? (0, 0)
            return (tier, v.0, v.1)
        }
    }

    var body: some View {
        let totalBytes = max(1, items.reduce(Int64(0)) { $0 + $1.sizeBytes })
        let buckets = bucketCounts

        VStack(alignment: .leading, spacing: 6) {
            GeometryReader { geo in
                HStack(spacing: 2) {
                    ForEach(buckets, id: \.0.rawValue) { tier, count, bytes in
                        if count > 0 {
                            let fraction = max(0.02, Double(bytes) / Double(totalBytes))
                            RoundedRectangle(cornerRadius: 3, style: .continuous)
                                .fill(tier.color)
                                .frame(width: max(6, geo.size.width * fraction - 2))
                                .help("\(tier.rawValue): \(count) items (\(ByteFormatting.string(from: bytes)))")
                        }
                    }
                    if items.isEmpty {
                        RoundedRectangle(cornerRadius: 3, style: .continuous)
                            .fill(Color.secondary.opacity(0.15))
                    }
                }
            }
            .frame(height: 10)
            .clipped()

            HStack(spacing: 14) {
                ForEach(buckets, id: \.0.rawValue) { tier, count, bytes in
                    HStack(spacing: 5) {
                        Circle()
                            .fill(tier.color)
                            .frame(width: 7, height: 7)
                        Text("\(tier.rawValue): \(count)")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        if bytes > 0 {
                            Text("(\(ByteFormatting.compactMBGB(from: bytes)))")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                    }
                }
            }
        }
    }
}

@MainActor
final class IconCache {
    static let shared = IconCache()
    private let cache = NSCache<NSString, NSImage>()

    private init() {
        cache.countLimit = 1000
    }

    func icon(for item: ScannedItem) -> NSImage {
        let key: String
        if item.kind == .file {
            let ext = item.url.pathExtension.lowercased()
            key = ext.isEmpty ? "path:\(item.path)" : "ext:\(ext)"
        } else {
            key = "path:\(item.path)"
        }

        if let cached = cache.object(forKey: key as NSString) {
            return cached
        }

        let image: NSImage
        if item.kind == .file {
            let ext = item.url.pathExtension
            if !ext.isEmpty, let type = UTType(filenameExtension: ext) {
                image = NSWorkspace.shared.icon(for: type)
            } else {
                image = NSWorkspace.shared.icon(forFile: item.path)
            }
        } else {
            image = NSWorkspace.shared.icon(forFile: item.path)
        }
        image.size = NSSize(width: 22, height: 22)
        cache.setObject(image, forKey: key as NSString)
        return image
    }

    func icon(forPath path: String) -> NSImage {
        let key = "path:\(path)" as NSString
        if let cached = cache.object(forKey: key) {
            return cached
        }
        let image = NSWorkspace.shared.icon(forFile: path)
        image.size = NSSize(width: 22, height: 22)
        cache.setObject(image, forKey: key)
        return image
    }
}

enum NativeCheckState: Equatable {
    case off
    case on
    case mixed

    var controlState: NSControl.StateValue {
        switch self {
        case .off: return .off
        case .on: return .on
        case .mixed: return .mixed
        }
    }
}

struct NativeCheckbox: NSViewRepresentable {
    let state: NativeCheckState
    let onToggle: (Bool) -> Void

    final class FirstMouseCheckbox: NSButton {
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    }

    final class Coordinator: NSObject {
        var onToggle: (Bool) -> Void

        init(onToggle: @escaping (Bool) -> Void) {
            self.onToggle = onToggle
        }

        @objc func handleClick(_ sender: NSButton) {
            let shift = NSEvent.modifierFlags.contains(.shift)
            onToggle(shift)
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(onToggle: onToggle)
    }

    func makeNSView(context: Context) -> FirstMouseCheckbox {
        let button = FirstMouseCheckbox(checkboxWithTitle: "", target: context.coordinator, action: #selector(Coordinator.handleClick(_:)))
        button.allowsMixedState = true
        button.isBordered = false
        button.setContentHuggingPriority(.required, for: .horizontal)
        button.setContentHuggingPriority(.required, for: .vertical)
        return button
    }

    func updateNSView(_ nsView: FirstMouseCheckbox, context: Context) {
        context.coordinator.onToggle = onToggle
        if nsView.state != state.controlState {
            nsView.state = state.controlState
        }
    }
}
