import Observation
import PhotosUI
import QuickLook
import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// 聊天页（UIKit）：时间线 + 输入栏。
final class ChatViewController: UIViewController {
    let chat: ChatModel
    let app: AppModel

    private let chatLayout = ChatLayout()
    private var collectionView: UICollectionView!
    private let composer = ComposerView()
    private let jumpButton = UIButton(configuration: .glass())
    private let replyIndicator = UIImageView(image: UIImage(systemName: "arrowshape.turn.up.left.circle.fill"))
    /// 聊天背景：渐变（可带平铺小图案）或照片
    private let wallpaperGradient = GradientView()
    private let wallpaperPattern = UIView()
    private let wallpaperImage = UIImageView()
    private let wallpaperDim = UIView()
    private var wallpaper: ChatWallpaper?
    private var rows: [Row] = []
    private var layoutCache: [String: (signature: String, width: CGFloat, layout: RowLayout)] = [:]
    private var lastWidth: CGFloat = 0
    /// 跳转到的那条消息：从什么时候开始闪，cell 重建时接着闪完
    private var highlight: (id: String, start: CFTimeInterval)?
    /// 刚跳转到的消息：之后一小会儿里排版变了（键盘收起、搜索页关掉、往前后翻页）都让它留在屏幕中间；用户一拖就放开
    private var pinned: (id: String, until: CFTimeInterval)?
    /// 是否跟着最新消息走。只在用户自己拖动时改变，程序滚动的中途不会误判成“离开了底部”
    private var stickToBottom = true
    private var lastTypingSent = Date.distantPast
    private var statusTimer: Timer?
    private var lastStatusSignature = ""
    private var swipeCell: UICollectionViewCell?
    private var swipeMessage: Message?
    private var didInitialScroll = false
    /// 输入栏贴在视图底部，离底边多远由键盘位置决定（见 viewWillLayoutSubviews）
    private var composerBottom: NSLayoutConstraint!
    /// 键盘在屏幕上的位置（屏幕坐标），收起时为空
    private var keyboardFrame: CGRect?
    private var pickerPurpose: PickerPurpose = .send
    private var previewURL: URL?

    private enum PickerPurpose { case send, sticker }

    init(chat: ChatModel, app: AppModel) {
        self.chat = chat
        self.app = app
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError() }

    // MARK: - 生命周期

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = Theme.chatBackground
        wallpaperImage.contentMode = .scaleAspectFill
        wallpaperImage.clipsToBounds = true
        for layer in [wallpaperGradient, wallpaperPattern, wallpaperImage, wallpaperDim] {
            layer.frame = view.bounds
            layer.isUserInteractionEnabled = false
            layer.isHidden = true
            view.addSubview(layer)
        }

        collectionView = UICollectionView(frame: view.bounds, collectionViewLayout: chatLayout)
        collectionView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        collectionView.backgroundColor = .clear
        collectionView.alwaysBounceVertical = true
        // 键盘位置靠通知跟踪，交互式收起时拿不到中间位置，所以一拖动就收起
        collectionView.keyboardDismissMode = .onDrag
        // 上下留白全部自己算（按输入栏的实际位置），不让系统再叠加安全区，键盘弹起收起时才不会算错
        collectionView.contentInsetAdjustmentBehavior = .never
        // 顶部完全透明（沉浸），底部用系统的滚动边缘效果衬住输入栏
        collectionView.topEdgeEffect.isHidden = true
        collectionView.bottomEdgeEffect.style = .soft
        collectionView.dataSource = self
        collectionView.delegate = self
        collectionView.register(MessageCell.self, forCellWithReuseIdentifier: MessageCell.reuseId)
        collectionView.register(CardCell.self, forCellWithReuseIdentifier: CardCell.reuseId)
        collectionView.register(CenterCell.self, forCellWithReuseIdentifier: CenterCell.reuseId)
        collectionView.register(TypingCell.self, forCellWithReuseIdentifier: TypingCell.reuseId)
        collectionView.register(LoadingCell.self, forCellWithReuseIdentifier: LoadingCell.reuseId)
        view.addSubview(collectionView)

        composer.translatesAutoresizingMaskIntoConstraints = false
        composer.delegate = self
        composer.hudHost = view
        composer.showsDajuShortcut = chat.conversationId == "couple"
        composer.refreshMenu()
        composer.stickerPanel.update(stickers: app.stickers, groups: app.stickerGroups)
        view.addSubview(composer)
        let bottomEdge = UIScrollEdgeElementContainerInteraction()
        bottomEdge.scrollView = collectionView
        bottomEdge.edge = .bottom
        composer.addInteraction(bottomEdge)
        // 不用 keyboardLayoutGuide：这个页面嵌在 SwiftUI 的标签页和导航里，外层重新排版（比如未读角标变化）时
        // 它会跟丢键盘，输入栏掉到键盘后面、之后也不再跟着键盘动。改成按键盘在屏幕上的实际位置自己算。
        composerBottom = composer.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        NSLayoutConstraint.activate([
            composer.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            composer.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            composerBottom,
        ])
        NotificationCenter.default.addObserver(self, selector: #selector(keyboardWillChange(_:)), name: UIResponder.keyboardWillChangeFrameNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(keyboardWillChange(_:)), name: UIResponder.keyboardWillHideNotification, object: nil)

        jumpButton.configuration?.image = UIImage(systemName: "chevron.down", withConfiguration: UIImage.SymbolConfiguration(pointSize: 15, weight: .bold))
        jumpButton.configuration?.cornerStyle = .capsule
        jumpButton.alpha = 0
        jumpButton.addAction(UIAction { [weak self] _ in
            guard let self else { return }
            Haptics.tap()
            self.stickToBottom = true
            if self.chat.isLive { self.scrollToBottom(animated: true) } else { Task { await self.chat.jumpToLatest() } }
        }, for: .touchUpInside)
        view.addSubview(jumpButton)

        replyIndicator.tintColor = Theme.accent
        replyIndicator.alpha = 0
        replyIndicator.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: 26)
        view.addSubview(replyIndicator)

