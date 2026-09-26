import UIKit

@MainActor
protocol MessageCellDelegate: AnyObject {
    func cellDidTapMedia(_ message: Message, index: Int, from view: UIView)
    func cellDidTapVoice(_ message: Message)
    func cellDidTapFile(_ message: Message)
    func cellDidTapReply(_ message: Message)
    func cellDidTapLink(_ url: URL)
    func cellDidTapFailed(_ message: Message)
    func cellDidTapCard(_ message: Message, accept: Bool)
    func cellDidConfirm(_ message: Message, accept: Bool)
    func cellDidTapInteraction(_ message: Message)
    func cellDidDoubleTap(_ message: Message)
    func cellDidOpenPlan(_ message: Message)
}

/// 每个角单独设置圆角的路径：分组里相邻的一侧用小圆角
enum BubbleShape {
    static func path(_ rect: CGRect, isMine: Bool, position: GroupPosition) -> UIBezierPath {
        let big = Theme.Radius.bubble
        let small = Theme.Radius.bubbleTight
        var tl = big, tr = big, bl = big, br = big
        switch (isMine, position) {
        case (true, .first): br = small
        case (true, .middle): tr = small; br = small
        case (true, .last): tr = small
        case (false, .first): bl = small
        case (false, .middle): tl = small; bl = small
        case (false, .last): tl = small
        default: break
        }
        let limit = min(rect.width, rect.height) / 2
        tl = min(tl, limit); tr = min(tr, limit); bl = min(bl, limit); br = min(br, limit)
        let path = UIBezierPath()
        path.move(to: CGPoint(x: rect.minX + tl, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX - tr, y: rect.minY))
        path.addArc(withCenter: CGPoint(x: rect.maxX - tr, y: rect.minY + tr), radius: tr, startAngle: -.pi / 2, endAngle: 0, clockwise: true)
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - br))
        path.addArc(withCenter: CGPoint(x: rect.maxX - br, y: rect.maxY - br), radius: br, startAngle: 0, endAngle: .pi / 2, clockwise: true)
        path.addLine(to: CGPoint(x: rect.minX + bl, y: rect.maxY))
        path.addArc(withCenter: CGPoint(x: rect.minX + bl, y: rect.maxY - bl), radius: bl, startAngle: .pi / 2, endAngle: .pi, clockwise: true)
        path.addLine(to: CGPoint(x: rect.minX, y: rect.minY + tl))
        path.addArc(withCenter: CGPoint(x: rect.minX + tl, y: rect.minY + tl), radius: tl, startAngle: .pi, endAngle: -.pi / 2, clockwise: true)
        path.close()
        return path
    }
}

/// 气泡背景：自己的是渐变色，对方的是纯色
final class BubbleView: UIView {
    let gradient = CAGradientLayer()
    let shape = CAShapeLayer()

    override init(frame: CGRect) {
        super.init(frame: frame)
        layer.addSublayer(gradient)
        gradient.startPoint = CGPoint(x: 0, y: 0)
        gradient.endPoint = CGPoint(x: 1, y: 1)
        layer.mask = shape
    }

    required init?(coder: NSCoder) { fatalError() }

    func configure(style: BubbleStyle, isMine: Bool, position: GroupPosition, transparent: Bool) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        gradient.frame = bounds
        shape.path = BubbleShape.path(bounds, isMine: isMine, position: position).cgPath
        if transparent {
            gradient.colors = [UIColor.clear.cgColor, UIColor.clear.cgColor]
        } else {
            switch style {
            case .mine: gradient.colors = Theme.palette.gradient.map { $0.cgColor }
            case .theirs:
                let color = Theme.incomingBubble.resolvedColor(with: traitCollection).cgColor
                gradient.colors = [color, color]
            case .daju:
                let color = Theme.dajuBubble.resolvedColor(with: traitCollection).cgColor
                gradient.colors = [color, color]
            }
        }
        CATransaction.commit()
    }
}

/// 引用块
final class ReplyQuoteView: UIView {
    let bar = UIView()
    let nameLabel = UILabel()
    let textLabel = UILabel()

    override init(frame: CGRect) {
        super.init(frame: frame)
        layer.cornerRadius = 10
        layer.cornerCurve = .continuous
        clipsToBounds = true
        bar.layer.cornerRadius = 1.5
        nameLabel.font = RichText.replyNameFont
        textLabel.font = RichText.replyTextFont
        textLabel.lineBreakMode = .byTruncatingTail
        addSubview(bar)
        addSubview(nameLabel)
        addSubview(textLabel)
    }

    required init?(coder: NSCoder) { fatalError() }

    func configure(_ reply: ReplyPreview, name: String, onMine: Bool) {
        let foreground: UIColor = onMine ? .white : .label
        backgroundColor = onMine ? UIColor.white.withAlphaComponent(0.18) : UIColor.label.withAlphaComponent(0.06)
        bar.backgroundColor = onMine ? .white : Theme.accent
        nameLabel.textColor = onMine ? .white : Theme.accent
        nameLabel.text = name
        textLabel.textColor = foreground.withAlphaComponent(0.8)
        textLabel.text = reply.recalled ? "消息已撤回" : MessagePreview.plain(reply.text.isEmpty ? "[\(reply.kind)]" : reply.text)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        bar.frame = CGRect(x: 6, y: 6, width: 3, height: bounds.height - 12)
        nameLabel.frame = CGRect(x: 15, y: 5, width: bounds.width - 21, height: 16)
        textLabel.frame = CGRect(x: 15, y: 21, width: bounds.width - 21, height: 17)
    }
}

/// 语音：播放按钮 + 波形 + 时长
final class VoiceContentView: UIView {
    let playIcon = UIImageView()
    let durationLabel = UILabel()
    private var bars: [CALayer] = []
    private var waveform: [Double] = []
    private var tint: UIColor = .white
    private var progress: Double = 0

