import UIKit

enum GroupPosition {
    case single, first, middle, last

    var isFirst: Bool { self == .single || self == .first }
    var isLast: Bool { self == .single || self == .last }
}

enum BubbleStyle {
    case mine, theirs, daju
}

/// 自己发的消息旁边的小圆点：发送中、发送失败、已送达、对方已读
enum Receipt: String {
    case sending, failed, sent, read
}

struct MessageRowData {
    let message: Message
    let isMine: Bool
    let position: GroupPosition
    let style: BubbleStyle
    let showName: Bool
    let showAvatar: Bool
    let statusText: String?
    let receipt: Receipt?
    let failed: Bool
    let progress: Double?
}

enum RowKind {
    case separator(String)
    case system(String)
    case message(MessageRowData)
    case typing(String?)
    case dajuStatus(String)
    case loadingOlder
}

/// 一行在 cell 里的排版结果（坐标都相对于 cell），提前算好，滚动时不再排版
struct RowLayout {
    var height: CGFloat = 0
    var bubble: CGRect = .zero
    var bare = false
    var reply: CGRect?
    var text: TextBlock?
    var textFrame: CGRect = .zero
    var mediaFrames: [CGRect] = []
    var transcript: TextBlock?
    var transcriptFrame: CGRect = .zero
    var name: CGRect?
    var avatar: CGRect?
    var reactions: CGRect?
    var footer: CGRect?
    var footerText: String?
    var receipt: CGRect?
    /// 链接预览卡片（相对气泡），里面的文字和图片位置相对卡片
    var link: CGRect?
    var linkTitle: TextBlock?
    var linkTitleFrame: CGRect = .zero
    var linkDetail: TextBlock?
    var linkDetailFrame: CGRect = .zero
    var linkSite: TextBlock?
    var linkSiteFrame: CGRect = .zero
    var linkImage: CGRect?
}

struct Row {
    let id: String
    let kind: RowKind
    /// 内容指纹：变了才需要重新排版
    let signature: String
    var layout = RowLayout()
}

/// 把消息列表变成时间线：插入时间分隔、分组、已读状态、正在输入
@MainActor
enum TimelineBuilder {
    static let groupGap: TimeInterval = 3 * 60
    static let separatorGap: TimeInterval = 10 * 60

    static func build(chat: ChatModel, app: AppModel) -> [Row] {
        let messages = chat.displayMessages
        let me = app.me?.id ?? ""
        let isDajuChat = chat.conversationId.hasPrefix("daju-")
        var rows: [Row] = []
        if chat.hasOlder && !messages.isEmpty { rows.append(Row(id: "loading-older", kind: .loadingOlder, signature: "loading")) }

        let partnerRead = chat.partnerReadSeq

        var previous: Message?
        for (index, message) in messages.enumerated() {
            let date = message.date
            if let previous {
                let gap = date.timeIntervalSince(previous.date)
                if gap > separatorGap || !Format.calendar.isDate(date, inSameDayAs: previous.date) {
                    rows.append(Row(id: "sep-\(message.id)", kind: .separator(Format.separator(date)), signature: Format.separator(date)))
                }
            } else {
                rows.append(Row(id: "sep-\(message.id)", kind: .separator(Format.separator(date)), signature: Format.separator(date)))
            }
            defer { previous = message }

            if message.isRecalled {
                let who = message.senderId == me ? "你" : app.name(message.senderId)
                rows.append(Row(id: message.id, kind: .system("\(who)撤回了一条消息"), signature: "recalled"))
                continue
            }
            if message.kind == "system" {
                rows.append(Row(id: message.id, kind: .system(message.text), signature: message.text))
                continue
            }

            let next = index + 1 < messages.count ? messages[index + 1] : nil
            let groupedWithPrevious = previous.map { canGroup($0, message) } ?? false
            let groupedWithNext = next.map { canGroup(message, $0) } ?? false
            let position: GroupPosition
            switch (groupedWithPrevious, groupedWithNext) {
            case (false, false): position = .single
            case (false, true): position = .first
            case (true, true): position = .middle
            case (true, false): position = .last
            }
            let isMine = message.senderId == me
            let style: BubbleStyle = isMine ? .mine : (message.senderId == "daju" ? .daju : .theirs)
            let outgoing = chat.outgoingState(message.id)
            var status: String?
            if let outgoing {
                if outgoing.failed {
                    status = "发送失败，点一下重试"
                } else if let progress = outgoing.progress {
                    status = "上传中 \(Int(progress * 100))%"
                }
            }
            if message.editedAt != nil { status = status.map { "已编辑 · \($0)" } ?? "已编辑" }
            // 每条自己发的消息旁边都显示状态；和大橘的私聊没有“已读”
            var receipt: Receipt?
            if isMine {
                if let outgoing {
                    receipt = outgoing.failed ? .failed : .sending
                } else if !isDajuChat {
                    receipt = partnerRead >= message.seq ? .read : .sent
                }
            }
            let data = MessageRowData(
                message: message,
                isMine: isMine,
                position: position,
                style: style,
                showName: false,
                showAvatar: position.isLast,
                statusText: status,
                receipt: receipt,
                failed: outgoing?.failed ?? false,
                progress: outgoing?.progress
            )
            rows.append(Row(id: message.id, kind: .message(data), signature: signature(message, data)))
        }

        if let activity = app.dajuActivity[chat.conversationId] {
            rows.append(Row(id: "daju-status", kind: .dajuStatus(dajuText(activity)), signature: dajuText(activity)))
        } else if app.isTyping(chat.conversationId) {
            rows.append(Row(id: "typing", kind: .typing(app.partner?.id), signature: "typing"))
        }
        return rows
    }

