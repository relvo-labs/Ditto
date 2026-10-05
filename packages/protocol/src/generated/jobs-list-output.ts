/* Generated from schema/jobs-list-output.json; do not edit. */

export type JobState = 'queued' | 'running' | 'succeeded' | 'failed' | 'cancelled';

export interface JobsListOutput {
  jobs: Job[];
}
export interface Job {
  created_at: string;
  error_key?: string | null;
  idempotency_key?: string | null;
  job_id: string;
  kind: string;
  progress?: number | null;
  result?: unknown;
  state: JobState;
  updated_at: string;
}
