import AppKit
import SwiftUI

struct PanelView: View {
    @ObservedObject var viewModel: MainViewModel
    var onEscape: () -> Void

    var body: some View {
        Group {
            if viewModel.isMenuVisible {
                MenuSettingsView(viewModel: viewModel)
            } else {
                QuickControlView(viewModel: viewModel)
            }
        }
        .frame(width: 520)
        .background(PanelBackdrop())
        .overlay(
            Rectangle()
                .strokeBorder(Color.primary.opacity(0.10), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .onExitCommand(perform: onEscape)
    }
}

// MARK: - 快捷控制页

private struct QuickControlView: View {
    @ObservedObject var viewModel: MainViewModel

    var body: some View {
        VStack(spacing: 0) {
            header
                .padding(.horizontal, 18)
                .padding(.top, 16)
                .padding(.bottom, 12)

            Divider().opacity(0.35)

            VStack(spacing: 12) {
                deviceRow

                if viewModel.isConnected {
                    if viewModel.isNowPlayingVisible {
                        nowPlayingCard
                    }
                    if viewModel.isFmVisible {
                        fmCard
                    }
                    volumeCard
                } else {
                    emptyState
                }
            }
            .padding(16)
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(viewModel.selectedDevice?.hostname ?? "WDeviceController")
                    .font(.system(size: 20, weight: .semibold))
                    .lineLimit(1)
                Text(viewModel.isConnected ? viewModel.bitrate : "未连接设备")
                    .font(.system(size: 12, weight: .medium))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 8)

            StatusPill(state: viewModel.deviceState, connected: viewModel.isConnected)
        }
    }

    private var deviceRow: some View {
        HStack(spacing: 8) {
            GlassPicker(
                options: viewModel.devices.map { (label: $0.displayName, value: Optional($0.id)) },
                selection: viewModel.selectedDeviceID,
                placeholder: viewModel.isScanning ? "扫描中…" : "未发现设备",
                isEnabled: !viewModel.devices.isEmpty && !viewModel.isScanning,
                fillsWidth: true,
                onSelect: { viewModel.selectDevice(id: $0) }
            )
            .frame(maxWidth: .infinity, alignment: .leading)

            if viewModel.isScanning {
                ProgressView()
                    .controlSize(.small)
                    .frame(width: 28, height: 28)
            } else {
                HoverIconButton(systemName: "arrow.clockwise", size: 13, help: "扫描设备") {
                    viewModel.scan()
                }
            }

            if viewModel.isConnected {
                HoverIconButton(
                    systemName: viewModel.isDeviceStandby ? "power.circle.fill" : "moon.zzz",
                    size: 14,
                    help: viewModel.isDeviceStandby ? "开机" : "待机"
                ) {
                    if viewModel.isDeviceStandby {
                        viewModel.powerOn()
                    } else {
                        viewModel.standby()
                    }
                }
            }

            GlassPillButton(
                systemName: viewModel.isConnected ? "bolt.slash.fill" : "bolt.fill",
                title: viewModel.isConnected ? "断开" : "连接",
                isEnabled: viewModel.isConnected || (viewModel.selectedDevice != nil && !viewModel.isConnecting)
            ) {
                if viewModel.isConnected {
                    viewModel.disconnect()
                } else {
                    viewModel.connectToSelectedDevice()
                }
            }
        }
    }

    private var emptyState: some View {
        HStack(spacing: 10) {
            Image(systemName: "wifi.exclamationmark")
                .font(.system(size: 16))
                .foregroundStyle(.secondary)
            Text("选择局域网内的设备并连接，即可控制播放、音量与设置。")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }
        .padding(.vertical, 14)
        .padding(.horizontal, 12)
        .cardStyle()
    }

    private var nowPlayingCard: some View {
        HStack(alignment: .top, spacing: 14) {
            AlbumArtView(image: viewModel.albumArt)

            VStack(alignment: .leading, spacing: 6) {
                Text(viewModel.nowPlayingTitle.isEmpty ? "未知曲目" : viewModel.nowPlayingTitle)
                    .font(.system(size: 16, weight: .semibold))
                    .lineLimit(2)
                    .help(viewModel.nowPlayingTitle)

                Text(viewModel.nowPlayingArtist.isEmpty ? "未知艺术家" : viewModel.nowPlayingArtist)
                    .font(.system(size: 12.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                HStack(spacing: 6) {
                    Text(viewModel.nowPlayingAlbum)
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)

                    if viewModel.isPlayerLinkPrimary {
                        Text("NGP")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(Color.accentColor)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Capsule().fill(Color.accentColor.opacity(0.16)))
                            .help("曲目信息来自 \(viewModel.playerLinkName ?? "No Glass Player")")
                    }
                }

                Spacer(minLength: 6)

                ProgressView(value: min(max(viewModel.playProgress, 0), 100), total: 100)
                    .progressViewStyle(.linear)
                    .tint(.accentColor)

                HStack {
                    Text(viewModel.playPositionText)
                    Spacer()
                    Text(viewModel.playLengthText)
                }
                .font(.system(size: 10, weight: .medium))
                .monospacedDigit()
                .foregroundStyle(.secondary)

                HStack(spacing: 16) {
                    Spacer()
                    TransportButton(systemName: "backward.fill", size: 15, help: "上一首") {
                        viewModel.previousTrack()
                    }
                    TransportButton(systemName: viewModel.playPauseSymbol, size: 21, help: "播放/暂停") {
                        viewModel.togglePlayPause()
                    }
                    TransportButton(systemName: "forward.fill", size: 15, help: "下一首") {
                        viewModel.nextTrack()
                    }
                    Spacer()
                }
                .padding(.top, 2)
            }
            .frame(height: 168, alignment: .top)
        }
        .padding(12)
        .cardStyle()
    }

    private var fmCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                SectionLabel(text: "Preset \(viewModel.fmPresetNumber)")
                Spacer()
                FmNameEditor(viewModel: viewModel)
            }

