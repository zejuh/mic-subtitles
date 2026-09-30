// 字幕引擎：麦克风 → 苹果语音识别 → 苹果翻译 → 字幕和文字记录，全部在本机完成

import AVFoundation
import AppKit
import Speech
import Synchronization
import Translation

struct Line: Identifiable {
    let id = UUID()
    let original: String
    var translation: String?
}

enum CaptionError: Error {
    case speechUnavailable
    case languageUnsupported
    case noMicrophone
    case audioFormat

    @MainActor
    func message(_ prefs: Preferences) -> String {
        switch self {
        case .speechUnavailable: prefs.t("Apple speech recognition isn't available on this Mac right now", "这台 Mac 现在用不了苹果的语音识别")
        case .languageUnsupported: prefs.t("Speech recognition doesn't support this language", "语音识别不支持这种语言")
        case .noMicrophone: prefs.t("No microphone found", "找不到可用的麦克风")
        case .audioFormat: prefs.t("Couldn't convert the microphone audio", "麦克风的声音格式转换失败")
        }
    }
}

// 讲话停顿多久算一句结束（只用在中日韩，见 Languages.splitsOnPauses）。在音频线程里调用
final class PauseDetector: Sendable {
    private struct State {
        var pause: Double
        var noiseFloor: Float = 0.003
        var silentSeconds: Double = 0
        var heardSpeech = false
    }

    private let state: Mutex<State>

    init(pause: Double) {
        state = Mutex(State(pause: pause))
    }

    func setPause(_ seconds: Double) {
        state.withLock { $0.pause = seconds }
    }

    // 返回 true 表示刚讲完一段
    func observe(rms: Float, seconds: Double) -> Bool {
        state.withLock { state in
            state.noiseFloor = rms < state.noiseFloor ? rms : state.noiseFloor + (rms - state.noiseFloor) * 0.01
            if rms > max(state.noiseFloor * 3, 0.004) {
                state.heardSpeech = true
                state.silentSeconds = 0
                return false
            }
            state.silentSeconds += seconds
            guard state.heardSpeech, state.silentSeconds >= state.pause else { return false }
            state.heardSpeech = false
            return true
        }
    }
}

// 把任意格式的声音转成识别器要的格式再交给它（换了麦克风、格式变了也能接上）
final class AudioFeeder: @unchecked Sendable {
    private let target: AVAudioFormat
    private let continuation: AsyncStream<AnalyzerInput>.Continuation
    private var converter: AVAudioConverter?

    init(target: AVAudioFormat, continuation: AsyncStream<AnalyzerInput>.Continuation) {
        self.target = target
        self.continuation = continuation
    }

    func feed(_ buffer: AVAudioPCMBuffer) {
        if converter?.inputFormat != buffer.format {
            converter = AVAudioConverter(from: buffer.format, to: target)
            converter?.downmix = true
        }
        guard let converter, let converted = convert(buffer, with: converter) else { return }
        continuation.yield(AnalyzerInput(buffer: converted))
    }

    private func convert(_ buffer: AVAudioPCMBuffer, with converter: AVAudioConverter) -> AVAudioPCMBuffer? {
        let ratio = target.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio + 64)
        guard let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return nil }
        var supplied = false
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, inputStatus in
            if supplied {
                inputStatus.pointee = .noDataNow
                return nil
            }
            supplied = true
            inputStatus.pointee = .haveData
            return buffer
        }
        return status == .error || output.frameLength == 0 ? nil : output
    }
}

@MainActor
@Observable
final class Captioner {
    enum Phase { case idle, starting, running, stopping }

    let prefs: Preferences

    private(set) var phase: Phase = .idle {
        didSet { onPhaseChange?(phase) }
    }
    private(set) var lines: [Line] = []
    private(set) var preview = ""
    private(set) var previewTranslation = ""
    private(set) var level: Double = 0
    private(set) var status = ""
    private(set) var revision = 0
    private(set) var installedSpeech: [LanguageOption] = []
    private(set) var downloadableSpeech: [LanguageOption] = []
    private(set) var translationTargets: [LanguageOption] = []

