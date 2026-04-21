using System.ComponentModel;
using System.Diagnostics;

namespace EfCoreMigrationsHelper.Tool;

internal sealed class EfCommandRunner
{
    public async Task<int> RunAsync(string workingDirectory, IReadOnlyList<string> args, CancellationToken cancellationToken = default)
    {
        Console.WriteLine($"> dotnet {string.Join(' ', args.Select(QuoteArgument))}");

        var startInfo = new ProcessStartInfo
        {
            FileName = "dotnet",
            WorkingDirectory = workingDirectory,
            UseShellExecute = false
        };

        foreach (var argument in args)
        {
            startInfo.ArgumentList.Add(argument);
        }

        try
        {
            using var process = Process.Start(startInfo);
            if (process is null)
            {
                Console.Error.WriteLine("Failed to start the dotnet process.");
                return 1;
            }

            await process.WaitForExitAsync(cancellationToken);
            return process.ExitCode;
        }
        catch (Win32Exception)
        {
            Console.Error.WriteLine("Could not find 'dotnet' on PATH. Install the .NET SDK and ensure dotnet is available in your shell.");
            return 1;
        }
    }

    private static string QuoteArgument(string argument)
    {
        return argument.Any(char.IsWhiteSpace)
            ? $"\"{argument.Replace("\"", "\\\"")}\""
            : argument;
    }
}