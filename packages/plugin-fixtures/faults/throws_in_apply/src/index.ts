import { defineDittoPlugin } from '@ditto/host-sdk'

/** Fault fixture: apply throws. The candidate must fail in prepare and leave the active set alone. */
export default defineDittoPlugin({
  name: 'ditto-fixture-throws-in-apply',
  apply() {
    throw new Error('fixture: apply refuses to start')
  },
})
