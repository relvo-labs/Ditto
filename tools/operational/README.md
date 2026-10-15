# G3 physical qualification (temporary operations branch)

This is an operational scaffold for source
`17f5d76dc043d7d8117f1e99458a9a0c9255354b`. It does not install that source
globally, repair product code, accept G3 exits, or establish physical PASS.
Authority is the parent's durable `physical/authority.md`, `auth-authority.md` and `plan.md`. The newer auth authority supersedes the old-store selection step.
The installed d49387f checkout, release executable and normal schema4 database
must survive unchanged. User-service WorkingDirectory is not a source root.

The workflow is manual only, on `hermes/g3-physical-qualification`, with read
permissions and one exclusive qualification group. Inputs are just a closed
phase choice, a numeric ID, and public mTLS transport metadata for auth_login. There is no command/ref/binary/store/code/private-key input.
Use one ID through all phases, for example the first preflight workflow run ID.
Parent must independently review this operation commit before push/dispatch.

## Fixed phases

On the existing reference runner, the workflow executes these commands:

```sh
python3 tools/operational/g3_ops.py preflight --id QUALIFICATION_ID
python3 tools/operational/g3_ops.py stage --id QUALIFICATION_ID
python3 tools/operational/g3_ops.py auth_prepare --id QUALIFICATION_ID
# Parent sets reviewed PUBLIC transport metadata as workflow input.
python3 tools/operational/g3_ops.py auth_login --id QUALIFICATION_ID
python3 tools/operational/g3_ops.py auth_status --id QUALIFICATION_ID
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

## Fresh realm and device bridge

Old-store discovery is **closed**. The retained inventory phase now returns a
closed/not_run receipt without searching. `selection.json` and manually asserted
`existing_subscription_proved` are never consulted by production phases.
The new authority explicitly permits one new realm:
`/home/neil/.cache/ditto/g3-auth-q<ID>` (0700), with database `data/core.db` and
exact future backend `state/agent/backend/{home,codex}` paths. An existing realm,
alias, normal-store link, stale receipt or unknown native identity is refused.
There is no credential/reference transplant, API-key path or new default CLI
home. Normal installed source/target, schema4 and Profile/hash are read back
unchanged before/after initialization, auth and cleanup.

`auth_prepare` requires successful stage, checks the exact pinned0.160 binary
hash/version and app-server help using an empty task-owned help home (no login),
then starts **candidate Core** with the fixture compositor and `DITTO_SYSTEM=none`.
Core initializes schema5 and configures gpt-6.1-sol/high through managed settings;
no DB rows are authored. Core launches the unmodified private relay as dittoctl.
No GUI, normal Core, GDM or CI runner is stopped. The fixture Core is stopped
before returning its native/public preparation receipt. It creates only a
reference-local ephemeral client key and public certificate; keys are 0600 under
0700 directories and never returned. A task-only 890s cleanup timer covers abandoned reference preparation (no CI queries). There is no auth during prepare.

Parent obtains the public preparation JSON from the known authenticated runner,
checks its qualification/source/operation SHA, and performs these commands
**outside the repository** after fresh independent source-read-only review:

```sh
# Absolute helper path; cwd and output directory are task-owned, outside repo.
python3 /ABS/OPS/tools/operational/g3_device_bridge.py prepare \
  --client-receipt /TASK/auth-prepare.json --directory /TASK/receiver-q<ID>
python3 /ABS/OPS/tools/operational/g3_device_bridge.py serve \
  --directory /TASK/receiver-q<ID>
