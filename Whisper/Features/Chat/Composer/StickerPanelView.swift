import UIKit

/// 贴纸面板，替换键盘显示，和系统键盘一样高、一样的底色（UIInputView 的键盘样式），切换时输入栏不跳。
/// 顶上一排是分组（全部、自己建的分组、未分组），右边是添加和管理；下面整块都是贴纸，一直铺到屏幕底。
final class StickerPanelView: UIInputView, UICollectionViewDataSource, UICollectionViewDelegate {
    private(set) var stickers: [Sticker] = []
    private(set) var groups: [StickerGroup] = []
    /// 正在看哪一组：nil 是全部，"" 是未分组，其余是分组 id
    private var selection: String?
    private var visible: [Sticker] = []

    /// 新加的贴纸放进哪个分组（看“全部”和“未分组”时为空）
    var selectedGroupId: String? {
        guard let selection, !selection.isEmpty else { return nil }
        return selection
    }

    var onSelect: ((Sticker) -> Void)?
    var onAdd: (() -> Void)?
    var onDelete: ((Sticker) -> Void)?
    var onManage: (() -> Void)?

    private let collectionView: UICollectionView
    private let emptyView = UIStackView()
    private let tabScroll = UIScrollView()
    private let tabStack = UIStackView()
    private let addButton = UIButton(type: .system)
    private let manageButton = UIButton(type: .system)
    private let actionDivider = UIView()
    private let divider = UIView()
    private static let selectionKey = "stickerPanel.selection"
    private static let barHeight: CGFloat = 46

    init(width: CGFloat) {
        let layout = UICollectionViewFlowLayout()
        layout.minimumInteritemSpacing = 6
        layout.minimumLineSpacing = 6
        layout.sectionInset = UIEdgeInsets(top: 10, left: 10, bottom: 10, right: 10)
        collectionView = UICollectionView(frame: .zero, collectionViewLayout: layout)
        super.init(frame: CGRect(x: 0, y: 0, width: width, height: 336), inputViewStyle: .keyboard)
        allowsSelfSizing = false
        selection = UserDefaults.standard.string(forKey: Self.selectionKey)

        collectionView.backgroundColor = .clear
        collectionView.alwaysBounceVertical = true
        collectionView.showsVerticalScrollIndicator = false
        collectionView.contentInsetAdjustmentBehavior = .never
        collectionView.dataSource = self
        collectionView.delegate = self
        collectionView.register(StickerCell.self, forCellWithReuseIdentifier: "sticker")
        addSubview(collectionView)

        let emptyIcon = UIImageView(image: UIImage(systemName: "face.smiling", withConfiguration: UIImage.SymbolConfiguration(pointSize: 30, weight: .light)))
        emptyIcon.tintColor = .tertiaryLabel
        let emptyLabel = UILabel()
        emptyLabel.text = "这一组还没有贴纸\n点右上角 + 从相册加，或者在聊天里长按图片“添加到贴纸”"
        emptyLabel.font = .systemFont(ofSize: 13)
        emptyLabel.textColor = .secondaryLabel
        emptyLabel.numberOfLines = 0
        emptyLabel.textAlignment = .center
        emptyView.axis = .vertical
        emptyView.alignment = .center
        emptyView.spacing = 10
        emptyView.addArrangedSubview(emptyIcon)
        emptyView.addArrangedSubview(emptyLabel)
        emptyView.isHidden = true
        addSubview(emptyView)

        tabScroll.showsHorizontalScrollIndicator = false
        tabScroll.alwaysBounceHorizontal = true
        tabStack.axis = .horizontal
        tabStack.spacing = 4
        tabStack.alignment = .center
        tabScroll.addSubview(tabStack)
        addSubview(tabScroll)

        configureBarButton(addButton, symbol: "plus", label: "从相册添加贴纸") { [weak self] in self?.onAdd?() }
        configureBarButton(manageButton, symbol: "slider.horizontal.3", label: "管理贴纸") { [weak self] in self?.onManage?() }
        actionDivider.backgroundColor = .separator
        divider.backgroundColor = .separator
        [addButton, manageButton, actionDivider, divider].forEach(addSubview)
        rebuildTabs()
    }

