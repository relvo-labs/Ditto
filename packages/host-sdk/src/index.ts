/**
 * Plugin-author SDK for the Ditto Cordis desktop host. Types describe
 * `ctx.ditto`; the cross-process contract is still the manifest, validated by
 * Core (plan/03/03 §8). Nothing here runs in its own process or Worker.
 */
import type { Context } from '@deepseek-ai/cordis'
import type { StandardSchemaV1 } from '@standard-schema/spec'
import type { CapabilityDefinition } from '@ditto/host-runtime/api'

export type * from '@ditto/host-runtime/api'
export type { Context }

export interface DeclaredEvent {
  name: string
  coalesce: 'none' | 'latest'
}

export interface DittoPluginDefinition<C = unknown> {
  /** Cordis plugin name; shown in diagnostics. Use a `ditto-` prefix or namespace. */
  name: string
  /** Services this plugin needs. `ditto` is always added. */
  inject?: string[]
  /**
   * Cordis services this plugin provides (via `ctx.provide` or `Service`). The
   * isolate_rebuild strategy mounts a candidate with exactly these names in a
   * separate realm, so the running provider keeps serving until commit.
   */
  services?: string[]
  /** Default coalesce policy per event; must match the manifest `events`. */
  events?: DeclaredEvent[]
  /** Config schema (Schemastery or any Standard Schema). Core validates against manifest `config_schema` first. */
  Config?: StandardSchemaV1<unknown, C>
  apply(ctx: Context, config: C): void | Promise<void>
}

export interface DittoPlugin<C = unknown> extends DittoPluginDefinition<C> {
  inject: string[]
}

/** Identity plus the `ditto` injection; the host reads `services` and `events` from the result. */
export function defineDittoPlugin<C>(definition: DittoPluginDefinition<C>): DittoPlugin<C> {
  return { ...definition, inject: [...new Set(['ditto', ...(definition.inject ?? [])])] }
}

/** Error names a capability handler may return (protocol 0.2 §4); anything else becomes `internal`. */
export type CapabilityErrorName = 'invalid_params' | 'not_found' | 'permission_denied' | 'timeout' | 'cancelled' | 'conflict' | 'unavailable' | 'unsupported'

/** Throw from a handler to answer with a closed protocol error instead of `internal`. */
export class CapabilityError extends Error {
  constructor(readonly errorName: CapabilityErrorName, message: string, readonly data?: Record<string, unknown>) {
    super(message)
  }
}

/** Typed helper for `ctx.ditto.capabilities.register`. */
export function defineCapability<I, O>(definition: CapabilityDefinition<I, O>): CapabilityDefinition<I, O> {
  return definition
}
