// 设置窗口（参照 OST）：顶上一排图标切换页面，每页是几组浅灰色的圆角分组

import SwiftUI

enum SettingsTab: String, CaseIterable {
    case general
    case appearance
    case overlay
    case transcripts

    func title(_ language: AppLanguage) -> String {
        let english = language == .english
        switch self {
        case .general: return english ? "General" : "通用"
        case .appearance: return english ? "Appearance" : "外观"
        case .overlay: return english ? "Subtitles" : "字幕条"
        case .transcripts: return english ? "Transcripts" : "文字记录"
        }
    }

    // 每页的高度正好放下内容，切换页面时窗口跟着变高变矮
    var height: CGFloat {
        switch self {
        case .general: 690
        case .appearance: 640
        case .overlay: 640
        case .transcripts: 470
        }
    }

    var symbol: String {
        switch self {
        case .general: "gearshape"
        case .appearance: "paintpalette"
        case .overlay: "captions.bubble"
        case .transcripts: "doc.text"
        }
    }
}

struct SettingsPageView: View {
    let page: SettingsTab
    let app: AppController

    var body: some View {
        Group {
            switch page {
            case .general: GeneralSettings(app: app)
            case .appearance: AppearanceSettings(prefs: app.prefs)
            case .overlay: OverlaySettings(app: app)
            case .transcripts: TranscriptSettings(app: app)
            }
        }
        .formStyle(.grouped)
        .frame(width: 640, height: page.height)
    }
}

private func note(_ text: String) -> some View {
    Text(text)
        .font(.caption)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
}

// MARK: - 语言选项（菜单栏和设置共用）

@MainActor @ViewBuilder
func speechLanguageOptions(_ model: Captioner) -> some View {
    let prefs = model.prefs
    Section(prefs.t("Downloaded", "已下载")) {
        ForEach(model.installedSpeech) { Text($0.name).tag($0.id) }
    }
    Section(prefs.t("Downloads on first use", "第一次用会自动下载")) {
        ForEach(model.downloadableSpeech) { Text($0.name).tag($0.id) }
    }
}

@MainActor @ViewBuilder
func translationLanguageOptions(_ model: Captioner) -> some View {
    Text(model.prefs.t("No translation (original only)", "不翻译（只出原文）")).tag(Languages.noTranslation)
    Divider()
    ForEach(model.translationTargets) { Text($0.name).tag($0.id) }
}

// MARK: - 通用

private struct GeneralSettings: View {
    let app: AppController

    var body: some View {
        @Bindable var prefs = app.prefs
        let model = app.model
        let idle = model.phase == .idle
        Form {
            Section {
                Picker(prefs.t("App language", "界面语言"), selection: languageBinding) {
                    ForEach(AppLanguage.allCases) { Text($0.label).tag($0) }
                }
            }

            Section(prefs.t("Languages", "语言")) {
                Picker(prefs.t("Speech language", "说话语言"), selection: $prefs.sourceLocale) {
                    speechLanguageOptions(model)
                }
                Picker(prefs.t("Translate to", "翻译成"), selection: $prefs.targetLanguage) {
                    translationLanguageOptions(model)
                }
                note(idle
                     ? prefs.t("Languages under “Downloads on first use” download Apple’s speech recognition the first time you start. This needs internet and takes a moment.",
                               "「第一次用会自动下载」里的语言，第一次开始时会先从苹果下载识别资源，要联网，稍等一会儿。")
                     : prefs.t("Stop first to change languages.", "正在转写时不能改语言，先停止。"))
            }
            .disabled(!idle)

            Section(prefs.t("Audio source", "声音来源")) {
                Picker(prefs.t("Listen to", "听哪里的声音"), selection: app.audioSourceBinding) {
                    ForEach(AudioSource.allCases) { Text($0.label(prefs.appLanguage)).tag($0) }
                }
                if prefs.audioSource == .microphone {
                    Picker(prefs.t("Microphone", "麦克风"), selection: deviceBinding) {
                        Text(prefs.t("System default", "系统默认") + " (\(app.devices.defaultName))").tag("")
                        ForEach(app.devices.inputs) { Text($0.name).tag($0.uid) }
                        if !prefs.inputDeviceUID.isEmpty, app.devices.name(for: prefs.inputDeviceUID) == nil {
                            Text(prefs.inputDeviceName + prefs.t(" (not connected)", "（没连接）")).tag(prefs.inputDeviceUID)
                        }
                    }
                }
                LabeledContent(prefs.t("Input level", "音量")) {
                    LevelMeter(level: model.isRunning ? model.level : 0)
                }
                note(prefs.audioSource == .microphone
                     ? prefs.t("For people speaking in the room, or sound from loudspeakers. While running, the green bar moves when you speak; if it doesn’t, this microphone isn’t hearing you.",
                               "用于现场有人讲话，或者扬声器放出来的声音。转写时讲话，绿条会跳动；不动就是这个麦克风没听到。")
                     : prefs.t("For what this Mac plays: videos, online classes, meetings. Works even when the Mac is muted. The first time, macOS asks to allow recording system audio.",
                               "用于电脑正在播放的声音：视频、网课、会议。Mac 静音时也能用。第一次用时，系统会问要不要允许录制系统声音。"))
            }

            Section(prefs.t("Sentence breaks", "断句")) {
                LabeledContent(prefs.t("Pause length", "停顿多久算一句结束")) {
                    HStack {
                        Slider(value: pauseBinding, in: 0.4...2.0, step: 0.1)
                            .frame(width: 200)
                        Text(String(format: prefs.t("%.1f sec", "%.1f 秒"), prefs.pauseSeconds))
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                            .frame(width: 56, alignment: .trailing)
                    }
                }
                note(prefs.t("For Chinese, Cantonese, Japanese and Korean: after a pause this long, the sentence is finished and translated. Shorter is faster; longer keeps sentences whole. English and other languages split sentences on their own.",
                             "用于中文、粤语、日语、韩语：停顿这么久，就把这一句定下来并翻译。短一点翻译出来更快，长一点句子更完整。英语等语言由识别器自己断句。"))
            }

            Section {
                Toggle(prefs.t("Open at login", "开机时自动打开"), isOn: loginBinding)
                if let error = app.loginItemError {
                    Text(error).font(.caption).foregroundStyle(.orange)
                }
            }
        }
    }