        let swipe = UIPanGestureRecognizer(target: self, action: #selector(handleSwipe(_:)))
        swipe.delegate = self
        collectionView.addGestureRecognizer(swipe)
        // 点聊天记录的空白处收起键盘（和气泡上的点击同时生效）
        let dismissTap = UITapGestureRecognizer(target: self, action: #selector(dismissKeyboard))
        dismissTap.cancelsTouchesInView = false
        dismissTap.delegate = self
        collectionView.addGestureRecognizer(dismissTap)

        chat.onChange = { [weak self] change in self?.modelChanged(change) }
        composer.text = UserDefaults.standard.string(forKey: "draft.\(chat.conversationId)") ?? ""

        statusTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshStatusRows() }
        }
        applyWallpaper()
        observeWallpaper()
        observeStickers()
        // 深浅色切换时换成对应的那张背景
        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (controller: ChatViewController, _: UITraitCollection) in
            controller.applyWallpaper()
        }
        Task { await chat.ensureLoaded() }
    }

    // MARK: - 聊天背景

    /// 个人设置里的聊天背景（白天、黑夜各一张）变了就重新铺
    private func observeWallpaper() {
        withObservationTracking {
            _ = app.settings.mine["chatWallpaper"]
            _ = app.settings.mine["chatWallpaperDark"]
        } onChange: { [weak self] in
            DispatchQueue.main.async {
                self?.applyWallpaper()
                self?.observeWallpaper()
            }
        }
    }

    private func applyWallpaper() {
        let next = ChatWallpaper.current(app.settings.mine, dark: traitCollection.userInterfaceStyle == .dark)
        let changed = next != wallpaper
        wallpaper = next
        [wallpaperGradient, wallpaperPattern, wallpaperImage, wallpaperDim].forEach { $0.isHidden = true }
        if let next, next.kind == "photo", let mediaId = next.mediaId {
            wallpaperImage.isHidden = false
            wallpaperDim.isHidden = false
            wallpaperDim.backgroundColor = UIColor.black.withAlphaComponent(next.dim)
            let side = max(UIScreen.main.bounds.width, UIScreen.main.bounds.height) * UIScreen.main.scale
            Task { [weak self] in
                let image = await MediaCache.shared.image(mediaId, thumb: false, maxPixel: side)
                self?.wallpaperImage.image = image
            }
        } else if let next, let preset = WallpaperPresets.preset(next.key) {
            wallpaperGradient.isHidden = false
            wallpaperGradient.colors = preset.colors
            if let symbol = preset.pattern {
                wallpaperPattern.isHidden = false
                wallpaperPattern.backgroundColor = WallpaperPresets.patternColor(symbol)
            }
        }
        if changed, lastWidth > 0 { collectionView.reloadData() }
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        UserDefaults.standard.set(composer.text, forKey: "draft.\(chat.conversationId)")
        VoicePlayer.shared.stop()
    }

    deinit {
        statusTimer?.invalidate()
    }

    // MARK: - 键盘

    override func viewWillLayoutSubviews() {
        super.viewWillLayoutSubviews()
        let offset = composerBottomOffset()
        if abs(composerBottom.constant + offset) > 0.5 { composerBottom.constant = -offset }
    }

    /// 输入栏离视图底边的距离：键盘盖住视图的高度，没有键盘时是底部安全区。每次排版都按键盘的屏幕位置重新换算，视图被外层挪动、改尺寸也不会错
    private func composerBottomOffset() -> CGFloat {
        var overlap: CGFloat = 0
        if let keyboardFrame, let screen = view.window?.windowScene?.screen {
            let frame = view.convert(keyboardFrame, from: screen.coordinateSpace)
            overlap = max(0, view.bounds.maxY - frame.minY)
        }
        return max(overlap, view.safeAreaInsets.bottom)
    }

    @objc private func keyboardWillChange(_ notification: Notification) {
        guard let info = notification.userInfo else { return }
        let end = (info[UIResponder.keyboardFrameEndUserInfoKey] as? NSValue)?.cgRectValue ?? .zero
        let screenHeight = view.window?.windowScene?.screen.bounds.height ?? .greatestFiniteMagnitude
        let hidden = notification.name == UIResponder.keyboardWillHideNotification || end.height < 1 || end.minY >= screenHeight
        keyboardFrame = hidden ? nil : end
        guard isViewLoaded, view.window != nil else { return }
        let duration = (info[UIResponder.keyboardAnimationDurationUserInfoKey] as? Double) ?? 0.25
        let curve = (info[UIResponder.keyboardAnimationCurveUserInfoKey] as? Int) ?? 7
        view.setNeedsLayout()
        UIView.animate(withDuration: duration, delay: 0, options: [UIView.AnimationOptions(rawValue: UInt(curve) << 16), .beginFromCurrentState, .allowUserInteraction]) {
            self.view.layoutIfNeeded()
        }
    }

    /// 背景按屏幕铺，不跟着视图尺寸变：外层在键盘弹起时改视图大小，背景也不会跟着缩放晃动
    private func layoutWallpaper() {
        guard let screen = view.window?.windowScene?.screen else { return }
        let frame = view.convert(screen.bounds, from: screen.coordinateSpace)
        for layer in [wallpaperGradient, wallpaperPattern, wallpaperImage, wallpaperDim] where layer.frame != frame {
            layer.frame = frame
        }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        layoutWallpaper()
        // 底部留白 = 输入栏顶边到屏幕底的距离，键盘、输入栏高度、底部安全区都已经算在里面
        let top = view.safeAreaInsets.top + 4
        let bottom = max(0, view.bounds.maxY - composer.frame.minY) + 6
        let old = collectionView.contentInset
        if abs(old.top - top) > 0.5 || abs(old.bottom - bottom) > 0.5 {
            let insets = UIEdgeInsets(top: top, left: 0, bottom: bottom, right: 0)
            collectionView.contentInset = insets
            collectionView.verticalScrollIndicatorInsets = insets
            // 可见高度变了：不满一屏时贴底的位置要重算
            chatLayout.invalidateLayout()
            collectionView.layoutIfNeeded()
            if let target = pinnedTarget {
                // 刚跳转过去：键盘收起、搜索页关掉引起的变化，都让那条消息留在中间
                center(on: target)
            } else if stickToBottom && !collectionView.isTracking {
                scrollToBottom(animated: false)
            } else if abs(old.bottom - bottom) > 0.5 {
                // 键盘弹出、输入栏变高时，内容跟着输入栏一起移动，正在看的那几条不被挡住
                collectionView.contentOffset.y = clampedOffset(collectionView.contentOffset.y + bottom - old.bottom)
            }
        }
        jumpButton.frame = CGRect(x: view.bounds.width - 58, y: composer.frame.minY - 54, width: 44, height: 44)
        if view.bounds.width != lastWidth, view.bounds.width > 0 {
            let firstLayout = lastWidth == 0
            lastWidth = view.bounds.width
            if firstLayout, let anchor = chat.pendingAnchor {
                modelChanged(.reset(anchor: anchor))
            } else {
                rebuild(anchor: stickToBottom ? .keepBottom : .keepAnchor)
            }
            // 会话可能在首页就已经加载好了，不会再收到 reset；第一次排版后就允许翻页
            didInitialScroll = true
        }
    }

    @objc private func dismissKeyboard() {
        guard composer.textView.isFirstResponder else { return }
        composer.textView.resignFirstResponder()
        composer.resetInputView()
    }

    // MARK: - 数据

    private enum ScrollIntent {
        case keepBottom
        case keepAnchor
        case scrollTo(String)
        case bottom(animated: Bool)
    }

    private func modelChanged(_ change: ChatModel.Change) {
        guard lastWidth > 0 else { return }
        switch change {
        case .reset(let anchor):
            chat.pendingAnchor = nil
            if let anchor {
                stickToBottom = false
                let start = CACurrentMediaTime()
                highlight = (anchor, start)
                pinned = (anchor, start + 1.8)
                rebuild(anchor: .scrollTo(anchor))
                DispatchQueue.main.asyncAfter(deadline: .now() + MessageFlash.duration + 0.2) { [weak self] in
                    if self?.highlight?.start == start { self?.highlight = nil }
                }
            } else {
                // 整个窗口换掉了，旧位置和新内容没有关系，直接落到底部
                stickToBottom = true
                pinned = nil
                rebuild(anchor: .bottom(animated: false))
            }
            didInitialScroll = true
        case .prepended, .pageAppended:
            rebuild(anchor: .keepAnchor)
        case .appended:
            let lastIsMine = chat.displayMessages.last?.senderId == app.me?.id
            if lastIsMine {
                stickToBottom = true
                pinned = nil
            }
            rebuild(anchor: stickToBottom ? .bottom(animated: true) : .keepAnchor, animateInsert: true)
        case .updated:
            rebuild(anchor: stickToBottom ? .keepBottom : .keepAnchor)
        }
        if isNearBottom() { chat.markReadIfNeeded() }
    }

    private func refreshStatusRows() {
        let signature = "\(app.isTyping(chat.conversationId))|\(app.dajuActivity[chat.conversationId].map(TimelineBuilder.dajuText) ?? "")"
        guard signature != lastStatusSignature else { return }
        lastStatusSignature = signature
        rebuild(anchor: stickToBottom ? .bottom(animated: true) : .keepAnchor)
    }

    private func buildRows() -> [Row] {
        let width = lastWidth
        return TimelineBuilder.build(chat: chat, app: app).map { row in
            var row = row
            if let cached = layoutCache[row.id], cached.signature == row.signature, cached.width == width {
                row.layout = cached.layout
            } else {
                row.layout = RowLayoutEngine.layout(row, width: width, app: app)
                layoutCache[row.id] = (row.signature, width, row.layout)
            }
            return row
        }
    }

    /// 还在“钉住”时间里的跳转目标
    private var pinnedTarget: String? {
        guard let pinned, CACurrentMediaTime() < pinned.until else { return nil }
        return pinned.id
    }

    /// 把一条消息放在可见区域中间偏上一点
    private func center(on id: String) {
        guard let index = rows.firstIndex(where: { $0.id == id }) else { return }
        chatLayout.prepareIfStale()
        guard let frame = chatLayout.frame(at: index) else { return }
        let inset = collectionView.adjustedContentInset
        let visible = collectionView.bounds.height - inset.top - inset.bottom
        // 用 setContentOffset 顺便停掉还在进行的滚动动画，免得动画把位置又带走
        collectionView.setContentOffset(CGPoint(x: 0, y: clampedOffset(frame.midY - inset.top - visible * 0.42)), animated: false)
    }

    private func rebuild(anchor requested: ScrollIntent, animateInsert: Bool = false) {
        // 刚跳转过去的那条：这期间的翻页、刷新都以它为准，不按屏幕顶上那条保持
        var intent = requested
        if let target = pinnedTarget, case .keepAnchor = requested { intent = .scrollTo(target) }
        let oldIds = rows.map(\.id)
        let oldSignatures = rows.map(\.signature)
        let savedAnchor = firstVisibleAnchor()
        let newRows = buildRows()
        let newIds = newRows.map(\.id)

        // 只在末尾追加时做插入动画。数据源和布局必须在同一批更新里一起换，
        // 否则 UIKit 会发现条数对不上直接崩溃（发消息、收消息都走这里）。
        let appendOnly = animateInsert && !oldIds.isEmpty && newIds.count > oldIds.count && Array(newIds.prefix(oldIds.count)) == oldIds
        if appendOnly, collectionView.numberOfItems(inSection: 0) == oldIds.count {
            let inserted = (oldIds.count ..< newIds.count).map { IndexPath(item: $0, section: 0) }
            // 已有的行排版也可能变了（气泡分组、已读），一起刷新
            let changed = (0 ..< oldIds.count).filter { oldSignatures[$0] != newRows[$0].signature }.map { IndexPath(item: $0, section: 0) }
            chatLayout.appearingIndexes = Set(inserted.map(\.item))
            collectionView.performBatchUpdates {
                rows = newRows
                chatLayout.heights = newRows.map(\.layout.height)
                collectionView.insertItems(at: inserted)
                if !changed.isEmpty { collectionView.reconfigureItems(at: changed) }
            } completion: { [weak self] _ in
                self?.chatLayout.appearingIndexes = []
            }
        } else {
            rows = newRows
            chatLayout.heights = newRows.map(\.layout.height)
            chatLayout.invalidateLayout()
            collectionView.reloadData()
        }
        collectionView.layoutIfNeeded()

        switch intent {
        case .keepBottom, .bottom(animated: false):
            scrollToBottom(animated: false)
        case .bottom(animated: true):
            scrollToBottom(animated: true)
        case .keepAnchor:
            if let savedAnchor, let index = rows.firstIndex(where: { $0.id == savedAnchor.id }), let frame = chatLayout.frame(at: index) {
                collectionView.contentOffset.y = clampedOffset(frame.minY - savedAnchor.offset)
            }
        case .scrollTo(let id):
            center(on: id)
        }
        updateJumpButton()
    }

    private var minOffset: CGFloat { -collectionView.adjustedContentInset.top }

    /// 内容高度用布局自己算的（刚换过整页数据时 collectionView.contentSize 可能还是旧的）
    private var maxOffset: CGFloat {
        max(minOffset, chatLayout.totalHeight + collectionView.adjustedContentInset.bottom - collectionView.bounds.height)
    }

    private func clampedOffset(_ y: CGFloat) -> CGFloat {
        min(maxOffset, max(minOffset, y))
    }

    private func firstVisibleAnchor() -> (id: String, offset: CGFloat)? {
        guard !rows.isEmpty else { return nil }
        let top = collectionView.contentOffset.y + collectionView.adjustedContentInset.top
        let visible = collectionView.indexPathsForVisibleItems.sorted()
        for indexPath in visible where indexPath.item < rows.count {
            guard let frame = chatLayout.frame(at: indexPath.item), frame.maxY > top else { continue }
            if case .loadingOlder = rows[indexPath.item].kind { continue }
            return (rows[indexPath.item].id, frame.minY - collectionView.contentOffset.y)
        }
        return nil
    }

    private func isNearBottom(threshold: CGFloat = 120) -> Bool {
        guard let collectionView else { return true }
        let visibleBottom = collectionView.contentOffset.y + collectionView.bounds.height - collectionView.adjustedContentInset.bottom
        return visibleBottom >= collectionView.contentSize.height - threshold
    }

    func scrollToBottom(animated: Bool) {
        let target = maxOffset
        // 离底部很远时先无动画跳到最后一屏附近再滑过去，不用一路滚过所有历史
        if animated, target - collectionView.contentOffset.y > collectionView.bounds.height * 1.5 {
            collectionView.setContentOffset(CGPoint(x: 0, y: target - collectionView.bounds.height * 0.6), animated: false)
        }
        collectionView.setContentOffset(CGPoint(x: 0, y: target), animated: animated)
    }

    private func updateJumpButton() {
        let show = !isNearBottom(threshold: 400) || chat.hasNewer
        UIView.animate(withDuration: 0.2) { self.jumpButton.alpha = show ? 1 : 0 }
    }

    private func message(at indexPath: IndexPath) -> MessageRowData? {
        guard indexPath.item < rows.count, case .message(let data) = rows[indexPath.item].kind else { return nil }
        return data
    }

    // MARK: - 媒体

    private func allMedia() -> [(message: Message, media: MessageMedia)] {
        chat.messages.filter { ($0.kind == "image" || $0.kind == "video") && !$0.isRecalled }.flatMap { message in message.media.map { (message, $0) } }
    }

    private func openMedia(_ message: Message, index: Int) {
        if message.kind == "sticker" {
            return
        }
        let items = allMedia()
        guard !items.isEmpty, index < message.media.count else { return }
        let target = message.media[index].id
        let start = items.firstIndex { $0.media.id == target } ?? 0
        let viewer = MediaViewerController(items: items.map { MediaViewerItem(media: $0.media, messageId: $0.message.id, senderId: $0.message.senderId, date: $0.message.date) }, startIndex: start, app: app)
        present(viewer, animated: true)
    }

    private func openFile(_ message: Message) {
        guard let media = message.media.first else { return }
        let destination = FileManager.default.temporaryDirectory.appendingPathComponent("files", isDirectory: true).appendingPathComponent(media.name ?? media.id)
        Task {
            do {
                if !FileManager.default.fileExists(atPath: destination.path) {
                    try await app.api.download(app.api.mediaURL(media.id), to: destination)
                }
                previewURL = destination
                let preview = QLPreviewController()
                preview.dataSource = self
                present(preview, animated: true)
            } catch {
                showAlert("文件打不开", error.localizedDescription)
            }
        }
    }

    private func showAlert(_ title: String, _ message: String?) {
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "好", style: .default))
        present(alert, animated: true)
    }

    private func presentSwiftUI<Content: View>(_ content: Content) {
        let host = UIHostingController(rootView: content.environment(app))
        present(host, animated: true)
    }

    // MARK: - 左滑回复

    @objc private func handleSwipe(_ gesture: UIPanGestureRecognizer) {
        let translation = min(0, gesture.translation(in: collectionView).x)
        switch gesture.state {
        case .began:
            let point = gesture.location(in: collectionView)
            guard let indexPath = collectionView.indexPathForItem(at: point), let data = message(at: indexPath), data.message.seq != Int.max else { return }
            swipeCell = collectionView.cellForItem(at: indexPath)
            swipeMessage = data.message
        case .changed:
            guard let cell = swipeCell else { return }
            let offset = max(-80, translation * 0.8)
            cell.contentView.transform = CGAffineTransform(translationX: offset, y: 0)
            let frame = collectionView.convert(cell.frame, to: view)
            replyIndicator.frame = CGRect(x: view.bounds.width - 44, y: frame.midY - 16, width: 32, height: 32)
            let progress = min(1, abs(offset) / 60)
            replyIndicator.alpha = progress
            replyIndicator.transform = CGAffineTransform(scaleX: 0.6 + 0.4 * progress, y: 0.6 + 0.4 * progress)
            if abs(offset) >= 60, replyIndicator.tag == 0 {
                replyIndicator.tag = 1
                Haptics.soft()
            } else if abs(offset) < 60 {
                replyIndicator.tag = 0
            }
        default:
            if let cell = swipeCell {
                if replyIndicator.tag == 1, let message = swipeMessage { startReply(message) }
                UIView.animate(withDuration: 0.3, delay: 0, usingSpringWithDamping: 0.8, initialSpringVelocity: 0) {
                    cell.contentView.transform = .identity
                    self.replyIndicator.alpha = 0
                }
            }
            replyIndicator.tag = 0
            swipeCell = nil
            swipeMessage = nil
        }
    }

    private func startReply(_ message: Message) {
        let name = message.senderId == app.me?.id ? "自己" : app.name(message.senderId)
        composer.setContext(.reply(message, name: name))
    }

    // MARK: - 长按菜单

    private func menu(for data: MessageRowData) -> UIMenu {
        let message = data.message
        var sections: [UIMenuElement] = []
        let isOutgoing = message.seq == Int.max
        if isOutgoing {
            if data.failed {
                sections.append(UIAction(title: "重新发送", image: UIImage(systemName: "arrow.clockwise")) { [weak self] _ in self?.chat.retry(message.id) })
                sections.append(UIAction(title: "删除", image: UIImage(systemName: "trash"), attributes: .destructive) { [weak self] _ in self?.chat.discard(message.id) })
            }
            return UIMenu(children: sections)
        }

        if !["card", "reminder", "interaction"].contains(message.kind) {
            let emojis = ["❤️", "👍", "😂", "😮", "😢", "🔥"]
            let mine = message.reactions.first { $0.userId == app.me?.id }?.emoji
            let palette = UIMenu(options: [.displayInline, .displayAsPalette], children: emojis.map { emoji in
                UIAction(image: Self.emojiImage(emoji), state: mine == emoji ? .on : .off) { [weak self] _ in
                    Haptics.tap()
                    self?.chat.react(message, emoji: mine == emoji ? nil : emoji)
                }
            })
            sections.append(palette)
        }

        var actions: [UIMenuElement] = [
            UIAction(title: "回复", image: UIImage(systemName: "arrowshape.turn.up.left")) { [weak self] _ in self?.startReply(message) },
        ]
        if message.kind == "text" || message.kind == "reminder" {
            actions.append(UIAction(title: "复制", image: UIImage(systemName: "doc.on.doc")) { _ in UIPasteboard.general.string = message.text })
        }
        if message.kind == "voice", let transcript = message.payload.transcript {
            actions.append(UIAction(title: "复制文字", image: UIImage(systemName: "doc.on.doc")) { _ in UIPasteboard.general.string = transcript })
        } else if message.kind == "voice", app.features.transcribe {
            actions.append(UIAction(title: "转文字", image: UIImage(systemName: "text.bubble")) { [weak self] _ in
                Task { await self?.chat.transcribe(message) }
            })
        }
        if message.kind == "image" || message.kind == "sticker" {
            actions.append(stickerMenu(for: message))
        }
        if message.kind == "image" || message.kind == "video" {
            actions.append(UIAction(title: "保存到相册", image: UIImage(systemName: "square.and.arrow.down")) { [weak self] _ in
                guard let self else { return }
                Task { await MediaSaver.save(message.media, api: self.app.api) }
            })
        }
        if chat.conversationId == "couple", message.senderId != "daju" {
            actions.append(UIAction(title: "问大橘", image: UIImage(systemName: "pawprint")) { [weak self] _ in
                guard let self else { return }
                self.startReply(message)
                if !self.composer.text.contains("@大橘") { self.composer.text = "@大橘 " + self.composer.text }
            })
        }
        sections.append(UIMenu(options: .displayInline, children: actions))

        if message.senderId == app.me?.id {
            var own: [UIMenuElement] = []
            let age = Date().timeIntervalSince(message.date)
            if message.kind == "text", age < 15 * 60 {
                own.append(UIAction(title: "编辑", image: UIImage(systemName: "pencil")) { [weak self] _ in self?.composer.setContext(.edit(message)) })
            }
            if age < 2 * 60 {
                own.append(UIAction(title: "撤回", image: UIImage(systemName: "arrow.uturn.backward"), attributes: .destructive) { [weak self] _ in
                    guard let self else { return }
                    Task {
                        do { try await self.chat.recall(message) } catch { self.showAlert("撤回失败", error.localizedDescription) }
                    }
                })
            }
            if !own.isEmpty { sections.append(UIMenu(options: .displayInline, children: own)) }
        }
        let title = Format.fullDateTime.string(from: message.date) + (message.editedAt != nil ? " · 已编辑" : "")
        return UIMenu(title: title, children: sections)
    }

    /// “添加到贴纸”：有分组时直接选放进哪一组
    private func stickerMenu(for message: Message) -> UIMenuElement {
        let add: (String?) -> Void = { [weak self] groupId in
            guard let self, let media = message.media.first else { return }
            Task { await self.addSticker(mediaId: media.id, groupId: groupId) }
        }
        let icon = UIImage(systemName: "face.smiling")
        guard !app.stickerGroups.isEmpty else {
            return UIAction(title: "添加到贴纸", image: icon) { _ in add(nil) }
        }
        let loose = UIAction(title: "不分组", image: UIImage(systemName: "tray")) { _ in add(nil) }
        let groups = app.stickerGroups.map { group in
            UIAction(title: group.title, image: UIImage(systemName: "folder")) { _ in add(group.id) }
        }
        return UIMenu(title: "添加到贴纸", image: icon, children: [loose] + groups)
    }

    private func addSticker(mediaId: String, groupId: String?) async {
        var body: [String: Any] = ["mediaId": mediaId]
        if let groupId { body["groupId"] = groupId }
        guard let state: StickerState = try? await app.api.post("v1/stickers", body) else {
            showAlert("没有加上", "网络不太好，等会儿再试试")
            return
        }
        app.applyStickers(state)
        composer.stickerPanel.update(stickers: app.stickers, groups: app.stickerGroups)
        Haptics.success()
    }

    /// 另一台手机改了贴纸（收到 stickers 事件后重新拉过）：面板跟着更新
    private func observeStickers() {
        withObservationTracking {
            _ = app.stickers
            _ = app.stickerGroups
        } onChange: { [weak self] in
            DispatchQueue.main.async {
                guard let self else { return }
                self.composer.stickerPanel.update(stickers: self.app.stickers, groups: self.app.stickerGroups)
                self.observeStickers()
            }
        }
    }

    static func emojiImage(_ emoji: String) -> UIImage {
        let size = CGSize(width: 32, height: 32)
        return UIGraphicsImageRenderer(size: size).image { _ in
            let text = emoji as NSString
            let attributes: [NSAttributedString.Key: Any] = [.font: UIFont.systemFont(ofSize: 26)]
            let textSize = text.size(withAttributes: attributes)
            text.draw(at: CGPoint(x: (size.width - textSize.width) / 2, y: (size.height - textSize.height) / 2), withAttributes: attributes)
        }.withRenderingMode(.alwaysOriginal)
    }

    private func targetedPreview(for indexPath: IndexPath) -> UITargetedPreview? {
        guard let cell = collectionView.cellForItem(at: indexPath), let data = message(at: indexPath) else { return nil }
        let parameters = UIPreviewParameters()
        parameters.backgroundColor = .clear
        let view: UIView
        if let messageCell = cell as? MessageCell {
            view = messageCell.bubbleSnapshotView
            parameters.visiblePath = BubbleShape.path(view.bounds, isMine: data.isMine, position: data.position)
        } else if let cardCell = cell as? CardCell {
            view = cardCell.snapshotView
            parameters.visiblePath = UIBezierPath(roundedRect: view.bounds, cornerRadius: 22)
        } else {
            return nil
        }
        return UITargetedPreview(view: view, parameters: parameters)
    }
}

