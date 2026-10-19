// Claude Usage — a menu bar item showing Claude plan usage at a glance.
//
// The label is a small ring filled to the session percentage plus the session
// and weekly numbers. Clicking opens the panel (Views.swift); right-click, or
// the gear in the panel, opens Open at Login and Quit.

import AppKit
import Combine
import ServiceManagement
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let popover = NSPopover()
    private let store = UsageStore()
    private var observers: Set<AnyCancellable> = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        popover.behavior = .transient
        popover.animates = true
        let host = NSHostingController(
            rootView: UsagePanel(store: store) { [weak self] view in self?.showSettingsMenu(from: view) })
        // Let the popover track the SwiftUI size, or it opens at a stale size and lands over the menu bar.
        host.sizingOptions = [.preferredContentSize]
        popover.contentViewController = host

        if let button = item.button {
            button.target = self
            button.action = #selector(clicked(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            button.imagePosition = .imageLeading
            button.setAccessibilityLabel("Claude usage")
        }

        store.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.renderLabel() }
            .store(in: &observers)
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(didWake), name: NSWorkspace.didWakeNotification, object: nil)

        store.start()
        renderLabel()
        if Demo.enabled || UserDefaults.standard.bool(forKey: "openPanel") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { self.showPanel() }
        }
    }

    @objc private func didWake() { store.refresh() }

    @objc private func clicked(_ sender: NSStatusBarButton) {
        if NSApp.currentEvent?.type == .rightMouseUp {
            showSettingsMenu(from: sender)
        } else if popover.isShown {
            popover.performClose(sender)
        } else {
            showPanel()
        }
    }

    private func showPanel() {
        guard let button = item.button else { return }
        store.refreshIfStale()
        store.panelOpened()
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
    }

    // MARK: Label

    private func renderLabel() {
        // objectWillChange fires before the value lands; read on the next turn.
        DispatchQueue.main.async { [self] in
            guard let button = item.button else { return }
            let usage = store.usage
            button.image = RingIcon.image(percent: usage?.session?.percent, stale: store.problem != nil)

            let title = NSMutableAttributedString()
            func add(_ s: String, _ color: NSColor?, _ weight: NSFont.Weight) {
                var attrs: [NSAttributedString.Key: Any] = [
                    .font: NSFont.monospacedDigitSystemFont(ofSize: 13, weight: weight),
                ]
                if let color { attrs[.foregroundColor] = color }
                title.append(NSAttributedString(string: s, attributes: attrs))
            }
            if let usage {
                add(" ", nil, .regular)
                add(usage.session.map { "\(Int($0.percent.rounded()))%" } ?? "–", tint(usage.session?.percent), .semibold)
                add("  ", nil, .regular)
                add(usage.weekly.map { "\(Int($0.percent.rounded()))%" } ?? "–",
                    tint(usage.weekly?.percent) ?? .secondaryLabelColor, .regular)
            }
            button.attributedTitle = title
            button.toolTip = tooltip(usage)
        }
    }

    private func tint(_ percent: Double?) -> NSColor? {
        guard let p = percent else { return nil }
        return p >= 90 ? .systemRed : p >= 75 ? .systemOrange : nil
    }

    private func tooltip(_ usage: Usage?) -> String {
        if let problem = store.problem, usage == nil { return problem }
        guard let usage else { return "Claude usage" }
        var lines: [String] = []
        if let s = usage.session { lines.append("Session \(Int(s.percent.rounded()))% · \(Fmt.relative(s.resetsAt).lowercased())") }
        if let w = usage.weekly { lines.append("Weekly \(Int(w.percent.rounded()))% · \(Fmt.relative(w.resetsAt).lowercased())") }
        return lines.joined(separator: "\n")
    }

    // MARK: Settings menu

    private func showSettingsMenu(from view: NSView?) {
        let menu = NSMenu()
        let refresh = NSMenuItem(title: "Refresh Now", action: #selector(refreshNow), keyEquivalent: "r")
        refresh.target = self
        menu.addItem(refresh)
        let login = NSMenuItem(title: "Open at Login", action: #selector(toggleLogin), keyEquivalent: "")
        login.target = self
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(login)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit Claude Usage", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        if let view {
            menu.popUp(positioning: nil, at: NSPoint(x: 0, y: view.isFlipped ? view.bounds.height + 4 : -4), in: view)
        } else {
            menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
        }
    }

    @objc private func refreshNow() { store.refresh() }

    @objc private func toggleLogin() {
        if SMAppService.mainApp.status == .enabled {
            try? SMAppService.mainApp.unregister()
        } else {
            try? SMAppService.mainApp.register()
        }
    }
}

