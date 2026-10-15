"""Closed, secret-free diagnostic vocabulary. Never serialize exception text."""
REASONS = frozenset({
    "NOT_RECORDED",
    "BLOCKED_AUTH_SIGNAL", "BLOCKED_NATIVE_BACKEND_START", "BLOCKED_AUTH_TRANSPORT_SIZE",
    'BLOCKED_AUTH_BACKEND_STILL_RUNNING',
    'BLOCKED_AUTH_BINDING',
    'BLOCKED_AUTH_CLEANUP',
    'BLOCKED_AUTH_CLEANUP_BUDGET',
    'BLOCKED_AUTH_CLEANUP_IDENTITY',
    'BLOCKED_AUTH_CORE_STILL_RUNNING',
    'BLOCKED_AUTH_DATABASE_CHANGED',
    'BLOCKED_AUTH_INTERRUPTED_OR_EXPIRED',
    'BLOCKED_AUTH_OR_MODEL_VERIFICATION',
    'BLOCKED_AUTH_PENDING_TURNS',
    'BLOCKED_AUTH_PID_REUSE',
    'BLOCKED_AUTH_PREFERENCES_CHANGED',
    'BLOCKED_AUTH_PREPARE',
    'BLOCKED_AUTH_REVOCATION',
    'BLOCKED_AUTH_REVOCATION_UNPROVED',
    'BLOCKED_AUTH_RUNTIME_ALIAS',
    'BLOCKED_AUTH_RUNTIME_IN_USE',
    'BLOCKED_AUTH_SCOPE_ABSENCE_UNPROVED',
    'BLOCKED_AUTH_SCOPE_CLEANUP',
    'BLOCKED_AUTH_SCOPE_IDENTITY',
    'BLOCKED_AUTH_SCOPE_READBACK',
    'BLOCKED_AUTH_SCOPE_STILL_ACTIVE',
    'BLOCKED_AUTH_SERVICE_STILL_RUNNING',
    'BLOCKED_AUTH_SINGLE_USE',
    'BLOCKED_AUTH_TRANSPORT_BINDING',
    'BLOCKED_AUTH_UNKNOWN_STATE',
    'BLOCKED_BRIDGE',
    'BLOCKED_BRIDGE_BODY',
    'BLOCKED_BRIDGE_CANCELLED',
    'BLOCKED_BRIDGE_CERTIFICATE',
    'BLOCKED_BRIDGE_INPUT_OR_STATE',
    'BLOCKED_BRIDGE_KEY_GENERATION',
    'BLOCKED_BRIDGE_PREPARE',
    'BLOCKED_DEVICE_LOGIN_EXPIRED',
    'BLOCKED_DEVICE_LOGIN_EXPIRY',
    'BLOCKED_DEVICE_LOGIN_METHOD',
    'BLOCKED_DEVICE_LOGIN_OR_PROBE',
    'BLOCKED_DEVICE_LOGIN_PROVIDER',
    'BLOCKED_DEVICE_PAYLOAD_CODE',
    'BLOCKED_DEVICE_PAYLOAD_EXPIRY',
    'BLOCKED_DEVICE_PAYLOAD_SHAPE',
    'BLOCKED_DEVICE_PAYLOAD_URL',
    'BLOCKED_FRESH_REALM_ALREADY_AUTHENTICATED',
    'BLOCKED_KEYRING_LOCKED',
    'BLOCKED_MINIMAL_PROBE_CANCEL',
    'BLOCKED_MINIMAL_PROBE_CLEANUP',
    'BLOCKED_MINIMAL_PROBE_DEADLINE',
    'BLOCKED_MINIMAL_PROBE_DESKTOP_CHANGE',
    'BLOCKED_MINIMAL_PROBE_MODEL',
    'BLOCKED_MINIMAL_PROBE_RECEIPT',
    'BLOCKED_MINIMAL_PROBE_SETTINGS',
    'BLOCKED_MINIMAL_PROBE_SETTINGS_REVISION',
    'BLOCKED_MINIMAL_PROBE_TOOLS_OR_RESULT',
    'BLOCKED_MTLS_HANDSHAKE',
    'BLOCKED_MTLS_NO_ROUTE',
    'BLOCKED_MTLS_OR_PRIVATE_HOME_ROUTE',
    'BLOCKED_MTLS_PEER_MISMATCH',
    'BLOCKED_MTLS_TCP_OTHER',
    'BLOCKED_MTLS_TCP_REFUSED',
    'BLOCKED_MTLS_TCP_TIMEOUT',
    'BLOCKED_NATIVE_AUTH_METHOD',
    'BLOCKED_NATIVE_AUTH_PATH',
    'BLOCKED_NATIVE_BACKEND_BINARY',
    'BLOCKED_NATIVE_BACKEND_BOUNDARY',
    'BLOCKED_NATIVE_BACKEND_QUOTA',
    'BLOCKED_NATIVE_BACKEND_SCOPE',
    'BLOCKED_NATIVE_CORE_START',
    'BLOCKED_NATIVE_MANAGED_API',
    'BLOCKED_NATIVE_RPC_DEADLINE',
    'BLOCKED_NATIVE_RPC_SIZE_OR_DISCONNECT',
    'BLOCKED_NON_NATIVE_AUTH_RECEIPT',
    'BLOCKED_NORMAL_PROVENANCE_CHANGED',
    'BLOCKED_NORMAL_STORE_ALIAS',
    'BLOCKED_PINNED_MANAGED_API_BINARY',
    'BLOCKED_PINNED_MANAGED_API_HELP',
    'BLOCKED_PLAINTEXT_AUTH',
    'BLOCKED_PRIVATE_HOME_ROUTE',
    'BLOCKED_PROBE_BINDING',
    'BLOCKED_PROBE_CLEANUP',
    'BLOCKED_PROBE_COLLISION',
    'BLOCKED_PROBE_INPUT',
    'BLOCKED_PROBE_PREPARE',
    'BLOCKED_PROBE_SINGLE_USE',
    'BLOCKED_PROVIDER_METHOD_OR_STATUS',
    'BLOCKED_REALM_ALIAS',
    'BLOCKED_REALM_DATABASE_ALIAS',
    'BLOCKED_REALM_SCHEMA_OR_NORMAL_ALIAS',
    'BLOCKED_RECEIVER_REFUSED',
    'BLOCKED_REQUIRED_MODEL_OR_EFFORT',
    'BLOCKED_TRANSPORT_EXPIRED',
    'BLOCKED_UNLISTED_REASON',
})
MARKERS = frozenset({"BLOCKED_UNLISTED_REASON","not_recorded", "supervisor_started", "transport_ready", "native_ready", "preauth_checked", "login_requested", "payload_validated", "code_forwarded", "awaiting_browser", "login_complete", "probe_done"})
LIFECYCLES = frozenset({"BLOCKED_UNLISTED_REASON","not_recorded", "none", "pending", "completed", "unknown", "revoked"})
CLEANUP_STEPS = frozenset({'scope_final_readback', 'auth_lifecycle_unknown', 'auth_revocation_failed', 'core_readback', 'bridge_transport', 'live_auth_revocation', 'scope_readback', 'normal_final_readback', 'cleanup_incomplete', 'scope_stop', 'core_stop', 'auth_revocation', 'prepare_deadline_timer', 'bridge_keys', 'runtime_stop', 'core_final_readback', 'backend_final_readback', 'auth_revocation_unproved'})
CLEANUP_CODES = frozenset({"BLOCKED_CLEANUP_" + name.upper() for name in CLEANUP_STEPS} | {"BLOCKED_CLEANUP_SCOPE_STOP", "BLOCKED_CLEANUP_SCOPE_READBACK", "BLOCKED_CLEANUP_BUDGET_EXHAUSTED", "BLOCKED_UNLISTED_REASON"})


