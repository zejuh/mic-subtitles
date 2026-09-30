// 所有设置：改了马上保存，下次打开还在

import AppKit
import SwiftUI

// 界面语言：默认英文（跟 OST 一样），可以切成中文
enum AppLanguage: String, CaseIterable, Identifiable {
    case english
    case chinese

    var id: String { rawValue }
    var label: String { self == .english ? "English" : "中文" }
    var locale: Locale { Locale(identifier: self == .english ? "en" : "zh-Hans") }
}

// 声音从哪来：电脑播放的声音（视频、会议），或者麦克风（现场讲话、扬声器）
enum AudioSource: String, CaseIterable, Identifiable {
    case systemAudio
    case microphone

    var id: String { rawValue }

    func label(_ language: AppLanguage) -> String {
        let english = language == .english
        switch self {
        case .systemAudio: return english ? "Mac audio (videos, calls)" : "电脑播放的声音（视频、会议）"
        case .microphone: return english ? "Microphone (in the room)" : "麦克风（现场讲话）"
        }
    }

    func shortLabel(_ language: AppLanguage) -> String {
        let english = language == .english
        switch self {
        case .systemAudio: return english ? "Mac audio" : "电脑声音"
        case .microphone: return english ? "Microphone" : "麦克风"
        }
    }
}

enum DisplayMode: String, CaseIterable, Identifiable {
    case both
    case translationOnly
    case sourceOnly

    var id: String { rawValue }

    func label(_ language: AppLanguage) -> String {
        let english = language == .english
        switch self {
        case .both: return english ? "Original and translation" : "原文和翻译"
        case .translationOnly: return english ? "Translation only" : "只显示翻译"
        case .sourceOnly: return english ? "Original only" : "只显示原文"
        }
    }
}

enum SubtitleAlignment: String, CaseIterable, Identifiable {
    case leading
    case center
    case trailing

    var id: String { rawValue }

    func label(_ language: AppLanguage) -> String {
        let english = language == .english
        switch self {
        case .leading: return english ? "Left" : "靠左"
        case .center: return english ? "Center" : "居中"
        case .trailing: return english ? "Right" : "靠右"
        }
    }

    var horizontal: HorizontalAlignment {
        switch self {
        case .leading: .leading
        case .center: .center
        case .trailing: .trailing
        }
    }

    var frame: Alignment {
        switch self {
        case .leading: .leading
        case .center: .center
        case .trailing: .trailing
        }
    }

    var text: TextAlignment {
        switch self {
        case .leading: .leading
        case .center: .center
        case .trailing: .trailing
        }
    }
}

struct RGBA: Equatable {
    var red: Double
    var green: Double
    var blue: Double
    var alpha: Double

    static let white = RGBA(red: 1, green: 1, blue: 1, alpha: 1)
    static let gray = RGBA(red: 0.72, green: 0.72, blue: 0.72, alpha: 1)
    static let black = RGBA(red: 0, green: 0, blue: 0, alpha: 1)

    var color: Color { Color(.sRGB, red: red, green: green, blue: blue, opacity: alpha) }
    var stored: [Double] { [red, green, blue, alpha] }
}

extension RGBA {
    init(_ color: Color) {
        let ns = NSColor(color).usingColorSpace(.sRGB) ?? .white
        self.init(
            red: Double(ns.redComponent),
            green: Double(ns.greenComponent),
            blue: Double(ns.blueComponent),
            alpha: Double(ns.alphaComponent)
        )
    }

    init?(stored: [Double]?) {
        guard let stored, stored.count == 4 else { return nil }
        self.init(red: stored[0], green: stored[1], blue: stored[2], alpha: stored[3])
    }
}

