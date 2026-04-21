# EF Core Migration Scripts

Helper scripts that wrap `dotnet ef` with the correct `--project` and `--startup-project`
flags for this solution, so you don't have to remember them.

**Projects:**
- DbContext lives in `CDI-PUI.Infra`
- Startup (configuration, DI) lives in `CDI-PUI.Api`
- Migrations output: `CDI-PUI.Infra/Persistence/Migrations`

## Setup (once per machine)

```powershell
# Ensure EF tools are installed
dotnet tool install --global dotnet-ef
# or, if the repo uses a local tool manifest:
dotnet tool restore
```

On Linux/macOS, make the bash script executable:

```bash
chmod +x scripts/ef.sh
```

On Windows, if PowerShell blocks the script with an execution-policy error, either unblock the
single file (safest) or allow local unsigned scripts for your user:

```powershell
Unblock-File .\scripts\ef.ps1
# or, one-time, wider scope:
Set-ExecutionPolicy -Scope CurrentUser RemoteSigned
```

## Getting help

Both scripts have a built-in help command listing every subcommand, flag, and example:

```powershell
.\scripts\ef.ps1 help        # or -Help, -h, or no args
```

```bash
./scripts/ef.sh help         # or --help, -h, or no args
```

PowerShell's built-in help also works:

```powershell
Get-Help .\scripts\ef.ps1 -Full
```

## Safety — Confirmations for destructive actions

Actions that can cause **data loss** require confirmation:

| Command | Confirmation |
|---|---|
| `drop` | 🔴 Double (`y/N` + type `YES`) |
| `reset` | 🔴 Double (`y/N` + type `YES`) |
| `update 0` | 🔴 Double (`y/N` + type `YES`) |
| `update <specific-migration>` | 🟡 Single (`y/N`) — could be a rollback |
| everything else | ✅ No prompt |

To bypass prompts in CI/CD, pass `-Force` (PowerShell) or `--force` (bash):

```powershell
.\scripts\ef.ps1 reset -Force
```

```bash
./scripts/ef.sh reset --force
```

**Do not use `-Force` interactively.** It exists solely for automated pipelines.

## Windows / PowerShell — `scripts\ef.ps1`

| Command | Purpose | Destructive? |
|---|---|---|
| `.\scripts\ef.ps1 help` | Show usage summary (also `-Help`, `-h`, no args) | No |
| `.\scripts\ef.ps1 add <n>` | Add a new migration | No |
| `.\scripts\ef.ps1 update` | Apply all pending migrations | No |
| `.\scripts\ef.ps1 update <Target>` | Update/rollback to a specific migration | 🟡 Single prompt |
| `.\scripts\ef.ps1 update 0` | Revert ALL migrations | 🔴 Double prompt |
| `.\scripts\ef.ps1 remove` | Remove the last (unapplied) migration file | No |
| `.\scripts\ef.ps1 list` | List migrations with Applied/Pending status | No |
| `.\scripts\ef.ps1 drop` | Drop the database | 🔴 Double prompt |
| `.\scripts\ef.ps1 reset` | Drop + re-apply all migrations (recreate DB) | 🔴 Double prompt |
| `.\scripts\ef.ps1 script` | Generate idempotent SQL script | No |
| `.\scripts\ef.ps1 pending` | Exit code 1 if model has uncommitted changes | No |
| `.\scripts\ef.ps1 bundle` | Build a self-contained `efbundle.exe` | No |

## Linux / macOS — `scripts/ef.sh`

Same commands, same protections:

```bash
./scripts/ef.sh help               # usage
./scripts/ef.sh add AddCustomerTable
./scripts/ef.sh update
./scripts/ef.sh reset              # prompts twice
./scripts/ef.sh reset --force      # no prompts (CI only)
```

## Examples

```powershell
# Don't remember the commands? Run help.
.\scripts\ef.ps1 help

# Daily workflow: change your entities, then:
.\scripts\ef.ps1 add AddProductsTable
# (read the generated .cs file!)
.\scripts\ef.ps1 update

# Recreate your local DB from scratch (prompts for double confirmation)
.\scripts\ef.ps1 reset

# Roll back to an earlier migration (prompts once)
.\scripts\ef.ps1 update DatabaseInitialization

# Undo the last migration (only if not yet applied to DB, no prompt)
.\scripts\ef.ps1 remove

# Generate SQL for DBA to review before prod deploy
.\scripts\ef.ps1 script -Output release-2026-04.sql
```

## If project paths ever change

Edit the variables at the top of both `ef.ps1` and `ef.sh`:

```powershell
$DbContextProject = '.\CDI-PUI.Infra\'
$StartupProject   = '.\CDI-PUI.Api\'
$MigrationsDir    = 'Persistence/Migrations'
```
