namespace EfCoreMigrationsHelper.Tool;

internal static class CommandLineParser
{
    private static readonly Dictionary<string, string> CommandAliases = new(StringComparer.OrdinalIgnoreCase)
    {
        ["a"] = "add",
        ["cfg"] = "config",
        ["h"] = "help",
        ["init"] = "setup",
        ["ls"] = "list",
        ["rm"] = "remove",
        ["sql"] = "script",
        ["u"] = "update",
        ["up"] = "update"
    };

    private static readonly HashSet<string> FlagOptions = new(StringComparer.OrdinalIgnoreCase)
    {
        "force",
        "help",
        "idempotent",
        "no-auto-recover",
        "no-idempotent"
    };

    private static readonly HashSet<string> ValueOptions = new(StringComparer.OrdinalIgnoreCase)
    {
        "config",
        "context",
        "dbcontext",
        "migrations-dir",
        "output",
        "profile",
        "startup",
        "working-dir"
    };

    public static CliInvocation Parse(string[] args)
    {
        var positionals = new List<string>();
        var options = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
        var flags = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        string? command = null;

        for (var index = 0; index < args.Length; index++)
        {
            var token = args[index];

            if (token == "--")
            {
                for (var remainderIndex = index + 1; remainderIndex < args.Length; remainderIndex++)
                {
                    positionals.Add(args[remainderIndex]);
                }

                break;
            }

            var option = TryNormalizeOption(token, out var inlineValue);
            if (option is not null)
            {
                if (FlagOptions.Contains(option))
                {
                    flags.Add(option);
                    continue;
                }

                if (inlineValue is null)
                {
                    if (index + 1 >= args.Length)
                    {
                        throw new CliUsageException($"Option '{token}' requires a value.");
                    }

                    inlineValue = args[++index];
                }

                options[option] = inlineValue;
                continue;
            }

            if (command is null)
            {
                command = NormalizeCommand(token);
                continue;
            }

            positionals.Add(token);
        }

        command ??= "help";
        string? helpTopic = null;

        if (flags.Contains("help") && !string.Equals(command, "help", StringComparison.OrdinalIgnoreCase))
        {
            helpTopic = command;
            command = "help";
        }
        else if (string.Equals(command, "help", StringComparison.OrdinalIgnoreCase) && positionals.Count > 0)
        {
            helpTopic = NormalizeCommand(positionals[0]);
        }

        return new CliInvocation
        {
            Command = command,
            HelpTopic = helpTopic,
            Positionals = positionals,
            Options = options,
            Flags = flags
        };
    }

    private static string NormalizeCommand(string command)
    {
        return CommandAliases.TryGetValue(command, out var normalized)
            ? normalized
            : command.Trim().ToLowerInvariant();
    }

    private static string? TryNormalizeOption(string token, out string? inlineValue)
    {
        inlineValue = null;

        if (string.IsNullOrWhiteSpace(token) || token == "-" || !token.StartsWith("-", StringComparison.Ordinal))
        {
            return null;
        }

        if (!token.StartsWith("--", StringComparison.Ordinal))
        {
            return token switch
            {
                "-h" => "help",
                "-y" => "force",
                _ => throw new CliUsageException($"Unknown option '{token}'.")
            };
        }

        var normalized = token[2..];
        var separatorIndex = normalized.IndexOf('=');
        if (separatorIndex >= 0)
        {
            inlineValue = normalized[(separatorIndex + 1)..];
            normalized = normalized[..separatorIndex];
        }

        if (FlagOptions.Contains(normalized) || ValueOptions.Contains(normalized))
        {
            return normalized;
        }

        throw new CliUsageException($"Unknown option '{token}'.");
    }
}

internal sealed class CliUsageException : Exception
{
    public CliUsageException(string message)
        : base(message)
    {
    }
}