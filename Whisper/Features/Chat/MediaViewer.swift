import AVKit
import Photos
import UIKit

struct MediaViewerItem {
    let media: MessageMedia
    let messageId: String
    let senderId: String
    let date: Date
}

/// 保存图片、视频到相册
@MainActor
enum MediaSaver {
    static func save(_ media: [MessageMedia], api: APIClient) async {
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else { return }
        for item in media {
            if item.kind == "video" {
                let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(item.id).mp4")
                guard (try? await api.download(api.mediaURL(item.id), to: url)) != nil else { continue }
                try? await PHPhotoLibrary.shared().performChanges {
                    PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: url)
                }
                try? FileManager.default.removeItem(at: url)
            } else if let data = await MediaCache.shared.data(item.id, thumb: false) {
                try? await PHPhotoLibrary.shared().performChanges {
                    PHAssetCreationRequest.forAsset().addResource(with: .photo, data: data, options: nil)
                }
            }
        }
        Haptics.success()
    }
}

/// 全屏看图、看视频：左右翻页，双击或捏合缩放，下拉关闭
final class MediaViewerController: UIViewController, UIPageViewControllerDataSource, UIPageViewControllerDelegate {
    private let items: [MediaViewerItem]
    private var index: Int
    private let app: AppModel
    private let pages = UIPageViewController(transitionStyle: .scroll, navigationOrientation: .horizontal, options: [.interPageSpacing: 16])
    private let topBar = UIView()
    private let infoLabel = UILabel()
    private let closeButton = UIButton(configuration: .glass())
    private let moreButton = UIButton(configuration: .glass())
    private var chromeHidden = false

    init(items: [MediaViewerItem], startIndex: Int, app: AppModel) {
        self.items = items
        self.index = min(max(0, startIndex), max(0, items.count - 1))
        self.app = app
        super.init(nibName: nil, bundle: nil)
        modalPresentationStyle = .overFullScreen
        modalTransitionStyle = .crossDissolve
    }

    required init?(coder: NSCoder) { fatalError() }

    override var prefersStatusBarHidden: Bool { chromeHidden }
    override var prefersHomeIndicatorAutoHidden: Bool { true }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        pages.dataSource = self
        pages.delegate = self
        addChild(pages)
        pages.view.frame = view.bounds
        pages.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(pages.view)
        pages.didMove(toParent: self)
        if let first = page(at: index) { pages.setViewControllers([first], direction: .forward, animated: false) }

        closeButton.configuration?.image = UIImage(systemName: "xmark")
        closeButton.configuration?.cornerStyle = .capsule
        closeButton.addAction(UIAction { [weak self] _ in self?.dismiss(animated: true) }, for: .touchUpInside)
        moreButton.configuration?.image = UIImage(systemName: "ellipsis")
        moreButton.configuration?.cornerStyle = .capsule
        moreButton.showsMenuAsPrimaryAction = true
        moreButton.menu = UIMenu(children: [
            UIAction(title: "保存到相册", image: UIImage(systemName: "square.and.arrow.down")) { [weak self] _ in
                guard let self else { return }
                let item = self.items[self.index]
                Task { await MediaSaver.save([item.media], api: self.app.api) }
            },
            UIAction(title: "分享", image: UIImage(systemName: "square.and.arrow.up")) { [weak self] _ in self?.share() },
        ])
        infoLabel.textColor = .white
        infoLabel.font = .systemFont(ofSize: 13, weight: .medium)
        infoLabel.textAlignment = .center
        infoLabel.numberOfLines = 2
        [topBar, closeButton, moreButton, infoLabel].forEach { view.addSubview($0) }
        updateInfo()

