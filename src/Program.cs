using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Reflection;
using System.Security.Cryptography;
using System.Threading;
using System.Windows.Forms;

namespace Clipman
{
    internal static partial class Program
    {
        public const string MutexName = "Local\\ClipmanPortableSingleInstance";
        public const string CloseEventName = "Local\\ClipmanCloseRequest";
        public const string ShowEventName = "Local\\ClipmanShowHistoryRequest";
        public const string PauseEventName = "Local\\ClipmanPauseRequest";
        public const string ResumeEventName = "Local\\ClipmanResumeRequest";
        public const string ToggleEventName = "Local\\ClipmanToggleRequest";
        private static readonly HashSet<string> SupportedTextExtensions = new HashSet<string>(StringComparer.OrdinalIgnoreCase)
        {
            ".txt", ".log", ".md", ".markdown",
            ".csv", ".tsv",
            ".json", ".xml", ".html", ".htm",
            ".css", ".js", ".ts",
            ".ps1", ".cmd", ".bat",
            ".ini", ".cfg", ".conf", ".yaml", ".yml",
            ".cs", ".vb", ".py", ".psm1", ".psd1",
            ".ahk", ".reg", ".rtf"
        };

        [STAThread]
        private static void Main(string[] args)
        {
            if (args.Length > 0 && string.Equals(args[0], "--apply-update", StringComparison.OrdinalIgnoreCase))
            {
                ApplyUpdateFromCommandLine(args);
                return;
            }

            if (args.Length > 0 && string.Equals(args[0], "--wait-restart", StringComparison.OrdinalIgnoreCase))
            {
                WaitRestartFromCommandLine(args);
                return;
            }

            if (args.Length > 0 && string.Equals(args[0], "--close", StringComparison.OrdinalIgnoreCase))
            {
                SignalEvent(CloseEventName);
                return;
            }

            if (args.Length > 0 && string.Equals(args[0], "--show", StringComparison.OrdinalIgnoreCase))
            {
                SignalEvent(ShowEventName);
                return;
            }

            if (args.Length > 0 && string.Equals(args[0], "--pause", StringComparison.OrdinalIgnoreCase))
            {
                SignalEvent(PauseEventName);
                return;
            }

            if (args.Length > 0 && string.Equals(args[0], "--resume", StringComparison.OrdinalIgnoreCase))
            {
                SignalEvent(ResumeEventName);
                return;
            }

            if (args.Length > 0 && string.Equals(args[0], "--toggle", StringComparison.OrdinalIgnoreCase))
            {
                SignalEvent(ToggleEventName);
                return;
            }

            if (args.Length > 1 && string.Equals(args[0], "--add", StringComparison.OrdinalIgnoreCase))
            {
                AddText(string.Join(" ", args.Skip(1).ToArray()));
                SignalEvent(ShowEventName);
                return;
            }

            if (args.Length > 1 && string.Equals(args[0], "--export", StringComparison.OrdinalIgnoreCase))
            {
                ExportDatabase(args[1]);
                return;
            }

            if (args.Length > 1 && string.Equals(args[0], "--import", StringComparison.OrdinalIgnoreCase))
            {
                ImportDatabase(args[1], false);
                SignalEvent(ShowEventName);
                return;
            }

            if (args.Length > 1 && string.Equals(args[0], "--import-replace", StringComparison.OrdinalIgnoreCase))
            {
                var silent = args.Any(arg => string.Equals(arg, "--yes", StringComparison.OrdinalIgnoreCase));
                if (ImportDatabase(args[1], true, silent))
                {
                    SignalEvent(ShowEventName);
                }
                return;
            }

            if (HasImportFiles(args))
            {
                if (ImportFiles(args))
                {
                    SignalEvent(ShowEventName);
                }
                return;
            }

            Mutex mutex;
            if (!AcquireSingleInstanceMutex(out mutex))
            {
                return;
            }

            using (mutex)
            {
                var appDirectory = AppDomain.CurrentDomain.BaseDirectory.TrimEnd(Path.DirectorySeparatorChar);
                InstanceStateStore.PublishCurrent(appDirectory);
                CleanupObsoleteFactorySoundBackups(appDirectory);
                try
                {
                    RunApplication();
                }
                finally
                {
                    InstanceStateStore.ClearIfCurrent(appDirectory);
                }

                GC.KeepAlive(mutex);
            }
        }

