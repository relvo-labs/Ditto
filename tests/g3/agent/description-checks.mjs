// Pure oracle over Core-read artifacts; also usable on retained real runs.
import {isDeepStrictEqual} from 'node:util'

export function descriptionChecks(artifacts) {
  const [a,b,aa,bb]=artifacts.map(a=>a.description)
  const tasks=structuredClone(a)
  tasks.version=aa.version
  tasks.width=380
  tasks.content.max_items=2
  const workspaces=structuredClone(b)
  workspaces.version=bb.version
  workspaces.width=340
  workspaces.content.actions[1].label='閱讀'
  return {
    'initial task description matches requested bounds':a.width===320&&a.content.max_items===4&&!a.content.show_completed,
    'initial workspace description matches requested bounds':b.width===280&&isDeepStrictEqual(b.content.actions.map(a=>a.label),['工作','整理']),
    'task modification preserves every unrequested field':isDeepStrictEqual(tasks,aa),
    'workspace modification preserves every unrequested field':isDeepStrictEqual(workspaces,bb),
  }
}