        let tap = UITapGestureRecognizer(target: self, action: #selector(toggleChrome))
        view.addGestureRecognizer(tap)
        let pan = UIPanGestureRecognizer(target: self, action: #selector(handleDismissPan(_:)))
        pan.delegate = self
        view.addGestureRecognizer(pan)
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let top = view.safeAreaInsets.top
        closeButton.frame = CGRect(x: 16, y: top + 8, width: 44, height: 44)
        moreButton.frame = CGRect(x: view.bounds.width - 60, y: top + 8, width: 44, height: 44)
        infoLabel.frame = CGRect(x: 70, y: top + 8, width: view.bounds.width - 140, height: 44)
    }

    private func updateInfo() {
        guard index < items.count else { return }
        let item = items[index]
        let who = item.senderId == app.me?.id ? "我" : app.name(item.senderId)
        infoLabel.text = "\(who) · \(Format.fullDateTime.string(from: item.date))\n\(index + 1) / \(items.count)"
    }

    private func page(at index: Int) -> UIViewController? {
        guard index >= 0, index < items.count else { return nil }
        let item = items[index]
        if item.media.kind == "video" {
            let controller = VideoPageController(media: item.media, api: app.api)
            controller.chromeHidden = chromeHidden
            controller.view.tag = index
            return controller
        }
        let controller = ZoomImageController(media: item.media)
        controller.view.tag = index
        return controller
    }

    func pageViewController(_ pageViewController: UIPageViewController, viewControllerBefore viewController: UIViewController) -> UIViewController? {
        page(at: viewController.view.tag - 1)
    }

    func pageViewController(_ pageViewController: UIPageViewController, viewControllerAfter viewController: UIViewController) -> UIViewController? {
        page(at: viewController.view.tag + 1)
    }

    func pageViewController(_ pageViewController: UIPageViewController, didFinishAnimating finished: Bool, previousViewControllers: [UIViewController], transitionCompleted completed: Bool) {
        guard completed, let current = pageViewController.viewControllers?.first else { return }
        index = current.view.tag
        updateInfo()
        for previous in previousViewControllers { (previous as? VideoPageController)?.pause() }
    }

    @objc private func toggleChrome() {
        chromeHidden.toggle()
        for page in pages.viewControllers ?? [] { (page as? VideoPageController)?.chromeHidden = chromeHidden }
        UIView.animate(withDuration: 0.2) {
            [self.closeButton, self.moreButton, self.infoLabel].forEach { $0.alpha = self.chromeHidden ? 0 : 1 }
            self.setNeedsStatusBarAppearanceUpdate()
        }
    }

    private func share() {
        let item = items[index]
        Task {
            var activity: [Any] = []
            if item.media.kind == "video" {
                let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(item.media.id).mp4")
                if (try? await app.api.download(app.api.mediaURL(item.media.id), to: url)) != nil { activity.append(url) }
            } else if let data = await MediaCache.shared.data(item.media.id, thumb: false), let image = UIImage(data: data) {
                activity.append(image)
            }
            guard !activity.isEmpty else { return }
            let controller = UIActivityViewController(activityItems: activity, applicationActivities: nil)
            controller.popoverPresentationController?.sourceView = moreButton
            present(controller, animated: true)
        }
    }

    @objc private func handleDismissPan(_ gesture: UIPanGestureRecognizer) {
        let translation = gesture.translation(in: view)
        let progress = min(1, max(0, translation.y / 300))
        switch gesture.state {
        case .changed:
            pages.view.transform = CGAffineTransform(translationX: translation.x * 0.3, y: max(0, translation.y)).scaledBy(x: 1 - progress * 0.2, y: 1 - progress * 0.2)
            view.backgroundColor = UIColor.black.withAlphaComponent(1 - progress)
        case .ended, .cancelled:
            if translation.y > 120 || gesture.velocity(in: view).y > 800 {
                dismiss(animated: true)
            } else {
                UIView.animate(withDuration: 0.3, delay: 0, usingSpringWithDamping: 0.85, initialSpringVelocity: 0) {
                    self.pages.view.transform = .identity
                    self.view.backgroundColor = .black
                }
            }
        default:
            break
        }
    }
}

extension MediaViewerController: UIGestureRecognizerDelegate {
    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard let pan = gestureRecognizer as? UIPanGestureRecognizer else { return true }
        let velocity = pan.velocity(in: view)
        if let zoom = pages.viewControllers?.first as? ZoomImageController, zoom.isZoomed { return false }
        return velocity.y > 0 && abs(velocity.y) > abs(velocity.x)
    }
}

/// 一张可以缩放的图片
final class ZoomImageController: UIViewController, UIScrollViewDelegate {
    private let media: MessageMedia
    private let scrollView = UIScrollView()
    private let imageView = UIImageView()
    private let spinner = UIActivityIndicatorView(style: .large)

    var isZoomed: Bool { scrollView.zoomScale > 1.01 }

