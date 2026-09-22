# Decision log

Design decisions with their rationale. Issues link here instead of restating decisions; when a
decision changes, change it here and note the date. Newest entries at the bottom.

Each entry has a stable anchor (`#d3`), so links never depend on the heading text. Format:
**Decision** (what) and **Why** (the reasoning that would have to be wrong to reverse it), plus
**Consequences** (what it forces elsewhere) where they are not obvious. Short entries may be a
bullet list.

---

<a id="d1"></a>
## D1 — The controller is a service, not a lab node

*2026-09-22*

**Decision.** The controller is one Python package (`adlab`) that runs on an operator-controlled
Linux machine: the laptop for standalone use, the KVM host itself in the central-server model
(D17), a small management VM for cloud deployments. It exposes a CLI and the FastAPI service. The
CLI verbs are `preflight`, `smoke`, `config …`, `image …`, `create`, `build`, `destroy`,
`rebuild`, `start`, `stop`, `reset`, `status`, `api`, `version` (the instance verbs are defined
in D11). `start`, `stop`, `reset` and `status` take `<instance> [vm]`: with a VM name they act on
that VM, without one on every VM of the instance. Instance-level `reset` (revert every VM to
golden) is the student's fast "start over"; `rebuild` is the slow path for a changed config.
The controller is **not** modelled as a node in the lab config.

**Why.** The earlier "controller as a topology node" idea conflated two things: students must be
able to reach the controller (true), and the controller must live inside the lab (does not
follow). A controller needs two kinds of reach: libvirt on each host (local socket or
`qemu+ssh://`) and the guests' SSH ports for plugin application. Both are available from the host
or from any management VM. Modelling it as a lab node creates a bootstrap problem and forces a
second host-side component anyway. The operator's daily action on a laptop is "stop the lab" and
the student's is "start the exercise over"; both are loops over the per-VM primitives.

**Consequences.** The default config has five nodes (DC, member server, workstation, attacker,
logserver). The CLI is a first-class deliverable of the scaffolding epic and the M1 driver. The
API binds only to the operator-facing interface (loopback by default), never to a lab bridge.
**The bind address alone does not isolate the API from guests:** a guest on a NAT network reaches
every address the host owns, so on any deployment where the API listens on a LAN address, a host
firewall rule drops traffic from the lab bridges (`virbr+`) to the host except DHCP and DNS.
Epic #8 owns that rule; the host-prerequisites doc records it.

<a id="d2"></a>
## D2 — Ownership is per lab instance; two deployment models

*2026-09-22*

**Decision.** The unit of ownership and of lifecycle actions is the **lab instance**. Two
deployment models are targets:

1. **Standalone laptop.** The whole stack runs on one machine with one instance. Whoever sits at
   it is the operator; there is no student/instructor split to enforce.
2. **Central server.** One controller runs N instances on one KVM server (later OpenStack). Each
   instance has an owner; students reach their instance remotely and the API in a student role.

The "instructor drives libvirt on every student laptop" mesh is **not** a target. The
"shared domain, one workstation per student" model is **not** a target.

**Why.** Standalone laptops are the likely near-term reality; a central server is the long-run
one. Both fit "instance has an owner" with single-host as the one-row case. The laptop mesh buys
central visibility at the cost of SSH into student machines, distributing tens of GB of images,
and Linux+KVM on every laptop, and standalone laptops deliver the same outcome without it.
Per-node ownership complicates reset semantics (reset must not touch the DC) for a model nobody
needs.

**Consequences.** RBAC models `instance.owner`. Epic #8 targets one central KVM server with the
controller on it (D17), not a laptop fleet. **Secret sealing is enforceable only on a central server**: a student
with root on their own laptop can read VM disks and the controller's database. Sealing stays in
the API because it is real on a server; standalone mode documents the limitation and only avoids
casual exposure in the UI and exports.

<a id="d3"></a>
## D3 — Lifecycle states, golden snapshot, reset semantics

*2026-09-22*

**Decision.** A lab instance moves through: `defined` → `provisioned` (VMs exist, OS booted, SSH
reachable) → `configured` (all plugins applied and verified) → **golden snapshot taken on every
VM** → `ready`. Runtime operations on a `ready` instance (per VM or per instance, D1):

