using System.ComponentModel;
using System.Diagnostics;

namespace EfCoreMigrationsHelper.Tool;

internal sealed record EfCommandRequest(
    string WorkingDirectory,
    IReadOnlyList<string> Arguments,
    string? StartupProject,
    bool AutoRecover = true);

internal sealed record DotnetCommandCaptureResult(int ExitCode, string StandardOutput, string StandardError)
{
    public string CombinedOutput => string.Concat(StandardOutput, Environment.NewLine, StandardError);
}

internal interface IDotnetProcessRunner
{
    Task<DotnetCommandCaptureResult> RunCapturedAsync(string workingDirectory, IReadOnlyList<string> args, CancellationToken cancellationToken = default);

    Task<int> RunStreamingAsync(string workingDirectory, IReadOnlyList<string> args, CancellationToken cancellationToken = default);
}

internal sealed class DotnetProcessRunner : IDotnetProcessRunner
{
    private const string DotnetMissingMessage = "Could not find 'dotnet' on PATH. Install the .NET SDK and ensure dotnet is available in your shell.";

    public async Task<DotnetCommandCaptureResult> RunCapturedAsync(string workingDirectory, IReadOnlyList<string> args, CancellationToken cancellationToken = default)
    {
        var startInfo = CreateStartInfo(workingDirectory, args);
        startInfo.RedirectStandardOutput = true;
        startInfo.RedirectStandardError = true;

        try
        {
            using var process = Process.Start(startInfo);
            if (process is null)
            {
                return new DotnetCommandCaptureResult(1, string.Empty, "Failed to start the dotnet process." + Environment.NewLine);
            }

            using var registration = RegisterCancellation(process, cancellationToken);
            var stdoutTask = process.StandardOutput.ReadToEndAsync(cancellationToken);
            var stderrTask = process.StandardError.ReadToEndAsync(cancellationToken);

            await process.WaitForExitAsync(cancellationToken);

            return new DotnetCommandCaptureResult(
                process.ExitCode,
                await stdoutTask,
                await stderrTask);
        }
        catch (Win32Exception)
        {
            return new DotnetCommandCaptureResult(1, string.Empty, DotnetMissingMessage + Environment.NewLine);
        }
    }

    public async Task<int> RunStreamingAsync(string workingDirectory, IReadOnlyList<string> args, CancellationToken cancellationToken = default)
    {
        var startInfo = CreateStartInfo(workingDirectory, args);

        try
        {
            using var process = Process.Start(startInfo);
            if (process is null)
            {
                Console.Error.WriteLine("Failed to start the dotnet process.");
                return 1;
            }

            using var registration = RegisterCancellation(process, cancellationToken);
            await process.WaitForExitAsync(cancellationToken);
            return process.ExitCode;
        }
        catch (Win32Exception)
        {
            Console.Error.WriteLine(DotnetMissingMessage);
            return 1;
        }
    }

    private static ProcessStartInfo CreateStartInfo(string workingDirectory, IReadOnlyList<string> args)
    {
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

        return startInfo;
    }

    private static CancellationTokenRegistration RegisterCancellation(Process process, CancellationToken cancellationToken)
    {
        if (!cancellationToken.CanBeCanceled)
        {
            return default;
        }

        return cancellationToken.Register(static state =>
        {
            try
            {
                var runningProcess = (Process)state!;
                if (!runningProcess.HasExited)
                {
                    runningProcess.Kill(entireProcessTree: true);
                }
            }
            catch (InvalidOperationException)
            {
            }
        }, process);
    }
}

internal sealed class EfCommandRunner
{
    private readonly IDotnetProcessRunner _processRunner;
    private readonly Action<string, IReadOnlyList<string>> _appendAutoRecoverLog;

    public EfCommandRunner()
        : this(new DotnetProcessRunner())
    {
    }

    internal EfCommandRunner(IDotnetProcessRunner processRunner, Action<string, IReadOnlyList<string>>? appendAutoRecoverLog = null)
    {
        _processRunner = processRunner;
        _appendAutoRecoverLog = appendAutoRecoverLog ?? AppendAutoRecoverLog;
    }

