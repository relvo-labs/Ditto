.pragma library

// Presentation only: search the supplied readback without retaining an index.
function matches(summary, manifest, entries, query, localized) {
    const needle = query.trim().toLowerCase();
    if (!needle) return true;
    const values = [summary.package_id, localized(summary.name), localized(manifest ? manifest.description : null)];
    for (const entry of entries) {
        if (entry.package === summary.package_id) {
            values.push(entry.entry_id, localized(entry.name));
        }
    }
    return values.some(value => String(value || "").toLowerCase().indexOf(needle) >= 0);
}
