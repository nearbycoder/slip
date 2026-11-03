using Microsoft.UI.Dispatching;

namespace Slip.App.Services;

/// <summary>Marshals work onto the UI thread. Slip.Core raises its events on background threads.</summary>
public static class UiThread
{
    private static DispatcherQueue? _queue;

    public static void Initialize(DispatcherQueue queue) => _queue = queue;

    public static bool HasAccess => _queue?.HasThreadAccess ?? false;

    public static void Post(Action action)
    {
        if (_queue is null || _queue.HasThreadAccess) action();
        else _queue.TryEnqueue(() => action());
    }

    public static Task RunAsync(Func<Task> action) => RunAsync(async () =>
    {
        await action();
        return true;
    });

    public static Task<T> RunAsync<T>(Func<Task<T>> action)
    {
        if (_queue is null || _queue.HasThreadAccess) return action();
        var tcs = new TaskCompletionSource<T>(TaskCreationOptions.RunContinuationsAsynchronously);
        var queued = _queue.TryEnqueue(async () =>
        {
            try { tcs.TrySetResult(await action()); }
            catch (Exception e) { tcs.TrySetException(e); }
        });
        if (!queued) tcs.TrySetCanceled();
        return tcs.Task;
    }
}
