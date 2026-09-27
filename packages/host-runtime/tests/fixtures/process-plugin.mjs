// Plain ESM plugin for the process tests: what a packed bundle looks like to hostd.
export const name = 'fixture-process'
export const inject = ['ditto']
export const services = ['processCounter']

export function apply(ctx, config) {
  let n = 0
  ctx.provide('processCounter', { tag: config.tag })
  ctx.ditto.capabilities.register({ id: 'plugin.test.process.get', version: '1.0.0', handler: () => ({ tag: config.tag, n: ++n, mode: ctx.ditto.mode }) })
  if (config.emit) ctx.ditto.events.emit('fixture/changed', { tag: config.tag })
}
