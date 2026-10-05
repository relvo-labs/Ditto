import { defineDittoPlugin } from '@ditto/host-sdk'

/**
 * D-34 simple settings plugin: one config namespace, one `plugin.ditto.fixture.clock_format.*`
 * capability. Config is validated by Core against the manifest `config_schema`;
 * the plugin carries no schema library of its own, so ten of these stay small.
 */
const defaults = { hour24: true }

export default defineDittoPlugin<Partial<typeof defaults>>({
  name: 'ditto-fixture-clock-format',
  apply(ctx, config) {
    const effective = { ...defaults, ...config }
    ctx.ditto.capabilities.register({
      id: 'plugin.ditto.fixture.clock_format.get',
      version: '1.0.0',
      handler: () => effective,
    })
  },
})