    static func dajuText(_ activity: DajuActivity) -> String {
        switch activity.state {
        case "searching": return activity.detail.isEmpty ? "大橘正在搜索" : "大橘正在搜索：\(activity.detail)"
        case "running": return "大橘正在查资料"
        case "writing": return "大橘正在写回复"
        default: return "大橘正在思考"
        }
    }

    private static func canGroup(_ a: Message, _ b: Message) -> Bool {
        guard a.senderId == b.senderId, !a.isRecalled, !b.isRecalled, a.kind != "system", b.kind != "system" else { return false }
        let standalone = ["interaction", "card", "reminder", "confirm"]
        if standalone.contains(a.kind) || standalone.contains(b.kind) { return false }
        return b.date.timeIntervalSince(a.date) < groupGap && Format.calendar.isDate(a.date, inSameDayAs: b.date)
    }

    private static func signature(_ message: Message, _ data: MessageRowData) -> String {
        let reactions = message.reactions.map { "\($0.userId)\($0.emoji)" }.joined()
        let payload = [message.payload.status ?? "", message.payload.transcript ?? "", String(message.payload.endsAt ?? 0), message.payload.link?.title ?? ""].joined(separator: "|")
        return "\(message.seq)|\(message.text.hashValue)|\(message.editedAt ?? 0)|\(reactions)|\(data.position)|\(data.statusText ?? "")|\(data.receipt?.rawValue ?? "")|\(data.showName)|\(data.showAvatar)|\(payload)|\(message.media.map(\.id).joined())"
    }
}

/// 计算每一行的排版
@MainActor
enum RowLayoutEngine {
    static let sideInset: CGFloat = 10
    static let avatarSize: CGFloat = 30
    /// 头像占的宽度（头像 + 和气泡的间隔）；两边都留，没有头像的那条也对齐
    static let avatarGutter: CGFloat = avatarSize + 6
    static let textInsets = UIEdgeInsets(top: 8, left: 13, bottom: 8, right: 13)
    static let replyHeight: CGFloat = 42
    static let reactionHeight: CGFloat = 26
    static let footerHeight: CGFloat = 16
    /// 自己的消息右边留给已读标记的位置（16 的圆点 + 4 的间隔），有没有标记都留，气泡右边线对齐
    static let receiptSpace: CGFloat = 20

