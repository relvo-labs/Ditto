// A second plugin that injects the counter example's service (used for L-01).
export const name = 'counter-consumer'
export const inject = ['ditto', 'dittoExampleCounter']

export function apply(ctx) {
  ctx.ditto.capabilities.register({ id: 'plugin.test.consumer.peek', version: '1.0.0', handler: () => ({ seen: ctx.dittoExampleCounter.value() }) })
}
