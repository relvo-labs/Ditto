import { defineDittoPlugin } from '@ditto/host-sdk'

/**
 * Fault fixture for EX1-12 ②: starts normally, then takes the whole host
 * process down shortly after it is enabled, every time. Core counts each
 * hostd death that follows an enable and disables the entry at its limit;
 * after that hostd must stay up and the entry must not run again.
 */
export default defineDittoPlugin({
  name: 'ditto-fixture-crashes-host',
  apply() {
    setTimeout(() => process.abort(), 1500).unref()
  },
})
