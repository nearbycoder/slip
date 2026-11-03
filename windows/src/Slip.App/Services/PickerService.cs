using Windows.Storage.Pickers;

namespace Slip.App.Services;

/// <summary>File/folder pickers. Desktop (unpackaged) apps must associate pickers with a window handle.</summary>
public static class PickerService
{
    private static IntPtr WindowHandle => WinRT.Interop.WindowNative.GetWindowHandle(App.MainWindow);

    public static async Task<IReadOnlyList<string>> PickFilesAsync()
    {
        var picker = new FileOpenPicker
        {
            ViewMode = PickerViewMode.List,
            SuggestedStartLocation = PickerLocationId.DocumentsLibrary,
        };
        picker.FileTypeFilter.Add("*");
        WinRT.Interop.InitializeWithWindow.Initialize(picker, WindowHandle);
        var files = await picker.PickMultipleFilesAsync();
        return files is null ? [] : files.Select(f => f.Path).Where(p => !string.IsNullOrEmpty(p)).ToList();
    }

    public static async Task<string?> PickFolderAsync()
    {
        var picker = new FolderPicker
        {
            ViewMode = PickerViewMode.List,
            SuggestedStartLocation = PickerLocationId.Downloads,
        };
        picker.FileTypeFilter.Add("*");
        WinRT.Interop.InitializeWithWindow.Initialize(picker, WindowHandle);
        var folder = await picker.PickSingleFolderAsync();
        return string.IsNullOrEmpty(folder?.Path) ? null : folder.Path;
    }
}
