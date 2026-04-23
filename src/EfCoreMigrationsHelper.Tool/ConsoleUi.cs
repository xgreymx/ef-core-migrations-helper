using System.Diagnostics;

namespace EfCoreMigrationsHelper.Tool;

internal static class ConsoleUi
{
    private static readonly object Sync = new();

    public static ConsoleActivity StartCommand(IReadOnlyList<string> arguments, string executable = "dotnet", bool enableSpinner = true)
    {
        var description = DescribeCommand(arguments, executable);
        var commandText = $"{executable} {FormatArguments(arguments)}";

        lock (Sync)
        {
            WriteBlankLineIfInteractive();
            WriteLabel(Console.Out, "RUN", ConsoleColor.Cyan);
            Console.Out.Write(' ');
            WriteColored(Console.Out, description, ConsoleColor.White);
            Console.Out.WriteLine();
            Console.Out.Write("      ");
            WriteColored(Console.Out, commandText, ConsoleColor.DarkCyan);
            Console.Out.WriteLine();
        }

        return new ConsoleActivity(description, enableSpinner);
    }

    public static void WriteWarning(string message)
    {
        WriteStatusLine(Console.Error, "WARN", message, ConsoleColor.Yellow);
    }

    public static void WriteError(string message)
    {
        WriteStatusLine(Console.Error, "FAIL", message, ConsoleColor.Red);
    }

    public static void WriteInfo(string message)
    {
        WriteStatusLine(Console.Out, "INFO", message, ConsoleColor.Blue);
    }

    public static void WriteSuccess(string message)
    {
        WriteStatusLine(Console.Out, "OK", message, ConsoleColor.Green);
    }

    public static void WriteCapturedOutput(DotnetCommandCaptureResult result, bool startOnNewLine = false)
    {
        if (startOnNewLine
            && (!string.IsNullOrWhiteSpace(result.StandardOutput) || !string.IsNullOrWhiteSpace(result.StandardError)))
        {
            lock (Sync)
            {
                Console.Out.WriteLine();
            }
        }

        var state = new RenderState();
        RenderBlock(result.StandardOutput, isErrorStream: false, state);
        RenderBlock(result.StandardError, isErrorStream: true, state);
    }

    public static void WriteCommandSummary(int exitCode, TimeSpan elapsed)
    {
        var rounded = elapsed.TotalSeconds < 1
            ? $"{elapsed.TotalMilliseconds:F0} ms"
            : $"{elapsed.TotalSeconds:F1} s";

        if (exitCode == 0)
        {
            WriteSuccess($"Command completed in {rounded}.");
            return;
        }

        WriteError($"Command failed with exit code {exitCode} after {rounded}.");
    }

    internal static bool LooksLikeMigrationId(string line)
    {
        if (line.Length < 16)
        {
            return false;
        }

        for (var index = 0; index < 14; index++)
        {
            if (!char.IsDigit(line[index]))
            {
                return false;
            }
        }

        return line[14] == '_';
    }

    internal static string FormatArguments(IReadOnlyList<string> arguments)
    {
        return string.Join(' ', arguments.Select(QuoteArgument));
    }

    private static void RenderBlock(string content, bool isErrorStream, RenderState state)
    {
        if (string.IsNullOrWhiteSpace(content))
        {
            return;
        }

        using var reader = new StringReader(content);
        string? line;

        while ((line = reader.ReadLine()) is not null)
        {
            var kind = ClassifyLine(line, isErrorStream);
            RenderLine(line, kind, state);
        }
    }

