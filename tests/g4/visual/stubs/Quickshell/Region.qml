import QtQuick

/// Test double: records the input region's geometry source and shape, as
/// Quickshell 0.3.1's Region (`item`, `shape`, `radius`, `intersection`).
/// `contains()` answers for a point in the item's own coordinates the way a
/// rounded-rectangle region would; the compositor is not involved.
QtObject {
    default property list<Region> regions
    property Item item: null
    property int shape: 0
    property int radius: 0
    property int intersection: 0

    function contains(x, y) {
        if (!item) {
            return regions.some(region => {
                if (!region.item) return false;
                const p = region.item.mapFromItem(region.item.parent, x, y);
                return region.contains(p.x, p.y);
            });
        }
        if (x < 0 || y < 0 || x >= item.width || y >= item.height) {
            return false;
        }
        const r = Math.min(radius, item.width / 2, item.height / 2);
        const cx = x < r ? r : (x > item.width - r ? item.width - r : x);
        const cy = y < r ? r : (y > item.height - r ? item.height - r : y);
        return (x - cx) * (x - cx) + (y - cy) * (y - cy) <= r * r;
    }
}