    required init?(coder: NSCoder) { fatalError() }

    private func configureBarButton(_ button: UIButton, symbol: String, label: String, action: @escaping () -> Void) {
        button.setImage(UIImage(systemName: symbol, withConfiguration: UIImage.SymbolConfiguration(pointSize: 17, weight: .semibold)), for: .normal)
        button.tintColor = .label
        button.accessibilityLabel = label
        button.addAction(UIAction { _ in
            Haptics.tap()
            action()
        }, for: .touchUpInside)
    }

    func update(stickers: [Sticker], groups: [StickerGroup]) {
        self.stickers = stickers
        self.groups = groups.sorted { $0.position < $1.position }
        // 正在看的分组被删掉了：回到全部
        if let selection, !selection.isEmpty, !self.groups.contains(where: { $0.id == selection }) { self.selection = nil }
        rebuildTabs()
        reloadVisible()
    }

    private func reloadVisible() {
        switch selection {
        case .none: visible = stickers
        case .some(""): visible = stickers.filter { $0.groupId == nil }
        case .some(let id): visible = stickers.filter { $0.groupId == id }
        }
        emptyView.isHidden = !visible.isEmpty
        collectionView.reloadData()
    }

    /// 顶上的分组：全部、各个分组，有没分组的贴纸时再加一个“未分组”
    private func rebuildTabs() {
        tabStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        var tabs: [(title: String, value: String?)] = [(title: "全部", value: nil)]
        for group in groups { tabs.append((title: group.title, value: group.id)) }
        if !groups.isEmpty, stickers.contains(where: { $0.groupId == nil }) || selection == "" { tabs.append((title: "未分组", value: "")) }
        for tab in tabs {
            let selected = tab.value == selection
            var configuration = UIButton.Configuration.plain()
            configuration.title = tab.title
            configuration.cornerStyle = .capsule
            configuration.contentInsets = NSDirectionalEdgeInsets(top: 6, leading: 13, bottom: 6, trailing: 13)
            configuration.baseForegroundColor = selected ? Theme.accent : .secondaryLabel
            configuration.background.backgroundColor = selected ? Theme.accent.withAlphaComponent(0.16) : .clear
            configuration.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { attributes in
                var attributes = attributes
                attributes.font = .systemFont(ofSize: 15, weight: selected ? .semibold : .regular)
                return attributes
            }
            let button = UIButton(configuration: configuration)
            let value = tab.value
            button.addAction(UIAction { [weak self] _ in self?.select(value) }, for: .touchUpInside)
            tabStack.addArrangedSubview(button)
        }
        setNeedsLayout()
    }

