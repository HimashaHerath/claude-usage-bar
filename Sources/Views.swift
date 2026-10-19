// The panel that opens from the menu bar.
//
// Graphite cards in the style of macOS's own widgets: two rings for the
// 5-hour and weekly limits, then segmented bars for each model's weekly cap.
// Colour only means something: green under 75%, amber to 90%, red above.

import SwiftUI
import AppKit

// MARK: - Tokens

enum Palette {
    static let card = adaptive(light: 0xFFFFFF, dark: 0x2C2C2E)
    static let track = adaptive(light: 0xE5E5EA, dark: 0x3A3A3C)
    static let green = adaptive(light: 0x1F9D6B, dark: 0x3DDC97)
    static let amber = adaptive(light: 0xC27400, dark: 0xFFB340)
    static let red = adaptive(light: 0xD70015, dark: 0xFF5A52)

    static func level(_ percent: Double) -> Color {
        percent >= 90 ? red : percent >= 75 ? amber : green
    }

    static func adaptive(light: UInt32, dark: UInt32) -> Color {
        func ns(_ hex: UInt32) -> NSColor {
            NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                    blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
        }
        return Color(nsColor: NSColor(name: nil) {
            $0.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? ns(dark) : ns(light)
        })
    }
}

// MARK: - Formatting

enum Fmt {
    static func pct(_ p: Double) -> String { "\(Int(p.rounded()))%" }

    /// "1h 35m left", "3d 7h left".
    static func left(_ date: Date?) -> String {
        guard let date else { return "No reset time" }
        let secs = Int(date.timeIntervalSinceNow)
        if secs <= 60 { return "Resetting" }
        let d = secs / 86400, h = (secs % 86400) / 3600, m = (secs % 3600) / 60
        if d > 0 { return "\(d)d \(h)h left" }
        if h > 0 { return "\(h)h \(m)m left" }
        return "\(m)m left"
    }

    static func relative(_ date: Date?) -> String {
        let l = left(date)
        return l.hasSuffix(" left") ? "Resets in \(l.dropLast(5))" : l
    }

    static func clock(_ date: Date?) -> String {
        guard let date else { return "" }
        let f = DateFormatter()
        f.dateFormat = Calendar.current.isDateInToday(date) ? "h:mm a" : "EEE h:mm a"
        return f.string(from: date)
    }

    static func ago(_ date: Date?) -> String {
        guard let date else { return "Not updated yet" }
        let secs = Int(-date.timeIntervalSinceNow)
        if secs < 60 { return "Updated just now" }
        if secs < 3600 { return "Updated \(secs / 60) min ago" }
        return "Updated \(secs / 3600) h ago"
    }
}

// MARK: - Panel

struct UsagePanel: View {
    @ObservedObject var store: UsageStore
    var openSettingsMenu: (NSView?) -> Void

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { _ in
            VStack(alignment: .leading, spacing: 10) {
                header
                if let usage = store.usage {
                    HStack(spacing: 10) {
                        RingCard(title: "5-hour session", window: usage.session, replay: store.openCount)
                        RingCard(title: "Weekly", window: usage.weekly, replay: store.openCount)
                    }
                    PaceWarning(usage: usage)
                    ModelsCard(windows: usage.scoped, replay: store.openCount)
                } else {
                    loading
                }
                if let problem = store.problem { ProblemBanner(text: problem) }
                footer
            }
            .padding(16)
            .frame(width: 336)
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            Text("Claude").font(.system(size: 15, weight: .semibold))
            Spacer()
            if let plan = store.plan {
                Text(plan).font(.system(size: 12)).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 2)
        .padding(.bottom, 2)
    }

    private var loading: some View {
        HStack(spacing: 10) {
            ProgressView().controlSize(.small)
            Text(store.problem == nil ? "Fetching usage…" : "No numbers yet")
                .font(.system(size: 13)).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, minHeight: 150)
        .background(Palette.card, in: .rect(cornerRadius: 12, style: .continuous))
    }

    private var footer: some View {
        HStack(spacing: 14) {
            Text(Fmt.ago(store.lastSuccess))
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
            Spacer()
            Button { NSWorkspace.shared.open(URL(string: "https://claude.ai/settings/usage")!) } label: {
                Image(systemName: "arrow.up.right.square")
            }
            .buttonStyle(.plain)
            .help("Open the usage page on claude.ai")
            .accessibilityLabel("Open usage page")
            Button { store.refresh() } label: {
                Image(systemName: "arrow.clockwise")
                    .rotationEffect(.degrees(store.refreshing ? 360 : 0))
                    .animation(store.refreshing ? .linear(duration: 0.9).repeatForever(autoreverses: false) : .default,
                               value: store.refreshing)
            }
            .buttonStyle(.plain)
            .help("Refresh now")
            .accessibilityLabel("Refresh")
            Button { openSettingsMenu(nil) } label: { Image(systemName: "gearshape") }
                .buttonStyle(.plain)
                .help("Settings")
                .accessibilityLabel("Settings")
        }
        .font(.system(size: 12, weight: .medium))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 2)
        .padding(.top, 2)
    }
}

// MARK: - Rings

struct RingCard: View {
    let title: String
    let window: UsageWindow?
    let replay: Int

