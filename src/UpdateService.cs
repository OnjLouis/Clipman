using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Net;
using System.Web.Script.Serialization;
using System.Windows.Forms;

namespace Clipman
{
    internal static class UpdateService
    {
        public const string ProjectUrl = "https://github.com/OnjLouis/Clipman";

        private const string UserAgent = "Clipman updater";

        public static void CheckForUpdates(IWin32Window owner, string currentVersion, Action exitApp)
        {
            try
            {
                var releases = FetchReleases();
                var release = LatestVersionedRelease(releases) ?? FetchLatestRelease();
                var latestVersionText = release == null ? string.Empty : (release.TagName ?? string.Empty).Trim().TrimStart('v', 'V');
                Version current;
                Version remote;
                if (string.IsNullOrWhiteSpace(latestVersionText) ||
                    !Version.TryParse(currentVersion, out current) ||
                    !Version.TryParse(latestVersionText, out remote))
                {
                    MessageBox.Show(owner, "Could not read the latest Clipman release version.", "Check for updates", MessageBoxButtons.OK, MessageBoxIcon.Information);
                    return;
                }

                if (remote <= current)
                {
                    MessageBox.Show(owner, "Clipman is up to date. Current version: " + currentVersion + ".", "Check for updates", MessageBoxButtons.OK, MessageBoxIcon.Information);
                    return;
                }

                ShowUpdateAvailableDialog(owner, release, releases, current, remote, exitApp);
            }
            catch (WebException ex)
            {
                MessageBox.Show(owner, "Could not check for updates. GitHub releases may not exist yet, or the network request failed." + Environment.NewLine + Environment.NewLine + ex.Message, "Check for updates", MessageBoxButtons.OK, MessageBoxIcon.Information);
            }
            catch (Exception ex)
            {
                MessageBox.Show(owner, ex.Message, "Check for updates", MessageBoxButtons.OK, MessageBoxIcon.Error);
            }
        }

        public static void CheckForUpdatesAutomatic(IWin32Window owner, string currentVersion, Action exitApp, bool installSilently)
        {
            try
            {
                var releases = FetchReleases();
                var release = LatestVersionedRelease(releases) ?? FetchLatestRelease();
                var latestVersionText = release == null ? string.Empty : (release.TagName ?? string.Empty).Trim().TrimStart('v', 'V');
                Version current;
                Version remote;
                if (string.IsNullOrWhiteSpace(latestVersionText) ||
                    !Version.TryParse(currentVersion, out current) ||
                    !Version.TryParse(latestVersionText, out remote) ||
                    remote <= current)
                {
                    return;
                }

                if (installSilently)
                {
                    var zipAsset = FindPortableZipAsset(release);
                    if (zipAsset == null || string.IsNullOrWhiteSpace(zipAsset.BrowserDownloadUrl)) return;
                    StartSelfUpdate(owner, zipAsset.BrowserDownloadUrl, exitApp, true);
                    return;
                }

                ShowUpdateAvailableDialog(owner, release, releases, current, remote, exitApp);
            }
            catch
            {
            }
        }

