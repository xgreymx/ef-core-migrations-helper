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
    [Parameter(Mandatory = $true, Position = 0)]
    [ValidateSet('add', 'update', 'remove', 'list', 'drop', 'reset', 'script', 'pending', 'bundle')]
    [string]$Command,

    [Parameter(Position = 1)]
    [string]$Argument,

    [string]$Output = 'migrations.sql',
    [switch]$Idempotent = $true,

    # Bypasses all confirmation prompts. Use only in CI/CD.
    [switch]$Force
)

# --- Configuration ---------------------------------------------------
# Change these if project names or folder layout change.
$DbContextProject = '.\CDI-PUI.Infra\'
$StartupProject   = '.\CDI-PUI.Api\'
$MigrationsDir    = 'Persistence/Migrations'
# ---------------------------------------------------------------------

$Common = @('--project', $DbContextProject, '--startup-project', $StartupProject)

function Invoke-Ef {
    param([string[]]$Args)
    Write-Host "▶ dotnet ef $($Args -join ' ')" -ForegroundColor Cyan
    & dotnet ef @Args
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
        $args = @('migrations', 'add', $Argument) + $Common
        if (-not (Test-Path $migrationsPath)) {
            $args += @('--output-dir', $MigrationsDir)
            Write-Host "First migration detected — using --output-dir $MigrationsDir" -ForegroundColor Yellow
        }
        Invoke-Ef $args
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

        $args = @('database', 'update')
        if ($Argument) { $args += $Argument }
        $args += $Common
        Invoke-Ef $args
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
        $args = @('migrations', 'script')
        if ($Idempotent) { $args += '--idempotent' }
        $args += @('-o', $Output)
        $args += $Common
        Invoke-Ef $args
        Write-Host "✓ SQL script written to $Output" -ForegroundColor Green
    }

    'pending' {
        Invoke-Ef (@('migrations', 'has-pending-model-changes') + $Common)
    }

    'bundle' {
        Invoke-Ef (@('migrations', 'bundle', '--force') + $Common)
    }
}
