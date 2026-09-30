// 麦克风字幕：用麦克风听现场讲话，实时显示原文 + 翻译。
// 跟 OST 一样是菜单栏小工具：没有普通窗口，字幕是一条浮在最上面的半透明字幕条。
// 识别用苹果的 SpeechAnalyzer，翻译用苹果的 Translation，全部在本机完成。
// 不碰系统声音、不静音、不改系统设置；每次的文字存到「文稿/Subtitles」（可在设置里改）。

import AppKit
import ServiceManagement
import SwiftUI

@MainActor
@Observable
final class AppController {
    let prefs: Preferences
    let model: Captioner
    let devices = DeviceMonitor()
    private(set) var overlayVisible = false
    private(set) var launchAtLogin = false
    private(set) var loginItemError: String?

    @ObservationIgnored private var overlay: OverlayController?
    @ObservationIgnored private var settingsWindow: NSWindow?
    @ObservationIgnored private var settingsTabs: NSTabViewController?

    init() {
        let prefs = Preferences()
        self.prefs = prefs
        model = Captioner(prefs: prefs)
    }

    func setUp() {
        overlay = OverlayController(model: model, prefs: prefs)
        model.onPhaseChange = { [weak self] phase in
            guard let self else { return }
            switch phase {
            case .starting: showOverlay()
            case .idle: if prefs.hideOverlayWhenStopped { hideOverlay() }
            default: break
            }
        }
        model.onError = { [weak self] message in
            guard let self else { return }
            Self.alert(title: prefs.t("Mic Subtitles couldn't start", "麦克风字幕没能开始"), message: message)
        }
        model.onNotice = { title, message in
            DispatchQueue.main.async { Self.alert(title: title, message: message) }
        }
        // 不挡住开始：先出原文，提示框另外弹
        model.onTranslationMissing = { [weak self] message in
            guard let self else { return }
            let prefs = prefs
            DispatchQueue.main.async {
                NSApp.activate()
                let alert = NSAlert()
                alert.messageText = prefs.t("Translation languages not downloaded", "翻译语言包还没下载")
                alert.informativeText = message
                alert.addButton(withTitle: prefs.t("Open Language & Region", "打开「语言与地区」"))
                alert.addButton(withTitle: prefs.t("OK", "好"))
                if alert.runModal() == .alertFirstButtonReturn,
                   let url = URL(string: "x-apple.systempreferences:com.apple.Localization-Settings.extension") {
                    NSWorkspace.shared.open(url)
                }
            }
        }
        refreshLaunchAtLogin()
        Task { await model.loadLanguages() }
    }

    // 声音来源：菜单和设置共用，正在转写时换了马上生效
    var audioSourceBinding: Binding<AudioSource> {
        Binding(
            get: { self.prefs.audioSource },
            set: {
                self.prefs.audioSource = $0
                self.model.audioSourceChanged()
            }
        )
    }

    // MARK: 字幕条

    func toggleOverlay() { overlayVisible ? hideOverlay() : showOverlay() }

    func scrollOverlayToTopForTesting() {
        overlay?.scrollToTopForTesting()
    }

    func jumpOverlayToLatestForTesting() {
        overlay?.jumpToLatestForTesting()
    }

    func resetOverlayPosition() {
        overlay?.resetPosition()
        showOverlay()
    }

    private func showOverlay() {
        overlay?.show()
        overlayVisible = true
    }

    private func hideOverlay() {
        overlay?.hide()
        overlayVisible = false
    }

    // MARK: 设置窗口

    // 跟 macOS 自带的设置窗口一样：顶上一排图标切换页面，窗口高度跟着页面走
    func showSettings(tab: SettingsTab? = nil) {
        if settingsWindow == nil {
            let tabs = NSTabViewController()
            tabs.tabStyle = .toolbar
            for page in SettingsTab.allCases {
                let host = NSHostingController(rootView: SettingsPageView(page: page, app: self))
                host.sizingOptions = [.preferredContentSize]
                let item = NSTabViewItem(viewController: host)
                item.image = NSImage(systemSymbolName: page.symbol, accessibilityDescription: nil)
                tabs.addTabViewItem(item)
            }
            let window = NSWindow(contentViewController: tabs)
            window.styleMask = [.titled, .closable, .miniaturizable]
            window.toolbarStyle = .preference
            window.isReleasedWhenClosed = false
            settingsTabs = tabs
            settingsWindow = window
            refreshSettingsTitles()
        }
        if settingsWindow?.isVisible == false {
            settingsWindow?.center()
        }
        NSApp.activate()
        settingsWindow?.makeKeyAndOrderFront(nil)
        if let tab, let index = SettingsTab.allCases.firstIndex(of: tab) {
            DispatchQueue.main.async { [weak self] in
                self?.settingsTabs?.selectedTabViewItemIndex = index
                self?.refreshSettingsTitles()
            }
        }
    }

    // 界面语言变了：页签名字、窗口标题、语言列表跟着换
    func appLanguageChanged() {
        refreshSettingsTitles()
        Task { await model.loadLanguages() }
    }

    private func refreshSettingsTitles() {
        guard let tabs = settingsTabs else { return }
        for (index, page) in SettingsTab.allCases.enumerated() where index < tabs.tabViewItems.count {
            let title = page.title(prefs.appLanguage)
            tabs.tabViewItems[index].label = title
            tabs.tabViewItems[index].viewController?.title = title
        }
        settingsWindow?.title = tabs.tabViewItems[tabs.selectedTabViewItemIndex].label
    }