```

Prepare emits only `qualification_id`, `flow_id`, exact parent host192.168.1.102,
a random high task port, certificate fingerprints/public server certificate and
expiry. Parent's private key stays on parent. Parent starts serve, then places
that **public JSON only** in the manual auth_login workflow's `auth_transport`
input. No branch/source modification after stage is needed or admitted: auth,
launch and collector workflow SHA must equal staged operation SHA. Receiver CLI
refuses GitHub Actions execution and repository cwd. It does not run on reference
or via a remote workflow. A port conflict is a blocker; no alternate endpoint
or routing fallback is inferred.

The receiver uses standard-library HTTPS/SSL, TLS>=1.2, CERT_REQUIRED, hostname
verification on client plus exact peer fingerprints. Public transport accepts
only parent192.168.1.102, high bounded port, qualification/flow IDs and public
certificate metadata. Its authorization lifetime is <=15 minutes; X509 has
one-day encoding validity but gives no authorization past that application
expiry, and local key files are deleted on terminal exit/signal/deadline. A task-only parent disposal child also removes keys if prepare is abandoned before serve. The child has no network or sender and stops when serve cleans up.
Only fixed POST `/login_code` and `/status` exist, with <=4096-byte closed JSON.
No query/bearer/code path, redirects, URL proxy, recipient, shell, file or admin
operation is accepted. Login URL is exactly https://auth.openai.com/codex/device;
code is 4–16 uppercase letters/digits/hyphens. Unknown fields, peer/flow mismatch,
replay and expiry refuse. Sender failures are terminal, never retried.

Receiver forwards directly using the already verified supported command:
`/home/neil/.local/bin/hermes send --to telegram:8016167934 --quiet --file -`.
Message text goes only to stdin; sender stdout/stderr are discarded. Neither
HTTP response nor receipts contain code, code hash, account identity or message.
The parent cannot infer subscription access from successful delivery alone.

`auth_login` starts a separate user service (900-second deadline, no restart,
stdout/stderr null, LimitCORE=0, 1GiB/128-task controller limit) with independent
180-second ExecStopPost cleanup. Candidate backend retains its own pinned
1GiB/200%-CPU/256-task limits; actual cgroup, executable, strict keyring config
and final HOME/CODEX_HOME are checked before login. Task-only scope prefix
`ditto-g3-auth-q<ID>` keeps it separate from the normal desktop's scopes.
Managed APIs are `agent.providers.login/status/cancel_login/logout`; they use the pinned
`chatgptDeviceCode` method, Unix socket transit only, strict keyring storage and
no auto/file fallback. Direct `codex login` is deliberately avoided because
[official authentication documentation](https://developers.openai.com/codex/auth)
notes direct login diagnostics. Official page snapshot is in durable
`physical/openai-auth-doc.html`; the exact0.160 native help/API gate remains
mandatory and is not inferred from newer documentation.

Code/URL/login response stays in memory and is sent once over mTLS. The provider
process stays alive for bounded **local provider** status polling; no Actions
status queries/timers are used. Neil opens the official URL and authenticates
directly to OpenAI, never returning password/token/callback to an agent. Official
device-code settings may require personal security/workspace-admin enablement.
On transport failure, signal, expiry or failed verification, cancel the exact
pending login, logout the sole fresh realm and read back unauthenticated before
stopping its task Core/backend scopes. Completed/unknown login is not revoked
by cancel:false or process exit. A failed logout/readback remains needs_human
with the original failure retained. No replacement code,
artifact/group fallback or login retry is issued for the same ID.

Pinned CodexBackend.status accepts only ChatGPT account type; fixture-model flag
and API-key inputs are absent. A login-complete receipt is separate from model
verification. One bounded synthetic no-tool request uses **gpt-6.1-sol/high**,
no fallback, 30s turn budget and the smallest supported tool-call budget (1).
Core turn/trace must show zero observed tools, the actual model/settings revision
must match, and private Profile/hash must remain unchanged. This is **observed
zero tools**, not an enforced zero-tool runtime: the pinned managed Agent still
advertises its discovered tools and retains existing Core authorization/sandbox
rules. Any observed tool, wrong model/method, unknown status, locked keyring or
failed minimal probe keeps launch closed. Account identity and model text are
not exported. Credentials remain solely reference Secret Service, keyed by the
same future CODEX_HOME; physical relogin never relocates it.

| Safe state | What it proves | Physical launch |
| --- | --- | --- |
| prepared | native Core initialized fixed schema5 realm; public client cert | refused |
| starting / awaiting_browser | detached auth service / code privately delivered | refused |
| login_complete | pinned managed status accepts ChatGPT subscription | refused |
| verified | exact minimal model/high, zero observed tools, native stopped, normal unchanged | admitted only with source/path/DB/service readbacks |
| blocked / needs_human | failed auth/probe or incomplete cleanup | refused; no retries |

`auth_status` exports these states/booleans, fixed model/source/id and the closed diagnostic fields described below.
TEST ONLY / fixture receipts are not admitted. Raw auth status, login_id, account
label, model response and code fields are never put in receipt/log/artifact.
Auth cleanup erases client cert/key before potentially slow native readback;
parent receiver erases its local key on terminal status/expiry. Installed source,
normal store and normal services remain untouched by authentication. Host-native
proof of pinned backend logging behavior, keyring and real cleanup is still
required: local logic/TLS tests cannot establish provider-internal behavior.

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

Normal recovery proves the test override absent and daemon reload successful
**before** normal relogin; both canonical copy and outer recovery gate login. It retains
the test autologin only until that login is attempted, then restores original
GDM bytes/permissions and checks normal schema4, installed source/executable,
relay template and Profile/hash. Private restoration is guarded by live
candidate executable/store readback and uses canonical APIs. Failure in one
recovery step does not skip subsequent normal rescue/runner restoration; it
leaves `needs_human`. Idempotent recovery is shared by finally and ExecStopPost.
Its result never erases the original failure or unfinished modes. Removed GDM/
override files alone cannot prove restoration: active intended seat, live normal
executable/store, relay, installed source and Profile must agree. If canonical
restoration removed autologin but normal login is incomplete, bounded authorized
relogin is attempted only after the removal/reload gate; failure is needs_human.
No new autologin setting or DB rollback is introduced. An abrupt
machine power loss/user-manager death is outside this transient unit's recovery
guarantee; retain task state for human recovery before normal use.

The runner is restored once, after all modes/failure cleanup. A collector
dispatch is possible only after verified recovery and all modes passed, using
the host's existing gh authentication, with no job tokens, polling or retries.
The branch head is checked against staged operation SHA; the collector also
refuses any workflow SHA mismatch. Host gh authentication is proven by inventory38583908188; it is rechecked at dispatch. A later missing auth or uncertain dispatch is
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
python3 -m py_compile tools/operational/g3_ops.py tools/operational/g3_auth.py tools/operational/g3_device_bridge.py
python3 tools/operational/g3_device_bridge.py selftest
bash -n tools/operational/build-g3.sh
git diff --check
```