    override init(frame: CGRect) {
        super.init(frame: frame)
        playIcon.contentMode = .scaleAspectFit
        durationLabel.font = .monospacedDigitSystemFont(ofSize: 13, weight: .medium)
        durationLabel.textAlignment = .right
        addSubview(playIcon)
        addSubview(durationLabel)
    }

    required init?(coder: NSCoder) { fatalError() }

    func configure(message: Message, tint: UIColor, playing: Bool, loading: Bool, progress: Double) {
        self.tint = tint
        self.progress = playing ? progress : 0
        waveform = message.payload.waveform.flatMap { $0.isEmpty ? nil : $0 } ?? Array(repeating: 0.3, count: 24)
        playIcon.image = UIImage(systemName: loading ? "ellipsis" : (playing ? "pause.fill" : "play.fill"))
        playIcon.tintColor = tint
        durationLabel.textColor = tint.withAlphaComponent(0.85)
        durationLabel.text = Format.voiceSeconds(message.media.first?.durationMs)
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        playIcon.frame = CGRect(x: 0, y: (bounds.height - 18) / 2, width: 18, height: 18)
        durationLabel.frame = CGRect(x: bounds.width - 34, y: 0, width: 34, height: bounds.height)
        bars.forEach { $0.removeFromSuperlayer() }
        bars = []
        let area = CGRect(x: 26, y: 2, width: max(0, bounds.width - 26 - 40), height: bounds.height - 4)
        // 复用的格子在 configure 之前也会被布局，这时还没有波形
        guard !waveform.isEmpty, area.width >= 4 else { return }
        let count = min(waveform.count, Int(area.width / 4))
        let step = area.width / CGFloat(count)
        for index in 0 ..< count {
            let sample = min(1, max(0, waveform[index * waveform.count / count]))
            let height = max(3, area.height * CGFloat(0.15 + 0.85 * sample))
            let bar = CALayer()
            bar.frame = CGRect(x: area.minX + CGFloat(index) * step, y: area.midY - height / 2, width: max(2, step - 2), height: height)
            bar.cornerRadius = 1
            let played = Double(index) / Double(count) < progress
            bar.backgroundColor = tint.withAlphaComponent(played ? 1 : 0.45).cgColor
            layer.addSublayer(bar)
            bars.append(bar)
        }
    }
}

/// 跳转到某条消息时的强调：整行铺一层主题色、气泡外描一圈，先亮一会儿再慢慢褪掉；气泡轻轻弹一下
enum MessageFlash {
    static let duration: CFTimeInterval = 2.8

    /// elapsed 是已经闪了多久：cell 被重建时接着闪完，不从头来
    static func fade(_ view: UIView, elapsed: CFTimeInterval) {
        view.layer.removeAnimation(forKey: "flash")
        view.layer.opacity = 0
        guard elapsed < duration else { return }
        let animation = CAKeyframeAnimation(keyPath: "opacity")
        animation.values = [0, 1, 1, 0.85, 1, 0]
        animation.keyTimes = [0, 0.06, 0.3, 0.38, 0.5, 1]
        animation.duration = duration
        animation.beginTime = view.layer.convertTime(CACurrentMediaTime(), from: nil) - elapsed
        view.layer.add(animation, forKey: "flash")
    }

    static func pulse(_ view: UIView) {
        let animation = CAKeyframeAnimation(keyPath: "transform.scale")
        animation.values = [1, 1.08, 0.97, 1.02, 1]
        animation.keyTimes = [0, 0.3, 0.6, 0.82, 1]
        animation.duration = 0.75
        animation.beginTime = view.layer.convertTime(CACurrentMediaTime(), from: nil) + 0.1
        animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        view.layer.add(animation, forKey: "pulse")
    }

    static func band(_ view: UIView, in contentView: UIView) {
        view.frame = contentView.bounds
        view.backgroundColor = Theme.accent.withAlphaComponent(0.18)
    }

    static func stop(_ views: UIView...) {
        for view in views {
            view.layer.removeAnimation(forKey: "flash")
            view.layer.opacity = 0
        }
    }

    static func makeOverlay() -> UIView {
        let view = UIView()
        view.isUserInteractionEnabled = false
        view.layer.opacity = 0
        return view
    }
}

@MainActor
protocol MessageFlashing: AnyObject {
    func flash(elapsed: CFTimeInterval)
}

final class MessageCell: UICollectionViewCell, MessageFlashing {
    static let reuseId = "message"

    weak var delegate: MessageCellDelegate?
    private(set) var message: Message?
    let bubble = BubbleView()
    private let textView = TextBlockView()
    private let transcriptView = TextBlockView()
    private let reply = ReplyQuoteView()
    private var imageViews: [UIImageView] = []
    private let playBadge = UIImageView(image: UIImage(systemName: "play.circle.fill"))
    private let durationBadge = PaddingLabel()
    private let voiceView = VoiceContentView()
    private let fileIcon = UIImageView(image: UIImage(systemName: "doc.fill"))
    private let fileName = UILabel()
    private let fileSize = UILabel()
    private let nameLabel = UILabel()
    private let avatarView = AvatarBadgeView(frame: .zero)
    private let reactionsLabel = PaddingLabel()
    private let footerLabel = UILabel()
    private let receiptLabel = UILabel()
    private let progressView = UIProgressView(progressViewStyle: .bar)
    private let missingLabel = UILabel()
    private let linkCard = UIView()
    private let linkTitleView = TextBlockView()
    private let linkDetailView = TextBlockView()
    private let linkSiteView = TextBlockView()
    private let linkImageView = UIImageView()
    private var loadTasks: [Task<Void, Never>] = []
    private var layoutInfo = RowLayout()
    private var isMine = false
    private let flashBand = MessageFlash.makeOverlay()
    private let flashRing = MessageFlash.makeOverlay()

