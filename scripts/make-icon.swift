// Renders the app icon: `xcrun swift scripts/make-icon.swift <out.png>` (1024 px).
// `make icon` turns it into Resources/AppIcon.icns.
import SwiftUI
import AppKit

func hex(_ v: UInt32) -> Color {
    Color(red: Double((v >> 16) & 0xFF) / 255, green: Double((v >> 8) & 0xFF) / 255, blue: Double(v & 0xFF) / 255)
}

struct Icon: View {
    let fill = 0.74          // how far the ring runs
    let pace = 0.58          // where the pace tick sits

    var body: some View {
        ZStack {
            // Apple's icon grid: an 824 pt body on a 1024 canvas.
            RoundedRectangle(cornerRadius: 186, style: .continuous)
                .fill(LinearGradient(colors: [hex(0x3A3A40), hex(0x161618)], startPoint: .top, endPoint: .bottom))
                .overlay(RoundedRectangle(cornerRadius: 186, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.10), lineWidth: 3))
                .frame(width: 824, height: 824)

            Circle()
                .stroke(Color.white.opacity(0.10), lineWidth: 92)
                .frame(width: 500, height: 500)

            Circle()
                .trim(from: 0, to: fill)
                .stroke(AngularGradient(stops: [.init(color: hex(0x3DDC97), location: 0),
                                                .init(color: hex(0x3DDC97), location: 0.55),
                                                .init(color: hex(0xFFB340), location: 0.86),
                                                .init(color: hex(0xFF5A52), location: 1)],
                                        center: .center, startAngle: .zero, endAngle: .degrees(360 * fill)),
                        style: StrokeStyle(lineWidth: 92, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .frame(width: 500, height: 500)

            Capsule()
                .fill(Color.white.opacity(0.92))
                .frame(width: 14, height: 132)
                .offset(y: -250)
                .rotationEffect(.degrees(pace * 360))
        }
        .frame(width: 1024, height: 1024)
    }
}

let out = CommandLine.arguments.dropFirst().first ?? "icon.png"
MainActor.assumeIsolated {
    let renderer = ImageRenderer(content: Icon())
    renderer.scale = 1
    guard let cg = renderer.cgImage,
          let png = NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:]) else {
        fatalError("render failed")
    }
    try! png.write(to: URL(fileURLWithPath: out))
}
