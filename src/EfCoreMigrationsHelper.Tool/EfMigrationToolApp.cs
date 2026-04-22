namespace EfCoreMigrationsHelper.Tool;

internal sealed class EfMigrationToolApp
{
    private readonly ToolConfigurationStore _configurationStore = new();
    private readonly EfCommandRunner _commandRunner = new();

    public async Task<int> RunAsync(string[] args, CancellationToken cancellationToken = default)
    {
        CliInvocation invocation;

        try
        {
            invocation = CommandLineParser.Parse(args);
        }
        catch (CliUsageException exception)
        {
            Console.Error.WriteLine(exception.Message);
            Console.Error.WriteLine("Run 'efm help' for usage.");
            return 1;
        }

        try
        {
            return invocation.Command switch
            {
                "help" => HandleHelp(invocation),
                "setup" => HandleSetup(invocation),
                "config" => HandleConfig(invocation),
                "profiles" => HandleProfiles(invocation),
                "use" => HandleUse(invocation),
                "add" or "update" or "remove" or "list" or "drop" or "reset" or "script" or "pending" or "bundle" => await HandleEfCommandAsync(invocation, cancellationToken),
                _ => HandleUnknownCommand(invocation.Command)
            };
        }
        catch (CliUsageException exception)
        {
            Console.Error.WriteLine(exception.Message);
            return 1;
        }
        catch (Exception exception) when (exception is IOException or InvalidOperationException or UnauthorizedAccessException or System.Text.Json.JsonException)
        {
            Console.Error.WriteLine(exception.Message);
            return 1;
        }
    }

    private int HandleHelp(CliInvocation invocation)
    {
        var topic = invocation.HelpTopic;
        var configPath = _configurationStore.ResolvePath(invocation.ConfigPath);

        if (string.IsNullOrWhiteSpace(topic))
        {
            Console.WriteLine(
                $"""
                EF Core Migrations Helper

                Usage:
                  efm <command> [arguments] [options]

                Start here:
                  efm setup                    Interactive project setup
                  efm setup --dbcontext <csproj> --startup <csproj>
                                            Non-interactive setup
                  efm config                   Show the active profile
                  efm profiles                 List saved profiles

                EF commands:
                  efm add <Name>              Add a migration
                  efm update [Target]         Apply pending migrations or move to a target
                  efm remove                  Remove the last unapplied migration
                  efm list                    List migrations
                  efm drop                    Drop the database
                  efm reset                   Drop and recreate the database from migrations
                  efm script [output.sql]     Generate a SQL script
                  efm pending                 Exit with code 1 when model changes are pending
                  efm bundle                  Build an efbundle executable

                Profile commands:
                  efm use <name>              Switch the active profile
                  efm config path             Print the config file path

                Useful options:
                  --profile <name>            Use or create a named profile
                  --config <path>             Override the config file location
                  --no-auto-recover          Disable Windows CIP clean/build retry
                  --force, -y                 Skip confirmation prompts
                  --help, -h                  Show help

                Short aliases:
                  a=add  u=update  ls=list  rm=remove  cfg=config  init=setup  sql=script

                Default config path:
                  {configPath}

                Run 'efm help setup' for setup options.
                """);
            return 0;
        }

        return topic switch
        {
            "setup" => WriteSetupHelp(),
            "config" => WriteConfigHelp(),
            "add" => WriteCommandHelp("add", "efm add <Name> [--profile <name>]", "Creates a new migration. If the configured migrations directory does not exist yet, the tool passes --output-dir automatically."),
            "update" => WriteCommandHelp("update", "efm update [Target] [--profile <name>] [--force]", "Updates the database to the latest migration or to a specific target. Updating to '0' requires a double confirmation unless --force is used."),
            "script" => WriteCommandHelp("script", "efm script [output.sql] [--output <file>] [--no-idempotent]", "Generates a SQL script. The default output is migrations.sql and the default mode is idempotent."),
            _ => WriteCommandHelp(topic, $"efm {topic}", "No extra help is available for this command yet.")
        };
    }

