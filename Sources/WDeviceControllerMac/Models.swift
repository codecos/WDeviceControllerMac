import Foundation

// MARK: - 设备

struct DeviceInfo: Identifiable, Hashable {
    var hostname: String
    var ip: String
    var port: Int = 9000
    var isOnline: Bool = true

    var id: String { "\(ip):\(port)" }
    var displayName: String { "\(hostname) (\(ip))" }
}

// MARK: - 入站消息

struct MessageHeader: Decodable {
    let cmd: String?
    let cmd_id: Int?
}

struct PlayStatusMessage: Decodable {
    let cmd: String?
    let payload: PlayStatusPayload?
}

struct PlayStatusPayload: Decodable {
    let device_status: String?
    let speed_str: String?
    let source_list: String?
    let source: String?
    let volume: Int?
    let volume_max: Int?
    let volume_min: Int?
    let volume_step: Int?
    let mute: Int?
    let play: Bool?
    let si_info_title: String?
    let playstatus: PlayStatusDetails?

    enum CodingKeys: String, CodingKey {
        case device_status, speed_str, source_list, source, volume
        case volume_max, volume_min, volume_step, mute, play
        case si_info_title, playstatus
    }
}

struct PlayStatusDetails: Decodable {
    let title: String?
    let artist: String?
    let album: String?
    let albumart_uri: String?
    let status: String?
    let next_allowed: Bool?
    let prev_allowed: Bool?
    let pause_allowed: Bool?
    let play_allowed: Bool?
    let play_pos: Int?
    let play_length: Int?
    let fm_channel: Int?
    let fm_freq: Int?

    enum CodingKeys: String, CodingKey {
        case title, artist, album, albumart_uri, status
        case next_allowed, prev_allowed, pause_allowed, play_allowed
        case play_pos, play_length, fm_channel, fm_freq
    }
}

struct MenuListMessage: Decodable {
    let cmd: String?
    let payload: [MenuSection]?
}

struct MenuSection: Decodable, Identifiable {
    let head: String
    let content: [MenuItem]?
    let disabled: Bool?

    var id: String { head }

    enum CodingKeys: String, CodingKey {
        case head, content, disabled
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        head = ((try? c.decodeIfPresent(String.self, forKey: .head)) ?? nil) ?? ""
        content = (try? c.decodeIfPresent([MenuItem].self, forKey: .content)) ?? nil
        disabled = (try? c.decodeIfPresent(Bool.self, forKey: .disabled)) ?? nil
    }
}

struct MenuItem: Decodable, Identifiable {
    let id: Int
    let action: String?
    let itemDescription: String?
    let type: String?
    let restart: Bool?
    let handler: Int?
    let eepromAddr: Int?
    let value: Int?
    let timeout: Int?
    let items: [ItemOption]?
    let hidden: Bool?

    /// 界面当前选中的值；与设备值分开保存，便于用户操作后不被旧推送覆盖。
    var selectedValue: Int

    enum CodingKeys: String, CodingKey {
        case id, action, type, restart, handler, value, timeout, items, hidden
        case itemDescription = "description"
        case eepromAddr = "eeprom_addr"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)

        func decode<T: Decodable>(_ type: T.Type, _ key: CodingKeys) -> T? {
            (try? c.decodeIfPresent(type, forKey: key)) ?? nil
        }

        id = decode(Int.self, .id) ?? 0
        action = decode(String.self, .action)
        itemDescription = decode(String.self, .itemDescription)
        type = decode(String.self, .type)
        restart = decode(Bool.self, .restart)
        handler = decode(Int.self, .handler)
        eepromAddr = decode(Int.self, .eepromAddr)
        let rawValue = decode(Int.self, .value) ?? 0
        value = rawValue
        selectedValue = rawValue
        timeout = decode(Int.self, .timeout)
        items = decode([ItemOption].self, .items)
        hidden = decode(Bool.self, .hidden)
    }
}

struct ItemOption: Decodable, Identifiable {
    let title: String
    let value: Int

    var id: Int { value }

    enum CodingKeys: String, CodingKey {
        case title, value
    }
}

struct PresetListMessage: Decodable {
    let payload: PresetListPayload?
}

struct PresetListPayload: Decodable {
    let preset_list: [String]?
}

// MARK: - 出站消息

enum Outbound {
    static func seq() -> UInt32 {
        UInt32(truncatingIfNeeded: DispatchTime.now().uptimeNanoseconds / 1_000_000)
    }

    private static func jsonString(_ object: [String: Any]) -> String? {
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object, options: []),
              let text = String(data: data, encoding: .utf8) else { return nil }
        return text
    }

    private static func envelope(cmd: String, cmdId: Int, payload: [String: Any]) -> String? {
        jsonString([
            "cmd": cmd,
            "cmd_id": cmdId,
            "cmd_type": 0,
            "payload": payload,
            "seq": seq(),
            "status": "OK"
        ])
    }

    static func button(_ name: String) -> String? {
        envelope(cmd: "button", cmdId: 32775,
                 payload: ["command": "button", "payload": name])
    }

    static func volume(_ value: Int, muted: Bool) -> String? {
        envelope(cmd: "volume", cmdId: 32774,
                 payload: ["command": "set_volume", "payload": value, "mute": muted ? 1 : 0])
    }

    static func selectSource(_ source: String) -> String? {
        envelope(cmd: "req_source", cmdId: 32769,
                 payload: ["command": "source_selection", "payload": source])
    }

    static func requestPlayStatus() -> String? {
        envelope(cmd: "play_status_req", cmdId: 32773, payload: [:])
    }

    static func requestMenuList() -> String? {
        envelope(cmd: "menulist", cmdId: 32772, payload: [:])
    }

    static func settings(id: Int, handler: Int, type: String, eepromAddr: Int, value: Int) -> String? {
        envelope(cmd: "settings", cmdId: 32778, payload: [
            "id": id,
            "handler": handler,
            "type": type,
            "eeprom_addr": eepromAddr,
            "value": value
        ])
    }

    static func fmPresetUpdate(id: Int, name: String) -> String? {
        envelope(cmd: "fm_preset_update", cmdId: 32780,
                 payload: ["id": id, "name": name])
    }
}
