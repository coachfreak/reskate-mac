import AppKit
import SwiftUI

// Renders the 1024px app icon PNG to the path given as first argument.
// Drawn from plain shapes only (SF Symbols may not be used in app icons).
struct Skateboard: View {
    var body: some View {
        ZStack {
            // wheels poking out on both sides of each truck
            ForEach([-205.0, 205.0], id: \.self) { x in
                ForEach([-112.0, 112.0], id: \.self) { y in
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .fill(Color(white: 0.12))
                        .frame(width: 92, height: 62)
                        .offset(x: x, y: y)
                }
            }
            // deck
            Capsule()
                .fill(.white)
                .frame(width: 640, height: 210)
            // grip tape
            Capsule()
                .fill(Color(white: 0.15))
                .frame(width: 560, height: 150)
            // bolts
            ForEach([-205.0, 205.0], id: \.self) { x in
                ForEach([-28.0, 28.0], id: \.self) { y in
                    Circle().fill(Color(white: 0.55)).frame(width: 22).offset(x: x, y: y)
                }
            }
        }
    }
}

struct IconView: View {
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 185, style: .continuous)
                .fill(LinearGradient(
                    colors: [Color(red: 1.0, green: 0.62, blue: 0.24), Color(red: 0.93, green: 0.42, blue: 0.08)],
                    startPoint: .top, endPoint: .bottom))
                .frame(width: 824, height: 824)
                .shadow(color: .black.opacity(0.35), radius: 24, y: 12)
            Skateboard()
                .rotationEffect(.degrees(-45))
                .shadow(color: .black.opacity(0.3), radius: 18, y: 12)
        }
        .frame(width: 1024, height: 1024)
    }
}

MainActor.assumeIsolated {
    let renderer = ImageRenderer(content: IconView())
    renderer.scale = 1
    guard let image = renderer.nsImage, let tiff = image.tiffRepresentation,
          let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else { exit(1) }
    try! png.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
}