    private int WriteSetupHelp()
    {
        Console.WriteLine(
            """
            efm setup

            Interactive setup:
              efm setup
              efm setup my-api

            Non-interactive setup:
              efm setup --profile my-api --working-dir . \
                --dbcontext src/MyApp.Infrastructure/MyApp.Infrastructure.csproj \
                --startup src/MyApp.Api/MyApp.Api.csproj \
                --migrations-dir Persistence/Migrations \
                --context AppDbContext

            Options:
              --profile <name>         Profile name to create or overwrite
              --working-dir <path>     Base directory used to resolve relative paths
              --dbcontext <csproj>     DbContext project file
              --startup <csproj>       Startup project file
              --migrations-dir <path>  Relative migrations directory inside the DbContext project
              --context <name>         Optional DbContext type name
              --config <path>          Override the config file location

            If --dbcontext or --startup are omitted, the tool switches to interactive prompts.
            """);
        return 0;
    }

    private int WriteConfigHelp()
    {
        Console.WriteLine(
            """
            efm config

            Commands:
              efm config               Show the active profile and config path
              efm config path          Print only the config file path
              efm profiles             List available profiles
              efm use <name>           Set the active profile
            """);
        return 0;
    }

    private int WriteCommandHelp(string command, string usage, string description)
    {
        Console.WriteLine($"{command}\n\nUsage:\n  {usage}\n\n{description}");
        return 0;
    }

    private int HandleUnknownCommand(string command)
    {
        Console.Error.WriteLine($"Unknown command '{command}'. Run 'efm help' for usage.");
        return 1;
    }

    private int HandleSetup(CliInvocation invocation)
    {
        var currentDirectory = Directory.GetCurrentDirectory();
        var workingDirectory = ResolveDirectoryPath(currentDirectory, invocation.TryGetOption("working-dir") ?? currentDirectory);
        var configuration = _configurationStore.Load(invocation.ConfigPath, workingDirectory);
        var profileName = invocation.ProfileName
            ?? invocation.Positionals.FirstOrDefault()
            ?? configuration.ActiveProfile
            ?? "default";

        var discoveredProjects = DiscoverProjects(workingDirectory);

        var dbContextInput = invocation.TryGetOption("dbcontext");
        var startupInput = invocation.TryGetOption("startup");
        var migrationsDirectory = invocation.TryGetOption("migrations-dir");
        var contextName = invocation.TryGetOption("context");

        var requiresPrompt = string.IsNullOrWhiteSpace(dbContextInput) || string.IsNullOrWhiteSpace(startupInput);
        if (requiresPrompt && Console.IsInputRedirected)
        {
            throw new InvalidOperationException("Setup requires --dbcontext and --startup when stdin is redirected.");
        }

        if (requiresPrompt)
        {
            Console.WriteLine($"Configuring profile '{profileName}'...");
            if (discoveredProjects.Count > 0)
            {
                Console.WriteLine("Discovered project files:");
                for (var index = 0; index < discoveredProjects.Count; index++)
                {
                    Console.WriteLine($"  {index + 1}. {Path.GetRelativePath(workingDirectory, discoveredProjects[index])}");
                }

                Console.WriteLine();
            }

            dbContextInput = PromptForProject(
                "DbContext project (.csproj)",
                workingDirectory,
                discoveredProjects,
                dbContextInput);

            startupInput = PromptForProject(
                "Startup project (.csproj)",
                workingDirectory,
                discoveredProjects,
                startupInput ?? dbContextInput);

            migrationsDirectory = Prompt("Migrations directory relative to the DbContext project", migrationsDirectory ?? "Persistence/Migrations");
            contextName = Prompt("DbContext name (optional)", contextName ?? string.Empty);
        }

        var profile = new EfProfile
        {
            Name = profileName,
            WorkingDirectory = workingDirectory,
            DbContextProject = ResolveFilePath(workingDirectory, dbContextInput!, "DbContext project"),
            StartupProject = ResolveFilePath(workingDirectory, startupInput!, "Startup project"),
            MigrationsDirectory = NormalizeRelativeDirectory(migrationsDirectory ?? "Persistence/Migrations"),
            DbContextName = string.IsNullOrWhiteSpace(contextName) ? null : contextName.Trim(),
            UpdatedAt = DateTimeOffset.UtcNow
        };

        ValidateProfile(profile);
        configuration.Profiles[profileName] = profile;
        configuration.ActiveProfile = profileName;
        _configurationStore.Save(configuration, invocation.ConfigPath, workingDirectory);

        Console.WriteLine($"Saved profile '{profileName}'.");
        Console.WriteLine($"Config path: {_configurationStore.ResolvePath(invocation.ConfigPath, workingDirectory)}");
        WriteProfile(profile, profileName == configuration.ActiveProfile);
        return 0;
    }