    @ObservationIgnored var onPhaseChange: ((Phase) -> Void)?
    @ObservationIgnored var onError: ((String) -> Void)?
    @ObservationIgnored var onNotice: ((String, String) -> Void)?
    @ObservationIgnored var onTranslationMissing: ((String) -> Void)?

    var isRunning: Bool { phase == .running }
    var isBusy: Bool { phase == .starting || phase == .stopping }
    var sourceName: String { Languages.speechName(prefs.sourceLocale, in: prefs.appLanguage.locale) }
    var targetName: String {
        prefs.targetLanguage == Languages.noTranslation
            ? prefs.t("No translation", "不翻译")
            : Languages.translationName(prefs.targetLanguage, in: prefs.appLanguage.locale)
    }

    @ObservationIgnored private var engine: AVAudioEngine?
    @ObservationIgnored private var systemCapture: SystemAudioCapture?
    @ObservationIgnored private var configObserver: NSObjectProtocol?
    @ObservationIgnored private var analyzer: SpeechAnalyzer?
    @ObservationIgnored private var analyzerFormat: AVAudioFormat?
    @ObservationIgnored private var inputContinuation: AsyncStream<AnalyzerInput>.Continuation?
    @ObservationIgnored private var pauses: PauseDetector?
    @ObservationIgnored private var resultsTask: Task<Void, Never>?
    @ObservationIgnored private var fileFeedTask: Task<Void, Never>?
    @ObservationIgnored private var translation: TranslationSession?
    @ObservationIgnored private var previewSession: TranslationSession?
    @ObservationIgnored private var previewTask: Task<Void, Never>?
    @ObservationIgnored private var translateChain: Task<Void, Never>?
    @ObservationIgnored private var reservedLocale: Locale?
    @ObservationIgnored private var transcriptFile: FileHandle?
    @ObservationIgnored private var translationFile: FileHandle?
    @ObservationIgnored private var sessionFiles: [URL] = []
    @ObservationIgnored private var savedLines = 0

    init(prefs: Preferences) {
        self.prefs = prefs
        status = prefs.t("Ready", "等待开始")
    }

    @ObservationIgnored private var traceStart = Date()
    private static let tracing = ProcessInfo.processInfo.environment["MICSUB_TRACE"] != nil
    private func trace(_ text: String) {
        guard Self.tracing else { return }
        FileHandle.standardError.write(Data(String(format: "TRACE %6.2f %@\n", Date().timeIntervalSince(traceStart), text).utf8))
    }

    private func describe(_ error: Error) -> String {
        if let error = error as? CaptionError { return error.message(prefs) }
        if let error = error as? SystemAudioError {
            switch error {
            case .permissionDenied:
                return prefs.t(
                    "No permission to capture this Mac’s audio. Allow it in System Settings → Privacy & Security → Screen & System Audio Recording.",
                    "没有录制电脑声音的权限。请到「系统设置 → 隐私与安全性 → 录屏与系统录音」里允许「麦克风字幕」。"
                )
            case .failed(let step, let status):
                return prefs.t("Couldn't capture this Mac’s audio", "没能抓到电脑的声音") + " (\(step), \(status))"
            }
        }
        return error.localizedDescription
    }

    func loadLanguages() async {
        let supported = await SpeechTranscriber.supportedLocales
        let installed = Set(await SpeechTranscriber.installedLocales.map(\.identifier))
        let locale = prefs.appLanguage.locale
        let all = supported.map { LanguageOption(id: $0.identifier, name: Languages.speechName($0.identifier, in: locale)) }
        installedSpeech = Languages.sortedByName(all.filter { installed.contains($0.id) }, in: locale)
        downloadableSpeech = Languages.sortedByName(all.filter { !installed.contains($0.id) }, in: locale)
        translationTargets = Languages.translationOptions(await LanguageAvailability().supportedLanguages, in: locale)
        if phase == .idle, lines.isEmpty { status = prefs.t("Ready", "等待开始") }
    }