    /// 提醒卡片里文字的起点（闹钟图标占左边）
    static let reminderTextInset: CGFloat = 56

    static func maxBubbleWidth(_ width: CGFloat) -> CGFloat {
        min((width - sideInset * 2 - avatarGutter) * 0.8, 520)
    }

    static func layout(_ row: Row, width: CGFloat, app: AppModel) -> RowLayout {
        switch row.kind {
        case .separator:
            return RowLayout(height: 34)
        case .loadingOlder:
            return RowLayout(height: 44)
        case .system(let text):
            let block = TextBlock(NSAttributedString(string: text, attributes: [.font: RichText.captionFont, .foregroundColor: UIColor.secondaryLabel]), maxWidth: width - 80)
            var layout = RowLayout(height: block.size.height + 16)
            layout.text = block
            layout.textFrame = CGRect(x: (width - block.size.width) / 2, y: 8, width: block.size.width, height: block.size.height)
            return layout
        case .typing, .dajuStatus:
            var layout = RowLayout(height: 48)
            layout.bubble = CGRect(x: sideInset, y: 6, width: 0, height: 36)
            return layout
        case .message(let data):
            return messageLayout(data, width: width, app: app)
        }
    }

    private static func messageLayout(_ data: MessageRowData, width: CGFloat, app: AppModel) -> RowLayout {
        let message = data.message
        var layout = RowLayout()
        let maxWidth = maxBubbleWidth(width)
        var top: CGFloat = data.position.isFirst ? 8 : 2
        let leading: CGFloat = sideInset + avatarGutter

        if data.showName {
            layout.name = CGRect(x: leading + 4, y: top, width: 200, height: 16)
            top += 18
        }

        // 气泡内容
        var contentSize: CGSize
        var bubbleInsets = textInsets
        let hasReply = message.replyTo != nil
        let replyWidth: CGFloat = hasReply ? min(maxWidth, 240) : 0

        switch message.kind {
        case "text":
            if RichText.isEmojiOnly(message.text) && !hasReply {
                let block = TextBlock(NSAttributedString(string: message.text, attributes: [.font: UIFont.systemFont(ofSize: 50)]), maxWidth: maxWidth)
                layout.text = block
                layout.bare = true
                contentSize = block.size
                bubbleInsets = .zero
            } else {
                let textWidth = maxWidth - textInsets.left - textInsets.right
                let block = TextBlock(textAttributed(data), maxWidth: textWidth)
                layout.text = block
                contentSize = block.size
                if let link = message.payload.link {
                    let card = linkLayout(link, data: data, width: min(textWidth, 250), into: &layout)
                    layout.link = CGRect(x: 0, y: contentSize.height + 8, width: card.width, height: card.height)
                    contentSize = CGSize(width: max(contentSize.width, card.width), height: contentSize.height + 8 + card.height)
                }
            }
        case "image", "video":
            let media = message.media
            if media.isEmpty {
                contentSize = CGSize(width: 180, height: 120)
            } else {
                let frames = mediaGrid(media, maxWidth: min(maxWidth, 250))
                layout.mediaFrames = frames
                contentSize = frames.reduce(CGRect.null) { $0.union($1) }.size
            }
            bubbleInsets = hasReply ? UIEdgeInsets(top: 0, left: 4, bottom: 4, right: 4) : .zero
        case "sticker":
            let media = message.media.first
            let ratio = media?.aspectRatio ?? 1
            let side: CGFloat = 130
            contentSize = ratio >= 1 ? CGSize(width: side, height: side / ratio) : CGSize(width: side * ratio, height: side)
            layout.mediaFrames = [CGRect(origin: .zero, size: contentSize)]
            layout.bare = true
            bubbleInsets = .zero
        case "voice":
            let seconds = Double(message.media.first?.durationMs ?? 0) / 1000
            let barWidth = 90 + min(1, seconds / 60) * 120
            contentSize = CGSize(width: barWidth, height: 24)
            if let transcript = message.payload.transcript, !transcript.isEmpty {
                let color = data.style == .mine ? UIColor.white : UIColor.label
                let block = TextBlock(NSAttributedString(string: transcript, attributes: [.font: RichText.transcriptFont, .foregroundColor: color.withAlphaComponent(0.9)]), maxWidth: maxWidth - textInsets.left - textInsets.right)
                layout.transcript = block
                contentSize.width = max(contentSize.width, block.size.width)
                layout.transcriptFrame = CGRect(x: 0, y: contentSize.height + 8, width: block.size.width, height: block.size.height)
                contentSize.height += 8 + block.size.height
            }
        case "file":
            contentSize = CGSize(width: min(maxWidth - 26, 220), height: 44)
        case "card":
            contentSize = CGSize(width: min(maxWidth, 260), height: cardHeight(data, app: app))
            layout.bare = true
            bubbleInsets = .zero
        case "confirm":
            let cardWidth = min(maxWidth, 270)
            let block = TextBlock(NSAttributedString(string: message.text, attributes: [.font: UIFont.systemFont(ofSize: 16, weight: .semibold), .foregroundColor: UIColor.white]), maxWidth: cardWidth - 32)
            layout.text = block
            contentSize = CGSize(width: cardWidth, height: confirmHeight(data, textHeight: block.size.height))
            layout.bare = true
            bubbleInsets = .zero
        case "reminder":
            // 提醒卡片居中显示，宽度随内容：左边闹钟，中间“提醒”和内容，右边箭头（点一下打开计划）
            let cardMax = min(width - 48, 320)
            let block = TextBlock(NSAttributedString(string: message.text, attributes: [.font: UIFont.systemFont(ofSize: 17, weight: .semibold), .foregroundColor: UIColor.white]), maxWidth: cardMax - reminderTextInset - 34)
            layout.text = block
            let cardWidth = max(210, min(cardMax, block.size.width + reminderTextInset + 34))
            let cardHeight = max(60, block.size.height + 40)
            layout.bubble = CGRect(x: ((width - cardWidth) / 2).rounded(), y: 8, width: cardWidth, height: cardHeight)
            layout.textFrame = CGRect(x: reminderTextInset, y: 28, width: block.size.width, height: block.size.height)
            layout.height = ceil(cardHeight + 16)
            return layout
        case "interaction":
            let text = interactionText(data, app: app)
            let block = TextBlock(NSAttributedString(string: text, attributes: [.font: UIFont.systemFont(ofSize: 15, weight: .medium), .foregroundColor: UIColor.label]), maxWidth: width - 120)
            layout.text = block
            let size = CGSize(width: block.size.width + 58, height: max(40, block.size.height + 20))
            layout.bubble = CGRect(x: (width - size.width) / 2, y: 10, width: size.width, height: size.height)
            layout.textFrame = CGRect(x: 44, y: (size.height - block.size.height) / 2, width: block.size.width, height: block.size.height)
            layout.height = size.height + 20
            return layout
        default:
            let block = TextBlock(textAttributed(data), maxWidth: maxWidth - textInsets.left - textInsets.right)
            layout.text = block
            contentSize = block.size
        }

        // 引用块放在内容上面
        var bubbleWidth = contentSize.width + bubbleInsets.left + bubbleInsets.right
        var contentTop = bubbleInsets.top
        if hasReply {
            bubbleWidth = max(bubbleWidth, replyWidth)
            layout.reply = CGRect(x: 6, y: 6, width: bubbleWidth - 12, height: replyHeight)
            contentTop = 6 + replyHeight + (layout.mediaFrames.isEmpty ? 4 : 4)
            if layout.bare {
                layout.bare = message.kind == "card" || message.kind == "reminder"
            }
        }
        let bubbleHeight = contentTop + contentSize.height + (hasReply && !layout.mediaFrames.isEmpty ? 4 : bubbleInsets.bottom)
        let bubbleX = data.isMine ? width - sideInset - avatarGutter - receiptSpace - bubbleWidth : leading
        layout.bubble = CGRect(x: bubbleX, y: top, width: bubbleWidth, height: bubbleHeight)
        let contentX = message.kind == "text" || message.kind == "voice" || message.kind == "file" ? bubbleInsets.left : (bubbleWidth - contentSize.width) / 2
        layout.textFrame = CGRect(x: contentX, y: contentTop, width: layout.text?.size.width ?? contentSize.width, height: layout.text?.size.height ?? contentSize.height)
        if !layout.mediaFrames.isEmpty {
            layout.mediaFrames = layout.mediaFrames.map { $0.offsetBy(dx: contentX, dy: contentTop) }
        }
        if layout.transcript != nil {
            layout.transcriptFrame = layout.transcriptFrame.offsetBy(dx: bubbleInsets.left, dy: contentTop)
        }
        if let link = layout.link {
            layout.link = link.offsetBy(dx: contentX, dy: contentTop)
        }
        if data.receipt != nil {
            // 贴着气泡右边、离底边 9pt（和旧版一样）；气泡很矮时居中
            let lift = min(9, max(0, (layout.bubble.height - 16) / 2))
            layout.receipt = CGRect(x: layout.bubble.maxX + 4, y: layout.bubble.maxY - 16 - lift, width: 16, height: 16)
        }
        var bottom = layout.bubble.maxY

        if !message.reactions.isEmpty {
            let emojis = Set(message.reactions.map(\.emoji)).count
            let pillWidth = CGFloat(emojis) * 22 + (message.reactions.count > emojis ? 22 : 0) + 12
            let x = data.isMine ? layout.bubble.minX - 4 : layout.bubble.maxX - pillWidth + 4
            layout.reactions = CGRect(x: max(sideInset, min(x, width - sideInset - pillWidth)), y: layout.bubble.maxY - 6, width: pillWidth, height: reactionHeight)
            bottom = layout.bubble.maxY - 6 + reactionHeight
        }
        if data.showAvatar {
            let x = data.isMine ? width - sideInset - avatarSize : sideInset
            layout.avatar = CGRect(x: x, y: layout.bubble.maxY - avatarSize, width: avatarSize, height: avatarSize)
        }
        if let status = data.statusText {
            layout.footerText = status
            let footerWidth: CGFloat = 200
            let x = data.isMine ? layout.bubble.maxX - footerWidth : layout.bubble.minX
            layout.footer = CGRect(x: x, y: bottom + 3, width: footerWidth, height: footerHeight)
            bottom += footerHeight + 3
        }
        layout.height = ceil(bottom + (data.position.isLast ? 4 : 0))
        return layout
    }