            HStack(alignment: .center, spacing: 8) {
                HoverIconButton(systemName: "chevron.left", size: 12, help: "上一个预设") {
                    viewModel.fmPresetDown()
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(viewModel.fmPresetTitle)
                        .font(.system(size: 16, weight: .semibold))
                        .lineLimit(1)
                    Text("FM")
                        .font(.system(size: 10, weight: .semibold))
                        .tracking(0.6)
                        .foregroundStyle(.secondary)
                }

                HoverIconButton(systemName: "chevron.right", size: 12, help: "下一个预设") {
                    viewModel.fmPresetUp()
                }

                Spacer(minLength: 8)

                VStack(spacing: 0) {
                    Text(viewModel.fmFrequency)
                        .font(.system(size: 30, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                    Text("MHz")
                        .font(.system(size: 9, weight: .semibold))
                        .tracking(0.8)
                        .foregroundStyle(.secondary)
                }

                VStack(spacing: 6) {
                    HoverIconButton(systemName: "chevron.up", size: 11, help: "频率 +") {
                        viewModel.fmFrequencyUp()
                    }
                    HoverIconButton(systemName: "chevron.down", size: 11, help: "频率 -") {
                        viewModel.fmFrequencyDown()
                    }
                }
            }
        }
        .padding(12)
        .cardStyle()
    }