- **start / stop** — provider runtime call.
- **reset** — revert to the golden snapshot. Fast, keeps plugin state.
- **rebuild** (instance only) — destroy, recreate, reconfigure, re-snapshot.

**Golden is the only snapshot.** There is no user-facing `snapshot` verb in the CLI, the API (#6)
or the UI (#7); `reset` always means "revert to golden". The provider interface keeps
`snapshot`/`revert` as primitives for the orchestrator.

**A `ready` instance is immutable with respect to its config.** Enabling, disabling or
reconfiguring a plugin edits the config document; a built instance picks the change up only
through `rebuild`. There is no reconfigure-in-place transition.

**Failure and resume.** The state list is the happy path. A build that fails leaves the instance
in the last state it reached, with the failure recorded on the instance record; `build` on any
non-`ready` instance resumes the orchestrator from that state (plugins are idempotent, so this is
cheap); `destroy` and `rebuild` are valid from every state. Plugin applied-markers are deleted
with the instance row.

**Golden state.** Golden is the guest disk *plus* the UEFI nvram *plus* the swtpm state, never
the qcow2 alone. libvirt's own snapshot paths do not cover all three: neither internal nor
external snapshots include swtpm state, and external snapshots do not include nvram. The spike
(#11) therefore decides the mechanism, the minimum libvirt version, **whether golden can exclude
the swtpm state** (tolerable only if nothing in the guest depends on the TPM after revert) and
**the controller's privilege model** (which files under `/var/lib/libvirt` it may touch, if any).
That result becomes a decision entry before #3's snapshot slice.

**Why.** Reset is the action students need most and must be fast. Reverting to a
post-configuration snapshot avoids re-running plugins and re-joining the domain. Alternatives
(recreate a single VM; snapshot before plugins and reapply) make the domain-join path the hot
path for every reset. A user-taken snapshot would leave "what does reset revert to" undefined,
and snapshot chains on UEFI guests are the hardest part of the Windows path; named user snapshots
can be added later as long as golden stays the fixed base. Applying plugins after golden would
either invalidate golden or require a second snapshot generation.

**Consequences.** OpenTofu must not track anything a revert changes (D5). Plugins are still
idempotent (rebuild and resume depend on it) but reset does not exercise them. Known limit: a
domain member reverted to golden after its machine-account password has rotated twice on the DC
(default interval 30 days) loses its domain trust; course-length labs never reach it and
`rebuild` recovers.

<a id="d4"></a>
## D4 — One guest transport: OpenSSH, including on Windows

*2026-09-22*

**Decision.** Every guest, Windows included, exposes OpenSSH. Packer enables the built-in
Windows OpenSSH server in the image. Plugin application (Ansible) talks SSH to all guests. WinRM
is not configured. Key management is D20.

**Why.** One transport for all nodes, no WinRM HTTPS listener and certificate setup in the image,
and it sidesteps the WinRM connection drops during domain join that the old lab documented at
length. Ansible supports Windows over SSH with a PowerShell shell type.

**Consequences.** The Windows-on-KVM spike must confirm SSH survives the DC promotion and the
domain join reboots. Plugins must not assume WinRM-specific behaviour; anything that is WinRM
under the hood (Windows Event Forwarding, for example) is out. **A key-based SSH logon on Windows
carries no network credentials** (Windows OpenSSH, by design): a task that authenticates onward
(AD cmdlets, SMB, LDAP) runs with `become: runas` and the per-instance administrator password (D20)
or passes explicit module credentials. The spike (#11) confirms both paths.

<a id="d5"></a>
## D5 — OpenTofu for create/destroy; it is an implementation detail of a provider

*2026-09-22*

**Decision.** OpenTofu (not Terraform) renders and applies the create/destroy of an instance's
VMs. It is invoked **inside** the provider implementation's `create_instance`/`destroy_instance`;
nothing outside `adlab.provisioning` and `provisioning/` knows OpenTofu exists. Runtime actions
(`start`, `stop`, `snapshot`, `revert`, `address`, `status`) go through the provider's own
runtime calls (libvirt API), never through OpenTofu. The libvirt OpenTofu provider is pinned at
0.9.1 or newer (the first version that undefines with the NVRAM and TPM flags and exposes
firmware, nvram format, generation id and TPM natively).

**Considered alternative: libvirt-python for create/destroy too.** The smoke path (#1) will
create a domain, network, volume and cloud-init seed with raw libvirt-python, and the provider's
runtime class reuses that code, so OpenTofu is a second implementation of "produce this domain
XML". It is kept for now for declarative, dependency-ordered create/destroy of a whole instance
and a state file that inventories what exists independently of the controller database.

**Kill criterion.** OpenTofu is dropped in favour of libvirt-python if #11 Q6 finds either: `tofu
plan` cannot be kept clean with the snapshot method that #11 Q4 selects for golden-state
correctness (`lifecycle.ignore_changes` on the affected attributes is an acceptable way to keep it
clean), or the libvirt provider cannot express the firmware posture (D19), the nvram template and
the TPM device. The verdict is #11's alone. **The snapshot method is chosen for correctness of
golden state, never to satisfy OpenTofu.**

**Why.** OpenTofu is licence-clean for a lab that may be handed to students and is drop-in
compatible with the libvirt provider. The claim that it gives multi-provider "for free" is
overstated: a new provider is an OpenTofu module **plus** a Python runtime class, and the runtime
half is hand-written regardless. Making OpenTofu a peer abstraction to the provider interface
would leave two layers doing the same job. OpenTofu reconciles to desired state and fights
out-of-band changes, which is why it is never used for runtime control.

**Consequences.** The provider interface owns `create_instance`, `destroy_instance` and per-VM
`start`, `stop`, `snapshot`, `revert`, `address`, `status`. OpenTofu state is stored per instance
under a controller-owned directory, keyed by (host, instance). The drift boundary: OpenTofu owns
VM existence and static shape (disks, NICs, firmware, sizing); the runtime owns power state,
snapshots and disk contents; the module ignores power state. OpenTofu is never *applied* against
a `ready` instance except to destroy it (`tofu plan` runs read-only as the drift check in #3's
`realvirt` tests), and `destroy_instance` deletes the golden snapshot before
`tofu destroy`, because libvirt refuses to undefine a domain that still has snapshots. Plugin
inventory addresses come from the provider's `address`, never from the config document.

<a id="d6"></a>
## D6 — The logserver stays in the default config with a minimal M1 plugin

*2026-09-22*

**Decision.** The default config keeps a logserver node. The base plugin set (epic #5) ships a
**minimal** observability baseline: a lightweight collector on the logserver and a log-shipping
agent on the Windows domain members (not Windows Event Forwarding, which is WinRM-based, D4).
Nothing heavier (Elastic stack, detection datasets) in M1.

**Why.** An observable default lab is worth the RAM; the old lab's stack was heavy and
version-fragile, not the idea of having one.

**Consequences.** Default sizing must fit guests into roughly 20 GB total on a 32 GB laptop. The
detection-dataset engine remains a future track.

<a id="d7"></a>
## D7 — Controller persistence is SQLite; the config document stays lab-facts only

*2026-09-22*

**Decision.** Runtime state that is not a lab fact — jobs and their logs, plugin applied-markers,
instances and owners, the host registry, users and tokens, guest credentials (D20) — lives in a
SQLite database owned by the controller. The lab config document holds only what describes a lab.

**Why.** "One config document is the source of truth" is about lab facts. Runtime state needs a
store with transactions and concurrent readers; SQLite is zero-ops and fits a single controller.

**Consequences.** Scaffolding (epic #1) picks the ORM/migration tooling. Nothing writes lab facts
anywhere but the config document.

<a id="d8"></a>
## D8 — Plugin graph metadata: #4 reserves the seam, #9 owns the shape

*2026-09-22*

**Decision.** The plugin contract carries an optional, versioned `graph` extension slot. Its
schema is owned by the attack-graph epic (#9) and defined there once the first weakness plugins
exist to inform it (M3); synthetic examples serve only as test fixtures. The plugin framework (#4)
only guarantees the slot exists and is passed through.

**Why.** Freezing the shape in #4 without a consumer and without weakness plugins to inform it
would be speculative design.

<a id="d10"></a>
## D10 — One Python package; asset directories stay top-level

*2026-09-22*

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
`provisioning/packer/`. `pyproject.toml` sits at the repo root.

<a id="d11"></a>
## D11 — The instance record, the build orchestrator and placement belong to provisioning

*2026-09-22*

**Decision.** Epic #3 owns three things that M1 needs:

1. The **instance record** in SQLite: id, unique name, a frozen copy of the config it was built
   from (so "config changed since build" is decidable), lifecycle state and failure detail (D3),
   the **host** (`localhost` in M1; selectable in #8), the per-network CIDR overrides (D16), and
   the image versions it was built from (D21). Epic #6 adds `owner` and jobs.
2. The **build orchestrator**: the code that drives an instance through D3's states —
   `create_instance` → wait for SSH → credential swap and hostname (D20; each guest gets its
   `node.name` as hostname, one reboot, so names are final before any plugin runs) → *plugin
   application hook* → golden snapshot → `ready` — plus `destroy` and `rebuild`, and resume from
   any non-`ready` state.
   Epic #4 fills the plugin hook; it does not own the sequence.
3. **The empty plugin set is trivially `configured`**, so #3 alone takes golden snapshots and
   tests `reset` before #4 exists.

**Verbs.** `create` writes the record in `defined` with name, host and CIDR overrides. `build
<instance>` drives it to `ready`, or resumes it. `adlab build <config>` without an instance does
both and names the instance after the config. `destroy` removes the VMs and the record, reading
only the OpenTofu state and the instance-prefixed provider objects, never the frozen config.
`rebuild <instance> [config]` is destroy plus build on the same record from the given document,
defaulting to the frozen copy; image versions are re-resolved to the newest in the image store
(D21) and re-recorded.

**Instance-scoped resource names.** Every provider object an instance creates (domains, networks,
volumes, nvram and TPM state paths, OpenTofu state) carries the instance id in its name, so N
instances of one config coexist on one host. Retrofitting this would mean destroying and
recreating every instance, so it is in from slice 1.

**Placement is an instance attribute, not a config fact.** The lab config document carries no
`host` field.

**Why.** `adlab build` creates an instance, OpenTofu state is kept per instance, and plugin
applied-markers are keyed by instance, so an instance identity cannot wait for M2. Without an
owner for the orchestrator, #3 and #4 each half-own it and #3's golden-snapshot step cannot be
tested until #4 lands. On a central server the same config builds N instances, and an instructor
may build a test instance locally from that same config; where an instance runs is runtime state
(D7), not a description of the lab.

<a id="d12"></a>
## D12 — Concurrency model: async FastAPI, blocking work off the event loop

*2026-09-22*

**Decision.** The API is async FastAPI. Anything that blocks — libvirt calls, `tofu`, `packer`,
Ansible, SSH — runs off the event loop (thread pool or subprocess), never inline in a request
handler. The CLI drives the same domain code synchronously. Every mutating verb takes a
per-instance lock (one mutating operation per instance at a time). The lock is cross-process — an
`flock` on the instance's state directory, released on process death — because the CLI and the
API are separate processes over one database; #3 slice 1 takes it around every mutating verb, and
the job runner (#6) wraps the same lock and bounds concurrent jobs per host.

**Why.** libvirt-python and the external binaries are blocking; one build inline would freeze
every other request, including the health check and streaming job logs that #6 needs. On a
central server a student can otherwise `reset` an instance whose `rebuild` is mid-flight, and N
students can start N builds at once.

<a id="d13"></a>
## D13 — The SPA is served same-origin by the API

*2026-09-22*

**Decision.** The FastAPI app serves the built SPA as static files from `webui/dist` on the same
origin as the API. No separate web server, no CORS configuration in the default deployment. The
mount is added by the first web-UI slice (#7), not by scaffolding.

**Why.** One process to run and one port to expose keeps the operator-facing surface (D1) a
single bind address, and it removes a class of cookie and CORS problems for the auth slice of #6.

<a id="d14"></a>
## D14 — Toolchain for the controller package

*2026-09-22*

- **CLI framework:** Typer (Click underneath). Sub-apps give `adlab config …`, `adlab image …`
  groups for free and the type-hint style matches Pydantic.
- **Project tool:** `uv`, with `uv.lock` committed. The package stays plain `pip install -e .`
  compatible; `uv` is a convenience, not a requirement.
- **Type checking:** mypy on the package, non-strict, in pre-commit and CI.
- **Python:** 3.12 only in CI.
- **Lint/format:** ruff. **Tests:** pytest. Real-virtualization tests carry a `realvirt` marker,
  are skipped by default, and run in a separate manually triggered workflow that #1's smoke slice
  creates with `adlab smoke` as its first job.
- **Ansible:** `ansible-core` is a pinned Python dependency of the `adlab` package; collections
  (`microsoft.ad` for domain work — the `ansible.windows` `win_domain*` modules were removed —
  plus `ansible.windows`, `community.windows`, …) come from a committed `requirements.yml`
  installed at setup. It is not a host binary and preflight does not check for it. *Why:* distro
  `ansible-core` versions vary widely and Windows-over-SSH support is version sensitive; one
  pinned version in the venv is reproducible. Whether the engine calls it via `ansible-runner` or
  a subprocess is #4's call.

<a id="d15"></a>
## D15 — Config schema clarifications

*2026-09-22*

- **`role` is a closed `StrEnum`** (`dc`, `member-server`, `workstation`, `attacker`,
  `logserver`). Extending it means adding a member. A free string would lose the JSON Schema
  `enum` the web UI's forms depend on.
- **`os` is `windows | linux`; `image` is a free string** naming a Packer image. Consumers need
  the shell family (PowerShell vs sh for Ansible) and which image to boot; an `os.version` would
  duplicate what the image name carries. `image` is cross-validated against the image store (D21)
  once #3 has one.
- **`domain` is required** for `dc`, `member-server` and `workstation`; **optional** for
  `attacker` and `logserver`. No plugin joins Linux to the domain and none is scoped to. A domain
  has `name` and `netbios`; forests and trusts are not modelled until a plugin needs them.
- **Static addressing.** A node's network attachment is `{network, ip}` with `ip` optional,
  validated inside the network's CIDR and unique per network. The default fixture pins all five
  nodes. The provider (#3) realises pins as libvirt DHCP host reservations; DHCP is always on and
  the schema has no toggle for it (nothing implements the off branch). *Why:* the DC is the
  members' DNS server; a fresh DHCP lease after a golden-snapshot reset must not move it. The
  fixture CIDR must not collide with libvirt's stock `default` network (192.168.122.0/24); D16
  explains why.
- **`disk_gb` is the overlay's virtual size** (D21), a ceiling on overlay growth. Provisioning (#3)
  cross-validates it against the image store: at least the image's virtual size. Nothing grows the
  guest's partition; a larger value is spare capacity only.
- **Default network mode is `nat`.** A libvirt NAT network is private from the LAN, the host
  reaches guests over the bridge, and guests have egress for package installs at plugin time.
  `isolated` stays available; choosing it means every package must be baked by Packer.
- **Plugin parameters are opaque to the schema.** Each plugin's parameter block is an opaque
  mapping keyed by plugin name; the plugin framework (#4) adds the hook that validates it against
  the plugin's own schema and the check that the plugin name is known (both need the plugin
  registry, which only #4 has). Epic #2 does not check plugin names.
- **The generation seed is a top-level secret field.** Users, groups and share content in #5
  derive from `seed`, a top-level, secret-marked config field (#2, second slice). It is top-level
  and not a plugin parameter because the secret marker must reach it without #4's schema hook.
  It is stripped from student exports, otherwise the export reproduces every password.
- **Round-trip is semantic.** Load → dump → load yields an equal model. Byte-stable YAML is not a
  goal; comments and ordering are not preserved.
- **Budget checks.** The schema validates only internal consistency: node refs, and the sum of
  declared node RAM against the optional declared `budget.ram_mb` (a design budget the author
  types, not a host fact). The guard against real host facts lives in provisioning (#3).
- **Small fixed values.** `schema_version` is an integer starting at 1. The default fixture
  ships as package data so `adlab config show` (path optional) works outside a checkout.

<a id="d16"></a>
## D16 — Per-instance network CIDR override

*2026-09-22*

**Decision.** The CIDR in the config document is the network's *default*. At instance creation
each network's CIDR may be overridden; the override is stored on the instance record (D11) and is
an instance attribute, never a config fact. Pinned node IPs (D15) keep their host part and are
rebased onto the effective prefix. The provider renders the OpenTofu module from the instance's
effective networks, never from the config directly. Standalone use never sets an override; #8
chooses one per instance on a central server.

**Why.** libvirt refuses to start a network whose subnet overlaps one already routed on the host
(`Network is already in use by interface virbrX`), and isolated mode does not escape the check
because the bridge still carries the gateway address for DHCP. So N instances of one config on
one KVM host (D2, D11) cannot share a CIDR. Deriving N configs by hand contradicts "the same
config builds N instances"; an automatic pool allocator needs pool configuration and allocation
state for a problem the operator can solve with one field. A pool allocator can be added later on
top of the override.

<a id="d17"></a>
## D17 — Central-server model: the controller runs on the KVM host

*2026-09-22*

**Decision.** In the central-server deployment (D2), the `adlab` controller runs on the KVM host
itself, not on a separate management VM. Epic #8 owns everything about reaching guests behind
their per-instance NAT networks: plugin SSH from the controller, ProxyJump via the host's SSH for
a genuinely remote KVM host, and the student access path to both the `attacker` node (the
student's seat) and the `workstation` (a libvirt graphical console proxied through the controller,
or documented RDP port forwarding; the slice decides).

**Why.** Guests on a NAT network are reachable only from the host that owns the bridge. A
controller anywhere else needs an SSH hop for every plugin run and log stream, and students'
machines cannot reach a NAT'd workstation at all. Running on the host collapses the first
problem; the second needs a deliverable, which #8 owns.

**Consequences.** #8's student-access slice delivers the D1 firewall rule; on the KVM host the
API listens on a LAN address, so the rule is mandatory there.

<a id="d18"></a>
## D18 — Windows evaluation clock: rearm plugin and image-age warning

*2026-09-22*

**Decision.** A small weakness-free base plugin (#5) runs `slmgr /rearm` on every Windows node
before the golden snapshot and verifies the remaining evaluation days. Provisioning (#3) records
an image's build date in the image store (D21) and its budget guard warns when a Windows image is
older than the evaluation period minus a margin. The spike (#11) documents the eval length and
the rearm limit.

**Why.** Evaluation media expire a fixed number of days after installation, which is the Packer
build, not the instance build; a golden snapshot freezes nothing about that clock. An image built
once and used months later hands a course a lab that dies mid-way. Rearming is an in-guest change
and so belongs in a plugin with a verifier, not in the orchestrator. The mechanism does not
depend on the exact numbers, which #11 supplies.

**Sysprep interaction.** Windows images end in `sysprep /generalize` (D21). Without `SkipRearm`
that consumes one rearm in the image and restarts the evaluation clock at each instance's first
boot, which moves the clock the warning must track from image age to instance age. #11 Q2
records which applies; the plugin and the warning follow that finding.

**Consequences.** #5 gains a slice; #3's budget guard gains a check. Rearms are finite, so the
warning still matters after the plugin exists.

<a id="d19"></a>
## D19 — One firmware mode: every guest boots UEFI

*2026-09-22*

**Decision.** Every guest, Linux included, boots UEFI (OVMF) so there is exactly one
snapshot/revert path. Windows domain XML carries `<genid/>`; a libvirt-driven revert regenerates
it, and if the snapshot method chosen by #11 reverts outside libvirt the provider regenerates it
itself, so a DC revert takes AD's VM-Generation-ID safe-restore path (matters once a second DC
exists).

**Firmware posture.** One posture for every guest: Secure-Boot-*capable* OVMF code with a
*non-enrolled* vars template, so Windows 11 Setup's capability check passes and unsigned Linux
kernels (Kali) still boot. It is set explicitly — Packer's `efi_firmware_code` /
`efi_firmware_vars`, the OpenTofu module's `loader` and nvram `template` — never through
libvirt's `firmware='efi'` autoselect, which on Debian and Fedora picks the enrolled-keys
descriptor first and would enforce Secure Boot. #11 Q2 verifies Windows 11 Setup accepts it.

**Why.** Golden state includes the nvram (D3); a BIOS guest has none, and two firmware modes
would mean two revert procedures to test and keep working. Two firmware postures would mean the
same for Secure Boot.

**Consequences.** The smoke path (#1) defines its throwaway domain with EFI firmware, not
libvirt's SeaBIOS default; stock Ubuntu cloud images are hybrid GPT images and boot under OVMF
unmodified. Kali's official QEMU images are BIOS-only, so the attacker image is a Packer build
like the others. Preflight requires a Secure-Boot-capable EFI firmware descriptor whose
non-enrolled vars template exists.

<a id="d20"></a>
## D20 — Guest credentials and SSH keys

*2026-09-22*

**Decision.** Packer bakes a **build key** and a build-time local administrator password into
every image; both are throwaway. At the orchestrator's "wait for SSH" step, before any plugin
runs, the controller generates a **per-instance SSH keypair** and stores it before touching any
guest, then runs an idempotent per-guest swap: connect with the per-instance key, else the build
key; ensure the per-instance public key (`administrators_authorized_keys` on Windows,
`authorized_keys` on Linux); ensure the per-instance local administrator password; remove the
build key. A resumed build (D3) repeats the swap harmlessly. The per-instance private key and
passwords are controller state in SQLite (D7), never config. Plugin application (D4) and every
later controller action use the per-instance key. All generated user passwords derive from the
secret seed (D15). The API (#6) exposes a **student-credentials** response for an owned instance:
the `attacker` node's login (the student's seat) and the `workstation` node's local administrator
password, never the seed and never the SSH key.

**Why.** A key baked into the image is either committed to the repo (then any image holder,
including the attacker seat, can SSH into the DC as administrator) or generated per controller
(then images are bound to one controller and break the "build once, use for months" story of
D18). Windows has no cloud-init to inject a key at first boot, so the swap has to happen over the
build key. Without a defined credential path a student on a central server has no way to log in
to their own instance, because everything else is sealed.

**Consequences.** #3 slice 1 owns the swap; #3's Packer templates own the build key. #5's
weakness-free proxy list gains "no repo-known credential grants access to any node". #6's
sealing slice owns the student-credentials response. `rebuild` rotates the per-instance key.

<a id="d21"></a>
## D21 — Instance volumes are copy-on-write overlays; images are immutable and versioned

*2026-09-22*

**Decision.** An instance's disks are qcow2 overlays whose backing file is the Packer image.
Images are therefore immutable: a Packer rebuild produces a new image version, never an in-place
replacement. The image store (owned by #3) records for each image its name, version, build date
(D18), source ISO and checksum; `adlab image list` shows it; `node.image` is cross-validated
against it; the instance record pins the image versions it was built from.

**Image invariants.** Every image boots on libvirt from a pristine OVMF vars template and an
empty swtpm state directory, not only as the VM Packer produced: libvirt creates each instance's
nvram from the template, so Packer's boot entries are gone (the Kali preseed forces the removable
EFI path for that reason). Windows images end in `sysprep /generalize` so every node has a unique
machine SID: a new forest's domain SID is the first DC's machine SID, and a member cloned from the
same image cannot join it (D18 for the rearm interaction). The spike (#11) checks both.

**Why.** Full copies of ~20 GB Windows images for five nodes and N instances are roughly ten
times the disk of overlays. An in-place rebuild of a backing file silently corrupts every overlay
on it, so immutability is not optional once overlays are chosen.

**Consequences.** The snapshot method chosen by #11 must work on an overlay volume, so the spike
snapshots an overlay, not the Packer output. Image distribution (#8) copies versioned images.
Disk-budget checks count overlay growth, not image size; `disk_gb` (D15) is the ceiling.
