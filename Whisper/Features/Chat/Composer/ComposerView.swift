import UIKit

@MainActor
protocol ComposerDelegate: AnyObject {
    func composerSend(text: String)
    func composerSaveEdit(_ message: Message, text: String)
    func composerTextChanged()
    func composerPickPhotos()
    func composerTakePhoto()
    func composerPickFile()
    func composerSendInteraction(_ interaction: String)
    func composerSendNote()
    func composerOpenCards()
    func composerSendSticker(_ sticker: Sticker)
    func composerAddSticker()
    func composerDeleteSticker(_ sticker: Sticker)
    func composerVoiceRecorded(url: URL, durationMs: Int, waveform: [Double])
    func composerContextCleared()
    func composerLayoutChanged()
}

/// 底部输入栏
final class ComposerView: UIView, UITextViewDelegate {
    enum Context {
        case reply(Message, name: String)
        case edit(Message)
    }

    weak var delegate: ComposerDelegate?
    weak var hudHost: UIView?
    let textView = UITextView()
    private let placeholder = UILabel()
    private let inputBackground = UIVisualEffectView(effect: UIGlassEffect())
    private let plusButton = UIButton(configuration: .glass())
    private let stickerButton = UIButton(type: .system)
    private let actionButton = UIButton(configuration: .prominentGlass())
    private let contextBar = UIVisualEffectView(effect: UIGlassEffect())
    private let contextIcon = UIImageView()
    private let contextTitle = UILabel()
    private let contextText = UILabel()
    private let contextClose = UIButton(type: .system)
    private var textHeight: NSLayoutConstraint!
    private var contextHeight: NSLayoutConstraint!
    private let recorder = VoiceRecorder()
    private var recordingHUD: RecordingHUD?
    private var recordingCancelled = false
    let stickerPanel = StickerPanelView()
    private(set) var context: Context?
    var showsDajuShortcut = true

    override init(frame: CGRect) {
        super.init(frame: frame)
        setup()
    }

    required init?(coder: NSCoder) { fatalError() }