    func chooseTranscriptFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = prefs.t("Choose", "选这个文件夹")
        panel.message = prefs.t("Choose a folder for transcripts", "选一个文件夹，用来保存文字记录")
        panel.directoryURL = URL(fileURLWithPath: prefs.transcriptFolder, isDirectory: true)
        NSApp.activate()
        if panel.runModal() == .OK, let url = panel.url {
            prefs.transcriptFolder = url.path
        }
    }

    // MARK: 开机时自动打开

    func setLaunchAtLogin(_ on: Bool) {
        do {
            if on {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            loginItemError = nil
        } catch {
            loginItemError = prefs.t("Couldn't change this: ", "没设置成功：") + error.localizedDescription
        }
        refreshLaunchAtLogin()
    }

    private func refreshLaunchAtLogin() {
        let status = SMAppService.mainApp.status
        launchAtLogin = status == .enabled
        if status == .requiresApproval {
            loginItemError = prefs.t(
                "Also allow it in System Settings → General → Login Items & Extensions.",
                "还需要在「系统设置 → 通用 → 登录项与扩展」里允许「麦克风字幕」。"
            )
        }
    }

    static func alert(title: String, message: String) {
        NSApp.activate()
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.runModal()
    }
}

// MARK: - 菜单栏

struct MenuBarView: View {
    let app: AppController

    var body: some View {
        @Bindable var prefs = app.prefs
        let model = app.model
        Group {
            Text(model.status)

            Divider()

            Button(model.isRunning ? prefs.t("Stop", "停止") : prefs.t("Start", "开始")) { model.toggle() }
                .disabled(model.isBusy)

            Picker(prefs.t("Source: ", "声音来源：") + prefs.audioSource.shortLabel(prefs.appLanguage), selection: app.audioSourceBinding) {
                ForEach(AudioSource.allCases) { Text($0.label(prefs.appLanguage)).tag($0) }
            }

            Picker(prefs.t("Speech: ", "说话语言：") + model.sourceName, selection: $prefs.sourceLocale) {
                speechLanguageOptions(model)
            }
            .disabled(model.phase != .idle)

            Picker(prefs.t("Translate to: ", "翻译成：") + model.targetName, selection: $prefs.targetLanguage) {
                translationLanguageOptions(model)
            }
            .disabled(model.phase != .idle)

            Divider()

            Button(app.overlayVisible ? prefs.t("Hide Subtitles", "隐藏字幕条") : prefs.t("Show Subtitles", "显示字幕条")) {
                app.toggleOverlay()
            }
            Button(prefs.overlayLocked ? prefs.t("Unlock Subtitles", "解锁字幕条") : prefs.t("Lock Subtitles", "锁定字幕条")) {
                prefs.overlayLocked.toggle()
            }
            Button(prefs.t("Clear Subtitles", "清空字幕条")) { model.clearLines() }
                .disabled(model.lines.isEmpty)

            Divider()

            Button(prefs.t("Open Transcripts Folder", "打开文字记录文件夹")) { model.openTranscriptFolder() }
            Button(prefs.t("Settings…", "设置…")) { app.showSettings() }
                .keyboardShortcut(",")

            Divider()

            Button(prefs.t("Quit", "退出")) { NSApp.terminate(nil) }
                .keyboardShortcut("q")
        }
    }
}

// MARK: - App

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let app = AppController()

    func applicationDidFinishLaunching(_ notification: Notification) {
        app.setUp()
        // 调试用：--settings <页面> 打开设置；--test-file <音频> 用音频文件代替麦克风，放完自动退出
        let args = CommandLine.arguments
        if let index = args.firstIndex(of: "--settings") {
            let tab = index + 1 < args.count ? SettingsTab(rawValue: args[index + 1]) : nil
            app.showSettings(tab: tab)
        }
        if let index = args.firstIndex(of: "--test-file"), index + 1 < args.count {
            let url = URL(fileURLWithPath: args[index + 1])
            Task { await app.model.start(testFile: url) }
        }
        // 调试用：--test-start 一打开就开始（用当前设置）
        if args.contains("--test-start") {
            Task { await app.model.start() }
        }
        // 调试用：--test-scroll-up <秒>、--test-jump-latest <秒>，到时候模拟往上翻、点「回到最新」
        if let index = args.firstIndex(of: "--test-scroll-up"), index + 1 < args.count,
           let seconds = Double(args[index + 1]) {
            Task {
                try? await Task.sleep(for: .seconds(seconds))
                app.scrollOverlayToTopForTesting()
            }
        }
        if let index = args.firstIndex(of: "--test-jump-latest"), index + 1 < args.count,
           let seconds = Double(args[index + 1]) {
            Task {
                try? await Task.sleep(for: .seconds(seconds))
                app.jumpOverlayToLatestForTesting()
            }
        }
    }

    // 退出前先收尾，最后几句也能存进文字记录
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard app.model.isRunning else { return .terminateNow }
        Task {
            await app.model.stop()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}

@main
struct MicSubtitlesApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra {
            MenuBarView(app: appDelegate.app)
        } label: {
            Image(systemName: appDelegate.app.model.isRunning ? "captions.bubble.fill" : "captions.bubble")
        }
    }
}
