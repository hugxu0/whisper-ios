import PhotosUI
import SwiftUI
import UIKit

/// 从服务端加载的图片（带缓存）
struct RemoteImage: View {
    let mediaId: String?
    var thumb = true
    var maxPixel: CGFloat = 600
    var contentMode: ContentMode = .fill
    var animated = false

    @State private var image: UIImage?

    var body: some View {
        ZStack {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: contentMode)
            } else {
                Rectangle().fill(Color(uiColor: .secondarySystemFill))
            }
        }
        .task(id: mediaId) {
            guard let mediaId else { return }
            if let cached = MediaCache.shared.cachedImage(mediaId, thumb: thumb, maxPixel: maxPixel) {
                image = cached
                return
            }
            image = animated ? await MediaCache.shared.animatedImage(mediaId, maxPixel: maxPixel) : await MediaCache.shared.image(mediaId, thumb: thumb, maxPixel: maxPixel)
        }
    }
}

struct AvatarView: View {
    @Environment(AppModel.self) private var app
    let userId: String?
    var size: CGFloat = 40

    var body: some View {
        let user = userId.flatMap { app.user($0) }
        ZStack {
            if let mediaId = user?.avatarMediaId {
                RemoteImage(mediaId: mediaId, thumb: true, maxPixel: size * 3)
            } else {
                LinearGradient(colors: gradient(for: userId), startPoint: .topLeading, endPoint: .bottomTrailing)
                Text(initial(user))
                    .font(.system(size: size * 0.42, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .overlay(Circle().strokeBorder(.white.opacity(0.15), lineWidth: 0.5))
    }

    private func initial(_ user: User?) -> String {
        if user?.id == "daju" { return "🐱" }
        return String((user?.displayName ?? "?").prefix(1))
    }

    private func gradient(for id: String?) -> [Color] {
        switch id {
        case "daju": return [Color(hex: 0xFFB36B), Color(hex: 0xF0873C)]
        case "xu": return [Color(hex: 0x6FB1FF), Color(hex: 0x3D7BFF)]
        default: return [Color(hex: 0xFF8FB1), Color(hex: 0xFF5C8A)]
        }
    }
}

/// 卡片容器：纸色卡片（见 Paper）
struct CardBackground: ViewModifier {
    var padding: CGFloat = Theme.Space.l

    func body(content: Content) -> some View {
        content.paperCard(padding: padding)
    }
}

extension View {
    func cardStyle(padding: CGFloat = Theme.Space.l) -> some View {
        modifier(CardBackground(padding: padding))
    }
}

struct SectionHeader: View {
    let title: String
    var systemImage: String?
    var actionTitle: String?
    var action: (() -> Void)?

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            if let systemImage {
                Image(systemName: systemImage).foregroundStyle(Theme.accentColor)
            }
            Text(title).font(.title3.weight(.semibold))
            Spacer()
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .font(.subheadline)
                    .foregroundStyle(Theme.accentColor)
            }
        }
    }
}

/// 进度条（宠物状态、经验值）
struct MeterBar: View {
    let value: Double
    let color: Color
    var height: CGFloat = 8

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(color.opacity(0.18))
                Capsule()
                    .fill(color.gradient)
                    .frame(width: max(height, geometry.size.width * min(1, max(0, value))))
            }
        }
        .frame(height: height)
        .animation(.spring(duration: 0.5), value: value)
    }
}

/// 出错提示：放在页面顶部的一行
struct ErrorBanner: View {
    let message: String

    var body: some View {
        Label(message, systemImage: "exclamationmark.triangle.fill")
            .font(.footnote)
            .foregroundStyle(.white)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(Color.red.opacity(0.85), in: Capsule())
    }
}

struct Toast: Equatable {
    let message: String
    var icon = "checkmark.circle.fill"
}

extension View {
    /// 轻提示，两秒后自动消失
    func toast(_ toast: Binding<Toast?>) -> some View {
        overlay(alignment: .top) {
            if let value = toast.wrappedValue {
                Label(value.message, systemImage: value.icon)
                    .font(.subheadline.weight(.medium))
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .glassEffect()
                    .padding(.top, 8)
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .task {
                        try? await Task.sleep(for: .seconds(2))
                        withAnimation { toast.wrappedValue = nil }
                    }
            }
        }
        .animation(.spring(duration: 0.35), value: toast.wrappedValue)
    }
}

/// 方形缩略图：图片按比例铺满后裁掉多余部分，不会撑出格子、叠到别的格子上
struct SquareThumbnail: View {
    let media: MessageMedia
    var maxPixel: CGFloat = 360
    var cornerRadius: CGFloat = 0

