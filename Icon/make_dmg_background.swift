import AppKit
import CoreText
import SwiftUI

// Renders the DMG window background (660x400 pt) at 1x and 2x.
// Icons sit at (180, 215) and (480, 215); see dmg_settings.py.
// Usage: swift Icon/make_dmg_background.swift <fonts dir> <out.png> <out@2x.png>
let args = CommandLine.arguments
for name in ["PermanentMarker-Regular.ttf", "Montserrat-ExtraBold.ttf", "Montserrat-SemiBold.ttf"] {
    CTFontManagerRegisterFontsForURL(URL(fileURLWithPath: args[1]).appending(path: name) as CFURL, .process, nil)
}

let orange = Color(red: 0.96, green: 0.52, blue: 0.13)

struct Arrow: View {
    var body: some View {
        Path { p in
            p.move(to: CGPoint(x: 0, y: 12))
            p.addLine(to: CGPoint(x: 92, y: 12))
            p.move(to: CGPoint(x: 80, y: 0))
            p.addLine(to: CGPoint(x: 94, y: 12))
            p.addLine(to: CGPoint(x: 80, y: 24))
        }
        .stroke(Color(white: 0.2).opacity(0.6), style: StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round))
        .frame(width: 96, height: 24)
    }
}

struct Background: View {
    var body: some View {
        ZStack(alignment: .topLeading) {
            LinearGradient(colors: [Color(white: 0.13), Color(white: 0.06)], startPoint: .top, endPoint: .bottom)
            RadialGradient(colors: [orange.opacity(0.22), .clear], center: .bottom, startRadius: 10, endRadius: 360)
            // Finder draws icon labels in black on custom backgrounds, even in Dark Mode: keep them on a light band
            Rectangle()
                .fill(LinearGradient(colors: [Color(white: 0.96), Color(white: 0.89)], startPoint: .top, endPoint: .bottom))
                .frame(width: 660, height: 196)
                .overlay(alignment: .top) { orange.frame(height: 4) }
                .offset(y: 124)
            VStack(alignment: .trailing, spacing: -5) {
                Text("RESKATE").font(.custom("PermanentMarker-Regular", size: 46)).foregroundStyle(.white)
                Text("MAC VERSION")
                    .font(.custom("Montserrat-ExtraBold", size: 10))
                    .tracking(3)
                    .foregroundStyle(Color(white: 0.06))
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(orange)
            }
            .rotationEffect(.degrees(-4))
            .frame(width: 660)
            .offset(y: 26)
            Arrow().offset(x: 282, y: 203)
            Text("Drag ReSkate into Applications")
                .font(.custom("Montserrat-SemiBold", size: 13))
                .foregroundStyle(.white.opacity(0.55))
                .frame(width: 660)
                .offset(y: 352)
        }
        .frame(width: 660, height: 400)
    }
}

@MainActor func render(scale: CGFloat, to path: String) {
    let renderer = ImageRenderer(content: Background())
    renderer.scale = scale
    guard let image = renderer.cgImage,
          let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else { exit(1) }
    try! png.write(to: URL(fileURLWithPath: path))
}

MainActor.assumeIsolated {
    render(scale: 1, to: args[2])
    render(scale: 2, to: args[3])
}
