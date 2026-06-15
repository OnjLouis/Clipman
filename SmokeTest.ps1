param(
    [string]$LivePath = '',
    [switch]$SkipBuild
)

$ErrorActionPreference = 'Stop'
$repoRoot = $PSScriptRoot
$portable = Join-Path $repoRoot 'portable'

function Fail([string]$message) {
    throw "Clipman smoke test failed: $message"
}

function Assert-Exists([string]$path, [string]$description) {
    if (!(Test-Path -LiteralPath $path)) {
        Fail "$description is missing: $path"
    }
}

function Assert-NotExists([string]$path, [string]$description) {
    if (Test-Path -LiteralPath $path) {
        Fail "$description should not exist: $path"
    }
}

function Assert-CleanPortable([string]$path) {
    Assert-Exists (Join-Path $path 'clipman.exe') 'Portable executable'
    Assert-Exists (Join-Path $path 'Manual.html') 'Portable manual'
    Assert-Exists (Join-Path $path 'LICENSE.txt') 'Portable license'
    Assert-Exists (Join-Path $path 'sounds') 'Portable sounds folder'
    Assert-Exists (Join-Path $path 'sqlite3.dll') 'Portable SQLite runtime'

    Assert-NotExists (Join-Path $path 'README.md') 'Source README in portable output'
    Assert-NotExists (Join-Path $path 'clipman-history.clipdb') 'Root compressed history database in portable output'
    Assert-NotExists (Join-Path $path 'clipman-history.json') 'Root history database in portable output'
    Assert-NotExists (Join-Path $path 'clipman-settings.json') 'Root settings file in portable output'
    Assert-NotExists (Join-Path $path 'Settings') 'Runtime Settings folder in clean portable output'
    Assert-NotExists (Join-Path $path 'Logs') 'Runtime Logs folder in clean portable output'
    Assert-NotExists (Join-Path $path 'Reports') 'Runtime Reports folder in clean portable output'
    Assert-NotExists (Join-Path $path 'Backups') 'Runtime Backups folder in clean portable output'
    Assert-NotExists (Join-Path $path 'sounds\sounds') 'Nested duplicate sounds folder'

    $expectedSounds = @('copy.wav', 'off.wav', 'on.wav', 'skip.wav')
    foreach ($sound in $expectedSounds) {
        Assert-Exists (Join-Path $path "sounds\$sound") "Portable sound $sound"
    }

    $unexpectedSounds = @(Get-ChildItem -LiteralPath (Join-Path $path 'sounds') -Force | Where-Object {
        $_.PSIsContainer -or ($expectedSounds -notcontains $_.Name)
    })
    if ($unexpectedSounds.Count -gt 0) {
        Fail "Unexpected item in portable sounds folder: $($unexpectedSounds[0].FullName)"
    }
}

function Assert-LiveCopyReasonable([string]$path) {
    if ([string]::IsNullOrWhiteSpace($path)) {
        Write-Host 'No live path supplied, skipping live-copy checks.'
        return
    }

    if (!(Test-Path -LiteralPath $path)) {
        Write-Host "Live path not found, skipping live-copy checks: $path"
        return
    }

    Assert-Exists (Join-Path $path 'clipman.exe') 'Live executable'
    Assert-Exists (Join-Path $path 'Manual.html') 'Live manual'
    Assert-Exists (Join-Path $path 'LICENSE.txt') 'Live license'
    Assert-Exists (Join-Path $path 'sounds') 'Live sounds folder'
    Assert-Exists (Join-Path $path 'sqlite3.dll') 'Live SQLite runtime'
    Assert-Exists (Join-Path $path 'Settings') 'Live Settings folder'

    Assert-NotExists (Join-Path $path 'README.md') 'Source README in live copy'
    Assert-NotExists (Join-Path $path 'clipman-history.clipdb') 'Root compressed history database in live copy'
    Assert-NotExists (Join-Path $path 'clipman-history.json') 'Legacy root history database in live copy'
    Assert-NotExists (Join-Path $path 'Settings\clipman-history.json') 'Plain JSON history database in live Settings folder'
    Assert-NotExists (Join-Path $path 'Settings\clipman-settings.json') 'Shared settings file in live Settings folder'
    Assert-NotExists (Join-Path $path 'clipman-settings.json') 'Legacy root settings file in live copy'
    Assert-NotExists (Join-Path $path 'sounds\sounds') 'Nested duplicate live sounds folder'
}