    init(media: MessageMedia) {
        self.media = media
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        // 翻页时相邻两页并排，每页都要裁掉自己范围外的内容
        view.backgroundColor = .black
        view.clipsToBounds = true
        scrollView.delegate = self
        scrollView.maximumZoomScale = 4
        scrollView.showsVerticalScrollIndicator = false
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.contentInsetAdjustmentBehavior = .never
        imageView.contentMode = .scaleAspectFit
        scrollView.addSubview(imageView)
        view.addSubview(scrollView)
        spinner.color = .white
        view.addSubview(spinner)
        let doubleTap = UITapGestureRecognizer(target: self, action: #selector(doubleTapped(_:)))
        doubleTap.numberOfTapsRequired = 2
        scrollView.addGestureRecognizer(doubleTap)
        let pixel = max(UIScreen.main.bounds.width, UIScreen.main.bounds.height) * UIScreen.main.scale
        if let preview = MediaCache.shared.cachedImage(media.id, thumb: media.hasThumb, maxPixel: 600) { imageView.image = preview }
        spinner.startAnimating()
        Task {
            let image = media.mime == "image/gif" ? await MediaCache.shared.animatedImage(media.id, maxPixel: pixel) : await MediaCache.shared.image(media.id, thumb: false, maxPixel: pixel * 1.5)
            spinner.stopAnimating()
            if let image { imageView.image = image }
            view.setNeedsLayout()
        }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        scrollView.frame = view.bounds
        spinner.center = CGPoint(x: view.bounds.midX, y: view.bounds.midY)
        if scrollView.zoomScale == 1 {
            imageView.frame = scrollView.bounds
            scrollView.contentSize = scrollView.bounds.size
        }
    }

    func viewForZooming(in scrollView: UIScrollView) -> UIView? { imageView }

    @objc private func doubleTapped(_ gesture: UITapGestureRecognizer) {
        if isZoomed {
            scrollView.setZoomScale(1, animated: true)
        } else {
            let point = gesture.location(in: imageView)
            let size = CGSize(width: scrollView.bounds.width / 2.5, height: scrollView.bounds.height / 2.5)
            scrollView.zoom(to: CGRect(x: point.x - size.width / 2, y: point.y - size.height / 2, width: size.width, height: size.height), animated: true)
        }
    }
}

/// 视频页：自己画控制条（播放/暂停、进度、时间），不用系统播放器那套，免得和上面的关闭、更多按钮叠在一起。
/// 先显示封面，缓冲时转圈；缓冲出两三秒就开播，不等系统攒够；自己发的视频在缓存里，直接放本地文件。
final class VideoPageController: UIViewController {
    private let media: MessageMedia
    private let api: APIClient
    private let player = AVPlayer()
    private let playerView = PlayerView()
    private let posterView = UIImageView()
    private let spinner = UIActivityIndicatorView(style: .large)
    private let centerPlay = UIButton(type: .system)
    private let controls = UIVisualEffectView(effect: UIGlassEffect())
    private let playButton = UIButton(type: .system)
    private let slider = UISlider()
    private let timeLabel = UILabel()
    private var timeObserver: Any?
    private var observations: [NSKeyValueObservation] = []
    private var endObserver: NSObjectProtocol?
    /// 用户想让它播着（暂停、播完、翻走时为 false）
    private var wantsToPlay = false
    private var scrubbing = false
    private var resumeAfterScrub = false
    private var seeking = false
    private var pendingSeek: Double?

    var chromeHidden = false {
        didSet { if isViewLoaded { applyChrome(animated: true) } }
    }

    init(media: MessageMedia, api: APIClient) {
        self.media = media
        self.api = api
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError() }

