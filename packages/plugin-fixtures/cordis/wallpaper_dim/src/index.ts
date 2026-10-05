import { defineDittoPlugin } from '@ditto/host-sdk'

/**
 * D-34 simple settings plugin: one config namespace, one `plugin.ditto.fixture.wallpaper_dim.*`
 * capability. Config is validated by Core against the manifest `config_schema`;
 * the plugin carries no schema library of its own, so ten of these stay small.
 */
const defaults = { percent: 20 }

export default defineDittoPlugin<Partial<typeof defaults>>({
  name: 'ditto-fixture-wallpaper-dim',
  apply(ctx, config) {
    const effective = { ...defaults, ...config }
    ctx.ditto.capabilities.register({
      id: 'plugin.ditto.fixture.wallpaper_dim.get',
      version: '1.0.0',
      handler: () => effective,
    })
  },
})
