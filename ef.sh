#!/usr/bin/env bash
# EF Core migrations helper for the shell-only branch.

set -euo pipefail

SCRIPT_NAME="$(basename "$0")"
DEFAULT_MIGRATIONS_DIR="Persistence/Migrations"

CONFIG_OVERRIDE=""
OUTPUT_OVERRIDE=""
WORKING_DIR_OVERRIDE=""
DBCONTEXT_OVERRIDE=""
STARTUP_OVERRIDE=""
MIGRATIONS_DIR_OVERRIDE=""
DBCONTEXT_NAME_OVERRIDE=""

OUTPUT_OVERRIDE_SET=0
WORKING_DIR_OVERRIDE_SET=0
DBCONTEXT_OVERRIDE_SET=0
STARTUP_OVERRIDE_SET=0
MIGRATIONS_DIR_OVERRIDE_SET=0
DBCONTEXT_NAME_OVERRIDE_SET=0

FORCE=0
IDEMPOTENT=1
HELP_FLAG=0

POSITIONALS=()
DISCOVERED_PROJECTS=()
EF_ARGS=()
SCRIPT_OUTPUT_PATH=""

CONFIG_VERSION="1"
CONFIG_STORAGE_ROOT=""
CONFIG_WORKING_DIR=""
CONFIG_DBCONTEXT_PROJECT=""
CONFIG_STARTUP_PROJECT=""
CONFIG_MIGRATIONS_DIR="$DEFAULT_MIGRATIONS_DIR"
CONFIG_DBCONTEXT_NAME=""

write_lines() {
  while (($#)); do
    printf '%s\n' "$1"
    shift
  done
}

trim_string() {
  local value="$1"
  value="${value#"${value%%[![:space:]]*}"}"
  value="${value%"${value##*[![:space:]]}"}"
  printf '%s\n' "$value"
}

lowercase() {
  printf '%s' "$1" | tr '[:upper:]' '[:lower:]'
}

die() {
  printf '%s\n' "$1" >&2
  exit 1
}

normalize_command() {
  local name
  name="$(lowercase "${1:-}")"

  case "$name" in
    '') printf 'help\n' ;;
    a) printf 'add\n' ;;
    cfg) printf 'config\n' ;;
    h) printf 'help\n' ;;
    init) printf 'setup\n' ;;
    ls) printf 'list\n' ;;
    rm) printf 'remove\n' ;;
    sql) printf 'script\n' ;;
    u|up) printf 'update\n' ;;
    *) printf '%s\n' "$name" ;;
  esac
}

