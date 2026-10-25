.pragma library

// UX mirror only. The root helper owns validation, name collisions and writes.
// Limits are deliberately bounded before JSON encoding (the wire cap is 4 KiB).
function characters(value) { return Array.from(value).length; }
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
    return /^[a-z][a-z0-9-]{0,30}$/.test(value)
        && ['root', 'admin', 'daemon', 'bin', 'sys', 'sync', 'games', 'man', 'lp',
            'mail', 'news', 'uucp', 'proxy', 'www-data', 'backup', 'list', 'irc',
            'nobody', 'systemd-network', 'systemd-timesync', 'messagebus'].indexOf(value) < 0;
}
function displayName(value) {
    return validUnicode(value) && characters(value) <= 128 && !/[\x00-\x1f\x7f-\x9f:,=]/.test(value);
}
function password(value) {
    return validUnicode(value) && characters(value) >= 8 && characters(value) <= 1024 && !/[\x00\r\n]/.test(value);
}
function weak(value) {
    // Advisory: common strings, a single repeated character, or digits only.
    return /^(.)\1+$/.test(value) || /^[0-9]+$/.test(value)
        || ['password', 'password123', 'qwerty123', 'abcdefgh', 'letmein123'].indexOf(value.toLowerCase()) >= 0;
}
function request(display, name, secret) {
    const json = JSON.stringify({display_name: display, username: name, password: secret}) + '\n';
    return unescape(encodeURIComponent(json)).length <= 4096 ? json : '';
}
function valid(display, name, secret, confirm) {
    return displayName(display) && username(name) && password(secret) && secret === confirm
        && request(display, name, secret).length > 0;
}
