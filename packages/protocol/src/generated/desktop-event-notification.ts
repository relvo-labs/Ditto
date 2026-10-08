/* Generated from schema/desktop-event-notification.json; do not edit. */

export type DesktopEventPayload =
  | {
      type: 'window_upsert';
      window: Window;
      [k: string]: unknown;
    }
  | {
      type: 'window_removed';
      window_id: WindowSessionId;
      [k: string]: unknown;
    }
  | {
      type: 'workspace_upsert';
      workspace: Workspace;
      [k: string]: unknown;
    }
  | {
      type: 'workspace_removed';
      workspace_id: string;
      [k: string]: unknown;
    }
  | {
      output: Output;
      type: 'output_upsert';
      [k: string]: unknown;
    }
  | {
      output_name: string;
      type: 'output_removed';
      [k: string]: unknown;
    }
  | {
      reason: string;
      type: 'resync_required';
      [k: string]: unknown;
    }
  | {
      active: boolean;
      head_revision: string;
      profile_id: string;
      type: 'profile_changed';
      [k: string]: unknown;
    }
  | {
      change: ChangeSummary;
      type: 'change_updated';
      [k: string]: unknown;
    }
  | {
      reason: string;
      type: 'capabilities_changed';
      [k: string]: unknown;
    }
  | {
      panels: PanelStatus[];
      type: 'panels_changed';
      [k: string]: unknown;
    }
  | {
      job: Job;
      type: 'jobs_updated';
      [k: string]: unknown;
    }
  | {
      notification: NotificationItem;
      type: 'notification_posted';
      [k: string]: unknown;
    }
  | {
      id: number;
      reason: string;
      type: 'notification_closed';
      [k: string]: unknown;
    }
  | {
      entry_id: string;
      name: string;
      payload: unknown;
      type: 'host_event';
      [k: string]: unknown;
    }
  | {
      state: SessionState;
      type: 'session_changed';
      [k: string]: unknown;
    }
  | {
      deleted?: boolean;
      next_seq: number;
      session_id: string;
      turn_id?: string | null;
      turn_state?: TurnState | null;
      type: 'conversation_updated';
      [k: string]: unknown;
    }
  | {
      session_id: string;
      text: string;
      turn_id: string;
      type: 'conversation_delta';
      [k: string]: unknown;
    };
/**
 * An opaque identifier valid only for the current compositor session.
 */
export type WindowSessionId = string;
export type WindowState = 'normal' | 'minimized' | 'maximized' | 'fullscreen';
export type Confirmation =
  | {
      state: 'not_required';
      [k: string]: unknown;
    }
  | {
      deadline: string;
      state: 'pending';
      [k: string]: unknown;
    }
  | {
      at: string;
      state: 'confirmed';
      [k: string]: unknown;
    }
  | {
      by_change: string;
      state: 'reverted';
      [k: string]: unknown;
    };
export type HotSwapLevel = 'instant' | 'controlled_handoff' | 'host_restart' | 'session_restart';
export type ChangeOrigin =
  | {
      kind: 'gui';
      surface?: string | null;
      [k: string]: unknown;
    }
  | {
      kind: 'cli';
      [k: string]: unknown;
    }
  | {
      kind: 'agent_standin';
      [k: string]: unknown;
    }
  | {
      kind: 'agent';
      session_id: string;
      tool_call_id: string;
      turn_id: string;
      [k: string]: unknown;
    }
  | {
      kind: 'rescue';
      [k: string]: unknown;
    }
  | {
      kind: 'supervisor';
      reason: string;
      [k: string]: unknown;
    }
  | {
      kind: 'timed_revert';
      reverts: string;
      [k: string]: unknown;
    }
  | {
      kind: 'undo';
      undoes: string;
      [k: string]: unknown;
    }
  | {
      kind: 'import';
      [k: string]: unknown;
    };
