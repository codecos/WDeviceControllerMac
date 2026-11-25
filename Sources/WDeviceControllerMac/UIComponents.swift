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
                    .fill(colorScheme == .dark ? Color.white.opacity(0.065) : Color.clear)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(colorScheme == .dark ? Color.white.opacity(0.10) : Color.clear,
                                  lineWidth: 1)
            )
    }
}

extension View {
    func cardStyle() -> some View {
        modifier(CardStyle())
    }
}

/// 悬停才显形的下拉选择器：静止时只有文字 + 箭头，鼠标移上去才浮出一块玻璃底。
struct GlassPicker<Value: Hashable>: View {
    let options: [(label: String, value: Value)]
    let selection: Value
    var placeholder: String = "--"
    var isEnabled: Bool = true
    var fillsWidth: Bool = false
    let onSelect: (Value) -> Void

    @State private var isHovering = false

    private var currentLabel: String {
        options.first(where: { $0.value == selection })?.label ?? placeholder
    }

    private var highlighted: Bool { isHovering && isEnabled }

    var body: some View {
        Menu {
            ForEach(options.indices, id: \.self) { index in
                Button {
                    onSelect(options[index].value)
                } label: {
                    if options[index].value == selection {
                        Label(options[index].label, systemImage: "checkmark")
                    } else {
                        Text(options[index].label)
                    }
                }
            }
        } label: {
            labelBody
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize(horizontal: !fillsWidth, vertical: false)
        .disabled(!isEnabled)
        .onHover { isHovering = $0 }
    }

    private var labelBody: some View {
        HStack(spacing: 6) {
            Text(currentLabel)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(isEnabled ? Color.primary : Color.secondary)
                .lineLimit(1)
                .truncationMode(.middle)

            Spacer(minLength: 6)

            Image(systemName: "chevron.up.chevron.down")
                .font(.system(size: 8, weight: .bold))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 6)
        .frame(maxWidth: fillsWidth ? .infinity : nil, alignment: .leading)
        .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .background { hoverBackground }
    }

    @ViewBuilder private var hoverBackground: some View {
        GlassHoverBackground(cornerRadius: 8, visible: highlighted)
    }
}

/// 悬停才出现的液态玻璃底：macOS 26 用系统 glassEffect，旧系统用材质 + 高光描边近似。
/// 圆角半径取控件宽高的一半即为圆形，避免为圆形/圆角矩形各写一份。
struct GlassHoverBackground: View {
    var cornerRadius: CGFloat
    var visible: Bool
    /// 需要强调时才传入浅色轻染，默认中性玻璃。
    var tint: Color? = nil

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
    }

    var body: some View {
        if #available(macOS 26.0, *) {
            if visible {
                if let tint {
                    Color.clear.glassEffect(.regular.tint(tint).interactive(), in: shape)
                } else {
                    Color.clear.glassEffect(.regular.interactive(), in: shape)
                }
            }
        } else if visible {
            shape
                .fill(.ultraThinMaterial)
                .overlay(shape.fill(tint ?? .clear))
                .overlay(
                    shape.strokeBorder(
                        LinearGradient(
                            colors: [Color.white.opacity(0.55), Color.white.opacity(0.06)],
                            startPoint: .top,
                            endPoint: .bottom
                        ),
                        lineWidth: 1
                    )
                )
                .shadow(color: Color.black.opacity(0.10), radius: 5, y: 2)
        }
    }
}

struct HoverIconButton: View {
    let systemName: String
    var size: CGFloat = 13
    var frame: CGFloat = 28
    var tint: Color = .primary
    var help: String = ""
    var isEnabled: Bool = true
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: size, weight: .semibold))
                .frame(width: frame, height: frame)
                .background {
                    GlassHoverBackground(cornerRadius: frame / 2, visible: isHovering && isEnabled)
                }
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(isEnabled ? tint : Color.secondary)
        .onHover { isHovering = $0 }
        .help(help)
        .disabled(!isEnabled)
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
    var isStandby: Bool = false

    private var color: Color {
        if !connected { return .secondary }
        return isStandby ? .orange : .green
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
    var size: CGFloat = 168

    var body: some View {
        Group {
            if let image {
                // 封面不一定是正方形（No Glass Player 的专辑图就是 16:9），
                // 以前用 .fill 铺满方块会把两边裁掉，看起来像被“拉大裁剪”。
                // 现在前景按原比例完整显示，空出来的部分用同一张图模糊铺底，既不变形也不丢内容。
                ZStack {
                    Image(nsImage: image)
                        .resizable()
                        .scaledToFill()
                        .frame(width: size * 1.4, height: size * 1.4)
                        .blur(radius: 24)
                        .overlay(Color.black.opacity(0.18))

                    Image(nsImage: image)
                        .resizable()
                        .scaledToFit()
                        .frame(width: size, height: size)
                }
            } else {
                ZStack {
                    Rectangle().fill(Color.primary.opacity(0.06))
                    Image(systemName: "music.note")
                        .font(.system(size: 42, weight: .light))
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .frame(width: size, height: size)
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
                .background { GlassHoverBackground(cornerRadius: 17, visible: isHovering) }
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.primary)
        .onHover { isHovering = $0 }
        .help(help)
    }
}
