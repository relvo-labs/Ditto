/* Generated from schema/provider-status.json; do not edit. */

export interface ProviderStatus {
  account_label?: string | null;
  authenticated: boolean;
  available: boolean;
  models: ProviderModel[];
  provider: string;
  rate_limits?: ProviderRateLimits | null;
}
export interface ProviderModel {
  default_effort?: string | null;
  id: string;
  label: string;
  reasoning_efforts: string[];
  supports_images: boolean;
}
export interface ProviderRateLimits {
  primary?: ProviderRateWindow | null;
  secondary?: ProviderRateWindow | null;
}
export interface ProviderRateWindow {
  resets_at_ms?: number | null;
  used_percent: number;
  window_minutes?: number | null;
}
