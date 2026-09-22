# CLAUDE.md — ad_lab

An Active Directory training lab: a config-driven, plugin-based environment with a web control
plane. A clean rebuild of the older `ad_exercise_ng`, which was Vagrant/VirtualBox-based (the HCP
Vagrant box registry is being retired).

**Clean rebuild.** `../ad_exercise_ng` is a source of *lessons only* — never copy its Ansible,
Vagrantfile, or scripts; they grew unmaintainable. Re-derive everything fresh.

## Where the truth lives

- **Roadmap and feature work:** GitHub issues. Start from the roadmap/tracking issue; each epic
  carries its own scope, first slice, and acceptance criteria. Do not restate issue specifics here.
- **Architecture:** `docs/`. Keep design decisions and rationale there, not in code comments or in
  this file. Add a doc when a decision is worth more than a sentence.
  `docs/decisions.md` is the decision log; issues link to its entries instead of restating them.
- **This file:** stable ground rules and layout only.

## Layout (built out over time)

```
controller/     # FastAPI control plane: API, RBAC, domain logic, lifecycle orchestration
provisioning/   # provider abstraction, Packer image builds, Terraform (create/destroy)
plugins/        # capability plugins ("things the AD can do") — the plugin contract + implementations
webui/          # SPA: define / configure / control the lab
docs/           # architecture docs and design rationale
tests/          # unit tests (real-virtualization tests are opt-in, separate)
```

## Ground rules

- **Provider is an interface, not a hardcode.** libvirt/KVM is the default; other providers
  (cloud/OpenStack) are additional implementations behind the same interface. Nothing outside
  `provisioning/` should know which provider is in use.
- **Terraform does create/destroy only.** Runtime VM control (start/stop/reset/snapshot) goes
  through the provider interface, never Terraform — it reconciles to desired state and fights
  out-of-band changes.
- **One config document is the source of truth.** Nodes, networks, sizing, provider, host, and
  enabled plugins with their parameters. Nothing else holds lab facts.
- **Every plugin ships a verifier.** A silent no-op reporting success is the worst failure mode.
  Plugin application is idempotent and records an applied-marker; "exit 0" is never proof it applied.
- **Plugins declare their dependencies;** the engine orders them. Never hand-order a global stage list.
- **No deliberate weaknesses yet.** The framework and base plugins are built weakness-free. The
  weakness-plugin track is later and separate — do not implement attacks, misconfigurations, or
  offensive tooling unless an issue explicitly scopes it.
- **The default config must fit a ~32 GB laptop** and must not depend on this specific host or OS.