// MARK: - 列表

extension ChatViewController: UICollectionViewDataSource, UICollectionViewDelegate {
    func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int {
        rows.count
    }

    func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
        let row = rows[indexPath.item]
        switch row.kind {
        case .separator(let text):
            let cell = collectionView.dequeueReusableCell(withReuseIdentifier: CenterCell.reuseId, for: indexPath) as! CenterCell
            cell.configureSeparator(text, pill: wallpaper != nil)
            return cell
        case .system:
            let cell = collectionView.dequeueReusableCell(withReuseIdentifier: CenterCell.reuseId, for: indexPath) as! CenterCell
            cell.configureSystem(row.layout)
            return cell
        case .loadingOlder:
            return collectionView.dequeueReusableCell(withReuseIdentifier: LoadingCell.reuseId, for: indexPath)
        case .typing(let userId):
            let cell = collectionView.dequeueReusableCell(withReuseIdentifier: TypingCell.reuseId, for: indexPath) as! TypingCell
            cell.configure(text: nil, userId: userId, daju: false, app: app)
            return cell
        case .dajuStatus(let text):
            let cell = collectionView.dequeueReusableCell(withReuseIdentifier: TypingCell.reuseId, for: indexPath) as! TypingCell
            cell.configure(text: text, userId: "daju", daju: true, app: app)
            return cell
        case .message(let data):
            if data.message.kind == "interaction" {
                let cell = collectionView.dequeueReusableCell(withReuseIdentifier: CenterCell.reuseId, for: indexPath) as! CenterCell
                cell.delegate = self
                cell.configureInteraction(data, layout: row.layout)
                return cell
            }
            if ["card", "reminder", "confirm"].contains(data.message.kind) {
                let cell = collectionView.dequeueReusableCell(withReuseIdentifier: CardCell.reuseId, for: indexPath) as! CardCell
                cell.delegate = self
                cell.configure(data, layout: row.layout, app: app)
                return cell
            }
            let cell = collectionView.dequeueReusableCell(withReuseIdentifier: MessageCell.reuseId, for: indexPath) as! MessageCell
            cell.delegate = self
            cell.configure(data, layout: row.layout, app: app)
            return cell
        }
    }

    func collectionView(_ collectionView: UICollectionView, willDisplay cell: UICollectionViewCell, forItemAt indexPath: IndexPath) {
        guard let highlight, indexPath.item < rows.count, rows[indexPath.item].id == highlight.id else { return }
        (cell as? MessageFlashing)?.flash(elapsed: CACurrentMediaTime() - highlight.start)
    }

    func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
        // 用户自己开始拖了，就不再把跳转的目标钉在中间
        pinned = nil
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        // 只有用户自己拖动时才更新“是否跟着最新消息”
        if scrollView.isTracking || scrollView.isDragging || scrollView.isDecelerating {
            stickToBottom = isNearBottom(threshold: 60) && !chat.hasNewer
        }
        guard didInitialScroll else { return }
        // 提前两三屏开始加载，滑到头之前历史已经接上
        let preload = max(1200, scrollView.bounds.height * 2)
        let top = scrollView.contentOffset.y + scrollView.adjustedContentInset.top
        if top < preload, chat.hasOlder, !chat.isLoadingOlder {
            Task { await chat.loadOlder() }
        }
        if isNearBottom(threshold: preload), chat.hasNewer, !chat.isLoadingNewer {
            Task { await chat.loadNewer() }
        }
        if isNearBottom() { chat.markReadIfNeeded() }
        updateJumpButton()
    }

    func collectionView(_ collectionView: UICollectionView, contextMenuConfigurationForItemsAt indexPaths: [IndexPath], point: CGPoint) -> UIContextMenuConfiguration? {
        guard let indexPath = indexPaths.first, let data = message(at: indexPath) else { return nil }
        if data.message.seq == Int.max && !data.failed { return nil }
        composer.textView.resignFirstResponder()
        return UIContextMenuConfiguration(identifier: indexPath as NSIndexPath, previewProvider: nil) { [weak self] _ in
            self?.menu(for: data)
        }
    }

    func collectionView(_ collectionView: UICollectionView, contextMenuConfiguration configuration: UIContextMenuConfiguration, highlightPreviewForItemAt indexPath: IndexPath) -> UITargetedPreview? {
        targetedPreview(for: indexPath)
    }

    func collectionView(_ collectionView: UICollectionView, contextMenuConfiguration configuration: UIContextMenuConfiguration, dismissalPreviewForItemAt indexPath: IndexPath) -> UITargetedPreview? {
        targetedPreview(for: indexPath)
    }
}

