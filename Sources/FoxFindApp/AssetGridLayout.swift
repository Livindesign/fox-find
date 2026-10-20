import AppKit

/// Fixed-size result tiles need no full-dataset flow layout. Attribute generation
/// is bounded by the requested viewport, even with hundreds of thousands of hits.
final class AssetGridLayout: NSCollectionViewLayout {
    var itemSize = NSSize(width: 200, height: 174)
    var columns = 1
    private let inset: CGFloat = 16, top: CGFloat = 8, gap: CGFloat = 10
    private var count: Int { collectionView?.numberOfItems(inSection: 0) ?? 0 }
    override var collectionViewContentSize: NSSize {
        let rows = (count + columns - 1) / columns
        return NSSize(width: collectionView?.bounds.width ?? 0,
                      height: top + CGFloat(rows) * (itemSize.height + gap))
    }
    override func layoutAttributesForItem(at indexPath: IndexPath) -> NSCollectionViewLayoutAttributes? {
        guard indexPath.section == 0, indexPath.item >= 0, indexPath.item < count else { return nil }
        let result = NSCollectionViewLayoutAttributes(forItemWith: indexPath)
        result.frame = NSRect(x: inset + CGFloat(indexPath.item % columns) * (itemSize.width + gap),
                              y: top + CGFloat(indexPath.item / columns) * (itemSize.height + gap),
                              width: itemSize.width, height: itemSize.height)
        return result
    }
    override func layoutAttributesForElements(in rect: NSRect) -> [NSCollectionViewLayoutAttributes] {
        guard count > 0, !rect.isEmpty else { return [] }
        let first = max(0, Int(floor((rect.minY - top) / (itemSize.height + gap))) * columns)
        let end = min(count, max(0, Int(ceil((rect.maxY - top) / (itemSize.height + gap)))) * columns)
        guard first < end else { return [] }
        return (first..<end).compactMap { layoutAttributesForItem(at: IndexPath(item: $0, section: 0)) }.filter { $0.frame.intersects(rect) }
    }
    override func shouldInvalidateLayout(forBoundsChange newBounds: NSRect) -> Bool {
        newBounds.width != collectionView?.bounds.width
    }
}
