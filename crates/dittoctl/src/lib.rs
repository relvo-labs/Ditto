//! Consumer registration. Every capability in the catalog needs at least one
//! consumer; `dittoctl probe` is the one that works without a graphical
//! session, which is what lets contract tests run in the PR check.

use ditto_protocol::catalog;

pub const CONSUMED_CAPABILITIES: &[&str] = &[
    catalog::CAPABILITIES_LIST,
    catalog::OUTPUTS_LIST,
    catalog::WORKSPACES_LIST,
    catalog::WORKSPACES_GET,
    catalog::WORKSPACES_ACTIVATE,
    catalog::WINDOWS_LIST,
    catalog::WINDOWS_GET,
    catalog::WINDOWS_FOCUS,
    catalog::WINDOWS_MOVE,
    catalog::WINDOWS_RESIZE,
    catalog::WINDOWS_SET_STATE,
    catalog::WINDOWS_CLOSE_REQUEST,
    catalog::EVENTS_SUBSCRIBE,
];