    var body: some View {
        Color.clear
            .aspectRatio(1, contentMode: .fit)
            .overlay {
                RemoteImage(mediaId: media.id, thumb: media.hasThumb || media.kind == "video", maxPixel: maxPixel)
            }
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay(alignment: .bottomTrailing) {
                if media.kind == "video" {
                    Image(systemName: "play.fill")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.white)
                        .padding(6)
                        .background(.black.opacity(0.4), in: Circle())
                        .padding(5)
                }
            }
            .contentShape(Rectangle())
    }
}

/// 系统相册选择器（可多选照片和视频）
struct PhotoPicker: UIViewControllerRepresentable {
    var limit = 30
    var filter: PHPickerFilter = .any(of: [.images, .videos])
    let onPick: ([PHPickerResult]) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onPick: onPick) }

    func makeUIViewController(context: Context) -> PHPickerViewController {
        var configuration = PHPickerConfiguration()
        configuration.selectionLimit = limit
        configuration.filter = filter
        configuration.selection = .ordered
        let picker = PHPickerViewController(configuration: configuration)
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ controller: PHPickerViewController, context: Context) {}

    final class Coordinator: NSObject, PHPickerViewControllerDelegate {
        let onPick: ([PHPickerResult]) -> Void

        init(onPick: @escaping ([PHPickerResult]) -> Void) {
            self.onPick = onPick
        }

        func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
            onPick(results)
        }
    }
}

/// Markdown 渲染（标题、列表、引用、代码块、分隔线；行内的粗体、斜体、链接交给系统）
struct MarkdownText: View {
    let text: String
    var bodyFont: Font = .body
    var lineSpacing: CGFloat = 5

    private enum Block {
        case heading(Int, String)
        case bullet(String)
        case ordered(String, String)
        case quote(String)
        case code(String)
        case rule
        case paragraph(String)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(Self.blocks(text).enumerated()), id: \.offset) { _, block in
                view(for: block)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func view(for block: Block) -> some View {
        switch block {
        case .heading(let level, let content):
            Text(Self.inline(content))
                .font(level == 1 ? .title2.weight(.bold) : (level == 2 ? .title3.weight(.bold) : .headline))
                .padding(.top, 4)
        case .bullet(let content):
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("•").foregroundStyle(Theme.accentColor)
                Text(Self.inline(content)).font(bodyFont).lineSpacing(lineSpacing)
            }
        case .ordered(let number, let content):
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(number + ".").font(bodyFont.monospacedDigit()).foregroundStyle(Theme.accentColor)
                Text(Self.inline(content)).font(bodyFont).lineSpacing(lineSpacing)
            }
        case .quote(let content):
            Text(Self.inline(content))
                .font(bodyFont)
                .italic()
                .foregroundStyle(.secondary)
                .lineSpacing(lineSpacing)
                .padding(.leading, 12)
                .overlay(alignment: .leading) { Capsule().fill(Theme.accentColor.opacity(0.6)).frame(width: 3) }
        case .code(let content):
            Text(content)
                .font(.callout.monospaced())
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(uiColor: .tertiarySystemFill), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        case .rule:
            Divider()
        case .paragraph(let content):
            Text(Self.inline(content)).font(bodyFont).lineSpacing(lineSpacing)
        }
    }

    private static func inline(_ text: String) -> AttributedString {
        (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(text)
    }

    private static func blocks(_ text: String) -> [Block] {
        var result: [Block] = []
        var paragraph: [String] = []
        var code: [String]?
        func flush() {
            if !paragraph.isEmpty { result.append(.paragraph(paragraph.joined(separator: "\n"))) }
            paragraph = []
        }
        for rawLine in text.components(separatedBy: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("```") {
                if let lines = code {
                    result.append(.code(lines.joined(separator: "\n")))
                    code = nil
                } else {
                    flush()
                    code = []
                }
                continue
            }
            if code != nil {
                code?.append(rawLine)
                continue
            }
            if line.isEmpty {
                flush()
            } else if let match = line.range(of: #"^#{1,6}\s+"#, options: .regularExpression) {
                flush()
                let level = line[match].filter { $0 == "#" }.count
                result.append(.heading(level, String(line[match.upperBound...])))
            } else if let match = line.range(of: #"^[-*+]\s+"#, options: .regularExpression) {
                flush()
                result.append(.bullet(String(line[match.upperBound...])))
            } else if let match = line.range(of: #"^\d+[.)]\s+"#, options: .regularExpression) {
                flush()
                let number = line[match].filter(\.isNumber)
                result.append(.ordered(String(number), String(line[match.upperBound...])))
            } else if line.hasPrefix(">") {
                flush()
                result.append(.quote(String(line.dropFirst()).trimmingCharacters(in: .whitespaces)))
            } else if line == "---" || line == "***" {
                flush()
                result.append(.rule)
            } else {
                paragraph.append(line)
            }
        }
        if let lines = code { result.append(.code(lines.joined(separator: "\n"))) }
        flush()
        return result
    }
}