extension ChatViewController: UIGestureRecognizerDelegate {
    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard let pan = gestureRecognizer as? UIPanGestureRecognizer, pan.view === collectionView else { return true }
        let velocity = pan.velocity(in: collectionView)
        return velocity.x < -80 && abs(velocity.x) > abs(velocity.y) * 1.6
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        gestureRecognizer is UITapGestureRecognizer
    }
}

// MARK: - 气泡点击

extension ChatViewController: MessageCellDelegate {
    func cellDidTapMedia(_ message: Message, index: Int, from view: UIView) {
        openMedia(message, index: index)
    }

    func cellDidTapVoice(_ message: Message) {
        VoicePlayer.shared.toggle(message)
    }

    func cellDidTapFile(_ message: Message) {
        openFile(message)
    }

    func cellDidTapReply(_ message: Message) {
        guard let target = message.replyTo?.id else { return }
        Haptics.selection()
        Task { await chat.jump(to: target) }
    }

    func cellDidTapLink(_ url: URL) {
        UIApplication.shared.open(url)
    }

    func cellDidTapFailed(_ message: Message) {
        guard chat.outgoingState(message.id)?.failed == true else { return }
        chat.retry(message.id)
    }

    func cellDidTapCard(_ message: Message, accept: Bool) {
        guard let playId = message.payload.playId else { return }
        Task {
            do {
                _ = try await app.api.send("POST", "v1/cards/plays/\(playId)/respond", body: ["accept": accept])
                if accept { Haptics.success() }
            } catch {
                showAlert("操作失败", error.localizedDescription)
            }
        }
    }

