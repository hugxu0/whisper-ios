import SwiftUI
import UIKit

/// 设计规范：颜色、字号、间距、圆角都在这里，页面里不写死数值。
enum Theme {
    struct Palette: Identifiable, Hashable {
        let key: String
        let name: String
        let top: UInt32
        let bottom: UInt32
        var id: String { key }

        var accent: UIColor { UIColor(hex: bottom) }
        var gradient: [UIColor] { [UIColor(hex: top), UIColor(hex: bottom)] }
    }

    static let palettes: [Palette] = [
        Palette(key: "tangerine", name: "暖橘", top: 0xFF9152, bottom: 0xFF6B3D),
        Palette(key: "sakura", name: "樱粉", top: 0xFF7EA0, bottom: 0xFF5282),
        Palette(key: "sky", name: "天蓝", top: 0x4DA6FF, bottom: 0x1F7BFF),
        Palette(key: "mint", name: "薄荷", top: 0x34CFA2, bottom: 0x14A884),
        Palette(key: "lavender", name: "薰衣草", top: 0xA98BFF, bottom: 0x7C5CFF),
        Palette(key: "graphite", name: "石墨", top: 0x6B7280, bottom: 0x3F4652),
    ]

    static var palette: Palette {
        let key = UserDefaults.standard.string(forKey: "theme") ?? "tangerine"
        return palettes.first { $0.key == key } ?? palettes[0]
    }

    static var accent: UIColor { palette.accent }
    static var accentColor: Color { Color(uiColor: accent) }

    /// 对方的气泡
    static let incomingBubble = UIColor { trait in
        trait.userInterfaceStyle == .dark ? UIColor(hex: 0x2A2A2E) : UIColor(hex: 0xEEEEF3)
    }

    /// 大橘的气泡：暖奶油色
    static let dajuBubble = UIColor { trait in
        trait.userInterfaceStyle == .dark ? UIColor(hex: 0x3B2C21) : UIColor(hex: 0xFFF1E4)
    }

    static let dajuAccent = UIColor(hex: 0xF08A3C)

    static let chatBackground = UIColor.systemBackground

    /// 卡牌稀有度的颜色：跟纸张风格搭，偏柔和（灰绿、雾蓝、雾紫、暖金）
    static let rarityColors: [String: [UInt32]] = [
        "common": [0xA9B3A2, 0x7E8B7B],
        "rare": [0x8EB4D8, 0x5A85B4],
        "epic": [0xBCA3DC, 0x8C6CBF],
        "legendary": [0xF2C774, 0xD9913E],
    ]

    static func rarityGradient(_ rarity: String) -> LinearGradient {
        let colors = (rarityColors[rarity] ?? rarityColors["common"]!).map { Color(uiColor: UIColor(hex: $0)) }
        return LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing)
    }

    static let rarityNames = ["common": "普通", "rare": "稀有", "epic": "史诗", "legendary": "传说"]

    /// 标签墙的颜色
    static let tagColors: [UInt32] = [0xFF6B81, 0xFF9F43, 0xFECA57, 0x1DD1A1, 0x48DBFB, 0x54A0FF, 0x5F27CD, 0xFF9FF3, 0x00D2D3, 0xEE5253, 0x10AC84, 0x8395A7]

    static func tagColor(_ index: Int) -> Color {
        Color(uiColor: UIColor(hex: tagColors[abs(index) % tagColors.count]))
    }

    enum Space {
        static let xs: CGFloat = 4
        static let s: CGFloat = 8
        static let m: CGFloat = 12
        static let l: CGFloat = 16
        static let xl: CGFloat = 24
        static let xxl: CGFloat = 32
    }

    enum Radius {
        static let bubble: CGFloat = 19
        static let bubbleTight: CGFloat = 6
        static let card: CGFloat = 24
        static let tile: CGFloat = 16
        static let small: CGFloat = 10
    }
}

extension UIColor {
    convenience init(hex: UInt32, alpha: CGFloat = 1) {
        self.init(
            red: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: alpha
        )
    }
}

extension Color {
    init(hex: UInt32) {
        self.init(uiColor: UIColor(hex: hex))
    }
}
