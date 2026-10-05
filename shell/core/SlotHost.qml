import QtQuick

/// One slot of the ProviderHost, or one member of a multi-entry area: the two
/// loaders of plan/03/04 §2.2.
///
/// `active` is the mounted provider, `candidate` the one a prepare loads. The
/// loaders are component incubators rather than `Loader` items, because a
/// provider's root is a non-visual `Scope` that owns layer-shell windows, and
/// Qt Quick's Loader only hosts items; the roles are the same. A candidate is
/// created with `shown: false`: it has no surface, no exclusive zone and no
/// input region, so loading it cannot take a click or a frame from the
/// desktop. Incubation is asynchronous for the same reason.
///
/// After a commit the old provider is released (surfaces, zone and input
/// gone) but kept as `retired` until the next prepare or for `retireMs`, so
/// that a rollback restores that same instance instead of building a new one
/// (protocol 0.2 §9). A retired provider has no surface.
QtObject {
    id: slot

    required property string name
    /// The ProviderHost: client, tokens, screen, url resolution.
    required property var host
    /// The slot reported in mounts: the slot itself, or the area a member
    /// belongs to.
    property string reportedSlot: name
    /// The key of this unit's prepare/commit/rollback items: the slot, or the
    /// member's entry id.
    property string itemKey: name
    readonly property bool inArea: reportedSlot !== name

    /// { object, binding } — binding is the ShellSlotBinding it was built from.
    property var active: null
    /// { object, binding, changeId, status: loading|ready|failed, reason }
    property var candidate: null
    /// { object, binding, changeId } — released after a commit, kept for rollback.
    property var retired: null
    property int retireMs: 20000

    readonly property var activeItem: active ? active.object : null

    property var pendingDone: null
    property var pendingComponent: null
    property var pendingIncubator: null

    function sameBinding(left, right) {
        if (!left && !right) {
            return true;
        }
        if (!left || !right) {
            return false;
        }
        return left.entry_id === right.entry_id && left.qml_url === right.qml_url
            && left.package === right.package && left.version === right.version
            && JSON.stringify(left.config) === JSON.stringify(right.config);
    }

    function needsChange(binding) {
        return !sameBinding(active ? active.binding : null, binding);
    }

    function destroyObject(object) {
        if (object) {
            try {
                if (object.shown) {
                    object.shown = false;
                }
            } catch (error) {}
            object.destroy();
        }
    }

    function releaseObject(object) {
        if (!object) {
            return;
        }
        try {
            if (typeof object.release === "function") {
                object.release();
            }
        } catch (error) {
            console.log("ditto-shell " + name + " release threw: " + error);
        }
        try {
            object.shown = false;
        } catch (error) {}
    }

    function dropRetired() {
        if (retired) {
            destroyObject(retired.object);
            retired = null;
        }
        retireTimer.stop();
    }

    function finishPrepare(status, reason) {
        readiness.stop();
        loading.stop();
        if (candidate) {
            candidate.status = status;
            candidate.reason = reason || "";
            if (status === "failed") {
                destroyObject(candidate.object);
                candidate.object = null;
            }
        }
        const done = pendingDone;
        pendingDone = null;
        pendingComponent = null;
        pendingIncubator = null;
        if (done) {
            done({
                key: itemKey,
                status: status,
                reason: status === "failed" ? (reason || "candidate not ready") : undefined
            });
        }
    }

    function checkHealth() {
        if (!pendingDone || !candidate || !candidate.object) {
            return;
        }
        const object = candidate.object;
        if (object.ready !== true) {
            return; // readiness timer or readyChanged decides
        }
        let healthy = false;
        try {
            healthy = typeof object.healthy === "function" ? object.healthy() === true : false;
        } catch (error) {
            finishPrepare("failed", "healthy() threw: " + error);
            return;
        }
        finishPrepare(healthy ? "ready" : "failed", healthy ? "" : "healthy() returned false");
    }

    function incubate(component, binding) {
        const properties = {
            client: host.client,
            tokens: host.tokens,
            config: binding.config || {},
            screen: host.screen,
            slotName: reportedSlot,
            entryId: binding.entry_id,
            shown: false
        };
        const incubator = component.incubateObject(slot, properties, Qt.Asynchronous);
        if (!incubator) {
            finishPrepare("failed", "the provider could not be instantiated");
            return;
        }
        pendingIncubator = incubator;
        const settle = function (status) {
            if (status === Component.Ready) {
                if (!candidate) {
                    incubator.object.destroy();
                    return;
                }
                candidate.object = incubator.object;
                try {
                    incubator.object.readyChanged.connect(slot.checkHealth);
                } catch (error) {}
                loading.stop();
                readiness.restart();
                checkHealth();
            } else if (status === Component.Error) {
                finishPrepare("failed", "the provider failed to instantiate");
            }
        };
        if (incubator.status !== Component.Loading) {
            settle(incubator.status);
        } else {
            incubator.onStatusChanged = settle;
        }
    }

    /// Load the candidate hidden, then `healthy()` within 2 s of its ready.
    /// `done(item)` receives the prepare item for this slot.
    function prepare(changeId, binding, done) {
        abort(null);
        dropRetired();
        candidate = { object: null, binding: binding, changeId: changeId, status: "loading", reason: "" };
        pendingDone = done;
        if (!binding) {
            // The slot is left empty by the target: nothing to load.
            finishPrepare("ready", "");
            return;
        }
        const url = host.resolveUrl(binding);
        loading.restart();
        const component = host.componentFor(url);
        pendingComponent = component;
        const settle = function () {
            if (pendingComponent !== component) {
                return;
            }
            if (component.status === Component.Ready) {
                incubate(component, binding);
            } else if (component.status === Component.Error) {
                console.log("ditto-shell " + name + " candidate did not load: " + component.errorString().trim());
                finishPrepare("failed", "the provider's QML did not load");
            }
        };
        if (component.status === Component.Loading) {
            component.statusChanged.connect(settle);
        } else {
            settle();
        }
    }

    /// Release the old provider first, then show the candidate: only after
    /// release() returns may the new one take the same exclusive zone.
    function commit(changeId) {
        if (!candidate || candidate.changeId !== changeId) {
            return null;
        }
        if (candidate.status !== "ready") {
            const failed = { key: itemKey, status: "failed", reason: candidate.reason || "candidate not ready" };
            abort(changeId);
            return failed;
        }
        const old = active;
        if (old) {
            releaseObject(old.object);
        }
        dropRetired();
        retired = old ? { object: old.object, binding: old.binding, changeId: changeId } : { object: null, binding: null, changeId: changeId };
        if (candidate.object) {
            candidate.object.shown = true;
        }
        active = candidate.binding ? { object: candidate.object, binding: candidate.binding } : null;
        candidate = null;
        retireTimer.restart();
        return { key: itemKey, status: "applied" };
    }

    /// The reverse of commit: release the new provider, show the retired one.
    function rollback(changeId) {
        if (candidate && candidate.changeId === changeId) {
            abort(changeId);
            return { key: itemKey, status: "restored" };
        }
        if (!retired || retired.changeId !== changeId) {
            return { key: itemKey, status: "not_restored", reason: "the previous provider is no longer kept" };
        }
        const current = active;
        if (current) {
            releaseObject(current.object);
            destroyObject(current.object);
        }
        const back = retired;
        retired = null;
        retireTimer.stop();
        if (back.object) {
            back.object.shown = true;
        }
        active = back.binding ? { object: back.object, binding: back.binding } : null;
        return { key: itemKey, status: "restored" };
    }

    /// Drop the candidate of `changeId` (or any candidate when null); returns
    /// once it is destroyed.
    function abort(changeId) {
        if (!candidate || (changeId !== null && candidate.changeId !== changeId)) {
            return;
        }
        readiness.stop();
        loading.stop();
        const dropped = candidate;
        const done = pendingDone;
        const incubator = pendingIncubator;
        candidate = null;
        pendingDone = null;
        pendingComponent = null;
        pendingIncubator = null;
        // A candidate still incubating completes now and, finding no
        // candidate, destroys itself (see incubate()).
        if (incubator && incubator.status === Component.Loading) {
            incubator.forceCompletion();
        }
        destroyObject(dropped.object);
        if (done) {
            done({ key: itemKey, status: "failed", reason: "aborted" });
        }
    }

    function mount() {
        if (!active) {
            return null;
        }
        const object = active.object;
        return {
            slot: reportedSlot,
            entry_id: active.binding.entry_id,
            mounted: !!object,
            // An area member is visible once it is placed where the area is
            // on screen, not merely shown.
            visible: !!object && object.shown === true && (!inArea || host.isPlaced(object))
        };
    }

    /// `healthy()` must answer within 2 s of the candidate being ready.
    property Timer readiness: Timer {
        interval: 2000
        onTriggered: {
            if (slot.pendingDone) {
                const object = slot.candidate ? slot.candidate.object : null;
                slot.finishPrepare("failed", object && object.ready !== true
                    ? "the provider never became ready"
                    : "healthy() did not answer in time");
            }
        }
    }

    /// Loading and instantiating the QML is bounded well inside Core's 10 s
    /// prepare timeout, so a stuck candidate is reported, not timed out.
    property Timer loading: Timer {
        interval: 6000
        onTriggered: {
            if (slot.pendingDone) {
                slot.finishPrepare("failed", "the provider did not finish loading");
            }
        }
    }

    property Timer retireTimer: Timer {
        interval: slot.retireMs
        onTriggered: slot.dropRetired()
    }
}
