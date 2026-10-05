import { defineDittoPlugin } from '@ditto/host-sdk'

/**
 * D-34 simple settings plugin: one config namespace, one `plugin.ditto.fixture.theme_hint.*`
 * capability. Config is validated by Core against the manifest `config_schema`;
 * the plugin carries no schema library of its own, so ten of these stay small.
 */
const defaults = { hint: 'soft' }

export default defineDittoPlugin<Partial<typeof defaults>>({
  name: 'ditto-fixture-theme-hint',
  apply(ctx, config) {
    const effective = { ...defaults, ...config }
    ctx.ditto.capabilities.register({
      id: 'plugin.ditto.fixture.theme_hint.get',
      version: '1.0.0',
      handler: () => effective,
    })
  },
})
