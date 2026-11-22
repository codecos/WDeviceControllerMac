import Foundation

/// 界面语言跟随系统首选语言：中文环境显示中文，其余语言一律回退英文。
enum InterfaceLanguage {
    static let isChinese: Bool = {
        let preferred = Locale.preferredLanguages.first ?? "en"
        return preferred.lowercased().hasPrefix("zh")
    }()
}

/// 就地取词：`L("连接", "Connect")`，避免为几十条文案单独维护 .strings 表格。
func L(_ chinese: String, _ english: String) -> String {
    InterfaceLanguage.isChinese ? chinese : english
}