Tests are TEST ONLY temporary file/SQLite/process fakes. They exercise real
rewrite, admission, witness, recovery, sanitizer and workflow boundary logic;
they establish no physical recovery, OS isolation or subscription result.
The standalone selftest binds loopback only and injects an in-memory TEST ONLY sender; it never invokes Hermes or a provider. Actual counts and logs for this extension are in durable `physical/auth-extension/gates/`. Native Core initialization, account login, model request, LAN bridge and physical recovery remain not_run in the writer session. Parent must review this implementation afresh, run real stage,
read the native host evidence and preserve recovery failures before claiming
any G3 requirement completed.

## Consolidated repair 1 — decisions before implementation

Review at 0e6a110bc0f00da8bfa50a7cbe423c71ab2bc36a is FAIL. This is the same
authorized operations repair, resumed after terminal provider503; no product
repair or native acceptance is implied. Tests below are TEST ONLY logic evidence.

| Class / state | Required transition / decision | Refusal outcome |
| --- | --- | --- |
| Auth pending / completed / unknown | cancel pending, logout possibly established sole fresh realm, read back unauthenticated before stop | original failure plus needs_human if revocation unproved |
| Owned cleanup | attempt every owned scope, exact Core cleanup, every final readback independently | aggregate all failures; no other PID signals |
| Agent starting | bounded ready wait before provider/settings consumers | failed/unknown/cancelled/deadline refuses, no retry |
| Normal NEED / NORMAL / UNKNOWN | executable/store/seat/relay provenance, then prove override gone and reload before login | no unsafe login; GDM/listener/runner cleanup still attempted |
| Worker alive / gone / reused / unreadable | independent original PID/start witness plus all Workers | reuse/unreadable/other Worker refuses pause |
| Bootstrap normal / private | pinned present normal helper vs explicit candidate helper, frozen outside _work | no private-to-normal fallback |

