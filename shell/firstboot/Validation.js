.pragma library
.import "UnicodeClasses.js" as Unicode

// UX mirror only. The root helper owns validation, name collisions and writes.
// Limits are deliberately bounded before JSON encoding (the wire cap is 4 KiB).
function codepoints(value) {
    const result = [];
    for (let i = 0; i < value.length; ++i) {
        const high = value.charCodeAt(i);
        if (high >= 0xd800 && high <= 0xdbff && i + 1 < value.length) {
            const low = value.charCodeAt(++i);
            result.push(0x10000 + ((high - 0xd800) << 10) + low - 0xdc00);
        } else result.push(high);
    }
    return result;
}
// QV4's Array.from(QString) counts UTF-16 units in Qt 6.10.2.
function characters(value) { return codepoints(value).length; }
function utf8Bytes(value) { return unescape(encodeURIComponent(value)).length; }
function validUnicode(value) {
    for (let i = 0; i < value.length; ++i) {
        const c = value.charCodeAt(i);
        if (c >= 0xd800 && c <= 0xdbff) {
            const next = value.charCodeAt(++i);
            if (!(next >= 0xdc00 && next <= 0xdfff)) return false;
        } else if (c >= 0xdc00 && c <= 0xdfff) return false;
    }
    return true;
}
function username(value) {
    return /^[a-z][a-z0-9-]{0,30}$/.test(value) && value.indexOf('systemd-') !== 0
        && ['root', 'daemon', 'bin', 'sys', 'sync', 'games', 'man', 'lp', 'mail', 'news', 'uucp',
            'proxy', 'www-data', 'backup', 'list', 'irc', 'gnats', 'nobody', 'nogroup', 'sudo', 'admin',
            'adm', 'wheel', 'shadow', 'staff', 'users', 'audio', 'video', 'input', 'render', 'disk',
            'tty', 'utmp', 'plugdev', 'netdev', 'messagebus', 'polkitd', 'sshd', 'pipewire', 'avahi',
            'kvm', 'lpadmin', 'dialout', 'cdrom', 'lxd', 'sambashare', 'greetd', 'ditto', 'firstboot'].indexOf(value) < 0;
}
function displayName(value) {
    return validUnicode(value) && characters(value) <= 128 && utf8Bytes(value) <= 512
        && !/[:,=]/.test(value) && !codepoints(value).some(cp => (Unicode.mask(cp) & 16) !== 0);
}
function password(value) {
    return validUnicode(value) && characters(value) >= 8 && utf8Bytes(value) <= 511 && !/[\x00\r\n]/.test(value);
}
function weak(value) {
    // Same Unicode properties as PR A's Rust char functions, Unicode 17.0.
    // No blocklist: the former listed strings all fall below 12 scalars.
    let classes = 0;
    for (const cp of codepoints(value)) classes |= Unicode.mask(cp) & 15;
    let count = 0;
    for (const bit of [1, 2, 4, 8]) if (classes & bit) ++count;
    return characters(value) < 12 || count < 2;
}
function request(display, name, secret) {
    const json = JSON.stringify({display_name: display, username: name, password: secret}) + '\n';
    return utf8Bytes(json) - 1 <= 4096 ? json : '';
}
function valid(display, name, secret, confirm) {
    return displayName(display) && username(name) && password(secret) && secret === confirm
        && request(display, name, secret).length > 0;
}
