# Codebase Explanation by Codex (Saved Transcript)

```
[loren@t1-1-1-q-61344 free5gc]~ codex

 To get started, describe a task or try one of these commands:

 /init - create an AGENTS.md file with instructions for Codex
 /status - show current session configuration and token usage

 1. Explain this codebase
 2. Summarize recent commits
 5. Write tests for @filename
 6. Improve documentation in @filename

user

I’m thinking I should check the README.md and the directory structure of the NFs
, maybe even the Makefile to understand the build targets. It seems that the web
 console is likely part of the frontend. I also noticed that the NFs directory c
ontains network functions like AMF, SMF, UPF, and others. It might be a good ide
a to list these NFs to have a clearer view of what's included.
mentation works and what I might need to consider further.

⚙︎ Working
    🔎 amf
    📂 app
    ⌨️ echo ---
    📖 amf_init.go
    📖 app.go
    ⌨️ echo ---
    📖 init.go
    🔎 upf
    ⌨️ echo ---
    📖 main.go
    🔎 smf
thinking
**Inspecting build configuration**

I see that the Makefile is showing the process for building various Go NFs, incl
uding amf, ausf, nrf, and others. In addition, it mentions a web console, with t
he frontend built using Yarn, and there’s a Go build embedding commit/time info.
 There’s a config directory mentioned too, so I need to take a closer look at th
e configuration to understand how everything fits together!
    ⌨️ head -n 40
    📖 run.sh
    📂 webconsole
thinking
**Checking binaries directory**

I'm checking the `bin` directory to see if the built binaries are present. It se
ems to be there, so I’ll need to list its contents. I guess that's a good step t
o confirm everything is in order. By listing the binaries, I'll be able to deter
mine if everything was built correctly and functioning as expected. Let's see wh
at I find there!

⚙︎ Working
  L 📂 bin

thinking
**Summarizing submodules**

I need to summarize the concept here. It’s important to mention that each NF ser
ves as a submodule, and we can find details in the .gitmodules file. So, opening
 .gitmodules should give me the relevant information I need. I want to make sure
 I capture all the essential details while keeping everything clear and easy to 
understand. It feels good to be organized and thorough in this process!

⚙︎ Working
  L 📖 .gitmodules
    📂 test
    🔎 test

thinking
**Structuring codebase explanation**

I'm considering how to explain this codebase effectively. It includes Go tests a
nd emulators, with several documentation files related to UE policy features. I 
want to summarize these elements clearly. Also, there are scripts like force_kil
l.sh and test.sh, but I don't think those are essential to the explanation.

I’ll outline typical data models using openapi models from the specified GitHub 
repository. I'll structure the final answer with headers like "Overview," "Archi
tecture," "Modules," "Build & Run," and so on, limiting the content to around 8-
12 structured bullets to keep it concise but informative.**Summarizing codebase 
responsibilities**

I’ll want to keep my overview concise without reproducing too much code. Includi
ng important commands and file paths in backticks will help clarity. I'll outlin
e high-level responsibilities for each network function: 

- AMF: manages access and mobility
- SMF: handles session management
- UPF: deals with user plane
- NRF: assists with registry and discovery
- PCF: handles policy control
- UDM/UDR: manages user data with MongoDB
- AUSF: responsible for authentication
- NSSF: handles slice selection
- NEF: aids exposure
- CHF: manages charging
- N3IWF/TNGF: supports interworking
- Webconsole: offers admin UI

Additionally, I’ll describe the Go module structure and key files for builds and
 configurations.**Crafting a structured explanation**

I’m thinking about how to keep the configuration examples light while also menti
oning tests and CI. I can suggest a typical development loop involving commands 
like `git submodule update --init --recursive`, `make`, and using configurations
.

It’s important to highlight external dependencies, such as the `gtp5g` kernel mo
dule and the need for `mongod` to be running. I’ll note the flow of data across 
network functions and how they register with NRF.

Also, I need to mention the logger and how to set logging options. I’ll put toge
ther a structured explanation that covers all these points.

thinking
**Summarizing codebase responsibilities**

I’ll want to keep my overview concise without reproducing too much code. Includi
ng important commands and file paths in backticks will help clarity. I'll outlin
e high-level responsibilities for each network function: 

- AMF: manages access and mobility
- SMF: handles session management
- UPF: deals with user plane
- UDM/UDR: manages user data with MongoDB
- AUSF: responsible for authentication
- NSSF: handles slice selection
- NEF: aids exposure
- CHF: manages charging
- N3IWF/TNGF: supports interworking
- Webconsole: offers admin UI

Additionally, I’ll describe the Go module structure and key files for builds and
 configurations.

thinking
**Crafting a structured explanation**

I’m thinking about how to keep the configuration examples light while also menti
oning tests and CI. I can suggest a typical development loop involving commands 
like `git submodule update --init --recursive`, `make`, and using configurations
.

It’s important to highlight external dependencies, such as the `gtp5g` kernel mo
dule and the need for `mongod` to be running. I’ll note the flow of data across 
network functions and how they register with NRF.

Also, I need to mention the logger and how to set logging options. I’ll put toge
ther a structured explanation that covers all these points.

codex
**High-Level Overview**
- **Purpose:** An open-source 5G Core (5GC) implementation aligned with 3GPP Rel
-15+.
- **Design:** Each Network Function (NF) is a separate Go module in `NFs/*` and 
built into its own binary.
- **Control Plane:** SBI between NFs over HTTP/2 (OpenAPI models), NGAP over SCT
P, PFCP to UPF over UDP.
- **User Plane:** UPF handles GTP-U data plane with the Linux `gtp5g` kernel mod
ule.
- **State/Profiles:** Uses MongoDB for NF profiles and persistent data.

**Key Directories**
- `NFs/`: All 5GC network functions as Git submodules.
  - `amf`: Access & Mobility (NGAP/NAS, registration, paging).
  - `smf`: Session Management (PDU sessions, PFCP with UPF).
  - `upf`: User Plane (GTP-U, PDR/FAR/QoS via PFCP).
  - `nrf`: NF Repository (registration and discovery).
  - `pcf`: Policy Control (policy rules, AF influence).
  - `udm`/`udr`: Subscriber data management/repository.
  - `ausf`: Authentication and security procedures.
  - `nssf`: Network Slice Selection.
  - `nef`: Network Exposure Function.
  - `chf`: Charging Function.
  - `n3iwf`/`tngf`: Non-3GPP interworking (IPsec/IKEv2 tunnel endpoints).
- `webconsole/`: Admin UI (Go backend + React/Vite frontend).
- `config/`: YAML configs per NF (`*cfg.yaml`), plus multi-instance examples.
- `bin/`: Built binaries (`amf`, `smf`, `upf`, etc.).
- `test/`: Integration tests, UE/RAN emulators, and helpers.
- Root scripts: `run.sh` (one-shot multi-NF bring-up), `test.sh`, `force_kill.sh
`.

**Build & Run**
- `Makefile`: Builds all NFs and webconsole.
  - `make nfs` or `make` builds `bin/{amf,smf,upf,...}` with version ldflags.
  - `make webconsole` builds backend and `frontend` with `yarn`.
- `run.sh`:
  - Starts `upf` (sudo), clears MongoDB collections, then starts `nrf amf smf ud
r pcf udm nssf ausf chf nef`.
  - Flags: `-cp/-dp` enable control/user-plane pcaps via `tcpdump`, `-n3iwf`, `-
tngf` include non-3GPP NFs.
  - Logs to `./log/<timestamp>/free5gc.log`, sets `GIN_MODE=release`.
- External deps to have installed/running:
  - `mongod` (MongoDB).
  - `gtp5g` kernel module for UPF (`make_gtp5gtunnel.sh` helps set up tunnel).
  - Kernel SCTP support for NGAP.

**NF Code Structure (common pattern)**
- `cmd/main.go`: CLI entry (`-c` config path, `-l` log path), log init, version 
print.
- `pkg/factory`: Config parsing (`ReadConfig`), defaults, and shared config acce
ssors.
- `pkg/service`: Lifecycle orchestration (`NewApp`, `Start`, `Terminate`), serve
rs, workers.
- `internal/*`: Protocol logic and state:
  - `context`: In-memory NF context (IDs, URIs, UE/session state).
  - `sbi`: HTTP2 clients/servers, request processors, and inter-NF consumers.
  - `ngap` (AMF): SCTP socket, message dispatch, RAN connection handling.
  - `pfcp` (SMF/UPF): Sessions, associations, PDR/FAR management.
  - `logger`: Logrus wrappers, per-package loggers.
  - `nas`, `gmm` (AMF): NAS procedures and state machines.
- Example flow (AMF):
  - `service.Start()` initializes context, starts NGAP SCTP listener, builds NF 
profile, registers with NRF via `Consumer().SendRegisterNFInstance`, then runs S
BI server.

**Configuration**
- Files: `config/*cfg.yaml` per NF; `uerouting.yaml` for SMF UE routing; upf con
figs (`upfcfg*.yaml`) for interfaces and PFCP endpoints.
- Typical keys:
  - `sbi`: service address/port/TLS.
  - `configuration`: NF-specific (AMF NGAP IP/port, SMF PFCP local addr, slices/
DNNs).
  - `mongodb`: database URI/name for data-backed NFs.
  - `logger`: level/enable/reportCaller.
- Multi-instance examples: `config/multiAMF`, `config/multiUPF` (ULCL topologies
).

**Runtime Communication**
- **NGAP (AMF-RAN):** SCTP on port 38412; handles registration, PDU session setu
p request signaling.
- **SBI (NF-NF):** HTTP/2 + JSON; OpenAPI models from `github.com/free5gc/openap
i/models`.
- **PFCP (SMF-UPF):** UDP 8805; session establishment/modification for user plan
e rules.
**Testing**
- `test/`: Go integration tests and emulators (`ueRanEmulator`, NGAP/NAS packets
, PFCP helpers).
- CI artifacts: `ci-test` submodule for pipelines and scenarios; scripts like `t
est_ci.sh`.

**Notable Scripts**
- `run.sh`: Single-host bring-up with logging and optional pcap.
- `reload_host_config.sh`: Host network config reloads for dev.
- `make_gtp5gtunnel.sh`: Helper for UPF GTP tunnel on Linux.

**How To Extend**
- Add logic under an NF’s `internal/*` (e.g., new SBI handler under `internal/sb
i/processor`).
- Expose service hooks in `pkg/service` as needed; pass config via `pkg/factory`
.
- Define new OpenAPI interactions via `github.com/free5gc/openapi` models and cl
ient helpers in `internal/sbi/consumer`.
- Keep configs in `config/*cfg.yaml` and wire up defaults in the NF factory.

If you want, I can map a specific call flow (e.g., Registration → PDU Session) t
o code paths or walk through one NF’s config fields in detail.

Token usage: total=38459 input=34946 (+ 219648 cached) output=3513 (reasoning 1152)
. Please save at current location with filename: codebase_explanation_by_codex.md
```