    private int HandleConfig(CliInvocation invocation)
    {
        if (invocation.Positionals.Count > 0 && string.Equals(invocation.Positionals[0], "path", StringComparison.OrdinalIgnoreCase))
        {
            Console.WriteLine(_configurationStore.ResolvePath(invocation.ConfigPath));
            return 0;
        }

        var configuration = _configurationStore.Load(invocation.ConfigPath);
        Console.WriteLine($"Config path: {_configurationStore.ResolvePath(invocation.ConfigPath)}");

        if (configuration.Profiles.Count == 0)
        {
            Console.WriteLine("No profiles configured. Run 'efm setup' first.");
            return 0;
        }

        var profileName = invocation.ProfileName
            ?? configuration.ActiveProfile
            ?? configuration.Profiles.Keys.First();

        if (!configuration.Profiles.TryGetValue(profileName, out var profile))
        {
            throw new InvalidOperationException($"Profile '{profileName}' was not found.");
        }

        WriteProfile(profile, profileName == configuration.ActiveProfile);
        return 0;
    }

    private int HandleProfiles(CliInvocation invocation)
    {
        var configuration = _configurationStore.Load(invocation.ConfigPath);
        Console.WriteLine($"Config path: {_configurationStore.ResolvePath(invocation.ConfigPath)}");

        if (configuration.Profiles.Count == 0)
        {
            Console.WriteLine("No profiles configured. Run 'efm setup' first.");
            return 0;
        }

        foreach (var entry in configuration.Profiles.OrderBy(item => item.Key, StringComparer.OrdinalIgnoreCase))
        {
            var marker = string.Equals(entry.Key, configuration.ActiveProfile, StringComparison.OrdinalIgnoreCase) ? "*" : " ";
            Console.WriteLine($"{marker} {entry.Key} -> {entry.Value.DbContextProject}");
        }

        return 0;
    }

    private int HandleUse(CliInvocation invocation)
    {
        var configuration = _configurationStore.Load(invocation.ConfigPath);
        if (configuration.Profiles.Count == 0)
        {
            throw new InvalidOperationException("No profiles are configured yet. Run 'efm setup' first.");
        }

        var profileName = invocation.ProfileName ?? invocation.Positionals.FirstOrDefault();
        if (string.IsNullOrWhiteSpace(profileName))
        {
            throw new CliUsageException("The 'use' command requires a profile name. Example: efm use my-api");
        }

        if (!configuration.Profiles.ContainsKey(profileName))
        {
            throw new InvalidOperationException($"Profile '{profileName}' was not found.");
        }

        configuration.ActiveProfile = profileName;
        _configurationStore.Save(configuration, invocation.ConfigPath);
        Console.WriteLine($"Active profile set to '{profileName}'.");
        return 0;
    }

    private async Task<int> HandleEfCommandAsync(CliInvocation invocation, CancellationToken cancellationToken)
    {
        var configuration = _configurationStore.Load(invocation.ConfigPath);
        if (configuration.Profiles.Count == 0)
        {
            throw new InvalidOperationException($"No profiles are configured. Run 'efm setup' first. Config path: {_configurationStore.ResolvePath(invocation.ConfigPath)}");
        }

        var profileName = invocation.ProfileName
            ?? configuration.ActiveProfile
            ?? configuration.Profiles.Keys.First();

        if (!configuration.Profiles.TryGetValue(profileName, out var profile))
        {
            throw new InvalidOperationException($"Profile '{profileName}' was not found.");
        }

        ValidateProfile(profile);

        return invocation.Command switch
        {
            "reset" => await HandleResetAsync(profile, invocation, cancellationToken),
            _ => await RunSingleEfCommandAsync(profile, invocation, cancellationToken)
        };
    }