    static func textAttributed(_ data: MessageRowData) -> NSAttributedString {
        let message = data.message
        let color: UIColor = data.style == .mine ? .white : .label
        let linkColor: UIColor = data.style == .mine ? .white : Theme.accent
        if message.payload.legacyType != nil {
            let italic = UIFont.italicSystemFont(ofSize: 17)
            return NSAttributedString(string: message.text, attributes: [.font: italic, .foregroundColor: color.withAlphaComponent(0.65)])
        }
        return RichText.attributed(message.text, color: color, linkColor: linkColor, markdown: message.payload.markdown == true)
    }

    @MainActor
    static func interactionText(_ data: MessageRowData, app: AppModel) -> String {
        let message = data.message
        let interaction = message.payload.interaction ?? ""
        let sender = data.isMine ? "你" : app.name(message.senderId)
        if interaction == "note" { return "\(sender)举牌：\(message.text)" }
        let verbs: [String: String] = [
            "miss": "想你了", "pat": "拍了拍", "poke": "戳了戳", "flower": "送了一朵花", "heart": "比了个心",
            "hug": "抱了抱", "kiss": "亲了亲", "fireworks": "放了一场烟花", "poop": "扔了一坨便便",
        ]
        let target = data.isMine ? (app.partner.map { app.name($0.id) } ?? "对方") : "你"
        switch interaction {
        case "miss": return "\(sender)说：想你了"
        case "fireworks", "flower", "heart", "poop": return "\(sender)\(verbs[interaction] ?? "")给\(target)"
        default: return "\(sender)\(verbs[interaction] ?? "互动了")\(target)"
        }
    }

