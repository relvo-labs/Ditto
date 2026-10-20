.pragma library

// Keyboard reach for scrolled content, shared by the centers' pages
// (Centers.qml) and the empty state (EmptyState.qml): one mechanism.
//
// reveal(): when keyboard focus lands on an item inside `flick` that is (partly)
// outside the visible part, scroll so the whole item shows with `room` around
// it (or as much of it as fits, its top first). Items outside `flick` are left
// alone. page(): PageUp/PageDown by a screen less a little overlap.

function contains(flick, item) {
    for (let node = item ? item.parent : null; node; node = node.parent) {
        if (node === flick.contentItem) return true;
    }
    return false;
}

function reveal(flick, item, room) {
    if (!flick || !item || !contains(flick, item)) return false;
    const box = item.mapToItem(flick.contentItem, 0, 0, item.width, item.height);
    const maxY = Math.max(0, flick.contentHeight - flick.height);
    let y = flick.contentY;
    if (box.y + box.height + room > y + flick.height) y = box.y + box.height + room - flick.height;
    if (box.y - room < y) y = box.y - room;
    y = Math.max(0, Math.min(maxY, y));
    if (y === flick.contentY) return false;
    flick.contentY = y;
    return true;
}

/// `direction` is +1 (PageDown) or -1 (PageUp). Returns whether it moved.
function page(flick, direction) {
    if (!flick) return false;
    const maxY = Math.max(0, flick.contentHeight - flick.height);
    const step = Math.max(40, flick.height - 48);
    const y = Math.max(0, Math.min(maxY, flick.contentY + direction * step));
    if (y === flick.contentY) return false;
    flick.contentY = y;
    return true;
}
