import AppKit
import CoreText
import SwiftUI

// Renders the "RESKATE / MAC VERSION" wordmark used in the README.
// Usage: swift Icon/make_wordmark.swift <fonts dir> <out-dark.png> <out-light.png>
let args = CommandLine.arguments
for name in ["PermanentMarker-Regular.ttf", "Montserrat-ExtraBold.ttf"] {
    CTFontManagerRegisterFontsForURL(URL(fileURLWithPath: args[1]).appending(path: name) as CFURL, .process, nil)
}

struct Wordmark: View {
    let text: Color

    var body: some View {
        VStack(alignment: .trailing, spacing: -10) {
            Text("RESKATE")
                .font(.custom("PermanentMarker-Regular", size: 120))
                .foregroundStyle(text)
            Text("MAC VERSION")
                .font(.custom("Montserrat-ExtraBold", size: 27))
                .tracking(8)
                .foregroundStyle(Color(white: 0.06))
                .padding(.horizontal, 16)
                .padding(.vertical, 6)
                .background(Color(red: 0.96, green: 0.52, blue: 0.13))
        }
        .rotationEffect(.degrees(-4))
        .padding(40)
    }
}

@MainActor func render(_ view: some View, to path: String) {
    let renderer = ImageRenderer(content: view)
    renderer.scale = 2
    guard let image = renderer.nsImage, let tiff = image.tiffRepresentation,
          let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else { exit(1) }
    try! png.write(to: URL(fileURLWithPath: path))
}

MainActor.assumeIsolated {
    render(Wordmark(text: .white), to: args[2])
    render(Wordmark(text: Color(white: 0.08)), to: args[3])
}
