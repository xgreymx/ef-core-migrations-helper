# EF Core Migrations Helper

Cross-platform EF Core migration helper built as a .NET tool.

The goal is simple: keep `dotnet ef` powerful, but remove the repetitive setup work. You configure your projects once, then use short commands such as `efm add`, `efm update`, or `efm script`.

## What this project includes

- A .NET tool with a short command name: `efm`
- Interactive and non-interactive setup that persists project paths
- Named profiles so you can switch between solutions or services
- Thin PowerShell and Bash wrappers for local repository use
- Safety prompts for destructive actions

## Install

Important:

- The tool command is `efm`
- `dotnet efm` does not work with the current package shape because that syntax only applies to tools exposed as `dotnet-<name>`
- `dotnet tool list` only shows the tool after you install it locally or globally
- `dotnet list package` does not show it because this is not a NuGet package reference of the project

### Prerequisites

```bash
dotnet --version
dotnet ef --help
```

If `dotnet ef` is missing:

```bash
dotnet tool install --global dotnet-ef
```

### Run from the repository

If you are developing or testing the repo, this is the fastest path. It does not require installing the tool first.

PowerShell:

```powershell
.\ef.ps1 help
```

Bash:

```bash
chmod +x ./ef.sh
./ef.sh help
```

Both wrappers prefer the local source project, so contributors can test the current branch without installing anything globally.

You can also run the tool directly from source:

```powershell
dotnet run --project .\src\EfCoreMigrationsHelper.Tool\EfCoreMigrationsHelper.Tool.csproj -- help
```

### Install as a global tool from source

```powershell
dotnet pack .\src\EfCoreMigrationsHelper.Tool\EfCoreMigrationsHelper.Tool.csproj -c Release
dotnet tool install --global --add-source .\src\EfCoreMigrationsHelper.Tool\bin\Release EfCoreMigrationsHelper.Tool
```

Once installed, use:

```bash
efm help
```

If you want it to appear in `dotnet tool list --global`, you must install it first with the command above.

### Install as a local tool from source

If you want a repo-scoped tool instead of a global install:

```powershell
dotnet new tool-manifest
dotnet pack .\src\EfCoreMigrationsHelper.Tool\EfCoreMigrationsHelper.Tool.csproj -c Release
dotnet tool install --local --add-source .\src\EfCoreMigrationsHelper.Tool\bin\Release EfCoreMigrationsHelper.Tool
dotnet tool run efm help
```

When the package is published to NuGet, installation becomes the usual `dotnet tool install --global <package-id>`.

## Publish to NuGet

Yes, the project is packable right now. To publish it for testing on other projects you still need two external prerequisites:

- a NuGet API key
- an available package ID on NuGet.org

The current package ID is `EfCoreMigrationsHelper.Tool`, and the repo URL already points to GitHub.

Typical publish flow:

```powershell
dotnet pack .\src\EfCoreMigrationsHelper.Tool\EfCoreMigrationsHelper.Tool.csproj -c Release
dotnet nuget push .\src\EfCoreMigrationsHelper.Tool\bin\Release\EfCoreMigrationsHelper.Tool.0.1.0.nupkg --api-key <YOUR_API_KEY> --source https://api.nuget.org/v3/index.json
```

If the package ID is already taken, change `PackageId` in the project file before pushing.

## First-time setup

### Interactive setup

```bash
efm setup
```

The tool can discover `*.csproj` files under the current directory and prompt for:

- DbContext project
- Startup project
- Migrations directory
- Optional DbContext type name

### Non-interactive setup

```bash
efm setup \
	--profile my-api \
	--working-dir . \
	--dbcontext src/MyApp.Infrastructure/MyApp.Infrastructure.csproj \
	--startup src/MyApp.Api/MyApp.Api.csproj \
	--migrations-dir Persistence/Migrations \
	--context AppDbContext
```

The default configuration is project-scoped.

By default the tool walks upward from the current directory and uses the nearest project root marker it can find, then stores the file at:

- `.efm/config.json`

Project root markers include:

- `.git`
- `*.sln`
- `*.slnx`
- `global.json`
- `Directory.Build.props`
- `Directory.Build.targets`

If no marker is found, the tool falls back to the current directory and creates `.efm/config.json` there.

The `.efm/` folder is ignored by the repository by default.

Inside that config file, project paths are stored as relative paths whenever possible. That keeps the setup portable across machines as long as the repository structure stays the same.

You can override the config file location with either:

```bash
efm --config ./efm.local.json config
```

or:

```bash
EFMH_CONFIG_PATH=./efm.local.json efm config
```

## Commands

| Command | Description |
|---|---|
| `efm add <Name>` | Create a new migration |
| `efm update [Target]` | Apply pending migrations or move to a target migration |
| `efm remove` | Remove the last unapplied migration |
| `efm list` | List migrations |
| `efm drop` | Drop the database |
| `efm reset` | Drop and recreate the database from migrations |
| `efm script [output.sql]` | Generate a SQL script |
| `efm pending` | Exit with code `1` when model changes are pending |
| `efm bundle [output]` | Build an EF migration bundle |
| `efm config` | Show the active profile and config file path |
| `efm profiles` | List saved profiles |
| `efm use <name>` | Switch the active profile |
| `efm help [command]` | Show help |

Short aliases:

- `a` -> `add`
- `u` or `up` -> `update`
- `ls` -> `list`
- `rm` -> `remove`
- `cfg` -> `config`
- `init` -> `setup`
- `sql` -> `script`

## Safety model

Actions with data-loss risk are protected:

| Command | Confirmation |
|---|---|
| `drop` | Double confirmation |
| `reset` | Double confirmation |
| `update 0` | Double confirmation |
| `update <Target>` | Single confirmation |

Use `--force` or `-y` to skip prompts for automation.

If a destructive action is cancelled by the user, the tool exits with code `2` instead of pretending success.

## Examples

```bash
efm setup
efm add AddCustomers
efm update
efm script release-2026-04.sql
efm update InitialCreate
efm reset --force
```

Using a named profile:

```bash
efm use billing-api
efm list
efm update --profile identity-api
```

## Repository layout

```text
ef.ps1
ef.sh
README.md
src/
	EfCoreMigrationsHelper.Tool/
```

- `ef.ps1` and `ef.sh` are repository wrappers for contributors and quick local usage
- `src/EfCoreMigrationsHelper.Tool` contains the actual tool implementation

## Development

```powershell
dotnet build .\src\EfCoreMigrationsHelper.Tool\EfCoreMigrationsHelper.Tool.csproj
dotnet run --project .\src\EfCoreMigrationsHelper.Tool\EfCoreMigrationsHelper.Tool.csproj -- help
```

The wrappers are useful during development too:

```powershell
.\ef.ps1 config
```

```bash
./ef.sh config
```

## Current scope

This repository is now generic and no longer hardcodes a specific solution. The next logical improvements are automated tests, CI, package publishing, and richer argument passthrough for advanced `dotnet ef` scenarios.
