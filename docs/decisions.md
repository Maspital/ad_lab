# Decision log

Design decisions with their rationale. Issues link here instead of restating decisions; when a
decision changes, change it here and note the date. Newest entries at the bottom.

Format per entry: **Decision** (what), **Why** (the reasoning that would have to be wrong to
reverse it), **Consequences** (what it forces elsewhere).

---

## D1 — The controller is a service, not a lab node (2026-09-22)

**Decision.** The controller is one Python package (`adlab`) that runs on an operator-controlled
Linux machine: the laptop for standalone use, a small management VM for cloud/RDP deployments. It
exposes a CLI (preflight, build, destroy, rebuild, start/stop, reset, status) and the FastAPI
service. (Verb list amended 2026-09-22 per the D3 amendment: `reset` added, user-facing `snapshot`
removed.)
The controller is **not** modelled as a node in the lab config.

**Why.** The earlier "controller as a topology node" idea conflated two things: students must be
able to reach the controller (true), and the controller must live inside the lab (does not
follow). A controller needs two kinds of reach: libvirt on each host (local socket or
`qemu+ssh://`) and the guests' SSH ports for plugin application. Both are available from the host
or from any management VM. Modelling it as a lab node creates a bootstrap problem (something must
exist before the controller to create the controller) and forces a second host-side component
anyway.

**Consequences.** The default config has five nodes (DC, member server, workstation, attacker,
logserver). The CLI is a first-class deliverable of the scaffolding epic and the M1 driver. The API
binds only to the operator-facing interface, never to the lab bridge, so guests cannot reach it.

**Amendment (2026-09-22): start/stop/reset act on a VM or on the whole instance.** Each verb
takes a VM name or, without one, applies to every VM of the instance. Instance-level `reset`
(revert every VM to golden) is the student's fast "start over"; `rebuild` stays the slow path for
a changed config. *Why:* the operator's daily action on a laptop is "stop the lab", and the
student's is "start the exercise over"; both are loops over the per-VM primitives and cost
nothing to expose.

## D2 — Ownership is per lab instance; two deployment models (2026-09-22)

**Decision.** The unit of ownership and of lifecycle actions is the **lab instance**. Two
deployment models are targets:

1. **Standalone laptop.** The whole stack runs on one machine with one instance. Whoever sits at
   it is the operator; there is no student/instructor split to enforce.
2. **Central server.** One controller runs N instances on one KVM server (later OpenStack). Each
   instance has an owner; students reach their instance remotely (RDP/console) and the API in a
   student role.

The "instructor drives libvirt on every student laptop" mesh is **not** a target. The
"shared domain, one workstation per student" model is **not** a target.

**Why.** Standalone laptops are the likely near-term reality; a central server is the long-run
one. Both fit "instance has an owner" with single-host as the one-row case. The laptop mesh buys
central visibility at the cost of SSH into student machines, distributing tens of GB of images,
and Linux+KVM on every laptop, and standalone laptops deliver the same outcome without it.
Per-node ownership complicates reset semantics (reset must not touch the DC) for a model nobody
needs.