    public Task<int> RunAsync(string workingDirectory, IReadOnlyList<string> args, CancellationToken cancellationToken = default)
    {
        return RunAsync(
            new EfCommandRequest(
                workingDirectory,
                args,
                TryGetOptionValue(args, "--startup-project")),
            cancellationToken);
    }

    public async Task<int> RunAsync(EfCommandRequest command, CancellationToken cancellationToken = default)
    {
        var totalStopwatch = Stopwatch.StartNew();
        var autoRecoverEnabled = command.AutoRecover && !IsAutoRecoverDisabledByEnvironment();
        using var activity = ConsoleUi.StartCommand(command.Arguments);

        var result = await _processRunner.RunCapturedAsync(command.WorkingDirectory, command.Arguments, cancellationToken);
        var isCipBlock = LooksLikeCipBlock(result.CombinedOutput);
        activity.Stop();

        if (result.ExitCode == 0)
        {
            ConsoleUi.WriteCapturedOutput(result, startOnNewLine: activity.IsAnimated);
            ConsoleUi.WriteCommandSummary(0, totalStopwatch.Elapsed);
            return 0;
        }

        if (!isCipBlock)
        {
            ConsoleUi.WriteCapturedOutput(result, startOnNewLine: activity.IsAnimated);
            ConsoleUi.WriteCommandSummary(result.ExitCode, totalStopwatch.Elapsed);
            return result.ExitCode;
        }

        if (!autoRecoverEnabled || string.IsNullOrWhiteSpace(command.StartupProject))
        {
            ConsoleUi.WriteCapturedOutput(result, startOnNewLine: activity.IsAnimated);
            WriteSmartAppControlTroubleshooting(
                command.StartupProject,
                cleanBuildAttempted: false,
                skipReason: autoRecoverEnabled
                    ? "Automatic clean/build retry was skipped because no startup project was available."
                    : "Automatic clean/build retry was skipped because auto-recovery is disabled for this command.");
            ConsoleUi.WriteCommandSummary(result.ExitCode, totalStopwatch.Elapsed);
            return result.ExitCode;
        }

        WriteSmartAppControlDetectionNotice(command.StartupProject);
        _appendAutoRecoverLog(command.StartupProject, command.Arguments);

        var cleanArguments = new[] { "clean", command.StartupProject };
        using var cleanActivity = ConsoleUi.StartCommand(cleanArguments, enableSpinner: false);
        var cleanExitCode = await _processRunner.RunStreamingAsync(command.WorkingDirectory, cleanArguments, cancellationToken);
        ConsoleUi.WriteCommandSummary(cleanExitCode, cleanActivity.Elapsed);
        if (cleanExitCode != 0)
        {
            return cleanExitCode;
        }

        var buildArguments = new[] { "build", command.StartupProject };
        using var buildActivity = ConsoleUi.StartCommand(buildArguments, enableSpinner: false);
        var buildExitCode = await _processRunner.RunStreamingAsync(command.WorkingDirectory, buildArguments, cancellationToken);
        ConsoleUi.WriteCommandSummary(buildExitCode, buildActivity.Elapsed);
        if (buildExitCode != 0)
        {
            return buildExitCode;
        }

        var retryCommand = command with { AutoRecover = false };
        using var retryActivity = ConsoleUi.StartCommand(retryCommand.Arguments);
        var retryResult = await _processRunner.RunCapturedAsync(retryCommand.WorkingDirectory, retryCommand.Arguments, cancellationToken);
        retryActivity.Stop();
        if (retryResult.ExitCode == 0)
        {
            ConsoleUi.WriteCapturedOutput(retryResult, startOnNewLine: retryActivity.IsAnimated);
            ConsoleUi.WriteSuccess("Automatic clean/build retry succeeded after a Smart App Control block.");
            ConsoleUi.WriteCommandSummary(0, totalStopwatch.Elapsed);
            return 0;
        }

        ConsoleUi.WriteCapturedOutput(result, startOnNewLine: retryActivity.IsAnimated);
        WriteSmartAppControlTroubleshooting(
            command.StartupProject,
            cleanBuildAttempted: true,
            skipReason: null);
        ConsoleUi.WriteCommandSummary(result.ExitCode, totalStopwatch.Elapsed);
        return result.ExitCode;
    }

    internal static bool LooksLikeCipBlock(string output)
    {
        return output.Contains("0x800711C7", StringComparison.OrdinalIgnoreCase)
            || output.Contains("Could not load file or assembly", StringComparison.OrdinalIgnoreCase);
    }

