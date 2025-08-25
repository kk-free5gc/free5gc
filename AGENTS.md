# Repository Guidelines

## Project Structure & Modules
- Source: `NFs/<nf>/{cmd,internal,pkg}` for each NF (`amf, ausf, nrf, nssf, pcf, smf, udm, udr, n3iwf, upf, chf, tngf, nef`). Executables output to `bin/`.
- Config: per-NF YAML in `config/*.yaml` (e.g., `amfcfg.yaml`, `smfcfg.yaml`). Certs in `cert/`.
- Tests: integration and helpers in `test/` (separate Go module). CI assets in `ci-test/`.
- Web UI: `webconsole/` (Go server + React frontend).
- Scripts: `run.sh`, `test*.sh` for local orchestration.

## Build, Test, and Development
- Build all NFs: `make` (default) or `make nfs`; include WebConsole: `make all`; debug symbols: `make debug`.
- Build a single NF: `make amf` (replace with any NF name). Artifacts appear in `bin/`.
- WebConsole: `make webconsole` (builds server and frontend with Yarn).
- Run core locally: `./run.sh [-cp|-dp|-n3iwf|-tngf]` (creates dated logs under `log/`). Requires MongoDB and root for UPF.
- Tests: `cd test && go test -v ./...` (coverage: `go test -cover ./...`). Some tests require running NFs and MongoDB.
- Lint/format: `golangci-lint run` (root or per NF). Enforces `gofmt`, `govet`, `errcheck`, etc. Config: `.golangci.yml`.

## Coding Style & Naming
- Go style: formatted by `gofmt`/`goimports`. Keep imports grouped; no unused code.
- Packages: lowercase, no underscores; exported identifiers use CamelCase. Errors are wrapped and checked.
- Files/configs: Go files lowercase with optional underscores; YAML indented with 2 spaces; follow `${NF}cfg.yaml` naming.

## Testing Guidelines
- Place unit tests as `_test.go` with `TestXxx` names. Prefer table-driven tests and clear given/when/then comments.
- Integration tests live under `test/`; keep data in `test/*Testpacket` and avoid external dependencies beyond MongoDB/NFs.

## Commit & Pull Request Guidelines
- Commits: conventional style, e.g. `fix: make Passivetransfer_port_range configurable`, `chore: update submodule hashes`.
- PRs: focused scope, description of changes, linked issues, test plan/output or logs, config impact (which YAML keys), and screenshots for WebConsole.
- Ensure `make` succeeds, `golangci-lint run` passes, and tests are green before requesting review.

## Security & Config Tips
- Do not commit secrets or real certs; keep dev certs in `cert/`. Sanitize logs before sharing.
- Changes to network behavior should note required kernel/sysctl or `sudo` needs (UPF, IPsec).
