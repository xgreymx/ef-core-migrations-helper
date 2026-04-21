# EF Core Migrations Helper

EF Core Migrations Helper is a cross-platform .NET tool that makes common Entity Framework Core migration tasks shorter and easier to run.

Instead of repeating `dotnet ef --project ... --startup-project ...`, you configure a project once and then use short commands such as `efm add`, `efm update`, or `efm script`.

## Installation

Install the EF Core CLI if it is not already available:

```bash
dotnet tool install --global dotnet-ef
```

Install this tool from NuGet:

```bash
dotnet tool install --global EfCoreMigrationsHelper.Tool
```

Run:

```bash
efm help
```

Note:

- The installed command is `efm`
- `dotnet efm` is not the correct command

## Quick Start

Configure the current project:

```bash
efm setup
```

Create and apply a migration:

```bash
efm add InitialCreate
efm update
```

Generate a deployment script:

```bash
efm script release.sql
```

## How It Works

The tool wraps `dotnet ef` and automatically injects the saved project settings.

Each profile stores:

- the working directory
- the DbContext project
- the startup project
- the migrations directory
- an optional DbContext name

This removes the need to type the same long command arguments every time.

## Configuration

The default config file is project-scoped:

```text
.efm/config.json
```

The tool walks up from the current directory and uses the nearest project root marker it can find, such as:

- `.git`
- `*.sln`
- `*.slnx`
- `global.json`
- `Directory.Build.props`
- `Directory.Build.targets`

If no marker is found, the current directory is used.

Paths inside `.efm/config.json` are stored as relative paths whenever possible, which makes the configuration easier to move between machines and clones of the same repository.

You can override the config location with:

```bash
efm --config ./custom-config.json config
```

or:

```bash
EFMH_CONFIG_PATH=./custom-config.json efm config
```

## Setup

Interactive setup:

```bash
efm setup
```

Non-interactive setup:

```bash
efm setup \
  --profile my-api \
  --working-dir . \
  --dbcontext src/MyApp.Infrastructure/MyApp.Infrastructure.csproj \
  --startup src/MyApp.Api/MyApp.Api.csproj \
  --migrations-dir Persistence/Migrations \
  --context AppDbContext
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

## Safety

Destructive commands require confirmation.

| Command | Confirmation |
|---|---|
| `drop` | Double confirmation |
| `reset` | Double confirmation |
| `update 0` | Double confirmation |
| `update <Target>` | Single confirmation |

Use `--force` or `-y` to skip prompts in automation.

If a destructive command is cancelled, the tool exits with code `2`.

## Examples

```bash
efm setup
efm add AddCustomers
efm update
efm script release.sql
efm update InitialCreate
efm reset --force
```

Using named profiles:

```bash
efm use billing-api
efm list
efm update --profile identity-api
```

## Development

Run directly from the repository:

PowerShell:

```powershell
.\ef.ps1 help
```

Bash:

```bash
chmod +x ./ef.sh
./ef.sh help
```

Or run the project directly:

```powershell
dotnet run --project .\src\EfCoreMigrationsHelper.Tool\EfCoreMigrationsHelper.Tool.csproj -- help
```
