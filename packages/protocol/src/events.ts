import type { DesktopSnapshot } from './generated/desktop-snapshot.js';
import type { DesktopEventNotification } from './generated/desktop-event-notification.js';

export class ResyncRequired extends Error {
  constructor(reason: string) { super(`Desktop snapshot required: ${reason}`); }
}

/** In-memory projection of compositor observations. IDs expire with the session. */
export class DesktopProjection {
  private current: DesktopSnapshot;
  private currentSeq: number;
  private stale = false;
  /** Active Profile head when the last event was published (0.2). */
  profileRevision: string | null = null;

  constructor(readonly subscriptionId: string, snapshot: DesktopSnapshot, seq: number) {
    this.current = structuredClone(snapshot);
    this.currentSeq = seq;
  }

  get seq(): number { return this.currentSeq; }
  get snapshot(): DesktopSnapshot { return structuredClone(this.current); }

  apply(event: DesktopEventNotification): void {
    if (this.stale) throw new ResyncRequired('subscription is stale');
    if (event.subscription_id !== this.subscriptionId) {
      this.stale = true;
      throw new ResyncRequired('subscription changed');
    }
    if (event.payload.type === 'resync_required') {
      this.stale = true;
      throw new ResyncRequired(event.payload.reason);
    }
    // One `seq` covers every topic, so it skips what this subscription did
    // not ask for; `prev_seq` chains the events it did get.
    if (event.prev_seq !== this.currentSeq || event.seq <= this.currentSeq) {
      this.stale = true;
      throw new ResyncRequired('event sequence is discontinuous');
    }
    const payload = event.payload;
    switch (payload.type) {
      case 'window_upsert':
        this.current.windows = this.current.windows.filter(item => item.id !== payload.window.id).concat(payload.window);
        break;
      case 'window_removed':
        this.current.windows = this.current.windows.filter(item => item.id !== payload.window_id);
        break;
      case 'workspace_upsert':
        this.current.workspaces = this.current.workspaces.filter(item => item.id !== payload.workspace.id).concat(payload.workspace);
        break;
      case 'workspace_removed':
        this.current.workspaces = this.current.workspaces.filter(item => item.id !== payload.workspace_id);
        break;
      case 'output_upsert':
        this.current.outputs = this.current.outputs.filter(item => item.name !== payload.output.name).concat(payload.output);
        break;
      case 'output_removed':
        this.current.outputs = this.current.outputs.filter(item => item.name !== payload.output_name);
        break;
    }
    this.currentSeq = event.seq;
    this.profileRevision = event.profile_revision ?? null;
  }
}
