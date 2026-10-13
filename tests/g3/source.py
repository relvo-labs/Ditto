"""Fingerprint the actual checked-out source, including untracked G3 files."""
import hashlib,json,pathlib,subprocess,os
root=pathlib.Path(__file__).resolve().parents[2]
h=hashlib.sha256()
names=subprocess.check_output(['git','ls-files','-c','-o','--exclude-standard','-z'],cwd=root).split(b'\0')
for name in sorted(set(names)):
    if not name:continue
    p=root/os.fsdecode(name)
    if p.is_file():h.update(name+b'\0');h.update(hashlib.sha256(p.read_bytes()).digest())
result={'commit':subprocess.check_output(['git','rev-parse','HEAD'],cwd=root,text=True).strip(),'dirty':bool(subprocess.check_output(['git','status','--porcelain'],cwd=root)),'source_tree_sha256':h.hexdigest(),'kernel':os.uname().release}
binary=root/'target/debug/ditto-generation-runner'
if binary.is_file():result['native_runner_sha256']=hashlib.sha256(binary.read_bytes()).hexdigest()
print(json.dumps(result))
