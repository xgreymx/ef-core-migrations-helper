using Xunit;

[assembly: CollectionBehavior(DisableTestParallelization = true)]

namespace EfCoreMigrationsHelper.Tool.Tests;

public sealed class EfCommandRunnerTests
{
    private const string TestWorkingDirectory = @"D:\work";
    private const string TestStartupProject = @"D:\src\My App\MyApp.Api.csproj";
    private const string TestDbContextProject = @"D:\src\My App\MyApp.Infrastructure.csproj";

    [Theory]
    [InlineData("Could not load file or assembly 'MyApp.dll'. 0x800711C7", true)]
    [InlineData("COULD NOT LOAD FILE OR ASSEMBLY 'MyApp.dll'.", true)]
    [InlineData("Random build failure", false)]
    public void LooksLikeCipBlock_matches_expected_markers(string output, bool expected)
    {
        Assert.Equal(expected, EfCommandRunner.LooksLikeCipBlock(output));
    }

    [Theory]
    [InlineData("20260421174048_DatabaseInitialization", true)]
    [InlineData("20260421_DatabaseInitialization", false)]
    [InlineData("DatabaseInitialization", false)]
    public void LooksLikeMigrationId_matches_expected_patterns(string line, bool expected)
    {
        Assert.Equal(expected, ConsoleUi.LooksLikeMigrationId(line));
    }

    [Fact]
    public async Task RunAsync_retries_once_after_cip_failure_and_succeeds()
    {
        var processRunner = new ScriptedProcessRunner();
        processRunner.EnqueueCaptured(17, stderr: "Could not load file or assembly 'MyApp.dll'. 0x800711C7");
        processRunner.EnqueueStreaming(0);
        processRunner.EnqueueStreaming(0);
        processRunner.EnqueueCaptured(0, stdout: "retry succeeded" + Environment.NewLine);

        var runner = new EfCommandRunner(processRunner, static (_, _) => { });

        var (exitCode, stdout, stderr) = await ExecuteAsync(runner, CreateRequest());

        Assert.Equal(0, exitCode);
        Assert.Contains("Detected a likely Smart App Control / Code Integrity block", stderr);
        Assert.Contains("known, sometimes random Windows 11 issue", stdout);
        Assert.Contains("retry succeeded", stdout);
        Assert.Contains("Automatic clean/build retry succeeded after a Smart App Control block.", stdout);
        Assert.DoesNotContain("0x800711C7", stderr);
        Assert.Equal(2, processRunner.CapturedCommands.Count);
        Assert.Equal(2, processRunner.StreamingCommands.Count);
        Assert.Equal("clean", processRunner.StreamingCommands[0][0]);
        Assert.Equal(TestStartupProject, processRunner.StreamingCommands[0][1]);
        Assert.Equal("build", processRunner.StreamingCommands[1][0]);
        Assert.Equal(TestStartupProject, processRunner.StreamingCommands[1][1]);
        Assert.Equal(processRunner.CapturedCommands[0], processRunner.CapturedCommands[1]);
    }

    [Fact]
    public async Task RunAsync_surfaces_original_failure_when_retry_fails()
    {
        var processRunner = new ScriptedProcessRunner();
        processRunner.EnqueueCaptured(19, stderr: "original cip error 0x800711C7" + Environment.NewLine);
        processRunner.EnqueueStreaming(0);
        processRunner.EnqueueStreaming(0);
        processRunner.EnqueueCaptured(23, stderr: "retry failed differently" + Environment.NewLine);

        var runner = new EfCommandRunner(processRunner, static (_, _) => { });

        var (exitCode, stdout, stderr) = await ExecuteAsync(runner, CreateRequest());

        Assert.Equal(19, exitCode);
        Assert.Contains("original cip error", stderr);
        Assert.DoesNotContain("retry failed differently", stderr);
        Assert.Contains("Already done: dotnet clean", stdout);
        Assert.Contains("Already done: dotnet build", stdout);
        Assert.Contains("Windows 11 updates released around February 2026", stdout);
        Assert.Contains("https://www.reddit.com/r/unrealengine/comments/1q26qsj/win_11_smart_app_control_keeps_blocking_random/", stdout);
        Assert.Equal(2, processRunner.CapturedCommands.Count);
        Assert.Equal(2, processRunner.StreamingCommands.Count);
    }

    [Fact]
    public async Task RunAsync_skips_recovery_for_non_cip_failures()
    {
        var processRunner = new ScriptedProcessRunner();
        processRunner.EnqueueCaptured(7, stderr: "plain failure" + Environment.NewLine);

        var runner = new EfCommandRunner(processRunner, static (_, _) => { });

        var (exitCode, _, stderr) = await ExecuteAsync(runner, CreateRequest());

        Assert.Equal(7, exitCode);
        Assert.Contains("plain failure", stderr);
        Assert.Single(processRunner.CapturedCommands);
        Assert.Empty(processRunner.StreamingCommands);
    }

