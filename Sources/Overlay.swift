// 字幕条：没有边框、浮在最上面的半透明条，可以往上翻看之前的内容

import AppKit
import SwiftUI

// 字幕内容（字幕条和设置里的预览共用）
struct SubtitleLines: View {
    let lines: [Line]
    let preview: String
    let previewTranslation: String
    let placeholder: String?
    let prefs: Preferences

    var body: some View {
        VStack(alignment: prefs.alignment.horizontal, spacing: 8) {
            if lines.isEmpty, preview.isEmpty, let placeholder {
                Text(placeholder)
                    .font(.caption)
                    .foregroundStyle(Color(white: 0.75))
            }
            ForEach(lines) { line in
                lineView(line)
            }
            if !preview.isEmpty {
                previewView  // 正在讲的这句：原文实时变，翻译先出一版预览
            }
        }
        .multilineTextAlignment(prefs.alignment.text)
        .frame(maxWidth: .infinity, alignment: prefs.alignment.frame)
    }

    @ViewBuilder
    private func lineView(_ line: Line) -> some View {
        VStack(alignment: prefs.alignment.horizontal, spacing: 2) {
            switch prefs.displayMode {
            case .both:
                sourceText(line.original, pending: false)
                if let translation = line.translation {
                    translationText(translation)
                }
            case .translationOnly:
                if let translation = line.translation {
                    translationText(translation)
                } else {
                    sourceText(line.original, pending: true)  // 翻译还没出来（或者不翻译）时先显示原文
                }
            case .sourceOnly:
                sourceText(line.original, pending: false)
            }
        }
    }

    @ViewBuilder
    private var previewView: some View {
        VStack(alignment: prefs.alignment.horizontal, spacing: 2) {
            switch prefs.displayMode {
            case .both:
                sourceText(preview, pending: true)
                if !previewTranslation.isEmpty {
                    translationText(previewTranslation, pending: true)
                }
            case .translationOnly:
                if previewTranslation.isEmpty {
                    sourceText(preview, pending: true)
                } else {
                    translationText(previewTranslation, pending: true)
                }
            case .sourceOnly:
                sourceText(preview, pending: true)
            }
        }
    }

    private func sourceText(_ text: String, pending: Bool) -> some View {
        Text(text)
            .font(.system(size: prefs.sourceFontSize))
            .foregroundStyle(prefs.sourceColor.color.opacity(pending ? 0.7 : 1))
    }

    private func translationText(_ text: String, pending: Bool = false) -> some View {
        Text(text)
            .font(.system(size: prefs.translationFontSize, weight: .medium))
            .foregroundStyle(prefs.translationColor.color.opacity(pending ? 0.6 : 1))
    }
}

// 字幕条的滚动状态（命令行编译用不了 @State，放在这里）
@MainActor
@Observable
final class OverlayScrollState {
    var position = ScrollPosition(edge: .bottom)
    var followLatest = true  // 在最底下就跟着新字幕走；往上翻时不打扰
    var atBottom = true

    func jumpToLatest() {
        followLatest = true
        position.scrollTo(edge: .bottom)
    }
}

struct OverlayView: View {
    let model: Captioner
    let prefs: Preferences
    let scroll: OverlayScrollState

