import QtQuick

/// Product-language wording for ChangeSet states, results, origins and diff
/// values. Every word here follows a real ChangeSet state from Core; nothing
/// is inferred from elapsed time, and there is no wording for progress Core
/// did not report.
QtObject {
    id: text

    required property var client

    function t(source) {
        return client ? client.t(source) : source;
    }

    function key(translationKey, args) {
        return client ? client.key(translationKey, args) : translationKey;
    }

    function pendingConfirmation(record) {
        return !!record && !!record.confirmation && record.confirmation.state === "pending";
    }

    /// A `scheduled` result is saved but not in effect: at the next login
    /// (session_restart level) or back in normal mode (a service change made
    /// in rescue mode). A summary has no items, so its hot-swap level decides.
    function scheduledReason(record) {
        const items = record && record.items ? record.items : [];
        if (items.some(item => item.reason === "rescue_mode")) {
            return "rescue_mode";
        }
        if (items.some(item => item.reason === "next_login") || (record && record.hot_swap_level === "session_restart")) {
            return "next_login";
        }
        return "rescue_mode";
    }

    /// Core's `saved_only` on a committed change: it was written to a
    /// Profile that is not active and nothing on the desktop changed
    /// (protocol 0.2 §8.1). Records and list summaries both carry it.
    function savedOnly(record) {
        return !!record && record.state === "committed" && !!record.saved_only ? record.saved_only : null;
    }

    /// Core says the Profile was deleted since (#171): it cannot be switched
    /// to, so the change will never apply, and Core refuses to undo it.
    function savedOnlyDeleted(record) {
        const saved = savedOnly(record);
        return !!saved && saved.profile_deleted === true;
    }

    function savedOnlyLabel(saved) {
        if (saved.profile_deleted === true) {
            return saved.profile_name ? t(qsTr("曾存到「%1」（已刪除）")).arg(saved.profile_name) : t(qsTr("曾存到另一個組合（已刪除）"));
        }
        return saved.profile_name ? t(qsTr("已存到「%1」")).arg(saved.profile_name) : t(qsTr("已存到另一個組合"));
    }

    /// Whether an undo button is offered for this record or summary: only a
    /// committed change that was not reverted, and not one Core says it
    /// cannot undo because its Profile was deleted. Every undo button that
    /// shows a change record uses this.
    function undoable(record) {
        return !!record && record.state === "committed"
            && !(record.confirmation && record.confirmation.state === "reverted")
            && !savedOnlyDeleted(record);
    }

    /// 準備中 / 套用中 / 確認中 / 完成 / 已回復 / 部分完成 / 無法確認
    function stateLabel(record) {
        if (!record) {
            return "";
        }
        switch (record.state) {
        case "draft":
        case "validated":
            return t(qsTr("準備中"));
        case "prepared":
        case "applying":
            return t(qsTr("套用中"));
        case "verifying":
            return t(qsTr("確認中"));
        case "committed":
            if (savedOnly(record)) {
                return savedOnlyLabel(savedOnly(record));
            }
            if (record.result === "scheduled") {
                return scheduledReason(record) === "rescue_mode" ? t(qsTr("回到一般模式後套用")) : t(qsTr("待下次登入套用"));
            }
            if (record.result === "partial") {
                return t(qsTr("部分完成"));
            }
            if (pendingConfirmation(record)) {
                return t(qsTr("試看中，等待保留"));
            }
            if (record.confirmation && record.confirmation.state === "reverted") {
                return t(qsTr("已回復"));
            }
            return t(qsTr("完成"));
        case "rolling_back":
            return t(qsTr("回復中"));
        case "rolled_back":
            return t(qsTr("已回復"));
        case "aborted":
            return t(qsTr("未套用"));
        case "rejected":
            return t(qsTr("未通過檢查"));
        case "partially_applied":
            return t(qsTr("部分完成"));
        case "unknown":
            return t(qsTr("無法確認"));
        }
        return record.state;
    }

    /// good | warn | bad | info | neutral, repeated by the text above.
    function tone(record) {
        if (!record) {
            return "neutral";
        }
        switch (record.state) {
        case "committed":
            if (savedOnlyDeleted(record)) {
                return "neutral";
            }
            if (record.result === "scheduled" || savedOnly(record)) {
                return "info";
            }
            if (record.result === "partial") {
                return "warn";
            }
            return pendingConfirmation(record) ? "info" : (record.confirmation && record.confirmation.state === "reverted" ? "neutral" : "good");
        case "rejected":
        case "aborted":
        case "rolled_back":
            return "bad";
        case "partially_applied":
        case "unknown":
            return "warn";
        }
        return "info";
    }

    function terminal(record) {
        return !!record && ["committed", "rejected", "aborted", "rolled_back", "partially_applied", "unknown"].indexOf(record.state) >= 0;
    }

    /// One sentence a non-engineer can act on: what took effect, what did not.
    function outcomeSentence(record) {
        if (!record) {
            return "";
        }
        switch (record.state) {
        case "committed":
            if (savedOnlyDeleted(record)) {
                return savedOnly(record).profile_name
                    ? t(qsTr("曾存到「%1」，桌面沒有改變；這個組合已刪除，所以不會再套用，也不能撤銷。")).arg(savedOnly(record).profile_name)
                    : t(qsTr("曾存到另一個組合，桌面沒有改變；那個組合已刪除，所以不會再套用，也不能撤銷。"));
            }
            if (savedOnly(record)) {
                // Core undoes such a change in the same Profile, so undo is
                // offered as for any committed change.
                return savedOnly(record).profile_name
                    ? t(qsTr("已存到「%1」，桌面沒有改變；切換到這個組合時才會套用。可以撤銷。")).arg(savedOnly(record).profile_name)
                    : t(qsTr("已存到另一個組合，桌面沒有改變；切換到那個組合時才會套用。可以撤銷。"));
            }
            if (record.result === "scheduled") {
                return scheduledReason(record) === "rescue_mode"
                    ? t(qsTr("已保存，還沒有生效：回到一般模式後才會套用。"))
                    : t(qsTr("已保存，還沒有生效：下次登入時才會套用。"));
            }
            if (record.result === "partial") {
                return t(qsTr("設定已改回，但下列項目無法還原。"));
            }
            if (pendingConfirmation(record)) {
                return t(qsTr("已套用，正在試看。按「保留」才會留下；取消或逾時會自動回復。"));
            }
            if (record.confirmation && record.confirmation.state === "reverted") {
                return t(qsTr("這項變更已被回復，目前是變更前的設定。"));
            }
            return t(qsTr("已套用並確認生效。可以撤銷。"));
        case "rejected":
            return t(qsTr("沒有套用：檢查時發現問題，原本的設定沒有改變。"));
        case "aborted":
            return t(qsTr("沒有套用：新的元件沒有準備好，原本的設定沒有改變。"));
        case "rolled_back":
            return t(qsTr("套用後沒有通過確認，已全部回復到原本的設定。"));
        case "partially_applied":
            return t(qsTr("只有部分生效，下列項目沒有還原。"));
        case "unknown":
            return t(qsTr("無法確認是否已生效。目前的實際狀態列在下方。"));
        }
        return stateLabel(record);
    }

    function kindLabel(kind) {
        const translationKey = "card.kind." + kind;
        return client && client.tr && client.tr.has(translationKey) ? key(translationKey, {}) : t(qsTr("變更"));
    }

    function surfaceName(surface) {
        switch (surface) {
        case "composition_center":
            return t(qsTr("組合中心"));
        case "plugin_center":
            return t(qsTr("插件中心"));
        case "history":
            return t(qsTr("變更紀錄"));
        case "personalization":
            return t(qsTr("個人化設定"));
        case "dock":
            return t(qsTr("Dock"));
        case "preview_bar":
            return t(qsTr("試看列"));
        }
        return surface ? surface : t(qsTr("桌面"));
    }

    function originLabel(origin) {
        if (!origin) {
            return "";
        }
        switch (origin.kind) {
        case "gui":
            return t(qsTr("在「%1」操作")).arg(surfaceName(origin.surface));
        case "cli":
            return t(qsTr("命令列"));
        case "agent_standin":
            return t(qsTr("Agent 替身"));
        case "rescue":
            return t(qsTr("救援"));
        case "supervisor":
            return t(qsTr("自動停用（服務一再失敗）"));
        case "timed_revert":
            return t(qsTr("未保留，自動回復"));
        case "undo":
            return t(qsTr("撤銷"));
        case "import":
            return t(qsTr("匯入"));
        }
        return origin.kind;
    }

    function revisionOrigin(origin) {
        if (!origin) {
            return "";
        }
        switch (origin.kind) {
        case "create":
            return t(qsTr("新建立"));
        case "duplicate":
            return t(qsTr("複製而來"));
        case "change":
            return t(qsTr("變更"));
        case "import":
            return t(qsTr("匯入"));
        case "rescue":
        case "rescue_offline":
            return t(qsTr("救援"));
        }
        return origin.kind;
    }

    function itemStatusLabel(status) {
        switch (status) {
        case "applied":
            return t(qsTr("已生效"));
        case "failed":
            return t(qsTr("未生效"));
        case "restored":
            return t(qsTr("已還原"));
        case "not_restored":
            return t(qsTr("未還原"));
        case "pending":
            return t(qsTr("等待中"));
        case "scheduled":
            return t(qsTr("尚未生效，之後套用"));
        }
        return status;
    }

    function participantName(participant) {
        switch (participant) {
        case "shell":
            return t(qsTr("桌面介面"));
        case "hostd":
            return t(qsTr("插件服務"));
        case "compositor":
            return t(qsTr("視窗管理"));
        }
        return participant;
    }

    /// The thing an outcome item names: a slot, `appearance`, an entry…
    function itemKeyName(itemKey) {
        if (!itemKey) {
            return "";
        }
        if (itemKey.indexOf("window:") === 0) {
            return t(qsTr("視窗的位置"));
        }
        if (itemKey.indexOf("ui.") === 0 || itemKey.indexOf("svc.") === 0 || itemKey === "layout.strategy") {
            return client && client.tr ? client.tr.slotName(itemKey) : itemKey;
        }
        switch (itemKey) {
        case "appearance":
            return t(qsTr("外觀"));
        case "avatar":
            return t(qsTr("角色"));
        case "layout":
            return t(qsTr("布局"));
        case "shortcuts":
            return t(qsTr("快捷鍵"));
        case "shell":
            return t(qsTr("桌面介面"));
        case "hostd":
            return t(qsTr("插件服務"));
        case "compositor":
            return t(qsTr("視窗管理"));
        }
        return itemKey;
    }

    /// An outcome reason: a translation key when Core sent one, otherwise a
    /// diagnostic string, which stays in the diagnostics area.
    function reasonText(reason) {
        if (!reason) {
            return "";
        }
        const head = String(reason).split(":")[0].trim();
        if (client && client.tr && client.tr.has(head)) {
            return key(head, {});
        }
        if (client && client.tr && client.tr.has("reason." + head)) {
            return key("reason." + head, {});
        }
        return t(qsTr("見診斷"));
    }

    function time(iso) {
        if (!iso) {
            return "";
        }
        const date = new Date(iso);
        return isNaN(date.getTime()) ? iso : Qt.formatDateTime(date, "HH:mm");
    }

    function dateTime(iso) {
        if (!iso) {
            return "";
        }
        const date = new Date(iso);
        return isNaN(date.getTime()) ? iso : Qt.formatDateTime(date, "yyyy-MM-dd HH:mm");
    }

    function packageName(packageId) {
        return client && client.tr ? client.tr.packageName(packageId) : packageId;
    }

    /// A before/after value of a diff item, in words.
    function valueText(item, which) {
        if (!item) {
            return "";
        }
        const args = item.label_args || {};
        if (item.label_key === "diff.slot.changed") {
            const packageId = which === "before" ? args.from_package : args.to_package;
            return packageId ? packageName(packageId) : t(qsTr("（無）"));
        }
        const value = item[which];
        if ((item.label_key === "diff.entry.added" || item.label_key === "diff.entry.removed") && typeof value === "string") {
            return packageName(value);
        }
        if ((item.label_key === "diff.area.joined" || item.label_key === "diff.area.left") && typeof value === "string") {
            // The area an item is shown in, by its product name.
            return client && client.tr ? client.tr.slotName(value) : value;
        }
        if (item.label_key === "diff.avatar.output") {
            // No output named: the character follows the primary screen.
            return value === undefined || value === null ? t(qsTr("主螢幕")) : String(value);
        }
        if (item.label_key === "diff.avatar.corner") {
            switch (value) {
            case "top_left":
                return t(qsTr("左上"));
            case "top_right":
                return t(qsTr("右上"));
            case "bottom_left":
                return t(qsTr("左下"));
            case "bottom_right":
                return t(qsTr("右下"));
            }
        }
        if (value === undefined || value === null) {
            return t(qsTr("（無）"));
        }
        if (typeof value === "boolean") {
            return value ? t(qsTr("開")) : t(qsTr("關"));
        }
        if (item.label_key === "diff.appearance.locale") {
            // Language names are written in their own language (autonyms).
            return value === "en" ? "English" : value === "zh-TW" ? qsTr("繁體中文") : String(value);
        }
        if (item.label_key === "diff.shortcuts" && Array.isArray(value)) {
            return client.join(value.map(binding => binding.chord)) || t(qsTr("（無）"));
        }
        if (Array.isArray(value)) {
            return t(qsTr("%1 項")).arg(value.length);
        }
        if (typeof value === "object") {
            return t(qsTr("%1 項設定")).arg(Object.keys(value).length);
        }
        return String(value);
    }

    function isColor(value) {
        return typeof value === "string" && /^#([0-9a-fA-F]{6}|[0-9a-fA-F]{8})$/.test(value);
    }
}
