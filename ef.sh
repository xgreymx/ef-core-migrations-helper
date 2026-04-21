#!/usr/bin/env bash
# EF Core migration helper for the CDI-PUI solution.
# Mirror of scripts/ef.ps1 for Linux / macOS / WSL.
#
# Destructive actions (drop / reset / update 0 / rollback to earlier migration)
# require confirmation. Pass --force to skip prompts (e.g. CI pipelines).
#
# Usage:
#   ./scripts/ef.sh add AddCustomerTable
#   ./scripts/ef.sh update
#   ./scripts/ef.sh update DatabaseInitialization   # rollback — prompts
#   ./scripts/ef.sh remove
#   ./scripts/ef.sh list
#   ./scripts/ef.sh drop                            # destructive — double prompt
#   ./scripts/ef.sh reset                           # destructive — double prompt
#   ./scripts/ef.sh reset --force                   # skip prompts (CI)
#   ./scripts/ef.sh script [output.sql]
#   ./scripts/ef.sh pending
#   ./scripts/ef.sh bundle

set -euo pipefail

# --- Configuration ---------------------------------------------------
DBCONTEXT_PROJECT="./CDI-PUI.Infra/"
STARTUP_PROJECT="./CDI-PUI.Api/"
MIGRATIONS_DIR="Persistence/Migrations"
# ---------------------------------------------------------------------

COMMON=(--project "$DBCONTEXT_PROJECT" --startup-project "$STARTUP_PROJECT")

# Parse --force from anywhere in args
FORCE=0
ARGS=()
for a in "$@"; do
  case "$a" in
    --force|-f|-y) FORCE=1 ;;
    *) ARGS+=("$a") ;;
  esac
done
set -- "${ARGS[@]:-}"

# Colors (fallback to no-op if terminal doesn't support)
if [[ -t 1 ]]; then
  RED='\033[0;31m'; YELLOW='\033[1;33m'; GREEN='\033[0;32m'; CYAN='\033[0;36m'; NC='\033[0m'
else
  RED=''; YELLOW=''; GREEN=''; CYAN=''; NC=''
fi

run_ef() {
  echo -e "${CYAN}▶ dotnet ef $*${NC}"
  dotnet ef "$@"
}

confirm_destructive() {
  local action="$1"
  local consequence="$2"

  if [[ "$FORCE" -eq 1 ]]; then
    echo -e "${YELLOW}⚠  --force specified, skipping confirmation for: $action${NC}"
    return 0
  fi

  echo ""
  echo -e "${RED}══════════════════════════════════════════════════════════════${NC}"
  echo -e "${RED}  ⚠  DESTRUCTIVE ACTION: $action${NC}"
  echo -e "${RED}══════════════════════════════════════════════════════════════${NC}"
  echo -e "${YELLOW}  $consequence${NC}"
  echo -e "${YELLOW}  This CANNOT be undone automatically.${NC}"
  echo ""

  read -rp "  Continue? [y/N] " c1
  if [[ ! "$c1" =~ ^[yY]$ ]]; then
    echo -e "${YELLOW}✗ Aborted.${NC}"
    exit 0
  fi

  echo ""
  read -rp "  Type 'YES' (uppercase) to confirm: " c2
  if [[ "$c2" != "YES" ]]; then
    echo -e "${YELLOW}✗ Aborted — confirmation did not match.${NC}"
    exit 0
  fi

  echo -e "${GREEN}✓ Confirmed. Proceeding...${NC}"
  echo ""
}

confirm_rollback() {
  local target="$1"

  if [[ "$FORCE" -eq 1 ]]; then return 0; fi

  echo ""
  echo -e "${YELLOW}⚠  Updating to a specific migration: $target${NC}"
  echo -e "${YELLOW}   If this migration is BEHIND the current DB state, tables/columns${NC}"
  echo -e "${YELLOW}   may be dropped and data lost.${NC}"
  echo ""
  read -rp "Continue? [y/N] " ans
  if [[ ! "$ans" =~ ^[yY]$ ]]; then
    echo -e "${YELLOW}✗ Aborted.${NC}"
    exit 0
  fi
}

cmd="${1:-}"
arg="${2:-}"

case "$cmd" in
  add)
    [[ -z "$arg" ]] && { echo "Migration name required. Example: ./scripts/ef.sh add AddProductsTable"; exit 1; }
    args=(migrations add "$arg" "${COMMON[@]}")
    if [[ ! -d "$DBCONTEXT_PROJECT/$MIGRATIONS_DIR" ]]; then
      echo "First migration detected — using --output-dir $MIGRATIONS_DIR"
      args+=(--output-dir "$MIGRATIONS_DIR")
    fi
    run_ef "${args[@]}"
    ;;

  update)
    if [[ "$arg" == "0" ]]; then
      confirm_destructive \
        "Revert ALL migrations (update 0)" \
        "Every table and column created by migrations will be DROPPED."
    elif [[ -n "$arg" ]]; then
      confirm_rollback "$arg"
    fi
    # else: no arg = forward to latest, no confirmation

    args=(database update)
    [[ -n "$arg" ]] && args+=("$arg")
    args+=("${COMMON[@]}")
    run_ef "${args[@]}"
    ;;

  remove)
    # Not destructive to data — only removes the local migration file
    run_ef migrations remove "${COMMON[@]}"
    ;;

  list)
    run_ef migrations list "${COMMON[@]}"
    ;;

  drop)
    confirm_destructive \
      "Drop the database" \
      "The entire database and ALL its data will be permanently deleted."
    run_ef database drop -f "${COMMON[@]}"
    ;;

  reset)
    confirm_destructive \
      "Reset the database (drop + re-apply all migrations)" \
      "The database will be dropped and recreated empty. ALL data will be lost."
    echo "Dropping database..."
    run_ef database drop -f "${COMMON[@]}"
    echo "Applying all migrations..."
    run_ef database update "${COMMON[@]}"
    echo -e "${GREEN}✓ Database recreated from migrations.${NC}"
    ;;

  script)
    output="${arg:-migrations.sql}"
    run_ef migrations script --idempotent -o "$output" "${COMMON[@]}"
    echo -e "${GREEN}✓ SQL script written to $output${NC}"
    ;;

  pending)
    run_ef migrations has-pending-model-changes "${COMMON[@]}"
    ;;

  bundle)
    run_ef migrations bundle --force "${COMMON[@]}"
    ;;

  *)
    echo "Unknown command: $cmd"
    echo "Valid: add | update | remove | list | drop | reset | script | pending | bundle"
    echo "Flags: --force (skip confirmations, for CI only)"
    exit 1
    ;;
esac