export type ResultKind = ('succeeded' | 'failed' | 'partial' | 'unknown') | 'scheduled';
export type ChangeState =
  | 'draft'
  | 'validated'
  | 'rejected'
  | 'prepared'
  | 'aborted'
  | 'applying'
  | 'verifying'
  | 'committed'
  | 'rolling_back'
  | 'rolled_back'
  | 'partially_applied'
  | 'unknown';
export type JobState = ('queued' | 'running' | 'succeeded' | 'failed' | 'cancelled') | 'cancelling';
export type PolicyDecision = 'show' | 'merge' | 'silence';
export type Urgency = 'low' | 'normal' | 'critical';
export type TurnState =
  | 'queued'
  | 'running'
  | 'awaiting_approval'
  | 'cancelling'
  | 'succeeded'
  | 'failed'
  | 'partial'
  | 'unknown'
  | 'cancelled';

export interface DesktopEventNotification {
  payload: DesktopEventPayload;
  /**
   * The `seq` of the previous event delivered to this subscription (or the
   * subscription's starting `seq`). A consumer detects a lost event when it
   * differs from the last `seq` it saw: topics it did not ask for leave
   * gaps in `seq`, never in this chain.
   */
  prev_seq: number;
  /**
   * The active Profile head when the event was published; `null` before
   * Core has loaded a Profile. 0.1 called an observation counter `revision`.
   */
  profile_revision?: string | null;
  /**
   * Position in Core's single event stream, shared by every topic; the
   * value to pass as `after_seq` when resubscribing.
   */
  seq: number;
  subscription_id: string;
}
export interface Window {
  app_id: string;
  focused: boolean;
  height?: number | null;
  id: WindowSessionId;
  /**
   * The output the window is on, by the name `desktop.outputs.list`
   * reports. `x`/`y` are relative to that output (and to its current
   * workspace), not to the global layout, so a position is only meaningful
   * together with this name. Absent when the compositor does not say.
   */
  output?: string | null;
  state: WindowState;
  title: string;
  width?: number | null;
  workspace_id?: string | null;
  x?: number | null;
  y?: number | null;
}
export interface Workspace {
  active: boolean;
  id: string;
  name: string;
}
export interface Output {
  enabled: boolean;
  height: number;
  name: string;
  scale: number;
  width: number;
  x: number;
  y: number;
}
export interface ChangeSummary {
  change_id: string;
  committed_revision?: string | null;
  confirmation: Confirmation;
  created_at: string;
  hot_swap_level: HotSwapLevel;
  origin: ChangeOrigin;
  profile_id: string;
  result?: ResultKind | null;
  state: ChangeState;
  title_key: string;
  updated_at: string;
}
export interface PanelStatus {
  bound_entry?: string | null;
  mounted: boolean;
  mounted_entry?: string | null;
  package?: string | null;
  slot: string;
  visible: boolean;
}
export interface Job {
  /**
   * Whether `desktop.jobs.cancel` can stop it now.
   */
  cancellable?: boolean;
  created_at: string;
  error_key?: string | null;
  idempotency_key?: string | null;
  job_id: string;
  kind: string;
  /**
   * The subject that submitted it (`agent`, `shell`, `cli`); Core owns
   * the job from then on, whoever leaves.
   */
  owner?: string | null;
  /**
   * What the worker reports it is doing (`hashing 3/12`, …).
   */
  phase?: string | null;
  progress?: number | null;
  result?: unknown;
  state: JobState;
  updated_at: string;
}
export interface NotificationItem {
  app_name: string;
  body: string;
  created_at: string;
  decision: PolicyDecision;
  id: number;
  merged_count: number;
  /**
   * Set when the policy could not be asked: the notification is shown and
   * the area says rules are unavailable (failing open to display).
   */
  policy_unavailable: boolean;
  summary: string;
  urgency: Urgency;
}
export interface SessionState {
  lock_client_running: boolean;
  locked: boolean;
  logind_available: boolean;
  preparing_for_sleep: boolean;
}