    func cellDidConfirm(_ message: Message, accept: Bool) {
        Task {
            do {
                struct Response: Decodable { let message: Message }
                let response: Response = try await app.api.post("v1/messages/\(message.id)/confirm", ["accept": accept])
                chat.upsert(response.message)
                if accept { Haptics.success() }
            } catch {
                showAlert("没有成功", error.localizedDescription)
            }
        }
    }

    /// 聊天里的提醒卡片：打开计划页，定位到这条提醒
    func cellDidOpenPlan(_ message: Message) {
        Haptics.tap()
        presentSwiftUI(NavigationStack { PlansView(model: UsModel(), initialKind: "reminder", focusPlanId: message.payload.planId) })
    }

    func cellDidTapInteraction(_ message: Message) {
        guard let interaction = message.payload.interaction else { return }
        app.interactionEffect = InteractionEffectRequest(interaction: interaction, fromMe: message.senderId == app.me?.id)
    }

    func cellDidDoubleTap(_ message: Message) {
        guard message.seq != Int.max, !["card", "reminder"].contains(message.kind) else { return }
        Haptics.tap()
        chat.toggleHeart(message)
    }
}

// MARK: - 输入栏

extension ChatViewController: ComposerDelegate {
    func composerSend(text: String) {
        var replyTo: Message?
        if case .reply(let message, _) = composer.context { replyTo = message }
        chat.sendText(text, replyTo: replyTo)
        composer.setContext(nil)
        UserDefaults.standard.removeObject(forKey: "draft.\(chat.conversationId)")
    }