    private var languageBinding: Binding<AppLanguage> {
        Binding(
            get: { app.prefs.appLanguage },
            set: {
                app.prefs.appLanguage = $0
                app.appLanguageChanged()
            }
        )
    }

    private var deviceBinding: Binding<String> {
        Binding(
            get: { app.prefs.inputDeviceUID },
            set: { uid in
                app.prefs.inputDeviceUID = uid
                app.prefs.inputDeviceName = app.devices.name(for: uid) ?? ""
                app.model.inputDeviceChanged()
            }
        )
    }

    private var pauseBinding: Binding<Double> {
        Binding(
            get: { app.prefs.pauseSeconds },
            set: {
                app.prefs.pauseSeconds = $0
                app.model.pauseChanged()
            }
        )
    }

    private var loginBinding: Binding<Bool> {
        Binding(get: { app.launchAtLogin }, set: { app.setLaunchAtLogin($0) })
    }
}

private struct LevelMeter: View {
    let level: Double

    var body: some View {
        Capsule()
            .fill(Color.secondary.opacity(0.2))
            .frame(width: 200, height: 6)
            .overlay(alignment: .leading) {
                Capsule()
                    .fill(Color.green)
                    .frame(width: 200 * level, height: 6)
            }
    }
}

// MARK: - 外观

private struct AppearanceSettings: View {
    let prefs: Preferences

    var body: some View {
        @Bindable var prefs = prefs
        Form {
            Section(prefs.t("Original", "原文")) {
                LabeledContent(prefs.t("Text size", "字号")) { sizeSlider($prefs.sourceFontSize) }
                ColorPicker(prefs.t("Text color", "颜色"), selection: colorBinding(\.sourceColor), supportsOpacity: true)
            }
            Section(prefs.t("Translation", "翻译")) {
                LabeledContent(prefs.t("Text size", "字号")) { sizeSlider($prefs.translationFontSize) }
                ColorPicker(prefs.t("Text color", "颜色"), selection: colorBinding(\.translationColor), supportsOpacity: true)
            }
            Section(prefs.t("Background", "背景")) {
                ColorPicker(prefs.t("Background color", "背景颜色"), selection: colorBinding(\.backgroundColor), supportsOpacity: false)
                LabeledContent(prefs.t("Opacity", "不透明度")) {
                    HStack {
                        Slider(value: $prefs.backgroundOpacity, in: 0...1, step: 0.05)
                            .frame(width: 200)
                        Text("\(Int((prefs.backgroundOpacity * 100).rounded()))%")
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                            .frame(width: 56, alignment: .trailing)
                    }
                }
            }
            Section {
                Button(prefs.t("Restore Default Appearance", "恢复默认外观")) { prefs.resetAppearance() }
            }
        }
    }

