import AppKit
import SwiftUI

struct VisualEffectView: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .popover
    var blendingMode: NSVisualEffectView.BlendingMode = .behindWindow

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = blendingMode
        view.state = .active
        view.isEmphasized = true
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {
        view.material = material
        view.blendingMode = blendingMode
    }
}

/// 面板底色：浅色模式下在毛玻璃上加一层白色，避免整体发灰。
struct PanelBackdrop: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ZStack {
            VisualEffectView(material: .popover, blendingMode: .behindWindow)

            if colorScheme == .light {
                Color.white.opacity(0.55)
            }
        }
    }
}

struct CardStyle: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme

    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(colorScheme == .dark
                          ? Color.white.opacity(0.065)
                          : Color.white.opacity(0.92))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(colorScheme == .dark
                                  ? Color.white.opacity(0.10)
                                  : Color.black.opacity(0.055),
                                  lineWidth: 1)
            )
    }
}

extension View {
    func cardStyle() -> some View {
        modifier(CardStyle())
    }
}

struct HoverIconButton: View {
    let systemName: String
    var size: CGFloat = 13
    var help: String = ""
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: size, weight: .semibold))
                .frame(width: 28, height: 28)
                .background(
                    Circle().fill(Color.primary.opacity(isHovering ? 0.10 : 0))
                )
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.primary)
        .onHover { isHovering = $0 }
        .help(help)
    }
}

struct SectionLabel: View {
    let text: String

    var body: some View {
        Text(text.uppercased())
            .font(.system(size: 10, weight: .semibold))
            .tracking(0.8)
            .foregroundStyle(.secondary)
    }
}

struct StatusPill: View {
    let state: String
    let connected: Bool

    private var color: Color {
        if !connected { return .secondary }
        return state.caseInsensitiveCompare("standby") == .orderedSame ? .orange : .green
    }

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(color)
                .frame(width: 6, height: 6)
            Text(state)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(
            Capsule().fill(Color.primary.opacity(0.06))
        )
    }
}

struct AlbumArtView: View {
    let image: NSImage?

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                ZStack {
                    Rectangle().fill(Color.primary.opacity(0.06))
                    Image(systemName: "music.note")
                        .font(.system(size: 42, weight: .light))
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .frame(width: 168, height: 168)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
        )
    }
}

struct TransportButton: View {
    let systemName: String
    var size: CGFloat = 17
    var help: String = ""
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: size, weight: .medium))
                .frame(width: 34, height: 34)
                .background(Circle().fill(Color.primary.opacity(isHovering ? 0.08 : 0)))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.primary)
        .onHover { isHovering = $0 }
        .help(help)
    }
}
