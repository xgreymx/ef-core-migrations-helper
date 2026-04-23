using Xunit;

namespace EfCoreMigrationsHelper.Tool.Tests;

public sealed class EfMigrationToolAppTests
{
    [Fact]
    public void CreateEfArguments_for_add_creates_nested_directory_and_always_passes_output_dir()
    {
        var tempRoot = Path.Combine(Path.GetTempPath(), "efm-tests-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(tempRoot);

        try
        {
            var dbContextProjectDirectory = Path.Combine(tempRoot, "MyApp.Infrastructure");
            Directory.CreateDirectory(dbContextProjectDirectory);

            var dbContextProject = Path.Combine(dbContextProjectDirectory, "MyApp.Infrastructure.csproj");
            var startupProject = Path.Combine(tempRoot, "MyApp.Api.csproj");
            File.WriteAllText(dbContextProject, "<Project />");
            File.WriteAllText(startupProject, "<Project />");

            var profile = new EfProfile
            {
                Name = "default",
                WorkingDirectory = tempRoot,
                DbContextProject = dbContextProject,
                StartupProject = startupProject,
                MigrationsDirectory = "Persistence/Migrations",
                UpdatedAt = DateTimeOffset.UtcNow
            };

            var app = new EfMigrationToolApp();
            var invocation = CommandLineParser.Parse(["add", "InitialCreate"]);

            var arguments = app.CreateEfArguments(profile, invocation);

            var outputDirectoryIndex = arguments.IndexOf("--output-dir");
            Assert.True(outputDirectoryIndex >= 0);
            Assert.Equal("Persistence/Migrations", arguments[outputDirectoryIndex + 1]);
            Assert.True(Directory.Exists(Path.Combine(dbContextProjectDirectory, "Persistence", "Migrations")));
        }
        finally
        {
            if (Directory.Exists(tempRoot))
            {
                Directory.Delete(tempRoot, recursive: true);
            }
        }
    }

    [Fact]
    public void ConfirmDestructive_uses_status_lines_for_reset_warning()
    {
        var originalOut = Console.Out;
        var originalError = Console.Error;
        var originalIn = Console.In;
        using var stdout = new StringWriter();
        using var stderr = new StringWriter();
        using var input = new StringReader("n" + Environment.NewLine);

        Console.SetOut(stdout);
        Console.SetError(stderr);
        Console.SetIn(input);

        try
        {
            var app = new EfMigrationToolApp();

            var shouldProceed = app.ConfirmDestructive(
                force: false,
                action: "Reset the database (drop + re-apply all migrations)",
                consequence: "The database will be dropped and recreated empty. All data will be lost.");

            Assert.False(shouldProceed);
        }
        finally
        {
            Console.SetOut(originalOut);
            Console.SetError(originalError);
            Console.SetIn(originalIn);
        }

        Assert.Contains("[WARN] DESTRUCTIVE ACTION: Reset the database (drop + re-apply all migrations)", stderr.ToString());
        Assert.Contains("[FAIL] The database will be dropped and recreated empty. All data will be lost.", stderr.ToString());
        Assert.Contains("[WARN] This cannot be undone automatically.", stderr.ToString());
    }
}