    private func sizeSlider(_ value: Binding<Double>) -> some View {
        HStack {
            Slider(value: value, in: 10...48, step: 1)
                .frame(width: 200)
            Text("\(Int(value.wrappedValue)) pt")
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(width: 56, alignment: .trailing)
        }
    }

    private func colorBinding(_ keyPath: ReferenceWritableKeyPath<Preferences, RGBA>) -> Binding<Color> {
        Binding(
            get: { prefs[keyPath: keyPath].color },
            set: { prefs[keyPath: keyPath] = RGBA($0) }
        )
    }
}

// MARK: - 字幕条

private struct OverlaySettings: View {
    let app: AppController

    var body: some View {
        @Bindable var prefs = app.prefs
        Form {
            Section(prefs.t("Layout", "显示")) {
                Picker(prefs.t("Show", "显示内容"), selection: $prefs.displayMode) {
                    ForEach(DisplayMode.allCases) { Text($0.label(prefs.appLanguage)).tag($0) }
                }
                Picker(prefs.t("Alignment", "对齐"), selection: $prefs.alignment) {
                    ForEach(SubtitleAlignment.allCases) { Text($0.label(prefs.appLanguage)).tag($0) }
                }
            }
            Section(prefs.t("Subtitle bar", "字幕条")) {
                Toggle(prefs.t("Lock subtitle bar", "锁定字幕条"), isOn: $prefs.overlayLocked)
                note(prefs.t("When locked, clicks pass through and nothing underneath is blocked, but you can’t move, resize or scroll it. When unlocked, drag to move, drag an edge to resize, and scroll to see earlier lines.",
                             "锁定后字幕条不挡下面的东西，但不能拖动、调整大小或往上翻看。解锁时：拖动字幕条可以移动，拖边缘可以调整大小，在上面滚动可以翻看之前的内容。"))
                Toggle(prefs.t("Hide when stopped", "停止后自动隐藏"), isOn: $prefs.hideOverlayWhenStopped)
                note(prefs.t("Turn this off to keep the subtitle bar on screen after stopping, so you can scroll back through the session.",
                             "关掉的话，停止后字幕条留在屏幕上，可以继续往上翻看这次的内容。"))
                HStack {
                    Button(app.overlayVisible ? prefs.t("Hide Subtitles", "隐藏字幕条") : prefs.t("Show Subtitles", "显示字幕条")) {
                        app.toggleOverlay()
                    }
                    Button(prefs.t("Reset Position", "放回屏幕下方")) { app.resetOverlayPosition() }
                }
            }
        }
    }
}

// MARK: - 文字记录

private struct TranscriptSettings: View {
    let app: AppController

    var body: some View {
        @Bindable var prefs = app.prefs
        Form {
            Section {
                Toggle(prefs.t("Save a transcript for each session", "每次都保存文字记录"), isOn: $prefs.saveTranscripts)
                note(prefs.t("Like OST, each session (Start to Stop) is saved as two .txt files: …-transcript.txt with the original and …-translation.txt with the translation, line by line. Sessions with nothing recognized aren’t saved. No audio is recorded.",
                             "跟 OST 一样，每次从「开始」到「停止」存两个 txt 文件：…-transcript.txt 是原文，…-translation.txt 是翻译，一行对一行。一句都没录到就不存。不会录音。"))
            }
            Section(prefs.t("Folder", "保存位置")) {
                HStack {
                    Image(systemName: "folder")
                        .foregroundStyle(.secondary)
                    Text(displayPath(prefs.transcriptFolder))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                    Button(prefs.t("Change…", "更改…")) { app.chooseTranscriptFolder() }
                    Button(prefs.t("Show in Finder", "在访达中打开")) { app.model.openTranscriptFolder() }
                }
                if prefs.transcriptFolder != Preferences.defaultFolder {
                    Button(prefs.t("Use Default Folder (Documents/Subtitles)", "改回默认位置（文稿/Subtitles）")) {
                        prefs.transcriptFolder = Preferences.defaultFolder
                    }
                }
                note(prefs.t("A new folder is used from the next Start.", "换了位置以后，从下次「开始」起存到新位置。"))
            }
            Section(prefs.t("Privacy", "隐私")) {
                note(prefs.t("Audio, text and translations are processed only on this Mac and never uploaded.",
                             "声音、文字和翻译都只在这台 Mac 上处理，不会上传。"))
                note(prefs.t("The first time you use a speech language, its speech recognition files are downloaded from Apple.",
                             "第一次用某种说话语言时，会从苹果下载这种语言的语音识别资源。"))
            }
        }
    }

    private func displayPath(_ path: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
    }
}