        private static bool AcquireSingleInstanceMutex(out Mutex mutex)
        {
            mutex = null;
            if (TryAcquireMutex(out mutex))
            {
                return true;
            }

            var appDirectory = AppDomain.CurrentDomain.BaseDirectory.TrimEnd(Path.DirectorySeparatorChar);
            if (InstanceStateStore.IsSameRunningFolder(appDirectory))
            {
                SignalEvent(ShowEventName);
                return false;
            }

            SignalEvent(CloseEventName);
            WaitForPreviousInstanceToExit();
            ResetEvent(CloseEventName);

            var deadline = DateTime.UtcNow.AddSeconds(15);
            while (DateTime.UtcNow < deadline)
            {
                if (TryAcquireMutex(out mutex))
                {
                    return true;
                }

                Thread.Sleep(250);
            }

            SignalEvent(ShowEventName);
            return false;
        }

        private static bool TryAcquireMutex(out Mutex mutex)
        {
            bool created;
            mutex = new Mutex(true, MutexName, out created);
            if (created)
            {
                return true;
            }

            mutex.Dispose();
            mutex = null;
            return false;
        }

        private static void WaitForPreviousInstanceToExit()
        {
            var processId = InstanceStateStore.RunningProcessId();
            if (processId > 0)
            {
                try
                {
                    using (var process = Process.GetProcessById(processId))
                    {
                        if (process.WaitForExit(10000))
                        {
                            return;
                        }
                    }
                }
                catch
                {
                    return;
                }
            }

            var current = Process.GetCurrentProcess();
            var processName = Path.GetFileNameWithoutExtension(Application.ExecutablePath);
            foreach (var process in Process.GetProcessesByName(processName).Where(p => p.Id != current.Id).ToList())
            {
                using (process)
                {
                    try
                    {
                        process.WaitForExit(2000);
                    }
                    catch
                    {
                    }
                }
            }
        }

        private static void RunApplication()
        {
            Application.EnableVisualStyles();
            Application.SetCompatibleTextRenderingDefault(false);

            try
            {
                using (var app = new ClipmanApplicationContext())
                {
                    Application.Run(app);
                }
            }
            catch (OperationCanceledException)
            {
                WriteStartupLog("Startup cancelled by user.", null);
            }
            catch (Exception ex)
            {
                WriteStartupLog("Startup failed.", ex);
                MessageBox.Show(
                    "Clipman could not start.\r\n\r\n" + ex.Message + "\r\n\r\nDetails were written to Logs\\Startup.log beside clipman.exe.",
                    "Clipman startup failed",
                    MessageBoxButtons.OK,
                    MessageBoxIcon.Error);
            }
        }

        private static void WriteStartupLog(string message, Exception exception)
        {
            try
            {
                var appDirectory = AppDomain.CurrentDomain.BaseDirectory.TrimEnd(Path.DirectorySeparatorChar);
                var logDirectory = Path.Combine(appDirectory, "Logs");
                Directory.CreateDirectory(logDirectory);
                var path = Path.Combine(logDirectory, "Startup.log");
                using (var writer = new StreamWriter(path, true))
                {
                    writer.WriteLine("[" + DateTime.Now.ToString("yyyy-MM-dd HH:mm:ss") + "] " + message);
                    writer.WriteLine("App: " + Assembly.GetExecutingAssembly().Location);
                    if (exception != null)
                    {
                        writer.WriteLine(exception);
                    }
                    writer.WriteLine();
                }
            }
            catch
            {
            }
        }

        private static void SignalEvent(string name)
        {
            try
            {
                bool created;
                using (var ev = new EventWaitHandle(false, EventResetMode.ManualReset, name, out created))
                {
                    ev.Set();
                }
            }
            catch
            {
            }
        }

        private static void ResetEvent(string name)
        {
            try
            {
                bool created;
                using (var ev = new EventWaitHandle(false, EventResetMode.ManualReset, name, out created))
                {
                    ev.Reset();
                }
            }
            catch
            {
            }
        }

        private static bool HasImportFiles(string[] args)
        {
            return args != null && args.Any(arg => !IsSwitch(arg) && File.Exists(arg));
        }

        private static bool ImportFiles(string[] args)
        {
            var appDirectory = AppDomain.CurrentDomain.BaseDirectory.TrimEnd(Path.DirectorySeparatorChar);
            var settingsStore = new SettingsStore(appDirectory);
            var settings = settingsStore.Load();
            var imported = false;
            using (var store = new ClipStore(settings.DatabasePath, settingsStore.DatabasePassword(settings)))
            {
                foreach (var file in args.Where(arg => !IsSwitch(arg) && File.Exists(arg)))
                {
                    imported = ImportFile(store, file, settings) || imported;
                }
            }

            return imported && settings.ShowHistoryAfterSendTo;
        }