    func toggle() {
        switch phase {
        case .idle: Task { await start() }
        case .running: Task { await stop() }
        default: break
        }
    }

    func clearLines() {
        lines = []
        preview = ""
        previewTranslation = ""
        bump()
    }

    // MARK: 开始／停止

    // testFile：调试用，拿音频文件代替麦克风，放完自动退出
    func start(testFile: URL? = nil) async {
        guard phase == .idle else { return }
        traceStart = Date()
        phase = .starting
        status = prefs.t("Getting ready…", "准备中…")
        lines = []
        preview = ""
        bump()

        if testFile == nil, prefs.audioSource == .microphone, !(await microphoneAllowed()) {
            fail(prefs.t(
                "No microphone access. Turn it on in System Settings → Privacy & Security → Microphone, then start again.",
                "没有麦克风权限。请到「系统设置 → 隐私与安全性 → 麦克风」打开「麦克风字幕」，再点开始。"
            ), short: prefs.t("No microphone access", "没有麦克风权限"))
            return
        }

        do {
            let transcriber = try await prepareTranscriber()
            await loadLanguages()  // 刚下载的语言挪到「已下载」
            guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else {
                throw CaptionError.audioFormat
            }
            let translationNote = await prepareTranslation()

            let analyzer = SpeechAnalyzer(modules: [transcriber])
            try await analyzer.prepareToAnalyze(in: format)
            let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream()
            try await analyzer.start(inputSequence: stream)
            self.analyzer = analyzer
            analyzerFormat = format
            inputContinuation = continuation
            pauses = PauseDetector(pause: prefs.pauseSeconds)

            resultsTask = Task { [weak self] in
                do {
                    for try await result in transcriber.results {
                        let text = String(result.text.characters)
                            .trimmingCharacters(in: .whitespacesAndNewlines)
                        self?.handle(text, final: result.isFinal)
                    }
                } catch {
                    guard let self else { return }
                    status = prefs.t("Recognition error", "识别出错")
                    onNotice?(prefs.t("Recognition error", "识别出错"), describe(error))
                }
            }

            var microphoneNote: String?
            if let testFile {
                try startFileFeed(testFile)
            } else {
                microphoneNote = try startInput()
            }
            let logNote = openTranscripts()
            phase = .running
            status = microphoneNote ?? logNote ?? translationNote ?? prefs.t("Listening…", "正在听…")
        } catch {
            await tearDown()
            fail(describe(error), short: prefs.t("Couldn't start", "没能开始"))
        }
    }

    func stop() async {
        guard phase == .running else { return }
        phase = .stopping
        status = prefs.t("Finishing…", "正在收尾…")
        await tearDown()
        phase = .idle
        status = sessionFiles.isEmpty
            ? prefs.t("Stopped", "已停止")
            : prefs.t("Stopped · Saved", "已停止 · 已保存")
    }

    private func fail(_ message: String, short: String) {
        phase = .idle
        status = short
        onError?(message)
    }

    private func tearDown() async {
        fileFeedTask?.cancel()
        fileFeedTask = nil
        stopInput()
        inputContinuation?.finish()
        inputContinuation = nil
        if let analyzer {
            do {
                try await analyzer.finalizeAndFinishThroughEndOfInput()
            } catch {
                await analyzer.cancelAndFinishNow()
            }
        }
        analyzer = nil
        analyzerFormat = nil
        pauses = nil
        await resultsTask?.value
        resultsTask = nil
        await translateChain?.value
        translateChain = nil
        translation = nil
        previewTask?.cancel()
        previewTask = nil
        previewSession = nil
        previewTranslation = ""
        closeTranscripts()
        if let reservedLocale {
            _ = await AssetInventory.release(reservedLocale: reservedLocale)
            self.reservedLocale = nil
        }
        preview = ""
        bump()
    }

    // MARK: 准备