    deinit {
        if let timeObserver { player.removeTimeObserver(timeObserver) }
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        view.clipsToBounds = true
        playerView.playerLayer.player = player
        playerView.playerLayer.videoGravity = .resizeAspect
        posterView.contentMode = .scaleAspectFit
        spinner.color = .white
        spinner.hidesWhenStopped = true
        centerPlay.setImage(UIImage(systemName: "play.circle.fill", withConfiguration: UIImage.SymbolConfiguration(pointSize: 64, weight: .regular)), for: .normal)
        centerPlay.tintColor = UIColor.white.withAlphaComponent(0.9)
        centerPlay.addAction(UIAction { [weak self] _ in self?.togglePlay() }, for: .touchUpInside)
        [playerView, posterView, spinner, centerPlay].forEach { view.addSubview($0) }

        controls.layer.cornerRadius = 24
        controls.layer.cornerCurve = .continuous
        controls.clipsToBounds = true
        playButton.tintColor = .white
        playButton.addAction(UIAction { [weak self] _ in self?.togglePlay() }, for: .touchUpInside)
        slider.minimumTrackTintColor = .white
        slider.maximumTrackTintColor = UIColor.white.withAlphaComponent(0.3)
        slider.setThumbImage(Self.thumbImage, for: .normal)
        slider.addTarget(self, action: #selector(scrubBegan), for: .touchDown)
        slider.addTarget(self, action: #selector(scrubChanged), for: .valueChanged)
        slider.addTarget(self, action: #selector(scrubEnded), for: [.touchUpInside, .touchUpOutside, .touchCancel])
        timeLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        timeLabel.textColor = .white
        timeLabel.textAlignment = .right
        [playButton, slider, timeLabel].forEach { controls.contentView.addSubview($0) }
        view.addSubview(controls)

        loadPoster()
        let local = MediaCache.shared.fileURL(media.id, thumb: false)
        // 缓存里的文件没有扩展名，要告诉 AVFoundation 它是什么格式
        let asset = FileManager.default.fileExists(atPath: local.path)
            ? AVURLAsset(url: local, options: [AVURLAssetOverrideMIMETypeKey: media.mime])
            : AVURLAsset(url: api.playableURL(media.id))
        let item = AVPlayerItem(asset: asset)
        player.replaceCurrentItem(with: item)
        observe(item)
        updateTime()
        updateButtons()
        applyChrome(animated: false)
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        playerView.frame = view.bounds
        posterView.frame = view.bounds
        spinner.center = CGPoint(x: view.bounds.midX, y: view.bounds.midY)
        centerPlay.frame = CGRect(x: view.bounds.midX - 44, y: view.bounds.midY - 44, width: 88, height: 88)
        let width = view.bounds.width - 32
        controls.frame = CGRect(x: 16, y: view.bounds.height - view.safeAreaInsets.bottom - 64, width: width, height: 48)
        playButton.frame = CGRect(x: 6, y: 4, width: 40, height: 40)
        timeLabel.frame = CGRect(x: width - 104, y: 0, width: 90, height: 48)
        slider.frame = CGRect(x: 52, y: 0, width: width - 52 - 112, height: 48)
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        try? AVAudioSession.sharedInstance().setCategory(.playback)
        play()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        pause()
    }

    func pause() {
        wantsToPlay = false
        player.pause()
        updateButtons()
    }

    private func play() {
        wantsToPlay = true
        if let item = player.currentItem, item.duration.isNumeric, item.currentTime() >= item.duration - CMTime(seconds: 0.2, preferredTimescale: 600) {
            player.seek(to: .zero)
        }
        player.play()
        startIfBuffered()
        updateButtons()
    }

    @objc private func togglePlay() {
        Haptics.tap()
        if wantsToPlay { pause() } else { play() }
    }

    // MARK: 状态

    private func observe(_ item: AVPlayerItem) {
        observations = [
            player.observe(\.timeControlStatus, options: [.new]) { [weak self] _, _ in
                DispatchQueue.main.async { self?.updateButtons() }
            },
            playerView.playerLayer.observe(\.isReadyForDisplay, options: [.new]) { [weak self] layer, _ in
                let ready = layer.isReadyForDisplay
                DispatchQueue.main.async {
                    guard let self, ready else { return }
                    UIView.animate(withDuration: 0.2) { self.posterView.alpha = 0 }
                }
            },
            item.observe(\.loadedTimeRanges, options: [.new]) { [weak self] _, _ in
                DispatchQueue.main.async { self?.startIfBuffered() }
            },
            item.observe(\.status, options: [.new]) { [weak self] item, _ in
                let failed = item.status == .failed
                DispatchQueue.main.async {
                    guard let self else { return }
                    if failed {
                        self.spinner.stopAnimating()
                        self.timeLabel.text = "播放失败"
                    }
                    self.updateTime()
                }
            },
        ]
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.25, preferredTimescale: 600), queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateTime() }
        }
        endObserver = NotificationCenter.default.addObserver(forName: AVPlayerItem.didPlayToEndTimeNotification, object: item, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.wantsToPlay = false
                self.player.pause()
                self.player.seek(to: .zero)
                self.updateButtons()
            }
        }
    }

