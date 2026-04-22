using EfCoreMigrationsHelper.Tool;

using var cancellationTokenSource = new CancellationTokenSource();

ConsoleCancelEventHandler handler = (_, eventArgs) =>
{
	eventArgs.Cancel = true;
	cancellationTokenSource.Cancel();
};

Console.CancelKeyPress += handler;

try
{
	return await new EfMigrationToolApp().RunAsync(args, cancellationTokenSource.Token);
}
catch (OperationCanceledException) when (cancellationTokenSource.IsCancellationRequested)
{
	return 130;
}
finally
{
	Console.CancelKeyPress -= handler;
}