    @State private var shown: Double

    init(title: String, window: UsageWindow?, replay: Int) {
        self.title = title
        self.window = window
        self.replay = replay
        // A snapshot renders one frame, so start full rather than animating in.
        _shown = State(initialValue: Demo.snapshotting ? (window?.percent ?? 0) : 0)
    }

    var body: some View {
        let percent = window?.percent ?? 0
        let color = Palette.level(percent)
        VStack(spacing: 10) {
            ZStack {
                Circle().stroke(Palette.track, lineWidth: 9)
                Circle()
                    .trim(from: 0, to: max(0.002, shown / 100))
                    .stroke(color, style: StrokeStyle(lineWidth: 9, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                if let pace = window?.elapsed, pace > 0.02, pace < 0.98 {
                    PaceTick(fraction: pace, radius: 40, length: 15)
                }
                Text(window.map { Fmt.pct($0.percent) } ?? "–")
                    .font(.system(size: 22, weight: .semibold))
                    .monospacedDigit()
                    .contentTransition(.numericText(value: percent))
            }
            .frame(width: 80, height: 80)
            .padding(5)

            VStack(spacing: 2) {
                Text(title).font(.system(size: 13, weight: .medium))
                Text(Fmt.left(window?.resetsAt))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        }
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity)
        .background(Palette.card, in: .rect(cornerRadius: 12, style: .continuous))
        .help(window?.resetsAt.map { "Resets \(Fmt.clock($0)). The tick marks an even pace." } ?? "")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(title), \(window.map { Fmt.pct($0.percent) } ?? "unknown"), \(Fmt.left(window?.resetsAt))")
        .task(id: replay) {
            guard !Demo.snapshotting else { return }
            shown = 0
            try? await Task.sleep(for: .milliseconds(60))
            withAnimation(.spring(response: 0.9, dampingFraction: 0.86)) { shown = percent }
        }
        .onChange(of: percent) { _, new in
            withAnimation(.easeOut(duration: 0.6)) { shown = new }
        }
    }
}

/// A short radial line where usage would be at an even pace through the window.
struct PaceTick: View {
    let fraction: Double
    let radius: CGFloat
    let length: CGFloat

    var body: some View {
        Capsule()
            .fill(Color.primary.opacity(0.7))
            .frame(width: 2, height: length)
            .offset(y: -radius)
            .rotationEffect(.degrees(fraction * 360))
    }
}

/// One amber line when a limit will run out before it resets.
struct PaceWarning: View {
    let usage: Usage

    var body: some View {
        let candidates: [(String, UsageWindow)] =
            [("Session", usage.session), ("Weekly limit", usage.weekly)].compactMap { name, w in w.map { (name, $0) } }
            + usage.scoped.map { ("\($0.label) limit", $0) }
        if let (name, w) = candidates.first(where: { $0.1.runsOutAt != nil }), let out = w.runsOutAt {
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.circle")
                Text("\(name) runs out around \(Fmt.clock(out)) at this pace")
            }
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(Palette.amber)
            .padding(.horizontal, 4)
        }
    }
}

// MARK: - Models

struct ModelsCard: View {
    let windows: [UsageWindow]
    let replay: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                Text("Models · weekly").font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
                Spacer()
                if let reset = windows.compactMap(\.resetsAt).min() {
                    Text("Resets \(Fmt.clock(reset))").font(.system(size: 11)).foregroundStyle(.tertiary)
                }
            }
            if windows.isEmpty {
                Text("Your plan has no separate per-model limits right now.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                ForEach(windows) { SegmentRow(window: $0, replay: replay) }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Palette.card, in: .rect(cornerRadius: 12, style: .continuous))
    }
}

struct SegmentRow: View {
    let window: UsageWindow
    let replay: Int
    private let cells = 20

    @State private var revealed = Demo.snapshotting

    var body: some View {
        let lit = Int((window.percent / 100 * Double(cells)).rounded())
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .firstTextBaseline) {
                Text(window.label).font(.system(size: 13, weight: .medium))
                Spacer()
                Text(Fmt.pct(window.percent))
                    .font(.system(size: 13, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(window.percent >= 75 ? Palette.level(window.percent) : .primary)
            }
            HStack(spacing: 3) {
                ForEach(0..<cells, id: \.self) { i in
                    let on = revealed && i < lit
                    RoundedRectangle(cornerRadius: 2, style: .continuous)
                        .fill(on ? Palette.level(Double(i + 1) * 100 / Double(cells)) : Palette.track)
                        .frame(height: 12)
                        .animation(.easeOut(duration: 0.18).delay(revealed ? Double(i) * 0.022 : 0), value: revealed)
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(window.label) weekly limit, \(Fmt.pct(window.percent))")
        .task(id: replay) {
            guard !Demo.snapshotting else { return }
            revealed = false
            try? await Task.sleep(for: .milliseconds(120))
            revealed = true
        }
    }
}

// MARK: - Bits

struct ProblemBanner: View {
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Palette.amber)
            Text(text).fixedSize(horizontal: false, vertical: true)
        }
        .font(.system(size: 12))
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Palette.card, in: .rect(cornerRadius: 12, style: .continuous))
    }
}
