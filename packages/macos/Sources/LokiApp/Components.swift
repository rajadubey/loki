import AppKit
import LokiCore
import SwiftUI

// On the macOS 27 SDK, SwiftUI's @State and @Bindable are macros whose plugin ships only with
// Xcode. The app builds with the Command Line Tools too, so view state lives in @Observable
// classes and bindings are made with these helpers.

extension Binding {
    /// Binding to a property of an observable object.
    init<Root: AnyObject>(_ root: Root, _ keyPath: ReferenceWritableKeyPath<Root, Value>) {
        self.init(get: { root[keyPath: keyPath] }, set: { root[keyPath: keyPath] = $0 })
    }
}

extension Health {
    var color: Color {
        switch self {
        case .up: .green
        case .slow: .orange
        case .down: .red
        case .unknown: .gray
        }
    }
}

extension CheckState {
    var symbol: (name: String, color: Color) {
        switch self {
        case .ok: ("checkmark.circle.fill", .green)
        case .warning: ("exclamationmark.circle.fill", .orange)
        case .failed: ("xmark.circle.fill", .red)
        }
    }
}

func copyToClipboard(_ text: String) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(text, forType: .string)
}

func openURL(_ string: String) {
    if let url = URL(string: string) { NSWorkspace.shared.open(url) }
}

struct StatusDot: View {
    let color: Color
    var size: CGFloat = 7

    var body: some View {
        Circle().fill(color).frame(width: size, height: size).accessibilityHidden(true)
    }
}

/// Health ring: up, slow and down arcs with "N/M up" in the middle.
struct Ring: View {
    let up: Int, slow: Int, down: Int, total: Int

    var body: some View {
        let t = Double(max(total, 1))
        let u = Double(up) / t, s = Double(slow) / t, d = Double(down) / t
        ZStack {
            Circle().stroke(.quaternary, lineWidth: 9)
            arc(0, u, .green)
            arc(u, u + s, .orange)
            arc(u + s, u + s + d, .red)
            VStack(spacing: 0) {
                Text("\(up + slow)/\(total)").font(.system(size: 16, weight: .semibold)).monospacedDigit()
                Text("up").font(.caption2).foregroundStyle(.secondary)
            }
        }
        .frame(width: 76, height: 76)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(up + slow) of \(total) services up")
    }

    private func arc(_ from: Double, _ to: Double, _ color: Color) -> some View {
        Circle().trim(from: from, to: to)
            .stroke(color, style: StrokeStyle(lineWidth: 9, lineCap: .butt))
            .rotationEffect(.degrees(-90))
    }
}

/// One bar per check over the last hour, colored by the share of services up.
struct TrendBars: View {
    let values: [Double]

    var body: some View {
        HStack(alignment: .bottom, spacing: 1) {
            ForEach(Array(values.suffix(60).enumerated()), id: \.offset) { _, v in
                RoundedRectangle(cornerRadius: 1)
                    .fill(v >= 1 ? Color.green : v > 0 ? .orange : .red)
                    .frame(width: 2, height: max(3, 16 * v))
            }
        }
        .frame(height: 16)
        .accessibilityLabel("Uptime trend")
    }
}

struct LinkButton: View {
    let title: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text("\(title) ↗").font(.caption).frame(maxWidth: .infinity).padding(.vertical, 5)
                .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 6))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
