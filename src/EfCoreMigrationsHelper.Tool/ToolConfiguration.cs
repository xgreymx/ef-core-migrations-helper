using System.Text.Json;

namespace EfCoreMigrationsHelper.Tool;

internal sealed class ToolConfiguration
{
    public int Version { get; set; } = 1;

    public string? ActiveProfile { get; set; } = "default";

    public Dictionary<string, EfProfile> Profiles { get; set; } = new(StringComparer.OrdinalIgnoreCase);
}

internal sealed class EfProfile
{
    public string Name { get; set; } = "default";

    public string WorkingDirectory { get; set; } = Directory.GetCurrentDirectory();

    public string DbContextProject { get; set; } = string.Empty;

    public string StartupProject { get; set; } = string.Empty;

    public string MigrationsDirectory { get; set; } = "Persistence/Migrations";

    public string? DbContextName { get; set; }

    public DateTimeOffset UpdatedAt { get; set; } = DateTimeOffset.UtcNow;
}

internal sealed class ToolConfigurationStore
{
    private static readonly JsonSerializerOptions JsonOptions = new()
    {
        PropertyNamingPolicy = JsonNamingPolicy.CamelCase,
        WriteIndented = true
    };

    public bool Exists(string? overridePath, string? searchDirectory = null)
    {
        return File.Exists(ResolvePath(overridePath, searchDirectory));
    }

    public ToolConfiguration Load(string? overridePath, string? searchDirectory = null)
    {
        var configPath = ResolvePath(overridePath, searchDirectory);
        if (!File.Exists(configPath))
        {
            return new ToolConfiguration();
        }

        var json = File.ReadAllText(configPath);
        var configuration = JsonSerializer.Deserialize<ToolConfiguration>(json, JsonOptions) ?? new ToolConfiguration();
        configuration.Profiles = new Dictionary<string, EfProfile>(configuration.Profiles, StringComparer.OrdinalIgnoreCase);
        var storageRoot = ResolveStorageRoot(configPath);

        foreach (var entry in configuration.Profiles)
        {
            entry.Value.Name = string.IsNullOrWhiteSpace(entry.Value.Name) ? entry.Key : entry.Value.Name;
            entry.Value.WorkingDirectory = ResolveStoredDirectoryPath(storageRoot, entry.Value.WorkingDirectory);
            entry.Value.DbContextProject = ResolveStoredFilePath(storageRoot, entry.Value.DbContextProject);
            entry.Value.StartupProject = ResolveStoredFilePath(storageRoot, entry.Value.StartupProject);
        }

        if (string.IsNullOrWhiteSpace(configuration.ActiveProfile) && configuration.Profiles.Count > 0)
        {
            configuration.ActiveProfile = configuration.Profiles.Keys.First();
        }

        return configuration;
    }

    public void Save(ToolConfiguration configuration, string? overridePath, string? searchDirectory = null)
    {
        var configPath = ResolvePath(overridePath, searchDirectory);
        var configDirectory = Path.GetDirectoryName(configPath);
        if (string.IsNullOrWhiteSpace(configDirectory))
        {
            throw new InvalidOperationException($"Unable to determine the config directory for '{configPath}'.");
        }

        Directory.CreateDirectory(configDirectory);
        configuration.Version = 1;
        var storageRoot = ResolveStorageRoot(configPath);
        var storedConfiguration = CreateStoredConfiguration(configuration, storageRoot);
        var json = JsonSerializer.Serialize(storedConfiguration, JsonOptions);
        File.WriteAllText(configPath, json + Environment.NewLine);
    }

    public string ResolvePath(string? overridePath, string? searchDirectory = null)
    {
        if (!string.IsNullOrWhiteSpace(overridePath))
        {
            return Path.GetFullPath(overridePath);
        }

        var environmentPath = Environment.GetEnvironmentVariable("EFMH_CONFIG_PATH");
        if (!string.IsNullOrWhiteSpace(environmentPath))
        {
            return Path.GetFullPath(environmentPath);
        }

        var effectiveSearchDirectory = Path.GetFullPath(searchDirectory ?? Directory.GetCurrentDirectory());
        var projectRoot = ResolveProjectRoot(effectiveSearchDirectory);
        return Path.Combine(projectRoot, ".efm", "config.json");
    }

