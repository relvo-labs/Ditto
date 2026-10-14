# G3 physical qualification (temporary operations branch)

This is an operational scaffold for source
`17f5d76dc043d7d8117f1e99458a9a0c9255354b`. It does not install that source
globally, repair product code, accept G3 exits, or establish physical PASS.
Authority is the parent's durable `physical/authority.md` and `plan.md`.
The installed d49387f checkout, release executable and normal schema4 database
must survive unchanged. User-service WorkingDirectory is not a source root.

The workflow is manual only, on `hermes/g3-physical-qualification`, with read
permissions and one exclusive qualification group. Inputs are just a closed
phase choice and a numeric ID. There is no command/ref/binary/store input.
Use one ID through all phases, for example the first preflight workflow run ID.
Parent must independently review this operation commit before push/dispatch.

## Fixed phases

On the existing reference runner, the workflow executes these commands:

```sh
python3 tools/operational/g3_ops.py preflight --id QUALIFICATION_ID
python3 tools/operational/g3_ops.py stage --id QUALIFICATION_ID
python3 tools/operational/g3_ops.py launch --id QUALIFICATION_ID
python3 tools/operational/g3_ops.py collect --id QUALIFICATION_ID
```

`QUALIFICATION_ID` must be 6–20 decimal digits, with no leading zero.
State lives at `/home/neil/.local/state/ditto-g3-qualification/q<ID>` (0700),
outside both installed checkout and Actions `_work`. Stage and launch are
single-use. A failed build retains its log; a fresh build uses a fresh ID.
Preflight reads physical seat, normal provenance, pinned tools, sudo, unlocked
keyring and existing `gh auth status`; it never signs in or invokes a model.

Stage clones local repository objects without hardlinks, checks out the fixed
source in its own detached checkout, and freezes the operations helpers outside
that checkout. No branch operation touches the installed repository. It builds
actual Cargo release bins, the native Qt runner, an independently compiled
fault-injection host, host/agent Node bundles and verification builtins. The
verification selection mirrors `install-session.sh` without invoking its
global installer. Node22.23.2/pnpm10.11.0 are required; Cargo and pnpm operate
offline. The pinned dbus-proxy **source** cache must already exist at the
installed checkout's `target/dbus-proxy-src`; it is independently rebuilt.
Missing caches/tools/build errors stop stage, with a private build log.
The build is a task-owned transient service: two Cargo jobs, 8 GiB memory,
zero swap, 256 tasks, 200% CPU, 512 MiB maximum individual file size and a
2700-second deadline; staging requires 12 GiB free space. These operational
limits are separate from canonical candidate isolation acceptance limits.
Candidate's unmodified `prepare-contexts.py` constructs faults/partial/unavailable
contexts. Source tree, compiler versions, binaries, bundles, templates, original
seat script, adapted script and diff have provenance hashes in `stage.json`.

## Store selection gate — currently BLOCKED

Neither supplied preflight proves the subscribed private store. A false
`auth_ref` flag does not prove missing keyring auth. There is no auto-search,
credential copy, new identity, or test-store relocation in this harness.
Parent must inspect the third host-local inventory and obtain any necessary
human selection. It then supplies **one** host-local `selection.json` under
the task root, containing metadata only:

```json
{
  "source": "17f5d76dc043d7d8117f1e99458a9a0c9255354b",
  "stores": [{
    "root": "EXACT_EXISTING_DITTO_DATA_DIR_FROM_PARENT_SELECTION",
    "codex_home": "SAME_ROOT/state/agent/backend/codex",
    "database_sha256": "CURRENT_SHA256_OF_SAME_ROOT/data/core.db",
    "existing_subscription_proved": true,
    "test_content_only": true
  }]
}
```

These placeholders are not invented executable paths. Only already inspected
task subdirectories below `/home/neil/funlab/Ditto/artifacts/g3` or
`/home/neil/.cache/ditto` are admitted. A store elsewhere is
`BLOCKED_UNPROVED_TASK_ROOT` and needs a further scoped operation review;
do not move it into an admitted path. The root is the original DITTO_DATA_DIR,
**not** the discovered `data/` directory. Symlink/hardlink/normal-store aliases,
stale hashes and absent/multiple selections are refused. Parent's metadata
selection does not substitute for live `agent.providers.status` authentication
readback, which occurs at the unchanged CODEX_HOME before the four model turns.
No provider login endpoint is called.