/// The menu bar glyph: a ring filled to the session percentage. A template
/// image, so it follows the menu bar's tint; the track is drawn faint.
enum RingIcon {
    static func image(percent: Double?, stale: Bool) -> NSImage {
        let image = NSImage(size: NSSize(width: 16, height: 16), flipped: false) { rect in
            let line: CGFloat = 2.6
            let r = rect.insetBy(dx: line / 2 + 0.5, dy: line / 2 + 0.5)
            let track = NSBezierPath(ovalIn: r)
            track.lineWidth = line
            NSColor.black.withAlphaComponent(0.28).setStroke()
            track.stroke()

            if let p = percent, p > 0 {
                let arc = NSBezierPath()
                arc.appendArc(withCenter: NSPoint(x: r.midX, y: r.midY), radius: r.width / 2,
                              startAngle: 90, endAngle: 90 - 360 * CGFloat(min(p, 100) / 100), clockwise: true)
                arc.lineWidth = line
                arc.lineCapStyle = .round
                NSColor.black.withAlphaComponent(stale ? 0.55 : 1).setStroke()
                arc.stroke()
            }
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "Claude usage"
        return image
    }
}

/// Renders the panel and the menu bar label with demo data, for the README.
@MainActor
enum Snapshot {
    static func run(path: String) {
        let dark = UserDefaults.standard.string(forKey: "appearance") != "light"
        let appearance = NSAppearance(named: dark ? .darkAqua : .aqua)!
        let store = UsageStore()
        store.start()

        let panel = UsagePanel(store: store) { _ in }
            .background(RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color(nsColor: dark ? NSColor(white: 0.12, alpha: 1) : NSColor(white: 0.93, alpha: 1))))
            .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.12), lineWidth: 1))
            .padding(24)
        // The label as it sits in a dark menu bar.
        let label = HStack(spacing: 6) {
            Image(nsImage: RingIcon.image(percent: Demo.usage.session?.percent, stale: false))
                .renderingMode(.template)
                .foregroundStyle(Color.white)
            Text("82%").fontWeight(.semibold).foregroundStyle(Color(red: 1, green: 0.62, blue: 0.04))
            Text("38%").foregroundStyle(Color.white.opacity(0.6))
        }
        .font(.system(size: 13).monospacedDigit())
        .padding(.horizontal, 10).padding(.vertical, 4)
        .background(Capsule().fill(Color.white.opacity(0.14)))
        .padding(.horizontal, 14).padding(.vertical, 6)
        .background(Color(white: 0.11))

        appearance.performAsCurrentDrawingAppearance {
            write(panel, dark: dark, to: path)
            if dark { write(label, dark: true, to: path.replacingOccurrences(of: "panel-dark", with: "menubar")) }
        }
    }

    private static func write<V: View>(_ view: V, dark: Bool, to path: String) {
        let renderer = ImageRenderer(content: view.environment(\.colorScheme, dark ? .dark : .light))
        renderer.scale = 2
        guard let cg = renderer.cgImage,
              let png = NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:]) else { return }
        try? png.write(to: URL(fileURLWithPath: path))
    }
}

MainActor.assumeIsolated {
    if let path = UserDefaults.standard.string(forKey: "snapshot") {
        Snapshot.run(path: path)
        exit(0)
    }
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    let delegate = AppDelegate()
    app.delegate = delegate
    app.run()
}