    internal static bool IsAutoRecoverDisabledByEnvironment()
    {
        return string.Equals(Environment.GetEnvironmentVariable("EFM_NO_AUTO_RECOVER"), "1", StringComparison.OrdinalIgnoreCase);
    }

    private static void WriteSmartAppControlDetectionNotice(string startupProject)
    {
        ConsoleUi.WriteWarning("Detected a likely Smart App Control / Code Integrity block while loading the EF Core startup assembly. Running dotnet clean + dotnet build and retrying once.");
        ConsoleUi.WriteInfo("This is a known, sometimes random Windows 11 issue where Smart App Control starts blocking project DLLs during development.");
        ConsoleUi.WriteInfo($"Startup project: {startupProject}");
        ConsoleUi.WriteInfo("If the retry still fails, the tool will show extra troubleshooting steps and a reference link.");
    }

    private static void WriteSmartAppControlTroubleshooting(string? startupProject, bool cleanBuildAttempted, string? skipReason)
    {
        ConsoleUi.WriteWarning(cleanBuildAttempted
            ? "Automatic clean/build already ran, but Smart App Control still appears to be blocking the startup assembly."
            : "The failure still looks like a Smart App Control / Code Integrity block.");

        if (!string.IsNullOrWhiteSpace(startupProject))
        {
            ConsoleUi.WriteInfo($"Startup project: {startupProject}");
        }

        if (cleanBuildAttempted)
        {
            if (!string.IsNullOrWhiteSpace(startupProject))
            {
                ConsoleUi.WriteSuccess($"Already done: dotnet clean {startupProject}");
                ConsoleUi.WriteSuccess($"Already done: dotnet build {startupProject}");
            }
            else
            {
                ConsoleUi.WriteSuccess("Already done: dotnet clean <startup-project>");
                ConsoleUi.WriteSuccess("Already done: dotnet build <startup-project>");
            }
        }
        else if (!string.IsNullOrWhiteSpace(skipReason))
        {
            ConsoleUi.WriteInfo(skipReason);
        }

        ConsoleUi.WriteInfo("Other troubleshooting options:");
        ConsoleUi.WriteInfo("1. Close Visual Studio, terminals, or any running process that may still have the blocked DLL loaded.");
        ConsoleUi.WriteInfo("2. Delete bin and obj for the startup and DbContext projects, then rebuild and rerun the command.");
        ConsoleUi.WriteInfo("3. Reboot Windows and rerun the migration command.");
        ConsoleUi.WriteWarning("Best long-term development workaround: temporarily disable Smart App Control if it keeps blocking random project DLLs.");
        ConsoleUi.WriteInfo("Windows 11 updates released around February 2026 allow turning Smart App Control off and on again without reinstalling Windows.");
        ConsoleUi.WriteInfo("Reference: https://www.reddit.com/r/unrealengine/comments/1q26qsj/win_11_smart_app_control_keeps_blocking_random/");
    }

    private static void AppendAutoRecoverLog(string startupProject, IReadOnlyList<string> args)
    {
        try
        {
            var localAppData = Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData);
            if (string.IsNullOrWhiteSpace(localAppData))
            {
                return;
            }

            var directory = Path.Combine(localAppData, "efm");
            Directory.CreateDirectory(directory);
            var logPath = Path.Combine(directory, "auto-recover.log");
            var line = $"{DateTimeOffset.UtcNow:O}\t{startupProject}\t{ConsoleUi.FormatArguments(args)}{Environment.NewLine}";
            File.AppendAllText(logPath, line);
        }
        catch (IOException)
        {
        }
        catch (UnauthorizedAccessException)
        {
        }
    }

    private static string? TryGetOptionValue(IReadOnlyList<string> args, string optionName)
    {
        for (var index = 0; index < args.Count; index++)
        {
            if (string.Equals(args[index], optionName, StringComparison.OrdinalIgnoreCase))
            {
                return index + 1 < args.Count ? args[index + 1] : null;
            }

            if (args[index].StartsWith(optionName + "=", StringComparison.OrdinalIgnoreCase))
            {
                return args[index][(optionName.Length + 1)..];
            }
        }

        return null;
    }
}