    var body: some View {
        // 在这里读一次滚动位置，位置一变界面才会跟着刷新（比如点「回到最新」）
        let position = scroll.position
        ScrollView(.vertical) {
            SubtitleLines(
                lines: model.lines,
                preview: model.preview,
                previewTranslation: model.previewTranslation,
                placeholder: model.status,
                prefs: prefs
            )
                .padding(.horizontal, 18)
        }
        .scrollPosition(Binding(get: { position }, set: { scroll.position = $0 }))
        .defaultScrollAnchor(.bottom, for: .initialOffset)
        .defaultScrollAnchor(.bottom, for: .alignment)
        .defaultScrollAnchor(scroll.followLatest ? .bottom : .top, for: .sizeChanges)
        .onScrollGeometryChange(for: Bool.self) { geometry in
            Self.isAtBottom(geometry)
        } action: { _, atBottom in
            scroll.atBottom = atBottom
        }
        .onScrollPhaseChange { _, phase in
            switch phase {
            case .idle: scroll.followLatest = scroll.atBottom  // 滚完了：停在最底下就继续跟
            case .animating: break
            default: scroll.followLatest = false  // 用户正在滚动
            }
        }
        .onChange(of: model.revision) {
            if scroll.followLatest { scroll.position.scrollTo(edge: .bottom) }
        }
        .onChange(of: prefs.overlayLocked) {
            if prefs.overlayLocked { scroll.jumpToLatest() }  // 锁定后没法滚动，回到最新
        }
        .padding(.vertical, 12)  // 上下边距留在字幕条上，不随内容滚走，顶上也有空
        .overlay(alignment: .bottomTrailing) {
            if !scroll.followLatest {
                Button(action: scroll.jumpToLatest) {
                    Label(prefs.t("Latest", "回到最新"), systemImage: "arrow.down")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(Capsule().fill(Color(white: 0.18)))
                        .overlay(Capsule().stroke(Color.white.opacity(0.3), lineWidth: 1))
                }
                .buttonStyle(.plain)
                .padding(10)
            }
        }
        .background(prefs.backgroundColor.color.opacity(prefs.backgroundOpacity))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .contentShape(Rectangle())
        .gesture(WindowDragGesture(), isEnabled: !prefs.overlayLocked)
        .environment(\EnvironmentValues.colorScheme, .dark)
    }

    private static func isAtBottom(_ geometry: ScrollGeometry) -> Bool {
        geometry.contentOffset.y + geometry.containerSize.height >= geometry.contentSize.height - 30
    }
}

final class SubtitlePanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class OverlayController {
    private let panel: SubtitlePanel
    private let prefs: Preferences
    private let scroll = OverlayScrollState()
    private static let frameName = "MicSubtitlesOverlay"

    var isVisible: Bool { panel.isVisible }

    init(model: Captioner, prefs: Preferences) {
        self.prefs = prefs
        panel = SubtitlePanel(
            contentRect: Self.defaultFrame(),
            styleMask: [.borderless, .nonactivatingPanel, .resizable],
            backing: .buffered,
            defer: false
        )
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.isReleasedWhenClosed = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.minSize = NSSize(width: 320, height: 80)

        // 字幕条大小由用户决定，不跟着文字变：内容放进普通容器里，
        // 只跟着容器伸缩，SwiftUI 的内容高度就撑不大窗口
        let host = NSHostingView(rootView: OverlayView(model: model, prefs: prefs, scroll: scroll))
        host.sizingOptions = []
        let container = NSView(frame: NSRect(origin: .zero, size: Self.defaultFrame().size))
        host.frame = container.bounds
        host.autoresizingMask = [.width, .height]
        container.addSubview(host)
        panel.contentView = container

        panel.setFrameAutosaveName(Self.frameName)
        panel.setFrameUsingName(Self.frameName)
        if !NSScreen.screens.contains(where: { $0.visibleFrame.intersects(panel.frame) }) {
            panel.setFrame(Self.defaultFrame(), display: false)
        }
        applyLock()
        observeLock()
    }

    func show() { panel.orderFrontRegardless() }
    func hide() { panel.orderOut(nil) }

    func resetPosition() {
        panel.setFrame(Self.defaultFrame(), display: true)
    }

    // 调试用：模拟用户往上翻到最顶上、点「回到最新」
    func scrollToTopForTesting() {
        scroll.followLatest = false
        scroll.position.scrollTo(y: 0)
    }

    func jumpToLatestForTesting() {
        scroll.jumpToLatest()
    }

    // 锁定后鼠标能直接点穿字幕条，不会挡住下面的东西
    private func applyLock() {
        panel.ignoresMouseEvents = prefs.overlayLocked
        if prefs.overlayLocked {
            panel.styleMask.remove(.resizable)
        } else {
            panel.styleMask.insert(.resizable)
        }
    }

    private func observeLock() {
        withObservationTracking {
            _ = prefs.overlayLocked
        } onChange: { [weak self] in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self?.applyLock()
                    self?.observeLock()
                }
            }
        }
    }

    // 默认放在屏幕下方正中
    private static func defaultFrame() -> NSRect {
        guard let visible = NSScreen.main?.visibleFrame ?? NSScreen.screens.first?.visibleFrame else {
            return NSRect(x: 100, y: 100, width: 760, height: 190)
        }
        let width = min(820, visible.width - 80)
        return NSRect(x: visible.midX - width / 2, y: visible.minY + 60, width: width, height: 190)
    }
}
