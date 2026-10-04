import QtQuick
import Quickshell

/// The Shell as a transaction participant (plan/03/04 §2, protocol 0.2 §9).
///
/// Core sends the full desired state — a ShellProjection: appearance, avatar,
/// one binding per `ui.*` slot, shortcuts — never a diff. The host compares it
/// with what it runs and changes only what differs: boot, reconnect, change and
/// rollback are the same path.
///
///   participant.prepare   load every changed slot's candidate hidden, then
///                         healthy() within 2 s; answer ready | failed per slot
///   participant.commit    per slot: release() the old provider, show the
///                         candidate; then apply appearance and avatar
///   participant.abort     drop the candidates, answer after they are gone
///   participant.rollback  the reverse of commit
///   participant.state     what is mounted, as observed here
///
/// After every mount change the observation is also sent as `shell.report`.
/// What Core compares is this observation, not a claim of success.
///
/// Every trusted QML provider runs in this one Shell process: same host, no
/// isolation (plan/03/04 §2.3). Providers get `client`, `tokens`, `config`,
/// `screen`, `slotName` and `shown`, and nothing else of the Shell.
QtObject {
    id: host

    required property var client
    required property var tokens
    property var screen: Quickshell.screens.length > 0 ? Quickshell.screens[0] : null
    property var counter: null

    /// What is applied now (the committed projection); null until the first.
    property var appearance: null
    property var avatar: null
    property var shortcuts: []
    /// Where the character is, as shell.qml laid it out (AvatarPlacement):
    /// the readback of `avatar`. Null while no placement is known.
    property var avatarPlacement: null

    /// slot name → SlotHost
    property var slots: ({})
    /// change id → { phase, slots: [names], appearance: previous, avatar: previous, target }
    property var changes: ({})
    /// The change being prepared: { changeId, origin, target, slots: [names],
    /// appearanceChanged, avatarChanged }
    property var prepared: null
    /// url → Component, so a swap back and forth reuses the compiled type.
    property var components: ({})

    signal mountsChanged()

    readonly property string devProviders: Quickshell.env("DITTO_SHELL_DEV_PROVIDERS") || ""
    /// Development only: package id → source directory under shell/providers.
    readonly property var devDirectories: ({
        "ditto.panel.top": "panel_top",
        "ditto.dock.bottom": "dock_bottom",
        "ditto.dock.pill": "dock_pill",
        "ditto.launcher.grid": "launcher_grid",
        "ditto.launcher.search": "launcher_search",
        "ditto.tasks.panel": "tasks_panel",
        "ditto.notifications.area": "notifications"
    })

    property Component slotComponent: Component {
        SlotHost {}
    }

    function slot(name) {
        let found = slots[name];
        if (!found) {
            found = slotComponent.createObject(host, { name: name, host: host });
            const table = Object.assign({}, slots);
            table[name] = found;
            slots = table;
        }
        return found;
    }

    /// The mounted provider of a slot, or null.
    function item(name) {
        const found = slots[name];
        return found ? found.activeItem : null;
    }

    /// `qml_url` points into the package store. With DITTO_SHELL_DEV_PROVIDERS
    /// set (development only, never in the release login session) the same
    /// `qml_entry` is loaded from the source tree instead.
    function resolveUrl(binding) {
        if (devProviders.length === 0) {
            return binding.qml_url;
        }
        const entry = binding.qml_url.replace(/^.*\/sha256\/[0-9a-fA-F]+\//, "");
        let directory = devDirectories[binding.package];
        if (!directory) {
            directory = binding.package.replace(/^ditto\./, "").replace(/[.-]/g, "_");
        }
        return "file://" + devProviders + "/" + directory + "/" + entry;
    }

    function componentFor(url) {
        let component = components[url];
        if (!component) {
            component = Qt.createComponent(url, Component.Asynchronous, host);
            if (component.status === Component.Error) {
                // Not cached: a fixed file must load on the next attempt.
                return component;
            }
            const table = Object.assign({}, components);
            table[url] = component;
            components = table;
        }
        return component;
    }

    function same(left, right) {
        return JSON.stringify(left === undefined ? null : left) === JSON.stringify(right === undefined ? null : right);
    }

    function observation() {
        const mounts = [];
        for (const name in slots) {
            const mount = slots[name].mount();
            if (mount) {
                mounts.push(mount);
            }
        }
        mounts.sort((left, right) => left.slot < right.slot ? -1 : 1);
        const observed = { mounts: mounts, appearance: appearance, avatar: avatar };
        if (avatarPlacement) {
            observed.avatar_placement = avatarPlacement;
        }
        return observed;
    }

    /// The placement last sent to Core, so a re-layout that ends where it
    /// started sends nothing.
    property string reportedPlacement: ""

    function sendReport() {
        const observed = observation();
        reportedPlacement = JSON.stringify(observed.avatar_placement || null);
        client.report(observed);
    }

    function reportMounts() {
        mountsChanged();
        sendReport();
    }

    /// The character moved without a change (an output came or went): the
    /// same report, so desktop.panels.list follows it. Not on the hot path:
    /// it runs when outputs or the character's settings change, never per frame.
    function reportPlacement() {
        if (client.online && JSON.stringify(avatarPlacement || null) !== reportedPlacement) {
            sendReport();
        }
    }

    function phaseOf(changeId) {
        if (prepared && prepared.changeId === changeId) {
            return "prepared";
        }
        const record = changes[changeId];
        return record ? record.phase : "unknown";
    }

    function remember(changeId, record) {
        const table = Object.assign({}, changes);
        table[changeId] = record;
        // Only the last few changes matter for rollback and readback.
        const ids = Object.keys(table);
        if (ids.length > 16) {
            delete table[ids[0]];
        }
        changes = table;
    }

    function handle(method, params, reply) {
        try {
            switch (method) {
            case "participant.prepare":
                prepare(params, reply);
                return;
            case "participant.commit":
                reply(commit(params.change_id));
                return;
            case "participant.abort":
                abort(params.change_id);
                reply({});
                return;
            case "participant.rollback":
                reply(rollback(params.change_id));
                return;
            case "participant.state":
                reply({
                    change: params.change_id ? { change_id: params.change_id, phase: phaseOf(params.change_id) } : null,
                    observed: Object.assign({ role: "shell" }, observation())
                });
                return;
            }
            reply(null, { code: -32000, name: "unsupported", message: "unknown participant method " + method });
        } catch (error) {
            console.log("ditto-shell participant " + method + " failed: " + error);
            reply(null, { code: -32099, name: "internal", message: String(error) });
        }
    }

    function prepare(params, reply) {
        const target = params.target;
        if (!target || target.role !== "shell") {
            reply(null, { code: -32001, name: "invalid_params", message: "not a shell projection" });
            return;
        }
        if (prepared && prepared.changeId !== params.change_id) {
            abort(prepared.changeId);
        }
        const changeId = params.change_id;
        const bindings = {};
        for (const binding of target.slots) {
            bindings[binding.slot] = binding;
        }
        const names = Object.keys(slots).concat(Object.keys(bindings)).filter((name, index, all) => all.indexOf(name) === index);
        const changed = names.filter(name => slot(name).needsChange(bindings[name] || null));
        const record = {
            changeId: changeId,
            origin: params.origin,
            target: target,
            slots: changed,
            appearanceChanged: !same(appearance, target.appearance),
            avatarChanged: !same(avatar, target.avatar)
        };
        prepared = record;
        console.log("ditto-participant prepare " + changeId + " origin=" + params.origin + " slots=" + changed.join(","));
        const items = [];
        if (record.appearanceChanged) {
            items.push({ key: "appearance", status: "ready" });
        }
        if (record.avatarChanged) {
            items.push({ key: "avatar", status: "ready" });
        }
        let waiting = changed.length;
        if (waiting === 0) {
            reply({ items: items });
            return;
        }
        for (const name of changed) {
            slot(name).prepare(changeId, bindings[name] || null, function (item) {
                const entry = { key: item.key, status: item.status };
                if (item.reason) {
                    entry.reason = item.reason;
                }
                items.push(entry);
                waiting -= 1;
                if (waiting === 0 && prepared === record) {
                    console.log("ditto-participant prepared " + changeId + " " + JSON.stringify(items));
                    reply({ items: items });
                } else if (waiting === 0) {
                    // Superseded by another prepare or aborted meanwhile.
                    reply({ items: items.map(value => ({ key: value.key, status: "failed", reason: value.reason || "aborted" })) });
                }
            });
        }
    }

    function commit(changeId) {
        const record = prepared;
        if (!record || record.changeId !== changeId) {
            if (phaseOf(changeId) === "committed") {
                return { items: [] };
            }
            throw new Error("no prepared change " + changeId);
        }
        prepared = null;
        const items = [];
        const committedSlots = [];
        if (counter) {
            counter.mark("provider.commit " + record.slots.join(","));
        }
        for (const name of record.slots) {
            const outcome = slot(name).commit(changeId);
            if (!outcome) {
                continue;
            }
            // At boot a failed candidate is skipped; the rest of the desktop
            // still comes up. In a change Core never commits a failed prepare.
            if (outcome.status === "applied") {
                committedSlots.push(name);
            }
            items.push(outcome);
        }
        const previousAppearance = appearance;
        const previousAvatar = avatar;
        if (record.appearanceChanged) {
            appearance = record.target.appearance;
            items.push({ key: "appearance", status: "applied" });
        }
        if (record.avatarChanged) {
            avatar = record.target.avatar;
            items.push({ key: "avatar", status: "applied" });
        }
        shortcuts = record.target.shortcuts || [];
        remember(changeId, {
            phase: "committed",
            slots: committedSlots,
            appearanceChanged: record.appearanceChanged,
            avatarChanged: record.avatarChanged,
            appearance: previousAppearance,
            avatar: previousAvatar
        });
        console.log("ditto-participant commit " + changeId + " " + JSON.stringify(items));
        reportMounts();
        return { items: items };
    }

    function abort(changeId) {
        if (prepared && prepared.changeId === changeId) {
            for (const name of prepared.slots) {
                slot(name).abort(changeId);
            }
            prepared = null;
        }
        remember(changeId, { phase: "aborted", slots: [] });
        console.log("ditto-participant abort " + changeId);
    }

    function rollback(changeId) {
        if (prepared && prepared.changeId === changeId) {
            abort(changeId);
            return { items: [] };
        }
        const record = changes[changeId];
        if (!record || record.phase !== "committed") {
            return { items: [] };
        }
        const items = [];
        for (const name of record.slots) {
            items.push(slot(name).rollback(changeId));
        }
        if (record.appearanceChanged) {
            appearance = record.appearance;
            items.push({ key: "appearance", status: "restored" });
        }
        if (record.avatarChanged) {
            avatar = record.avatar;
            items.push({ key: "avatar", status: "restored" });
        }
        remember(changeId, { phase: "rolled_back", slots: [] });
        console.log("ditto-participant rollback " + changeId + " " + JSON.stringify(items));
        reportMounts();
        return { items: items };
    }
}