    private async Task<int> RunSingleEfCommandAsync(EfProfile profile, CliInvocation invocation, CancellationToken cancellationToken)
    {
        if (!ShouldProceed(invocation))
        {
            return 2;
        }

        var args = CreateEfArguments(profile, invocation);
        var exitCode = await _commandRunner.RunAsync(
            new EfCommandRequest(profile.WorkingDirectory, args, profile.StartupProject, invocation.AutoRecover),
            cancellationToken);
        if (exitCode == 0 && string.Equals(invocation.Command, "script", StringComparison.OrdinalIgnoreCase))
        {
            var output = invocation.TryGetOption("output") ?? invocation.Positionals.FirstOrDefault() ?? "migrations.sql";
            ConsoleUi.WriteSuccess($"SQL script written to {output}");
        }

        return exitCode;
    }

    private async Task<int> HandleResetAsync(EfProfile profile, CliInvocation invocation, CancellationToken cancellationToken)
    {
        if (!ShouldProceed(invocation))
        {
            return 2;
        }

        var commonArguments = BuildCommonArguments(profile);

        ConsoleUi.WriteInfo("Dropping database...");
        var dropArguments = new List<string> { "ef", "database", "drop", "-f" };
        dropArguments.AddRange(commonArguments);

        var dropExitCode = await _commandRunner.RunAsync(
            new EfCommandRequest(profile.WorkingDirectory, dropArguments, profile.StartupProject, invocation.AutoRecover),
            cancellationToken);
        if (dropExitCode != 0)
        {
            return dropExitCode;
        }

        ConsoleUi.WriteInfo("Applying all migrations...");
        var updateArguments = new List<string> { "ef", "database", "update" };
        updateArguments.AddRange(commonArguments);

        var updateExitCode = await _commandRunner.RunAsync(
            new EfCommandRequest(profile.WorkingDirectory, updateArguments, profile.StartupProject, invocation.AutoRecover),
            cancellationToken);
        if (updateExitCode == 0)
        {
            ConsoleUi.WriteSuccess("Database recreated from migrations.");
        }

        return updateExitCode;
    }

    private List<string> CreateEfArguments(EfProfile profile, CliInvocation invocation)
    {
        var arguments = new List<string> { "ef" };

        switch (invocation.Command)
        {
            case "add":
            {
                var migrationName = invocation.Positionals.FirstOrDefault();
                if (string.IsNullOrWhiteSpace(migrationName))
                {
                    throw new CliUsageException("Migration name required. Example: efm add AddProductsTable");
                }

                arguments.AddRange(["migrations", "add", migrationName]);
                arguments.AddRange(BuildCommonArguments(profile));

                var migrationsPath = Path.Combine(Path.GetDirectoryName(profile.DbContextProject)!, profile.MigrationsDirectory);
                if (!Directory.Exists(migrationsPath))
                {
                    ConsoleUi.WriteInfo($"Using --output-dir {profile.MigrationsDirectory} because the folder does not exist yet.");
                    arguments.AddRange(["--output-dir", profile.MigrationsDirectory]);
                }

                return arguments;
            }

            case "update":
            {
                arguments.AddRange(["database", "update"]);
                var target = invocation.Positionals.FirstOrDefault();
                if (!string.IsNullOrWhiteSpace(target))
                {
                    arguments.Add(target);
                }

                arguments.AddRange(BuildCommonArguments(profile));
                return arguments;
            }

            case "remove":
                arguments.AddRange(["migrations", "remove"]);
                arguments.AddRange(BuildCommonArguments(profile));
                return arguments;

            case "list":
                arguments.AddRange(["migrations", "list"]);
                arguments.AddRange(BuildCommonArguments(profile));
                return arguments;

            case "drop":
                arguments.AddRange(["database", "drop", "-f"]);
                arguments.AddRange(BuildCommonArguments(profile));
                return arguments;

            case "script":
            {
                arguments.AddRange(["migrations", "script"]);
                if (!invocation.HasFlag("no-idempotent"))
                {
                    arguments.Add("--idempotent");
                }

                var output = invocation.TryGetOption("output") ?? invocation.Positionals.FirstOrDefault() ?? "migrations.sql";
                arguments.AddRange(["-o", output]);
                arguments.AddRange(BuildCommonArguments(profile));
                return arguments;
            }

            case "pending":
                arguments.AddRange(["migrations", "has-pending-model-changes"]);
                arguments.AddRange(BuildCommonArguments(profile));
                return arguments;

            case "bundle":
            {
                arguments.AddRange(["migrations", "bundle", "--force"]);
                var output = invocation.TryGetOption("output") ?? invocation.Positionals.FirstOrDefault();
                if (!string.IsNullOrWhiteSpace(output))
                {
                    arguments.AddRange(["-o", output]);
                }

                arguments.AddRange(BuildCommonArguments(profile));
                return arguments;
            }

            default:
                throw new CliUsageException($"'{invocation.Command}' is not a supported EF command.");
        }
    }