@MainActor
@Observable
final class Preferences {
    static let defaultFolder = FileManager.default
        .urls(for: .documentDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Subtitles", isDirectory: true).path

    enum Default {
        static let sourceFontSize = 15.0
        static let translationFontSize = 21.0
        static let sourceColor = RGBA.gray
        static let translationColor = RGBA.white
        static let backgroundColor = RGBA.black
        static let backgroundOpacity = 0.68
        static let pauseSeconds = 0.8
    }

    @ObservationIgnored private let store = UserDefaults.standard

    // 通用
    var appLanguage: AppLanguage { didSet { store.set(appLanguage.rawValue, forKey: "appLanguage") } }
    var audioSource: AudioSource { didSet { store.set(audioSource.rawValue, forKey: "audioSource") } }
    var sourceLocale: String { didSet { store.set(sourceLocale, forKey: "sourceLocale") } }
    var targetLanguage: String { didSet { store.set(targetLanguage, forKey: "targetLanguage") } }
    var inputDeviceUID: String { didSet { store.set(inputDeviceUID, forKey: "inputDevice") } }
    var inputDeviceName: String { didSet { store.set(inputDeviceName, forKey: "inputDeviceName") } }
    var pauseSeconds: Double { didSet { store.set(pauseSeconds, forKey: "pauseSeconds") } }

    // 外观
    var sourceFontSize: Double { didSet { store.set(sourceFontSize, forKey: "sourceFontSize") } }
    var translationFontSize: Double { didSet { store.set(translationFontSize, forKey: "translationFontSize") } }
    var sourceColor: RGBA { didSet { store.set(sourceColor.stored, forKey: "sourceColor") } }
    var translationColor: RGBA { didSet { store.set(translationColor.stored, forKey: "translationColor") } }
    var backgroundColor: RGBA { didSet { store.set(backgroundColor.stored, forKey: "backgroundColor") } }
    var backgroundOpacity: Double { didSet { store.set(backgroundOpacity, forKey: "backgroundOpacity") } }

    // 字幕条
    var displayMode: DisplayMode { didSet { store.set(displayMode.rawValue, forKey: "displayMode") } }
    var alignment: SubtitleAlignment { didSet { store.set(alignment.rawValue, forKey: "alignment") } }
    var overlayLocked: Bool { didSet { store.set(overlayLocked, forKey: "overlayLocked") } }
    var hideOverlayWhenStopped: Bool { didSet { store.set(hideOverlayWhenStopped, forKey: "hideOverlayWhenStopped") } }

    // 文字记录
    var saveTranscripts: Bool { didSet { store.set(saveTranscripts, forKey: "saveTranscripts") } }
    var transcriptFolder: String { didSet { store.set(transcriptFolder, forKey: "transcriptFolder") } }

    init() {
        let store = UserDefaults.standard
        appLanguage = AppLanguage(rawValue: store.string(forKey: "appLanguage") ?? "") ?? .english
        audioSource = AudioSource(rawValue: store.string(forKey: "audioSource") ?? "") ?? .microphone
        sourceLocale = store.string(forKey: "sourceLocale") ?? "en_US"
        targetLanguage = store.string(forKey: "targetLanguage") ?? "zh"
        inputDeviceUID = store.string(forKey: "inputDevice") ?? ""
        inputDeviceName = store.string(forKey: "inputDeviceName") ?? ""
        pauseSeconds = store.object(forKey: "pauseSeconds") as? Double ?? Default.pauseSeconds

        sourceFontSize = store.object(forKey: "sourceFontSize") as? Double ?? Default.sourceFontSize
        translationFontSize = store.object(forKey: "translationFontSize") as? Double ?? Default.translationFontSize
        sourceColor = RGBA(stored: store.array(forKey: "sourceColor") as? [Double]) ?? Default.sourceColor
        translationColor = RGBA(stored: store.array(forKey: "translationColor") as? [Double]) ?? Default.translationColor
        backgroundColor = RGBA(stored: store.array(forKey: "backgroundColor") as? [Double]) ?? Default.backgroundColor
        backgroundOpacity = store.object(forKey: "backgroundOpacity") as? Double ?? Default.backgroundOpacity

        displayMode = DisplayMode(rawValue: store.string(forKey: "displayMode") ?? "") ?? .both
        alignment = SubtitleAlignment(rawValue: store.string(forKey: "alignment") ?? "") ?? .leading
        overlayLocked = store.bool(forKey: "overlayLocked")
        hideOverlayWhenStopped = store.object(forKey: "hideOverlayWhenStopped") as? Bool ?? true

        saveTranscripts = store.object(forKey: "saveTranscripts") as? Bool ?? true
        transcriptFolder = store.string(forKey: "transcriptFolder") ?? Self.defaultFolder
    }

    // 按界面语言选文字：t("English", "中文")
    func t(_ english: String, _ chinese: String) -> String {
        appLanguage == .english ? english : chinese
    }

    func resetAppearance() {
        sourceFontSize = Default.sourceFontSize
        translationFontSize = Default.translationFontSize
        sourceColor = Default.sourceColor
        translationColor = Default.translationColor
        backgroundColor = Default.backgroundColor
        backgroundOpacity = Default.backgroundOpacity
    }
}