## Launch, recovery and evidence

Launch creates an independent transient user service with a unique task ID,
2400-second lifetime, no restart, control-group termination and a bounded
ExecStopPost recovery handler. The controller waits up to 300 seconds for the
exact originating Worker PID/starttime to disappear, refuses other Workers and
PID reuse, then pauses the known runner. This assumes the explicitly dedicated
machine has no competing work. It never sends a kill to a Worker. The user
manager must survive graphical logout; this prerequisite requires host proof.
Launch's Actions result is a receipt only.
Before requesting stop it briefly suspends the **one exact Listener** found
in that unit's cgroup via pidfd, waits for stopped-state readback and rechecks
Workers. It waits for stop completion before its own resume cleanup, so a new
job cannot slip through the guard. The saved
Listener PID/starttime is also resumed by independent recovery after a crash.
The controller has its own 1 GiB memory/zero-swap, 128-task, 200% CPU and
256 MiB per-file limits; these do not alter the native probe quotas.

Controller takes a bounded SQLite backup under Core's same writer lock before
migration. Only the DB is backed up; keyring, auth files and backend home are
not copied. Private state/cache remain at their original path. The post-test DB
stays private at that path even if migrated to schema5; no downgrade is claimed.
The backup is recovery material, never a publishable artifact.

Only the hash-pinned **copy** of canonical `seat.sh` is adapted. Its candidate
root and test ExecStart are fixed, the known relay template is fully re-rooted,
and candidate ExecStart plus private DITTO_DATA_DIR share the same removable
`zz-g3-reference-test.conf`. There is no additional bootstrap drop-in.
The copy retains seat/DRM/limit guards, canonical tests and quotas. It adds
private API snapshots/restore hooks and gives runner restoration to the outer
controller. Full/faults/partial/unavailable run serially; full invokes the
unmodified real driver once (four bounded turns), with no retries. Only full
runs real-model and quota probes. Each mode's readback is checked against the
staged source byte tree. Other modes do not invoke models.

Normal recovery removes the test override **before** normal relogin, retains
the test autologin only until that login is attempted, then restores original
GDM bytes/permissions and checks normal schema4, installed source/executable,
relay template and Profile/hash. Private restoration is guarded by live
candidate executable/store readback and uses canonical APIs. Failure in one
recovery step does not skip subsequent normal rescue/runner restoration; it
leaves `needs_human`. Idempotent recovery is shared by finally and ExecStopPost.
Its result never erases the original failure or unfinished modes. An abrupt
machine power loss/user-manager death is outside this transient unit's recovery
guarantee; retain task state for human recovery before normal use.

The runner is restored once, after all modes/failure cleanup. A collector
dispatch is possible only after verified recovery and all modes passed, using
the host's existing gh authentication, with no job tokens, polling or retries.
The branch head is checked against staged operation SHA; the collector also
refuses any workflow SHA mismatch. Missing auth or uncertain dispatch is
`BLOCKED_AUTO_DELIVERY`; parent must explicitly collect host-local evidence.
No webhook is configured or promised.

Collection builds one allowlisted typed `receipt.json`, keeping failed/not_run
modes explicit. Native source checks, restored normal provenance and private
schema changes are read back. Raw evidence hashes identify host-local files.
Raw DBs, environments, model/account traces and logs are never published.
Canonical PNGs include the whole screen: this minimal collector cannot prove
task-only pixels, so all screenshots remain host-local for parent inspection.
Secret sentinels/credential markers in admitted JSON refuse publication.

## Local validation (logic evidence only)

```sh
python3 -m unittest discover -s tools/operational/tests -v
python3 -m py_compile tools/operational/g3_ops.py tools/operational/tests/test_g3_ops.py
bash -n tools/operational/build-g3.sh
git diff --check
```

Tests are TEST ONLY temporary file/SQLite/process fakes. They exercise real
rewrite, admission, witness, recovery, sanitizer and workflow boundary logic;
they establish no physical recovery, OS isolation or subscription result.
Actual local counts and logs are in the parent's durable `physical/writer/`
directory. Parent must review this implementation afresh, run real stage,
read the native host evidence and preserve recovery failures before claiming
any G3 requirement completed.