    /// 大橘的确认卡片：标题行、内容、按钮或结果
    static func confirmHeight(_ data: MessageRowData, textHeight: CGFloat) -> CGFloat {
        let pending = data.message.payload.status == "pending"
        return 16 + 20 + 8 + textHeight + 12 + (pending ? 38 : 20) + 16
    }

    /// 链接卡片：左边标题、简介、网站名，有图时右边放缩略图
    private static func linkLayout(_ link: LinkPreview, data: MessageRowData, width: CGFloat, into layout: inout RowLayout) -> CGSize {
        let mine = data.style == .mine
        let primary: UIColor = mine ? .white : .label
        let secondary: UIColor = mine ? UIColor.white.withAlphaComponent(0.8) : .secondaryLabel
        let padding: CGFloat = 10
        let imageSide: CGFloat = 56
        let hasImage = link.imageMediaId != nil
        let textWidth = width - padding * 2 - (hasImage ? imageSide + 8 : 0)
        var y = padding
        if !link.title.isEmpty {
            let block = TextBlock(NSAttributedString(string: link.title, attributes: [.font: UIFont.systemFont(ofSize: 15, weight: .semibold), .foregroundColor: primary]), maxWidth: textWidth, maxLines: 2)
            layout.linkTitle = block
            layout.linkTitleFrame = CGRect(x: padding, y: y, width: block.size.width, height: block.size.height)
            y += block.size.height + 3
        }
        if !link.description.isEmpty {
            let block = TextBlock(NSAttributedString(string: link.description, attributes: [.font: UIFont.systemFont(ofSize: 13), .foregroundColor: secondary]), maxWidth: textWidth, maxLines: 2)
            layout.linkDetail = block
            layout.linkDetailFrame = CGRect(x: padding, y: y, width: block.size.width, height: block.size.height)
            y += block.size.height + 3
        }
        let site = TextBlock(NSAttributedString(string: link.siteName, attributes: [.font: UIFont.systemFont(ofSize: 11, weight: .medium), .foregroundColor: secondary]), maxWidth: textWidth, maxLines: 1)
        layout.linkSite = site
        layout.linkSiteFrame = CGRect(x: padding, y: y, width: site.size.width, height: site.size.height)
        var height = y + site.size.height + padding
        if hasImage {
            height = max(height, imageSide + padding * 2)
            layout.linkImage = CGRect(x: width - padding - imageSide, y: padding, width: imageSide, height: imageSide)
        }
        return CGSize(width: width, height: height)
    }

