//! The single authorization entry point. Every capability call, from the
//! Shell as much as from the Agent stand-in, passes `authorize`; the policy
//! table is the one in `docs/contracts/protocol-0.2.md` §7. G1 has no
//! approval responder, so a decision that needs approval is a refusal
//! (`approval_unavailable`): failures never default to allow.

use ditto_protocol::{
    catalog::scope,
    services::{Decision, Grant, PolicyRow},
    PermissionDeniedReason, Subject,
};

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum PolicyDefault {
    Allow,
    Deny,
    GrantRequired,
}

/// Policy for one subject kind and scope. `files:<grant>` is always a grant.
pub fn policy(subject: &Subject, scope_name: &str) -> PolicyDefault {
    use PolicyDefault::{Allow, Deny, GrantRequired};
    if scope_name.starts_with(scope::FILES_PREFIX) {
        return match subject.as_str() {
            Subject::CLI_RESCUE | Subject::RESCUE_UI | Subject::LOCK | Subject::CORE => Deny,
            _ => GrantRequired,
        };
    }
    let host = subject.host_entry().is_some();
    let column = match subject.as_str() {
        Subject::SHELL => 0,
        Subject::CLI => 1,
        Subject::CLI_RESCUE => 2,
        Subject::RESCUE_UI => 3,
        Subject::AGENT => 5,
        Subject::LOCK => 6,
        Subject::CORE => return Allow,
        _ if host => 4,
        _ => return Deny,
    };
    // Rows: shell, cli, cli:rescue, rescue_ui, host:<entry>, agent, lock.
    let row: [PolicyDefault; 7] = match scope_name {
        scope::AGENT_INTERACT | scope::AGENT_READ => [Allow, Allow, Deny, Deny, Deny, Allow, Deny],
        scope::AGENT_WRITE => [Deny, Deny, Deny, Deny, Deny, Allow, Deny],
        scope::AGENT_MANAGE => [Allow, Allow, Deny, Deny, Deny, Deny, Deny],
        // Only a person's own surface (or the CLI they run) takes private
        // context; the Agent and plugins never fetch it themselves.
        scope::CONTEXT => [Allow, Allow, Deny, Deny, Deny, Deny, Deny],
        // Trusted kinds only, whoever submits; plugins have no pool of their
        // own through this door.
        scope::JOBS_RUN => [Allow, Allow, Deny, Deny, Deny, Allow, Deny],
        scope::READ => [Allow, Allow, Allow, Allow, Allow, Allow, Deny],
        scope::CONFIG => [Allow, Allow, Deny, Deny, GrantRequired, Allow, Deny],
        scope::WINDOWS_READ => [
            Allow,
            Allow,
            Allow,
            Allow,
            GrantRequired,
            GrantRequired,
            Deny,
        ],
        scope::WINDOWS_CONTROL => [
            Allow,
            Allow,
            Allow,
            Allow,
            GrantRequired,
            GrantRequired,
            Deny,
        ],
        scope::RESCUE => [Allow, Allow, Allow, Allow, Deny, Deny, Deny],
        scope::PLUGINS_MANAGE => [Allow, Allow, Deny, Deny, Deny, GrantRequired, Deny],
        scope::PERMISSIONS_MANAGE => [Allow, Allow, Deny, Deny, Deny, Deny, Deny],
        scope::SESSION_POWER => [Allow, Allow, Allow, Deny, Deny, Deny, Deny],
        scope::SESSION_LOCK => [Allow, Allow, Allow, Allow, Deny, GrantRequired, Allow],
        scope::NOTIFICATIONS_READ => [Allow, Allow, Deny, Deny, GrantRequired, GrantRequired, Deny],
        scope::TASKS_READ | scope::TASKS_WRITE => {
            [Allow, Allow, Deny, Deny, GrantRequired, GrantRequired, Deny]
        }
        scope::APPS_LAUNCH => [
            Allow,
            Allow,
            Deny,
            Allow,
            GrantRequired,
            GrantRequired,
            Deny,
        ],
        scope::CORE => [Deny; 7],
        scope::NETWORK | scope::PROCESS_EXEC | scope::CLIPBOARD | scope::SCREENSHOT => [
            GrantRequired,
            GrantRequired,
            Deny,
            Deny,
            GrantRequired,
            GrantRequired,
            Deny,
        ],
        _ => [Deny; 7],
    };
    row[column]
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Outcome {
    pub decision: Decision,
    /// The decision a call actually gets: `needs_approval` becomes `denied`.
    pub effective: Decision,
    pub reason: Option<PermissionDeniedReason>,
    /// The scope that decided a refusal.
    pub scope: Option<String>,
}

impl Outcome {
    pub fn allowed(&self) -> bool {
        self.effective == Decision::Allowed
    }
}

/// `grants` are the subject's effective grants (not revoked, not expired).
/// `resource` names the file grant for `files:` scopes.
pub fn authorize(
    subject: &Subject,
    scopes: &[&str],
    resource: Option<&str>,
    grants: &[Grant],
) -> Outcome {
    for scope_name in scopes {
        let scope_name = if *scope_name == "files:*" {
            match resource {
                Some(grant) => format!("{}{grant}", scope::FILES_PREFIX),
                None => scope_name.to_string(),
            }
        } else {
            scope_name.to_string()
        };
        let decision = match policy(subject, &scope_name) {
            PolicyDefault::Allow => continue,
            PolicyDefault::Deny => Decision::Denied,
            PolicyDefault::GrantRequired => {
                let covered = grants.iter().any(|grant| {
                    grant.subject == subject.0
                        && ditto_store::grants::pattern_covers(&grant.scope, &scope_name)
                });
                if covered {
                    continue;
                }
                Decision::NeedsApproval
            }
        };
        return Outcome {
            decision,
            effective: Decision::Denied,
            reason: Some(match decision {
                Decision::NeedsApproval => PermissionDeniedReason::ApprovalUnavailable,
                _ => PermissionDeniedReason::PolicyDenied,
            }),
            scope: Some(scope_name),
        };
    }
    Outcome {
        decision: Decision::Allowed,
        effective: Decision::Allowed,
        reason: None,
        scope: None,
    }
}

pub fn policy_table() -> Vec<PolicyRow> {
    let subjects = [
        Subject::SHELL,
        Subject::CLI,
        Subject::CLI_RESCUE,
        Subject::RESCUE_UI,
        "host:<entry>",
        Subject::AGENT,
        Subject::LOCK,
    ];
    let mut rows = Vec::new();
    for subject in subjects {
        let probe = if subject == "host:<entry>" {
            Subject::host("ent-x")
        } else {
            Subject(subject.into())
        };
        for scope_name in scope::ALL.iter().copied().chain(["files:<grant>"]) {
            let decision = policy(
                &probe,
                if scope_name == "files:<grant>" {
                    "files:x"
                } else {
                    scope_name
                },
            );
            rows.push(PolicyRow {
                subject_kind: subject.into(),
                scope: scope_name.into(),
                default: match decision {
                    PolicyDefault::Allow => "allowed",
                    PolicyDefault::Deny => "denied",
                    PolicyDefault::GrantRequired => "grant_required",
                }
                .into(),
            });
        }
    }
    rows
}

#[cfg(test)]
mod tests {
    use super::*;

    fn grant(subject: &str, scope_name: &str) -> Grant {
        Grant {
            grant_id: "grant-1".into(),
            subject: subject.into(),
            scope: scope_name.into(),
            resource: None,
            granted_at: "2026-09-27T00:00:00.000Z".into(),
            expires_at: None,
            revoked_at: None,
            granted_by: "shell".into(),
        }
    }

    #[test]
    fn the_same_rule_answers_gui_and_agent_and_fails_closed_without_a_responder() {
        let shell = Subject(Subject::SHELL.into());
        let agent = Subject(Subject::AGENT.into());
        assert!(authorize(&shell, &[scope::WINDOWS_CONTROL], None, &[]).allowed());
        let refused = authorize(&agent, &[scope::WINDOWS_CONTROL], None, &[]);
        assert_eq!(refused.decision, Decision::NeedsApproval);
        assert_eq!(refused.effective, Decision::Denied);
        assert_eq!(
            refused.reason,
            Some(PermissionDeniedReason::ApprovalUnavailable)
        );
        let granted = [grant("agent", scope::WINDOWS_CONTROL)];
        assert!(authorize(&agent, &[scope::WINDOWS_CONTROL], None, &granted).allowed());
    }

    #[test]
    fn a_host_entry_needs_its_own_file_grant_and_can_never_manage_plugins() {
        let host = Subject::host("ent-a");
        assert!(!authorize(&host, &["files:*"], Some("grant-1"), &[]).allowed());
        let granted = [grant("host:ent-a", "files:grant-1")];
        assert!(authorize(&host, &["files:*"], Some("grant-1"), &granted).allowed());
        let other = Subject::host("ent-b");
        assert!(!authorize(&other, &["files:*"], Some("grant-1"), &granted).allowed());
        assert_eq!(
            authorize(&host, &[scope::PLUGINS_MANAGE], None, &granted).decision,
            Decision::Denied
        );
    }

    #[test]
    fn rescue_and_lock_subjects_get_only_what_rescue_needs() {
        let rescue = Subject(Subject::CLI_RESCUE.into());
        assert!(authorize(&rescue, &[scope::RESCUE], None, &[]).allowed());
        assert!(!authorize(&rescue, &[scope::CONFIG], None, &[]).allowed());
        let lock = Subject(Subject::LOCK.into());
        assert!(authorize(&lock, &[scope::SESSION_LOCK], None, &[]).allowed());
        assert!(!authorize(&lock, &[scope::READ], None, &[]).allowed());
        assert!(!authorize(&Subject("stranger".into()), &[scope::READ], None, &[]).allowed());
        assert!(!authorize(&Subject(Subject::SHELL.into()), &[scope::CORE], None, &[]).allowed());
    }

    #[test]
    fn every_known_scope_has_a_policy_for_every_subject() {
        assert_eq!(policy_table().len(), 7 * (scope::ALL.len() + 1));
    }
}