    func composerSaveEdit(_ message: Message, text: String) {
        Task {
            do { try await chat.edit(message, text: text) } catch { showAlert("编辑失败", error.localizedDescription) }
        }
    }

    func composerTextChanged() {
        guard !composer.text.isEmpty, Date().timeIntervalSince(lastTypingSent) > 3, chat.conversationId == "couple" else { return }
        lastTypingSent = Date()
        app.sendTyping(chat.conversationId)
    }

    func composerPickPhotos() {
        pickerPurpose = .send
        var configuration = PHPickerConfiguration()
        configuration.filter = .any(of: [.images, .videos])
        configuration.selectionLimit = 9
        configuration.preferredAssetRepresentationMode = .compatible
        let picker = PHPickerViewController(configuration: configuration)
        picker.delegate = self
        present(picker, animated: true)
    }

    func composerTakePhoto() {
        guard UIImagePickerController.isSourceTypeAvailable(.camera) else { return }
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.mediaTypes = [UTType.image.identifier, UTType.movie.identifier]
        picker.videoQuality = .typeHigh
        picker.delegate = self
        present(picker, animated: true)
    }

    func composerPickFile() {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.item], asCopy: true)
        picker.delegate = self
        present(picker, animated: true)
    }

    func composerSendInteraction(_ interaction: String) {
        Haptics.success()
        chat.sendInteraction(interaction)
    }

    func composerSendNote() {
        let alert = UIAlertController(title: "举个牌子", message: "写一句想对 TA 说的话（30 字以内）", preferredStyle: .alert)
        alert.addTextField { $0.placeholder = "比如：今天也很想你" }
        alert.addAction(UIAlertAction(title: "取消", style: .cancel))
        alert.addAction(UIAlertAction(title: "举起来", style: .default) { [weak self, weak alert] _ in
            let note = alert?.textFields?.first?.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !note.isEmpty else { return }
            self?.chat.sendInteraction("note", note: String(note.prefix(30)))
        })
        present(alert, animated: true)
    }

    func composerOpenCards() {
        presentSwiftUI(NavigationStack { CardsView() })
    }

    func composerSendSticker(_ sticker: Sticker) {
        chat.sendSticker(sticker)
    }

    func composerAddSticker() {
        pickerPurpose = .sticker
        var configuration = PHPickerConfiguration()
        configuration.filter = .images
        configuration.selectionLimit = 9
        let picker = PHPickerViewController(configuration: configuration)
        picker.delegate = self
        present(picker, animated: true)
    }

    func composerDeleteSticker(_ sticker: Sticker) {
        Task {
            if let data = try? await app.api.send("DELETE", "v1/stickers/\(sticker.id)"), let state = try? JSONDecoder().decode(StickerState.self, from: data) {
                app.applyStickers(state)
            } else {
                await app.reloadStickers()
            }
            composer.stickerPanel.update(stickers: app.stickers, groups: app.stickerGroups)
        }
    }

    func composerManageStickers() {
        composer.textView.resignFirstResponder()
        composer.resetInputView()
        presentSwiftUI(NavigationStack { StickerManagerView() })
    }

    func composerVoiceRecorded(url: URL, durationMs: Int, waveform: [Double]) {
        chat.sendMedia([MediaPrep.voice(url: url, durationMs: durationMs)], kind: "voice", waveform: waveform)
    }

    func composerContextCleared() {}

    func composerLayoutChanged() {
        UIView.animate(withDuration: 0.2) {
            self.view.layoutIfNeeded()
        }
    }

    private func sendPrepared(_ items: [PreparedMedia]) {
        let images = items.filter { $0.meta.kind == "image" }
        let videos = items.filter { $0.meta.kind == "video" }
        if !images.isEmpty { chat.sendMedia(Array(images.prefix(9)), kind: "image") }
        for video in videos { chat.sendMedia([video], kind: "video") }
    }

    /// 从相册加的贴纸放进面板上正在看的那个分组
    private func uploadStickers(_ items: [PreparedMedia]) {
        let groupId = composer.stickerPanel.selectedGroupId
        Task {
            for item in items {
                if let media = try? await app.api.upload(meta: item.meta, file: item.fileURL, filename: item.filename, thumb: item.thumbnail) {
                    if let data = try? Data(contentsOf: item.fileURL) { MediaCache.shared.store(data, id: media.id, thumb: false) }
                    var body: [String: Any] = ["mediaId": media.id]
                    if let groupId { body["groupId"] = groupId }
                    _ = try? await app.api.send("POST", "v1/stickers", body: body)
                }
                try? FileManager.default.removeItem(at: item.fileURL)
            }
            await app.reloadStickers()
            composer.stickerPanel.update(stickers: app.stickers, groups: app.stickerGroups)
            Haptics.success()
        }
    }
}