    private func select(_ value: String?) {
        guard value != selection else { return }
        Haptics.selection()
        selection = value
        if let value { UserDefaults.standard.set(value, forKey: Self.selectionKey) } else { UserDefaults.standard.removeObject(forKey: Self.selectionKey) }
        rebuildTabs()
        reloadVisible()
        collectionView.setContentOffset(.zero, animated: false)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let bar = Self.barHeight
        let hairline = 1 / max(1, traitCollection.displayScale)
        // 顶栏：左边分组可以横着滑，右边添加、管理
        manageButton.frame = CGRect(x: bounds.width - 48, y: 0, width: 44, height: bar)
        addButton.frame = CGRect(x: bounds.width - 92, y: 0, width: 44, height: bar)
        actionDivider.frame = CGRect(x: bounds.width - 96, y: 13, width: hairline, height: bar - 26)
        tabScroll.frame = CGRect(x: 6, y: 0, width: max(0, bounds.width - 106), height: bar)
        let size = tabStack.systemLayoutSizeFitting(CGSize(width: UIView.layoutFittingCompressedSize.width, height: bar))
        tabStack.frame = CGRect(x: 0, y: 0, width: size.width, height: bar)
        tabScroll.contentSize = CGSize(width: size.width, height: bar)
        divider.frame = CGRect(x: 0, y: bar, width: bounds.width, height: hairline)

        // 贴纸铺满下面整块，最后一行能滑到底部安全区上面
        collectionView.frame = CGRect(x: 0, y: bar, width: bounds.width, height: max(0, bounds.height - bar))
        let bottom = safeAreaInsets.bottom
        if collectionView.contentInset.bottom != bottom {
            collectionView.contentInset.bottom = bottom
            collectionView.verticalScrollIndicatorInsets.bottom = bottom
        }
        let emptyWidth = min(bounds.width - 64, 300)
        let emptySize = emptyView.systemLayoutSizeFitting(CGSize(width: emptyWidth, height: UIView.layoutFittingCompressedSize.height), withHorizontalFittingPriority: .required, verticalFittingPriority: .fittingSizeLevel)
        emptyView.frame = CGRect(x: (bounds.width - emptyWidth) / 2, y: bar + max(12, (bounds.height - bar - bottom - emptySize.height) / 2), width: emptyWidth, height: emptySize.height)
        if let layout = collectionView.collectionViewLayout as? UICollectionViewFlowLayout {
            let columns: CGFloat = bounds.width > 600 ? 8 : 5
            let side = floor((bounds.width - 20 - (columns - 1) * 6) / columns)
            if layout.itemSize.width != side { layout.itemSize = CGSize(width: side, height: side) }
        }
    }

    func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int {
        visible.count
    }

    func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
        let cell = collectionView.dequeueReusableCell(withReuseIdentifier: "sticker", for: indexPath) as! StickerCell
        cell.show(visible[indexPath.item])
        return cell
    }

    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        Haptics.tap()
        onSelect?(visible[indexPath.item])
    }

    func collectionView(_ collectionView: UICollectionView, contextMenuConfigurationForItemsAt indexPaths: [IndexPath], point: CGPoint) -> UIContextMenuConfiguration? {
        guard let indexPath = indexPaths.first, indexPath.item < visible.count else { return nil }
        let sticker = visible[indexPath.item]
        return UIContextMenuConfiguration(actionProvider: { [weak self] _ in
            UIMenu(children: [
                UIAction(title: "管理贴纸", image: UIImage(systemName: "slider.horizontal.3")) { _ in self?.onManage?() },
                UIAction(title: "删除", image: UIImage(systemName: "trash"), attributes: .destructive) { _ in self?.onDelete?(sticker) },
            ])
        })
    }
}

final class StickerCell: UICollectionViewCell {
    private let imageView = UIImageView()
    private var task: Task<Void, Never>?

    override init(frame: CGRect) {
        super.init(frame: frame)
        imageView.contentMode = .scaleAspectFit
        contentView.addSubview(imageView)
        contentView.layer.cornerRadius = 12
        contentView.layer.cornerCurve = .continuous
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layoutSubviews() {
        super.layoutSubviews()
        imageView.frame = contentView.bounds.insetBy(dx: 5, dy: 5)
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        task?.cancel()
        imageView.image = nil
    }

    /// 按下去时像表情键盘那样有个浅底、稍微缩一点
    override var isHighlighted: Bool {
        didSet {
            UIView.animate(withDuration: isHighlighted ? 0.08 : 0.2) {
                self.contentView.backgroundColor = self.isHighlighted ? UIColor.label.withAlphaComponent(0.08) : .clear
                self.imageView.transform = self.isHighlighted ? CGAffineTransform(scaleX: 0.92, y: 0.92) : .identity
            }
        }
    }

    func show(_ sticker: Sticker) {
        contentView.backgroundColor = .clear
        let pixel = bounds.width * UIScreen.main.scale
        task = Task { [weak self] in
            let image = await MediaCache.shared.animatedImage(sticker.media.id, maxPixel: max(160, pixel))
            if !Task.isCancelled { self?.imageView.image = image }
        }
    }
}
