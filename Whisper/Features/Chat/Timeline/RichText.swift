import UIKit

/// 气泡里的文字：链接识别、大橘回复的 Markdown、只有表情时放大。
enum RichText {
    static let bodyFont = UIFont.systemFont(ofSize: 17)
    static let replyNameFont = UIFont.systemFont(ofSize: 13, weight: .semibold)
    static let replyTextFont = UIFont.systemFont(ofSize: 13)
    static let captionFont = UIFont.systemFont(ofSize: 12)
    static let transcriptFont = UIFont.systemFont(ofSize: 15)

    private static let linkDetector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
    /// 链接地址放在自定义属性里：用系统的 .link 属性时，NSLayoutManager 一律画成蓝色
    static let linkKey = NSAttributedString.Key("WhisperLink")

    /// 只含 1~3 个表情的消息，像 iMessage 一样放大、不要气泡
    static func isEmojiOnly(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 3 else { return false }
        return trimmed.allSatisfy { character in
            character.unicodeScalars.contains { $0.properties.isEmojiPresentation } ||
                (character.unicodeScalars.first?.properties.isEmoji == true && character.unicodeScalars.count > 1)
        }
    }

    static func attributed(_ text: String, color: UIColor, linkColor: UIColor, font: UIFont = bodyFont, markdown: Bool = false) -> NSAttributedString {
        let result = markdown ? renderMarkdown(text, color: color, linkColor: linkColor, font: font) : NSMutableAttributedString(string: text, attributes: [.font: font, .foregroundColor: color])
        let string = result.string
        let range = NSRange(string.startIndex..., in: string)
        linkDetector?.enumerateMatches(in: string, options: [], range: range) { match, _, _ in
            guard let match, let url = match.url else { return }
            result.addAttributes([linkKey: url, .foregroundColor: linkColor, .underlineStyle: NSUnderlineStyle.single.rawValue], range: match.range)
        }
        return result
    }

    /// 简单的 Markdown：标题、列表、引用、代码块按行处理，行内的粗体、斜体、代码、链接交给系统解析
    static func renderMarkdown(_ text: String, color: UIColor, linkColor: UIColor, font: UIFont) -> NSMutableAttributedString {
        let output = NSMutableAttributedString()
        let paragraph = NSMutableParagraphStyle()
        paragraph.paragraphSpacing = 4
        var inCode = false
        let lines = text.components(separatedBy: "\n")
        for (index, rawLine) in lines.enumerated() {
            var line = rawLine
            var lineFont = font
            var lineColor = color
            let lineParagraph = paragraph.mutableCopy() as! NSMutableParagraphStyle
            if line.trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                inCode.toggle()
                continue
            }
            if inCode {
                let code = NSAttributedString(string: line + (index < lines.count - 1 ? "\n" : ""), attributes: [
                    .font: UIFont.monospacedSystemFont(ofSize: font.pointSize - 2, weight: .regular),
                    .foregroundColor: color,
                    .paragraphStyle: lineParagraph,
                ])
                output.append(code)
                continue
            }
            if let match = line.range(of: #"^#{1,6}\s+"#, options: .regularExpression) {
                line.removeSubrange(match)
                lineFont = UIFont.systemFont(ofSize: font.pointSize + 1, weight: .bold)
            } else if let match = line.range(of: #"^\s*[-*+]\s+"#, options: .regularExpression) {
                line.replaceSubrange(match, with: "•  ")
                lineParagraph.headIndent = 16
            } else if line.range(of: #"^\s*\d+[.)]\s+"#, options: .regularExpression) != nil {
                lineParagraph.headIndent = 18
            } else if let match = line.range(of: #"^>\s?"#, options: .regularExpression) {
                line.removeSubrange(match)
                lineColor = color.withAlphaComponent(0.7)
            }
            let inline = inlineMarkdown(line, font: lineFont, color: lineColor, linkColor: linkColor)
            inline.addAttribute(.paragraphStyle, value: lineParagraph, range: NSRange(location: 0, length: inline.length))
            output.append(inline)
            if index < lines.count - 1 { output.append(NSAttributedString(string: "\n", attributes: [.font: font])) }
        }
        // 去掉结尾多余的空行
        while output.string.hasSuffix("\n") { output.deleteCharacters(in: NSRange(location: output.length - 1, length: 1)) }
        return output
    }

    private static func inlineMarkdown(_ line: String, font: UIFont, color: UIColor, linkColor: UIColor) -> NSMutableAttributedString {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        guard let parsed = try? AttributedString(markdown: line, options: options) else {
            return NSMutableAttributedString(string: line, attributes: [.font: font, .foregroundColor: color])
        }
        let result = NSMutableAttributedString()
        for run in parsed.runs {
            let text = String(parsed[run.range].characters)
            var runFont = font
            if let intent = run.inlinePresentationIntent {
                if intent.contains(.code) {
                    runFont = UIFont.monospacedSystemFont(ofSize: font.pointSize - 1, weight: .regular)
                } else {
                    var traits: UIFontDescriptor.SymbolicTraits = []
                    if intent.contains(.stronglyEmphasized) { traits.insert(.traitBold) }
                    if intent.contains(.emphasized) { traits.insert(.traitItalic) }
                    if !traits.isEmpty, let descriptor = font.fontDescriptor.withSymbolicTraits(traits) {
                        runFont = UIFont(descriptor: descriptor, size: font.pointSize)
                    }
                }
            }
            var attributes: [NSAttributedString.Key: Any] = [.font: runFont, .foregroundColor: color]
            if let link = run.link {
                attributes[linkKey] = link
                attributes[.foregroundColor] = linkColor
                attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue
            }
            if run.inlinePresentationIntent?.contains(.strikethrough) == true { attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
            result.append(NSAttributedString(string: text, attributes: attributes))
        }
        return result
    }
}

