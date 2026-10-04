import { faultPoint as enabledFaultPoint, presentedLeaseIds as enabledPresentedLeaseIds } from './fault-enabled.ts'

/**
 * Fault points for Rust integration tests (plan/03/06 §4). `__DITTO_FAULT__` is
 * a build-time constant: the production bundle defines it `false`, so the
 * conditional below folds to the no-op and fault-enabled.ts (the only module
 * that reads DITTO_HOST_FAULT) is tree-shaken out. scripts/build.mjs fails the
 * build if the production bundle still contains that variable name.
 */
declare const __DITTO_FAULT__: boolean

export type FaultPoint =
  | 'prepare.before'
  | 'prepare.after_mount'
  | 'commit.before'
  | 'commit.after_drain'
  | 'commit.after_dispose'
  | 'abort.before'
  | 'rollback.before'
  | 'lease.renew'
  | 'heartbeat'
  | 'invoke.before'

export const faultPoints: readonly FaultPoint[] = [
  'prepare.before', 'prepare.after_mount', 'commit.before', 'commit.after_drain', 'commit.after_dispose',
  'abort.before', 'rollback.before', 'lease.renew', 'heartbeat', 'invoke.before',
]

const noop = async (_point: FaultPoint): Promise<void> => {}

export const faultPoint: (point: FaultPoint) => Promise<void> = __DITTO_FAULT__ ? enabledFaultPoint : noop
export const faultsCompiledIn: boolean = __DITTO_FAULT__
/** Test build only: lease ids from an earlier connection to present on renewal (L-07). */
export const presentedLeaseIds: () => string[] = __DITTO_FAULT__ ? enabledPresentedLeaseIds : () => []
