import Foundation

/// 菜单分组（对应原版 MenuGroupViewModel）。
struct MenuGroup: Identifiable {
    let head: String
    var items: [MenuItem]

    var id: String { head }

    init(section: MenuSection) {
        head = section.head
        items = (section.content ?? []).filter { !($0.hidden ?? false) }
    }

    init(head: String, items: [MenuItem]) {
        self.head = head
        self.items = items
    }
}