/// 用 TextKit 1 排版和绘制文字：测量和显示用同一套排版，保证尺寸完全一致。
final class TextBlock {
    let storage: NSTextStorage
    let manager = NSLayoutManager()
    let container: NSTextContainer
    let size: CGSize

    init(_ text: NSAttributedString, maxWidth: CGFloat, maxLines: Int = 0) {
        storage = NSTextStorage(attributedString: text)
        container = NSTextContainer(size: CGSize(width: maxWidth, height: .greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        container.maximumNumberOfLines = maxLines
        if maxLines > 0 { container.lineBreakMode = .byTruncatingTail }
        manager.addTextContainer(container)
        storage.addLayoutManager(manager)
        manager.ensureLayout(for: container)
        let used = manager.usedRect(for: container)
        size = CGSize(width: ceil(used.width), height: ceil(used.height))
    }

    func draw(at origin: CGPoint) {
        let range = manager.glyphRange(for: container)
        manager.drawBackground(forGlyphRange: range, at: origin)
        manager.drawGlyphs(forGlyphRange: range, at: origin)
    }

    /// 点击位置上的链接
    func link(at point: CGPoint) -> URL? {
        guard point.x >= 0, point.y >= 0, point.x <= size.width, point.y <= size.height else { return nil }
        var fraction: CGFloat = 0
        let index = manager.characterIndex(for: point, in: container, fractionOfDistanceBetweenInsertionPoints: &fraction)
        guard index < storage.length else { return nil }
        let value = storage.attribute(RichText.linkKey, at: index, effectiveRange: nil)
        if let url = value as? URL { return url }
        if let string = value as? String { return URL(string: string) }
        return nil
    }
}

final class TextBlockView: UIView {
    var block: TextBlock? {
        didSet { setNeedsDisplay() }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        isOpaque = false
        contentMode = .redraw
    }

    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ rect: CGRect) {
        block?.draw(at: .zero)
    }
}