function Deploy-LiveCopy([string]$path) {
    if ([string]::IsNullOrWhiteSpace($path)) {
        return
    }

    if (!(Test-Path -LiteralPath $path)) {
        Write-Host "Live path not found, skipping live-copy deployment: $path"
        return
    }

    $liveExe = Join-Path $path 'clipman.exe'
    if (Test-Path -LiteralPath $liveExe) {
        try {
            & $liveExe --close | Out-Null
            Start-Sleep -Seconds 2
        }
        catch {
            Write-Host "Could not ask live Clipman to close before deployment: $($_.Exception.Message)"
        }
    }

    foreach ($fileName in @('clipman.exe', 'Manual.html', 'LICENSE.txt', 'sqlite3.dll')) {
        $source = Join-Path $portable $fileName
        if (Test-Path -LiteralPath $source) {
            Copy-Item -LiteralPath $source -Destination (Join-Path $path $fileName) -Force
        }
    }

    $soundSource = Join-Path $portable 'sounds'
    $soundTarget = Join-Path $path 'sounds'
    if (Test-Path -LiteralPath $soundSource) {
        Remove-Item -LiteralPath $soundTarget -Recurse -Force -ErrorAction SilentlyContinue
        Copy-Item -LiteralPath $soundSource -Destination $soundTarget -Recurse -Force
    }

    Write-Host "Deployed live copy to $path"
}

function Assert-TextDoesNotMatch([string]$path, [string]$pattern, [string]$description) {
    Assert-Exists $path $description
    $text = Get-Content -LiteralPath $path -Raw
    if ($text -match $pattern) {
        Fail "$description contains forbidden or stale text matching: $pattern"
    }
}

function Assert-TextMatches([string]$path, [string]$pattern, [string]$description) {
    Assert-Exists $path $description
    $text = Get-Content -LiteralPath $path -Raw
    if ($text -notmatch $pattern) {
        Fail "$description is missing expected text matching: $pattern"
    }
}

