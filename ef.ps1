<#
.SYNOPSIS
    EF Core migrations helper for the shell-only branch.

.DESCRIPTION
    Wraps dotnet ef with a saved project configuration so you do not have to
    repeat --project and --startup-project for every command.

    Run .\ef.ps1 setup to create or update the project-scoped configuration.

.EXAMPLE
    .\ef.ps1 setup

.EXAMPLE
    .\ef.ps1 add AddProductsTable

.EXAMPLE
    .\ef.ps1 script -Output release.sql
#>

[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [string]$Command = 'help',

    [Parameter(Position = 1)]
    [string]$Argument,

    [string]$Config,
    [string]$Output,
    [string]$WorkingDir,
    [string]$DbContext,
    [string]$Startup,
    [string]$MigrationsDir,

    [Alias('Context')]
    [string]$DbContextName,

    [Alias('y')]
    [switch]$Force,

    [switch]$NoIdempotent,

    [Alias('h')]
    [switch]$Help
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$ScriptName = if ($PSCommandPath) { Split-Path -Leaf $PSCommandPath } else { 'ef.ps1' }
$DefaultMigrationsDir = 'Persistence/Migrations'

$script:HasOutputOverride = $PSBoundParameters.ContainsKey('Output')
$script:HasWorkingDirOverride = $PSBoundParameters.ContainsKey('WorkingDir')
$script:HasDbContextOverride = $PSBoundParameters.ContainsKey('DbContext')
$script:HasStartupOverride = $PSBoundParameters.ContainsKey('Startup')
$script:HasMigrationsDirOverride = $PSBoundParameters.ContainsKey('MigrationsDir')
$script:HasDbContextNameOverride = $PSBoundParameters.ContainsKey('DbContextName')

function Write-Lines {
    param([string[]]$Lines)

    foreach ($line in $Lines) {
        Write-Host $line
    }
}

function Normalize-Command {
    param([string]$Name)

    if ([string]::IsNullOrWhiteSpace($Name)) {
        return 'help'
    }

    switch ($Name.Trim().ToLowerInvariant()) {
        'a' { 'add' }
        'cfg' { 'config' }
        'h' { 'help' }
        'init' { 'setup' }
        'ls' { 'list' }
        'rm' { 'remove' }
        'sql' { 'script' }
        'u' { 'update' }
        'up' { 'update' }
        default { $Name.Trim().ToLowerInvariant() }
    }
}

function Resolve-FullPath {
    param(
        [Parameter(Mandatory)][string]$BaseDirectory,
        [Parameter(Mandatory)][string]$InputPath
    )

    if ([string]::IsNullOrWhiteSpace($InputPath)) {
        return [IO.Path]::GetFullPath($BaseDirectory)
    }

    if ([IO.Path]::IsPathRooted($InputPath)) {
        return [IO.Path]::GetFullPath($InputPath)
    }

    return [IO.Path]::GetFullPath([IO.Path]::Combine($BaseDirectory, $InputPath))
}

function Get-AncestorDirectories {
    param([Parameter(Mandatory)][string]$StartDirectory)

    $current = [IO.DirectoryInfo]::new([IO.Path]::GetFullPath($StartDirectory))
    while ($null -ne $current) {
        $current.FullName
        $current = $current.Parent
    }
}

function Test-ProjectRootMarker {
    param([Parameter(Mandatory)][string]$Directory)

    if (Test-Path (Join-Path $Directory '.git')) {
        return $true
    }

    if (Test-Path (Join-Path $Directory 'global.json') -PathType Leaf) {
        return $true
    }

    if (Test-Path (Join-Path $Directory 'Directory.Build.props') -PathType Leaf) {
        return $true
    }

    if (Test-Path (Join-Path $Directory 'Directory.Build.targets') -PathType Leaf) {
        return $true
    }

    if (Get-ChildItem -LiteralPath $Directory -Filter '*.sln' -File -ErrorAction SilentlyContinue | Select-Object -First 1) {
        return $true
    }

    if (Get-ChildItem -LiteralPath $Directory -Filter '*.slnx' -File -ErrorAction SilentlyContinue | Select-Object -First 1) {
        return $true
    }

    return $false
}

function Resolve-ProjectRoot {
    param([Parameter(Mandatory)][string]$SearchDirectory)

    $fullSearchDirectory = [IO.Path]::GetFullPath($SearchDirectory)

    foreach ($candidate in Get-AncestorDirectories -StartDirectory $fullSearchDirectory) {
        if (Test-Path (Join-Path $candidate '.efm\config.env') -PathType Leaf) {
            return $candidate
        }
    }

    foreach ($candidate in Get-AncestorDirectories -StartDirectory $fullSearchDirectory) {
        if (Test-ProjectRootMarker -Directory $candidate) {
            return $candidate
        }
    }

    foreach ($candidate in Get-AncestorDirectories -StartDirectory $fullSearchDirectory) {
        if (Get-ChildItem -LiteralPath $candidate -Filter '*.csproj' -File -ErrorAction SilentlyContinue | Select-Object -First 1) {
            return $candidate
        }
    }

    return $fullSearchDirectory
}

function Resolve-ConfigPath {
    param(
        [string]$OverridePath,
        [string]$SearchDirectory = (Get-Location).Path
    )

    $baseDirectory = [IO.Path]::GetFullPath($SearchDirectory)

    if (-not [string]::IsNullOrWhiteSpace($OverridePath)) {
        return Resolve-FullPath -BaseDirectory $baseDirectory -InputPath $OverridePath
    }

    if (-not [string]::IsNullOrWhiteSpace($env:EFMH_CONFIG_PATH)) {
        return Resolve-FullPath -BaseDirectory (Get-Location).Path -InputPath $env:EFMH_CONFIG_PATH
    }

    $projectRoot = Resolve-ProjectRoot -SearchDirectory $baseDirectory
    return Join-Path (Join-Path $projectRoot '.efm') 'config.env'
}

function Resolve-StorageRoot {
    param([Parameter(Mandatory)][string]$ConfigPath)

    $configDirectory = Split-Path -Parent ([IO.Path]::GetFullPath($ConfigPath))
    if ([string]::IsNullOrWhiteSpace($configDirectory)) {
        throw "Unable to determine the config directory for '$ConfigPath'."
    }

    $directoryInfo = [IO.DirectoryInfo]::new($configDirectory)
    if ($directoryInfo.Name -ieq '.efm' -and $null -ne $directoryInfo.Parent) {
        return $directoryInfo.Parent.FullName
    }

    return $directoryInfo.FullName
}

function Convert-ToStoredPath {
    param(
        [Parameter(Mandatory)][string]$StorageRoot,
        [Parameter(Mandatory)][string]$InputPath
    )

    if ([string]::IsNullOrWhiteSpace($InputPath)) {
        return ''
    }

    return [IO.Path]::GetRelativePath($StorageRoot, [IO.Path]::GetFullPath($InputPath)).Replace('\', '/')
}

function Resolve-StoredPath {
    param(
        [Parameter(Mandatory)][string]$StorageRoot,
        [Parameter(Mandatory)][string]$StoredPath
    )

    if ([string]::IsNullOrWhiteSpace($StoredPath)) {
        return [IO.Path]::GetFullPath($StorageRoot)
    }

    if ([IO.Path]::IsPathRooted($StoredPath)) {
        return [IO.Path]::GetFullPath($StoredPath)
    }

    return [IO.Path]::GetFullPath([IO.Path]::Combine($StorageRoot, $StoredPath))
}

function Get-RelativePath {
    param(
        [Parameter(Mandatory)][string]$BaseDirectory,
        [Parameter(Mandatory)][string]$InputPath
    )

    return [IO.Path]::GetRelativePath([IO.Path]::GetFullPath($BaseDirectory), [IO.Path]::GetFullPath($InputPath)).Replace('\', '/')
}

function Normalize-RelativeDirectory {
    param([string]$InputPath)

    $normalized = if ($null -eq $InputPath) { '' } else { $InputPath.Trim().Replace('\', '/') }
    while ($normalized.StartsWith('./', [StringComparison]::Ordinal)) {
        $normalized = $normalized.Substring(2)
    }

    $normalized = $normalized.Trim('/')

    if ([string]::IsNullOrWhiteSpace($normalized)) {
        return $DefaultMigrationsDir
    }

    if ([IO.Path]::IsPathRooted($normalized)) {
        throw 'The migrations directory must be relative to the DbContext project.'
    }

    return $normalized
}

function New-ConfigurationObject {
    param([Parameter(Mandatory)][string]$ConfigPath)

    $storageRoot = Resolve-StorageRoot -ConfigPath $ConfigPath

    return [pscustomobject]@{
        Version             = '1'
        WorkingDirectory    = $storageRoot
        DbContextProject    = ''
        StartupProject      = ''
        MigrationsDirectory = $DefaultMigrationsDir
        DbContextName       = ''
        ConfigPath          = [IO.Path]::GetFullPath($ConfigPath)
        StorageRoot         = $storageRoot
    }
}

function Load-Configuration {
    param([Parameter(Mandatory)][string]$ConfigPath)

    $configuration = New-ConfigurationObject -ConfigPath $ConfigPath
    if (-not (Test-Path $ConfigPath -PathType Leaf)) {
        return $configuration
    }

    foreach ($line in [IO.File]::ReadAllLines([IO.Path]::GetFullPath($ConfigPath))) {
        $trimmed = $line.Trim()
        if ($trimmed.Length -eq 0 -or $trimmed.StartsWith('#', [StringComparison]::Ordinal)) {
            continue
        }

        $separatorIndex = $line.IndexOf('=')
        if ($separatorIndex -lt 0) {
            continue
        }

        $key = $line.Substring(0, $separatorIndex).Trim()
        $value = $line.Substring($separatorIndex + 1).Trim()

        switch ($key) {
            'version' {
                $configuration.Version = $value
            }
            'working_dir' {
                if ($value) {
                    $configuration.WorkingDirectory = Resolve-StoredPath -StorageRoot $configuration.StorageRoot -StoredPath $value
                }
            }
            'dbcontext_project' {
                if ($value) {
                    $configuration.DbContextProject = Resolve-StoredPath -StorageRoot $configuration.StorageRoot -StoredPath $value
                }
            }
            'startup_project' {
                if ($value) {
                    $configuration.StartupProject = Resolve-StoredPath -StorageRoot $configuration.StorageRoot -StoredPath $value
                }
            }
            'migrations_dir' {
                if ($value) {
                    $configuration.MigrationsDirectory = $value.Replace('\', '/')
                }
            }
            'dbcontext_name' {
                $configuration.DbContextName = $value
            }
        }
    }

    return $configuration
}

function Save-Configuration {
    param(
        [Parameter(Mandatory)][pscustomobject]$Configuration,
        [Parameter(Mandatory)][string]$ConfigPath
    )

    $fullConfigPath = [IO.Path]::GetFullPath($ConfigPath)
    $storageRoot = Resolve-StorageRoot -ConfigPath $fullConfigPath
    $configDirectory = Split-Path -Parent $fullConfigPath

    [IO.Directory]::CreateDirectory($configDirectory) | Out-Null

    $lines = @(
        '# EF Core migrations helper shell config',
        'version=1',
        "working_dir=$(Convert-ToStoredPath -StorageRoot $storageRoot -InputPath $Configuration.WorkingDirectory)",
        "dbcontext_project=$(Convert-ToStoredPath -StorageRoot $storageRoot -InputPath $Configuration.DbContextProject)",
        "startup_project=$(Convert-ToStoredPath -StorageRoot $storageRoot -InputPath $Configuration.StartupProject)",
        "migrations_dir=$(Normalize-RelativeDirectory -InputPath $Configuration.MigrationsDirectory)",
        "dbcontext_name=$($Configuration.DbContextName)"
    )

    $content = ($lines -join [Environment]::NewLine) + [Environment]::NewLine
    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    [IO.File]::WriteAllText($fullConfigPath, $content, $utf8NoBom)
}

function Validate-Configuration {
    param([Parameter(Mandatory)][pscustomobject]$Configuration)

    if (-not (Test-Path $Configuration.WorkingDirectory -PathType Container)) {
        throw "Working directory was not found: $($Configuration.WorkingDirectory)"
    }

    if (-not (Test-Path $Configuration.DbContextProject -PathType Leaf)) {
        throw "DbContext project was not found: $($Configuration.DbContextProject)"
    }

    if (-not $Configuration.DbContextProject.EndsWith('.csproj', [StringComparison]::OrdinalIgnoreCase)) {
        throw "DbContext project must point to a .csproj file: $($Configuration.DbContextProject)"
    }

    if (-not (Test-Path $Configuration.StartupProject -PathType Leaf)) {
        throw "Startup project was not found: $($Configuration.StartupProject)"
    }

    if (-not $Configuration.StartupProject.EndsWith('.csproj', [StringComparison]::OrdinalIgnoreCase)) {
        throw "Startup project must point to a .csproj file: $($Configuration.StartupProject)"
    }

    if ([IO.Path]::IsPathRooted($Configuration.MigrationsDirectory)) {
        throw 'The migrations directory must be relative to the DbContext project.'
    }
}

function Get-DiscoveredProjects {
    param([Parameter(Mandatory)][string]$WorkingDirectory)

    return @(Get-ChildItem -LiteralPath $WorkingDirectory -Filter '*.csproj' -File -Recurse -ErrorAction SilentlyContinue |
        Where-Object {
            $_.FullName -notmatch '[\\/](bin|obj|\.git|\.efm)[\\/]'
        } |
        Sort-Object FullName |
        ForEach-Object FullName)
}

function Read-PromptValue {
    param(
        [Parameter(Mandatory)][string]$Label,
        [string]$DefaultValue,
        [switch]$AllowEmpty
    )

    while ($true) {
        $suffix = if ([string]::IsNullOrWhiteSpace($DefaultValue)) { '' } else { " [$DefaultValue]" }
        $answer = Read-Host "$Label$suffix"

        if (-not [string]::IsNullOrWhiteSpace($answer)) {
            return $answer.Trim()
        }

        if (-not [string]::IsNullOrWhiteSpace($DefaultValue)) {
            return $DefaultValue
        }

        if ($AllowEmpty) {
            return ''
        }

        Write-Host 'A value is required.' -ForegroundColor Yellow
    }
}

function Prompt-Project {
    param(
        [Parameter(Mandatory)][string]$Label,
        [Parameter(Mandatory)][string]$WorkingDirectory,
        [Parameter(Mandatory)][string[]]$Projects,
        [string]$DefaultValue
    )

    while ($true) {
        $answer = Read-PromptValue -Label $Label -DefaultValue $DefaultValue
        $index = 0

        if ([int]::TryParse($answer, [ref]$index) -and $index -ge 1 -and $index -le $Projects.Count) {
            return Get-RelativePath -BaseDirectory $WorkingDirectory -InputPath $Projects[$index - 1]
        }

        if (-not [string]::IsNullOrWhiteSpace($answer)) {
            return $answer
        }
    }
}

function Format-CommandArgument {
    param([Parameter(Mandatory)][string]$ArgumentValue)

    if ($ArgumentValue -match '\s') {
        return '"' + $ArgumentValue + '"'
    }

    return $ArgumentValue
}

function Invoke-Ef {
    param(
        [Parameter(Mandatory)][string]$WorkingDirectory,
        [Parameter(Mandatory)][string[]]$Arguments
    )

    if (-not (Get-Command dotnet -ErrorAction SilentlyContinue)) {
        throw "Could not find 'dotnet' on PATH. Install the .NET SDK and ensure dotnet is available in your shell."
    }

    $display = ($Arguments | ForEach-Object { Format-CommandArgument -ArgumentValue $_ }) -join ' '
    Write-Host "> dotnet $display" -ForegroundColor Cyan

    $exitCode = 0
    Push-Location $WorkingDirectory
    try {
        & dotnet @Arguments
        $exitCode = $LASTEXITCODE
    }
    finally {
        Pop-Location
    }

    return [int]$exitCode
}

function Confirm-Destructive {
    param(
        [Parameter(Mandatory)][string]$Action,
        [Parameter(Mandatory)][string]$Consequence,
        [switch]$Bypass
    )

    if ($Bypass) {
        Write-Host "Skipping confirmation for '$Action' because -Force was specified." -ForegroundColor Yellow
        return $true
    }

    Write-Host ''
    Write-Host '============================================================' -ForegroundColor Red
    Write-Host "DESTRUCTIVE ACTION: $Action" -ForegroundColor Red
    Write-Host '============================================================' -ForegroundColor Red
    Write-Host $Consequence -ForegroundColor Yellow
    Write-Host 'This cannot be undone automatically.' -ForegroundColor Yellow
    Write-Host ''

    $firstConfirmation = Read-Host 'Continue? [y/N]'
    if ($firstConfirmation -notmatch '^[yY]$') {
        Write-Host 'Aborted.' -ForegroundColor Yellow
        return $false
    }

    $secondConfirmation = Read-Host "Type 'YES' to confirm"
    if ($secondConfirmation -cne 'YES') {
        Write-Host 'Aborted. Confirmation text did not match.' -ForegroundColor Yellow
        return $false
    }

    return $true
}

function Confirm-Update {
    param(
        [string]$Target,
        [switch]$Bypass
    )

    if ([string]::IsNullOrWhiteSpace($Target)) {
        return $true
    }

    if ($Target -eq '0') {
        return Confirm-Destructive -Action 'Revert all migrations (update 0)' -Consequence 'Every table and column created by migrations will be dropped.' -Bypass:$Bypass
    }

    if ($Bypass) {
        Write-Host "Skipping confirmation for update $Target because -Force was specified." -ForegroundColor Yellow
        return $true
    }

    Write-Host ''
    Write-Host "Updating to a specific migration: $Target" -ForegroundColor Yellow
    Write-Host 'If this target is behind the current database state, tables or columns may be dropped.' -ForegroundColor Yellow
    $answer = Read-Host 'Continue? [y/N]'
    if ($answer -notmatch '^[yY]$') {
        Write-Host 'Aborted.' -ForegroundColor Yellow
        return $false
    }

    return $true
}

function Should-Proceed {
    param(
        [Parameter(Mandatory)][string]$EffectiveCommand,
        [string]$EffectiveArgument
    )

    switch ($EffectiveCommand) {
        'drop' {
            return Confirm-Destructive -Action 'Drop the database' -Consequence 'The entire database and all its data will be permanently deleted.' -Bypass:$Force
        }
        'reset' {
            return Confirm-Destructive -Action 'Reset the database (drop + re-apply all migrations)' -Consequence 'The database will be dropped and recreated empty. All data will be lost.' -Bypass:$Force
        }
        'update' {
            return Confirm-Update -Target $EffectiveArgument -Bypass:$Force
        }
        default {
            return $true
        }
    }
}

function Build-CommonArguments {
    param([Parameter(Mandatory)][pscustomobject]$Configuration)

    $arguments = @(
        '--project', $Configuration.DbContextProject,
        '--startup-project', $Configuration.StartupProject
    )

    if (-not [string]::IsNullOrWhiteSpace($Configuration.DbContextName)) {
        $arguments += @('--context', $Configuration.DbContextName)
    }

    return $arguments
}

function New-EfArguments {
    param(
        [Parameter(Mandatory)][pscustomobject]$Configuration,
        [Parameter(Mandatory)][string]$EffectiveCommand,
        [string]$EffectiveArgument
    )

    switch ($EffectiveCommand) {
        'add' {
            if ([string]::IsNullOrWhiteSpace($EffectiveArgument)) {
                throw "Migration name required. Example: .\$ScriptName add AddProductsTable"
            }

            $arguments = @('ef', 'migrations', 'add', $EffectiveArgument) + (Build-CommonArguments -Configuration $Configuration)
            $migrationsPath = Join-Path (Split-Path -Parent $Configuration.DbContextProject) $Configuration.MigrationsDirectory
            if (-not (Test-Path $migrationsPath -PathType Container)) {
                Write-Host "Using --output-dir $($Configuration.MigrationsDirectory) because the folder does not exist yet." -ForegroundColor Yellow
                $arguments += @('--output-dir', $Configuration.MigrationsDirectory)
            }

            return $arguments
        }
        'update' {
            $arguments = @('ef', 'database', 'update')
            if (-not [string]::IsNullOrWhiteSpace($EffectiveArgument)) {
                $arguments += $EffectiveArgument
            }

            return $arguments + (Build-CommonArguments -Configuration $Configuration)
        }
        'remove' {
            return @('ef', 'migrations', 'remove') + (Build-CommonArguments -Configuration $Configuration)
        }
        'list' {
            return @('ef', 'migrations', 'list') + (Build-CommonArguments -Configuration $Configuration)
        }
        'drop' {
            return @('ef', 'database', 'drop', '-f') + (Build-CommonArguments -Configuration $Configuration)
        }
        'script' {
            $scriptOutput = if ($script:HasOutputOverride) { $Output } elseif (-not [string]::IsNullOrWhiteSpace($EffectiveArgument)) { $EffectiveArgument } else { 'migrations.sql' }
            $arguments = @('ef', 'migrations', 'script')
            if (-not $NoIdempotent) {
                $arguments += '--idempotent'
            }

            $arguments += @('-o', $scriptOutput)
            return $arguments + (Build-CommonArguments -Configuration $Configuration)
        }
        'pending' {
            return @('ef', 'migrations', 'has-pending-model-changes') + (Build-CommonArguments -Configuration $Configuration)
        }
        'bundle' {
            $arguments = @('ef', 'migrations', 'bundle', '--force')
            $bundleOutput = if ($script:HasOutputOverride) { $Output } else { $EffectiveArgument }
            if (-not [string]::IsNullOrWhiteSpace($bundleOutput)) {
                $arguments += @('-o', $bundleOutput)
            }

            return $arguments + (Build-CommonArguments -Configuration $Configuration)
        }
        default {
            throw "'$EffectiveCommand' is not a supported EF command."
        }
    }
}

function Show-Configuration {
    param(
        [Parameter(Mandatory)][pscustomobject]$Configuration,
        [Parameter(Mandatory)][string]$ConfigPath
    )

    $contextDisplay = if ([string]::IsNullOrWhiteSpace($Configuration.DbContextName)) { '<default>' } else { $Configuration.DbContextName }

    Write-Lines @(
        "Config path: $([IO.Path]::GetFullPath($ConfigPath))",
        "  Working directory : $($Configuration.WorkingDirectory)",
        "  DbContext project : $($Configuration.DbContextProject)",
        "  Startup project   : $($Configuration.StartupProject)",
        "  Migrations dir    : $($Configuration.MigrationsDirectory)",
        "  DbContext name    : $contextDisplay"
    )
}

function Write-SetupHelp {
    Write-Lines @(
        "$ScriptName setup",
        '',
        'Interactive setup:',
        "  .\$ScriptName setup",
        '',
        'Non-interactive setup:',
        "  .\$ScriptName setup -WorkingDir . -DbContext src/MyApp.Infrastructure/MyApp.Infrastructure.csproj -Startup src/MyApp.Api/MyApp.Api.csproj -MigrationsDir Persistence/Migrations -Context AppDbContext",
        '',
        'Options:',
        '  -WorkingDir <path>     Base directory used to resolve relative paths',
        '  -DbContext <csproj>    DbContext project file',
        '  -Startup <csproj>      Startup project file',
        '  -MigrationsDir <path>  Relative migrations directory inside the DbContext project',
        '  -Context <name>        Optional DbContext type name',
        '  -Config <path>         Override the config file location',
        '',
        'If -DbContext or -Startup are omitted, the script switches to interactive prompts.'
    )
}

function Write-ConfigHelp {
    Write-Lines @(
        "$ScriptName config",
        '',
        'Commands:',
        "  .\$ScriptName config      Show the current configuration and config path",
        "  .\$ScriptName config path Print only the config file path"
    )
}

function Write-CommandHelp {
    param(
        [Parameter(Mandatory)][string]$Topic,
        [Parameter(Mandatory)][string]$Usage,
        [Parameter(Mandatory)][string]$Description
    )

    Write-Lines @(
        $Topic,
        '',
        'Usage:',
        "  $Usage",
        '',
        $Description
    )
}

function Show-Help {
    param([string]$Topic)

    $configPath = Resolve-ConfigPath -OverridePath $Config -SearchDirectory (Get-Location).Path

    switch ($Topic) {
        'setup' {
            Write-SetupHelp
            return
        }
        'config' {
            Write-ConfigHelp
            return
        }
        'add' {
            Write-CommandHelp -Topic 'add' -Usage ".\$ScriptName add <Name>" -Description 'Creates a new migration. If the configured migrations directory does not exist yet, the script passes --output-dir automatically.'
            return
        }
        'update' {
            Write-CommandHelp -Topic 'update' -Usage ".\$ScriptName update [Target] [-Force]" -Description "Updates the database to the latest migration or to a specific target. Updating to '0' requires a double confirmation unless -Force is used."
            return
        }
        'script' {
            Write-CommandHelp -Topic 'script' -Usage ".\$ScriptName script [output.sql] [-Output <file>] [-NoIdempotent]" -Description 'Generates a SQL script. The default output is migrations.sql and the default mode is idempotent.'
            return
        }
    }

    Write-Lines @(
        'EF Core migrations helper (shell branch)',
        '',
        'Usage:',
        "  .\$ScriptName <command> [argument] [options]",
        '',
        'Start here:',
        "  .\$ScriptName setup               Interactive project setup",
        "  .\$ScriptName config              Show the saved configuration",
        '',
        'EF commands:',
        "  .\$ScriptName add <Name>          Add a migration",
        "  .\$ScriptName update [Target]     Apply pending migrations or move to a target",
        "  .\$ScriptName remove              Remove the last unapplied migration",
        "  .\$ScriptName list                List migrations",
        "  .\$ScriptName drop                Drop the database",
        "  .\$ScriptName reset               Drop and recreate the database from migrations",
        "  .\$ScriptName script [output.sql] Generate a SQL script",
        "  .\$ScriptName pending             Exit with code 1 when model changes are pending",
        "  .\$ScriptName bundle [output]     Build an efbundle executable",
        '',
        'Useful options:',
        '  -Config <path>                    Override the config file location',
        '  -Force, -y                        Skip confirmation prompts',
        '  -Help, -h                         Show help',
        '  -NoIdempotent                     Generate a non-idempotent SQL script',
        '',
        'Short aliases:',
        '  a=add  u=update  ls=list  rm=remove  cfg=config  init=setup  sql=script',
        '',
        'Default config path:',
        "  $configPath",
        '',
        "Run '.\$ScriptName help setup' for setup options."
    )
}

function Invoke-Setup {
    $currentDirectory = (Get-Location).Path
    $effectiveWorkingDirInput = if ($script:HasWorkingDirOverride) { $WorkingDir } else { $currentDirectory }
    $effectiveWorkingDirectory = Resolve-FullPath -BaseDirectory $currentDirectory -InputPath $effectiveWorkingDirInput

    if (-not (Test-Path $effectiveWorkingDirectory -PathType Container)) {
        throw "Working directory was not found: $effectiveWorkingDirectory"
    }

    $configPath = Resolve-ConfigPath -OverridePath $Config -SearchDirectory $effectiveWorkingDirectory
    $existing = Load-Configuration -ConfigPath $configPath
    $discoveredProjects = Get-DiscoveredProjects -WorkingDirectory $effectiveWorkingDirectory

    $dbContextInput = if ($script:HasDbContextOverride) {
        $DbContext
    }
    elseif (-not [string]::IsNullOrWhiteSpace($existing.DbContextProject)) {
        Get-RelativePath -BaseDirectory $effectiveWorkingDirectory -InputPath $existing.DbContextProject
    }
    else {
        ''
    }

    $startupInput = if ($script:HasStartupOverride) {
        $Startup
    }
    elseif (-not [string]::IsNullOrWhiteSpace($existing.StartupProject)) {
        Get-RelativePath -BaseDirectory $effectiveWorkingDirectory -InputPath $existing.StartupProject
    }
    else {
        $dbContextInput
    }

    $migrationsInput = if ($script:HasMigrationsDirOverride) {
        $MigrationsDir
    }
    elseif (-not [string]::IsNullOrWhiteSpace($existing.MigrationsDirectory)) {
        $existing.MigrationsDirectory
    }
    else {
        $DefaultMigrationsDir
    }

    $contextInput = if ($script:HasDbContextNameOverride) {
        $DbContextName
    }
    else {
        $existing.DbContextName
    }

    $requiresPrompt = [string]::IsNullOrWhiteSpace($dbContextInput) -or [string]::IsNullOrWhiteSpace($startupInput)
    if ($requiresPrompt -and [Console]::IsInputRedirected) {
        throw 'Setup requires -DbContext and -Startup when stdin is redirected.'
    }

    if ($requiresPrompt) {
        Write-Host "Configuring $ScriptName..."
        if ($discoveredProjects.Count -gt 0) {
            Write-Host 'Discovered project files:'
            for ($index = 0; $index -lt $discoveredProjects.Count; $index++) {
                Write-Host ("  {0}. {1}" -f ($index + 1), (Get-RelativePath -BaseDirectory $effectiveWorkingDirectory -InputPath $discoveredProjects[$index]))
            }

            Write-Host ''
        }

        $dbContextInput = Prompt-Project -Label 'DbContext project (.csproj)' -WorkingDirectory $effectiveWorkingDirectory -Projects $discoveredProjects -DefaultValue $dbContextInput
        $startupDefault = if ([string]::IsNullOrWhiteSpace($startupInput)) { $dbContextInput } else { $startupInput }
        $startupInput = Prompt-Project -Label 'Startup project (.csproj)' -WorkingDirectory $effectiveWorkingDirectory -Projects $discoveredProjects -DefaultValue $startupDefault
        $migrationsInput = Read-PromptValue -Label 'Migrations directory relative to the DbContext project' -DefaultValue $migrationsInput
        $contextInput = Read-PromptValue -Label 'DbContext name (optional)' -DefaultValue $contextInput -AllowEmpty
    }

    $configuration = New-ConfigurationObject -ConfigPath $configPath
    $configuration.WorkingDirectory = $effectiveWorkingDirectory
    $configuration.DbContextProject = Resolve-FullPath -BaseDirectory $effectiveWorkingDirectory -InputPath $dbContextInput
    $configuration.StartupProject = Resolve-FullPath -BaseDirectory $effectiveWorkingDirectory -InputPath $startupInput
    $configuration.MigrationsDirectory = Normalize-RelativeDirectory -InputPath $migrationsInput
    $configuration.DbContextName = if ([string]::IsNullOrWhiteSpace($contextInput)) { '' } else { $contextInput.Trim() }

    Validate-Configuration -Configuration $configuration
    Save-Configuration -Configuration $configuration -ConfigPath $configPath

    Write-Host 'Saved configuration.' -ForegroundColor Green
    Show-Configuration -Configuration $configuration -ConfigPath $configPath
}

function Invoke-Config {
    $configPath = Resolve-ConfigPath -OverridePath $Config -SearchDirectory (Get-Location).Path

    if ($Argument -ieq 'path') {
        Write-Host $configPath
        return
    }

    if (-not (Test-Path $configPath -PathType Leaf)) {
        Write-Lines @(
            "Config path: $configPath",
            "No configuration found. Run .\$ScriptName setup first."
        )
        return
    }

    $configuration = Load-Configuration -ConfigPath $configPath
    Show-Configuration -Configuration $configuration -ConfigPath $configPath
}

function Invoke-Reset {
    param([Parameter(Mandatory)][pscustomobject]$Configuration)

    Write-Host 'Dropping database...' -ForegroundColor Yellow
    $dropExitCode = Invoke-Ef -WorkingDirectory $Configuration.WorkingDirectory -Arguments (@('ef', 'database', 'drop', '-f') + (Build-CommonArguments -Configuration $Configuration))
    if ($dropExitCode -ne 0) {
        exit $dropExitCode
    }

    Write-Host 'Applying all migrations...' -ForegroundColor Yellow
    $updateExitCode = Invoke-Ef -WorkingDirectory $Configuration.WorkingDirectory -Arguments (@('ef', 'database', 'update') + (Build-CommonArguments -Configuration $Configuration))
    if ($updateExitCode -eq 0) {
        Write-Host 'Database recreated from migrations.' -ForegroundColor Green
    }

    exit $updateExitCode
}

$effectiveCommand = Normalize-Command -Name $Command

if ($Help -and $effectiveCommand -ne 'help') {
    Show-Help -Topic $effectiveCommand
    exit 0
}

if ($effectiveCommand -eq 'help') {
    $helpTopic = if ([string]::IsNullOrWhiteSpace($Argument)) { '' } else { Normalize-Command -Name $Argument }
    Show-Help -Topic $helpTopic
    exit 0
}

switch ($effectiveCommand) {
    'setup' {
        Invoke-Setup
        exit 0
    }
    'config' {
        Invoke-Config
        exit 0
    }
    'add' { }
    'update' { }
    'remove' { }
    'list' { }
    'drop' { }
    'reset' { }
    'script' { }
    'pending' { }
    'bundle' { }
    default {
        throw "Unknown command '$Command'. Run .\$ScriptName help for usage."
    }
}

$resolvedConfigPath = Resolve-ConfigPath -OverridePath $Config -SearchDirectory (Get-Location).Path
if (-not (Test-Path $resolvedConfigPath -PathType Leaf)) {
    throw "No configuration found. Run .\$ScriptName setup first. Config path: $resolvedConfigPath"
}

$resolvedConfiguration = Load-Configuration -ConfigPath $resolvedConfigPath
Validate-Configuration -Configuration $resolvedConfiguration

if (-not (Should-Proceed -EffectiveCommand $effectiveCommand -EffectiveArgument $Argument)) {
    exit 2
}

if ($effectiveCommand -eq 'reset') {
    Invoke-Reset -Configuration $resolvedConfiguration
}

$efArguments = New-EfArguments -Configuration $resolvedConfiguration -EffectiveCommand $effectiveCommand -EffectiveArgument $Argument
$commandExitCode = Invoke-Ef -WorkingDirectory $resolvedConfiguration.WorkingDirectory -Arguments $efArguments

if ($commandExitCode -eq 0 -and $effectiveCommand -eq 'script') {
    $effectiveOutput = if ($script:HasOutputOverride) { $Output } elseif (-not [string]::IsNullOrWhiteSpace($Argument)) { $Argument } else { 'migrations.sql' }
    Write-Host "SQL script written to $effectiveOutput" -ForegroundColor Green
}

exit $commandExitCode