    private List<string> BuildCommonArguments(EfProfile profile)
    {
        var arguments = new List<string>
        {
            "--project", profile.DbContextProject,
            "--startup-project", profile.StartupProject
        };

        if (!string.IsNullOrWhiteSpace(profile.DbContextName))
        {
            arguments.AddRange(["--context", profile.DbContextName]);
        }

        return arguments;
    }

    private bool ShouldProceed(CliInvocation invocation)
    {
        return invocation.Command switch
        {
            "drop" => ConfirmDestructive(
                invocation.Force,
                "Drop the database",
                "The entire database and all its data will be permanently deleted."),
            "reset" => ConfirmDestructive(
                invocation.Force,
                "Reset the database (drop + re-apply all migrations)",
                "The database will be dropped and recreated empty. All data will be lost."),
            "update" => ConfirmUpdate(invocation),
            _ => true
        };
    }

    private bool ConfirmUpdate(CliInvocation invocation)
    {
        var target = invocation.Positionals.FirstOrDefault();
        if (string.IsNullOrWhiteSpace(target))
        {
            return true;
        }

        if (string.Equals(target, "0", StringComparison.Ordinal))
        {
            return ConfirmDestructive(
                invocation.Force,
                "Revert all migrations (update 0)",
                "Every table and column created by migrations will be dropped.");
        }

        if (invocation.Force)
        {
            Console.WriteLine($"Skipping confirmation for update {target} because --force was specified.");
            return true;
        }

        Console.WriteLine();
        Console.WriteLine($"Updating to a specific migration: {target}");
        Console.WriteLine("If this target is behind the current database state, tables or columns may be dropped.");
        Console.Write("Continue? [y/N]: ");

        var answer = Console.ReadLine();
        if (!IsYes(answer))
        {
            Console.WriteLine("Aborted.");
            return false;
        }

        return true;
    }

    private bool ConfirmDestructive(bool force, string action, string consequence)
    {
        if (force)
        {
            Console.WriteLine($"Skipping confirmation for '{action}' because --force was specified.");
            return true;
        }

        Console.WriteLine();
        Console.WriteLine("============================================================");
        Console.WriteLine($"DESTRUCTIVE ACTION: {action}");
        Console.WriteLine("============================================================");
        Console.WriteLine(consequence);
        Console.WriteLine("This cannot be undone automatically.");
        Console.WriteLine();

        Console.Write("Continue? [y/N]: ");
        var firstConfirmation = Console.ReadLine();
        if (!IsYes(firstConfirmation))
        {
            Console.WriteLine("Aborted.");
            return false;
        }

        Console.Write("Type 'YES' to confirm: ");
        var secondConfirmation = Console.ReadLine();
        if (!string.Equals(secondConfirmation, "YES", StringComparison.Ordinal))
        {
            Console.WriteLine("Aborted. Confirmation text did not match.");
            return false;
        }

        return true;
    }

    private static bool IsYes(string? answer)
    {
        return string.Equals(answer, "y", StringComparison.OrdinalIgnoreCase);
    }

    private static void ValidateProfile(EfProfile profile)
    {
        if (!Directory.Exists(profile.WorkingDirectory))
        {
            throw new InvalidOperationException($"Working directory was not found: {profile.WorkingDirectory}");
        }

        if (!File.Exists(profile.DbContextProject))
        {
            throw new InvalidOperationException($"DbContext project was not found: {profile.DbContextProject}");
        }

        if (!File.Exists(profile.StartupProject))
        {
            throw new InvalidOperationException($"Startup project was not found: {profile.StartupProject}");
        }

        if (Path.IsPathRooted(profile.MigrationsDirectory))
        {
            throw new InvalidOperationException("The migrations directory must be relative to the DbContext project.");
        }
    }

