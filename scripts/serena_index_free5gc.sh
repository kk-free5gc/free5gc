#!/usr/bin/env bash
# serena_index_free5gc.sh
# Stage or full-workspace Serena indexing for a multi-module Go repo.
# - Keeps ONE .serena at the repo root
# - Can create a minimal go.work and expand in batches (staged)
# - OR create a full go.work covering all modules up front (full)
#
# Usage:
#   uv run --directory $SERENA_SRC serena project index $REPO
#   or
#   chmod +x serena_index_free5gc.sh
#   ./serena_index_free5gc.sh                    # staged (default)
#   ./serena_index_free5gc.sh --workspace full   # create go.work with all modules, index once
#   ./serena_index_free5gc.sh --workspace staged # staged (explicit)
# Options:
#   --timeout <sec>        Per-file index timeout (default: 90)
#   --repo <path>          Repo root (default set in script)
#   --serena-src <path>    Serena source dir containing pyproject.toml (default set in script)

set -euo pipefail

### ==== DEFAULTS (edit if you like) =======================================
REPO="/home/wnc/Downloads/source_code/free5gc_4.0.1/free5gc"
SERENA_SRC="/home/wnc/Downloads/source_code/serena"
TIMEOUT=90
WORKSPACE_MODE="staged"   # staged|full
# Batches for staged mode (relative to $REPO)
BATCH1=( "NFs/amf" )
BATCH2=( "NFs/smf" "NFs/udr" )
BATCH3=( "NFs/pcf" "NFs/nrf" )
BATCH4=( "NFs/udm" "NFs/ausf" )
BATCH5=( "NFs/upf" "NFs/chf" )
BATCH6=( "NFs/n3iwf" "NFs/tngf" "NFs/nef" )
BATCH7=( "webconsole" "ci-test/test/goTest" "test")
# All modules for "full" workspace mode (exact order doesn't matter)
ALL_MODULES=(
  "NFs/amf" "NFs/smf" "NFs/udm" "NFs/udr" "NFs/nrf" "NFs/ausf" "NFs/nssf"
  "NFs/pcf" "NFs/upf" "NFs/chf" "NFs/n3iwf" "NFs/tngf" "NFs/nef" 
  "webconsole" "ci-test/test/goTest" "test"
)
### =======================================================================

usage() {
  cat <<EOF
Usage: $(basename "$0") [--workspace staged|full] [--timeout SECONDS] [--repo PATH] [--serena-src PATH]

Examples:
  $(basename "$0")                       # staged (default)
  $(basename "$0") --workspace full      # full workspace: create go.work with ALL_MODULES and index once
  $(basename "$0") --timeout 120         # raise per-file timeout
EOF
}

# ---- arg parsing ----
while [[ $# -gt 0 ]]; do
  case "$1" in
    --workspace)
      shift; WORKSPACE_MODE="${1:-staged}";;
    --timeout)
      shift; TIMEOUT="${1:-90}";;
    --repo)
      shift; REPO="${1:-}";;
    --serena-src)
      shift; SERENA_SRC="${1:-}";;
    -h|--help)
      usage; exit 0;;
    *)
      echo "Unknown arg: $1" >&2; usage; exit 2;;
  esac
  shift || true
done

die() { echo "ERROR: $*" >&2; exit 1; }
have() { command -v "$1" >/dev/null 2>&1; }

require_cmds() {
  have go      || die "go not found in PATH"
  have gopls   || die "gopls not found in PATH (go install golang.org/x/tools/gopls@<compatible>)"
}

resolve_uv() {
  if have uv; then
    UV_BIN="$(command -v uv)"
  else
    for p in "$HOME/.local/bin/uv" "$HOME/.cargo/bin/uv"; do
      if [ -x "$p" ]; then UV_BIN="$p"; break; fi
    done
    [ -n "${UV_BIN:-}" ] || die "uv not found. Add it to PATH or install it."
  fi
  echo "Using uv: $UV_BIN"
}

write_project_yml() {
  mkdir -p "$REPO/.serena"
  cat > "$REPO/.serena/project.yml" <<'YAML'
language: go
ignore_all_files_in_gitignore: true
ignored_paths:
  - 'ci-test/**'
  - 'test/**'
  - 'webconsole/**'
  - '**/mock/**'
  - '**/generated/**'
YAML
  echo "Wrote $REPO/.serena/project.yml"
}

backup_go_work() {
  cd "$REPO"
  if [ -f go.work ]; then
    cp -a go.work go.work.bak
    echo "Backed up existing go.work -> go.work.bak"
  fi
}

restore_go_work() {
  cd "$REPO"
  if [ -f go.work.bak ]; then
    mv -f go.work.bak go.work
    echo "Restored original go.work"
  fi
}

