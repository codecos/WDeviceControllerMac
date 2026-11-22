import Foundation

/// 界面语言跟随系统首选语言；未列出的语言一律回退英文。
enum InterfaceLanguage: String {
    case zh
    case en
    case ja
    case ko
    case de

    static let current: InterfaceLanguage = {
        let code = (Locale.preferredLanguages.first ?? "en").lowercased()
        if code.hasPrefix("zh") { return .zh }
        if code.hasPrefix("ja") { return .ja }
        if code.hasPrefix("ko") { return .ko }
        if code.hasPrefix("de") { return .de }
        return .en
    }()
}

/// 就地取词：中文与英文写在调用处，日/韩/德按英文原文查表，查不到就用英文。
func L(_ chinese: String, _ english: String) -> String {
    switch InterfaceLanguage.current {
    case .zh:
        return chinese
    case .en:
        return english
    case .ja, .ko, .de:
        return Translations.table[english]?[InterfaceLanguage.current] ?? english
    }
}

/// 带占位符的取词，中文与英文都写成 `%@` / `%ld` 形式。
func LF(_ chinese: String, _ english: String, _ arguments: CVarArg...) -> String {
    String(format: L(chinese, english), arguments: arguments)
}

/// 英文字面量 → 日/韩/德译文。新增文案时只需补这张表。
enum Translations {
    static let table: [String: [InterfaceLanguage: String]] = [
        "WDeviceController · Connected": [
            .ja: "WDeviceController · 接続済み",
            .ko: "WDeviceController · 연결됨",
            .de: "WDeviceController · Verbunden"
        ],
        "WDeviceController · Disconnected": [
            .ja: "WDeviceController · 未接続",
            .ko: "WDeviceController · 연결 안 됨",
            .de: "WDeviceController · Nicht verbunden"
        ],
        "Connected": [
            .ja: "接続済み",
            .ko: "연결됨",
            .de: "Verbunden"
        ],
        "Disconnected": [
            .ja: "未接続",
            .ko: "연결 안 됨",
            .de: "Nicht verbunden"
        ],
        "Not Connected": [
            .ja: "未接続",
            .ko: "연결 안 됨",
            .de: "Nicht verbunden"
        ],
        "Standby": [
            .ja: "スタンバイ",
            .ko: "대기",
            .de: "Standby"
        ],
        "Connect": [
            .ja: "接続",
            .ko: "연결",
            .de: "Verbinden"
        ],
        "Disconnect": [
            .ja: "切断",
            .ko: "연결 해제",
            .de: "Trennen"
        ],
        "Power On": [
            .ja: "電源オン",
            .ko: "전원 켜기",
            .de: "Einschalten"
        ],
        "Scan for devices": [
            .ja: "デバイスを検索",
            .ko: "기기 검색",
            .de: "Nach Geräten suchen"
        ],
        "Scanning…": [
            .ja: "スキャン中…",
            .ko: "검색 중…",
            .de: "Suche läuft…"
        ],
        "No device found": [
            .ja: "デバイスが見つかりません",
            .ko: "기기를 찾을 수 없습니다",
            .de: "Kein Gerät gefunden"
        ],
        "Choose a device on your network to control playback, volume and settings.": [
            .ja: "ネットワーク上のデバイスを選択すると、再生・音量・設定を操作できます。",
            .ko: "네트워크의 기기를 선택하면 재생, 음량, 설정을 제어할 수 있습니다.",
            .de: "Wähle ein Gerät im Netzwerk, um Wiedergabe, Lautstärke und Einstellungen zu steuern."
        ],
        "Unknown Title": [
            .ja: "不明な曲名",
            .ko: "알 수 없는 곡",
            .de: "Unbekannter Titel"
        ],
        "Unknown Artist": [
            .ja: "不明なアーティスト",
            .ko: "알 수 없는 아티스트",
            .de: "Unbekannter Künstler"
        ],
        "Track info from %@": [
            .ja: "%@ からの曲情報",
            .ko: "%@에서 가져온 곡 정보",
            .de: "Titelinfo von %@"
        ],
        "Previous": [
            .ja: "前へ",
            .ko: "이전 곡",
            .de: "Zurück"
        ],
        "Next": [
            .ja: "次へ",
            .ko: "다음 곡",
            .de: "Weiter"
        ],
        "Play/Pause": [
            .ja: "再生/一時停止",
            .ko: "재생/일시정지",
            .de: "Wiedergabe/Pause"
        ],
        "Previous preset": [
            .ja: "前のプリセット",
            .ko: "이전 프리셋",
            .de: "Vorherige Voreinstellung"
        ],
        "Next preset": [
            .ja: "次のプリセット",
            .ko: "다음 프리셋",
            .de: "Nächste Voreinstellung"
        ],
        "Frequency +": [
            .ja: "周波数 +",
            .ko: "주파수 +",
            .de: "Frequenz +"
        ],
        "Frequency −": [
            .ja: "周波数 −",
            .ko: "주파수 −",
            .de: "Frequenz −"
        ],
        "Preset name": [
            .ja: "プリセット名",
            .ko: "프리셋 이름",
            .de: "Name der Voreinstellung"
        ],
        "Rename preset": [
            .ja: "プリセット名を変更",
            .ko: "프리셋 이름 변경",
            .de: "Voreinstellung umbenennen"
        ],
        "Save": [
            .ja: "保存",
            .ko: "저장",
            .de: "Sichern"
        ],
        "Cancel": [
            .ja: "キャンセル",
            .ko: "취소",
            .de: "Abbrechen"
        ],
        "Mute": [
            .ja: "ミュート",
            .ko: "음소거",
            .de: "Stumm"
        ],
        "Unmute": [
            .ja: "ミュート解除",
            .ko: "음소거 해제",
            .de: "Ton an"
        ],
        "Open settings": [
            .ja: "設定を開く",
            .ko: "설정 열기",
            .de: "Einstellungen öffnen"
        ],
        "Settings": [
            .ja: "設定",
            .ko: "설정",
            .de: "Einstellungen"
        ],
        "Back": [
            .ja: "戻る",
            .ko: "뒤로",
            .de: "Zurück"
        ],
        "Loading device settings…": [
            .ja: "デバイス設定を読み込み中…",
            .ko: "기기 설정을 불러오는 중…",
            .de: "Geräteeinstellungen werden geladen…"
        ],
        "Open Panel": [
            .ja: "パネルを開く",
            .ko: "패널 열기",
            .de: "Panel öffnen"
        ],
        "Launch at Login": [
            .ja: "ログイン時に起動",
            .ko: "로그인 시 실행",
            .de: "Bei Anmeldung öffnen"
        ],
        "Quit": [
            .ja: "終了",
            .ko: "종료",
            .de: "Beenden"
        ],
        "OK": [
            .ja: "OK",
            .ko: "확인",
            .de: "OK"
        ],
        "Couldn't change Launch at Login": [
            .ja: "ログイン時の起動を変更できません",
            .ko: "로그인 시 실행을 변경할 수 없습니다",
            .de: "„Bei Anmeldung öffnen“ konnte nicht geändert werden"
        ],
        "Move WDeviceController into the Applications folder and try again. If it still fails, add it manually in System Settings › General › Login Items.": [
            .ja: "WDeviceController を「アプリケーション」フォルダに移動してから、もう一度お試しください。それでも失敗する場合は、「システム設定 › 一般 › ログイン項目」で手動で追加してください。",
            .ko: "WDeviceController를 「응용 프로그램」 폴더로 옮긴 뒤 다시 시도해 주세요. 그래도 실패하면 「시스템 설정 › 일반 › 로그인 항목」에서 직접 추가할 수 있습니다.",
            .de: "Verschiebe WDeviceController in den Ordner „Programme“ und versuche es erneut. Falls es weiterhin fehlschlägt, füge die App unter „Systemeinstellungen › Allgemein › Anmeldeobjekte“ manuell hinzu."
        ],
        "Invalid player URL": [
            .ja: "プレーヤーのアドレスが無効です",
            .ko: "플레이어 주소가 올바르지 않습니다",
            .de: "Ungültige Player-Adresse"
        ],
        "Unexpected player response": [
            .ja: "プレーヤーの応答が異常です",
            .ko: "플레이어 응답이 비정상입니다",
            .de: "Unerwartete Antwort des Players"
        ],
        "Unsupported player data format": [
            .ja: "プレーヤーのデータ形式に対応していません",
            .ko: "플레이어 데이터 형식을 지원하지 않습니다",
            .de: "Nicht unterstütztes Datenformat des Players"
        ],
        "Player returned HTTP %ld": [
            .ja: "プレーヤーが HTTP %ld を返しました",
            .ko: "플레이어가 HTTP %ld을(를) 반환했습니다",
            .de: "Player hat HTTP %ld zurückgegeben"
        ],
        "WebHost not ready": [
            .ja: "WebHost の準備ができていません",
            .ko: "WebHost가 준비되지 않았습니다",
            .de: "WebHost ist nicht bereit"
        ],
        "This node requires authentication": [
            .ja: "このノードには認証が必要です",
            .ko: "이 노드에는 인증이 필요합니다",
            .de: "Dieser Knoten erfordert eine Anmeldung"
        ]
    ]
}
