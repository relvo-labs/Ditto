/** Protocol 0.2 closed error set (docs/contracts/protocol-0.2.md §4). */
export const errorCodes = {
  unsupported: -32000,
  invalid_params: -32001,
  not_found: -32002,
  permission_denied: -32003,
  timeout: -32004,
  cancelled: -32005,
  conflict: -32006,
  unavailable: -32007,
  protocol_version_unsupported: -32008,
  identity_rejected: -32009,
  preflight_rejected: -32010,
  internal: -32099,
} as const

export type ErrorName = keyof typeof errorCodes

export interface WireError {
  code: number
  name: string
  message: string
  data?: Record<string, unknown>
  outcome?: 'unknown'
}

/** An error that crosses the socket. `message` is diagnostic text, never product copy. */
export class DittoError extends Error {
  constructor(
    readonly errorName: ErrorName,
    message: string,
    readonly data?: Record<string, unknown>,
    readonly outcome?: 'unknown',
  ) {
    super(message)
  }

  get code(): number { return errorCodes[this.errorName] }

  /** `data.reason` when Core sent one; callers branch on this, not on `message`. */
  get reason(): string | undefined {
    const reason = this.data?.['reason']
    return typeof reason === 'string' ? reason : undefined
  }

  toWire(): WireError {
    return {
      code: this.code,
      name: this.errorName,
      message: this.message,
      ...(this.data ? { data: this.data } : {}),
      ...(this.outcome ? { outcome: this.outcome } : {}),
    }
  }

  static fromWire(error: WireError): DittoError {
    const name = (error.name in errorCodes ? error.name : 'internal') as ErrorName
    return new DittoError(name, error.message, error.data, error.outcome)
  }
}

/**
 * Anything thrown by plugin code becomes `internal` unless it names a closed
 * error. Plugin bundles carry their own copy of the SDK's error class, so the
 * check is structural (`errorName` in the closed set), not `instanceof`.
 */
export function toWireError(error: unknown): WireError {
  if (error instanceof DittoError) return error.toWire()
  const named = error as { errorName?: unknown; message?: unknown; data?: unknown } | undefined
  if (typeof named?.errorName === 'string' && named.errorName in errorCodes) {
    const data = named.data && typeof named.data === 'object' ? named.data as Record<string, unknown> : undefined
    return new DittoError(named.errorName as ErrorName, String(named.message ?? named.errorName), data).toWire()
  }
  const message = error instanceof Error ? error.message : String(error)
  return new DittoError('internal', message).toWire()
}

export function describe(error: unknown): string {
  return error instanceof Error ? error.message : String(error)
}