        private static bool ImportFile(ClipStore store, string file, AppSettings settings)
        {
            var extension = Path.GetExtension(file);
            if (!SupportedTextExtensions.Contains(extension))
            {
                return false;
            }

            string text;
            try
            {
                text = File.ReadAllText(file);
            }
            catch
            {
                return false;
            }

            if (!string.IsNullOrEmpty(text))
            {
                if (settings.AutoRemoveUrlTracking)
                {
                    text = UrlTrackingCleaner.CleanText(text);
                }
                var group = settings.AutoGroupByApp ? "Send To" : string.Empty;
                store.AddText(text, settings.DuplicateMode, settings.MaxHistoryEntries, settings.MaxHistoryDays, group);
                return true;
            }

            return false;
        }

        private static void AddText(string text)
        {
            if (string.IsNullOrEmpty(text)) return;
            var appDirectory = AppDomain.CurrentDomain.BaseDirectory.TrimEnd(Path.DirectorySeparatorChar);
            var settingsStore = new SettingsStore(appDirectory);
            var settings = settingsStore.Load();
            using (var store = new ClipStore(settings.DatabasePath, settingsStore.DatabasePassword(settings)))
            {
                if (settings.AutoRemoveUrlTracking)
                {
                    text = UrlTrackingCleaner.CleanText(text);
                }
                store.AddText(text, settings.DuplicateMode, settings.MaxHistoryEntries, settings.MaxHistoryDays);
            }
        }

        private static void ExportDatabase(string targetPath)
        {
            if (string.IsNullOrWhiteSpace(targetPath)) return;
            if (File.Exists(targetPath)) return;
            var dir = Path.GetDirectoryName(Path.GetFullPath(targetPath));
            if (!string.IsNullOrEmpty(dir))
            {
                Directory.CreateDirectory(dir);
            }

            var appDirectory = AppDomain.CurrentDomain.BaseDirectory.TrimEnd(Path.DirectorySeparatorChar);
            var settingsStore = new SettingsStore(appDirectory);
            var settings = settingsStore.Load();
            using (var store = new ClipStore(settings.DatabasePath, settingsStore.DatabasePassword(settings)))
            {
                store.ExportToFile(targetPath);
            }
        }

        private static bool ImportDatabase(string sourcePath, bool replace)
        {
            return ImportDatabase(sourcePath, replace, false);
        }

        private static bool ImportDatabase(string sourcePath, bool replace, bool silent)
        {
            if (string.IsNullOrWhiteSpace(sourcePath) || !File.Exists(sourcePath)) return false;
            var appDirectory = AppDomain.CurrentDomain.BaseDirectory.TrimEnd(Path.DirectorySeparatorChar);
            var settingsStore = new SettingsStore(appDirectory);
            var settings = settingsStore.Load();
            if (replace)
            {
                if (!silent && !ConfirmReplace(sourcePath))
                {
                    return false;
                }
                BackupDatabase(settings.DatabasePath);
            }
            using (var store = new ClipStore(settings.DatabasePath, settingsStore.DatabasePassword(settings)))
            {
                store.ImportFromFile(sourcePath, replace);
            }
            return true;
        }

        private static bool ConfirmReplace(string sourcePath)
        {
            var message =
                "Replace Clipman history?\r\n\r\n" +
                "This will replace the current clipboard history with:\r\n" +
                sourcePath + "\r\n\r\n" +
                "A timestamped backup of the current database will be created first.";
            return MessageBox.Show(message, "Clipman Import Replace", MessageBoxButtons.YesNo, MessageBoxIcon.Warning, MessageBoxDefaultButton.Button2) == DialogResult.Yes;
        }

        private static void BackupDatabase(string databasePath)
        {
            if (string.IsNullOrWhiteSpace(databasePath) || !File.Exists(databasePath)) return;
            var directory = Path.GetDirectoryName(databasePath);
            var name = Path.GetFileNameWithoutExtension(databasePath);
            var extension = Path.GetExtension(databasePath);
            if (string.IsNullOrEmpty(directory)) directory = AppDomain.CurrentDomain.BaseDirectory;
            if (string.IsNullOrEmpty(name)) name = "clipman-history";
            if (string.IsNullOrEmpty(extension)) extension = ".json";
            var stamp = DateTime.Now.ToString("yyyyMMdd-HHmmss");
            var backupPath = Path.Combine(directory, name + ".before-import-replace-" + stamp + extension);
            File.Copy(databasePath, backupPath, false);
        }

        private static bool IsSwitch(string arg)
        {
            return !string.IsNullOrEmpty(arg) && (arg.StartsWith("-", StringComparison.Ordinal) || arg.StartsWith("/", StringComparison.Ordinal));
        }

        private static bool TryGetOptionValue(string[] args, string optionName, out string value)
        {
            value = string.Empty;
            if (args == null || string.IsNullOrWhiteSpace(optionName)) return false;
            for (var i = 0; i < args.Length - 1; i++)
            {
                if (string.Equals(args[i], optionName, StringComparison.OrdinalIgnoreCase))
                {
                    value = args[i + 1];
                    return true;
                }
            }

            return false;
        }