    private func microphoneAllowed() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return true
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: .audio)
        default: return false
        }
    }

    private func prepareTranscriber() async throws -> SpeechTranscriber {
        guard SpeechTranscriber.isAvailable else { throw CaptionError.speechUnavailable }
        guard let locale = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: prefs.sourceLocale)) else {
            throw CaptionError.languageUnsupported
        }
        if try await AssetInventory.reserve(locale: locale) {
            reservedLocale = locale
        }
        let transcriber = SpeechTranscriber(locale: locale, preset: .progressiveTranscription)
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            status = prefs.t("Downloading speech files…", "正在下载识别资源…")
            try await request.downloadAndInstall()
        }
        return transcriber
    }

    // 返回 nil 表示翻译可用；否则返回给用户看的说明（这时只出原文）
    private func prepareTranslation() async -> String? {
        let originalOnly = prefs.t("Listening · Original only", "正在听 · 只出原文")
        guard prefs.targetLanguage != Languages.noTranslation else { return originalOnly }
        let source = Locale(identifier: prefs.sourceLocale).language
        let target = Locale.Language(identifier: prefs.targetLanguage)
        if Languages.group(source) == Languages.group(target) {
            return originalOnly
        }
        // 低延迟模式：翻译快很多（OST 也用这个）
        let availability: LanguageAvailability
        if #available(macOS 26.4, *) {
            availability = LanguageAvailability(preferredStrategy: .lowLatency)
        } else {
            availability = LanguageAvailability()
        }
        switch await availability.status(from: source, to: target) {
        case .installed:
            if #available(macOS 26.4, *) {
                translation = TranslationSession(installedSource: source, target: target, preferredStrategy: .lowLatency)
                previewSession = TranslationSession(installedSource: source, target: target, preferredStrategy: .lowLatency)
            } else {
                translation = TranslationSession(installedSource: source, target: target)
                previewSession = TranslationSession(installedSource: source, target: target)
            }
            return nil
        case .supported:
            onTranslationMissing?(prefs.t(
                "The translation languages for \(sourceName) → \(targetName) aren't downloaded yet, so only the original is shown this time. Download them in System Settings → General → Language & Region → Translation Languages.",
                "「\(sourceName) → \(targetName)」的翻译语言包还没下载，这次先只出原文。到「系统设置 → 通用 → 语言与地区 → 翻译语言」下载后就能翻译。"
            ))
            return originalOnly
        default:
            return originalOnly
        }
    }

    // MARK: 麦克风

    // 返回给用户看的说明（比如选的麦克风不在了），没有就返回 nil
    private func startMicrophone() throws -> String? {
        guard let format = analyzerFormat, let continuation = inputContinuation, let pauses else { return nil }
        let engine = AVAudioEngine()
        var note: String?
        if !prefs.inputDeviceUID.isEmpty, !AudioDevices.use(prefs.inputDeviceUID, on: engine) {
            note = prefs.t("Listening · Default mic", "正在听 · 默认麦克风")
        }
        let input = engine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else { throw CaptionError.noMicrophone }

        let feeder = AudioFeeder(target: format, continuation: continuation)
        input.installTap(onBus: 0, bufferSize: 4096, format: nil) { [weak self] buffer, _ in
            let rms = Captioner.rms(of: buffer)
            let paused = pauses.observe(rms: rms, seconds: Double(buffer.frameLength) / buffer.format.sampleRate)
            feeder.feed(buffer)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self?.level = Captioner.level(fromRMS: rms)
                    if paused { self?.finalizePending() }
                }
            }
        }
        engine.prepare()
        try engine.start()
        self.engine = engine

        // 插拔耳机、换麦克风时引擎会停下，自动重新接上
        configObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.restartInput(note: self.prefs.t("Listening… (mic changed)", "正在听…（麦克风已切换）"))
            }
        }
        return note
    }

    private func stopMicrophone() {
        if let configObserver {
            NotificationCenter.default.removeObserver(configObserver)
            self.configObserver = nil
        }
        if let engine {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
        }
        engine = nil
        level = 0
    }

    private func startInput() throws -> String? {
        switch prefs.audioSource {
        case .microphone: return try startMicrophone()
        case .systemAudio: return try startSystemAudio()
        }
    }

    private func stopInput() {
        stopMicrophone()
        systemCapture?.stop()
        systemCapture = nil
        level = 0
    }

    private func restartInput(note: String) {
        guard phase == .running, engine != nil || systemCapture != nil else { return }
        stopInput()
        do {
            status = try startInput() ?? note
        } catch {
            status = prefs.audioSource == .microphone
                ? prefs.t("Microphone disconnected", "麦克风断开了")
                : prefs.t("Lost the Mac’s audio", "电脑声音断开了")
            onNotice?(status, describe(error))
        }
    }

    // 在设置或菜单里换了声音来源：正在转写就马上换过去
    func audioSourceChanged() {
        restartInput(note: prefs.t("Listening…", "正在听…"))
    }

    private func startSystemAudio() throws -> String? {
        guard let format = analyzerFormat, let continuation = inputContinuation, let pauses else { return nil }
        let feeder = AudioFeeder(target: format, continuation: continuation)
        let capture = SystemAudioCapture()
        try capture.start(
            onBuffer: { [weak self] buffer in
                let rms = Captioner.rms(of: buffer)
                let paused = pauses.observe(rms: rms, seconds: Double(buffer.frameLength) / buffer.format.sampleRate)
                feeder.feed(buffer)
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        self?.level = Captioner.level(fromRMS: rms)
                        if paused { self?.finalizePending() }
                    }
                }
            },
            onChange: { [weak self] in
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        guard let self else { return }
                        self.restartInput(note: self.prefs.t("Listening…", "正在听…"))
                    }
                }
            }
        )
        systemCapture = capture
        return nil
    }

    // 在设置里换了麦克风：正在转写就马上换过去
    func inputDeviceChanged() {
        guard prefs.audioSource == .microphone else { return }
        restartInput(note: prefs.t("Listening… (mic changed)", "正在听…（麦克风已切换）"))
    }

    func pauseChanged() {
        pauses?.setPause(prefs.pauseSeconds)
    }

    private func startFileFeed(_ url: URL) throws {
        guard let format = analyzerFormat, let continuation = inputContinuation, let pauses else { return }
        let file = try AVAudioFile(forReading: url)
        let feeder = AudioFeeder(target: format, continuation: continuation)
        fileFeedTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 4096),
                      (try? file.read(into: buffer)) != nil, buffer.frameLength > 0 else { break }
                feeder.feed(buffer)
                let rms = Captioner.rms(of: buffer)
                let seconds = Double(buffer.frameLength) / buffer.format.sampleRate
                self?.level = Captioner.level(fromRMS: rms)
                if pauses.observe(rms: rms, seconds: seconds) { self?.finalizePending() }
                try? await Task.sleep(for: .seconds(seconds))
            }
            try? await Task.sleep(for: .seconds(1))
            await self?.stop()
            NSApp.terminate(nil)
        }
    }

    nonisolated private static func rms(of buffer: AVAudioPCMBuffer) -> Float {
        guard let data = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return 0 }
        var sum: Float = 0
        for i in 0..<Int(buffer.frameLength) { sum += data[i] * data[i] }
        return sqrt(sum / Float(buffer.frameLength))
    }

    nonisolated private static func level(fromRMS rms: Float) -> Double {
        let db = 20 * log10(max(rms, 1e-7))
        return Double(min(max((db + 60) / 60, 0), 1))
    }

    // 停顿时把正在识别的这段定下来，马上翻译
    private func finalizePending() {
        trace("pause")
        guard phase == .running, Languages.splitsOnPauses(prefs.sourceLocale), let analyzer else { return }
        Task { try? await analyzer.finalize(through: nil) }
    }

    // MARK: 结果 → 字幕

    private func handle(_ text: String, final: Bool) {
        guard final else {
            preview = text
            bump()
            schedulePreviewTranslation(text)
            return
        }
        previewTask?.cancel()
        preview = ""
        previewTranslation = ""
        let text = Self.tidy(text)
        guard !text.isEmpty else {
            bump()
            return
        }
        trace("final: \(text.prefix(30))")
        let line = Line(original: text)
        lines.append(line)
        if lines.count > 500 { lines.removeFirst(lines.count - 500) }
        bump()
        translate(line)
    }

    // 去掉句首残留的标点（比如 ",..."），英文句首字母大写
    private static func tidy(_ text: String) -> String {
        let junk = CharacterSet(charactersIn: ",.…，。、;；:：!！?？").union(.whitespacesAndNewlines)
        var result = String(text.unicodeScalars.drop(while: { junk.contains($0) }))
        if let first = result.first, first.isLowercase {
            result = first.uppercased() + result.dropFirst()
        }
        return result
    }

    // 还在讲：停 0.5 秒没新字就先翻一版预览（新字一来就作废重排）
    private func schedulePreviewTranslation(_ text: String) {
        previewTask?.cancel()
        guard let session = previewSession, !text.isEmpty else { return }
        previewTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled,
                  let translated = try? await session.translate(text).targetText,
                  !Task.isCancelled,
                  let self, preview == text else { return }
            previewTranslation = translated
            trace("preview translated: \(text.suffix(25))")
            bump()
        }
    }

    private func translate(_ line: Line) {
        let session = translation
        let previous = translateChain
        translateChain = Task { [weak self] in
            await previous?.value
            var translated: String?
            if let session {
                translated = try? await session.translate(line.original).targetText
            }
            self?.finish(line, translation: translated)
        }
    }

    private func finish(_ line: Line, translation: String?) {
        trace("translated: \(line.original.prefix(30))")
        if let translation, let index = lines.firstIndex(where: { $0.id == line.id }) {
            lines[index].translation = translation
            bump()
        }
        // 跟 OST 一样：原文、翻译各一个文件，一行对一行（这句没翻译出来就留一个空行）
        transcriptFile?.write(Data((line.original + "\n").utf8))
        translationFile?.write(Data(((translation ?? "") + "\n").utf8))
        savedLines += 1
    }

    private func bump() { revision &+= 1 }

    // MARK: 文字记录

    // 跟 OST 一样存两个文件：……-transcript.txt（原文）和 ……-translation.txt（翻译）。
    // 返回给用户看的说明（保存失败时），没有就返回 nil
    private func openTranscripts() -> String? {
        transcriptFile = nil
        translationFile = nil
        sessionFiles = []
        savedLines = 0
        guard prefs.saveTranscripts else { return nil }
        let folder = URL(fileURLWithPath: prefs.transcriptFolder, isDirectory: true)
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd-HH-mm-ss"
        let stamp = formatter.string(from: Date())
        var names = ["\(stamp)-transcript.txt"]
        if translation != nil { names.append("\(stamp)-translation.txt") }
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            var handles: [FileHandle] = []
            for name in names {
                let url = folder.appendingPathComponent(name)
                guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
                    throw CocoaError(.fileWriteNoPermission)
                }
                sessionFiles.append(url)
                handles.append(try FileHandle(forWritingTo: url))
            }
            transcriptFile = handles.first
            translationFile = handles.count > 1 ? handles[1] : nil
            return nil
        } catch {
            closeTranscripts()
            onNotice?(
                prefs.t("Couldn't save this transcript", "这次的文字记录没法保存"),
                prefs.t(
                    "Couldn't write to “\(folder.path)”. Subtitles still work. You can choose another folder in Settings → Transcripts.",
                    "没法写入「\(folder.path)」。字幕照常显示。可以在「设置 → 文字记录」里换一个文件夹。"
                )
            )
            return prefs.t("Listening · Not saving", "正在听 · 不保存")
        }
    }

    // 一句都没录到就不留空文件
    private func closeTranscripts() {
        try? transcriptFile?.close()
        try? translationFile?.close()
        transcriptFile = nil
        translationFile = nil
        if savedLines == 0 {
            for url in sessionFiles { try? FileManager.default.removeItem(at: url) }
            sessionFiles = []
        }
    }

    func openTranscriptFolder() {
        let folder = URL(fileURLWithPath: prefs.transcriptFolder, isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        NSWorkspace.shared.open(folder)
    }
}