    private static void RenderLine(string line, ConsoleLineKind kind, RenderState state)
    {
        if (kind == ConsoleLineKind.Blank)
        {
            if (state.HasContent && state.PreviousKind != ConsoleLineKind.Blank)
            {
                lock (Sync)
                {
                    Console.Out.WriteLine();
                }
            }

            state.PreviousKind = ConsoleLineKind.Blank;
            return;
        }

        if (kind == ConsoleLineKind.Result && state.HasContent && state.PreviousKind is not ConsoleLineKind.Blank and not ConsoleLineKind.Result)
        {
            lock (Sync)
            {
                Console.Out.WriteLine();
            }
        }

        var writer = kind == ConsoleLineKind.Error || kind == ConsoleLineKind.Warning
            ? Console.Error
            : Console.Out;

        var color = kind switch
        {
            ConsoleLineKind.Success => ConsoleColor.Green,
            ConsoleLineKind.Warning => ConsoleColor.Yellow,
            ConsoleLineKind.Error => ConsoleColor.Red,
            ConsoleLineKind.Verbose => ConsoleColor.DarkGray,
            ConsoleLineKind.Result => ConsoleColor.Green,
            ConsoleLineKind.Info => ConsoleColor.Blue,
            _ => (ConsoleColor?)null
        };

        lock (Sync)
        {
            WriteColored(writer, line, color);
            writer.WriteLine();
        }

        state.HasContent = true;
        state.PreviousKind = kind;
    }

    private static ConsoleLineKind ClassifyLine(string line, bool isErrorStream)
    {
        var trimmed = line.Trim();
        if (trimmed.Length == 0)
        {
            return ConsoleLineKind.Blank;
        }

        if (LooksLikeMigrationId(trimmed)
            || trimmed.StartsWith("Applying migration", StringComparison.OrdinalIgnoreCase)
            || trimmed.StartsWith("Done.", StringComparison.OrdinalIgnoreCase)
            || trimmed.Contains("No migrations were found", StringComparison.OrdinalIgnoreCase))
        {
            return ConsoleLineKind.Result;
        }

        if (trimmed.StartsWith("Build succeeded", StringComparison.OrdinalIgnoreCase)
            || trimmed.StartsWith("Build completed", StringComparison.OrdinalIgnoreCase))
        {
            return ConsoleLineKind.Success;
        }

        if (trimmed.StartsWith("Build started", StringComparison.OrdinalIgnoreCase)
            || trimmed.StartsWith("Determining projects to restore", StringComparison.OrdinalIgnoreCase))
        {
            return ConsoleLineKind.Info;
        }

        if (trimmed.StartsWith("warn:", StringComparison.OrdinalIgnoreCase)
            || trimmed.StartsWith("warning", StringComparison.OrdinalIgnoreCase))
        {
            return ConsoleLineKind.Warning;
        }

        if (isErrorStream
            || trimmed.StartsWith("fail:", StringComparison.OrdinalIgnoreCase)
            || trimmed.StartsWith("error", StringComparison.OrdinalIgnoreCase)
            || trimmed.Contains("Unhandled exception", StringComparison.OrdinalIgnoreCase))
        {
            return ConsoleLineKind.Error;
        }

        if (trimmed.StartsWith("info:", StringComparison.OrdinalIgnoreCase)
            || trimmed.StartsWith("dbug:", StringComparison.OrdinalIgnoreCase)
            || trimmed.StartsWith("trce:", StringComparison.OrdinalIgnoreCase)
            || trimmed.StartsWith("Executed DbCommand", StringComparison.OrdinalIgnoreCase)
            || trimmed.StartsWith("SELECT ", StringComparison.OrdinalIgnoreCase)
            || trimmed.StartsWith("FROM ", StringComparison.OrdinalIgnoreCase)
            || trimmed.StartsWith("ORDER BY ", StringComparison.OrdinalIgnoreCase)
            || trimmed.StartsWith("WHERE ", StringComparison.OrdinalIgnoreCase)
            || line.StartsWith("      ", StringComparison.Ordinal))
        {
            return ConsoleLineKind.Verbose;
        }

        return ConsoleLineKind.Normal;
    }

    private static string DescribeCommand(IReadOnlyList<string> arguments, string executable)
    {
        if (arguments.Count == 0)
        {
            return $"Running {executable}";
        }

        if (string.Equals(arguments[0], "ef", StringComparison.OrdinalIgnoreCase) && arguments.Count >= 3)
        {
            return $"Running EF {arguments[1]} {arguments[2]}";
        }

        if (arguments.Count >= 2)
        {
            return $"Running {executable} {arguments[0]} {arguments[1]}";
        }

        return $"Running {executable} {arguments[0]}";
    }

