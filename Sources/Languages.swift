// 语言列表：说话语言来自苹果语音识别，翻译语言来自苹果翻译

import Foundation

struct LanguageOption: Identifiable, Hashable {
    let id: String  // 说话语言：Locale 标识（如 en_US）；翻译语言：语言标识（如 zh、en）
    let name: String
}

enum Languages {
    static let noTranslation = ""

    static func speechName(_ id: String, in locale: Locale) -> String {
        locale.localizedString(forIdentifier: id) ?? id
    }

    // 中文按简体／繁体显示；其他语言只显示语言名
    static func translationName(_ id: String, in locale: Locale) -> String {
        let language = Locale.Language(identifier: id)
        if language.languageCode == .chinese {
            let script = group(language).hasSuffix("Hant") ? "zh-Hant" : "zh-Hans"
            return locale.localizedString(forIdentifier: script) ?? id
        }
        let code = language.languageCode?.identifier ?? id
        return locale.localizedString(forLanguageCode: code) ?? id
    }

    // 语言 + 文字，比如 en-Latn、zh-Hans、zh-Hant：同一组算同一种语言
    static func group(_ language: Locale.Language) -> String {
        language.maximalIdentifier.split(separator: "-").prefix(2).joined(separator: "-")
    }

    // 翻译语言里的地区变体（en-GB、es-MX…）合并成一个；繁体中文用 zh-TW
    static func translationOptions(_ languages: [Locale.Language], in locale: Locale) -> [LanguageOption] {
        var picked: [String: String] = [:]
        for language in languages {
            let id = language.minimalIdentifier
            let key = group(language)
            if let current = picked[key], !prefer(id, over: current) { continue }
            picked[key] = id
        }
        return sortedByName(picked.values.map { LanguageOption(id: $0, name: translationName($0, in: locale)) }, in: locale)
    }

    private static func prefer(_ a: String, over b: String) -> Bool {
        if a == "zh-TW" { return true }
        if b == "zh-TW" { return false }
        let aHasRegion = a.contains("-"), bHasRegion = b.contains("-")
        if aHasRegion != bHasRegion { return !aHasRegion }
        return a < b
    }

    static func sortedByName(_ options: [LanguageOption], in locale: Locale) -> [LanguageOption] {
        options.sorted { $0.name.compare($1.name, locale: locale) == .orderedAscending }
    }

    // 英文等语言的识别器自己会在停顿后很快断句，强行断句反而认错字；中日韩不会自己断，要靠停顿
    static func splitsOnPauses(_ speechID: String) -> Bool {
        let code = Locale(identifier: speechID).language.languageCode?.identifier ?? ""
        return ["zh", "yue", "ja", "ko"].contains(code)
    }
}
