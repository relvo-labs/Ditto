"""Read-only reference host probe; never unlock, relogin or run models."""
import argparse, hashlib, json, os, pathlib, shlex, socket, sqlite3, subprocess

def command(argv, env=None):
    try:
        r=subprocess.run(argv,env=env,stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True,timeout=30)
        return r.returncode,r.stdout.strip()
    except (OSError,subprocess.TimeoutExpired): return 127,''

def environment_paths(text):
    admitted={}
    for item in shlex.split(text):
        key,sep,value=item.partition('=')
        if sep and key in {'DITTO_DATA_DIR','DITTO_WORKSPACE','DITTO_RUNTIME_DIR'} and value.startswith('/'):
            admitted[key]=value
    return admitted

def readonly_schema(directory):
    p=pathlib.Path(directory)/'core.db'
    if not p.is_file():return None
    try:
        c=sqlite3.connect(p.as_uri()+'?mode=ro',uri=True)
        try:return c.execute('PRAGMA user_version').fetchone()[0]
        finally:c.close()
    except sqlite3.Error:return None

def process_link(pid,name):
    try:return str(pathlib.Path(f'/proc/{pid}/{name}').resolve(strict=True))
    except OSError:return None

def main():
    ap=argparse.ArgumentParser();ap.add_argument('--out',required=True);args=ap.parse_args()
    home=pathlib.Path.home();uid=os.getuid();runtime=pathlib.Path('/run/user')/str(uid)
    env=os.environ.copy();env.update(XDG_RUNTIME_DIR=str(runtime),DBUS_SESSION_BUS_ADDRESS=f'unix:path={runtime}/bus')
    units={}
    for unit in ['ditto-core.service','ditto-shell.service','github-actions-ditto-ref.service']:
        rc,text=command(['systemctl','--user','show',unit,'-p','ActiveState','-p','MainPID','-p','WorkingDirectory','-p','FragmentPath'],env)
        fields=dict(line.split('=',1) for line in text.splitlines() if '=' in line)
        pid=int(fields.get('MainPID','0') or 0)
        units[unit]={'query_exit':rc,**fields,'exe':process_link(pid,'exe') if pid else None,'cwd':process_link(pid,'cwd') if pid else None}
    rc,e=command(['systemctl','--user','show','ditto-core.service','-p','Environment','--value'],env)
    paths=environment_paths(e)
    data=paths.get('DITTO_DATA_DIR',str(home/'.local/share/ditto'))
    roots=[]
    for x in [units['ditto-core.service'].get('WorkingDirectory'),units['ditto-core.service'].get('cwd'),str(home/'funlab/Ditto')]:
        if x and x not in roots and pathlib.Path(x,'AGENTS.md').is_file():roots.append(x)
    checkouts=[]
    for x in roots:
        _,sha=command(['git','-C',x,'rev-parse','HEAD']);_,status=command(['git','-C',x,'status','--porcelain=v1']);checkouts.append({'root':x,'head':sha,'dirty_path_count':len(status.splitlines())})
    candidates=[]
    for base in [home/'.local/share',home/'.local/state',home/'funlab']:
        if base.is_dir():
            for p in sorted(base.glob('*')):
                if p.is_dir() and any(word in p.name.lower() for word in ['ditto','g3','subscription']):
                    for q in [p,*list(p.glob('*'))[:80]]:
                        schema=readonly_schema(q)
                        if schema is not None:candidates.append({'path':str(q),'schema':schema})
    _,sessions=command(['loginctl','list-sessions','--no-legend'],env)
    physical=[]
    for line in sessions.splitlines():
        vals=line.split()
        if vals:
            _,props=command(['loginctl','show-session',vals[0],'-p','User','-p','Type','-p','Active','-p','Seat'],env)
            f=dict(l.split('=',1) for l in props.splitlines() if '=' in l)
            if f.get('User')==str(uid):physical.append({'id':vals[0],**f})
    core=units['ditto-core.service'];root=core.get('cwd') if core.get('cwd') in roots else (roots[0] if roots else None)
    profile=None
    if root:
        rc,result=command(['python3',str(pathlib.Path(root,'tests/g1/lib/gui.py')),'relay','desktop.profiles.get'],env)
        if rc==0:
            try:
                d=json.loads(result)['result'];profile={'profile_id':d['profile']['profile_id'],'document_sha256':d['revision']['document_sha256']}
            except (KeyError,ValueError):pass
    rc,locked=command(['busctl','--user','get-property','org.freedesktop.secrets','/org/freedesktop/secrets/collection/login','org.freedesktop.Secret.Collection','Locked'],env)
    keyring={'query_exit':rc,'locked':locked=='b true' if rc==0 else None}
    _,addr=command(['ip','-j','address','show'],env)
    addresses=[]
    try:
        for iface in json.loads(addr):
            addresses += [a['local'] for a in iface.get('addr_info',[]) if a.get('scope')=='global']
    except ValueError:pass
    sudo_rc,_=command(['sudo','-n','true'],env)
    gdm=pathlib.Path('/etc/gdm3/custom.conf');gdm_sha=hashlib.sha256(gdm.read_bytes()).hexdigest() if gdm.is_file() and os.access(gdm,os.R_OK) else None
    overrides=[]
    for p in [pathlib.Path('/etc/systemd/user/ditto-core.service.d/verification-relay.conf'),runtime/'systemd/user/ditto-core.service.d/zz-g3-reference-test.conf']:
        if p.is_file():overrides.append({'path':str(p),'sha256':hashlib.sha256(p.read_bytes()).hexdigest(),'size':p.stat().st_size})
    tool_paths={}
    for name,p in [('node',home/'.nvm/versions/node/v22.23.2/bin/node'),('qt',home/'Qt/6.10.2/gcc_64/bin/qmake6'),('relogin',pathlib.Path('/usr/local/libexec/ditto-relogin'))]:tool_paths[name]={'path':str(p),'executable':os.access(p,os.X_OK)}
    # Credential values, account identifiers and raw environments never emitted.
    report={'format_version':1,'phase':'read-only-preflight','hostname':socket.gethostname(),'uid':uid,'units':units,'checkouts':checkouts,'data_dir':data,'normal_store_schema':readonly_schema(data),'private_store_candidates':candidates,'sessions':physical,'profile':profile,'keyring':keyring,'sudo_available':sudo_rc==0,'gdm_sha256':gdm_sha,'overrides':overrides,'tools':tool_paths,'global_addresses':addresses,'disruption_started':False,'provider_called':False}
    out=pathlib.Path(args.out);out.parent.mkdir(parents=True,exist_ok=True);out.write_text(json.dumps(report,indent=2));out.chmod(0o600)
    print(json.dumps({'phase':report['phase'],'disruption_started':False,'provider_called':False,'core_active':core.get('ActiveState')=='active','profile_readable':profile is not None,'store_candidates':len(candidates)}))

if __name__=='__main__':main()