    override init(frame: CGRect) {
        super.init(frame: frame)
        contentView.addSubview(flashBand)
        flashRing.layer.borderWidth = 2.5
        flashRing.layer.cornerCurve = .continuous
        contentView.addSubview(flashRing)
        contentView.addSubview(bubble)
        bubble.addSubview(reply)
        bubble.addSubview(textView)
        bubble.addSubview(transcriptView)
        linkCard.layer.cornerRadius = 12
        linkCard.layer.cornerCurve = .continuous
        linkCard.clipsToBounds = true
        linkImageView.contentMode = .scaleAspectFill
        linkImageView.clipsToBounds = true
        linkImageView.layer.cornerRadius = 8
        linkImageView.backgroundColor = .tertiarySystemFill
        [linkTitleView, linkDetailView, linkSiteView, linkImageView].forEach { linkCard.addSubview($0) }
        bubble.addSubview(linkCard)
        receiptLabel.font = .systemFont(ofSize: 9, weight: .bold)
        receiptLabel.textAlignment = .center
        receiptLabel.layer.cornerRadius = 8
        receiptLabel.layer.borderWidth = 1.3
        receiptLabel.clipsToBounds = true
        receiptLabel.isUserInteractionEnabled = true
        receiptLabel.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(tapFooter)))
        contentView.addSubview(receiptLabel)
        for _ in 0 ..< 9 {
            let view = UIImageView()
            view.contentMode = .scaleAspectFill
            view.clipsToBounds = true
            view.backgroundColor = .secondarySystemFill
            view.isUserInteractionEnabled = true
            view.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(tapImage(_:))))
            imageViews.append(view)
            bubble.addSubview(view)
        }
        playBadge.tintColor = .white
        playBadge.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: 40, weight: .regular)
        playBadge.layer.shadowOpacity = 0.3
        playBadge.layer.shadowRadius = 6
        playBadge.layer.shadowOffset = .zero
        durationBadge.font = .monospacedDigitSystemFont(ofSize: 12, weight: .semibold)
        durationBadge.textColor = .white
        durationBadge.backgroundColor = UIColor.black.withAlphaComponent(0.45)
        durationBadge.layer.cornerRadius = 9
        durationBadge.clipsToBounds = true
        bubble.addSubview(playBadge)
        bubble.addSubview(durationBadge)
        bubble.addSubview(voiceView)
        fileIcon.contentMode = .scaleAspectFit
        fileName.font = .systemFont(ofSize: 15, weight: .medium)
        fileName.numberOfLines = 1
        fileName.lineBreakMode = .byTruncatingMiddle
        fileSize.font = .systemFont(ofSize: 12)
        bubble.addSubview(fileIcon)
        bubble.addSubview(fileName)
        bubble.addSubview(fileSize)
        missingLabel.font = .systemFont(ofSize: 13)
        missingLabel.textColor = .secondaryLabel
        missingLabel.textAlignment = .center
        missingLabel.text = "文件已丢失"
        bubble.addSubview(missingLabel)
        progressView.progressTintColor = .white
        progressView.trackTintColor = UIColor.white.withAlphaComponent(0.3)
        bubble.addSubview(progressView)

        nameLabel.font = .systemFont(ofSize: 12, weight: .semibold)
        nameLabel.textColor = Theme.dajuAccent

        reactionsLabel.font = .systemFont(ofSize: 14)
        reactionsLabel.backgroundColor = .secondarySystemBackground
        reactionsLabel.layer.cornerRadius = 13
        reactionsLabel.layer.borderWidth = 2
        reactionsLabel.layer.borderColor = UIColor.systemBackground.cgColor
        reactionsLabel.clipsToBounds = true
        reactionsLabel.textAlignment = .center
        footerLabel.font = .systemFont(ofSize: 11, weight: .medium)
        footerLabel.textColor = .secondaryLabel
        contentView.addSubview(nameLabel)
        contentView.addSubview(avatarView)
        contentView.addSubview(reactionsLabel)
        contentView.addSubview(footerLabel)

        let bubbleTap = UITapGestureRecognizer(target: self, action: #selector(tapBubble(_:)))
        let doubleTap = UITapGestureRecognizer(target: self, action: #selector(doubleTapBubble))
        doubleTap.numberOfTapsRequired = 2
        bubbleTap.require(toFail: doubleTap)
        for view in imageViews { view.gestureRecognizers?.first?.require(toFail: doubleTap) }
        bubble.addGestureRecognizer(bubbleTap)
        bubble.addGestureRecognizer(doubleTap)
        footerLabel.isUserInteractionEnabled = true
        footerLabel.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(tapFooter)))
        NotificationCenter.default.addObserver(self, selector: #selector(voiceChanged), name: .voicePlayerChanged, object: nil)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func prepareForReuse() {
        super.prepareForReuse()
        loadTasks.forEach { $0.cancel() }
        loadTasks = []
        imageViews.forEach { $0.image = nil }
        avatarView.reset()
        MessageFlash.stop(flashBand, flashRing)
        bubble.layer.removeAnimation(forKey: "pulse")
    }

    var bubbleSnapshotView: UIView { bubble }

    func flash(elapsed: CFTimeInterval) {
        MessageFlash.band(flashBand, in: contentView)
        flashRing.frame = bubble.frame.insetBy(dx: -4, dy: -4)
        flashRing.layer.cornerRadius = min(24, flashRing.bounds.height / 2)
        flashRing.layer.borderColor = Theme.accent.cgColor
        flashRing.backgroundColor = Theme.accent.withAlphaComponent(0.12)
        MessageFlash.fade(flashBand, elapsed: elapsed)
        MessageFlash.fade(flashRing, elapsed: elapsed)
        if elapsed < 0.4 { MessageFlash.pulse(bubble) }
    }

    func configure(_ data: MessageRowData, layout: RowLayout, app: AppModel) {
        message = data.message
        layoutInfo = layout
        isMine = data.isMine
        let message = data.message
        let hideAll: (UIView) -> Void = { $0.isHidden = true }
        [reply, textView, transcriptView, playBadge, durationBadge, voiceView, fileIcon, fileName, fileSize, missingLabel, progressView, linkCard].forEach(hideAll)
        imageViews.forEach(hideAll)

        bubble.frame = layout.bubble
        let imageOnly = (message.kind == "image" || message.kind == "video") && message.replyTo == nil && !message.media.isEmpty
        bubble.configure(style: data.style, isMine: data.isMine, position: data.position, transparent: layout.bare || imageOnly)
        bubble.alpha = data.failed ? 0.6 : 1

        if let replyFrame = layout.reply, let replyTo = message.replyTo {
            reply.isHidden = false
            reply.frame = replyFrame
            reply.configure(replyTo, name: replyTo.senderId == app.me?.id ? "我" : app.name(replyTo.senderId), onMine: data.style == .mine)
        }

        switch message.kind {
        case "image", "video", "sticker":
            configureMedia(message, frames: layout.mediaFrames, isSticker: message.kind == "sticker")
            if message.payload.missing == true || message.media.isEmpty {
                missingLabel.isHidden = false
                missingLabel.frame = bubble.bounds
                bubble.configure(style: .theirs, isMine: data.isMine, position: data.position, transparent: false)
            }
        case "voice":
            voiceView.isHidden = false
            voiceView.frame = CGRect(x: layout.textFrame.minX, y: layout.textFrame.minY, width: layout.bubble.width - RowLayoutEngine.textInsets.left - RowLayoutEngine.textInsets.right, height: 24)
            updateVoice()
            if let transcript = layout.transcript {
                transcriptView.isHidden = false
                transcriptView.block = transcript
                transcriptView.frame = layout.transcriptFrame
            }
        case "file":
            let tint: UIColor = data.style == .mine ? .white : Theme.accent
            fileIcon.isHidden = false
            fileName.isHidden = false
            fileSize.isHidden = false
            fileIcon.tintColor = tint
            fileIcon.frame = CGRect(x: 12, y: 12, width: 30, height: 36)
            fileName.frame = CGRect(x: 50, y: 12, width: layout.bubble.width - 62, height: 20)
            fileSize.frame = CGRect(x: 50, y: 33, width: layout.bubble.width - 62, height: 16)
            fileName.textColor = data.style == .mine ? .white : .label
            fileSize.textColor = (data.style == .mine ? UIColor.white : UIColor.secondaryLabel).withAlphaComponent(0.8)
            fileName.text = message.media.first?.name ?? "文件"
            fileSize.text = Format.fileSize(Int64(message.media.first?.size ?? 0))
        default:
            if let text = layout.text {
                textView.isHidden = false
                textView.block = text
                textView.frame = layout.textFrame
            }
            if let frame = layout.link, let link = message.payload.link {
                configureLink(link, frame: frame, layout: layout, mine: data.style == .mine)
            }
        }

        receiptLabel.isHidden = layout.receipt == nil || data.receipt == nil
        if let frame = layout.receipt, let receipt = data.receipt {
            receiptLabel.frame = frame
            let accent = Theme.accent
            switch receipt {
            case .sending:
                receiptLabel.text = "…"
                receiptLabel.textColor = accent
                receiptLabel.backgroundColor = .clear
                receiptLabel.layer.borderColor = accent.withAlphaComponent(0.5).cgColor
            case .failed:
                receiptLabel.text = "!"
                receiptLabel.textColor = .white
                receiptLabel.backgroundColor = .systemRed
                receiptLabel.layer.borderColor = UIColor.systemRed.cgColor
            case .sent:
                receiptLabel.text = "✓"
                receiptLabel.textColor = accent
                receiptLabel.backgroundColor = .clear
                receiptLabel.layer.borderColor = accent.withAlphaComponent(0.85).cgColor
            case .read:
                receiptLabel.text = "✓"
                receiptLabel.textColor = .white
                receiptLabel.backgroundColor = accent.withAlphaComponent(0.92)
                receiptLabel.layer.borderColor = accent.cgColor
            }
            receiptLabel.accessibilityLabel = ["sending": "正在发送", "failed": "发送失败", "sent": "已送达", "read": "已读"][receipt.rawValue]
        }

        if let progress = data.progress {
            progressView.isHidden = false
            progressView.frame = CGRect(x: 12, y: layout.bubble.height - 10, width: layout.bubble.width - 24, height: 3)
            progressView.progress = Float(progress)
        }

        nameLabel.isHidden = layout.name == nil
        if let frame = layout.name {
            nameLabel.frame = frame
            nameLabel.text = app.daju?.displayName ?? "大橘"
        }
        avatarView.isHidden = layout.avatar == nil
        if let frame = layout.avatar {
            avatarView.frame = frame
            avatarView.configure(userId: message.senderId, isMine: data.isMine, app: app)
        }
        reactionsLabel.isHidden = layout.reactions == nil
        if let frame = layout.reactions {
            reactionsLabel.frame = frame
            reactionsLabel.text = reactionsText(message.reactions)
            reactionsLabel.layer.borderColor = UIColor.systemBackground.cgColor
        }
        footerLabel.isHidden = layout.footer == nil
        if let frame = layout.footer {
            footerLabel.frame = frame
            footerLabel.text = layout.footerText
            footerLabel.textAlignment = data.isMine ? .right : .left
            footerLabel.textColor = data.failed ? .systemRed : .secondaryLabel
        }
    }

    private func configureLink(_ link: LinkPreview, frame: CGRect, layout: RowLayout, mine: Bool) {
        linkCard.isHidden = false
        linkCard.frame = frame
        linkCard.backgroundColor = mine ? UIColor.white.withAlphaComponent(0.18) : UIColor.systemBackground.withAlphaComponent(0.65)
        linkTitleView.isHidden = layout.linkTitle == nil
        linkTitleView.block = layout.linkTitle
        linkTitleView.frame = layout.linkTitleFrame
        linkDetailView.isHidden = layout.linkDetail == nil
        linkDetailView.block = layout.linkDetail
        linkDetailView.frame = layout.linkDetailFrame
        linkSiteView.block = layout.linkSite
        linkSiteView.frame = layout.linkSiteFrame
        linkImageView.isHidden = layout.linkImage == nil
        linkImageView.image = nil
        if let imageFrame = layout.linkImage, let mediaId = link.imageMediaId {
            linkImageView.frame = imageFrame
            if let cached = MediaCache.shared.cachedImage(mediaId, thumb: false, maxPixel: 200) {
                linkImageView.image = cached
            } else {
                loadTasks.append(Task { [weak self] in
                    let image = await MediaCache.shared.image(mediaId, thumb: false, maxPixel: 200)
                    if !Task.isCancelled { self?.linkImageView.image = image }
                })
            }
        }
    }

    private func reactionsText(_ reactions: [Reaction]) -> String {
        var seen: [String] = []
        for reaction in reactions where !seen.contains(reaction.emoji) { seen.append(reaction.emoji) }
        return seen.joined() + (reactions.count > seen.count ? " \(reactions.count)" : "")
    }

    private func configureMedia(_ message: Message, frames: [CGRect], isSticker: Bool) {
        for (index, frame) in frames.enumerated() where index < imageViews.count && index < message.media.count {
            let view = imageViews[index]
            let media = message.media[index]
            view.isHidden = false
            view.frame = frame
            view.backgroundColor = isSticker ? .clear : .secondarySystemFill
            view.contentMode = isSticker ? .scaleAspectFit : .scaleAspectFill
            view.layer.cornerRadius = frames.count > 1 ? 4 : 0
            let pixel = max(frame.width, frame.height) * UIScreen.main.scale
            if let cached = MediaCache.shared.cachedImage(media.id, thumb: !isSticker && media.hasThumb, maxPixel: pixel) {
                view.image = cached
            } else {
                loadTasks.append(Task { [weak view] in
                    let image: UIImage?
                    if isSticker || media.mime == "image/gif" {
                        image = await MediaCache.shared.animatedImage(media.id, maxPixel: pixel)
                    } else if media.kind == "video" {
                        image = media.hasThumb ? await MediaCache.shared.image(media.id, thumb: true, maxPixel: pixel) : await VideoPoster.poster(for: media.id)
                    } else {
                        // 气泡里一律用缩略图（和上面查内存缓存的键一致），原图只在全屏查看时加载
                        image = await MediaCache.shared.image(media.id, thumb: media.hasThumb, maxPixel: pixel)
                    }
                    if !Task.isCancelled { view?.image = image }
                })
            }
            if media.kind == "video", index == 0 {
                playBadge.isHidden = false
                playBadge.frame = CGRect(x: frame.midX - 24, y: frame.midY - 24, width: 48, height: 48)
                durationBadge.isHidden = false
                durationBadge.text = Format.duration(media.durationMs)
                let width = durationBadge.intrinsicContentSize.width
                durationBadge.frame = CGRect(x: frame.maxX - width - 8, y: frame.maxY - 26, width: width, height: 18)
            }
        }
    }

    @objc private func voiceChanged() {
        guard message?.kind == "voice" else { return }
        updateVoice()
    }

    private func updateVoice() {
        guard let message else { return }
        let player = VoicePlayer.shared
        let tint: UIColor = isMine ? .white : Theme.accent
        voiceView.configure(message: message, tint: tint, playing: player.playingId == message.id, loading: player.loadingId == message.id, progress: player.progress)
    }

    @objc private func tapImage(_ gesture: UITapGestureRecognizer) {
        guard let message, let view = gesture.view as? UIImageView, let index = imageViews.firstIndex(of: view) else { return }
        if message.kind == "sticker" {
            delegate?.cellDidTapMedia(message, index: 0, from: view)
        } else {
            delegate?.cellDidTapMedia(message, index: index, from: view)
        }
    }

    @objc private func tapBubble(_ gesture: UITapGestureRecognizer) {
        guard let message else { return }
        let point = gesture.location(in: bubble)
        if let replyFrame = layoutInfo.reply, replyFrame.contains(point) {
            delegate?.cellDidTapReply(message)
            return
        }
        if let linkFrame = layoutInfo.link, linkFrame.contains(point), let link = message.payload.link, let url = URL(string: link.url) {
            delegate?.cellDidTapLink(url)
            return
        }
        switch message.kind {
        case "voice": delegate?.cellDidTapVoice(message)
        case "file": delegate?.cellDidTapFile(message)
        default:
            if let block = layoutInfo.text, let url = block.link(at: gesture.location(in: textView)) {
                delegate?.cellDidTapLink(url)
            }
        }
    }

    @objc private func doubleTapBubble() {
        guard let message else { return }
        delegate?.cellDidDoubleTap(message)
    }

    @objc private func tapFooter() {
        guard let message else { return }
        delegate?.cellDidTapFailed(message)
    }
}