| Row | Unchanged-code counterexample (`test_ops_repair1.RepairCounterexamples`) | Sibling surfaces to close |
| --- | --- | --- |
| F1 | test_F1_completed_probe_failure_revokes | transport, expiry, method/status failure, final verified forwarding, abrupt cleanup |
| F2 | test_F2_cleanup_attempts_normal_after_scope_failure | all scopes, NativeCore.stop, pidfd/readbacks/key cleanup |
| F3 | test_F3_enter_waits_before_provider_status | NativeCore.ready, probe, auth status/logout |
| F4 | test_F4_remove_failure_forbids_relogin | canonical copy, outer finally, ExecStopPost, cached reload |
| F5 | test_F5_removed_files_do_not_prove_normal | canonical partial restore, normal seat/provenance, idempotency |
| F6 | test_F6_reused_nonworker_refuses | controller wait/pause, frozen Listener, dispatch |
| F7 | test_F7_fresh_normal_helper_exists | preflight/stage failure, detached recovery, private API targeting |

Existing crypto, quotas, templates and source17f remain pinned. If canonical GDM
restoration removed automatic login and live normal proof fails, bounded normal
relogin may fail and returns needs_human; no new autologin policy is introduced.
RED/GREEN logs and final gate counts live under physical/ops-repair1/gates.
Native initialization/auth/LAN/Home/model/physical remain not_run by this writer.

The normal relay resolver always uses hash-pinned `ops/bootstrap/tests/g1/lib/gui.py`
and `tools/compositor-probe/g1/wfipc.py`. These unchanged source17f bytes were
compared with installed d493's ABI and are recorded with source/path/hash in
preflight. Stage freezes them with ops before detached use; clone/build failure
cannot remove the baseline API path. Private desktop APIs explicitly use the
candidate helper after live candidate executable/store proof. Auth uses only
the fixed task Unix socket. There is no fallback from missing private candidate
to normal Core.

Every ensure→provider path shares bounded readiness readback. Revocation also
rechecks readiness because restoring disabled preferences stops Agent in17f.
Auth cleanup attempts every owned scope and each active/process readback, exact
Core pidfd cleanup, backend/Core readbacks and normal provenance independently.
Errors are aggregated and remain sticky. Pending/completed/unknown auth is
revoked through a still-live identity-bound task Core before resource stop when
possible. After an abrupt Core death, only a source/ops/path-bound, initialized
same realm may be reopened for formal logout/status, after owned processes are
proved stopped. This is recovery, with no login/model/network-delivery retry.
Unknown lifecycle or failed revocation/cleanup requires human inspection.
Receiver `verified` forwarding reports model verification; authoritative native
stopped/normal proof is still the local auth-state receipt after cleanup.

Repair evidence is under durable `physical/ops-repair1/gates`. The seven original
assertions fail on unchanged0e6a and pass with this implementation. Additional
transition-table tests exercise the sibling callers. Intermediate failures are
retained separately (old Listener fixture did not distinguish origin PID; one
TEST ONLY shell witness had a syntax error); these are not new baseline REDs.
The prior semantic FAIL and provider503 ledger remain unchanged. Independent
delta review is required before parent uses any native phase.

## Operations repair 2: scoped auth cleanup closure

Review2 at85b954e was FAIL for B1/B2/B3; F4–F7 were independently fixed and
are unchanged here. Durable `physical/ops-repair2/repair-plan.md` records the
pre-fix decisions and counterexample names. Commands/phases and receiver
crypto/quotas/templates remain unchanged.

| Class | Readback / transition | Production sibling callers audited | Tests |
| --- | --- | --- | --- |
| A/B1 | nonzero stop is clean only with explicit not-found/inactive/no cgroup; empty output is unknown, loaded stop failure/residue fails | owned_units, scope_snapshot, stop_scopes, scope_readbacks; NativeCore.stop prepare/supervisor exit and cleanup/ExecStopPost | test_ops_repair2.test_A_absent_scopes_prepare_and_repeated_cleanup; test_ops_repair2_surfaces.test_A_* |
| B/B2 | revoke may wait old draining→stopped, ensure same realm once, then starting→ready; failed/unknown/cancelled/deadline refuse | wait_ready, NativeCore.ready, device_flow, revoke, revoke_live_core, stopped-realm recovery, physical enter | test_ops_repair2.test_B_real_ready_drains_before_logout; test_ops_repair2_surfaces.test_B_* |
| C/B3 | one150s cleanup deadline inside180s unit limit; phase caps and reserved cleanup/normal/write tail; incomplete/expired steps persisted | cleanup journal, Host.command, source checks/hash/schema, NativeCore socket/start/reap, stop_owned_core, normal provenance | test_ops_repair2.test_C_total_deadline_persists_attempt_all; test_ops_repair2_surfaces.test_C_* |