**Consequences.** RBAC models `instance.owner`. Multi-host (epic #8) targets one remote KVM
server, not a laptop fleet. **Secret sealing is enforceable only on a central server**: a student
with root on their own laptop can read VM disks and the overlay. Sealing stays in the API because
it is real on a server; standalone mode documents the limitation and only avoids casual exposure
in the UI and exports.

## D3 — Lifecycle states and reset semantics: golden snapshot (2026-09-22)

**Decision.** A lab instance moves through: `defined` → `provisioned` (VMs exist, OS booted, SSH
reachable) → `configured` (all plugins applied and verified) → **golden snapshot taken on every
VM** → `ready`. Runtime operations on a `ready` instance:

- **start / stop** a VM — provider runtime call.
- **reset** a VM — revert to its golden snapshot. Fast, keeps plugin state.
- **rebuild** the instance — destroy, recreate, reconfigure, re-snapshot.

**Why.** Reset is the action students need most and must be fast. Reverting to a
post-configuration snapshot avoids re-running plugins and re-joining the domain. Alternatives
(recreate a single VM; snapshot before plugins and reapply) are slower and make the domain-join
path the hot path for every reset.

**Consequences.** Snapshot/revert must work on UEFI+TPM Windows guests on libvirt; libvirt does
not support internal snapshots of pflash-firmware VMs, so the spike must settle external
snapshots or a libvirt version that handles it. OpenTofu must not track anything a snapshot revert
changes (see D5). Plugins are still idempotent — rebuild depends on it — but reset does not
exercise them.

**Amendment (2026-09-22): golden is the only snapshot.** There is no user-facing `snapshot` verb
in the CLI, the API (#6) or the UI (#7). `reset` always means "revert to golden". The provider
interface keeps `snapshot`/`revert` as primitives because the orchestrator uses them to take and
revert the golden snapshot. *Why:* a user-taken snapshot would leave "what does reset revert to"
undefined, and external-snapshot chains on UEFI guests are the hardest part of the Windows path;
nobody has asked for mid-exercise checkpoints. Named user snapshots can be added later without
breaking anything as long as golden stays the fixed base.

**Amendment (2026-09-22): a `ready` instance is immutable with respect to its config.** Enabling,
disabling or reconfiguring a plugin edits the config document; a built instance picks the change
up only through `rebuild`. There is no reconfigure-in-place transition. *Why:* the golden snapshot
is taken at `configured`; applying more plugins afterwards would either invalidate golden or
require a second snapshot generation, and #6's "plugin enable/configure" would otherwise invite
exactly that feature.

**Note (2026-09-22): golden state and revert.** Golden is the disk *plus* the UEFI nvram file
*plus* the swtpm state, never the qcow2 alone; the spike (#11) fixes the mechanism and the
minimum libvirt version (Ubuntu 24.04 ships 10.0.0, which supports neither internal snapshots
of UEFI guests nor external disk-only revert). Windows domains carry `<genid/>` so a revert of a
DC takes AD's VM-Generation-ID safe-restore path. Known limit: a domain member reverted to golden
after its machine-account password has rotated twice on the DC (default interval 30 days, so
roughly 60+ days of instance uptime) loses its domain trust; course-length labs never reach it,
and `rebuild` recovers.

## D4 — One guest transport: OpenSSH, including on Windows (2026-09-22)

**Decision.** Every guest, Windows included, exposes OpenSSH. Packer enables the built-in
Windows OpenSSH server in the image. Plugin application (Ansible is the likely runner) talks SSH
to all guests. WinRM is not configured.

**Why.** One transport for all nodes, no WinRM HTTPS listener and certificate setup in the image,
and it sidesteps the WinRM connection drops during domain join that the old lab documented at
length. Ansible supports Windows over SSH with a PowerShell shell type.

**Consequences.** The Windows-on-KVM spike must confirm SSH survives the DC promotion and domain
join reboots. Plugins must not assume WinRM-specific behaviour.

## D5 — OpenTofu for create/destroy; it is an implementation detail of a provider (2026-09-22)

**Decision.** OpenTofu (not Terraform) renders and applies the create/destroy of an instance's
VMs. It is invoked **inside** the provider implementation's `create`/`destroy`; nothing outside
`provisioning/` knows OpenTofu exists. Runtime actions (start/stop/snapshot/revert) go through the
provider's own runtime calls (libvirt API), never through OpenTofu.

**Why.** OpenTofu is licence-clean for a lab that may be handed to students and is drop-in
compatible with the libvirt provider. The claim that Terraform gives multi-provider "for free" is
overstated: a new provider is an OpenTofu module **plus** a Python runtime class, and the runtime
half is hand-written regardless. Making OpenTofu a peer abstraction to the provider interface
would leave two layers doing the same job.

**Consequences.** The provider interface owns create/destroy/start/stop/snapshot/revert/address.
State is stored per instance (path decided in epic #3; keyed by host+instance once #8 lands).
The state-drift boundary is: OpenTofu owns VM existence and static shape; the runtime owns power
state and disk contents.

## D6 — The logserver stays in the default config with a minimal M1 plugin (2026-09-22)

**Decision.** The default config keeps a logserver node. The base plugin set (epic #5) ships a
**minimal** observability baseline: a lightweight collector on the logserver and Windows event
forwarding from the domain members. Nothing heavier (Elastic stack, detection datasets) in M1.

**Why.** An observable default lab is worth the RAM; the old lab's stack was heavy and
version-fragile, not the idea of having one. Deciding now removes an open scope question from #5.

**Consequences.** Default sizing must fit guests into roughly 20 GB total on a 32 GB laptop. The
detection-dataset engine remains a future track.

## D7 — Controller persistence is SQLite; the config document stays lab-facts only (2026-09-22)

**Decision.** Runtime state that is not a lab fact — jobs and their logs, plugin applied-markers,
instances and owners, the host registry, users and tokens — lives in a SQLite database owned by the
controller. The lab config document holds only what describes a lab.

**Why.** "One config document is the source of truth" is about lab facts. Runtime state needs a
store with transactions and concurrent readers; SQLite is zero-ops and fits a single controller.

**Consequences.** Scaffolding (epic #1) picks the ORM/migration tooling. Nothing writes lab facts
anywhere but the config document.

## D8 — Plugin graph metadata: #4 reserves the seam, #9 owns the shape (2026-09-22)

**Decision.** The plugin contract carries an optional, versioned `graph` extension slot. Its
schema is owned by the attack-graph epic (#9) and defined there, against synthetic examples. The
plugin framework (#4) only guarantees the slot exists and is passed through.

**Why.** Freezing the shape in #4 without a consumer and without weakness plugins to inform it
would be speculative design.

## D9 — Small clarifications (2026-09-22)

- **Attacker seat.** A stock Kali image as the `attacker` node is a student's seat, not a
  deliberate weakness, and is in scope for the weakness-free lab.
- **Round-trip.** Config import/export is **semantically** stable (load → dump → load yields an
  equal model). Byte-stable YAML is not a goal; comments and ordering are not preserved.
- **Plugin parameters in the schema.** The config schema (epic #2) treats each plugin's parameter
  block as an opaque mapping keyed by plugin name; the plugin framework (epic #4) adds the hook
  that validates it against the plugin's own schema.
- **Host budget guard** lives in provisioning (epic #3), which has host facts. The schema
  validates only internal consistency (node refs, sum of declared sizes against an optional
  declared budget). *(Amended 2026-09-22:)* the unknown-plugin check needs a plugin registry,
  which only the plugin framework (epic #4) has; #4 adds it together with the parameter-validation
  hook. Epic #2 does not check plugin names.
- **HCP Vagrant dates.** HashiCorp's notice: no new boxes or registries after 1 Oct 2026;
  decommissioned 31 Dec 2026. The old lab's box dependency is dead by the end of 2026 either way.

## D10 — One Python package; asset directories stay top-level (2026-09-22)

**Decision.** All Python lives in one package at `src/adlab/` with subpackages `controller`,
`provisioning` and `plugins` that mirror the layout in `CLAUDE.md`. The top-level `provisioning/`
and `plugins/` directories hold non-Python assets only: Packer templates and OpenTofu modules under
`provisioning/`, plugin bundles (manifest plus Ansible content) under `plugins/`. There is no
top-level `controller/` directory; the control plane is `adlab.controller`.

**Why.** The `adlab` CLI and API must import the provider runtime classes and the plugin engine,
so Python spanning three top-level directories would need either three packages or a
`package-dir` mapping that editable installs, mypy and pytest handle poorly. One `src/` package
is what every tool expects. Putting provider classes inside the controller instead would break
the rule that nothing outside provisioning knows which provider is in use.

**Consequences.** The "nothing outside `provisioning/` knows the provider" rule applies to both
`adlab.provisioning` and the asset directory. The Windows spike's Packer template (#11) lands in
`provisioning/packer/` as planned. `pyproject.toml` sits at the repo root.

## D11 — The instance record, the build orchestrator and placement belong to provisioning (2026-09-22)

**Decision.** Epic #3 owns three things that M1 needs and that were previously assigned to the
M2 API epic:

1. A **minimal instance record** in SQLite: id, name, the config it was built from, its lifecycle
   state (D3), and its **host** (`localhost` in M1). Epic #6 adds `owner` and jobs; epic #8 makes
   the host selectable.
2. The **build orchestrator**: the code that drives an instance through D3's states —
   `create_instance` → wait for SSH → *plugin application hook* → golden snapshot → `ready` — and
   the `destroy` and `rebuild` sequences. Epic #4 fills the plugin hook; it does not own the
   sequence.
3. **The empty plugin set is trivially `configured`.** With no plugins enabled, `configured`
   follows `provisioned` immediately, so #3 alone takes golden snapshots and tests `reset` before
   #4 exists.

**Placement is an instance attribute, not a config fact.** The lab config document carries no
`host` field.

**Why.** `adlab build` (M1) creates an instance, OpenTofu state is kept per instance, and plugin
applied-markers are keyed by instance, so an instance identity cannot wait for M2. Without an
owner for the orchestrator, #3 and #4 each half-own it and #3's golden-snapshot step cannot be
tested until #4 lands (a hidden cycle: #4 depends on #3). On a central server the same config
builds N instances, and an instructor may build a test instance locally from that same config;
where an instance runs is runtime state (D7), not a description of the lab.

**Consequences.** `CLAUDE.md`'s "one config document" rule no longer lists host. Epic #2 and its
slice #13 drop the `host` field. Epic #6's first slice is "jobs and the API over #3's instance
model", not "instance + job model". Epic #8 assigns a host to an instance at creation.

## D12 — Concurrency model: async FastAPI, blocking work off the event loop (2026-09-22)

**Decision.** The API is async FastAPI. Anything that blocks — libvirt calls, `tofu`, `packer`,
Ansible, SSH — runs off the event loop (thread pool or subprocess), never inline in a request
handler. The CLI drives the same domain code synchronously.

**Why.** libvirt-python and the external binaries are blocking; one build inline would freeze
every other request, including the health check and streaming job logs that #6 needs.

## D13 — The SPA is served same-origin by the API (2026-09-22)

**Decision.** The FastAPI app serves the built SPA as static files from `webui/dist` on the same
origin as the API. No separate web server, no CORS configuration in the default deployment.

**Why.** One process to run and one port to expose keeps the operator-facing surface (D1) a
single bind address, and it removes a class of cookie and CORS problems for the auth slice of #6.

## D14 — Toolchain for the controller package (2026-09-22)

- **CLI framework:** Typer (Click underneath). Sub-apps give `adlab config …`, `adlab …` groups
  for free and the type-hint style matches Pydantic.
- **Project tool:** `uv`, with `uv.lock` committed. The package stays plain `pip install -e .`
  compatible; `uv` is a convenience, not a requirement.
- **Type checking:** mypy on the package, non-strict, in pre-commit and CI.
- **Python:** 3.12 only in CI.
- **Lint/format:** ruff. **Tests:** pytest.

## D15 — Config schema clarifications (2026-09-22)

- **`role` is a closed `StrEnum`** (`dc`, `member-server`, `workstation`, `attacker`,
  `logserver`). Extending it means adding a member. A free string would lose the JSON Schema
  `enum` the web UI's forms depend on.
- **`os` is `windows | linux`; `image` is a free string** naming a Packer image. Consumers need
  the shell family (PowerShell vs sh for Ansible) and which image to boot; an `os.version` would
  duplicate what the image name carries. No cross-validation of `image` until #3 owns an image
  list.
- **`domain` is required** for `dc`, `member-server` and `workstation`; **optional** for
  `attacker` and `logserver`. No plugin joins Linux to the domain and none is scoped to.
- **Static addressing.** A node's network attachment is `{network, ip}` with `ip` optional,
  validated inside the network's CIDR and unique per network. The default fixture pins all five
  nodes. The provider (#3) realises pins as libvirt DHCP host reservations; DHCP is always on and
  the schema has no toggle for it *(amended 2026-09-22: nothing implements the off branch)*.
  *Why:* the DC is the members' DNS server; a fresh DHCP lease after a golden-snapshot reset must
  not move it. The fixture CIDR must not collide with libvirt's stock `default` network
  (192.168.122.0/24); libvirt refuses to start a network whose subnet overlaps one already on the
  host.
- **Default network mode is `nat`.** A libvirt NAT network is private from the LAN, the host
  reaches guests over the bridge, and guests have egress for package installs at plugin time
  (collector on the logserver, Kali updates). `isolated` stays available; choosing it means every
  package must be baked by Packer.
- **The generation seed is a secret.** Users, groups and share content in #5 derive from a seed;
  the seed is a secret-marked config field (#2, second slice) and is stripped from student
  exports, otherwise the export reproduces every password.
- **Small fixed values.** `schema_version` is an integer starting at 1. The default fixture
  ships as package data so `adlab config show` works outside a checkout. The libvirt provider
  block has no required keys in #13. The default fixture declares `budget.ram_mb: 20480`.