    /// 系统为了不卡顿会攒很久的缓冲再播；这里缓冲出两三秒就先播起来，卡住了再转圈等
    private func startIfBuffered() {
        guard wantsToPlay, !scrubbing, player.timeControlStatus == .waitingToPlayAtSpecifiedRate,
              player.reasonForWaitingToPlay == .toMinimizeStalls, let item = player.currentItem else { return }
        let now = item.currentTime()
        let buffered = item.loadedTimeRanges.map(\.timeRangeValue).first { $0.containsTime(now) }
        let ahead = buffered.map { CMTimeGetSeconds(CMTimeRangeGetEnd($0)) - CMTimeGetSeconds(now) } ?? 0
        let left = item.duration.isNumeric ? CMTimeGetSeconds(item.duration) - CMTimeGetSeconds(now) : .infinity
        if ahead >= min(2.5, max(0.3, left - 0.2)) {
            player.playImmediately(atRate: 1)
        }
    }

    private func updateButtons() {
        let waiting = wantsToPlay && player.timeControlStatus == .waitingToPlayAtSpecifiedRate
        if waiting { spinner.startAnimating() } else { spinner.stopAnimating() }
        let symbol = wantsToPlay ? "pause.fill" : "play.fill"
        playButton.setImage(UIImage(systemName: symbol, withConfiguration: UIImage.SymbolConfiguration(pointSize: 18, weight: .bold)), for: .normal)
        UIView.animate(withDuration: 0.15) {
            self.centerPlay.alpha = self.wantsToPlay || self.scrubbing ? 0 : 1
        }
    }

    private func updateTime() {
        guard let item = player.currentItem else { return }
        let duration = item.duration.isNumeric ? CMTimeGetSeconds(item.duration) : Double(media.durationMs ?? 0) / 1000
        let current = scrubbing ? Double(slider.value) : CMTimeGetSeconds(item.currentTime())
        if duration > 0 {
            slider.maximumValue = Float(duration)
            if !scrubbing { slider.value = Float(current) }
        }
        timeLabel.text = "\(Self.clock(current)) / \(Self.clock(duration))"
    }

    private static func clock(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0:00" }
        let total = Int(seconds.rounded(.down))
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    // MARK: 拖进度

    @objc private func scrubBegan() {
        scrubbing = true
        resumeAfterScrub = wantsToPlay
        player.pause()
        updateButtons()
    }

    @objc private func scrubChanged() {
        seek(to: Double(slider.value), precise: false)
        updateTime()
    }

    @objc private func scrubEnded() {
        seek(to: Double(slider.value), precise: true)
        scrubbing = false
        if resumeAfterScrub { play() } else { updateButtons() }
    }

    /// 拖动时上一次跳转还没完成就只记下最新的位置，完成后再跳，避免堆积
    private func seek(to seconds: Double, precise: Bool) {
        if seeking && !precise {
            pendingSeek = seconds
            return
        }
        seeking = true
        let tolerance = precise ? CMTime.zero : CMTime(seconds: 0.4, preferredTimescale: 600)
        player.seek(to: CMTime(seconds: seconds, preferredTimescale: 600), toleranceBefore: tolerance, toleranceAfter: tolerance) { [weak self] _ in
            DispatchQueue.main.async {
                guard let self else { return }
                self.seeking = false
                if let next = self.pendingSeek {
                    self.pendingSeek = nil
                    self.seek(to: next, precise: !self.scrubbing)
                }
            }
        }
    }

    // MARK: 界面

    private func applyChrome(animated: Bool) {
        let changes = { self.controls.alpha = self.chromeHidden ? 0 : 1 }
        if animated { UIView.animate(withDuration: 0.2, animations: changes) } else { changes() }
    }

    private func loadPoster() {
        if media.hasThumb {
            posterView.image = MediaCache.shared.cachedImage(media.id, thumb: true, maxPixel: 800)
            Task { [weak self] in
                guard let self else { return }
                let image = await MediaCache.shared.image(self.media.id, thumb: true, maxPixel: 800)
                if self.posterView.image == nil { self.posterView.image = image }
            }
        } else {
            Task { [weak self] in
                guard let self else { return }
                let image = await VideoPoster.poster(for: self.media.id)
                if self.posterView.image == nil { self.posterView.image = image }
            }
        }
    }

    private static let thumbImage: UIImage = {
        let size = CGSize(width: 14, height: 14)
        return UIGraphicsImageRenderer(size: size).image { context in
            UIColor.white.setFill()
            context.cgContext.fillEllipse(in: CGRect(origin: .zero, size: size))
        }
    }()
}

/// 只放一个 AVPlayerLayer 的视图
final class PlayerView: UIView {
    override class var layerClass: AnyClass { AVPlayerLayer.self }

    var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
}
