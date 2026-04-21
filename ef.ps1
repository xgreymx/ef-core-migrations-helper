[CmdletBinding(PositionalBinding = $false)]
param(
    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]]$Arguments
)

$ErrorActionPreference = 'Stop'

$toolProject = Join-Path $PSScriptRoot 'src\EfCoreMigrationsHelper.Tool\EfCoreMigrationsHelper.Tool.csproj'

function Invoke-LocalTool {
    if (-not (Get-Command dotnet -ErrorAction SilentlyContinue)) {
        throw "dotnet was not found on PATH. Install the .NET SDK to run the local tool project."
    }

    & dotnet run --project $toolProject -- @Arguments
    exit $LASTEXITCODE
}

if (Test-Path $toolProject) {
    Invoke-LocalTool
}

$installedTool = Get-Command efm -ErrorAction SilentlyContinue
if ($installedTool) {
    & $installedTool.Source @Arguments
    exit $LASTEXITCODE
}

throw "Could not find the local tool project or an installed 'efm' command. Build the repository or install the dotnet tool first."
