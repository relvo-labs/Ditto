import QtQuick

/// #116 fixture: a DittoClient double with labelled sample data for the
/// centers and chat (three compositions, the built-in packages, a short
/// history). No Core: every write is recorded in `calls` and answered with a
/// fixture error; nothing is applied. Captures and the legacy-equality test
/// use the same data so the base and current files render the same state.
QtObject {
    id: client

    property bool online: true
    property string status: "桌面服務已連線"
    property string mode: "normal"
    property string headRevision: "rev-3"
    property var calls: []
    property var pendingConfirmations: []
    property var windows: []
    property var workspaces: [
        { id: "1", name: "1", active: true }, { id: "2", name: "2", active: false },
        { id: "3", name: "3", active: false }, { id: "4", name: "4", active: false }
    ]
    function activateWorkspace(id) {}
    property var apps: []
    property var packages: [
        { package_id: "ditto.dock.pill" }, { package_id: "ditto.panel.top" }
    ]
    readonly property var names: ({
        "ui.panel_top": "頂部面板", "ui.dock": "Dock", "ui.launcher": "啟動器",
        "ui.tasks_panel": "待辦面板", "ui.notifications": "通知區", "layout.strategy": "布局策略",
        "ditto.panel.top": "頂部面板", "ditto.dock.pill": "膠囊式 Dock", "ditto.dock.bottom": "視窗列 Dock",
        "ditto.launcher.search": "搜尋式啟動器", "ditto.launcher.grid": "網格式啟動器",
        "ditto.tasks.panel": "待辦面板", "ditto.notifications.area": "通知區",
        "ditto.layout.floating": "浮動視窗", "ditto.layout.tile": "基本平鋪",
        "layout.floating": "浮動視窗", "layout.tile": "基本平鋪", "command.assistant": "開啟助理"
    })
    property var tr: ({
        slotName: name => client.names[name] || name,
        packageName: name => client.names[name] || name,
        has: key => false,
        localized: value => typeof value === "string" ? value : (value ? (value["zh-TW"] || value.en || "") : "")
    })

    signal profileChanged(var payload)
    signal changeUpdated(var change)
    signal capabilitiesReloaded()
    signal panelsReported(var panels)
    signal jobUpdated(var job)

    function t(text) { return text; }
    function key(text, args) { return names[text] || text; }
    function join(list) { return list.join("、"); }
    function errorText(error) { return "（fixture）沒有連接 Core，未套用。"; }
    function diagnosticText(error) { return ""; }
    function newKey(prefix) { return prefix + "-fixture"; }
    function capabilityAvailable(name) { return true; }
    function notePending(record) {}
    function refreshPendingConfirmations() {}
    function watchTasks() {}
    function unwatchTasks() {}
    function propose(ops, options, ok, fail) { calls = calls.concat([{ propose: ops }]); if (fail) fail({ name: "fixture" }); }
    function setAppearance(fields, ok, fail) { calls = calls.concat([{ appearance: fields }]); if (fail) fail({ name: "fixture" }); }
    function focusWindow(id) {}
    function launchApp(id, ok, fail) {}

    readonly property var profiles: [
        { profile_id: "p-default", name: "預設", active: true, updated_at: "2026-10-19T08:33:00Z" },
        { profile_id: "p-dev", name: "開發", active: false, updated_at: "2026-10-19T08:14:00Z" },
        { profile_id: "p-present", name: "簡報", active: false, updated_at: "2026-10-19T08:14:00Z" }
    ]
    readonly property var entries: [
        { entry_id: "e-panel", package: "ditto.panel.top", version: "1.1.0", host: "qml", config: {}, disabled: false },
        { entry_id: "e-dock", package: "ditto.dock.pill", version: "1.1.0", host: "qml", config: {}, disabled: false },
        { entry_id: "e-launch", package: "ditto.launcher.search", version: "1.1.0", host: "qml", config: {}, disabled: false },
        { entry_id: "e-tasks", package: "ditto.tasks.panel", version: "1.1.0", host: "qml", config: {}, disabled: false },
        { entry_id: "e-notif", package: "ditto.notifications.area", version: "1.1.0", host: "qml", config: {}, disabled: false },
        { entry_id: "e-layout", package: "ditto.layout.floating", version: "1.0.0", host: "core_builtin", config: {}, disabled: false }
    ]
    readonly property var document: ({
        slots: { "ui.panel_top": "e-panel", "ui.dock": "e-dock", "ui.launcher": "e-launch",
                 "ui.tasks_panel": "e-tasks", "ui.notifications": "e-notif", "layout.strategy": "e-layout" },
        entries: entries,
        shortcuts: [{ chord: "Super+A", command: "assistant.toggle" }]
    })
    readonly property var history: [
        { revision_id: "rev-3", created_at: "2026-10-19T08:33:00Z", origin: { kind: "change" }, last_known_good: true },
        { revision_id: "rev-2", created_at: "2026-10-19T08:20:00Z", origin: { kind: "change" }, pending_confirmation: false },
        { revision_id: "rev-1", created_at: "2026-10-19T08:14:00Z", origin: { kind: "create" } }
    ]
    readonly property var installed: [
        ["ditto.panel.top", ["ui.panel_top"]], ["ditto.dock.pill", ["ui.dock"]], ["ditto.dock.bottom", ["ui.dock"]],
        ["ditto.launcher.search", ["ui.launcher"]], ["ditto.launcher.grid", ["ui.launcher"]],
        ["ditto.tasks.panel", ["ui.tasks_panel"]], ["ditto.notifications.area", ["ui.notifications"]]
    ]

    /// The appearance tokens `desktop.appearance.get` answers with; a test
    /// changes them to stand for a change committed elsewhere (dittoctl, the
    /// Agent, an undo). Every read is recorded in `reads`.
    property var appearanceTokens: ({ accent: "#b9a4ff" })
    /// When set, the whole appearance `desktop.appearance.get` answers with
    /// (a test keeps it equal to the projection it gives the Shell).
    property var appearanceValue: null
    property var reads: []
    function capability(method, args, ok, fail) {
        reads = reads.concat([method]);
        const answer = {
            "desktop.profiles.list": () => ({ profiles: profiles }),
            "desktop.profiles.get": () => {
                const profile = profiles.find(p => p.profile_id === (args.profile_id || "p-default"));
                return { profile: { profile_id: profile.profile_id, name: profile.name, head_revision: "rev-3" },
                         document: document, history: history };
            },
            "desktop.plugins.list": () => ({
                packages: installed.map(([id]) => ({ package_id: id, version: "1.1.0", host_kind: "qml", name: names[id],
                    source: "builtin", author: "Ditto", license: "fixture", trust_level: "builtin" })),
                entries: entries
            }),
            "desktop.plugins.get": () => {
                const found = installed.find(([id]) => id === args.package_id);
                return { manifest: { id: args.package_id, version: "1.1.0", slots: found ? found[1] : [],
                    description: "（fixture）內建套件。", required_protocol_version: "0.2", permissions: [] } };
            },
            "desktop.plugins.diagnostics": () => ({ entries: [] }),
            "desktop.permissions.list": () => ({ grants: [] }),
            "desktop.plugins.development.list": () => ({ artifacts: [] }),
            "desktop.jobs.list": () => ({ jobs: [] }),
            "desktop.layout.get": () => ({ available: [
                { package: "ditto.layout.floating", name_key: "layout.floating" },
                { package: "ditto.layout.tile", name_key: "layout.tile" }] }),
            "desktop.changes.list": () => ({ changes: [] }),
            "desktop.appearance.get": () => ({
                appearance: appearanceValue ? appearanceValue
                    : { theme: "soft-jelly-light", tokens: Object.assign({}, appearanceTokens), locale: "zh-TW",
                        reduced_motion: false, reduced_transparency: false, low_power_style: false },
                avatar: { enabled: true, hidden: false, scale: 1, animations: true, corner: "bottom_right", presentation: "assistant" } }),
            "desktop.shortcuts.list": () => ({ shortcuts: [] }),
            "desktop.commands.list": () => ({ commands: [{ command_id: "assistant.toggle", title_key: "command.assistant" }] }),
            "desktop.outputs.list": () => ({ outputs: [{ name: "Virtual-1", enabled: true }] }),
            "desktop.panels.list": () => ({ avatar: { output: "Virtual-1", corner: "bottom_right" } }),
            "desktop.launcher.list_apps": () => ({ apps: apps })
        }[method];
        if (answer) {
            if (ok) ok(answer());
        } else if (fail) {
            fail({ name: "fixture", message: method });
        }
    }
}