        public static void ShowVersionHistory(IWin32Window owner, string currentVersion)
        {
            try
            {
                var releases = FetchReleases();
                var release = LatestVersionedRelease(releases) ?? FetchLatestRelease();
                var version = release == null ? currentVersion : (release.TagName ?? currentVersion).Trim().TrimStart('v', 'V');
                var releaseUrl = release == null || string.IsNullOrWhiteSpace(release.HtmlUrl) ? ProjectUrl + "/releases" : release.HtmlUrl;
                var notesText = FormatReleaseNotesForDialog(release == null ? string.Empty : release.Body, "No release notes were provided for this update.");

                using (var dialog = new Form())
                {
                    dialog.Text = "Version history - " + version;
                    dialog.StartPosition = FormStartPosition.CenterParent;
                    dialog.Width = 720;
                    dialog.Height = 520;
                    dialog.MinimizeBox = false;
                    dialog.MaximizeBox = false;
                    dialog.ShowIcon = false;
                    dialog.ShowInTaskbar = false;

                    var layout = new TableLayoutPanel
                    {
                        Dock = DockStyle.Fill,
                        ColumnCount = 1,
                        RowCount = 3,
                        Padding = new Padding(12)
                    };
                    layout.RowStyles.Add(new RowStyle(SizeType.AutoSize));
                    layout.RowStyles.Add(new RowStyle(SizeType.Percent, 100));
                    layout.RowStyles.Add(new RowStyle(SizeType.AutoSize));

                    layout.Controls.Add(new Label
                    {
                        AutoSize = true,
                        Dock = DockStyle.Top,
                        Text = "Latest release: " + version,
                        Padding = new Padding(0, 0, 0, 8)
                    }, 0, 0);

                    layout.Controls.Add(new TextBox
                    {
                        Dock = DockStyle.Fill,
                        Multiline = true,
                        ReadOnly = true,
                        ScrollBars = ScrollBars.Vertical,
                        Text = "Latest release: " + version + Environment.NewLine + Environment.NewLine + notesText,
                        AccessibleName = "Version history " + version
                    }, 0, 1);

                    var buttons = new FlowLayoutPanel
                    {
                        AutoSize = true,
                        Dock = DockStyle.Fill,
                        FlowDirection = FlowDirection.LeftToRight,
                        Padding = new Padding(0, 8, 0, 0)
                    };
                    var releaseButton = new Button { Text = "Open &release page", AutoSize = true };
                    releaseButton.Click += delegate { OpenUrl(releaseUrl); };
                    var allReleasesButton = new Button { Text = "Open &all releases", AutoSize = true };
                    allReleasesButton.Click += delegate { OpenUrl(ProjectUrl + "/releases"); };
                    var closeButton = new Button { Text = "&Close", DialogResult = DialogResult.OK, AutoSize = true };
                    buttons.Controls.Add(releaseButton);
                    buttons.Controls.Add(allReleasesButton);
                    buttons.Controls.Add(closeButton);

                    layout.Controls.Add(buttons, 0, 2);
                    dialog.Controls.Add(layout);
                    dialog.AcceptButton = closeButton;
                    dialog.CancelButton = closeButton;
                    dialog.ShowDialog(owner);
                }
            }
            catch (Exception ex)
            {
                MessageBox.Show(owner, "Could not check version history. GitHub releases may not exist yet, or the network request failed." + Environment.NewLine + Environment.NewLine + ex.Message, "Version history", MessageBoxButtons.OK, MessageBoxIcon.Information);
            }
        }

        public static void OpenProjectPage()
        {
            OpenUrl(ProjectUrl);
        }

        public static void OpenContactPage()
        {
            OpenUrl("https://onj.me/contact");
        }

        public static void OpenDonatePage()
        {
            OpenUrl("https://onj.me/donate");
        }

