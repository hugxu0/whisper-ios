import UIKit

/// 贴纸面板，替换键盘显示
final class StickerPanelView: UIView, UICollectionViewDataSource, UICollectionViewDelegate {
    var stickers: [Sticker] = [] {
        didSet { collectionView.reloadData() }
    }

    var onSelect: ((Sticker) -> Void)?
    var onAdd: (() -> Void)?
    var onDelete: ((Sticker) -> Void)?

    private let collectionView: UICollectionView
    private let emptyLabel = UILabel()

    override init(frame: CGRect) {
        let layout = UICollectionViewFlowLayout()
        layout.minimumInteritemSpacing = 8
        layout.minimumLineSpacing = 8
        layout.sectionInset = UIEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
        collectionView = UICollectionView(frame: .zero, collectionViewLayout: layout)
        super.init(frame: frame)
        backgroundColor = .secondarySystemBackground
        collectionView.backgroundColor = .clear
        collectionView.dataSource = self
        collectionView.delegate = self
        collectionView.register(StickerCell.self, forCellWithReuseIdentifier: "sticker")
        addSubview(collectionView)
        autoresizingMask = [.flexibleWidth]
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layoutSubviews() {
        super.layoutSubviews()
        collectionView.frame = bounds
        if let layout = collectionView.collectionViewLayout as? UICollectionViewFlowLayout {
            let columns: CGFloat = bounds.width > 600 ? 8 : 5
            let side = floor((bounds.width - 24 - (columns - 1) * 8) / columns)
            layout.itemSize = CGSize(width: side, height: side)
        }
    }

    func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int {
        stickers.count + 1
    }

    func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
        let cell = collectionView.dequeueReusableCell(withReuseIdentifier: "sticker", for: indexPath) as! StickerCell
        if indexPath.item == 0 {
            cell.showAdd()
        } else {
            cell.show(stickers[indexPath.item - 1])
        }
        return cell
    }

    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        Haptics.tap()
        if indexPath.item == 0 { onAdd?() } else { onSelect?(stickers[indexPath.item - 1]) }
    }

    func collectionView(_ collectionView: UICollectionView, contextMenuConfigurationForItemsAt indexPaths: [IndexPath], point: CGPoint) -> UIContextMenuConfiguration? {
        guard let indexPath = indexPaths.first, indexPath.item > 0 else { return nil }
        let sticker = stickers[indexPath.item - 1]
        return UIContextMenuConfiguration(actionProvider: { [weak self] _ in
            UIMenu(children: [UIAction(title: "删除", image: UIImage(systemName: "trash"), attributes: .destructive) { _ in self?.onDelete?(sticker) }])
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
