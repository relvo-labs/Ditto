/* Generated from schema/provider-rate-limits.json; do not edit. */

export interface ProviderRateLimits {
  primary?: ProviderRateWindow | null;
  secondary?: ProviderRateWindow | null;
}
export interface ProviderRateWindow {
  resets_at_ms?: number | null;
  used_percent: number;
  window_minutes?: number | null;
}