Only revocation passes `for_revoke=True`; login/device_flow and physical enter
keep strict starting→ready admission. Prepare does not start Agent/backend;
its disabled initialization can now leave never-created scopes idempotently.
Probe still makes one request only; preference restoration may drain Agent,
and that legal old-generation transition no longer blocks logout. A second
drain after restart refuses; no login/model retry or alternate realm exists.

Cleanup phase caps sum140s with10s reserved for writes/overhead. Early auth/
scope work cannot spend the last60s; later recovery cannot spend the last25s
(normal readback15s plus write tail10s). Commands, the whole socket exchange,
readiness, child waits, source checks and SQLite busy waits use remaining
time. The existing auth-state is written fail-closed before effects and after
each phase: cleanup_in_progress, cleanup_pending, cleanup_steps and errors.
Budget exhaustion is explicit needs_human, never an inferred clean result.
A kill retains cleanup_incomplete and unattempted names; successful repeated
cleanup does not invent errors for reaped scopes. No new persistence layer.
Kernel/filesystem stalls and real unit/keyring behavior still need native host
proof; local virtual-clock tests establish cooperative budget/control logic.

Repair2 gates: 3 unchanged counterexamples RED(exit1)/GREEN(exit0), prior7
GREEN, full207 tests(exit0, including35 TLS tests), standalone35 loopback TLS
selftest(exit0; overlaps full suite), Python AST/compile, bash syntax, unchanged
manual workflow boundaries and git diff --check. Logs: durable
`physical/ops-repair2/gates/`. One intermediate full run retained failures
from old TEST ONLY adapters lacking the purpose flag/structured readback shape;
assertions for the three new RED tests remain byte-identical on GREEN.
Independent delta review remains required; real auth/Home/model/physical are
not_run and these gates do not certify physical readiness.

## Diagnostics 1: closed reasons and no-login reachability

Authority: durable `physical/auth-diagnostics-authority.md`. The observed old
qualification38668800746 is blocked with no model/login completion and proved
cleanup; zero receiver connections do not establish the cause. Preserve that
failure. This writer runs no live host/provider/Home action. Independent delta
review is required before parent uses these new phases.

| Row | Implementation / witness |
| --- | --- |
| D1 | login_payload validates URL/code/expiry/shape at their sites; Client reports TCP errno/type, SSL wrap/alert, peer pin and receiver refusal; test_ops_diag1.test_D1_* and test_ops_diag1_surfaces.test_D1_* |
| D2 | supervisor try includes Client construction, first reason stays sticky, last_marker advances only through fixed sites; test_D2_constructor_failure_recorded, test_D2_cleanup_failure_keeps_original_first_reason, test_D2_real_flow_markers_are_closed_and_secret_free |
| D3 | public_status constructs typed constants only; unknown fields become BLOCKED_UNLISTED_REASON, absent old fields are NOT_RECORDED/not_recorded; test_D3_* |
| D4 | auth_reason verifies existing staged source/file hashes with Git optional writes disabled, then reads only auth-state among private auth files; no Host, lock, normal readback, service, current-SHA equality or login; test_D4_* |
| E1 | probe.prepare/run/cleanup: own namespace, public-only cert,5min deletion lease, one request, key erasure readback; test_E1_* and test_probe_phase_real_client_receipt_proves_key_cleanup |
| E2 | prepare-probe/serve-probe and ProbeReceiverState accept only probe, never a sender; normal receiver rejects probe; test_probe_* loopback tests and test_E2_wrong_receiver_mode_never_touches_auth_receiver_keys |
| E3 | probe IDs/dirs refuse auth-root collisions in both directions; only workflow phase lists changed; test_E3_* |