    static func cardHeight(_ data: MessageRowData, app: AppModel) -> CGFloat {
        let payload = data.message.payload
        let waitingForMe = payload.status == "pending" && payload.toUser == app.me?.id && payload.effect != "addTime" && payload.effect != "copy" && payload.effect != "bounce"
        var height: CGFloat = 150
        if !data.message.text.isEmpty { height += 22 }
        if waitingForMe { height += 46 }
        return height
    }

    /// 一张图按比例；多张排成网格
    static func mediaGrid(_ media: [MessageMedia], maxWidth: CGFloat) -> [CGRect] {
        if media.count == 1 {
            let item = media[0]
            let ratio = item.aspectRatio
            var width = maxWidth
            var height = width / ratio
            let maxHeight: CGFloat = 320
            if height > maxHeight {
                height = maxHeight
                width = height * ratio
            }
            width = max(width, item.kind == "video" ? 160 : 110)
            height = max(height, 80)
            return [CGRect(x: 0, y: 0, width: width, height: height)]
        }
        let columns = media.count == 2 || media.count == 4 ? 2 : 3
        let gap: CGFloat = 2
        let side = floor((maxWidth - gap * CGFloat(columns - 1)) / CGFloat(columns))
        return media.enumerated().map { index, _ in
            CGRect(x: CGFloat(index % columns) * (side + gap), y: CGFloat(index / columns) * (side + gap), width: side, height: side)
        }
    }
}