        private static void ShowUpdateAvailableDialog(IWin32Window owner, GitHubReleaseInfo release, IEnumerable<GitHubReleaseInfo> releases, Version current, Version remote, Action exitApp)
        {
            var latest = release == null ? remote.ToString() : (release.TagName ?? remote.ToString());
            var releaseUrl = release == null || string.IsNullOrWhiteSpace(release.HtmlUrl) ? ProjectUrl + "/releases" : release.HtmlUrl;
            var zipAsset = FindPortableZipAsset(release);
            var releaseNotes = BuildUpdateReleaseNotes(releases, current, remote);

            using (var dialog = new Form())
            {
                dialog.Text = "Update available";
                dialog.StartPosition = FormStartPosition.CenterParent;
                dialog.Width = 720;
                dialog.Height = 520;
                dialog.MinimizeBox = false;
                dialog.MaximizeBox = false;
                dialog.ShowIcon = false;
                dialog.ShowInTaskbar = false;

                var layout = new TableLayoutPanel
                {
                    Dock = DockStyle.Fill,
                    ColumnCount = 1,
                    RowCount = 3,
                    Padding = new Padding(12)
                };
                layout.RowStyles.Add(new RowStyle(SizeType.AutoSize));
                layout.RowStyles.Add(new RowStyle(SizeType.Percent, 100));
                layout.RowStyles.Add(new RowStyle(SizeType.AutoSize));

                var header = new Label
                {
                    AutoSize = true,
                    Dock = DockStyle.Top,
                    Text = "Clipman " + latest + " is available.",
                    Padding = new Padding(0, 0, 0, 8)
                };

                var notes = new TextBox
                {
                    Dock = DockStyle.Fill,
                    Multiline = true,
                    ReadOnly = true,
                    ScrollBars = ScrollBars.Vertical,
                    Text = releaseNotes,
                    AccessibleName = "Release notes"
                };

                var buttons = new FlowLayoutPanel
                {
                    AutoSize = true,
                    Dock = DockStyle.Fill,
                    FlowDirection = FlowDirection.LeftToRight,
                    Padding = new Padding(0, 8, 0, 0)
                };

                var laterButton = new Button { Text = "&Later", DialogResult = DialogResult.Cancel, AutoSize = true };
                var releaseButton = new Button { Text = "Open &release page", AutoSize = true };
                releaseButton.Click += delegate { OpenUrl(releaseUrl); };

                if (zipAsset != null && !string.IsNullOrWhiteSpace(zipAsset.BrowserDownloadUrl))
                {
                    var installButton = new Button { Text = "&Download and install", AutoSize = true };
                    installButton.Click += delegate
                    {
                        dialog.DialogResult = DialogResult.OK;
                        dialog.Close();
                        StartSelfUpdate(owner, zipAsset.BrowserDownloadUrl, exitApp, false);
                    };
                    buttons.Controls.Add(installButton);
                    dialog.AcceptButton = installButton;
                }

                buttons.Controls.Add(releaseButton);
                buttons.Controls.Add(laterButton);

                dialog.CancelButton = laterButton;
                layout.Controls.Add(header, 0, 0);
                layout.Controls.Add(notes, 0, 1);
                layout.Controls.Add(buttons, 0, 2);
                dialog.Controls.Add(layout);
                dialog.ShowDialog(owner);
            }
        }

        private static void StartSelfUpdate(IWin32Window owner, string zipUrl, Action exitApp, bool silent)
        {
            if (!silent &&
                MessageBox.Show(
                        owner,
                        "Clipman will close, download the update, replace the files in this folder, and restart. Your Settings folder will be kept." + Environment.NewLine + Environment.NewLine + "Do you want to continue?",
                        "Download and install",
                        MessageBoxButtons.YesNo,
                        MessageBoxIcon.Question,
                        MessageBoxDefaultButton.Button2) != DialogResult.Yes)
            {
                return;
            }

            try
            {
                var appDir = AppDomain.CurrentDomain.BaseDirectory.TrimEnd(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar);
                var exePath = Application.ExecutablePath;
                var updaterTempDir = GetUpdaterTempDirectory(appDir);
                var updaterRoot = Path.Combine(updaterTempDir, "ClipmanUpdater-" + Guid.NewGuid().ToString("N"));
                Directory.CreateDirectory(updaterRoot);
                var updaterExe = Path.Combine(updaterRoot, "Clipman Updater.exe");
                File.Copy(exePath, updaterExe, true);
                Process.Start(new ProcessStartInfo
                {
                    FileName = updaterExe,
                    Arguments =
                        "--apply-update" +
                        " --update-url " + CommandLineQuote(zipUrl) +
                        " --update-target " + CommandLineQuote(appDir) +
                        " --update-exe " + CommandLineQuote(exePath) +
                        " --update-temp " + CommandLineQuote(updaterTempDir) +
                        " --update-wait-pid " + Process.GetCurrentProcess().Id,
                    WorkingDirectory = updaterRoot,
                    UseShellExecute = false,
                    CreateNoWindow = true
                });
                if (exitApp != null) exitApp();
            }
            catch (Exception ex)
            {
                if (silent) return;
                MessageBox.Show(owner, ex.Message, "Could not start updater", MessageBoxButtons.OK, MessageBoxIcon.Error);
            }
        }

        private static GitHubReleaseInfo FetchLatestRelease()
        {
            using (var client = CreateGitHubClient())
            {
                var json = client.DownloadString(ApiBaseUrl() + "/releases/latest");
                return ParseRelease(json);
            }
        }

        private static List<GitHubReleaseInfo> FetchReleases()
        {
            using (var client = CreateGitHubClient())
            {
                var json = client.DownloadString(ApiBaseUrl() + "/releases?per_page=100");
                return ParseReleases(json);
            }
        }