    private static string ResolveProjectRoot(string searchDirectory)
    {
        foreach (var candidate in EnumerateSelfAndAncestors(searchDirectory))
        {
            if (File.Exists(Path.Combine(candidate, ".efm", "config.json")))
            {
                return candidate;
            }
        }

        foreach (var candidate in EnumerateSelfAndAncestors(searchDirectory))
        {
            if (HasProjectRootMarker(candidate))
            {
                return candidate;
            }
        }

        foreach (var candidate in EnumerateSelfAndAncestors(searchDirectory))
        {
            if (Directory.EnumerateFiles(candidate, "*.csproj", SearchOption.TopDirectoryOnly).Any())
            {
                return candidate;
            }
        }

        return searchDirectory;
    }

    private static IEnumerable<string> EnumerateSelfAndAncestors(string startDirectory)
    {
        var current = new DirectoryInfo(startDirectory);
        while (current is not null)
        {
            yield return current.FullName;
            current = current.Parent;
        }
    }

    private static bool HasProjectRootMarker(string directory)
    {
        return Directory.Exists(Path.Combine(directory, ".git"))
            || File.Exists(Path.Combine(directory, ".git"))
            || File.Exists(Path.Combine(directory, "global.json"))
            || File.Exists(Path.Combine(directory, "Directory.Build.props"))
            || File.Exists(Path.Combine(directory, "Directory.Build.targets"))
            || Directory.EnumerateFiles(directory, "*.sln", SearchOption.TopDirectoryOnly).Any()
            || Directory.EnumerateFiles(directory, "*.slnx", SearchOption.TopDirectoryOnly).Any();
    }

    private static ToolConfiguration CreateStoredConfiguration(ToolConfiguration configuration, string storageRoot)
    {
        return new ToolConfiguration
        {
            Version = 1,
            ActiveProfile = configuration.ActiveProfile,
            Profiles = configuration.Profiles.ToDictionary(
                entry => entry.Key,
                entry => CreateStoredProfile(entry.Value, storageRoot),
                StringComparer.OrdinalIgnoreCase)
        };
    }

    private static EfProfile CreateStoredProfile(EfProfile profile, string storageRoot)
    {
        return new EfProfile
        {
            Name = profile.Name,
            WorkingDirectory = ToStoredPath(storageRoot, profile.WorkingDirectory),
            DbContextProject = ToStoredPath(storageRoot, profile.DbContextProject),
            StartupProject = ToStoredPath(storageRoot, profile.StartupProject),
            MigrationsDirectory = profile.MigrationsDirectory,
            DbContextName = profile.DbContextName,
            UpdatedAt = profile.UpdatedAt
        };
    }

    private static string ResolveStorageRoot(string configPath)
    {
        var configDirectory = Path.GetDirectoryName(Path.GetFullPath(configPath));
        if (string.IsNullOrWhiteSpace(configDirectory))
        {
            throw new InvalidOperationException($"Unable to determine the storage root for '{configPath}'.");
        }

        var directoryInfo = new DirectoryInfo(configDirectory);
        if (string.Equals(directoryInfo.Name, ".efm", StringComparison.OrdinalIgnoreCase) && directoryInfo.Parent is not null)
        {
            return directoryInfo.Parent.FullName;
        }

        return directoryInfo.FullName;
    }

    private static string ResolveStoredDirectoryPath(string storageRoot, string? path)
    {
        if (string.IsNullOrWhiteSpace(path))
        {
            return storageRoot;
        }

        return ResolveStoredPath(storageRoot, path);
    }

    private static string ResolveStoredFilePath(string storageRoot, string? path)
    {
        if (string.IsNullOrWhiteSpace(path))
        {
            return string.Empty;
        }

        return ResolveStoredPath(storageRoot, path);
    }

    private static string ResolveStoredPath(string storageRoot, string path)
    {
        return Path.IsPathRooted(path)
            ? Path.GetFullPath(path)
            : Path.GetFullPath(Path.Combine(storageRoot, path));
    }

    private static string ToStoredPath(string storageRoot, string path)
    {
        if (string.IsNullOrWhiteSpace(path))
        {
            return path;
        }

        var fullPath = Path.GetFullPath(path);
        return Path.GetRelativePath(storageRoot, fullPath).Replace('\\', '/');
    }
}