#if canImport(SwiftUI)
import SwiftUI
import SearchCore

/// One result (design doc §2, P08): type badge, highlighted name, type · brand · room, online status,
/// power state and reason chips. Reasons always come from evidence, never from model text (P04).
public struct SearchResultRow: View {
    let result: SearchResult

    public init(result: SearchResult) {
        self.result = result
    }

    public var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Text(result.typeCode)
                .font(.caption.weight(.semibold))
                .frame(minWidth: 32, minHeight: 32)
                .background(.tint.opacity(0.15), in: RoundedRectangle(cornerRadius: 8))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(highlightedName).lineLimit(2)
                    if result.rankChange > 0 {
                        Image(systemName: "arrow.up").font(.caption2).foregroundStyle(.secondary)
                            .accessibilityHidden(true)
                    }
                }
                Text(meta).font(.footnote).foregroundStyle(.secondary)
                if !result.reasons.isEmpty {
                    HStack(spacing: 4) {
                        ForEach(result.reasons, id: \.self) { reason in
                            Text(reason.text)
                                .font(.caption2)
                                .padding(.horizontal, 6).padding(.vertical, 2)
                                .background(.quaternary, in: Capsule())
                        }
                    }
                }
            }
            Spacer(minLength: 0)
            statusView
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }

    private var meta: String {
        [result.typeLabel, result.device.manufacturer, result.device.room].compactMap { $0 }.filter { !$0.isEmpty }
            .joined(separator: " · ")
    }

    private var highlightedName: AttributedString {
        var name = AttributedString(result.device.name)
        let length = result.device.name.count
        for range in result.highlights where range.lowerBound >= 0 && range.upperBound <= length && range.lowerBound < range.upperBound {
            let lower = name.index(name.startIndex, offsetByCharacters: range.lowerBound)
            let upper = name.index(name.startIndex, offsetByCharacters: range.upperBound)
            name[lower..<upper].inlinePresentationIntent = .stronglyEmphasized
        }
        return name
    }

    @ViewBuilder private var statusView: some View {
        if let status = result.device.status {
            VStack(alignment: .trailing, spacing: 4) {
                Circle()
                    .fill(status.isOnline ? Color.green : Color.secondary)
                    .frame(width: 8, height: 8)
                    .accessibilityLabel(Text(status.isOnline ? "Online" : "Offline"))
                if let isOn = status.isOn {
                    Text(isOn ? "On" : "Off").font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
    }
}
#endif