    private static void WriteStatusLine(TextWriter writer, string label, string message, ConsoleColor color)
    {
        lock (Sync)
        {
            WriteBlankLineIfInteractive();
            WriteLabel(writer, label, color);
            writer.Write(' ');
            WriteColored(writer, message, ConsoleColor.White);
            writer.WriteLine();
        }
    }

    private static void WriteBlankLineIfInteractive()
    {
        if (!Console.IsOutputRedirected)
        {
            Console.Out.WriteLine();
        }
    }

    private static void WriteLabel(TextWriter writer, string label, ConsoleColor color)
    {
        WriteColored(writer, $"[{label}]", color);
    }

    private static void WriteColored(TextWriter writer, string text, ConsoleColor? color)
    {
        if (!color.HasValue || !CanUseColors())
        {
            writer.Write(text);
            return;
        }

        var previousColor = Console.ForegroundColor;
        Console.ForegroundColor = color.Value;

        try
        {
            writer.Write(text);
        }
        finally
        {
            Console.ForegroundColor = previousColor;
        }
    }

    private static bool CanUseColors()
    {
        return !Console.IsOutputRedirected && !Console.IsErrorRedirected;
    }

    private static string QuoteArgument(string argument)
    {
        return argument.Any(char.IsWhiteSpace)
            ? $"\"{argument.Replace("\"", "\\\"")}\""
            : argument;
    }

    private enum ConsoleLineKind
    {
        Blank,
        Normal,
        Info,
        Success,
        Warning,
        Error,
        Verbose,
        Result
    }

    private sealed class RenderState
    {
        public bool HasContent { get; set; }

        public ConsoleLineKind PreviousKind { get; set; }
    }

    internal sealed class ConsoleActivity : IDisposable
    {
        private static readonly char[] Frames = ['|', '/', '-', '\\'];

        private readonly CancellationTokenSource _cancellationTokenSource = new();
        private readonly Stopwatch _stopwatch = Stopwatch.StartNew();
        private readonly Task? _spinnerTask;
        private readonly string _label;
        private readonly bool _enabled;
        private int _lastFrameLength;
        private int _disposed;

        public ConsoleActivity(string label, bool enableSpinner)
        {
            _label = label;
            _enabled = enableSpinner && CanAnimate();

            if (_enabled)
            {
                _spinnerTask = Task.Run(SpinAsync);
            }
        }

        public TimeSpan Elapsed => _stopwatch.Elapsed;

        public bool IsAnimated => _enabled;

        public void Stop()
        {
            Dispose();
        }

        public void Dispose()
        {
            if (Interlocked.Exchange(ref _disposed, 1) != 0)
            {
                return;
            }

            _stopwatch.Stop();

            if (!_enabled)
            {
                return;
            }

            _cancellationTokenSource.Cancel();

            try
            {
                _spinnerTask?.GetAwaiter().GetResult();
            }
            catch (OperationCanceledException)
            {
            }

            lock (Sync)
            {
                var clear = new string(' ', _lastFrameLength);
                Console.Out.Write('\r');
                Console.Out.Write(clear);
                Console.Out.Write('\r');
            }
        }

        private async Task SpinAsync()
        {
            var frameIndex = 0;

            while (!_cancellationTokenSource.Token.IsCancellationRequested)
            {
                var elapsedText = _stopwatch.Elapsed.TotalSeconds < 1
                    ? $"{_stopwatch.Elapsed.TotalMilliseconds:F0} ms"
                    : $"{_stopwatch.Elapsed.TotalSeconds:F1} s";
                var frameText = $"[{Frames[frameIndex++ % Frames.Length]}] {_label}  {elapsedText}";

                lock (Sync)
                {
                    _lastFrameLength = frameText.Length;
                    WriteColored(Console.Out, "\r" + frameText, ConsoleColor.DarkGray);
                    Console.Out.Flush();
                }

                try
                {
                    await Task.Delay(90, _cancellationTokenSource.Token);
                }
                catch (OperationCanceledException)
                {
                    break;
                }
            }
        }

        private static bool CanAnimate()
        {
            return !Console.IsOutputRedirected
                && !Console.IsErrorRedirected
                && Console.Out is not StringWriter
                && Console.Error is not StringWriter;
        }
    }
}