Full closed sets are in [diagnostic-codes.json](diagnostic-codes.json), enforced
by g3_diagnostics.py. New diagnostic reasons are:

- BLOCKED_DEVICE_PAYLOAD_{URL,CODE,EXPIRY,SHAPE}.
- BLOCKED_MTLS_{TCP_TIMEOUT,TCP_REFUSED,NO_ROUTE,TCP_OTHER,HANDSHAKE,PEER_MISMATCH}.
- BLOCKED_RECEIVER_REFUSED, BLOCKED_TRANSPORT_EXPIRED,
  BLOCKED_DEVICE_LOGIN_PROVIDER, BLOCKED_UNLISTED_REASON.
- Existing fixed auth/native/probe-local guard reasons and cleanup codes are
  enumerated in the same catalog; arbitrary exception messages, paths, peer
  values, account, login_id, URL, user_code or hashes of codes are never exported.

Markers: not_recorded, supervisor_started, transport_ready, native_ready,
preauth_checked, login_requested, payload_validated, code_forwarded,
awaiting_browser, login_complete, probe_done; invalid→BLOCKED_UNLISTED_REASON.
Auth lifecycles: none/pending/completed/unknown/revoked; missing old value is
not_recorded, invalid is BLOCKED_UNLISTED_REASON. Missing old reason is
NOT_RECORDED; historical coarse reasons remain coarse, never inferred.
Cleanup's private per-unit witnesses are mapped to fixed cleanup codes.

These codes describe the observed failure boundary. An SSL error or a timeout
inside SSL wrap is HANDSHAKE; a reset/closure after the client handshake may be
RECEIVER_REFUSED (including late TLS1.3 client-certificate rejection). No code
claims an unobserved server policy or proves device login was disabled.

After review and parent publication, manually dispatch on the ops branch:

```sh
# Existing root; do NOT stage, prepare or log in again for this ID.
gh workflow run nightly-refmachine.yml --ref hermes/g3-physical-qualification \
  -f phase=auth_reason -f qualification_id=38668800746
```

The workflow invokes `python3 tools/operational/g3_ops.py auth_reason --id
38668800746`. Its phase.json contains only the allowlisted export. A mismatched
staged tree refuses. It reads the existing root with no cleanup-blocking lock
and permits the old staged ops SHA; every mutable auth/physical gate stays
unchanged. Do not infer missing markers from the old root.

Use a **different, never-used numeric PROBE_ID** for this no-login sequence.
The probe needs no stage/build/Core/realm/keyring/provider. Its root is
`/home/neil/.local/state/ditto-g3-qualification/bridge-probes/p<ID>`0700; client
keys are0600 under client/. An auth q<ID> or a prior probe tombstone refuses
ID reuse; a probe ID is never used for later authentication.

1. Manual workflow: phase=bridge_probe_prepare, qualification_id=PROBE_ID.
   Obtain its public preparation JSON from the authenticated runner. It has
   source/ops SHA, flow, certificate/fingerprint and expiry, no private key.
2. Parent, cwd and directory outside repo, using the reviewed absolute helper:

```sh
python3 /ABS/OPS/tools/operational/g3_device_bridge.py prepare-probe \
  --client-receipt /TASK/probe-prepare.json --directory /TASK/probe-receiver
python3 /ABS/OPS/tools/operational/g3_device_bridge.py serve-probe \
  --directory /TASK/probe-receiver
```

3. Use prepare-probe's **public JSON only** as auth_transport in a manual
   phase=bridge_probe workflow with that same PROBE_ID and same ops commit.
   Parent IP is fixed192.168.1.102; high task port is selected at preparation.
   Existing workflow transport label is retained; no new input is introduced.
4. Reference posts one fixed reachability-v1 body to /probe. Success requires
   TCP, mTLS, both peer pins and flow agreement. phase.json returns PROBE_OK
   plus keys_erased=true; failure returns only a closed code and erasure result.
   The parent probe receiver exits after one accepted request and also emits a
   public PROBE_OK/keys_erased receipt. Other paths refuse. No Home sender or
   provider is ever constructed by the probe.