        private static WebClient CreateGitHubClient()
        {
            NetworkSecurity.EnableModernTls();
            var client = new WebClient();
            client.Headers.Add("User-Agent", UserAgent);
            return client;
        }

        private static string ApiBaseUrl()
        {
            return ProjectUrl.Replace("https://github.com/", "https://api.github.com/repos/");
        }

        private static GitHubReleaseInfo LatestVersionedRelease(IEnumerable<GitHubReleaseInfo> releases)
        {
            return (releases ?? new List<GitHubReleaseInfo>())
                .Select(r => new { Release = r, Version = ReleaseVersion(r) })
                .Where(i => i.Version != null)
                .OrderByDescending(i => i.Version)
                .Select(i => i.Release)
                .FirstOrDefault();
        }

        private static Version ReleaseVersion(GitHubReleaseInfo release)
        {
            if (release == null || string.IsNullOrWhiteSpace(release.TagName)) return null;
            Version version;
            return Version.TryParse(release.TagName.Trim().TrimStart('v', 'V'), out version) ? version : null;
        }

        private static string BuildUpdateReleaseNotes(IEnumerable<GitHubReleaseInfo> releases, Version current, Version latest)
        {
            var newerReleases = (releases ?? new List<GitHubReleaseInfo>())
                .Select(r => new { Release = r, Version = ReleaseVersion(r) })
                .Where(i => i.Version != null && i.Version > current && i.Version <= latest)
                .OrderBy(i => i.Version)
                .ToList();

            var builder = new System.Text.StringBuilder();
            builder.AppendLine("Your version: " + current);
            builder.AppendLine("New version: " + latest);
            builder.AppendLine();
            builder.AppendLine("Changes between " + current + " and " + latest);

            if (newerReleases.Count == 0)
            {
                builder.AppendLine();
                builder.AppendLine("No release notes were provided for this update.");
                return builder.ToString().TrimEnd();
            }

            foreach (var item in newerReleases)
            {
                builder.AppendLine();
                builder.AppendLine(item.Release.TagName);
                builder.AppendLine(FormatReleaseNotesForDialog(RemoveDuplicateReleaseHeading(item.Release.Body, item.Release.TagName), "No release notes were provided for this update."));
            }

            return builder.ToString().TrimEnd();
        }

        private static GitHubReleaseAsset FindPortableZipAsset(GitHubReleaseInfo release)
        {
            if (release == null || release.Assets == null) return null;
            return release.Assets
                .Where(a => a != null && !string.IsNullOrWhiteSpace(a.BrowserDownloadUrl) && !string.IsNullOrWhiteSpace(a.Name))
                .Where(a => a.Name.EndsWith(".zip", StringComparison.OrdinalIgnoreCase))
                .OrderByDescending(a => a.Name.IndexOf("portable", StringComparison.OrdinalIgnoreCase) >= 0)
                .ThenByDescending(a => a.Name.IndexOf("clipman", StringComparison.OrdinalIgnoreCase) >= 0)
                .FirstOrDefault();
        }

        private static string FormatReleaseNotesForDialog(string markdown, string emptyText)
        {
            if (string.IsNullOrWhiteSpace(markdown)) return emptyText;
            var text = markdown
                .Replace("\r\n", "\n")
                .Replace("\r", "\n");
            var lines = text.Split('\n')
                .Select(line => line.TrimEnd())
                .Select(line => line.StartsWith("#", StringComparison.Ordinal) ? line.TrimStart('#').Trim() : line)
                .Select(line => line.StartsWith("- ", StringComparison.Ordinal) ? "  " + line.Substring(2) : line)
                .Select(line => line.StartsWith("* ", StringComparison.Ordinal) ? "  " + line.Substring(2) : line);
            return string.Join(Environment.NewLine, lines).Trim();
        }

