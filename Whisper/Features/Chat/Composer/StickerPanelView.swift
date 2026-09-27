import UIKit

/// 贴纸面板，替换键盘显示。底下一排是分组（全部、自己建的分组、未分组），右边是管理；
/// 第一格是“添加”，加的贴纸放进正在看的分组。
final class StickerPanelView: UIView, UICollectionViewDataSource, UICollectionViewDelegate {
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
    private let emptyLabel = UILabel()
    private let tabScroll = UIScrollView()
    private let tabStack = UIStackView()
    private let manageButton = UIButton(type: .system)
    private let divider = UIView()
    private static let selectionKey = "stickerPanel.selection"
    private static let tabHeight: CGFloat = 44

    override init(frame: CGRect) {
        let layout = UICollectionViewFlowLayout()
        layout.minimumInteritemSpacing = 8
        layout.minimumLineSpacing = 8
        layout.sectionInset = UIEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
        collectionView = UICollectionView(frame: .zero, collectionViewLayout: layout)
        super.init(frame: frame)
        backgroundColor = .secondarySystemBackground
        selection = UserDefaults.standard.string(forKey: Self.selectionKey)
        collectionView.backgroundColor = .clear
        collectionView.dataSource = self
        collectionView.delegate = self
        collectionView.register(StickerCell.self, forCellWithReuseIdentifier: "sticker")
        addSubview(collectionView)

        emptyLabel.text = "这一组还没有贴纸，点 + 从相册加，或者在聊天里长按图片“添加到贴纸”"
        emptyLabel.font = .systemFont(ofSize: 13)
        emptyLabel.textColor = .secondaryLabel
        emptyLabel.numberOfLines = 0
        emptyLabel.textAlignment = .center
        emptyLabel.isHidden = true
        addSubview(emptyLabel)

        divider.backgroundColor = .separator
        addSubview(divider)
        tabScroll.showsHorizontalScrollIndicator = false
        tabStack.axis = .horizontal
        tabStack.spacing = 6
        tabStack.alignment = .center
        tabScroll.addSubview(tabStack)
        addSubview(tabScroll)
        manageButton.setImage(UIImage(systemName: "slider.horizontal.3", withConfiguration: UIImage.SymbolConfiguration(pointSize: 16, weight: .semibold)), for: .normal)
        manageButton.tintColor = .secondaryLabel
        manageButton.accessibilityLabel = "管理贴纸"
        manageButton.addAction(UIAction { [weak self] _ in
            Haptics.tap()
            self?.onManage?()
        }, for: .touchUpInside)
        addSubview(manageButton)
        autoresizingMask = [.flexibleWidth]
        rebuildTabs()
    }

    required init?(coder: NSCoder) { fatalError() }

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
        emptyLabel.isHidden = !visible.isEmpty
        collectionView.reloadData()
    }

    /// 底下的分组按钮：全部、各个分组，有没分组的贴纸时再加一个“未分组”
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
            configuration.contentInsets = NSDirectionalEdgeInsets(top: 5, leading: 12, bottom: 5, trailing: 12)
            configuration.baseForegroundColor = selected ? Theme.accent : .secondaryLabel
            configuration.background.backgroundColor = selected ? Theme.accent.withAlphaComponent(0.15) : .clear
            configuration.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { attributes in
                var attributes = attributes
                attributes.font = .systemFont(ofSize: 14, weight: selected ? .semibold : .regular)
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
        let bottom = safeAreaInsets.bottom
        let tabY = bounds.height - bottom - Self.tabHeight
        collectionView.frame = CGRect(x: 0, y: 0, width: bounds.width, height: max(0, tabY))
        emptyLabel.frame = CGRect(x: 40, y: 0, width: bounds.width - 80, height: max(0, tabY)).insetBy(dx: 0, dy: 40)
        divider.frame = CGRect(x: 0, y: tabY, width: bounds.width, height: 1 / max(1, traitCollection.displayScale))
        manageButton.frame = CGRect(x: bounds.width - 50, y: tabY, width: 44, height: Self.tabHeight)
        tabScroll.frame = CGRect(x: 8, y: tabY, width: max(0, bounds.width - 62), height: Self.tabHeight)
        let size = tabStack.systemLayoutSizeFitting(CGSize(width: UIView.layoutFittingCompressedSize.width, height: Self.tabHeight))
        tabStack.frame = CGRect(x: 0, y: 0, width: size.width, height: Self.tabHeight)
        tabScroll.contentSize = CGSize(width: size.width, height: Self.tabHeight)
        if let layout = collectionView.collectionViewLayout as? UICollectionViewFlowLayout {
            let columns: CGFloat = bounds.width > 600 ? 8 : 5
            let side = floor((bounds.width - 24 - (columns - 1) * 8) / columns)
            if layout.itemSize.width != side { layout.itemSize = CGSize(width: side, height: side) }
        }
    }

    func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int {
        visible.count + 1
    }

    func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
        let cell = collectionView.dequeueReusableCell(withReuseIdentifier: "sticker", for: indexPath) as! StickerCell
        if indexPath.item == 0 {
            cell.showAdd()
        } else {
            cell.show(visible[indexPath.item - 1])
        }
        return cell
    }

    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        Haptics.tap()
        if indexPath.item == 0 { onAdd?() } else { onSelect?(visible[indexPath.item - 1]) }
    }

    func collectionView(_ collectionView: UICollectionView, contextMenuConfigurationForItemsAt indexPaths: [IndexPath], point: CGPoint) -> UIContextMenuConfiguration? {
        guard let indexPath = indexPaths.first, indexPath.item > 0 else { return nil }
        let sticker = visible[indexPath.item - 1]
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
        imageView.frame = contentView.bounds.insetBy(dx: 4, dy: 4)
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        task?.cancel()
        imageView.image = nil
    }

    func showAdd() {
        contentView.backgroundColor = .tertiarySystemFill
        imageView.image = UIImage(systemName: "plus")
        imageView.tintColor = .secondaryLabel
        imageView.contentMode = .center
    }

    func show(_ sticker: Sticker) {
        contentView.backgroundColor = .clear
        imageView.contentMode = .scaleAspectFit
        let pixel = bounds.width * UIScreen.main.scale
        task = Task { [weak self] in
            let image = await MediaCache.shared.animatedImage(sticker.media.id, maxPixel: max(160, pixel))
            if !Task.isCancelled { self?.imageView.image = image }
        }
    }
}
