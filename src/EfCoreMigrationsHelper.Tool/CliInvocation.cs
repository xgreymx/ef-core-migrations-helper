namespace EfCoreMigrationsHelper.Tool;

internal sealed class CliInvocation
{
    public string Command { get; init; } = "help";

    public string? HelpTopic { get; init; }

    public IReadOnlyList<string> Positionals { get; init; } = Array.Empty<string>();

    public IReadOnlyDictionary<string, string> Options { get; init; } = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);

    public IReadOnlySet<string> Flags { get; init; } = new HashSet<string>(StringComparer.OrdinalIgnoreCase);

    public string? ConfigPath => TryGetOption("config");

    public string? ProfileName => TryGetOption("profile");

    public bool Force => HasFlag("force");

    public bool WantsHelp => HasFlag("help");

    public bool HasFlag(string name)
    {
        return Flags.Contains(name);
    }

    public string? TryGetOption(string name)
    {
        return Options.TryGetValue(name, out var value) ? value : null;
    }
}