function Assert-ManualAndReadmeClean {
    $manual = Join-Path $repoRoot 'Manual.html'
    $readme = Join-Path $repoRoot 'README.md'

    Assert-TextMatches $manual '<h2 id="contents">Contents</h2>' 'Manual table of contents'
    Assert-TextMatches $manual 'Project page: <a href="https://github.com/OnjLouis/Clipman">' 'Manual project page link'
    Assert-TextMatches $manual 'Remove URL tracking' 'Manual URL tracking documentation'
    Assert-TextMatches $manual 'File history is session-only' 'Manual file-history session-only note'
    Assert-TextMatches $manual 'Run Clipman at Windows startup' 'Manual startup documentation'
    Assert-TextMatches $manual 'Install updates silently when possible' 'Manual silent update documentation'
    Assert-TextMatches $manual 'Settings\\sounds' 'Manual user sound override documentation'
    Assert-TextMatches $manual 'Shift\+F1' 'Manual update shortcut'
    Assert-TextMatches $manual 'Ctrl\+F1' 'Manual project shortcut'
    Assert-TextMatches $manual 'Alt\+F1' 'Manual diagnostics shortcut'
    Assert-TextMatches $manual 'Help, Contact' 'Manual contact documentation'
    Assert-TextMatches $manual 'Help, Donate' 'Manual donate documentation'
    Assert-TextMatches $manual 'Multiple running Clipman instances can use the same history database' 'Manual shared history explanation'
    Assert-TextMatches $manual 'During an online or automatic update' 'Manual seamless update explanation'
    Assert-TextMatches $manual 'Storage and Password' 'Manual storage/password tab documentation'
    Assert-TextMatches $manual 'Ctrl\+1</code> to <code>Ctrl\+4' 'Manual preferences tab shortcut documentation'
    Assert-TextMatches $manual 'Use no password button clears the saved history password' 'Manual no-password button documentation'
    Assert-TextMatches $manual 'History password' 'Manual encryption documentation'
    Assert-TextMatches $manual 'ascending and descending' 'Manual sort direction documentation'
    Assert-TextMatches $manual '<h3>1\.1\.1</h3>' 'Manual 1.1.1 changelog'
    Assert-TextMatches $manual 'deliberately ignores that generated password copy' 'Manual generated password documentation'
    Assert-TextMatches $manual '<h2 id="application-files">Application Files</h2>' 'Manual application files section'
    Assert-TextMatches $manual '<code>sqlite3\.dll</code>' 'Manual SQLite runtime file documentation'
    Assert-TextMatches $manual '<code>LICENSE\.txt</code>' 'Manual license file documentation'
    Assert-TextMatches $manual '<h2 id="license">License</h2>' 'Manual license section'
    Assert-TextMatches $manual 'old Clipman <code>clipman\.db</code>, or Ditto SQLite database' 'Manual SQLite import documentation'
    Assert-TextMatches $manual 'SQLite import support uses the public-domain SQLite runtime' 'Manual SQLite credit'
    Assert-TextMatches $manual '<code>Backspace</code> to jump to the first normal entry' 'Manual Backspace normal-entry shortcut'
    Assert-TextMatches $manual 'Ctrl\+Shift\+R' 'Manual URL tracking shortcut'
    Assert-TextMatches $manual 'Ctrl\+A' 'Manual select-all/viewer shortcut'
    Assert-TextMatches $manual 'Tyler Spivey' 'Manual credits'
    Assert-TextMatches $readme 'Project page: <https://github.com/OnjLouis/Clipman>' 'README project page link'
    Assert-TextMatches $readme '<code>Ctrl\+Alt\+`</code>' 'README backtick hotkey formatting'
    Assert-TextMatches $readme 'automatic update checks' 'README update preferences'
    Assert-TextMatches $readme 'Switch Preferences tabs' 'README preferences tab shortcut'
    Assert-TextMatches $readme 'Storage and Password' 'README storage/password tab documentation'
    Assert-TextMatches $readme 'LICENSE\.txt' 'README license file documentation'
    Assert-TextMatches $readme 'Sort direction can be toggled' 'README sort direction documentation'
    Assert-TextMatches $readme 'Settings\\sounds' 'README user sound override documentation'
    Assert-TextMatches $readme 'Multiple machines can write to the same history database' 'README shared history explanation'
    Assert-TextMatches $readme 'Optional history password encryption' 'README encryption documentation'
    Assert-TextMatches $readme 'deliberately ignores that generated password copy' 'README generated password documentation'
    Assert-TextMatches $readme 'old Clipman `clipman\.db` and Ditto SQLite databases' 'README SQLite import documentation'
    Assert-TextMatches $readme 'Press Backspace in the history list' 'README Backspace normal-entry shortcut'
    Assert-TextMatches $readme 'Help` > `Contact`' 'README contact documentation'
    Assert-TextMatches $readme 'Help` > `Donate`' 'README donate documentation'
    Assert-TextMatches (Join-Path $repoRoot 'src\Program.Updater.cs') 'PublishCloseRequest' 'Updater shared close request code'
    Assert-TextMatches (Join-Path $repoRoot 'src\Program.Updater.cs') 'TryRestartUpdatedApp' 'Updater restart code'
    Assert-TextMatches (Join-Path $repoRoot 'src\ClipmanApplicationContext.cs') 'ClipDatabaseFile\.IsEncryptedFile\(settings\.DatabasePath\)' 'Startup encrypted database detection'
    Assert-TextMatches (Join-Path $repoRoot 'src\ClipmanApplicationContext.cs') 'CopySensitiveTextToClipboard' 'Sensitive clipboard copy suppression'
    Assert-TextMatches (Join-Path $repoRoot 'src\ClipmanApplicationContext.cs') 'LastPreferencesTab' 'Preferences tab persistence application'
    Assert-TextMatches (Join-Path $repoRoot 'src\PreferencesForm.cs') 'SelectPreferencesTabByShortcut' 'Preferences tab shortcut code'
    Assert-TextMatches (Join-Path $repoRoot 'src\Models.cs') 'LastPreferencesTab' 'Preferences tab persistence setting'
    Assert-TextDoesNotMatch (Join-Path $repoRoot 'src\PreferencesForm.cs') 'encryptDatabase|Clipboard\.SetText\(password\)' 'Preferences encryption checkbox and raw password clipboard copy'
    Assert-TextMatches (Join-Path $repoRoot 'src\Program.cs') 'Logs\\\\Startup\.log' 'Startup failure log message'
    Assert-TextMatches (Join-Path $repoRoot 'src\Program.cs') 'WriteStartupLog\("Startup failed\."' 'Startup failure logging'
    Assert-TextMatches (Join-Path $repoRoot 'src\AssemblyInfo.cs') 'AssemblyCompany\("Andre Louis"\)' 'Executable company metadata'
    Assert-TextMatches (Join-Path $repoRoot 'src\AssemblyInfo.cs') 'Copyright \(c\) Andre Louis' 'Executable copyright metadata'
    Assert-TextMatches (Join-Path $repoRoot 'src\HistoryForm.cs') 'Build stamp: ' 'About build stamp'
    Assert-TextMatches (Join-Path $repoRoot 'src\HistoryForm.cs') 'Based on earlier Clipman work by Tyler Spivey' 'About credits'
    Assert-TextMatches (Join-Path $repoRoot 'GITHUB-RELEASE-RULES.md') 'sqlite3\.dll' 'GitHub release rules SQLite runtime packaging'
    Assert-TextMatches (Join-Path $repoRoot 'GITHUB-RELEASE-RULES.md') 'LICENSE\.txt' 'GitHub release rules license packaging'

    $forbidden = 'Merjille|Kobo|VIP40|D:\\|E:\\|\bolder installs\b|\bolder versions\b|migration|migrate automatically|temporary workaround|Dropbox'
    Assert-TextDoesNotMatch $manual $forbidden 'Manual'
    Assert-TextDoesNotMatch $readme $forbidden 'README'
}

