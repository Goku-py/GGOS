# GGOS — AME Wizard Playbook

An interactive Windows 10/11 optimization, debloat and cleanup playbook for
[AME Wizard](https://amelabs.net/). GGOS combines ideas from TBOK-Win11Optimizer
(hardware-aware tuning, per-user tweaks for all profiles), CTT WinUtil (MIT) and
community playbooks like FSOS-X.

## Structure

```
GGOS/
├── playbook.conf            # Metadata, requirements, interactive feature pages
├── Configuration/
│   ├── main.yml             # Task orchestration
│   └── Tasks/               # Action files (registry, services, appx, ...)
└── Executables/             # PowerShell helpers (rollback, cleanup, per-user)
```

## Feature pages

Selection happens in AME Wizard before anything runs. Options gate YAML actions
via the `option:` property (see [AME docs](https://docs.amelabs.net/creating_playbooks.html)).

## Attribution / licenses

- **CTT WinUtil** (`ChrisTitusTech/winutil`, MIT): specific registry/service/task values may
  be re-used — MIT notice preserved in `Configuration/Tasks/` file headers.
- **TBOK-Win11Optimizer**: no license exists upstream; used as a reference specification
  only (semantics ported, no code copied). No affiliation implied.
- **FSOS-X / XOS**: used as structural/format references for playbook layout.
