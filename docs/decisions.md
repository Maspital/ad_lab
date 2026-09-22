# Decision log

Design decisions with their rationale. Issues link here instead of restating decisions; when a
decision changes, change it here and note the date. Newest entries at the bottom.

Format per entry: **Decision** (what), **Why** (the reasoning that would have to be wrong to
reverse it), **Consequences** (what it forces elsewhere).

---

## D1 — The controller is a service, not a lab node (2026-09-22)

**Decision.** The controller is one Python package (`adlab`) that runs on an operator-controlled
Linux machine: the laptop for standalone use, a small management VM for cloud/RDP deployments. It
exposes a CLI (preflight, build, destroy, start/stop, snapshot, status) and the FastAPI service.
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
  validates only internal consistency (node refs, unknown plugins, sum of declared sizes against
  an optional declared budget).
- **HCP Vagrant dates.** HashiCorp's notice: no new boxes or registries after 1 Oct 2026;
  decommissioned 31 Dec 2026. The old lab's box dependency is dead by the end of 2026 either way.
