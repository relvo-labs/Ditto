/* Generated from schema/job.json; do not edit. */

export type JobState = ('queued' | 'running' | 'succeeded' | 'failed' | 'cancelled') | 'cancelling';

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
