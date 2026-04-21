<#
.SYNOPSIS
    EF Core migration helper for the CDI-PUI solution.

.DESCRIPTION
    Wraps `dotnet ef` with the correct --project and --startup-project flags
    so you don't have to type them every time.

    DbContext project  : CDI-PUI.Infra
    Startup project    : CDI-PUI.Api
    Migrations folder  : CDI-PUI.Infra/Persistence/Migrations

    Destructive actions (drop / reset / update 0 / rollback to earlier migration)
    require confirmation. Pass -Force to skip prompts (e.g. CI pipelines).

    Run `.\scripts\ef.ps1 help` for a summary of commands.

.EXAMPLE
    .\scripts\ef.ps1 add AddCustomerTable

.EXAMPLE
    .\scripts\ef.ps1 update

.EXAMPLE
    # Destructive — prompts for double confirmation
    .\scripts\ef.ps1 reset

.EXAMPLE
    # Skip prompts (CI/CD only — be careful!)
    .\scripts\ef.ps1 reset -Force
#>

[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [ValidateSet('add', 'update', 'remove', 'list', 'drop', 'reset', 'script', 'pending', 'bundle', 'help')]
    [string]$Command = 'help',

    [Parameter(Position = 1)]
    [string]$Argument,

    [string]$Output = 'migrations.sql',
    [switch]$Idempotent = $true,

    # Bypasses all confirmation prompts. Use only in CI/CD.
    [switch]$Force,

    # Show help and exit.
    [Alias('h')]
    [switch]$Help
)

# --- Configuration ---------------------------------------------------
# Change these if project names or folder layout change.
$DbContextProject = '.\CDI-PUI.Infra\'
$StartupProject   = '.\CDI-PUI.Api\'
$MigrationsDir    = 'Persistence/Migrations'
# ---------------------------------------------------------------------

$Common = @('--project', $DbContextProject, '--startup-project', $StartupProject)

function Show-Help {
    $script = $MyInvocation.ScriptName
    if (-not $script) { $script = '.\scripts\ef.ps1' }

    Write-Host ""
    Write-Host "EF Core migration helper — CDI-PUI" -ForegroundColor Cyan
    Write-Host "Wraps `dotnet ef` with the correct --project/--startup-project flags." -ForegroundColor Gray
    Write-Host ""
    Write-Host "Configuration:" -ForegroundColor White
    Write-Host "  DbContext project : $DbContextProject"
    Write-Host "  Startup project   : $StartupProject"
    Write-Host "  Migrations folder : $DbContextProject$MigrationsDir"
    Write-Host ""
    Write-Host "Usage:" -ForegroundColor White
    Write-Host "  .\scripts\ef.ps1 <command> [argument] [-Force] [-Help]"
    Write-Host ""
    Write-Host "Commands:" -ForegroundColor White
    Write-Host "  add <Name>          " -NoNewline; Write-Host "Create a new migration."
    Write-Host "  update [Target]     " -NoNewline; Write-Host "Apply pending migrations, or update to a target migration."
    Write-Host "                        (Prompts if Target is specified. Double prompt for 'update 0'.)"
    Write-Host "  remove              " -NoNewline; Write-Host "Remove the last (unapplied) migration file."
    Write-Host "  list                " -NoNewline; Write-Host "List migrations with Applied/Pending status."
    Write-Host "  drop                " -NoNewline -ForegroundColor Red; Write-Host "Drop the database. (Double confirmation.)" -ForegroundColor Red
    Write-Host "  reset               " -NoNewline -ForegroundColor Red; Write-Host "Drop + re-apply all migrations. (Double confirmation.)" -ForegroundColor Red
    Write-Host "  script [-Output]    " -NoNewline; Write-Host "Generate an idempotent SQL script (default: migrations.sql)."
    Write-Host "  pending             " -NoNewline; Write-Host "Exit 1 if the model has uncommitted changes."
    Write-Host "  bundle              " -NoNewline; Write-Host "Build a self-contained efbundle.exe."
    Write-Host "  help                " -NoNewline; Write-Host "Show this help. Also: -Help, -h."
    Write-Host ""
    Write-Host "Flags:" -ForegroundColor White
    Write-Host "  -Force              Skip all confirmations. CI/CD only — do not use interactively."
    Write-Host "  -Output <file>      Output file for 'script' (default: migrations.sql)."
    Write-Host "  -Help, -h           Show this help."
    Write-Host ""
    Write-Host "Examples:" -ForegroundColor White
    Write-Host "  .\scripts\ef.ps1 add AddCustomerTable"
    Write-Host "  .\scripts\ef.ps1 update"
    Write-Host "  .\scripts\ef.ps1 update DatabaseInitialization   # rollback, prompts"
    Write-Host "  .\scripts\ef.ps1 reset                           # prompts twice"
    Write-Host "  .\scripts\ef.ps1 reset -Force                    # no prompts (CI)"
    Write-Host "  .\scripts\ef.ps1 script -Output release.sql"
    Write-Host ""
    Write-Host "For the full `dotnet ef` reference, run: dotnet ef --help" -ForegroundColor Gray
    Write-Host ""
}

if ($Help -or $Command -eq 'help') {
    Show-Help
    exit 0
}

function Invoke-Ef {
    param([string[]]$EfArgs)
    Write-Host "▶ dotnet ef $($EfArgs -join ' ')" -ForegroundColor Cyan
    & dotnet ef @EfArgs
    if ($LASTEXITCODE -ne 0) {
        throw "dotnet ef failed with exit code $LASTEXITCODE"
    }
}

