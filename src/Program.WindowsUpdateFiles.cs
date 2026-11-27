using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Threading;

namespace Clipman
{
    internal static partial class Program
    {
        private static readonly string[] WindowsUpdateRootFiles =
        {
            "LICENSE.txt", "Manual.html", "sqlite3.dll"
        };

        private static Version InstalledUpdateVersion(string executable)
        {
            CheckUpdatePath(executable, false);
            var file = FileVersionInfo.GetVersionInfo(executable);
            if (string.IsNullOrWhiteSpace(file.FileVersion))
            {
                throw new InvalidDataException("Could not read the Windows Clipman executable version.");
            }
            return new Version(file.FileMajorPart, file.FileMinorPart, file.FileBuildPart);
        }

        internal static void InstallWindowsUpdate(string stage, string target, Version previousVersion)
        {
            CheckUpdatePath(target, true);
            var sounds = Path.Combine(target, "sounds");
            CheckUpdatePath(sounds, true);

            var files = WindowsUpdateFiles(stage);
            foreach (var relative in files)
            {
                CheckUpdatePath(Path.Combine(target, relative), false);
            }

            var lockPath = Path.Combine(target, ".clipman-update.lock");
            using (new FileStream(lockPath, FileMode.CreateNew, FileAccess.ReadWrite, FileShare.None, 1, FileOptions.DeleteOnClose))
            {
                if (InstalledUpdateVersion(Path.Combine(target, "clipman.exe")) != previousVersion)
                {
                    throw new InvalidDataException("Clipman changed while the update was being prepared.");
                }
                ReplaceWindowsUpdateFiles(stage, target, sounds, files);
            }
        }

        private static List<string> WindowsUpdateFiles(string stage)
        {
            var rootNames = WindowsUpdateRootFiles.Concat(new[] { "clipman.exe" });
            foreach (var name in rootNames)
            {
                if (!File.Exists(Path.Combine(stage, name))) throw new InvalidDataException("The Windows update is missing " + name + ".");
            }
            if (Directory.EnumerateFileSystemEntries(stage).Select(Path.GetFileName)
                .Except(rootNames.Concat(new[] { "sounds" }), StringComparer.OrdinalIgnoreCase).Any())
            {
                throw new InvalidDataException("The Windows update contains unexpected files or folders.");
            }

            var stagedSounds = Path.Combine(stage, "sounds");
            var files = WindowsUpdateRootFiles.ToList();
            if (Directory.Exists(stagedSounds))
            {
                foreach (var path in Directory.EnumerateFileSystemEntries(stagedSounds))
                {
                    if (!File.Exists(path) || !Path.GetExtension(path).Equals(".wav", StringComparison.OrdinalIgnoreCase))
                    {
                        throw new InvalidDataException("The Windows update contains unexpected content in its sounds folder.");
                    }
                    files.Add(Path.Combine("sounds", Path.GetFileName(path)));
                }
            }
            else if (File.Exists(stagedSounds))
            {
                throw new InvalidDataException("The Windows update sounds path must be a folder.");
            }
            // Replace the executable last so a failed resource replacement leaves the old executable in place.
            files.Add("clipman.exe");
            return files;
        }

        private static void ReplaceWindowsUpdateFiles(string stage, string target, string sounds, List<string> files)
        {
            // File.Replace needs the incoming file, destination and rollback file on the same volume.
            var work = Path.Combine(target, ".clipman-update-" + Guid.NewGuid().ToString("N"));
            var createdFiles = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
            var createdSounds = false;
            var keepRollback = false;
            Directory.CreateDirectory(work);
            try
            {
                for (var index = 0; index < files.Count; index++)
                {
                    File.Copy(Path.Combine(stage, files[index]), Path.Combine(work, index + ".new"));
                }
                if (!Directory.Exists(sounds) && files.Any(relative => Path.GetDirectoryName(relative) == "sounds"))
                {
                    Directory.CreateDirectory(sounds);
                    createdSounds = true;
                }

                for (var index = 0; index < files.Count; index++)
                {
                    var destination = Path.Combine(target, files[index]);
                    var incoming = Path.Combine(work, index + ".new");
                    var backup = Path.Combine(work, index + ".bak");
                    if (File.Exists(destination))
                    {
                        ReplaceUpdateFile(incoming, destination, backup);
                    }
                    else
                    {
                        File.Move(incoming, destination);
                        createdFiles.Add(destination);
                    }
                }
            }
            catch (Exception installError)
            {
                var failures = new List<Exception> { installError };
                for (var index = files.Count - 1; index >= 0; index--)
                {
                    var destination = Path.Combine(target, files[index]);
                    var backup = Path.Combine(work, index + ".bak");
                    try
                    {
                        if (File.Exists(backup))
                        {
                            if (File.Exists(destination)) ReplaceUpdateFile(backup, destination, null);
                            else File.Move(backup, destination);
                        }
                        else if (createdFiles.Contains(destination))
                        {
                            File.Delete(destination);
                        }
                    }
                    catch (Exception rollbackError)
                    {
                        failures.Add(rollbackError);
                    }
                }
                if (createdSounds) RemoveEmptyDirectory(sounds);
                keepRollback = failures.Count > 1;
                if (keepRollback) throw new UpdateRollbackException(work, new AggregateException(failures));
                throw;
            }
            finally
            {
                if (!keepRollback) TryDeleteDirectory(work);
            }
        }

        private static void ReplaceUpdateFile(string incoming, string destination, string backup)
        {
            for (var attempt = 0; ; attempt++)
            {
                try
                {
                    File.Replace(incoming, destination, backup);
                    return;
                }
                catch (IOException error)
                {
                    var code = error.HResult & 65535;
                    if (attempt == 9 || (code != 32 && code != 33)) throw;
                    Thread.Sleep(250);
                }
            }
        }

        private static void CheckUpdatePath(string path, bool directory)
        {
            FileAttributes attributes;
            try { attributes = File.GetAttributes(path); }
            catch (FileNotFoundException) { return; }
            catch (DirectoryNotFoundException) { return; }
            if ((attributes & FileAttributes.ReparsePoint) != 0 || ((attributes & FileAttributes.Directory) != 0) != directory)
            {
                throw new IOException("The Windows update cannot replace " + path + " safely.");
            }
        }

        private sealed class UpdateRollbackException : IOException
        {
            internal UpdateRollbackException(string rollback, Exception error)
                : base("Clipman could not restore every file. Recovery files are in " + rollback + ".", error)
            {
            }
        }
    }
}
