import { defineDittoPlugin } from '@ditto/host-sdk'

/**
 * D-34 simple settings plugin: one config namespace, one `plugin.ditto.fixture.focus_minutes.*`
 * capability. Config is validated by Core against the manifest `config_schema`;
 * the plugin carries no schema library of its own, so ten of these stay small.
 */
const defaults = { minutes: 25 }

export default defineDittoPlugin<Partial<typeof defaults>>({
  name: 'ditto-fixture-focus-minutes',
  apply(ctx, config) {
    const effective = { ...defaults, ...config }
    ctx.ditto.capabilities.register({
      id: 'plugin.ditto.fixture.focus_minutes.get',
      version: '1.0.0',
      handler: () => effective,
    })
  },
})
