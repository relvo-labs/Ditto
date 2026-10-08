import {readFileSync} from 'node:fs'
import {createHash} from 'node:crypto'
const root=new URL('../vendor/harness/',import.meta.url)
const manifest=JSON.parse(readFileSync(new URL('upstream.json',root),'utf8'))
for(const file of manifest.files){
  const hash=createHash('sha256').update(readFileSync(new URL(file.file,root))).digest('hex')
  if(hash!==file.sha256)throw new Error(`unrecorded upstream modification: ${file.file}`)
}
console.log(`Harness ${manifest.upstream_commit}: ${manifest.files.length} unchanged files verified`)