    private var volumeCard: some View {
        VStack(spacing: 10) {
            HStack(spacing: 10) {
                Button {
                    viewModel.toggleMute()
                } label: {
                    Image(systemName: muteSymbol)
                        .font(.system(size: 15, weight: .medium))
                        .frame(width: 26, height: 26)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(viewModel.isMuted ? "取消静音" : "静音")

                Slider(
                    value: Binding(
                        get: { viewModel.volume },
                        set: { viewModel.userSetVolume($0) }
                    ),
                    in: viewModel.volumeMin...max(viewModel.volumeMin + 1, viewModel.volumeMax),
                    onEditingChanged: { viewModel.volumeEditingChanged($0) }
                )
                .tint(.accentColor)

                Text(viewModel.volumeText)
                    .font(.system(size: 12, weight: .medium))
                    .monospacedDigit()
                    .frame(width: 34, alignment: .trailing)
                    .foregroundStyle(.secondary)
            }

            Divider().opacity(0.35)

            HStack(spacing: 10) {
                Image(systemName: "hifispeaker")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)

                if viewModel.availableSources.isEmpty {
                    Text("--").font(.system(size: 12)).foregroundStyle(.secondary)
                } else {
                    GlassPicker(
                        options: viewModel.availableSources.map { (label: $0, value: Optional($0)) },
                        selection: viewModel.selectedSource,
                        fillsWidth: true,
                        onSelect: { if let source = $0 { viewModel.setSource(source) } }
                    )
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                Spacer(minLength: 4)

                SettingsButton { viewModel.openMenu() }
            }
        }
        .padding(12)
        .cardStyle()
    }

    private var muteSymbol: String {
        if viewModel.isMuted { return "speaker.slash.fill" }
        if viewModel.volume <= 0 { return "speaker.fill" }
        return "speaker.wave.2.fill"
    }

}

// MARK: - FM 预设名称编辑

private struct FmNameEditor: View {
    @ObservedObject var viewModel: MainViewModel

    @State private var isEditing = false
    @State private var draft = ""
    @FocusState private var isFocused: Bool

    var body: some View {
        if isEditing {
            HStack(spacing: 4) {
                TextField("预设名称", text: $draft)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 11))
                    .frame(width: 150)
                    .focused($isFocused)
                    .onSubmit(commit)

                HoverIconButton(systemName: "checkmark", size: 10, help: "保存") {
                    commit()
                }
                HoverIconButton(systemName: "xmark", size: 10, help: "取消") {
                    isEditing = false
                }
            }
        } else {
            HoverIconButton(systemName: "pencil", size: 11, help: "重命名预设") {
                draft = viewModel.fmPresetTitle
                isEditing = true
                isFocused = true
            }
        }
    }

    private func commit() {
        viewModel.updateFmPresetName(draft)
        isEditing = false
    }
}

// MARK: - 设置菜单页

private struct MenuSettingsView: View {
    @ObservedObject var viewModel: MainViewModel

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                HoverIconButton(systemName: "chevron.left", size: 13, help: "返回") {
                    viewModel.closeMenu()
                }

                Text("设置")
                    .font(.system(size: 18, weight: .semibold))

                Spacer()

                Text("ESC")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .fill(Color.primary.opacity(0.08))
                    )
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)

            Divider().opacity(0.35)

            if viewModel.menuGroups.isEmpty {
                VStack(spacing: 10) {
                    ProgressView()
                        .controlSize(.small)
                    Text("正在读取设备设置…")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 60)
            } else {
                // 不套 ScrollView：面板高度由内容撑开，菜单项有多少显示多少，
                // 面板总高由 StatusItemController 限制在屏幕可用高度内。
                menuList
            }
        }
    }

    private var menuList: some View {
        VStack(alignment: .leading, spacing: 18) {
            ForEach(viewModel.menuGroups) { group in
                menuGroup(group)
            }
        }
        .padding(16)
    }

    private func menuGroup(_ group: MenuGroup) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel(text: group.head)

            VStack(spacing: 0) {
                ForEach(Array(group.items.enumerated()), id: \.element.id) { index, item in
                    menuRow(item)
                    if index < group.items.count - 1 {
                        Divider()
                            .opacity(0.3)
                            .padding(.leading, 12)
                    }
                }
            }
            .cardStyle()
        }
    }

    private func menuRow(_ item: MenuItem) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 1) {
                Text(item.action ?? item.itemDescription ?? "Item \(item.id)")
                    .font(.system(size: 12.5, weight: .medium))
                    .lineLimit(1)

                if let description = item.itemDescription,
                   !description.isEmpty,
                   description != item.action {
                    Text(description)
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 8)

            if let options = item.items, !options.isEmpty {
                GlassPicker(
                    options: options.map { (label: $0.title, value: $0.value) },
                    selection: item.selectedValue,
                    fillsWidth: true,
                    onSelect: { viewModel.setMenuValue(itemID: item.id, value: $0) }
                )
                .frame(width: 190)
            } else {
                Text(String(item.selectedValue))
                    .font(.system(size: 12, weight: .medium))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
    }
}
