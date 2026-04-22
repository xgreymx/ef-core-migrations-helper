# EF Core Migrations Helper

This `main` branch intentionally keeps only the standalone shell helpers:

- `ef.ps1`
- `ef.sh`

If you want the packaged .NET tool and its source code, switch to the `dotnet-tool` branch. That branch has its own README and is the place for the installable `efm` tool.

## What this branch is for

Use this branch when you want a zero-build fallback that stays as plain shell scripts inside your repository.

Both scripts now share the same core behavior:

- project-scoped interactive setup
- saved configuration in `.efm/config.env`
- the same command names and aliases
- the same destructive-action confirmations
- idempotent SQL script generation by default

## Use it in your project

1. Copy `ef.ps1` and/or `ef.sh` into the root of your repository, or into any folder you prefer.
2. Make sure `dotnet ef` is available.
3. Run the setup command once from your project root.
4. Use the saved configuration for day-to-day migration commands.

Install EF Core CLI if needed:

```bash
dotnet tool install --global dotnet-ef
```

If your repo uses a local tool manifest instead:

```bash
dotnet tool restore
```

PowerShell setup:

```powershell
.\ef.ps1 setup
```

Bash setup:

```bash
chmod +x ./ef.sh
./ef.sh setup
```

If PowerShell blocks the script on Windows, either unblock the file or allow local unsigned scripts for your user:

```powershell
Unblock-File .\ef.ps1
# or
Set-ExecutionPolicy -Scope CurrentUser RemoteSigned
```

The setup flow discovers `.csproj` files and saves:

- working directory
- DbContext project
- startup project
- migrations directory
- optional DbContext name

The default config path is:

```text
.efm/config.env
```

The scripts walk up from the current directory and use the nearest project root marker they can find, such as `.git`, `*.sln`, `*.slnx`, `global.json`, `Directory.Build.props`, or `Directory.Build.targets`.

If you want to place the config somewhere else, use `-Config <path>` in PowerShell, `--config <path>` in bash, or set `EFMH_CONFIG_PATH`.

## Commands

Both scripts support the same commands:

| Command | Purpose |
| --- | --- |
| `setup` | Interactive or non-interactive project setup |
| `config` | Show the saved configuration |
| `add <Name>` | Create a migration |
| `update [Target]` | Apply pending migrations or move to a target migration |
| `remove` | Remove the last unapplied migration |
| `list` | List migrations |
| `drop` | Drop the database |
| `reset` | Drop and recreate the database from migrations |
| `script [output.sql]` | Generate a SQL script |
| `pending` | Exit with code `1` when model changes are pending |
| `bundle [output]` | Build an EF migration bundle |
| `help [command]` | Show help |

Short aliases are also aligned across both scripts:

- `a` -> `add`
- `u`, `up` -> `update`
- `ls` -> `list`
- `rm` -> `remove`
- `cfg` -> `config`
- `init` -> `setup`
- `sql` -> `script`

## Safety

Destructive commands require confirmation in both scripts:

| Command | Confirmation |
| --- | --- |
| `drop` | double confirmation |
| `reset` | double confirmation |
| `update 0` | double confirmation |
| `update <Target>` | single confirmation |

If a destructive command is cancelled, the scripts exit with code `2`.

Use `-Force` in PowerShell or `--force` / `-y` in bash only for automation.

SQL script generation is idempotent by default in both scripts:

```powershell
.\ef.ps1 script
.\ef.ps1 script -NoIdempotent
```

```bash
./ef.sh script
./ef.sh script --no-idempotent
```

## Examples

Create the initial config and add a migration:

```powershell
.\ef.ps1 setup
.\ef.ps1 add AddCustomers
.\ef.ps1 update
```

```bash
./ef.sh setup
./ef.sh add AddCustomers
./ef.sh update
```

Generate a SQL script:

```powershell
.\ef.ps1 script -Output release.sql
```

```bash
./ef.sh script --output release.sql
```

Check the saved configuration:

```powershell
.\ef.ps1 config
```

```bash
./ef.sh config
```

## Branches

- `main`: shell-only helpers for repos that want plain scripts.
- `dotnet-tool`: the installable .NET tool implementation, source code, and its own README.