create_go_work_with_modules() {
  cd "$REPO"
  echo "Creating go.work with modules: $*"
  {
    echo "go 1.21"
    for m in "$@"; do
      echo "use ./$m"
    done
  } > go.work
  echo "go.work content:"
  cat go.work
}

append_modules_to_go_work() {
  cd "$REPO"
  for m in "$@"; do
    echo "use ./$m" >> go.work
  done
  echo "Updated go.work (appended ${*}):"
  cat go.work
}

warm_module() {
  local m="$1"; local path="$REPO/$m"
  [ -d "$path" ] || { echo "Skip warm (missing): $m"; return 0; }
  echo "Warming module: $m"
  ( cd "$path" && GOWORK=off go mod download )
  ( cd "$path" && GOWORK=off go list ./... >/dev/null )
}

warm_hot_files() {
  local f1="$REPO/NFs/amf/internal/ngap/dispatcher.go"
  local f2="$REPO/NFs/amf/internal/ngap/testing/conn_stub.go"
  [ -f "$f1" ] && GOWORK=off gopls symbols "$f1" >/dev/null || true
  [ -f "$f2" ] && GOWORK=off gopls symbols "$f2" >/dev/null || true
}

index_root() {
  echo "Indexing root with timeout=$TIMEOUT ..."
  GOPACKAGESDRIVER=off CGO_ENABLED=0 GOWORK="$REPO/go.work" \
  "$UV_BIN" run --directory "$SERENA_SRC" \
    serena project index --timeout "$TIMEOUT" "$REPO"
  echo "Indexing complete."
  local log="$REPO/.serena/logs/indexing.txt"
  if [ -f "$log" ]; then
    if grep -q "Failed to index" "$log"; then
      echo "⚠️  Some files failed. See: $log"
      sed -n '1,80p' "$log" || true
    else
      echo "✅ No failures reported. Log: $log"
    fi
  fi
}

kill_gopls() { pkill gopls 2>/dev/null || true; }

##########################################################################################
# ---- main ----
##########################################################################################

require_cmds
resolve_uv

[ -d "$REPO" ] || die "Repo path not found: $REPO"
[ -d "$SERENA_SRC" ] || die "Serena source path not found: $SERENA_SRC"

export PATH="$(dirname "$UV_BIN"):$HOME/go/bin:/usr/local/go/bin:/usr/bin:/bin:$PATH"
ulimit -n 4096 || true
export GOMAXPROCS="$(nproc || echo 4)"

echo "Repo:        $REPO"
echo "Serena src:  $SERENA_SRC"
echo "Timeout:     $TIMEOUT s"
echo "Mode:        $WORKSPACE_MODE"
echo

trap 'restore_go_work' EXIT  # ensure restoration on exit
kill_gopls
##write_project_yml
backup_go_work

if [[ "$WORKSPACE_MODE" == "full" ]]; then
  echo ">>> FULL workspace mode: creating go.work with ALL modules"
  create_go_work_with_modules "${ALL_MODULES[@]}"
  # Warm modules (module mode)
  for m in "${ALL_MODULES[@]}"; do warm_module "$m"; done
  warm_hot_files
  index_root
  echo "Full-workspace indexing done."
else
  echo ">>> STAGED mode: batching modules to avoid LSP timeouts"
  # Pass 1
  create_go_work_with_modules "${BATCH1[@]}"
  for m in "${BATCH1[@]}"; do warm_module "$m"; done
  warm_hot_files
  index_root

  # Pass 2..n
  declare -a BATCHES_LIST=( "BATCH2[@]" "BATCH3[@]" "BATCH4[@]" "BATCH5[@]" "BATCH6[@]" "BATCH7[@]" )
  for bname in "${BATCHES_LIST[@]}"; do
    batch=( "${!bname}" )
    [ "${#batch[@]}" -gt 0 ] || continue
    echo
    echo "Adding modules: ${batch[*]}"
    append_modules_to_go_work "${batch[@]}"
    for m in "${batch[@]}"; do warm_module "$m"; done
    warm_hot_files
    index_root
  done
  echo "Staged indexing done."
fi

# Final pass with restored go.work (your original workspace), if it existed
if [ -f "$REPO/go.work.bak" ]; then
  echo ">>> Final full pass using restored go.work"
  # restore_go_work will run on EXIT; do a manual restore for immediate pass
  mv -f "$REPO/go.work.bak" "$REPO/go.work"
  GOPACKAGESDRIVER=off CGO_ENABLED=0 \
  "$UV_BIN" run --directory "$SERENA_SRC" \
    serena project index --timeout "$TIMEOUT" "$REPO"
  echo "Final indexing complete."
fi

echo
echo "Done. Single project cache at: $REPO/.serena/cache/go/document_symbols_cache_*.pkl"