function Assert-CodeBehavior {
    $tmp = Join-Path ([IO.Path]::GetTempPath()) ('clipman-smoke-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Force -Path $tmp | Out-Null
    try {
        $testSource = Join-Path $tmp 'ClipmanSmokeHarness.cs'
        @'
using System;
using System.IO;
using System.Linq;
using System.Text;
using Clipman;

internal static class ClipmanSmokeHarness
{
    private static void Assert(bool condition, string message)
    {
        if (!condition) throw new Exception(message);
    }

    private static void Main()
    {
        var cleaned = UrlTrackingCleaner.CleanText("Visit https://example.com/page?a=1&utm_source=news&fbclid=abc&b=2.");
        Assert(cleaned == "Visit https://example.com/page?a=1&b=2.", "URL tracking cleaner did not remove only tracking parameters.");

        var html = UrlTrackingCleaner.CleanText("<a href=\"https://example.com/?a=1&amp;utm_medium=email&amp;b=2\">link</a>");
        Assert(html.Contains("href=\"https://example.com/?a=1&amp;b=2\""), "URL tracking cleaner did not preserve HTML ampersands.");

        var path = Path.Combine(Path.GetTempPath(), "clipman-test-" + Guid.NewGuid().ToString("N") + ".clipdb");
        var secretText = "plain text should be compressed";
        ClipDatabaseFile.SaveAtomic(path, new ClipDatabase
        {
            Entries = { new ClipEntry { Text = secretText, Name = "Test", Group = "Smoke" } }
        });
        var raw = File.ReadAllText(path, Encoding.Default);
        Assert(!raw.Contains(secretText), ".clipdb file contains raw clipboard text.");
        var rawBytes = File.ReadAllBytes(path);
        Assert(rawBytes.Length > 8 && rawBytes[0] == (byte)'C' && rawBytes[1] == (byte)'L' && rawBytes[2] == (byte)'I' && rawBytes[3] == (byte)'P', ".clipdb file is missing Clipman header.");
        Assert(!(rawBytes[0] == 0x1f && rawBytes[1] == 0x8b), ".clipdb file starts with a raw gzip header.");
        var loaded = ClipDatabaseFile.Load(path);
        Assert(loaded.Entries.Count == 1 && loaded.Entries[0].Text == secretText, ".clipdb round trip failed.");
        File.Delete(path);

        var encryptedPath = Path.Combine(Path.GetTempPath(), "clipman-test-" + Guid.NewGuid().ToString("N") + ".clipdb");
        var password = "correct horse battery staple";
        ClipDatabaseFile.SaveAtomic(encryptedPath, new ClipDatabase
        {
            Entries = { new ClipEntry { Text = secretText, Name = "Encrypted", Group = "Smoke" } }
        }, password);
        var encryptedRaw = File.ReadAllText(encryptedPath, Encoding.Default);
        Assert(!encryptedRaw.Contains(secretText), "Encrypted .clipdb file contains raw clipboard text.");
        Assert(ClipDatabaseFile.IsEncryptedFile(encryptedPath), "Encrypted .clipdb file was not recognized as encrypted.");
        var encryptedLoaded = ClipDatabaseFile.Load(encryptedPath, password);
        Assert(encryptedLoaded.Entries.Count == 1 && encryptedLoaded.Entries[0].Text == secretText, "Encrypted .clipdb round trip failed.");
        var wrongPasswordRejected = false;
        try
        {
            ClipDatabaseFile.Load(encryptedPath, "wrong password");
        }
        catch (DatabasePasswordRequiredException)
        {
            wrongPasswordRejected = true;
        }
        Assert(wrongPasswordRejected, "Encrypted .clipdb did not reject the wrong password.");
        File.Delete(encryptedPath);

        var oldClipmanDb = Path.Combine(Path.GetTempPath(), "clipman-old-" + Guid.NewGuid().ToString("N") + ".db");
        CreateOldClipmanDatabase(oldClipmanDb, "old Clipman import text");
        var oldClipmanEntries = SqliteClipboardImporter.LoadEntries(oldClipmanDb);
        Assert(oldClipmanEntries.Count == 1, "Old Clipman SQLite import returned the wrong number of entries.");
        Assert(oldClipmanEntries[0].Text == "old Clipman import text", "Old Clipman SQLite import returned the wrong text.");
        Assert(oldClipmanEntries[0].Group == "Imported from old Clipman", "Old Clipman SQLite import did not set the expected group.");
        File.Delete(oldClipmanDb);

        var dittoDb = Path.Combine(Path.GetTempPath(), "ditto-" + Guid.NewGuid().ToString("N") + ".db");
        CreateDittoDatabase(dittoDb, "Ditto import text");
        var dittoEntries = SqliteClipboardImporter.LoadEntries(dittoDb);
        Assert(dittoEntries.Count == 1, "Ditto SQLite import returned the wrong number of entries.");
        Assert(dittoEntries[0].Text == "Ditto import text", "Ditto SQLite import returned the wrong text.");
        Assert(dittoEntries[0].Group == "Imported from Ditto", "Ditto SQLite import did not set the expected group.");
        File.Delete(dittoDb);

        var conflictDir = Path.Combine(Path.GetTempPath(), "clipman-conflict-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(conflictDir);
        var mainDb = Path.Combine(conflictDir, "clipman-history.clipdb");
        var conflictDb = Path.Combine(conflictDir, "clipman-history (Desktop conflicted copy 2026-06-14).clipdb");
        ClipDatabaseFile.SaveAtomic(mainDb, new ClipDatabase { Entries = { new ClipEntry { Text = "main entry", Group = "Main" } } });
        ClipDatabaseFile.SaveAtomic(conflictDb, new ClipDatabase { Entries = { new ClipEntry { Text = "conflict entry", Group = "Conflict" } } });
        SyncConflictResolver.ResolveDatabaseConflicts(mainDb);
        var merged = ClipDatabaseFile.Load(mainDb);
        Assert(merged.Entries.Any(e => e.Text == "main entry") && merged.Entries.Any(e => e.Text == "conflict entry"), "Database conflict merge failed.");
        Assert(!File.Exists(conflictDb), "Database conflict file was not removed.");

        var mainSettings = Path.Combine(conflictDir, "Desktop-settings.json");
        var conflictSettings = Path.Combine(conflictDir, "Desktop-settings (Laptop).json");
        JsonUtil.SaveAtomic(mainSettings, new AppSettings { MaxHistoryEntries = 111 });
        System.Threading.Thread.Sleep(20);
        JsonUtil.SaveAtomic(conflictSettings, new AppSettings { MaxHistoryEntries = 222 });
        SyncConflictResolver.ResolveSettingsConflicts(mainSettings);
        var settings = JsonUtil.Load<AppSettings>(mainSettings);
        Assert(settings.MaxHistoryEntries == 222, "Settings conflict resolver did not keep newest settings.");
        Assert(!File.Exists(conflictSettings), "Settings conflict file was not removed.");

        var stateDir = Path.Combine(conflictDir, "state");
        Directory.CreateDirectory(stateDir);
        SharedUpdateStateStore.PublishCurrentBuild(stateDir);
        var state = SharedUpdateStateStore.Load(stateDir);
        Assert(state.BuildStampUtcMs == BuildInfo.BuildStampUtcMs, "Shared update state did not publish current build stamp.");
        Assert(!string.IsNullOrWhiteSpace(state.ExeSha256), "Shared update state did not publish executable hash.");

        SharedUpdateStateStore.PublishCloseRequest(stateDir, 10);
        var localClose = SharedUpdateStateStore.Load(stateDir);
        SharedUpdateState ignoredClose;
        Assert(localClose.CloseRequestUntilUtcMs > TimeUtil.NowUnixMs(), "Shared close request did not set an active expiration.");
        Assert(!string.IsNullOrWhiteSpace(localClose.CloseRequestId), "Shared close request did not set a request id.");
        Assert(!SharedUpdateStateStore.HasActiveCloseRequest(stateDir, string.Empty, out ignoredClose), "Shared close request from this machine should be ignored.");

        var remoteRequestId = "smoke-" + Guid.NewGuid().ToString("N");
        JsonUtil.SaveAtomic(SharedUpdateStateStore.StatePath(stateDir), new SharedUpdateState
        {
            BuildStampUtcMs = BuildInfo.BuildStampUtcMs,
            ExeSha256 = "not-this-exe",
            CloseRequestUntilUtcMs = TimeUtil.NowUnixMs() + 30000,
            CloseRequestId = remoteRequestId,
            CloseRequestedByMachine = "OtherMachine"
        });
        SharedUpdateState remoteClose;
        Assert(SharedUpdateStateStore.HasActiveCloseRequest(stateDir, string.Empty, out remoteClose), "Shared close request from another machine was not detected.");
        Assert(!SharedUpdateStateStore.HasActiveCloseRequest(stateDir, remoteRequestId, out remoteClose), "Already handled shared close request was not ignored.");

        var newerStatePath = SharedUpdateStateStore.StatePath(stateDir);
        JsonUtil.SaveAtomic(newerStatePath, new SharedUpdateState { BuildStampUtcMs = BuildInfo.BuildStampUtcMs + 1000, ExeSha256 = "not-this-exe" });
        var remoteNewerState = SharedUpdateStateStore.Load(stateDir);
        Assert(SharedUpdateStateStore.IsNewerStateFromAnotherMachine(remoteNewerState), "Newer shared state from another machine was not identified.");
        SharedUpdateStateStore.PublishCurrentBuild(stateDir);
        var preserved = SharedUpdateStateStore.Load(stateDir);
        Assert(preserved.BuildStampUtcMs == BuildInfo.BuildStampUtcMs + 1000, "Shared update state overwrote a newer state file.");

        Directory.Delete(conflictDir, true);
    }

    private static void CreateOldClipmanDatabase(string path, string text)
    {
        var bytes = Encoding.Unicode.GetBytes(text + "\0");
        using (var db = new SmokeSqliteDatabase(path))
        {
            db.Exec("create table items (id integer primary key, size integer, description text, time integer)");
            db.Exec("create table formats (clip_id integer, format text, data blob)");
            db.Exec("insert into items (id, size, description, time) values (1, " + bytes.Length + ", 'old Clipman import text', 1700000000)");
            db.InsertBlob("insert into formats (clip_id, format, data) values (1, 'CF_UNICODETEXT', ?)", bytes);
        }
    }

    private static void CreateDittoDatabase(string path, string text)
    {
        using (var db = new SmokeSqliteDatabase(path))
        {
            db.Exec("create table Main (mText text, lDate integer)");
            db.Exec("insert into Main (mText, lDate) values ('" + text.Replace("'", "''") + "', 1700000000)");
        }
    }

    private sealed class SmokeSqliteDatabase : IDisposable
    {
        private IntPtr handle;

        public SmokeSqliteDatabase(string path)
        {
            if (sqlite3_open16(path, out handle) != 0)
            {
                throw new Exception("Could not create SQLite smoke database.");
            }
        }

        public void Exec(string sql)
        {
            IntPtr error;
            if (sqlite3_exec(handle, sql, IntPtr.Zero, IntPtr.Zero, out error) != 0)
            {
                throw new Exception("SQLite smoke exec failed: " + System.Runtime.InteropServices.Marshal.PtrToStringAnsi(error));
            }
        }

        public void InsertBlob(string sql, byte[] data)
        {
            IntPtr statement;
            if (sqlite3_prepare16_v2(handle, sql, -1, out statement, IntPtr.Zero) != 0)
            {
                throw new Exception("SQLite smoke prepare failed.");
            }
            try
            {
                if (sqlite3_bind_blob(statement, 1, data, data.Length, new IntPtr(-1)) != 0)
                {
                    throw new Exception("SQLite smoke blob bind failed.");
                }
                if (sqlite3_step(statement) != 101)
                {
                    throw new Exception("SQLite smoke step failed.");
                }
            }
            finally
            {
                sqlite3_finalize(statement);
            }
        }

        public void Dispose()
        {
            if (handle == IntPtr.Zero) return;
            sqlite3_close(handle);
            handle = IntPtr.Zero;
        }
    }

    [System.Runtime.InteropServices.DllImport("sqlite3", CallingConvention = System.Runtime.InteropServices.CallingConvention.Cdecl, CharSet = System.Runtime.InteropServices.CharSet.Unicode)]
    private static extern int sqlite3_open16(string filename, out IntPtr db);

    [System.Runtime.InteropServices.DllImport("sqlite3", CallingConvention = System.Runtime.InteropServices.CallingConvention.Cdecl)]
    private static extern int sqlite3_close(IntPtr db);

    [System.Runtime.InteropServices.DllImport("sqlite3", CallingConvention = System.Runtime.InteropServices.CallingConvention.Cdecl, CharSet = System.Runtime.InteropServices.CharSet.Ansi)]
    private static extern int sqlite3_exec(IntPtr db, string sql, IntPtr callback, IntPtr arg, out IntPtr error);

    [System.Runtime.InteropServices.DllImport("sqlite3", CallingConvention = System.Runtime.InteropServices.CallingConvention.Cdecl, CharSet = System.Runtime.InteropServices.CharSet.Unicode, EntryPoint = "sqlite3_prepare16_v2")]
    private static extern int sqlite3_prepare16_v2(IntPtr db, string sql, int nByte, out IntPtr statement, IntPtr tail);

    [System.Runtime.InteropServices.DllImport("sqlite3", CallingConvention = System.Runtime.InteropServices.CallingConvention.Cdecl)]
    private static extern int sqlite3_bind_blob(IntPtr statement, int index, byte[] value, int bytes, IntPtr destructor);

    [System.Runtime.InteropServices.DllImport("sqlite3", CallingConvention = System.Runtime.InteropServices.CallingConvention.Cdecl)]
    private static extern int sqlite3_step(IntPtr statement);

    [System.Runtime.InteropServices.DllImport("sqlite3", CallingConvention = System.Runtime.InteropServices.CallingConvention.Cdecl)]
    private static extern int sqlite3_finalize(IntPtr statement);
}
'@ | Set-Content -LiteralPath $testSource -Encoding UTF8

        $csc = Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
        $sources = @(
            (Join-Path $repoRoot 'src\Models.cs'),
            (Join-Path $repoRoot 'src\JsonUtil.cs'),
            (Join-Path $repoRoot 'src\ClipDatabaseFile.cs'),
            (Join-Path $repoRoot 'src\UrlTrackingCleaner.cs'),
            (Join-Path $repoRoot 'src\SqliteClipboardImporter.cs'),
            (Join-Path $repoRoot 'src\SyncConflictResolver.cs'),
            (Join-Path $repoRoot 'src\SharedUpdateState.cs'),
            (Join-Path $repoRoot 'src\BuildInfo.cs'),
            $testSource
        )
        $out = Join-Path $tmp 'ClipmanSmokeHarness.exe'
        & $csc /nologo /target:exe /out:$out /reference:System.dll,System.Core.dll,System.IO.Compression.dll,System.IO.Compression.FileSystem.dll,System.Security.dll,System.Web.Extensions.dll,System.Windows.Forms.dll $sources
        if ($LASTEXITCODE -ne 0) {
            Fail "Smoke harness build failed with exit code $LASTEXITCODE"
        }
        Copy-Item -LiteralPath (Join-Path $repoRoot 'Assets\sqlite\sqlite3.dll') -Destination (Join-Path $tmp 'sqlite3.dll') -Force
        & $out
        if ($LASTEXITCODE -ne 0) {
            Fail "Smoke harness failed with exit code $LASTEXITCODE"
        }
    }
    finally {
        Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
    }
}

if (!$SkipBuild) {
    & (Join-Path $repoRoot 'Build.ps1')
}

Assert-ManualAndReadmeClean
Assert-CodeBehavior
Assert-CleanPortable $portable
Deploy-LiveCopy $LivePath
Assert-LiveCopyReasonable $LivePath

Write-Host 'Clipman smoke test passed.'
