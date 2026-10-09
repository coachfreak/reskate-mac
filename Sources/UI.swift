import AppKit
import SwiftUI

// Look of the ReSkate launcher: photo backdrop, flat dark panels, Montserrat + Permanent Marker, blue PLAY block.
enum Theme {
    static let panel = Color(red: 0.1, green: 0.1, blue: 0.11).opacity(0.94)
    static let panelHover = Color(red: 0.16, green: 0.16, blue: 0.17).opacity(0.96)
    static let line = Color.white.opacity(0.12)
    static let dim = Color.white.opacity(0.62)
    static let green = Color(red: 0.2, green: 0.78, blue: 0.4)
    static let blue = Color(red: 0.0, green: 0.55, blue: 1.0)
    static let orange = Color(red: 0.96, green: 0.52, blue: 0.13)
    static let red = Color(red: 0.95, green: 0.3, blue: 0.27)
    static let ink = Color(white: 0.06)

    static func heavy(_ size: CGFloat) -> Font { .custom("Montserrat-ExtraBold", size: size) }
    static func bold(_ size: CGFloat) -> Font { .custom("Montserrat-Bold", size: size) }
    static func semibold(_ size: CGFloat) -> Font { .custom("Montserrat-SemiBold", size: size) }
    static func medium(_ size: CGFloat) -> Font { .custom("Montserrat-Medium", size: size) }
    static func marker(_ size: CGFloat) -> Font { .custom("PermanentMarker-Regular", size: size) }
}

struct Backdrop: View {
    let image: NSImage?

    var body: some View {
        ZStack {
            if let image {
                Image(nsImage: image).resizable().scaledToFill()
            } else {
                LinearGradient(colors: [Color(white: 0.16), Color(white: 0.05)], startPoint: .topLeading, endPoint: .bottomTrailing)
            }
            Color.black.opacity(0.45)
            LinearGradient(colors: [.black.opacity(0.45), .clear], startPoint: .leading, endPoint: .center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped()
        .ignoresSafeArea()
    }
}

// MARK: - Window chrome

struct WindowConfigurator: NSViewRepresentable {
    func makeNSView(context _: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            guard let window = view.window else { return }
            for kind in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
                window.standardWindowButton(kind)?.isHidden = true
            }
            window.isMovableByWindowBackground = true
            window.backgroundColor = .black
        }
        return view
    }

    func updateNSView(_: NSView, context _: Context) {}
}

struct WindowControls: View {
    var body: some View {
        HStack(spacing: 18) {
            ChromeButton(symbol: "minus") { NSApp.keyWindow?.miniaturize(nil) }
            ChromeButton(symbol: "xmark") { NSApp.terminate(nil) }
        }
    }
}

struct ChromeButton: View {
    let symbol: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .light))
                .foregroundStyle(.white.opacity(hovering ? 1 : 0.8))
                .frame(width: 24, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

struct Logo: View {
    var tag = "MAC VERSION"

    var body: some View {
        VStack(alignment: .trailing, spacing: -6) {
            Text("RESKATE")
                .font(Theme.marker(58))
                .foregroundStyle(.white)
            Text(tag)
                .font(Theme.heavy(13))
                .tracking(4)
                .foregroundStyle(Theme.ink)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Theme.orange)
        }
        .rotationEffect(.degrees(-4))
        .shadow(color: .black.opacity(0.5), radius: 10, y: 4)
    }
}

struct Pill: View {
    let text: String
    let color: Color

    var body: some View {
        Text(text)
            .font(Theme.heavy(10))
            .foregroundStyle(Theme.ink.opacity(0.85))
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(color, in: Capsule())
    }
}

enum RowIcon {
    case ok, warn, error, pending, busy, skipped

    init(_ state: StepState) {
        switch state {
        case .pending: self = .pending
        case .running: self = .busy
        case .done: self = .ok
        case .skipped: self = .skipped
        case .failed: self = .error
        }
    }
}

struct StatusRow: View {
    let icon: RowIcon
    let title: String
    var detail: String?
    var large = false
    var progress: Double?

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            symbol.frame(width: 20, height: 20)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(large ? Theme.bold(17) : Theme.semibold(13))
                    .foregroundStyle(icon == .pending ? Theme.dim : .white)
                if let detail, !detail.isEmpty {
                    Text(detail)
                        .font(Theme.medium(large ? 12 : 11))
                        .foregroundStyle(Theme.dim)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let progress {
                    ProgressBar(value: progress).padding(.top, 3)
                }
            }
            Spacer(minLength: 0)
        }
    }

    @ViewBuilder private var symbol: some View {
        switch icon {
        case .ok: Image(systemName: "checkmark.circle.fill").font(.system(size: 18)).foregroundStyle(.white, Theme.green)
        case .warn: Image(systemName: "exclamationmark.circle.fill").font(.system(size: 18)).foregroundStyle(.white, Theme.orange)
        case .error: Image(systemName: "xmark.circle.fill").font(.system(size: 18)).foregroundStyle(.white, Theme.red)
        case .skipped: Image(systemName: "minus.circle.fill").font(.system(size: 18)).foregroundStyle(.white, Color(white: 0.4))
        case .pending: Circle().strokeBorder(Color(white: 0.4), lineWidth: 1.5).frame(width: 17, height: 17)
        case .busy: ProgressView().controlSize(.small).tint(.white)
        }
    }
}

struct ProgressBar: View {
    let value: Double

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Rectangle().fill(Color.white.opacity(0.12))
                Rectangle().fill(Theme.blue).frame(width: geo.size.width * max(0, min(1, value)))
            }
        }
        .frame(height: 4)
    }
}

struct Divided: View {
    var body: some View { Rectangle().fill(Theme.line).frame(height: 1) }
}

struct PanelLabel: View {
    let title: String
    let subtitle: String
    let symbol: String
    var hovering = false

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(Theme.heavy(20)).foregroundStyle(.white)
                Text(subtitle)
                    .font(Theme.medium(11))
                    .foregroundStyle(Theme.dim)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 0)
            Image(systemName: symbol)
                .font(.system(size: 17, weight: .light))
                .foregroundStyle(.white.opacity(0.85))
                .frame(width: 46, height: 46)
                .overlay(Circle().strokeBorder(.white.opacity(0.55), lineWidth: 1.2))
        }
        .padding(.horizontal, 20)
        .frame(height: 78)
        .background(hovering ? Theme.panelHover : Theme.panel)
        .contentShape(Rectangle())
    }
}

struct ActionPanel: View {
    let title: String
    let subtitle: String
    let symbol: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            PanelLabel(title: title, subtitle: subtitle, symbol: symbol, hovering: hovering)
        }
        .buttonStyle(PressStyle())
        .onHover { hovering = $0 }
    }
}

struct BigBlock: View {
    let title: String
    let subtitle: String
    var enabled = true
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 0) {
                Text(title)
                    .font(Theme.heavy(title.count > 6 ? 30 : 40))
                    .foregroundStyle(Theme.ink)
                Spacer(minLength: 0)
                Text(subtitle)
                    .font(Theme.bold(12))
                    .foregroundStyle(Theme.ink.opacity(0.8))
                    .lineLimit(1)
            }
            .padding(.horizontal, 22)
            .padding(.top, 16)
            .padding(.bottom, 16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: 124)
            .background(Theme.blue.opacity(enabled ? (hovering ? 1 : 0.94) : 0.6))
            .contentShape(Rectangle())
        }
        .buttonStyle(PressStyle())
        .disabled(!enabled)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.15), value: hovering)
    }
}

struct PressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .animation(.spring(duration: 0.2), value: configuration.isPressed)
    }
}
