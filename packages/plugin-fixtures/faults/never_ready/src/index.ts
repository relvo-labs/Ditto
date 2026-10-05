import { defineDittoPlugin } from '@ditto/host-sdk'

/** Fault fixture: injects a service nobody provides. PENDING means "waiting for ditto.fixture.missing". */
export default defineDittoPlugin({
  name: 'ditto-fixture-never-ready',
  inject: ['ditto.fixture.missing'],
  apply() {},
})