        private static void WaitRestartFromCommandLine(string[] args)
        {
            string exePath;
            string workingDirectory;
            string statePath;
            string buildText;
            string pidText;
            string timeoutText;
            TryGetOptionValue(args, "--restart-exe", out exePath);
            TryGetOptionValue(args, "--restart-working-dir", out workingDirectory);
            TryGetOptionValue(args, "--restart-state", out statePath);
            TryGetOptionValue(args, "--restart-current-build", out buildText);
            TryGetOptionValue(args, "--restart-wait-pid", out pidText);
            TryGetOptionValue(args, "--restart-timeout-ms", out timeoutText);

            long currentBuild;
            int processId;
            int timeoutMs;
            long.TryParse(buildText, out currentBuild);
            int.TryParse(pidText, out processId);
            if (!int.TryParse(timeoutText, out timeoutMs) || timeoutMs <= 0) timeoutMs = 120000;

            if (processId > 0)
            {
                try
                {
                    using (var process = Process.GetProcessById(processId))
                    {
                        process.WaitForExit(30000);
                    }
                }
                catch
                {
                }
            }

            var start = Environment.TickCount;
            while (unchecked(Environment.TickCount - start) < timeoutMs)
            {
                try
                {
                    if (File.Exists(exePath) && File.Exists(statePath))
                    {
                        var state = JsonUtil.Load<SharedUpdateState>(statePath);
                        if (state != null &&
                            state.BuildStampUtcMs > currentBuild &&
                            string.Equals(HashFileForRestart(exePath), state.ExeSha256, StringComparison.OrdinalIgnoreCase))
                        {
                            Process.Start(new ProcessStartInfo
                            {
                                FileName = exePath,
                                WorkingDirectory = Directory.Exists(workingDirectory) ? workingDirectory : Path.GetDirectoryName(exePath),
                                UseShellExecute = true
                            });
                            return;
                        }
                    }
                }
                catch
                {
                }

                Thread.Sleep(1500);
            }
        }

        private static string HashFileForRestart(string path)
        {
            using (var sha = SHA256.Create())
            using (var stream = File.Open(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete))
            {
                return BitConverter.ToString(sha.ComputeHash(stream)).Replace("-", string.Empty).ToLowerInvariant();
            }
        }
    }

    internal static class SendToInstaller
    {
        private const string SendToShortcutName = "&Clipman - add text to history.lnk";
        private const string OldSendToShortcutName = "Clipman - add text to history.lnk";

        public static void SetInstalled(bool installed)
        {
            var path = GetSendToPath();
            if (installed)
            {
                DeleteShortcutIfExists(OldSendToShortcutName);
                var shellType = Type.GetTypeFromProgID("WScript.Shell");
                if (shellType == null)
                {
                    throw new InvalidOperationException("WScript.Shell is not available.");
                }

                var shell = Activator.CreateInstance(shellType);
                var shortcut = shellType.InvokeMember("CreateShortcut", BindingFlags.InvokeMethod, null, shell, new object[] { path });
                var shortcutType = shortcut.GetType();
                shortcutType.InvokeMember("TargetPath", BindingFlags.SetProperty, null, shortcut, new object[] { Application.ExecutablePath });
                shortcutType.InvokeMember("WorkingDirectory", BindingFlags.SetProperty, null, shortcut, new object[] { Application.StartupPath });
                shortcutType.InvokeMember("Description", BindingFlags.SetProperty, null, shortcut, new object[] { "Add text files to Clipman history" });
                shortcutType.InvokeMember("Save", BindingFlags.InvokeMethod, null, shortcut, null);
            }
            else if (File.Exists(path))
            {
                File.Delete(path);
                DeleteShortcutIfExists(OldSendToShortcutName);
            }
        }

        private static string GetSendToPath()
        {
            var sendToFolder = Environment.GetFolderPath(Environment.SpecialFolder.SendTo);
            if (string.IsNullOrWhiteSpace(sendToFolder))
            {
                throw new InvalidOperationException("The Windows Send To folder could not be found.");
            }

            Directory.CreateDirectory(sendToFolder);
            return Path.Combine(sendToFolder, SendToShortcutName);
        }

        private static void DeleteShortcutIfExists(string shortcutName)
        {
            var sendToFolder = Environment.GetFolderPath(Environment.SpecialFolder.SendTo);
            if (string.IsNullOrWhiteSpace(sendToFolder)) return;
            var path = Path.Combine(sendToFolder, shortcutName);
            if (File.Exists(path))
            {
                File.Delete(path);
            }
        }
    }
}
