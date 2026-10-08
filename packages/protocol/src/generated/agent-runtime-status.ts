/* Generated from schema/agent-runtime-status.json; do not edit. */

export type RuntimePhase = 'stopped' | 'starting' | 'ready' | 'draining' | 'failed';

export interface AgentRuntimeStatus {
  active_turns: number;
  backend_pid?: number | null;
  controller_pid?: number | null;
  failure_reason?: string | null;
  generation: number;
  installed: boolean;
  isolation_verified: boolean;
  phase: RuntimePhase;
}