extension ChatViewController: PHPickerViewControllerDelegate, UIImagePickerControllerDelegate, UINavigationControllerDelegate, UIDocumentPickerDelegate {
    func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
        picker.dismiss(animated: true)
        guard !results.isEmpty else { return }
        let purpose = pickerPurpose
        Task {
            let prepared = await MediaPrep.load(results)
            if purpose == .sticker { uploadStickers(prepared) } else { sendPrepared(prepared) }
        }
    }

    func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
        picker.dismiss(animated: true)
        if let image = info[.originalImage] as? UIImage, let prepared = MediaPrep.photo(image) {
            chat.sendMedia([prepared], kind: "image")
        } else if let url = info[.mediaURL] as? URL {
            Task {
                if let prepared = await MediaPrep.video(url) { chat.sendMedia([prepared], kind: "video") }
            }
        }
    }

    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        for url in urls {
            if let prepared = MediaPrep.file(url) { chat.sendMedia([prepared], kind: "file") }
        }
    }
}

extension ChatViewController: QLPreviewControllerDataSource {
    func numberOfPreviewItems(in controller: QLPreviewController) -> Int {
        previewURL == nil ? 0 : 1
    }

    func previewController(_ controller: QLPreviewController, previewItemAt index: Int) -> QLPreviewItem {
        (previewURL ?? URL(fileURLWithPath: "/")) as NSURL
    }
}

/// 竖直渐变，颜色跟着深浅色走
final class GradientView: UIView {
    override class var layerClass: AnyClass { CAGradientLayer.self }

    var colors: [UIColor] = [] {
        didSet { updateColors() }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (view: GradientView, _: UITraitCollection) in
            view.updateColors()
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    private func updateColors() {
        (layer as? CAGradientLayer)?.colors = colors.map { $0.resolvedColor(with: traitCollection).cgColor }
    }
}
