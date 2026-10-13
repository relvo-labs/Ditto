/* Generated from schema/generation-validation.json; do not edit. */

export type Enforcement = 'full' | 'partial' | 'unavailable';
export type StageResult = 'passed' | 'failed' | 'not_run';
export type ValidationStage = 'syntax' | 'contract' | 'load' | 'focus' | 'interaction';

export interface GenerationValidation {
  boundary: GenerationBoundary;
  bundle_sha256: string;
  diagnostics?: string[];
  preview_opened: boolean;
  stages: StageEvidence[];
  test_data: boolean;
}
export interface GenerationBoundary {
  cgroup?: string | null;
  cleanup_complete: boolean;
  cpu_max: string;
  deadline_ms: number;
  enforcement: Enforcement;
  files: boolean;
  landlock_abi: number;
  memory_max: number;
  network: boolean;
  pids_max: number;
  policy: string;
  process_exec_blocked: boolean;
  reasons: string[];
  runner_pid?: number | null;
  unit?: string | null;
}
export interface StageEvidence {
  diagnostic: string;
  result: StageResult;
  stage: ValidationStage;
}