/// 卡牌消息和提醒消息
final class CardCell: UICollectionViewCell, MessageFlashing {
    static let reuseId = "card"
    private let flashBand = MessageFlash.makeOverlay()

    weak var delegate: MessageCellDelegate?
    private var message: Message?
    private let card = UIView()
    private let gradient = CAGradientLayer()
    private let icon = UIImageView()
    private let titleLabel = UILabel()
    private let summaryLabel = UILabel()
    private let noteLabel = UILabel()
    private let statusLabel = UILabel()
    private let acceptButton = UIButton(configuration: .prominentGlass())
    private let declineButton = UIButton(configuration: .glass())
    private let footerLabel = UILabel()
    private let bodyView = TextBlockView()
    private let chevron = UIImageView(image: UIImage(systemName: "chevron.right"))
    private var timer: Timer?

    override init(frame: CGRect) {
        super.init(frame: frame)
        card.layer.cornerRadius = 22
        card.layer.cornerCurve = .continuous
        card.clipsToBounds = true
        card.layer.insertSublayer(gradient, at: 0)
        gradient.startPoint = CGPoint(x: 0, y: 0)
        gradient.endPoint = CGPoint(x: 1, y: 1)
        icon.tintColor = .white
        icon.contentMode = .scaleAspectFit
        icon.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: 26, weight: .semibold)
        titleLabel.font = .systemFont(ofSize: 18, weight: .bold)
        titleLabel.textColor = .white
        summaryLabel.font = .systemFont(ofSize: 14)
        summaryLabel.textColor = UIColor.white.withAlphaComponent(0.92)
        summaryLabel.numberOfLines = 2
        noteLabel.font = .italicSystemFont(ofSize: 13)
        noteLabel.textColor = UIColor.white.withAlphaComponent(0.9)
        statusLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        statusLabel.textColor = .white
        chevron.tintColor = UIColor.white.withAlphaComponent(0.85)
        chevron.contentMode = .scaleAspectFit
        chevron.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: 14, weight: .bold)
        [icon, titleLabel, summaryLabel, noteLabel, statusLabel, bodyView, acceptButton, declineButton, chevron].forEach { card.addSubview($0) }
        contentView.addSubview(card)
        footerLabel.font = .systemFont(ofSize: 11, weight: .medium)
        footerLabel.textColor = .secondaryLabel
        contentView.addSubview(footerLabel)
        acceptButton.configuration?.title = "接受"
        declineButton.configuration?.title = "拒绝"
        acceptButton.addAction(UIAction { [weak self] _ in self?.respond(true) }, for: .touchUpInside)
        declineButton.addAction(UIAction { [weak self] _ in self?.respond(false) }, for: .touchUpInside)
        card.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(tapCard)))
        contentView.insertSubview(flashBand, at: 0)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func prepareForReuse() {
        super.prepareForReuse()
        timer?.invalidate()
        timer = nil
        MessageFlash.stop(flashBand)
        card.layer.removeAnimation(forKey: "pulse")
    }

    func flash(elapsed: CFTimeInterval) {
        MessageFlash.band(flashBand, in: contentView)
        MessageFlash.fade(flashBand, elapsed: elapsed)
        if elapsed < 0.4 { MessageFlash.pulse(card) }
    }

    var snapshotView: UIView { card }

    func configure(_ data: MessageRowData, layout: RowLayout, app: AppModel) {
        message = data.message
        let message = data.message
        card.frame = layout.bubble
        gradient.frame = card.bounds
        card.layer.cornerRadius = 22
        chevron.isHidden = true
        titleLabel.textColor = .white
        acceptButton.isHidden = true
        declineButton.isHidden = true
        noteLabel.isHidden = true
        bodyView.isHidden = true
        summaryLabel.isHidden = false
        acceptButton.configuration?.title = "接受"
        declineButton.configuration?.title = "拒绝"
        timer?.invalidate()
        let width = layout.bubble.width

        if message.kind == "confirm" {
            let payload = message.payload
            gradient.colors = [UIColor(hex: 0xFFB56B).cgColor, UIColor(hex: 0xEE7E3A).cgColor]
            icon.image = UIImage(systemName: "pawprint.fill")
            icon.frame = CGRect(x: 16, y: 14, width: 22, height: 22)
            titleLabel.font = .systemFont(ofSize: 13, weight: .semibold)
            titleLabel.frame = CGRect(x: 44, y: 16, width: width - 60, height: 20)
            titleLabel.text = payload.plan?.kind == "memo" ? "大橘想帮你记个备忘" : "大橘想帮你建个提醒"
            summaryLabel.isHidden = true
            bodyView.isHidden = false
            bodyView.block = layout.text
            let textHeight = layout.text?.size.height ?? 0
            bodyView.frame = CGRect(x: 16, y: 44, width: width - 32, height: textHeight)
            let bottomY = 44 + textHeight + 12
            if payload.status == "pending" {
                statusLabel.text = nil
                acceptButton.isHidden = false
                declineButton.isHidden = false
                acceptButton.configuration?.title = "确认"
                declineButton.configuration?.title = "不用了"
                let buttonWidth = (width - 42) / 2
                declineButton.frame = CGRect(x: 16, y: bottomY, width: buttonWidth, height: 38)
                acceptButton.frame = CGRect(x: 26 + buttonWidth, y: bottomY, width: buttonWidth, height: 38)
            } else {
                statusLabel.frame = CGRect(x: 16, y: bottomY, width: width - 32, height: 20)
                let who = payload.handledBy == app.me?.id ? "你" : app.name(payload.handledBy ?? "")
                statusLabel.text = payload.status == "done" ? "✅ \(who)确认了，已经建好" : "已取消"
            }
        } else if message.kind == "reminder" {
            let height = layout.bubble.height
            card.layer.cornerRadius = height <= 64 ? height / 2 : 24
            gradient.colors = [UIColor(hex: 0xFFB56B).cgColor, UIColor(hex: 0xF0873C).cgColor]
            icon.image = UIImage(systemName: "alarm.fill")
            icon.frame = CGRect(x: 18, y: (height - 28) / 2, width: 28, height: 28)
            titleLabel.font = .systemFont(ofSize: 12, weight: .semibold)
            titleLabel.frame = CGRect(x: RowLayoutEngine.reminderTextInset, y: 10, width: width - RowLayoutEngine.reminderTextInset - 34, height: 16)
            titleLabel.text = "提醒 · \(Format.time.string(from: message.date))"
            titleLabel.textColor = UIColor.white.withAlphaComponent(0.85)
            summaryLabel.isHidden = true
            bodyView.isHidden = false
            bodyView.block = layout.text
            bodyView.frame = layout.textFrame
            chevron.isHidden = false
            chevron.frame = CGRect(x: width - 30, y: (height - 16) / 2, width: 14, height: 16)
            statusLabel.text = nil
        } else {
            let payload = message.payload
            let colors = (Theme.rarityColors[payload.rarity ?? "common"] ?? Theme.rarityColors["common"]!).map { UIColor(hex: $0).cgColor }
            gradient.colors = colors
            icon.image = UIImage(systemName: payload.icon ?? "sparkles")
            icon.frame = CGRect(x: 16, y: 18, width: 34, height: 34)
            titleLabel.font = .systemFont(ofSize: 18, weight: .bold)
            titleLabel.frame = CGRect(x: 60, y: 16, width: width - 76, height: 24)
            titleLabel.text = payload.title
            summaryLabel.font = .systemFont(ofSize: 14)
            summaryLabel.numberOfLines = 2
            summaryLabel.frame = CGRect(x: 60, y: 42, width: width - 76, height: 40)
            summaryLabel.text = "\(Theme.rarityNames[payload.rarity ?? ""] ?? "")·\(payload.summary ?? "")"
            var y: CGFloat = 92
            if !message.text.isEmpty {
                noteLabel.isHidden = false
                noteLabel.frame = CGRect(x: 16, y: y, width: width - 32, height: 18)
                noteLabel.text = "“\(message.text)”"
                y += 22
            }
            statusLabel.frame = CGRect(x: 16, y: y, width: width - 32, height: 20)
            updateStatus(payload: payload, app: app)
            if payload.status == "accepted", let ends = payload.endsAt, ends > Date().timeIntervalSince1970 * 1000 {
                timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
                    Task { @MainActor in self?.updateStatus(payload: payload, app: app) }
                }
            }
            let waitingForMe = payload.status == "pending" && payload.toUser == app.me?.id && !["addTime", "copy", "bounce"].contains(payload.effect ?? "")
            if waitingForMe {
                acceptButton.isHidden = false
                declineButton.isHidden = false
                let buttonWidth = (width - 42) / 2
                declineButton.frame = CGRect(x: 16, y: layout.bubble.height - 50, width: buttonWidth, height: 38)
                acceptButton.frame = CGRect(x: 26 + buttonWidth, y: layout.bubble.height - 50, width: buttonWidth, height: 38)
            }
        }
        footerLabel.isHidden = layout.footer == nil
        if let frame = layout.footer {
            footerLabel.frame = frame
            footerLabel.text = layout.footerText
            footerLabel.textAlignment = data.isMine ? .right : .left
        }
    }

    private func updateStatus(payload: MessagePayload, app: AppModel) {
        let now = Date().timeIntervalSince1970 * 1000
        switch payload.status {
        case "pending":
            let target = payload.toUser == app.me?.id ? "你" : app.name(payload.toUser ?? "")
            statusLabel.text = "⏳ 等待\(target)接受"
        case "accepted":
            if let ends = payload.endsAt, ends > now {
                statusLabel.text = "⏱ 进行中 · 还剩 \(Format.countdown((ends - now) / 1000))"
            } else {
                statusLabel.text = "✅ 已完成"
                timer?.invalidate()
            }
        case "declined": statusLabel.text = "🙅 被拒绝了，卡已退回"
        case "done":
            if payload.effect == "copy" { statusLabel.text = "📋 复制了一张\(payload.copiedTitle ?? "卡")" }
            else if payload.effect == "addTime" { statusLabel.text = "⏱ 加时成功" }
            else if payload.effect == "bounce" { statusLabel.text = "🔄 反弹成功" }
            else { statusLabel.text = "✅ 已完成" }
        default: statusLabel.text = nil
        }
    }

    private func respond(_ accept: Bool) {
        guard let message else { return }
        Haptics.tap()
        if message.kind == "confirm" {
            delegate?.cellDidConfirm(message, accept: accept)
        } else {
            delegate?.cellDidTapCard(message, accept: accept)
        }
    }

    @objc private func tapCard() {
        guard let message, message.kind == "reminder" else { return }
        delegate?.cellDidOpenPlan(message)
    }
}

