import QtQuick
import Quickshell.Io

/// Runtime translation. Quickshell 0.3.1 installs no QTranslator, so qsTr()
/// alone would always return its source text. Every Ditto string is still
/// written as qsTr("…") — that is what lupdate and scripts/lint-shell-i18n.mjs
/// read — and is passed through t(), which looks the source text up in the
/// catalogue of the current language. The catalogues are generated from
/// shell/i18n/ditto_*.ts by `node scripts/lint-shell-i18n.mjs --write`.
///
/// Core never sends product text: it sends translation keys (preflight
/// reasons, change-card titles, diff labels). key() renders those.
///
/// A binding that calls t() or key() re-evaluates when the language changes,
/// because both read `language` and `catalogues`.
QtObject {
    id: tr

    /// Profile `appearance.locale`; "zh-TW" and "en" are the two G1 languages.
    property string locale: "zh-TW"
    readonly property string language: locale.toLowerCase().indexOf("en") === 0 ? "en" : "zh-TW"
    property var catalogues: ({})
    /// package id → manifest `name` object ({ "zh-TW": …, "en": … }), filled by
    /// the client from `desktop.plugins.list`, so change cards can name a
    /// package in product language instead of by its id.
    property var packageNames: ({})

    function t(source) {
        const catalogue = catalogues[language];
        if (!catalogue || !catalogue.strings) {
            return source;
        }
        const hit = catalogue.strings[source];
        return hit !== undefined && hit !== "" ? hit : source;
    }

    function has(translationKey) {
        const catalogue = catalogues[language];
        return !!(catalogue && catalogue.keys && catalogue.keys[translationKey] !== undefined);
    }

    /// Render a Core translation key. `{name}` placeholders take the argument
    /// of that name; slot and package arguments are named in product language.
    /// An unknown key is shown as a generic sentence, never as the raw key:
    /// the key itself belongs in the diagnostics area.
    function key(translationKey, args) {
        const catalogue = catalogues[language];
        let text = catalogue && catalogue.keys ? catalogue.keys[translationKey] : undefined;
        if (text === undefined) {
            const prefix = String(translationKey || "").split(".")[0];
            const generic = catalogue && catalogue.keys ? catalogue.keys["generic." + prefix] : undefined;
            text = generic !== undefined ? generic : t(qsTr("（未翻譯的項目）"));
        }
        const values = args || {};
        return text.replace(/\{([a-z_]+)\}/g, (match, name) => {
            if (values[name] === undefined || values[name] === null) {
                return "";
            }
            return argument(name, values[name]);
        });
    }

    function argument(name, value) {
        if (name === "slot") {
            return slotName(String(value));
        }
        if (name === "package" || name === "from_package" || name === "to_package") {
            return packageName(String(value));
        }
        if (name === "token") {
            return tokenName(String(value));
        }
        return typeof value === "object" ? JSON.stringify(value) : String(value);
    }

    function slotName(slot) {
        const translationKey = "slot." + slot;
        if (has(translationKey)) {
            return key(translationKey, {});
        }
        return slot;
    }

    function tokenName(token) {
        const translationKey = "token." + token;
        if (has(translationKey)) {
            return key(translationKey, {});
        }
        return token;
    }

    function packageName(packageId) {
        const names = packageNames[packageId];
        if (names && typeof names === "object") {
            return names[language] || names["zh-TW"] || names.en || packageId;
        }
        if (typeof names === "string" && names.length > 0) {
            return names;
        }
        return packageId || t(qsTr("（無）"));
    }

    /// A manifest `name` or `description`: a string, or an object per locale.
    function localized(value) {
        if (value && typeof value === "object") {
            return value[language] || value["zh-TW"] || value.en || "";
        }
        return value ? String(value) : "";
    }

    function load(language, text) {
        let parsed = null;
        try {
            parsed = JSON.parse(text);
        } catch (error) {
            console.log("ditto-shell translation catalogue unreadable: " + language);
            return;
        }
        const next = Object.assign({}, catalogues);
        next[language] = parsed;
        catalogues = next;
    }

    /// Read once at startup from the shell's own directory; the catalogues are
    /// part of the Shell, not of any package.
    property FileView englishFile: FileView {
        path: Qt.resolvedUrl("../i18n/ditto_en.json").toString().replace("file://", "")
        blockLoading: true
        onLoaded: tr.load("en", text())
    }

    property FileView chineseFile: FileView {
        path: Qt.resolvedUrl("../i18n/ditto_zh_TW.json").toString().replace("file://", "")
        blockLoading: true
        onLoaded: tr.load("zh-TW", text())
    }

    Component.onCompleted: {
        if (!catalogues.en) {
            load("en", englishFile.text());
        }
        if (!catalogues["zh-TW"]) {
            load("zh-TW", chineseFile.text());
        }
    }
}