Reference's frozen task cleanup lease deletes its client keys after290s even
if the probe job is abandoned; parent disposal/receiver expiry covers parent
keys. Neither lease queries Actions. Failed/expired attempts are single-use,
not retried; cleanup aliases refuse. No extra SSH/tunnel/service configuration.
PROBE_OK proves only current reachability at that selected endpoint. It neither
proves the cause of38668800746 nor subscription/model/physical readiness. Parent
must identify/remove the actual cause before the separately authorized ONE new
device-code request under another new auth ID. Stop rules remain unchanged.

RED/GREEN and gate evidence is under durable `physical/ops-diag1/gates/`.
Intermediate failures are retained, including the TLS1.3 late-rejection test
correction. The original four counterexamples remain byte-identical on GREEN.
Local tests are TEST ONLY; actual reverse route, receiver/host execution and
real provider diagnosis remain pending parent review/dispatch.

Diagnostics1 final local gates: original4 counterexamples RED exit1
(failures4/errors0) then byte-identical GREEN exit0; prior repair1=7, repair2=3
and repair2 surfaces=16 all exit0; full237 tests exit0; standalone selftest44
tests exit0 (includes real loopback TLS and overlaps the full suite). Python
AST/compile, bash syntax, YAML/embedded-shell parse, phase-only workflow diff
and git diff checks exit0. No native/live readiness claim.

## Diagnostics repair: preserve the first failure through cleanup

Review4 at c40e670 is FAIL for F1/F2; D1/D3/D4/E2/E3 remain closed.
Auth now records the first closed reason before revocation, context exit and
start-failure stop. NativeCore cleanup errors accumulate separately and force
needs_human; prepare and supervisor reload that state rather than overwriting
it with a wrapper error. Cleanup merges reopened-Core failures and retains an
earlier cause when marking an interrupted operation blocked.

| Row | Production siblings audited | Witness |
| --- | --- | --- |
| F1a | supervisor postflow/outer except/finally, device_flow revoke, NativeCore.__exit__/stop | test_ops_diag1_repair.test_F1_supervisor_postflow_then_exit_failure; repair_surfaces real_context_exit / successful_context_cleanup |
| F1b | NativeCore.__enter__ (Popen/witness/readiness), prepare wrapper/key erase, cleanup persist/attempt/reopened Core | test_F1_start_then_stop_failure; repair_surfaces popen_failure / auth_prepare_wrapper / cleanup_merges |
| F2 | probe run/finally, prepare failure/erase, cleanup and cleanup phase | test_F2_probe_transport_then_key_failure; repair_surfaces probe_prepare_failure / probe_success_transport |
| unchanged | minimal_probe original_failure/finally, device_flow first-reason update; g3_ops auth_supervise/auth_cleanup and constant-only outer reporting | existing repair/diagnostics suites plus closed catalog witness |

Probe `result` describes the transport outcome, including PROBE_OK even if
later deletion fails. Always inspect `keys_erased` and `cleanup_errors` too:
failed deletion returns false and BLOCKED_CLEANUP_PROBE_KEYS separately.
It is not a fully clean probe. The first transport result is persisted before
erasure. Probe prepare similarly persists its failure before attempting erase.
Only this cleanup constant is added; reasons, markers, TLS, routing, quotas,
workflow inputs, source17f and normal runtime are unchanged.

Evidence: durable `physical/ops-diag1-repair/gates/`. The three specified
counterexamples have no pre-filled reason and stay byte-identical RED→GREEN.
Sibling tests are TEST ONLY injected API/process/file failures. No native
account, Home, model or physical evidence is produced; independent delta review
is still required before parent use.

Diagnostics repair local gates: required RED3 exit1 (failures3/errors0),
byte-identical GREEN3 exit0; sibling8 exit0; prior five suites47 exit0;
full248 exit0; standalone bridge selftest44 exit0 (real loopback TLS plus
logic, overlapping full suite). Python AST/compile19 files, bash syntax,
workflow YAML/manual inputs/embedded shell and git diff --check all exit0.
No product/workflow bytes changed. These are logic and loopback evidence only.