        private static string RemoveDuplicateReleaseHeading(string markdown, string tagName)
        {
            if (string.IsNullOrWhiteSpace(markdown) || string.IsNullOrWhiteSpace(tagName)) return markdown;
            var lines = markdown.Replace("\r\n", "\n").Replace("\r", "\n").Split('\n').ToList();
            var firstContentIndex = lines.FindIndex(line => !string.IsNullOrWhiteSpace(line));
            if (firstContentIndex < 0) return markdown;
            var firstLine = lines[firstContentIndex].Trim();
            if (!firstLine.StartsWith("#", StringComparison.Ordinal)) return markdown;
            var heading = NormalizeReleaseHeading(firstLine.TrimStart('#').Trim());
            var tag = NormalizeReleaseHeading(tagName);
            if (heading.Length > 0 && tag.Length > 0 && (heading == tag || heading.Contains(tag) || tag.Contains(heading)))
            {
                lines.RemoveAt(firstContentIndex);
                return string.Join("\n", lines).TrimStart('\n');
            }

            return markdown;
        }

        private static string NormalizeReleaseHeading(string value)
        {
            if (string.IsNullOrWhiteSpace(value)) return string.Empty;
            var text = value.Trim().ToLowerInvariant();
            text = text.Replace("what's new in", string.Empty).Replace("whats new in", string.Empty).Replace("what is new in", string.Empty).Replace("version", string.Empty).Trim();
            return text.StartsWith("v", StringComparison.Ordinal) ? text.Substring(1) : text;
        }

        private static List<GitHubReleaseInfo> ParseReleases(string json)
        {
            var serializer = new JavaScriptSerializer();
            var rows = serializer.DeserializeObject(json) as object[];
            if (rows == null) return new List<GitHubReleaseInfo>();
            return rows.Select(ParseReleaseObject).Where(r => r != null).ToList();
        }

        private static GitHubReleaseInfo ParseRelease(string json)
        {
            var serializer = new JavaScriptSerializer();
            return ParseReleaseObject(serializer.DeserializeObject(json));
        }

        private static GitHubReleaseInfo ParseReleaseObject(object value)
        {
            var map = value as Dictionary<string, object>;
            if (map == null) return null;
            var release = new GitHubReleaseInfo
            {
                TagName = GetString(map, "tag_name"),
                HtmlUrl = GetString(map, "html_url"),
                Body = GetString(map, "body"),
                Assets = new List<GitHubReleaseAsset>()
            };

            object assetsValue;
            if (map.TryGetValue("assets", out assetsValue))
            {
                var assets = assetsValue as object[];
                if (assets != null)
                {
                    foreach (var assetValue in assets)
                    {
                        var assetMap = assetValue as Dictionary<string, object>;
                        if (assetMap == null) continue;
                        release.Assets.Add(new GitHubReleaseAsset
                        {
                            Name = GetString(assetMap, "name"),
                            BrowserDownloadUrl = GetString(assetMap, "browser_download_url")
                        });
                    }
                }
            }

            return release;
        }

        private static string GetString(Dictionary<string, object> map, string key)
        {
            object value;
            return map.TryGetValue(key, out value) && value != null ? Convert.ToString(value) : string.Empty;
        }

        private static void OpenUrl(string url)
        {
            try
            {
                Process.Start(new ProcessStartInfo { FileName = url, UseShellExecute = true });
            }
            catch
            {
            }
        }

        private static string GetUpdaterTempDirectory(string appDir)
        {
            var candidates = new List<string>();
            var localAppData = Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData);
            if (!string.IsNullOrWhiteSpace(localAppData)) candidates.Add(Path.Combine(localAppData, "Temp"));
            candidates.Add(Path.GetTempPath());
            candidates.Add(Path.Combine(appDir, "Settings", "Update Temp"));

            foreach (var candidate in candidates)
            {
                if (string.IsNullOrWhiteSpace(candidate)) continue;
                try
                {
                    var fullPath = Path.GetFullPath(Environment.ExpandEnvironmentVariables(candidate));
                    Directory.CreateDirectory(fullPath);
                    return fullPath;
                }
                catch
                {
                }
            }

            throw new InvalidOperationException("Could not create a temporary folder for the updater.");
        }

        private static string CommandLineQuote(string value)
        {
            if (value == null) return "\"\"";
            return "\"" + value.Replace("\"", "\\\"") + "\"";
        }

        private sealed class GitHubReleaseInfo
        {
            public string TagName { get; set; }
            public string HtmlUrl { get; set; }
            public string Body { get; set; }
            public List<GitHubReleaseAsset> Assets { get; set; }
        }

        private sealed class GitHubReleaseAsset
        {
            public string Name { get; set; }
            public string BrowserDownloadUrl { get; set; }
        }
    }
}