    [Fact]
    public async Task RunAsync_writes_banner_spacing_and_summary_for_list_output()
    {
        const string migrationId = "20260421174048_DatabaseInitialization";

        var processRunner = new ScriptedProcessRunner();
        processRunner.EnqueueCaptured(
            0,
            stdout: string.Join(
                Environment.NewLine,
                [
                    "Build started...",
                    "Build succeeded.",
                    "info: Microsoft.EntityFrameworkCore.Database.Command[20101]",
                    "      Executed DbCommand (15ms) [Parameters=[], CommandType='Text', CommandTimeout='30']",
                    "      SELECT [MigrationId], [ProductVersion]",
                    "      FROM [__EFMigrationsHistory]",
                    "      ORDER BY [MigrationId];",
                    migrationId,
                    string.Empty
                ]));

        var runner = new EfCommandRunner(processRunner, static (_, _) => { });
        var request = new EfCommandRequest(
            TestWorkingDirectory,
            ["ef", "migrations", "list", "--project", TestDbContextProject, "--startup-project", TestStartupProject],
            TestStartupProject);

        var (exitCode, stdout, stderr) = await ExecuteAsync(runner, request);

        Assert.Equal(0, exitCode);
        Assert.Empty(stderr);
        Assert.Contains("[RUN] Running EF migrations list", stdout);
        Assert.Contains("[OK] Command completed", stdout);
        Assert.Contains($"ORDER BY [MigrationId];{Environment.NewLine}{Environment.NewLine}{migrationId}", stdout);
    }

    [Fact]
    public async Task RunAsync_skips_recovery_when_auto_recover_is_disabled()
    {
        var invocation = CommandLineParser.Parse(["update", "--no-auto-recover"]);
        Assert.False(invocation.AutoRecover);

        var processRunner = new ScriptedProcessRunner();
        processRunner.EnqueueCaptured(11, stderr: "Could not load file or assembly 'MyApp.dll'. 0x800711C7" + Environment.NewLine);

        var runner = new EfCommandRunner(processRunner, static (_, _) => { });

        var (exitCode, stdout, stderr) = await ExecuteAsync(runner, CreateRequest(invocation.AutoRecover));

        Assert.Equal(11, exitCode);
        Assert.Contains("0x800711C7", stderr);
        Assert.Contains("Automatic clean/build retry was skipped because auto-recovery is disabled for this command.", stdout);
        Assert.Contains("https://www.reddit.com/r/unrealengine/comments/1q26qsj/win_11_smart_app_control_keeps_blocking_random/", stdout);
        Assert.Single(processRunner.CapturedCommands);
        Assert.Empty(processRunner.StreamingCommands);
    }

    [Fact]
    public void WriteCapturedOutput_can_start_on_a_new_line_for_spinner_output()
    {
        var originalOut = Console.Out;
        var originalError = Console.Error;
        using var stdout = new StringWriter();
        using var stderr = new StringWriter();

        Console.SetOut(stdout);
        Console.SetError(stderr);

        try
        {
            ConsoleUi.WriteCapturedOutput(
                new DotnetCommandCaptureResult(0, "Build started..." + Environment.NewLine, string.Empty),
                startOnNewLine: true);
        }
        finally
        {
            Console.SetOut(originalOut);
            Console.SetError(originalError);
        }

        Assert.Equal(Environment.NewLine + "Build started..." + Environment.NewLine, stdout.ToString());
        Assert.Empty(stderr.ToString());
    }

    private static EfCommandRequest CreateRequest(bool autoRecover = true)
    {
        return new EfCommandRequest(
            TestWorkingDirectory,
            ["ef", "database", "update", "--project", TestDbContextProject, "--startup-project", TestStartupProject],
            TestStartupProject,
            autoRecover);
    }

    private static async Task<(int ExitCode, string StandardOutput, string StandardError)> ExecuteAsync(EfCommandRunner runner, EfCommandRequest request)
    {
        var originalOut = Console.Out;
        var originalError = Console.Error;
        using var stdout = new StringWriter();
        using var stderr = new StringWriter();

        Console.SetOut(stdout);
        Console.SetError(stderr);

        try
        {
            var exitCode = await runner.RunAsync(request);
            return (exitCode, stdout.ToString(), stderr.ToString());
        }
        finally
        {
            Console.SetOut(originalOut);
            Console.SetError(originalError);
        }
    }

    private sealed class ScriptedProcessRunner : IDotnetProcessRunner
    {
        private readonly Queue<DotnetCommandCaptureResult> _capturedResults = new();
        private readonly Queue<int> _streamingResults = new();

        public List<string[]> CapturedCommands { get; } = [];

        public List<string[]> StreamingCommands { get; } = [];

        public void EnqueueCaptured(int exitCode, string stdout = "", string stderr = "")
        {
            _capturedResults.Enqueue(new DotnetCommandCaptureResult(exitCode, stdout, stderr));
        }

        public void EnqueueStreaming(int exitCode)
        {
            _streamingResults.Enqueue(exitCode);
        }

        public Task<DotnetCommandCaptureResult> RunCapturedAsync(string workingDirectory, IReadOnlyList<string> args, CancellationToken cancellationToken = default)
        {
            CapturedCommands.Add(args.ToArray());
            return Task.FromResult(_capturedResults.Dequeue());
        }

        public Task<int> RunStreamingAsync(string workingDirectory, IReadOnlyList<string> args, CancellationToken cancellationToken = default)
        {
            StreamingCommands.Add(args.ToArray());
            return Task.FromResult(_streamingResults.Dequeue());
        }
    }
}