function Confirm-Destructive {
    <#
    Double-confirmation prompt for destructive actions.
    - First prompt: y/N
    - Second prompt: must type YES in all caps
    Aborts script with exit 0 on any mismatch. Bypassed by -Force.
    #>
    param(
        [Parameter(Mandatory)][string]$Action,
        [Parameter(Mandatory)][string]$Consequence
    )

    if ($Force) {
        Write-Host "⚠  -Force specified, skipping confirmation for: $Action" -ForegroundColor Yellow
        return
    }

    Write-Host ""
    Write-Host "══════════════════════════════════════════════════════════════" -ForegroundColor Red
    Write-Host "  ⚠  DESTRUCTIVE ACTION: $Action" -ForegroundColor Red
    Write-Host "══════════════════════════════════════════════════════════════" -ForegroundColor Red
    Write-Host "  $Consequence" -ForegroundColor Yellow
    Write-Host "  This CANNOT be undone automatically." -ForegroundColor Yellow
    Write-Host ""

    $confirm1 = Read-Host "  Continue? [y/N]"
    if ($confirm1 -notmatch '^[yY]$') {
        Write-Host "✗ Aborted." -ForegroundColor Yellow
        exit 0
    }

    Write-Host ""
    Write-Host "  Type 'YES' (uppercase) to confirm:" -ForegroundColor Red -NoNewline
    Write-Host " " -NoNewline
    $confirm2 = Read-Host
    if ($confirm2 -cne 'YES') {
        Write-Host "✗ Aborted — confirmation did not match." -ForegroundColor Yellow
        exit 0
    }

    Write-Host "✓ Confirmed. Proceeding..." -ForegroundColor Green
    Write-Host ""
}

function Confirm-Rollback {
    <#
    Single-prompt confirmation — used when target is a named migration,
    which *might* be a rollback and could drop tables/columns.
    #>
    param([string]$Target)

    if ($Force) { return }

    Write-Host ""
    Write-Host "⚠  Updating to a specific migration: $Target" -ForegroundColor Yellow
    Write-Host "   If this migration is BEHIND the current DB state, tables/columns" -ForegroundColor Yellow
    Write-Host "   may be dropped and data lost." -ForegroundColor Yellow
    Write-Host ""
    $ans = Read-Host "Continue? [y/N]"
    if ($ans -notmatch '^[yY]$') {
        Write-Host "✗ Aborted." -ForegroundColor Yellow
        exit 0
    }
}

switch ($Command) {

    'add' {
        if ([string]::IsNullOrWhiteSpace($Argument)) {
            throw "Migration name required. Example: .\scripts\ef.ps1 add AddProductsTable"
        }

        # Only pass --output-dir if the Migrations folder doesn't exist yet
        $migrationsPath = Join-Path $DbContextProject $MigrationsDir
        $efArgs = @('migrations', 'add', $Argument) + $Common
        if (-not (Test-Path $migrationsPath)) {
            $efArgs += @('--output-dir', $MigrationsDir)
            Write-Host "First migration detected — using --output-dir $MigrationsDir" -ForegroundColor Yellow
        }
        Invoke-Ef $efArgs
    }

    'update' {
        if ($Argument -eq '0') {
            # Reverting ALL migrations — highly destructive
            Confirm-Destructive `
                -Action "Revert ALL migrations (update 0)" `
                -Consequence "Every table and column created by migrations will be DROPPED."
        }
        elseif ($Argument) {
            # Specific target — could be forward or backward
            Confirm-Rollback -Target $Argument
        }
        # else: no arg = forward to latest, no confirmation

        $efArgs = @('database', 'update')
        if ($Argument) { $efArgs += $Argument }
        $efArgs += $Common
        Invoke-Ef $efArgs
    }

    'remove' {
        # Not destructive to data — only removes the local migration file
        Invoke-Ef (@('migrations', 'remove') + $Common)
    }

    'list' {
        Invoke-Ef (@('migrations', 'list') + $Common)
    }

    'drop' {
        Confirm-Destructive `
            -Action "Drop the database" `
            -Consequence "The entire database and ALL its data will be permanently deleted."
        Invoke-Ef (@('database', 'drop', '-f') + $Common)
    }

    'reset' {
        Confirm-Destructive `
            -Action "Reset the database (drop + re-apply all migrations)" `
            -Consequence "The database will be dropped and recreated empty. ALL data will be lost."

        Write-Host "Dropping database..." -ForegroundColor Yellow
        Invoke-Ef (@('database', 'drop', '-f') + $Common)
        Write-Host "Applying all migrations..." -ForegroundColor Yellow
        Invoke-Ef (@('database', 'update') + $Common)
        Write-Host "✓ Database recreated from migrations." -ForegroundColor Green
    }

    'script' {
        $efArgs = @('migrations', 'script')
        if ($Idempotent) { $efArgs += '--idempotent' }
        $efArgs += @('-o', $Output)
        $efArgs += $Common
        Invoke-Ef $efArgs
        Write-Host "✓ SQL script written to $Output" -ForegroundColor Green
    }

    'pending' {
        Invoke-Ef (@('migrations', 'has-pending-model-changes') + $Common)
    }

    'bundle' {
        Invoke-Ef (@('migrations', 'bundle', '--force') + $Common)
    }
}
