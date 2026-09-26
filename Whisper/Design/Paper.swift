import SwiftUI
import UIKit

/// 纸张风格（取自大橘日记）：暖色的桌面做底，纸色卡片，墨色文字，标题用衬线体。
/// 聊天页本身不用，聊天外面的页面都用这一套。
enum Paper {
    static let canvasUI = UIColor { $0.userInterfaceStyle == .dark ? UIColor(hex: 0x17140F) : UIColor(hex: 0xF3EBDD) }
    static let cardUI = UIColor { $0.userInterfaceStyle == .dark ? UIColor(hex: 0x241F18) : UIColor(hex: 0xFFFBF2) }

    /// 页面底色
    static let canvas = Color(uiColor: canvasUI)
    /// 卡片
    static let card = Color(uiColor: cardUI)
    /// 卡片里再凹下去一层（比如最新消息的底）
    static let inset = Color(uiColor: UIColor { $0.userInterfaceStyle == .dark ? UIColor(hex: 0x1C1813) : UIColor(hex: 0xF7EFE2) })
    /// 细线、描边
    static let line = Color(uiColor: UIColor { $0.userInterfaceStyle == .dark ? UIColor(hex: 0x3A3226) : UIColor(hex: 0xE8DCC8) })
    /// 墨色文字
    static let ink = Color(uiColor: UIColor { $0.userInterfaceStyle == .dark ? UIColor(hex: 0xEDE3D1) : UIColor(hex: 0x3B3024) })
    static let inkSoft = Color(uiColor: UIColor { $0.userInterfaceStyle == .dark ? UIColor(hex: 0xB3A690) : UIColor(hex: 0x8A7A64) })
    /// 卡片阴影：暖棕色，很淡
    static let shadow = Color(hex: 0x7A5A2E).opacity(0.08)

    static let radius: CGFloat = 22

    static func title(_ style: Font.TextStyle = .title3) -> Font {
        .system(style, design: .serif).weight(.bold)
    }
}

/// 纸色卡片：圆角、淡淡的描边和阴影
struct PaperCard: ViewModifier {
    var padding: CGFloat = 16
    var radius: CGFloat = Paper.radius

    func body(content: Content) -> some View {
        content
            .padding(padding)
            .background {
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(Paper.card)
                    .shadow(color: Paper.shadow, radius: 10, y: 4)
            }
            .overlay {
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(Paper.line.opacity(0.8), lineWidth: 0.6)
            }
    }
}

extension View {
    func paperCard(padding: CGFloat = 16, radius: CGFloat = Paper.radius) -> some View {
        modifier(PaperCard(padding: padding, radius: radius))
    }

    /// List、Form 用纸色的底
    func paperList() -> some View {
        scrollContentBackground(.hidden)
            .background(Paper.canvas.ignoresSafeArea())
    }
}

/// 纸色的 Form：底色是桌面，每一行是纸色（不是系统的纯白）
struct PaperForm<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        Form {
            Group { content }
                .listRowBackground(Paper.card)
        }
        .paperList()
    }
}

/// 纸色的 List：同 PaperForm
struct PaperList<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        List {
            Group { content }
                .listRowBackground(Paper.card)
        }
        .paperList()
    }
}

/// 分区标题：衬线体，右边可以放“全部”
struct PaperSectionTitle: View {
    let title: String
    var subtitle: String?
    var trailing: String?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(title)
                .font(Paper.title())
                .foregroundStyle(Paper.ink)
            if let subtitle {
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(Paper.inkSoft)
            }
            Spacer(minLength: 0)
            if let trailing {
                HStack(spacing: 2) {
                    Text(trailing)
                    Image(systemName: "chevron.right").font(.caption2.weight(.bold))
                }
                .font(.footnote.weight(.medium))
                .foregroundStyle(Paper.inkSoft)
            }
        }
        .padding(.horizontal, 4)
    }
}

/// 一组设置样式的行，放在同一张纸上，行之间自动加细线
struct PaperGroup<Content: View>: View {
    var title: String?
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let title {
                Text(title)
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(Paper.inkSoft)
                    .padding(.leading, 8)
            }
            VStack(spacing: 0) {
                Group(subviews: content) { subviews in
                    ForEach(subviews) { subview in
                        subview
                        if subview.id != subviews.last?.id {
                            Rectangle()
                                .fill(Paper.line)
                                .frame(height: 0.6)
                                .padding(.leading, 60)
                        }
                    }
                }
            }
            .background {
                RoundedRectangle(cornerRadius: Paper.radius, style: .continuous)
                    .fill(Paper.card)
                    .shadow(color: Paper.shadow, radius: 10, y: 4)
            }
            .overlay {
                RoundedRectangle(cornerRadius: Paper.radius, style: .continuous)
                    .strokeBorder(Paper.line.opacity(0.8), lineWidth: 0.6)
            }
        }
    }
}

/// 设置样式的一行：淡色图标、标题、说明、右边的值和箭头
struct PaperRow: View {
    let icon: String
    let tint: Color
    let title: String
    var subtitle: String?
    var value: String?
    var chevron = true

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: icon)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 32, height: 32)
                .background(tint.opacity(0.14), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.body).foregroundStyle(Paper.ink)
                if let subtitle {
                    Text(subtitle).font(.caption).foregroundStyle(Paper.inkSoft).lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            if let value {
                Text(value).font(.subheadline).foregroundStyle(Paper.inkSoft).lineLimit(1)
            }
            if chevron {
                Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(Paper.inkSoft.opacity(0.6))
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .contentShape(Rectangle())
    }
}

/// 淡色圆形图标，用在卡片标题前
struct PaperIcon: View {
    let systemName: String
    let tint: Color
    var size: CGFloat = 36

    var body: some View {
        Image(systemName: systemName)
            .font(.system(size: size * 0.42, weight: .semibold))
            .foregroundStyle(tint)
            .frame(width: size, height: size)
            .background(tint.opacity(0.14), in: Circle())
    }
}
