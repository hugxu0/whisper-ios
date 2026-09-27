import UIKit

/// 竖直排列、高度提前算好的布局。内容高度精确，往上加载历史时可以精确保持滚动位置。
final class ChatLayout: UICollectionViewLayout {
    var heights: [CGFloat] = []
    var topPadding: CGFloat = 8
    var bottomPadding: CGFloat = 8
    /// 新插入的行从下方淡入
    var appearingIndexes: Set<Int> = []

    private var frames: [CGRect] = []
    private var contentHeight: CGFloat = 0
    private var width: CGFloat = 0

    override func prepare() {
        super.prepare()
        guard let collectionView else { return }
        width = collectionView.bounds.width
        frames.removeAll(keepingCapacity: true)
        // 内容不满一屏时整体贴着底部（输入栏上方），像 iMessage 那样
        let inset = collectionView.adjustedContentInset
        let visible = collectionView.bounds.height - inset.top - inset.bottom
        let total = topPadding + heights.reduce(0, +) + bottomPadding
        var y = topPadding + max(0, visible - total)
        for height in heights {
            frames.append(CGRect(x: 0, y: y, width: width, height: height))
            y += height
        }
        contentHeight = y + bottomPadding
    }

    override var collectionViewContentSize: CGSize {
        CGSize(width: width, height: contentHeight)
    }

    override func layoutAttributesForElements(in rect: CGRect) -> [UICollectionViewLayoutAttributes]? {
        guard !frames.isEmpty else { return [] }
        // 二分查找第一个可见的行
        var low = 0
        var high = frames.count - 1
        while low < high {
            let mid = (low + high) / 2
            if frames[mid].maxY < rect.minY { low = mid + 1 } else { high = mid }
        }
        var result: [UICollectionViewLayoutAttributes] = []
        var index = low
        while index < frames.count, frames[index].minY <= rect.maxY {
            result.append(attributes(at: index))
            index += 1
        }
        return result
    }

    override func layoutAttributesForItem(at indexPath: IndexPath) -> UICollectionViewLayoutAttributes? {
        guard indexPath.item < frames.count else { return nil }
        return attributes(at: indexPath.item)
    }

    private func attributes(at index: Int) -> UICollectionViewLayoutAttributes {
        let attributes = UICollectionViewLayoutAttributes(forCellWith: IndexPath(item: index, section: 0))
        attributes.frame = frames[index]
        return attributes
    }

    override func initialLayoutAttributesForAppearingItem(at itemIndexPath: IndexPath) -> UICollectionViewLayoutAttributes? {
        guard let attributes = layoutAttributesForItem(at: itemIndexPath)?.copy() as? UICollectionViewLayoutAttributes else { return nil }
        if appearingIndexes.contains(itemIndexPath.item) {
            attributes.alpha = 0
            attributes.transform = CGAffineTransform(translationX: 0, y: 24).scaledBy(x: 0.96, y: 0.96)
        }
        return attributes
    }

    override func shouldInvalidateLayout(forBoundsChange newBounds: CGRect) -> Bool {
        newBounds.width != width
    }

    func frame(at index: Int) -> CGRect? {
        index < frames.count ? frames[index] : nil
    }

    /// 行数和算好的位置对不上（数据刚换、还没排版）时，按现在的高度马上重算
    func prepareIfStale() {
        if frames.count != heights.count { prepare() }
    }

    var totalHeight: CGFloat { contentHeight }
}