normalize_path() {
  local path="$1"
  local is_absolute=0
  local IFS='/'
  local raw_parts=()
  local parts=()
  local part
  local last_index
  local joined=""

  if [[ "$path" == /* ]]; then
    is_absolute=1
  fi

  read -r -a raw_parts <<< "$path"

  for part in "${raw_parts[@]}"; do
    case "$part" in
      ''|'.')
        ;;
      '..')
        if ((${#parts[@]} > 0)); then
          last_index=$((${#parts[@]} - 1))
          if [[ "${parts[$last_index]}" != '..' ]]; then
            unset "parts[$last_index]"
            parts=("${parts[@]}")
          elif (( ! is_absolute )); then
            parts+=("..")
          fi
        elif (( ! is_absolute )); then
          parts+=("..")
        fi
        ;;
      *)
        parts+=("$part")
        ;;
    esac
  done

  for part in "${parts[@]}"; do
    if [[ -n "$joined" ]]; then
      joined="$joined/$part"
    else
      joined="$part"
    fi
  done

  if (( is_absolute )); then
    if [[ -n "$joined" ]]; then
      printf '/%s\n' "$joined"
    else
      printf '/\n'
    fi
  else
    if [[ -n "$joined" ]]; then
      printf '%s\n' "$joined"
    else
      printf '.\n'
    fi
  fi
}

resolve_full_path() {
  local base_directory="$1"
  local input_path="$2"

  if [[ -z "$input_path" ]]; then
    normalize_path "$base_directory"
  elif [[ "$input_path" == /* ]]; then
    normalize_path "$input_path"
  else
    normalize_path "$base_directory/$input_path"
  fi
}

ancestor_directories() {
  local current
  current="$(normalize_path "$1")"

  while :; do
    printf '%s\n' "$current"
    if [[ "$current" == "/" ]]; then
      break
    fi
    current="$(dirname "$current")"
  done
}

test_project_root_marker() {
  local directory="$1"

  [[ -e "$directory/.git" ]] && return 0
  [[ -f "$directory/global.json" ]] && return 0
  [[ -f "$directory/Directory.Build.props" ]] && return 0
  [[ -f "$directory/Directory.Build.targets" ]] && return 0
  compgen -G "$directory/*.sln" > /dev/null && return 0
  compgen -G "$directory/*.slnx" > /dev/null && return 0

  return 1
}

resolve_project_root() {
  local search_directory="$1"
  local candidate

  while IFS= read -r candidate; do
    if [[ -f "$candidate/.efm/config.env" ]]; then
      printf '%s\n' "$candidate"
      return
    fi
  done < <(ancestor_directories "$search_directory")

  while IFS= read -r candidate; do
    if test_project_root_marker "$candidate"; then
      printf '%s\n' "$candidate"
      return
    fi
  done < <(ancestor_directories "$search_directory")

  while IFS= read -r candidate; do
    if compgen -G "$candidate/*.csproj" > /dev/null; then
      printf '%s\n' "$candidate"
      return
    fi
  done < <(ancestor_directories "$search_directory")

  normalize_path "$search_directory"
}

resolve_config_path() {
  local override_path="$1"
  local search_directory="${2:-$PWD}"
  local base_directory
  local project_root

  base_directory="$(normalize_path "$search_directory")"

  if [[ -n "$override_path" ]]; then
    resolve_full_path "$base_directory" "$override_path"
    return
  fi

  if [[ -n "${EFMH_CONFIG_PATH:-}" ]]; then
    resolve_full_path "$PWD" "$EFMH_CONFIG_PATH"
    return
  fi

  project_root="$(resolve_project_root "$base_directory")"
  printf '%s\n' "$project_root/.efm/config.env"
}

resolve_storage_root() {
  local config_path
  local config_directory

  config_path="$(normalize_path "$1")"
  config_directory="$(dirname "$config_path")"

  if [[ "$(basename "$config_directory")" == ".efm" ]]; then
    dirname "$config_directory"
  else
    printf '%s\n' "$config_directory"
  fi
}

get_relative_path() {
  local base target
  local base_trimmed target_trimmed
  local IFS='/'
  local base_parts=()
  local target_parts=()
  local relative_parts=()
  local index=0
  local rel=""
  local part
  local i

  base="$(normalize_path "$1")"
  target="$(normalize_path "$2")"

  base_trimmed="${base#/}"
  target_trimmed="${target#/}"

  if [[ -n "$base_trimmed" ]]; then
    read -r -a base_parts <<< "$base_trimmed"
  fi

  if [[ -n "$target_trimmed" ]]; then
    read -r -a target_parts <<< "$target_trimmed"
  fi

  while (( index < ${#base_parts[@]} && index < ${#target_parts[@]} )); do
    if [[ "${base_parts[$index]}" != "${target_parts[$index]}" ]]; then
      break
    fi
    index=$((index + 1))
  done

  for ((i=index; i<${#base_parts[@]}; i++)); do
    relative_parts+=("..")
  done

  for ((i=index; i<${#target_parts[@]}; i++)); do
    relative_parts+=("${target_parts[$i]}")
  done

  if ((${#relative_parts[@]} == 0)); then
    printf '.\n'
    return
  fi

  for part in "${relative_parts[@]}"; do
    if [[ -n "$rel" ]]; then
      rel="$rel/$part"
    else
      rel="$part"
    fi
  done

  printf '%s\n' "$rel"
}

to_stored_path() {
  local storage_root="$1"
  local input_path="$2"

  if [[ -z "$input_path" ]]; then
    printf '\n'
    return
  fi

  get_relative_path "$storage_root" "$input_path"
}

resolve_stored_path() {
  local storage_root="$1"
  local stored_path="$2"

  if [[ -z "$stored_path" ]]; then
    normalize_path "$storage_root"
  elif [[ "$stored_path" == /* ]]; then
    normalize_path "$stored_path"
  else
    normalize_path "$storage_root/$stored_path"
  fi
}

normalize_relative_directory() {
  local input_path="${1:-}"
  local normalized

  normalized="${input_path//\\//}"
  normalized="$(trim_string "$normalized")"

  while [[ "$normalized" == ./* ]]; do
    normalized="${normalized#./}"
  done

  normalized="${normalized#/}"
  normalized="${normalized%/}"

  if [[ -z "$normalized" ]]; then
    printf '%s\n' "$DEFAULT_MIGRATIONS_DIR"
    return
  fi

  if [[ "$normalized" == /* ]]; then
    die 'The migrations directory must be relative to the DbContext project.'
  fi

  printf '%s\n' "$normalized"
}

load_configuration() {
  local config_path="$1"
  local line key value separator_index

  CONFIG_STORAGE_ROOT="$(resolve_storage_root "$config_path")"
  CONFIG_VERSION="1"
  CONFIG_WORKING_DIR="$CONFIG_STORAGE_ROOT"
  CONFIG_DBCONTEXT_PROJECT=""
  CONFIG_STARTUP_PROJECT=""
  CONFIG_MIGRATIONS_DIR="$DEFAULT_MIGRATIONS_DIR"
  CONFIG_DBCONTEXT_NAME=""

  if [[ ! -f "$config_path" ]]; then
    return
  fi

  while IFS= read -r line || [[ -n "$line" ]]; do
    line="$(trim_string "$line")"
    [[ -z "$line" ]] && continue
    [[ "$line" == \#* ]] && continue
    [[ "$line" != *=* ]] && continue

    key="${line%%=*}"
    value="${line#*=}"
    key="$(trim_string "$key")"
    value="$(trim_string "$value")"

    case "$key" in
      version)
        CONFIG_VERSION="$value"
        ;;
      working_dir)
        if [[ -n "$value" ]]; then
          CONFIG_WORKING_DIR="$(resolve_stored_path "$CONFIG_STORAGE_ROOT" "$value")"
        fi
        ;;
      dbcontext_project)
        if [[ -n "$value" ]]; then
          CONFIG_DBCONTEXT_PROJECT="$(resolve_stored_path "$CONFIG_STORAGE_ROOT" "$value")"
        fi
        ;;
      startup_project)
        if [[ -n "$value" ]]; then
          CONFIG_STARTUP_PROJECT="$(resolve_stored_path "$CONFIG_STORAGE_ROOT" "$value")"
        fi
        ;;
      migrations_dir)
        if [[ -n "$value" ]]; then
          CONFIG_MIGRATIONS_DIR="${value//\\//}"
        fi
        ;;
      dbcontext_name)
        CONFIG_DBCONTEXT_NAME="$value"
        ;;
    esac
  done < "$config_path"
}

save_configuration() {
  local config_path="$1"
  local working_dir="$2"
  local dbcontext_project="$3"
  local startup_project="$4"
  local migrations_dir="$5"
  local dbcontext_name="$6"
  local storage_root
  local config_directory

  storage_root="$(resolve_storage_root "$config_path")"
  config_directory="$(dirname "$config_path")"
  mkdir -p "$config_directory"

  {
    printf '# EF Core migrations helper shell config\n'
    printf 'version=1\n'
    printf 'working_dir=%s\n' "$(to_stored_path "$storage_root" "$working_dir")"
    printf 'dbcontext_project=%s\n' "$(to_stored_path "$storage_root" "$dbcontext_project")"
    printf 'startup_project=%s\n' "$(to_stored_path "$storage_root" "$startup_project")"
    printf 'migrations_dir=%s\n' "$(normalize_relative_directory "$migrations_dir")"
    printf 'dbcontext_name=%s\n' "$dbcontext_name"
  } > "$config_path"
}

validate_configuration() {
  [[ -d "$CONFIG_WORKING_DIR" ]] || die "Working directory was not found: $CONFIG_WORKING_DIR"
  [[ -f "$CONFIG_DBCONTEXT_PROJECT" ]] || die "DbContext project was not found: $CONFIG_DBCONTEXT_PROJECT"
  [[ "$CONFIG_DBCONTEXT_PROJECT" == *.csproj ]] || die "DbContext project must point to a .csproj file: $CONFIG_DBCONTEXT_PROJECT"
  [[ -f "$CONFIG_STARTUP_PROJECT" ]] || die "Startup project was not found: $CONFIG_STARTUP_PROJECT"
  [[ "$CONFIG_STARTUP_PROJECT" == *.csproj ]] || die "Startup project must point to a .csproj file: $CONFIG_STARTUP_PROJECT"
  [[ "$CONFIG_MIGRATIONS_DIR" != /* ]] || die 'The migrations directory must be relative to the DbContext project.'
}

discover_projects() {
  local working_dir="$1"

  DISCOVERED_PROJECTS=()
  while IFS= read -r path; do
    [[ -n "$path" ]] && DISCOVERED_PROJECTS+=("$(normalize_path "$path")")
  done < <(find "$working_dir" -type f -name '*.csproj' ! -path '*/bin/*' ! -path '*/obj/*' ! -path '*/.git/*' ! -path '*/.efm/*' | LC_ALL=C sort)
}

read_prompt_value() {
  local label="$1"
  local default_value="$2"
  local allow_empty="${3:-0}"
  local suffix=""
  local answer=""

  while true; do
    if [[ -n "$default_value" ]]; then
      suffix=" [$default_value]"
    else
      suffix=""
    fi

    printf '%s%s: ' "$label" "$suffix"
    if ! IFS= read -r answer; then
      answer=""
    fi
    answer="$(trim_string "$answer")"

    if [[ -n "$answer" ]]; then
      printf '%s\n' "$answer"
      return
    fi

    if [[ -n "$default_value" ]]; then
      printf '%s\n' "$default_value"
      return
    fi

    if [[ "$allow_empty" -eq 1 ]]; then
      printf '\n'
      return
    fi

    printf '%s\n' 'A value is required.' >&2
  done
}

prompt_project() {
  local label="$1"
  local working_dir="$2"
  local default_value="$3"
  local answer
  local index

  while true; do
    answer="$(read_prompt_value "$label" "$default_value" 0)"
    if [[ "$answer" =~ ^[0-9]+$ ]]; then
      index=$((answer - 1))
      if (( index >= 0 && index < ${#DISCOVERED_PROJECTS[@]} )); then
        get_relative_path "$working_dir" "${DISCOVERED_PROJECTS[$index]}"
        return
      fi
    fi

    if [[ -n "$answer" ]]; then
      printf '%s\n' "$answer"
      return
    fi
  done
}

run_ef() {
  local working_dir="$1"
  shift
  local args=("$@")

  command -v dotnet > /dev/null 2>&1 || {
    printf '%s\n' "Could not find 'dotnet' on PATH. Install the .NET SDK and ensure dotnet is available in your shell." >&2
    return 1
  }

  printf '> dotnet'
  local arg
  for arg in "${args[@]}"; do
    printf ' %q' "$arg"
  done
  printf '\n'

  (
    cd "$working_dir"
    dotnet "${args[@]}"
  )
}

confirm_destructive() {
  local action="$1"
  local consequence="$2"
  local first_confirmation second_confirmation

  if (( FORCE )); then
    printf '%s\n' "Skipping confirmation for '$action' because --force was specified."
    return 0
  fi

  write_lines \
    '' \
    '============================================================' \
    "DESTRUCTIVE ACTION: $action" \
    '============================================================' \
    "$consequence" \
    'This cannot be undone automatically.' \
    ''

  printf 'Continue? [y/N]: '
  IFS= read -r first_confirmation || first_confirmation=""
  if [[ ! "$first_confirmation" =~ ^[Yy]$ ]]; then
    printf '%s\n' 'Aborted.'
    return 1
  fi

  printf "Type 'YES' to confirm: "
  IFS= read -r second_confirmation || second_confirmation=""
  if [[ "$second_confirmation" != 'YES' ]]; then
    printf '%s\n' 'Aborted. Confirmation text did not match.'
    return 1
  fi

  return 0
}

confirm_update() {
  local target="$1"
  local answer

  if [[ -z "$target" ]]; then
    return 0
  fi

  if [[ "$target" == '0' ]]; then
    confirm_destructive 'Revert all migrations (update 0)' 'Every table and column created by migrations will be dropped.'
    return
  fi

  if (( FORCE )); then
    printf '%s\n' "Skipping confirmation for update $target because --force was specified."
    return 0
  fi

  write_lines \
    '' \
    "Updating to a specific migration: $target" \
    'If this target is behind the current database state, tables or columns may be dropped.'

  printf 'Continue? [y/N]: '
  IFS= read -r answer || answer=""
  if [[ ! "$answer" =~ ^[Yy]$ ]]; then
    printf '%s\n' 'Aborted.'
    return 1
  fi

  return 0
}

should_proceed() {
  local effective_command="$1"
  local effective_argument="$2"

  case "$effective_command" in
    drop)
      confirm_destructive 'Drop the database' 'The entire database and all its data will be permanently deleted.'
      ;;
    reset)
      confirm_destructive 'Reset the database (drop + re-apply all migrations)' 'The database will be dropped and recreated empty. All data will be lost.'
      ;;
    update)
      confirm_update "$effective_argument"
      ;;
    *)
      return 0
      ;;
  esac
}

build_common_args() {
  EF_ARGS=(--project "$CONFIG_DBCONTEXT_PROJECT" --startup-project "$CONFIG_STARTUP_PROJECT")
  if [[ -n "$CONFIG_DBCONTEXT_NAME" ]]; then
    EF_ARGS+=(--context "$CONFIG_DBCONTEXT_NAME")
  fi
}

create_ef_arguments() {
  local effective_command="$1"
  local effective_argument="$2"
  local migrations_path bundle_output script_output

  build_common_args
  local common_args=("${EF_ARGS[@]}")
  EF_ARGS=()
  SCRIPT_OUTPUT_PATH=""

  case "$effective_command" in
    add)
      [[ -n "$effective_argument" ]] || die "Migration name required. Example: ./$SCRIPT_NAME add AddProductsTable"
      EF_ARGS=(ef migrations add "$effective_argument" "${common_args[@]}")
      migrations_path="$(resolve_full_path "$(dirname "$CONFIG_DBCONTEXT_PROJECT")" "$CONFIG_MIGRATIONS_DIR")"
      if [[ ! -d "$migrations_path" ]]; then
        printf '%s\n' "Using --output-dir $CONFIG_MIGRATIONS_DIR because the folder does not exist yet."
        EF_ARGS+=(--output-dir "$CONFIG_MIGRATIONS_DIR")
      fi
      ;;
    update)
      EF_ARGS=(ef database update)
      if [[ -n "$effective_argument" ]]; then
        EF_ARGS+=("$effective_argument")
      fi
      EF_ARGS+=("${common_args[@]}")
      ;;
    remove)
      EF_ARGS=(ef migrations remove "${common_args[@]}")
      ;;
    list)
      EF_ARGS=(ef migrations list "${common_args[@]}")
      ;;
    drop)
      EF_ARGS=(ef database drop -f "${common_args[@]}")
      ;;
    script)
      if (( OUTPUT_OVERRIDE_SET )); then
        script_output="$OUTPUT_OVERRIDE"
      elif [[ -n "$effective_argument" ]]; then
        script_output="$effective_argument"
      else
        script_output='migrations.sql'
      fi
      EF_ARGS=(ef migrations script)
      if (( IDEMPOTENT )); then
        EF_ARGS+=(--idempotent)
      fi
      EF_ARGS+=(-o "$script_output" "${common_args[@]}")
      SCRIPT_OUTPUT_PATH="$script_output"
      ;;
    pending)
      EF_ARGS=(ef migrations has-pending-model-changes "${common_args[@]}")
      ;;
    bundle)
      EF_ARGS=(ef migrations bundle --force)
      if (( OUTPUT_OVERRIDE_SET )); then
        bundle_output="$OUTPUT_OVERRIDE"
      else
        bundle_output="$effective_argument"
      fi
      if [[ -n "$bundle_output" ]]; then
        EF_ARGS+=(-o "$bundle_output")
      fi
      EF_ARGS+=("${common_args[@]}")
      ;;
    *)
      die "'$effective_command' is not a supported EF command."
      ;;
  esac
}

show_configuration() {
  local config_path="$1"
  local context_display='<default>'

  if [[ -n "$CONFIG_DBCONTEXT_NAME" ]]; then
    context_display="$CONFIG_DBCONTEXT_NAME"
  fi

  write_lines \
    "Config path: $(normalize_path "$config_path")" \
    "  Working directory : $CONFIG_WORKING_DIR" \
    "  DbContext project : $CONFIG_DBCONTEXT_PROJECT" \
    "  Startup project   : $CONFIG_STARTUP_PROJECT" \
    "  Migrations dir    : $CONFIG_MIGRATIONS_DIR" \
    "  DbContext name    : $context_display"
}

write_setup_help() {
  cat <<EOF
$SCRIPT_NAME setup

Interactive setup:
  ./$SCRIPT_NAME setup

Non-interactive setup:
  ./$SCRIPT_NAME setup --working-dir . --dbcontext src/MyApp.Infrastructure/MyApp.Infrastructure.csproj --startup src/MyApp.Api/MyApp.Api.csproj --migrations-dir Persistence/Migrations --context AppDbContext

Options:
  --working-dir <path>     Base directory used to resolve relative paths
  --dbcontext <csproj>     DbContext project file
  --startup <csproj>       Startup project file
  --migrations-dir <path>  Relative migrations directory inside the DbContext project
  --context <name>         Optional DbContext type name
  --config <path>          Override the config file location

If --dbcontext or --startup are omitted, the script switches to interactive prompts.
EOF
}

write_config_help() {
  cat <<EOF
$SCRIPT_NAME config

Commands:
  ./$SCRIPT_NAME config      Show the current configuration and config path
  ./$SCRIPT_NAME config path Print only the config file path
EOF
}

write_command_help() {
  local topic="$1"
  local usage="$2"
  local description="$3"

  write_lines \
    "$topic" \
    '' \
    'Usage:' \
    "  $usage" \
    '' \
    "$description"
}

show_help() {
  local topic="$1"
  local config_path

  config_path="$(resolve_config_path "$CONFIG_OVERRIDE" "$PWD")"

  case "$topic" in
    setup)
      write_setup_help
      return
      ;;
    config)
      write_config_help
      return
      ;;
    add)
      write_command_help 'add' "./$SCRIPT_NAME add <Name>" 'Creates a new migration. If the configured migrations directory does not exist yet, the script passes --output-dir automatically.'
      return
      ;;
    update)
      write_command_help 'update' "./$SCRIPT_NAME update [Target] [--force]" "Updates the database to the latest migration or to a specific target. Updating to '0' requires a double confirmation unless --force is used."
      return
      ;;
    script)
      write_command_help 'script' "./$SCRIPT_NAME script [output.sql] [--output <file>] [--no-idempotent]" 'Generates a SQL script. The default output is migrations.sql and the default mode is idempotent.'
      return
      ;;
  esac

  cat <<EOF
EF Core migrations helper (shell branch)

Usage:
  ./$SCRIPT_NAME <command> [argument] [options]

Start here:
  ./$SCRIPT_NAME setup               Interactive project setup
  ./$SCRIPT_NAME config              Show the saved configuration

EF commands:
  ./$SCRIPT_NAME add <Name>          Add a migration
  ./$SCRIPT_NAME update [Target]     Apply pending migrations or move to a target
  ./$SCRIPT_NAME remove              Remove the last unapplied migration
  ./$SCRIPT_NAME list                List migrations
  ./$SCRIPT_NAME drop                Drop the database
  ./$SCRIPT_NAME reset               Drop and recreate the database from migrations
  ./$SCRIPT_NAME script [output.sql] Generate a SQL script
  ./$SCRIPT_NAME pending             Exit with code 1 when model changes are pending
  ./$SCRIPT_NAME bundle [output]     Build an efbundle executable

Useful options:
  --config <path>                    Override the config file location
  --force, -y                        Skip confirmation prompts
  --help, -h                         Show help
  --no-idempotent                    Generate a non-idempotent SQL script

Short aliases:
  a=add  u=update  ls=list  rm=remove  cfg=config  init=setup  sql=script

Default config path:
  $config_path

Run './$SCRIPT_NAME help setup' for setup options.
EOF
}

invoke_setup() {
  local current_directory effective_working_dir_input effective_working_directory config_path
  local dbcontext_input startup_input migrations_input context_input requires_prompt
  local startup_default

  current_directory="$(pwd -P)"
  if (( WORKING_DIR_OVERRIDE_SET )); then
    effective_working_dir_input="$WORKING_DIR_OVERRIDE"
  else
    effective_working_dir_input="$current_directory"
  fi
  effective_working_directory="$(resolve_full_path "$current_directory" "$effective_working_dir_input")"

  [[ -d "$effective_working_directory" ]] || die "Working directory was not found: $effective_working_directory"

  config_path="$(resolve_config_path "$CONFIG_OVERRIDE" "$effective_working_directory")"
  load_configuration "$config_path"
  discover_projects "$effective_working_directory"

  if (( DBCONTEXT_OVERRIDE_SET )); then
    dbcontext_input="$DBCONTEXT_OVERRIDE"
  elif [[ -n "$CONFIG_DBCONTEXT_PROJECT" ]]; then
    dbcontext_input="$(get_relative_path "$effective_working_directory" "$CONFIG_DBCONTEXT_PROJECT")"
  else
    dbcontext_input=""
  fi

  if (( STARTUP_OVERRIDE_SET )); then
    startup_input="$STARTUP_OVERRIDE"
  elif [[ -n "$CONFIG_STARTUP_PROJECT" ]]; then
    startup_input="$(get_relative_path "$effective_working_directory" "$CONFIG_STARTUP_PROJECT")"
  else
    startup_input="$dbcontext_input"
  fi

  if (( MIGRATIONS_DIR_OVERRIDE_SET )); then
    migrations_input="$MIGRATIONS_DIR_OVERRIDE"
  elif [[ -n "$CONFIG_MIGRATIONS_DIR" ]]; then
    migrations_input="$CONFIG_MIGRATIONS_DIR"
  else
    migrations_input="$DEFAULT_MIGRATIONS_DIR"
  fi

  if (( DBCONTEXT_NAME_OVERRIDE_SET )); then
    context_input="$DBCONTEXT_NAME_OVERRIDE"
  else
    context_input="$CONFIG_DBCONTEXT_NAME"
  fi

  requires_prompt=0
  if [[ -z "$dbcontext_input" || -z "$startup_input" ]]; then
    requires_prompt=1
  fi

  if (( requires_prompt )) && [[ ! -t 0 ]]; then
    die 'Setup requires --dbcontext and --startup when stdin is redirected.'
  fi

  if (( requires_prompt )); then
    printf '%s\n' "Configuring $SCRIPT_NAME..."
    if ((${#DISCOVERED_PROJECTS[@]} > 0)); then
      printf '%s\n' 'Discovered project files:'
      local index
      for ((index=0; index<${#DISCOVERED_PROJECTS[@]}; index++)); do
        printf '  %d. %s\n' "$((index + 1))" "$(get_relative_path "$effective_working_directory" "${DISCOVERED_PROJECTS[$index]}")"
      done
      printf '\n'
    fi

    dbcontext_input="$(prompt_project 'DbContext project (.csproj)' "$effective_working_directory" "$dbcontext_input")"
    if [[ -z "$startup_input" ]]; then
      startup_default="$dbcontext_input"
    else
      startup_default="$startup_input"
    fi
    startup_input="$(prompt_project 'Startup project (.csproj)' "$effective_working_directory" "$startup_default")"
    migrations_input="$(read_prompt_value 'Migrations directory relative to the DbContext project' "$migrations_input" 0)"
    context_input="$(read_prompt_value 'DbContext name (optional)' "$context_input" 1)"
  fi

  CONFIG_WORKING_DIR="$effective_working_directory"
  CONFIG_DBCONTEXT_PROJECT="$(resolve_full_path "$effective_working_directory" "$dbcontext_input")"
  CONFIG_STARTUP_PROJECT="$(resolve_full_path "$effective_working_directory" "$startup_input")"
  CONFIG_MIGRATIONS_DIR="$(normalize_relative_directory "$migrations_input")"
  CONFIG_DBCONTEXT_NAME="$context_input"

  validate_configuration
  save_configuration "$config_path" "$CONFIG_WORKING_DIR" "$CONFIG_DBCONTEXT_PROJECT" "$CONFIG_STARTUP_PROJECT" "$CONFIG_MIGRATIONS_DIR" "$CONFIG_DBCONTEXT_NAME"

  printf '%s\n' 'Saved configuration.'
  load_configuration "$config_path"
  show_configuration "$config_path"
}

invoke_config() {
  local argument="$1"
  local config_path

  config_path="$(resolve_config_path "$CONFIG_OVERRIDE" "$PWD")"

  if [[ "$argument" == 'path' ]]; then
    printf '%s\n' "$config_path"
    return
  fi

  if [[ ! -f "$config_path" ]]; then
    write_lines "Config path: $config_path" "No configuration found. Run './$SCRIPT_NAME setup' first."
    return
  fi

  load_configuration "$config_path"
  show_configuration "$config_path"
}

invoke_reset() {
  build_common_args
  local common_args=("${EF_ARGS[@]}")
  local exit_code

  printf '%s\n' 'Dropping database...'
  if run_ef "$CONFIG_WORKING_DIR" ef database drop -f "${common_args[@]}"; then
    :
  else
    exit_code=$?
    exit "$exit_code"
  fi

  printf '%s\n' 'Applying all migrations...'
  if run_ef "$CONFIG_WORKING_DIR" ef database update "${common_args[@]}"; then
    printf '%s\n' 'Database recreated from migrations.'
    exit 0
  else
    exit_code=$?
    exit "$exit_code"
  fi
}

while (($#)); do
  case "$1" in
    --help|-h)
      HELP_FLAG=1
      ;;
    --force|-y)
      FORCE=1
      ;;
    --no-idempotent)
      IDEMPOTENT=0
      ;;
    --idempotent)
      IDEMPOTENT=1
      ;;
    --config)
      (($# >= 2)) || die "Option '$1' requires a value."
      CONFIG_OVERRIDE="$2"
      shift
      ;;
    --config=*)
      CONFIG_OVERRIDE="${1#*=}"
      ;;
    --output)
      (($# >= 2)) || die "Option '$1' requires a value."
      OUTPUT_OVERRIDE="$2"
      OUTPUT_OVERRIDE_SET=1
      shift
      ;;
    --output=*)
      OUTPUT_OVERRIDE="${1#*=}"
      OUTPUT_OVERRIDE_SET=1
      ;;
    --working-dir)
      (($# >= 2)) || die "Option '$1' requires a value."
      WORKING_DIR_OVERRIDE="$2"
      WORKING_DIR_OVERRIDE_SET=1
      shift
      ;;
    --working-dir=*)
      WORKING_DIR_OVERRIDE="${1#*=}"
      WORKING_DIR_OVERRIDE_SET=1
      ;;
    --dbcontext)
      (($# >= 2)) || die "Option '$1' requires a value."
      DBCONTEXT_OVERRIDE="$2"
      DBCONTEXT_OVERRIDE_SET=1
      shift
      ;;
    --dbcontext=*)
      DBCONTEXT_OVERRIDE="${1#*=}"
      DBCONTEXT_OVERRIDE_SET=1
      ;;
    --startup)
      (($# >= 2)) || die "Option '$1' requires a value."
      STARTUP_OVERRIDE="$2"
      STARTUP_OVERRIDE_SET=1
      shift
      ;;
    --startup=*)
      STARTUP_OVERRIDE="${1#*=}"
      STARTUP_OVERRIDE_SET=1
      ;;
    --migrations-dir)
      (($# >= 2)) || die "Option '$1' requires a value."
      MIGRATIONS_DIR_OVERRIDE="$2"
      MIGRATIONS_DIR_OVERRIDE_SET=1
      shift
      ;;
    --migrations-dir=*)
      MIGRATIONS_DIR_OVERRIDE="${1#*=}"
      MIGRATIONS_DIR_OVERRIDE_SET=1
      ;;
    --context)
      (($# >= 2)) || die "Option '$1' requires a value."
      DBCONTEXT_NAME_OVERRIDE="$2"
      DBCONTEXT_NAME_OVERRIDE_SET=1
      shift
      ;;
    --context=*)
      DBCONTEXT_NAME_OVERRIDE="${1#*=}"
      DBCONTEXT_NAME_OVERRIDE_SET=1
      ;;
    --)
      shift
      while (($#)); do
        POSITIONALS+=("$1")
        shift
      done
      break
      ;;
    -*)
      die "Unknown option '$1'. Run './$SCRIPT_NAME help' for usage."
      ;;
    *)
      POSITIONALS+=("$1")
      ;;
  esac
  shift

done

COMMAND="$(normalize_command "${POSITIONALS[0]:-help}")"
ARGUMENT="${POSITIONALS[1]:-}"

if (( HELP_FLAG )) && [[ "$COMMAND" != 'help' ]]; then
  show_help "$COMMAND"
  exit 0
fi

if [[ "$COMMAND" == 'help' ]]; then
  HELP_TOPIC=""
  if [[ -n "$ARGUMENT" ]]; then
    HELP_TOPIC="$(normalize_command "$ARGUMENT")"
  fi
  show_help "$HELP_TOPIC"
  exit 0
fi

case "$COMMAND" in
  setup)
    invoke_setup
    exit 0
    ;;
  config)
    invoke_config "$ARGUMENT"
    exit 0
    ;;
  add|update|remove|list|drop|reset|script|pending|bundle)
    ;;
  *)
    die "Unknown command '$COMMAND'. Run './$SCRIPT_NAME help' for usage."
    ;;
esac

RESOLVED_CONFIG_PATH="$(resolve_config_path "$CONFIG_OVERRIDE" "$PWD")"
[[ -f "$RESOLVED_CONFIG_PATH" ]] || die "No configuration found. Run './$SCRIPT_NAME setup' first. Config path: $RESOLVED_CONFIG_PATH"

load_configuration "$RESOLVED_CONFIG_PATH"
validate_configuration

if ! should_proceed "$COMMAND" "$ARGUMENT"; then
  exit 2
fi

if [[ "$COMMAND" == 'reset' ]]; then
  invoke_reset
fi

create_ef_arguments "$COMMAND" "$ARGUMENT"
if run_ef "$CONFIG_WORKING_DIR" "${EF_ARGS[@]}"; then
  if [[ "$COMMAND" == 'script' ]]; then
    printf '%s\n' "SQL script written to $SCRIPT_OUTPUT_PATH"
  fi
  exit 0
else
  exit_code=$?
  exit "$exit_code"
fi