    private func setup() {
        textView.font = RichText.bodyFont
        textView.backgroundColor = .clear
        textView.textContainerInset = UIEdgeInsets(top: 9, left: 4, bottom: 9, right: 4)
        textView.delegate = self
        textView.isScrollEnabled = false
        textView.returnKeyType = .default
        placeholder.text = "发消息…"
        placeholder.font = RichText.bodyFont
        placeholder.textColor = .placeholderText

        inputBackground.layer.cornerRadius = 20
        inputBackground.layer.cornerCurve = .continuous
        inputBackground.clipsToBounds = true
        inputBackground.contentView.addSubview(textView)
        inputBackground.contentView.addSubview(placeholder)
        inputBackground.contentView.addSubview(stickerButton)

        plusButton.configuration?.image = UIImage(systemName: "plus", withConfiguration: UIImage.SymbolConfiguration(pointSize: 17, weight: .semibold))
        plusButton.configuration?.cornerStyle = .capsule
        plusButton.showsMenuAsPrimaryAction = true
        plusButton.menu = attachmentMenu()

        stickerButton.setImage(UIImage(systemName: "face.smiling", withConfiguration: UIImage.SymbolConfiguration(pointSize: 20, weight: .regular)), for: .normal)
        stickerButton.tintColor = .secondaryLabel
        stickerButton.addAction(UIAction { [weak self] _ in self?.toggleStickers() }, for: .touchUpInside)

        actionButton.configuration?.cornerStyle = .capsule
        actionButton.tintColor = Theme.accent
        actionButton.addAction(UIAction { [weak self] _ in self?.actionTapped() }, for: .touchUpInside)
        let press = UILongPressGestureRecognizer(target: self, action: #selector(recordGesture(_:)))
        press.minimumPressDuration = 0.18
        actionButton.addGestureRecognizer(press)

        contextBar.layer.cornerRadius = 16
        contextBar.layer.cornerCurve = .continuous
        contextBar.clipsToBounds = true
        contextBar.isHidden = true
        contextIcon.tintColor = Theme.accent
        contextIcon.contentMode = .scaleAspectFit
        contextTitle.font = .systemFont(ofSize: 13, weight: .semibold)
        contextTitle.textColor = Theme.accent
        contextText.font = .systemFont(ofSize: 13)
        contextText.textColor = .secondaryLabel
        contextClose.setImage(UIImage(systemName: "xmark.circle.fill"), for: .normal)
        contextClose.tintColor = .tertiaryLabel
        contextClose.addAction(UIAction { [weak self] _ in self?.clearContext(notify: true) }, for: .touchUpInside)
        [contextIcon, contextTitle, contextText, contextClose].forEach { contextBar.contentView.addSubview($0) }

        [contextBar, plusButton, inputBackground, actionButton].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            addSubview($0)
        }
        [textView, placeholder, stickerButton, contextIcon, contextTitle, contextText, contextClose].forEach { $0.translatesAutoresizingMaskIntoConstraints = false }

        textHeight = textView.heightAnchor.constraint(equalToConstant: 40)
        contextHeight = contextBar.heightAnchor.constraint(equalToConstant: 0)
        NSLayoutConstraint.activate([
            contextBar.topAnchor.constraint(equalTo: topAnchor),
            contextBar.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            contextBar.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            contextHeight,

            plusButton.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            plusButton.bottomAnchor.constraint(equalTo: inputBackground.bottomAnchor),
            plusButton.widthAnchor.constraint(equalToConstant: 40),
            plusButton.heightAnchor.constraint(equalToConstant: 40),

            inputBackground.topAnchor.constraint(equalTo: contextBar.bottomAnchor, constant: 6),
            inputBackground.leadingAnchor.constraint(equalTo: plusButton.trailingAnchor, constant: 8),
            inputBackground.trailingAnchor.constraint(equalTo: actionButton.leadingAnchor, constant: -8),
            inputBackground.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),

            actionButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            actionButton.bottomAnchor.constraint(equalTo: inputBackground.bottomAnchor),
            actionButton.widthAnchor.constraint(equalToConstant: 40),
            actionButton.heightAnchor.constraint(equalToConstant: 40),

            textView.topAnchor.constraint(equalTo: inputBackground.contentView.topAnchor),
            textView.bottomAnchor.constraint(equalTo: inputBackground.contentView.bottomAnchor),
            textView.leadingAnchor.constraint(equalTo: inputBackground.contentView.leadingAnchor, constant: 8),
            textView.trailingAnchor.constraint(equalTo: stickerButton.leadingAnchor),
            textHeight,

            placeholder.leadingAnchor.constraint(equalTo: textView.leadingAnchor, constant: 9),
            placeholder.centerYAnchor.constraint(equalTo: textView.centerYAnchor),

            stickerButton.trailingAnchor.constraint(equalTo: inputBackground.contentView.trailingAnchor, constant: -6),
            stickerButton.bottomAnchor.constraint(equalTo: inputBackground.contentView.bottomAnchor, constant: -4),
            stickerButton.widthAnchor.constraint(equalToConstant: 32),
            stickerButton.heightAnchor.constraint(equalToConstant: 32),

            contextIcon.leadingAnchor.constraint(equalTo: contextBar.contentView.leadingAnchor, constant: 12),
            contextIcon.centerYAnchor.constraint(equalTo: contextBar.contentView.centerYAnchor),
            contextIcon.widthAnchor.constraint(equalToConstant: 18),
            contextTitle.leadingAnchor.constraint(equalTo: contextIcon.trailingAnchor, constant: 10),
            contextTitle.topAnchor.constraint(equalTo: contextBar.contentView.topAnchor, constant: 6),
            contextTitle.trailingAnchor.constraint(equalTo: contextClose.leadingAnchor, constant: -8),
            contextText.leadingAnchor.constraint(equalTo: contextTitle.leadingAnchor),
            contextText.topAnchor.constraint(equalTo: contextTitle.bottomAnchor, constant: 1),
            contextText.trailingAnchor.constraint(equalTo: contextTitle.trailingAnchor),
            contextClose.trailingAnchor.constraint(equalTo: contextBar.contentView.trailingAnchor, constant: -8),
            contextClose.centerYAnchor.constraint(equalTo: contextBar.contentView.centerYAnchor),
            contextClose.widthAnchor.constraint(equalToConstant: 28),
            contextClose.heightAnchor.constraint(equalToConstant: 28),
        ])
        stickerPanel.onSelect = { [weak self] sticker in self?.delegate?.composerSendSticker(sticker) }
        stickerPanel.onAdd = { [weak self] in self?.delegate?.composerAddSticker() }
        stickerPanel.onDelete = { [weak self] sticker in self?.delegate?.composerDeleteSticker(sticker) }
        updateAction()
    }

    private func attachmentMenu() -> UIMenu {
        // 五个全屏互动，和聊天首页一致；“举个牌子”是带一句话的
        let interactions: [(String, String, String)] = [
            ("miss", "想你了", "heart.fill"), ("hug", "抱抱", "figure.2.arms.open"), ("kiss", "亲亲", "mouth.fill"),
            ("pat", "拍一拍", "hand.wave.fill"), ("flower", "送花", "camera.macro"),
        ]
        let interactionMenu = UIMenu(title: "互动", image: UIImage(systemName: "sparkles"), children: interactions.map { key, title, icon in
            UIAction(title: title, image: UIImage(systemName: icon)) { [weak self] _ in self?.delegate?.composerSendInteraction(key) }
        } + [UIAction(title: "举个牌子…", image: UIImage(systemName: "signpost.right.fill")) { [weak self] _ in self?.delegate?.composerSendNote() }])
        var children: [UIMenuElement] = [
            UIAction(title: "照片和视频", image: UIImage(systemName: "photo.on.rectangle")) { [weak self] _ in self?.delegate?.composerPickPhotos() },
            UIAction(title: "拍摄", image: UIImage(systemName: "camera")) { [weak self] _ in self?.delegate?.composerTakePhoto() },
            UIAction(title: "文件", image: UIImage(systemName: "doc")) { [weak self] _ in self?.delegate?.composerPickFile() },
            interactionMenu,
            UIAction(title: "卡牌", image: UIImage(systemName: "suit.heart.fill")) { [weak self] _ in self?.delegate?.composerOpenCards() },
        ]
        if showsDajuShortcut {
            children.append(UIAction(title: "问大橘", image: UIImage(systemName: "pawprint.fill")) { [weak self] _ in self?.insertMention() })
        }
        return UIMenu(children: children)
    }

    func refreshMenu() {
        plusButton.menu = attachmentMenu()
    }

    private func insertMention() {
        if !textView.text.contains("@大橘") {
            textView.text = "@大橘 " + textView.text
        }
        textView.becomeFirstResponder()
        textViewDidChange(textView)
    }

    // MARK: - 文字

    var text: String {
        get { textView.text ?? "" }
        set {
            textView.text = newValue
            textViewDidChange(textView)
        }
    }

    func textViewDidChange(_ textView: UITextView) {
        placeholder.isHidden = !textView.text.isEmpty
        updateHeight()
        updateAction()
        delegate?.composerTextChanged()
    }

    private func updateHeight() {
        let width = max(40, textView.bounds.width)
        let fitting = textView.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude)).height
        let height = min(max(40, fitting), 140)
        textView.isScrollEnabled = fitting > 140
        if abs(textHeight.constant - height) > 0.5 {
            textHeight.constant = height
            delegate?.composerLayoutChanged()
        }
    }

    private var hasText: Bool { !(textView.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    private func updateAction() {
        let symbol: String
        if case .edit = context {
            symbol = "checkmark"
        } else {
            symbol = hasText ? "arrow.up" : "mic.fill"
        }
        actionButton.configuration?.image = UIImage(systemName: symbol, withConfiguration: UIImage.SymbolConfiguration(pointSize: 16, weight: .bold))
        actionButton.configuration = hasText || isEditingMessage ? .prominentGlass() : .glass()
        actionButton.configuration?.image = UIImage(systemName: symbol, withConfiguration: UIImage.SymbolConfiguration(pointSize: 16, weight: .bold))
        actionButton.configuration?.cornerStyle = .capsule
        actionButton.tintColor = hasText || isEditingMessage ? Theme.accent : .label
    }

    private var isEditingMessage: Bool {
        if case .edit = context { return true }
        return false
    }

    private func actionTapped() {
        if case .edit(let message) = context {
            let value = textView.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty else { return }
            delegate?.composerSaveEdit(message, text: value)
            clearContext(notify: false)
            text = ""
            return
        }
        if hasText {
            Haptics.tap()
            delegate?.composerSend(text: textView.text)
            text = ""
        } else {
            showHint("按住说话")
        }
    }

    // MARK: - 回复、编辑

    func setContext(_ context: Context?) {
        self.context = context
        switch context {
        case .reply(let message, let name):
            contextIcon.image = UIImage(systemName: "arrowshape.turn.up.left.fill")
            contextTitle.text = "回复 \(name)"
            contextText.text = MessagePreview.text(message, app: nil)
            showContextBar(true)
            textView.becomeFirstResponder()
        case .edit(let message):
            contextIcon.image = UIImage(systemName: "pencil")
            contextTitle.text = "编辑消息"
            contextText.text = message.text
            text = message.text
            showContextBar(true)
            textView.becomeFirstResponder()
        case nil:
            showContextBar(false)
        }
        updateAction()
    }

    private func clearContext(notify: Bool) {
        if case .edit = context { text = "" }
        context = nil
        showContextBar(false)
        updateAction()
        if notify { delegate?.composerContextCleared() }
    }

    private func showContextBar(_ visible: Bool) {
        contextBar.isHidden = !visible
        contextHeight.constant = visible ? 46 : 0
        delegate?.composerLayoutChanged()
    }

    // MARK: - 贴纸

    private func toggleStickers() {
        Haptics.selection()
        if textView.inputView == nil {
            stickerPanel.frame = CGRect(x: 0, y: 0, width: bounds.width, height: 300)
            textView.inputView = stickerPanel
            stickerButton.setImage(UIImage(systemName: "keyboard", withConfiguration: UIImage.SymbolConfiguration(pointSize: 18)), for: .normal)
        } else {
            textView.inputView = nil
            stickerButton.setImage(UIImage(systemName: "face.smiling", withConfiguration: UIImage.SymbolConfiguration(pointSize: 20)), for: .normal)
        }
        textView.reloadInputViews()
        if !textView.isFirstResponder { textView.becomeFirstResponder() }
    }

    func resetInputView() {
        guard textView.inputView != nil else { return }
        textView.inputView = nil
        stickerButton.setImage(UIImage(systemName: "face.smiling", withConfiguration: UIImage.SymbolConfiguration(pointSize: 20)), for: .normal)
        textView.reloadInputViews()
    }

    // MARK: - 录音

    @objc private func recordGesture(_ gesture: UILongPressGestureRecognizer) {
        guard !hasText, !isEditingMessage else { return }
        let host = hudHost ?? superview
        switch gesture.state {
        case .began:
            Task { @MainActor in
                guard await VoiceRecorder.requestPermission() else {
                    showHint("请在设置里允许使用麦克风")
                    return
                }
                guard gesture.state == .began || gesture.state == .changed else { return }
                do {
                    try recorder.start()
                } catch {
                    showHint("录音失败")
                    return
                }
                Haptics.rigid()
                recordingCancelled = false
                let hud = RecordingHUD()
                if let host {
                    hud.frame = host.bounds
                    host.addSubview(hud)
                }
                recordingHUD = hud
                recorder.onLevel = { [weak hud] level, duration in hud?.update(level: level, duration: duration) }
            }
        case .changed:
            let location = gesture.location(in: self)
            recordingCancelled = location.y < -70
            recordingHUD?.setCancelling(recordingCancelled)
        case .ended, .cancelled, .failed:
            recordingHUD?.removeFromSuperview()
            recordingHUD = nil
            if recordingCancelled || gesture.state != .ended {
                recorder.cancel()
            } else if let result = recorder.finish() {
                Haptics.tap()
                delegate?.composerVoiceRecorded(url: result.url, durationMs: result.durationMs, waveform: result.waveform)
            } else {
                showHint("说话时间太短")
            }
        default:
            break
        }
    }

    private func showHint(_ text: String) {
        guard let host = hudHost ?? superview else { return }
        let label = PaddingLabel()
        label.insets = UIEdgeInsets(top: 8, left: 14, bottom: 8, right: 14)
        label.text = text
        label.font = .systemFont(ofSize: 14, weight: .medium)
        label.textColor = .white
        label.backgroundColor = UIColor.black.withAlphaComponent(0.7)
        label.layer.cornerRadius = 16
        label.clipsToBounds = true
        let size = label.intrinsicContentSize
        label.frame = CGRect(x: (host.bounds.width - size.width) / 2, y: host.convert(bounds, from: self).minY - size.height - 16, width: size.width, height: size.height)
        host.addSubview(label)
        UIView.animate(withDuration: 0.3, delay: 1.2, options: []) { label.alpha = 0 } completion: { _ in label.removeFromSuperview() }
    }
}

/// 录音时屏幕中间的提示
final class RecordingHUD: UIView {
    private let panel = UIVisualEffectView(effect: UIGlassEffect())
    private let icon = UIImageView(image: UIImage(systemName: "mic.fill"))
    private let ring = CAShapeLayer()
    private let timeLabel = UILabel()
    private let hint = UILabel()

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        panel.layer.cornerRadius = 28
        panel.layer.cornerCurve = .continuous
        panel.clipsToBounds = true
        addSubview(panel)
        icon.tintColor = Theme.accent
        icon.contentMode = .scaleAspectFit
        icon.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: 34, weight: .semibold)
        ring.fillColor = Theme.accent.withAlphaComponent(0.18).cgColor
        panel.contentView.layer.addSublayer(ring)
        panel.contentView.addSubview(icon)
        timeLabel.font = .monospacedDigitSystemFont(ofSize: 17, weight: .semibold)
        timeLabel.textAlignment = .center
        timeLabel.text = "0:00"
        hint.font = .systemFont(ofSize: 13)
        hint.textAlignment = .center
        hint.textColor = .secondaryLabel
        hint.text = "松开发送，上滑取消"
        panel.contentView.addSubview(timeLabel)
        panel.contentView.addSubview(hint)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layoutSubviews() {
        super.layoutSubviews()
        panel.frame = CGRect(x: (bounds.width - 180) / 2, y: bounds.height * 0.32, width: 180, height: 180)
        icon.frame = CGRect(x: 60, y: 30, width: 60, height: 60)
        timeLabel.frame = CGRect(x: 0, y: 108, width: 180, height: 22)
        hint.frame = CGRect(x: 0, y: 136, width: 180, height: 20)
        update(level: 0, duration: 0)
    }

    func update(level: Double, duration: TimeInterval) {
        let radius = 30 + CGFloat(level) * 26
        ring.path = UIBezierPath(ovalIn: CGRect(x: 90 - radius, y: 60 - radius, width: radius * 2, height: radius * 2)).cgPath
        timeLabel.text = Format.duration(Int(duration * 1000))
    }

    func setCancelling(_ cancelling: Bool) {
        icon.image = UIImage(systemName: cancelling ? "xmark.circle.fill" : "mic.fill")
        icon.tintColor = cancelling ? .systemRed : Theme.accent
        hint.text = cancelling ? "松开手指，取消发送" : "松开发送，上滑取消"
        hint.textColor = cancelling ? .systemRed : .secondaryLabel
    }
}