    private static IReadOnlyList<string> DiscoverProjects(string workingDirectory)
    {
        return Directory
            .EnumerateFiles(workingDirectory, "*.csproj", SearchOption.AllDirectories)
            .Where(path => !IsIgnoredPath(path))
            .OrderBy(path => path, StringComparer.OrdinalIgnoreCase)
            .ToList();
    }

    private static bool IsIgnoredPath(string path)
    {
        var normalizedPath = path.Replace('\\', '/');
        return normalizedPath.Contains("/bin/", StringComparison.OrdinalIgnoreCase)
            || normalizedPath.Contains("/obj/", StringComparison.OrdinalIgnoreCase)
            || normalizedPath.Contains("/.git/", StringComparison.OrdinalIgnoreCase);
    }

    private static string PromptForProject(string label, string workingDirectory, IReadOnlyList<string> discoveredProjects, string? defaultValue)
    {
        while (true)
        {
            Console.Write($"{label}{FormatDefault(defaultValue)}: ");
            var answer = Console.ReadLine()?.Trim();

            if (string.IsNullOrWhiteSpace(answer))
            {
                if (!string.IsNullOrWhiteSpace(defaultValue))
                {
                    return defaultValue;
                }

                Console.WriteLine("A value is required.");
                continue;
            }

            if (int.TryParse(answer, out var index) && index >= 1 && index <= discoveredProjects.Count)
            {
                return Path.GetRelativePath(workingDirectory, discoveredProjects[index - 1]);
            }

            return answer;
        }
    }

    private static string Prompt(string label, string defaultValue)
    {
        Console.Write($"{label}{FormatDefault(defaultValue)}: ");
        var answer = Console.ReadLine();
        return string.IsNullOrWhiteSpace(answer) ? defaultValue : answer.Trim();
    }

    private static string FormatDefault(string? defaultValue)
    {
        return string.IsNullOrWhiteSpace(defaultValue) ? string.Empty : $" [{defaultValue}]";
    }

    private static string ResolveDirectoryPath(string baseDirectory, string input)
    {
        var path = Path.IsPathRooted(input)
            ? input
            : Path.Combine(baseDirectory, input);

        return Path.GetFullPath(path);
    }

    private static string ResolveFilePath(string baseDirectory, string input, string label)
    {
        var path = Path.IsPathRooted(input)
            ? input
            : Path.Combine(baseDirectory, input);

        var fullPath = Path.GetFullPath(path);
        if (!File.Exists(fullPath))
        {
            throw new InvalidOperationException($"{label} was not found: {fullPath}");
        }

        if (!fullPath.EndsWith(".csproj", StringComparison.OrdinalIgnoreCase))
        {
            throw new InvalidOperationException($"{label} must point to a .csproj file: {fullPath}");
        }

        return fullPath;
    }

    private static string NormalizeRelativeDirectory(string migrationsDirectory)
    {
        var normalized = migrationsDirectory.Trim().Replace('\\', '/');
        while (normalized.StartsWith("./", StringComparison.Ordinal))
        {
            normalized = normalized[2..];
        }

        normalized = normalized.Trim('/');

        if (string.IsNullOrWhiteSpace(normalized))
        {
            return "Persistence/Migrations";
        }

        if (Path.IsPathRooted(normalized))
        {
            throw new InvalidOperationException("The migrations directory must be relative to the DbContext project.");
        }

        return normalized;
    }

    private static void WriteProfile(EfProfile profile, bool isActive)
    {
        Console.WriteLine($"Profile: {profile.Name}{(isActive ? " (active)" : string.Empty)}");
        Console.WriteLine($"  Working directory : {profile.WorkingDirectory}");
        Console.WriteLine($"  DbContext project : {profile.DbContextProject}");
        Console.WriteLine($"  Startup project   : {profile.StartupProject}");
        Console.WriteLine($"  Migrations dir    : {profile.MigrationsDirectory}");
        Console.WriteLine($"  DbContext name    : {(string.IsNullOrWhiteSpace(profile.DbContextName) ? "<default>" : profile.DbContextName)}");
        Console.WriteLine($"  Updated at        : {profile.UpdatedAt:O}");
    }
}