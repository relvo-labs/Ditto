"""One no-login mTLS probe. Separate namespace; no Core/provider/Home APIs."""
import hashlib
import json
import os
from pathlib import Path
import secrets
import shutil
import subprocess
import g3_ops as ops
import g3_device_bridge as bridge
import g3_diagnostics as diag

LIFE_MS = 300_000
FILES = ('g3_ops.py', 'g3_device_bridge.py', 'g3_diagnostics.py', 'g3_bridge_probe.py')

def root_for(identifier, *, cleanup=False):
    bridge.qualification(identifier)
    base = ops.BASE / 'bridge-probes'
    root = base / ('p' + identifier)
    ops.require(ops.BASE == ops.BASE.resolve() and base == base.resolve() and root == root.resolve(), 'BLOCKED_PROBE_BINDING')
    if not cleanup:
        ops.require(not (ops.BASE / ('q' + identifier)).exists(), 'BLOCKED_PROBE_COLLISION')
    return root

def cleanup(root):
    bridge.private_directory(root)
    bridge.private_directory(root / 'client')
    bridge.erase_keys(root / 'client', 'client')
    erased = all(not (root / 'client' / name).exists() and not (root / 'client' / name).is_symlink() for name in ('client.key', 'client.pem'))
    ops.require(erased, 'BLOCKED_PROBE_CLEANUP')
    return erased

def prepare(root, identifier, host):
    ops.require(not root.exists(), 'BLOCKED_PROBE_SINGLE_USE')
    root.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    bridge.private_directory(root.parent)
    root.mkdir(mode=0o700)
    state = {'qualification_id': identifier, 'status': 'preparing', 'attempted': False, 'source': ops.SOURCE}
    ops.write(root / 'probe-state.json', state)
    try:
        repo = ops.HERE.parents[1]
        ops_sha = host.command(['git', '-C', str(repo), 'rev-parse', 'HEAD']).stdout.strip()
        ops.require(ops_sha == os.environ.get('GITHUB_SHA') and ops.re.fullmatch(r'[a-f0-9]{40}', ops_sha), 'BLOCKED_PROBE_BINDING')
        frozen = root / 'ops'; frozen.mkdir(mode=0o700)
        for name in FILES:
            shutil.copyfile(ops.HERE / name, frozen / name)
        directory = root / 'client'; directory.mkdir(mode=0o700)
        cert = bridge.certificate(directory, 'client', '10.0.1.234')
        state.update(status='prepared', ops_sha=ops_sha, flow_id=secrets.token_hex(16), expires_at_ms=bridge.now_ms()+LIFE_MS,
                     ops_files={name: ops.sha(frozen / name) for name in FILES})
        ops.write(root / 'probe-state.json', state)
        receipt = {k: state[k] for k in ('qualification_id','flow_id','source','ops_sha','expires_at_ms')}
        receipt.update(evidence_class='mtls-probe-prepare', client_certificate=cert['certificate'], client_sha256=cert['sha256'])
        ops.write(root / 'probe-prepare.json', receipt)
        # Task-only deletion lease, outside CI and graphical session. It does
        # not connect, sign in, inspect keyring or invoke a sender.
        host.command(['systemd-run','--user','--unit=ditto-g3-probe-lease-p'+identifier,'--on-active=290','--timer-property=AccuracySec=1',
                      '--property=Type=oneshot','--property=RuntimeMaxSec=20','--property=StandardOutput=null','--property=StandardError=null',
                      '/usr/bin/python3',str(frozen/'g3_ops.py'),'bridge_probe_cleanup','--id',identifier])
        return receipt
    except BaseException as error:
        result = diag.exception_reason(error, 'BLOCKED_PROBE_PREPARE')
        state.update(status='blocked', result=result)
        ops.write(root/'probe-state.json',state)  # before potentially failing erase
        errors = []
        try:
            erased = cleanup(root) if (root / 'client').exists() else True
        except Exception:
            erased = False
            errors.append('BLOCKED_CLEANUP_PROBE_KEYS')
        state.update(keys_erased=erased, cleanup_errors=errors)
        ops.write(root/'probe-state.json',state)
        raise ops.Refused(result) from None

def run(root, host, raw_transport):
    bridge.private_directory(root)
    state = ops.read(root / 'probe-state.json')
    ops.require(state.get('status') == 'prepared' and state.get('attempted') is False, 'BLOCKED_PROBE_SINGLE_USE')
    state.update(status='running', attempted=True)
    ops.write(root/'probe-state.json',state)  # ambiguous result never retried
    result = 'BLOCKED_PROBE_INPUT'
    try:
        ops.require(state.get('qualification_id') == root.name[1:], 'BLOCKED_PROBE_BINDING')
        ops.require(state.get('source') == ops.SOURCE and state.get('ops_sha') == os.environ.get('GITHUB_SHA'), 'BLOCKED_PROBE_BINDING')
        for name in FILES:
            ops.require(ops.sha(root/'ops'/name) == state['ops_files'][name], 'BLOCKED_PROBE_BINDING')
        ops.require(type(raw_transport) is str and len(raw_transport) <= 16384, 'BLOCKED_PROBE_INPUT')
        config = json.loads(raw_transport)
        receipt = ops.read(root/'probe-prepare.json')
        ops.require(config.get('expires_at_ms') == state['expires_at_ms'] and config.get('client_sha256') == receipt['client_sha256'], 'BLOCKED_PROBE_BINDING')
        client = bridge.Client(root/'client',config,state['qualification_id'],state['flow_id'],probe=True)
        client.post('/probe',{'qualification_id':state['qualification_id'],'flow_id':state['flow_id'],'probe':'reachability-v1'})
        result = 'PROBE_OK'
    except Exception as error:
        result = diag.exception_reason(error,'BLOCKED_PROBE_INPUT')
    finally:
        state.update(result=result)
        ops.write(root/'probe-state.json',state)  # first transport outcome before erase
        errors = []
        try:
            erased = cleanup(root)
        except Exception:
            erased = False
            errors.append('BLOCKED_CLEANUP_PROBE_KEYS')
        state.update(status='complete', result=result, keys_erased=erased, cleanup_errors=errors)
        ops.write(root/'probe-state.json',state)
    # No transport/cert/flow/account/code data in the result.
    public = {'qualification_id':root.name[1:],'source':ops.SOURCE,'result':result,'keys_erased':erased,'cleanup_errors':errors,'provider_called':False,'home_called':False}
    ops.require(not ops.SECRET.search(json.dumps(public)), 'BLOCKED_UNLISTED_REASON')
    return public

def phase(name, identifier):
    root = root_for(identifier, cleanup=name=='bridge_probe_cleanup')
    if name == 'bridge_probe_cleanup':
        ops.require(ops.HERE == root/'ops', 'BLOCKED_PROBE_BINDING')
        cleanup(root)
        return
    if name == 'bridge_probe_prepare':
        ops.BASE.mkdir(mode=0o700,parents=True,exist_ok=True)
        result = prepare(root,identifier,ops.Host(root))
    else:
        result = run(root,ops.Host(root),os.environ.get('DITTO_G3_AUTH_TRANSPORT',''))
    print(json.dumps(result))