/// 居中的行：时间分隔、系统提示、互动
final class CenterCell: UICollectionViewCell, MessageFlashing {
    static let reuseId = "center"
    private let flashBand = MessageFlash.makeOverlay()

    weak var delegate: MessageCellDelegate?
    private var message: Message?
    private let label = UILabel()
    private let textView = TextBlockView()
    private let pill = UIView()
    private let emojiLabel = UILabel()

    override init(frame: CGRect) {
        super.init(frame: frame)
        label.font = .systemFont(ofSize: 12, weight: .medium)
        label.textColor = .secondaryLabel
        label.textAlignment = .center
        pill.layer.cornerRadius = 20
        pill.layer.cornerCurve = .continuous
        emojiLabel.font = .systemFont(ofSize: 22)
        emojiLabel.textAlignment = .center
        contentView.addSubview(label)
        contentView.addSubview(pill)
        pill.addSubview(emojiLabel)
        pill.addSubview(textView)
        contentView.addSubview(textView)
        pill.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(tapPill)))
        contentView.insertSubview(flashBand, at: 0)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func prepareForReuse() {
        super.prepareForReuse()
        MessageFlash.stop(flashBand)
    }

    func flash(elapsed: CFTimeInterval) {
        MessageFlash.band(flashBand, in: contentView)
        MessageFlash.fade(flashBand, elapsed: elapsed)
    }

    /// pill：有聊天背景时给时间加一个半透明底，不然看不清
    func configureSeparator(_ text: String, pill onBackground: Bool = false) {
        message = nil
        pill.isHidden = true
        textView.isHidden = true
        label.isHidden = false
        label.text = text
        if onBackground {
            let width = min(contentView.bounds.width - 40, (text as NSString).size(withAttributes: [.font: label.font!]).width + 20)
            label.frame = CGRect(x: (contentView.bounds.width - width) / 2, y: (contentView.bounds.height - 22) / 2, width: width, height: 22)
            label.backgroundColor = UIColor.systemBackground.withAlphaComponent(0.7)
            label.layer.cornerRadius = 11
            label.clipsToBounds = true
        } else {
            label.frame = contentView.bounds.insetBy(dx: 20, dy: 4)
            label.backgroundColor = .clear
            label.layer.cornerRadius = 0
        }
    }

    func configureSystem(_ layout: RowLayout) {
        message = nil
        pill.isHidden = true
        label.isHidden = true
        textView.isHidden = false
        if textView.superview !== contentView { contentView.addSubview(textView) }
        textView.block = layout.text
        textView.frame = layout.textFrame
    }

    func configureInteraction(_ data: MessageRowData, layout: RowLayout) {
        message = data.message
        label.isHidden = true
        pill.isHidden = false
        textView.isHidden = false
        if textView.superview !== pill { pill.addSubview(textView) }
        pill.frame = layout.bubble
        pill.backgroundColor = data.isMine ? Theme.accent.withAlphaComponent(0.14) : Theme.dajuAccent.withAlphaComponent(0.14)
        emojiLabel.frame = CGRect(x: 10, y: (layout.bubble.height - 30) / 2, width: 30, height: 30)
        emojiLabel.text = MessagePreview.interactionEmoji[data.message.payload.interaction ?? ""] ?? "✨"
        textView.block = layout.text
        textView.frame = layout.textFrame
    }

    @objc private func tapPill() {
        guard let message else { return }
        delegate?.cellDidTapInteraction(message)
    }
}

