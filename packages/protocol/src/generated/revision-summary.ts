/* Generated from schema/revision-summary.json; do not edit. */

export type RevisionOrigin =
  | {
      from: string;
      kind: 'create';
      [k: string]: unknown;
    }
  | {
      kind: 'duplicate';
      source_revision: string;
      [k: string]: unknown;
    }
  | {
      change_id: string;
      kind: 'change';
      [k: string]: unknown;
    }
  | {
      kind: 'import';
      [k: string]: unknown;
    }
  | {
      action: string;
      kind: 'rescue_offline';
      [k: string]: unknown;
    }
  | {
      action: string;
      kind: 'rescue';
      [k: string]: unknown;
    };

export interface RevisionSummary {
  created_at: string;
  document_sha256: string;
  last_known_good?: boolean;
  origin: RevisionOrigin;
  parent?: string | null;
  /**
   * Committed and inside a timed-revert or preview window.
   */
  pending_confirmation?: boolean;
  profile_id: string;
  revision_id: string;
  /**
   * A supervisor restart or a failed entry happened in the observation
   * period after this revision was committed.
   */
  unstable?: boolean;
}