def reason(value, missing="NOT_RECORDED"):
    if value is None:
        return missing
    return value if type(value) is str and value in REASONS else "BLOCKED_UNLISTED_REASON"


def exception_reason(error, fallback):
    # Only exact membership of a structured constant, never str(error).
    if error.__class__.__name__ in ("Refused", "BridgeRefused", "CleanupFailed"):
        value = error.args[0] if error.args else None
        if type(value) is str and value in {"Agent readiness deadline", "Agent draining before ready", "old draining generation did not stop", "Agent stopped before ready", "Agent failed/cancelled/unknown before ready"}:
            return "BLOCKED_NATIVE_BACKEND_START"
        return reason(value, "BLOCKED_UNLISTED_REASON")
    return fallback


def cleanup_code(value, identifier):
    if type(value) is not str:
        return "BLOCKED_UNLISTED_REASON"
    if value in CLEANUP_CODES:
        return value
    if value in CLEANUP_STEPS:
        return "BLOCKED_CLEANUP_" + value.upper()
    if value.endswith(":budget_exhausted") and value[:-17] in CLEANUP_STEPS:
        return "BLOCKED_CLEANUP_BUDGET_EXHAUSTED"
    # Legacy receipts use prefix-bound unit names; only this selected ID and
    # three exact units may be converted. No path/process data is exported.
    for kind in ("agent", "agent-backend", "dittoctl"):
        unit = "ditto-g3-auth-q" + identifier + "-" + kind + ".scope"
        if value == unit + ":stop": return "BLOCKED_CLEANUP_SCOPE_STOP"
        if value in (unit + ":readback", unit + ":active_readback", unit + ":process_readback"): return "BLOCKED_CLEANUP_SCOPE_READBACK"
        if value == unit + ":budget_exhausted": return "BLOCKED_CLEANUP_BUDGET_EXHAUSTED"
    return "BLOCKED_UNLISTED_REASON"