/// 正在输入 / 大橘正在思考：左边带头像，和收到的气泡对齐
final class TypingCell: UICollectionViewCell {
    static let reuseId = "typing"

    private let avatar = AvatarBadgeView(frame: .zero)
    private let bubble = UIView()
    private let label = UILabel()
    private var dots: [UIView] = []

    override init(frame: CGRect) {
        super.init(frame: frame)
        bubble.layer.cornerRadius = 18
        bubble.layer.cornerCurve = .continuous
        label.font = .systemFont(ofSize: 14)
        label.textColor = .secondaryLabel
        contentView.addSubview(avatar)
        contentView.addSubview(bubble)
        bubble.addSubview(label)
        for _ in 0 ..< 3 {
            let dot = UIView()
            dot.backgroundColor = .secondaryLabel
            dot.layer.cornerRadius = 3.5
            bubble.addSubview(dot)
            dots.append(dot)
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    override func prepareForReuse() {
        super.prepareForReuse()
        avatar.reset()
    }

    func configure(text: String?, userId: String?, daju: Bool, app: AppModel) {
        let size = RowLayoutEngine.avatarSize
        avatar.isHidden = userId == nil
        avatar.frame = CGRect(x: RowLayoutEngine.sideInset, y: 6 + 36 - size, width: size, height: size)
        if let userId { avatar.configure(userId: userId, isMine: false, app: app) }
        bubble.backgroundColor = daju ? Theme.dajuBubble : Theme.incomingBubble
        label.text = text
        let textWidth = text.map { ($0 as NSString).size(withAttributes: [.font: label.font!]).width + 10 } ?? 0
        let width = 58 + textWidth
        bubble.frame = CGRect(x: RowLayoutEngine.sideInset + RowLayoutEngine.avatarGutter, y: 6, width: width, height: 36)
        label.frame = CGRect(x: 14, y: 0, width: textWidth, height: 36)
        for (index, dot) in dots.enumerated() {
            dot.frame = CGRect(x: 14 + textWidth + CGFloat(index) * 11, y: 14.5, width: 7, height: 7)
            dot.layer.removeAllAnimations()
            let animation = CABasicAnimation(keyPath: "transform.translation.y")
            animation.fromValue = 0
            animation.toValue = -4
            animation.duration = 0.35
            animation.autoreverses = true
            animation.repeatCount = .infinity
            animation.beginTime = CACurrentMediaTime() + Double(index) * 0.15
            dot.layer.add(animation, forKey: "bounce")
        }
    }
}

final class LoadingCell: UICollectionViewCell {
    static let reuseId = "loading"
    private let spinner = UIActivityIndicatorView(style: .medium)

    override init(frame: CGRect) {
        super.init(frame: frame)
        contentView.addSubview(spinner)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layoutSubviews() {
        super.layoutSubviews()
        spinner.center = CGPoint(x: contentView.bounds.midX, y: contentView.bounds.midY)
        spinner.startAnimating()
    }
}

/// 圆形头像：有头像图片用图片，没有就用名字的第一个字
final class AvatarBadgeView: UIImageView {
    private let initial = UILabel()
    private var loadTask: Task<Void, Never>?
    private var mediaId: String?

    override init(frame: CGRect) {
        super.init(frame: frame)
        contentMode = .scaleAspectFill
        clipsToBounds = true
        initial.font = .systemFont(ofSize: 13, weight: .bold)
        initial.textColor = .white
        initial.textAlignment = .center
        addSubview(initial)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layoutSubviews() {
        super.layoutSubviews()
        layer.cornerRadius = bounds.width / 2
        initial.frame = bounds
    }

    func configure(userId: String, isMine: Bool, app: AppModel) {
        let user = app.user(userId)
        backgroundColor = userId == "daju" ? UIColor(hex: 0xFFB36B) : (isMine ? Theme.accent : UIColor(hex: 0xF29CB8))
        initial.text = String((user?.displayName ?? "?").prefix(1))
        guard let mediaId = user?.avatarMediaId else {
            reset()
            return
        }
        if mediaId == self.mediaId, image != nil { return }
        loadTask?.cancel()
        self.mediaId = mediaId
        let pixel = max(bounds.width, RowLayoutEngine.avatarSize) * UIScreen.main.scale
        if let cached = MediaCache.shared.cachedImage(mediaId, thumb: true, maxPixel: pixel) {
            image = cached
            initial.isHidden = true
            return
        }
        image = nil
        initial.isHidden = false
        loadTask = Task { [weak self] in
            let loaded = await MediaCache.shared.image(mediaId, thumb: true, maxPixel: pixel)
            guard !Task.isCancelled, let self, self.mediaId == mediaId, let loaded else { return }
            self.image = loaded
            self.initial.isHidden = true
        }
    }

    func reset() {
        loadTask?.cancel()
        loadTask = nil
        mediaId = nil
        image = nil
        initial.isHidden = false
    }
}

/// 带内边距的标签（视频时长、表情回应）
final class PaddingLabel: UILabel {
    var insets = UIEdgeInsets(top: 0, left: 6, bottom: 0, right: 6)

    override func drawText(in rect: CGRect) {
        super.drawText(in: rect.inset(by: insets))
    }

    override var intrinsicContentSize: CGSize {
        let size = super.intrinsicContentSize
        return CGSize(width: size.width + insets.left + insets.right, height: size.height + insets.top + insets.bottom)
    }
}
