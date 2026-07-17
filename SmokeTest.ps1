param(
    [string]$LivePath = '',
    [switch]$SkipBuild,
    [switch]$RunPostPublishUpdateSmoke,
    [switch]$RequireMacReleaseAsset,
    [switch]$SkipMacReleaseAsset,
    [switch]$SkipInstalledMacAppCheck,
    [string]$Version = '',
    [int[]]$ReviewedOpenIssue = @(),
    [switch]$SkipGitHubActivityCheck,
    [switch]$ServerOnly,
    [switch]$ClientOnly
)

$ErrorActionPreference = 'Stop'
$repoRoot = $PSScriptRoot
$portable = Join-Path $repoRoot 'portable'
$programBuilds = if ([string]::IsNullOrWhiteSpace($env:CLIPMAN_PROGRAM_BUILDS)) {
    Join-Path $repoRoot 'release\Program Builds'
} else {
    $env:CLIPMAN_PROGRAM_BUILDS
}

function Fail([string]$message) {
    throw "Clipman smoke test failed: $message"
}

if ($ServerOnly -and $ClientOnly) {
    Fail 'Use either -ServerOnly or -ClientOnly, not both.'
}

function Is-SmokePath([string]$path) {
    if ([string]::IsNullOrWhiteSpace($path)) {
        return $false
    }

    $full = [IO.Path]::GetFullPath($path)
    $temp = [IO.Path]::GetFullPath($env:TEMP).TrimEnd('\') + '\'
    if (!$full.StartsWith($temp, [StringComparison]::OrdinalIgnoreCase)) {
        return $false
    }

    return $full -match '\\clipman-(local-update-smoke|github-update-smoke)-'
}

function Stop-SmokeClipmanProcesses {
    foreach ($process in @(Get-Process clipman -ErrorAction SilentlyContinue)) {
        $path = ''
        try {
            $path = $process.Path
        }
        catch {
        }

        if (!(Is-SmokePath $path)) {
            continue
        }

        try {
            $process.CloseMainWindow() | Out-Null
            if (!$process.WaitForExit(2000)) {
                $process.Kill()
                $process.WaitForExit(5000)
            }
        }
        catch {
        }
        finally {
            try { $process.Dispose() } catch { }
        }
    }
}

function Clear-OldSmokeFolders {
    Stop-SmokeClipmanProcesses
    foreach ($pattern in @('clipman-local-update-smoke-*', 'clipman-github-update-smoke-*')) {
        foreach ($folder in @(Get-ChildItem -LiteralPath $env:TEMP -Directory -Filter $pattern -ErrorAction SilentlyContinue)) {
            try {
                Remove-Item -LiteralPath $folder.FullName -Recurse -Force -ErrorAction Stop
            }
            catch {
            }
        }
    }
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

    Assert-NotExists (Join-Path $path 'ClipmanServer.exe') 'Server executable in normal Clipman client portable output'
    Assert-NotExists (Join-Path $path 'README.md') 'Source README in portable output'
    Assert-NotExists (Join-Path $path 'clipman-history.clipdb') 'Root compressed history database in portable output'
    Assert-NotExists (Join-Path $path 'clipman-history.json') 'Root history database in portable output'
    Assert-NotExists (Join-Path $path 'clipman-settings.json') 'Root settings file in portable output'
    Assert-NotExists (Join-Path $path 'Settings') 'Runtime Settings folder in clean portable output'
    Assert-NotExists (Join-Path $path 'Logs') 'Runtime Logs folder in clean portable output'
    Assert-NotExists (Join-Path $path 'Reports') 'Runtime Reports folder in clean portable output'
    Assert-NotExists (Join-Path $path 'Backups') 'Runtime Backups folder in clean portable output'
    Assert-NotExists (Join-Path $path 'sounds\sounds') 'Nested duplicate sounds folder'
    Assert-NotExists (Join-Path $path 'ClipmanServerLinux') 'Linux server folder in Windows portable output'

    $expectedSounds = @('copy.wav', 'exclude.wav', 'off.wav', 'on.wav', 'remote.wav', 'skip.wav')
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
    Assert-NotExists (Join-Path $path 'ClipmanServer.exe') 'Server executable in normal Clipman client live copy'
    Assert-NotExists (Join-Path $path 'ClipmanServerLinux') 'Linux server folder in Windows live copy'

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

    Remove-Item -LiteralPath (Join-Path $path 'ClipmanServer.exe') -Force -ErrorAction SilentlyContinue

    $soundSource = Join-Path $portable 'sounds'
    $soundTarget = Join-Path $path 'sounds'
    if (Test-Path -LiteralPath $soundSource) {
        Remove-Item -LiteralPath $soundTarget -Recurse -Force -ErrorAction SilentlyContinue
        Copy-Item -LiteralPath $soundSource -Destination $soundTarget -Recurse -Force
    }

    if (Test-Path -LiteralPath $liveExe) {
        try {
            Start-Process -FilePath $liveExe -WorkingDirectory $path -WindowStyle Hidden | Out-Null
            Start-Sleep -Seconds 3
        }
        catch {
            Write-Host "Could not restart live Clipman after deployment: $($_.Exception.Message)"
        }
    }

    Write-Host "Deployed live copy to $path"
}

function Invoke-LiveServerDeploy {
    $sshTarget = $env:CLIPMAN_LIVE_SERVER_SSH
    $remoteDir = $env:CLIPMAN_LIVE_SERVER_DIR
    $remoteConfig = $env:CLIPMAN_LIVE_SERVER_CONFIG
    $serviceName = if ([string]::IsNullOrWhiteSpace($env:CLIPMAN_LIVE_SERVER_SERVICE)) { 'clipman-server.service' } else { $env:CLIPMAN_LIVE_SERVER_SERVICE }

    if ([string]::IsNullOrWhiteSpace($sshTarget) -or
        [string]::IsNullOrWhiteSpace($remoteDir) -or
        [string]::IsNullOrWhiteSpace($remoteConfig)) {
        Write-Host 'No live Clipman Server deployment target configured, skipping server deployment.'
        return
    }

    $normalizedRemoteDir = $remoteDir.TrimEnd('/')
    $normalizedRemoteConfig = $remoteConfig.TrimEnd('/')
    if ($normalizedRemoteConfig.StartsWith($normalizedRemoteDir + '/', [StringComparison]::Ordinal)) {
        Fail "Live Clipman Server config must not live under the runtime program directory. Use a persistent config path such as ~/.config/clipman-server/clipman-server-settings.json, not $remoteConfig."
    }

    $serverScript = Join-Path $repoRoot 'ClipmanServerLinux\clipman_server.py'
    $serverManual = Join-Path $repoRoot 'ClipmanServer\Manual.html'
    Assert-Exists $serverScript 'Live server deployment script'
    Assert-Exists $serverManual 'Live server deployment manual'

    & ssh $sshTarget "mkdir -p '$remoteDir'"
    if ($LASTEXITCODE -ne 0) {
        Fail "Could not create live Clipman Server directory $remoteDir on $sshTarget."
    }

    & scp $serverScript "${sshTarget}:${remoteDir}/clipman_server.py.new"
    if ($LASTEXITCODE -ne 0) {
        Fail "Could not copy Clipman Server to live server target $sshTarget."
    }
    & scp $serverManual "${sshTarget}:${remoteDir}/Manual.html.new"
    if ($LASTEXITCODE -ne 0) {
        Fail "Could not copy Clipman Server manual to live server target $sshTarget."
    }

$remote = @"
set -e
cd "$remoteDir"
mv clipman_server.py.new clipman_server.py
mv Manual.html.new Manual.html
chmod 700 clipman_server.py
chmod 600 Manual.html
rm -f README.md
mkdir -p "`$HOME/.local/bin"
cat > "`$HOME/.local/bin/clipmanserver" <<'EOF'
#!/usr/bin/env sh
set -eu
SERVICE="$serviceName"
PYTHON="/usr/bin/python3"
SCRIPT="$remoteDir/clipman_server.py"
CONFIG="$remoteConfig"

usage() {
  cat <<USAGE
Usage: clipmanserver <command>

Commands:
  start       Start Clipman Server
  stop        Stop Clipman Server
  restart     Restart Clipman Server
  status      Show service or process status
  list        List database buckets
  list-json   List database buckets with full IDs as JSON
  delete      Move an inactive database bucket to DeletedDatabases
  force-delete Move a database bucket even if recently active
  console     Run Clipman Server in the current terminal
  token       Print the server token
  connection  Write and print the connection details file path
  help        Show this help
USAGE
}

has_system_service() {
  command -v systemctl >/dev/null 2>&1 && systemctl list-unit-files "`$SERVICE" --no-legend 2>/dev/null | grep -q "`$SERVICE"
}

case "`${1:-help}" in
  start)
    if has_system_service; then
      sudo systemctl start "`$SERVICE"
    else
      nohup "`$PYTHON" "`$SCRIPT" --config "`$CONFIG" >/dev/null 2>&1 &
      echo "Clipman Server started."
    fi
    ;;
  stop)
    if has_system_service; then
      sudo systemctl stop "`$SERVICE"
    else
      pkill -f "clipman_server.py --config `$CONFIG" 2>/dev/null || true
    fi
    ;;
  restart)
    "`$0" stop
    "`$0" start
    ;;
  status)
    if has_system_service; then
      systemctl status "`$SERVICE" --no-pager
    else
      pgrep -af "clipman_server.py --config `$CONFIG" || echo "Clipman Server is not running."
    fi
    ;;
  list)
    "`$PYTHON" "`$SCRIPT" --config "`$CONFIG" --list-databases
    ;;
  list-json)
    "`$PYTHON" "`$SCRIPT" --config "`$CONFIG" --list-databases-json
    ;;
  delete)
    if [ -z "`${2:-}" ]; then
      echo "Usage: clipmanserver delete <database-id>" >&2
      echo "Tip: run clipmanserver list first, then use --list-databases-json for full IDs." >&2
      exit 2
    fi
    "`$PYTHON" "`$SCRIPT" --config "`$CONFIG" --delete-database "`$2" --confirm
    ;;
  force-delete)
    if [ -z "`${2:-}" ]; then
      echo "Usage: clipmanserver force-delete <database-id>" >&2
      echo "This bypasses the 24-hour recent-activity safety guard." >&2
      exit 2
    fi
    "`$PYTHON" "`$SCRIPT" --config "`$CONFIG" --delete-database "`$2" --confirm --force-recent
    ;;
  console)
    exec "`$PYTHON" "`$SCRIPT" --config "`$CONFIG"
    ;;
  token)
    "`$PYTHON" "`$SCRIPT" --config "`$CONFIG" --show-token
    ;;
  connection)
    "`$PYTHON" "`$SCRIPT" --config "`$CONFIG" --write-connection-info
    ;;
  help|-h|--help)
    usage
    ;;
  *)
    usage
    exit 2
    ;;
esac
EOF
chmod 700 "`$HOME/.local/bin/clipmanserver"
if command -v systemctl >/dev/null 2>&1 && sudo -n true >/dev/null 2>&1; then
  sudo tee /etc/systemd/system/$serviceName >/dev/null <<EOF
[Unit]
Description=Clipman Server
After=network-online.target tailscaled.service
Wants=network-online.target

[Service]
Type=simple
User=`$USER
WorkingDirectory=$remoteDir
ExecStart=/usr/bin/python3 $remoteDir/clipman_server.py --config $remoteConfig
Restart=always
RestartSec=5
NoNewPrivileges=true

[Install]
WantedBy=multi-user.target
EOF
  sudo systemctl daemon-reload
  sudo systemctl enable "$serviceName"
  sudo systemctl restart "$serviceName"
  sleep 2
  systemctl is-enabled "$serviceName"
  systemctl is-active "$serviceName"
else
  nohup python3 ./clipman_server.py --config "$remoteConfig" >/dev/null 2>&1 &
  sleep 2
fi
python3 -c "import json, urllib.request, sys; cfg=json.load(open(sys.argv[1], encoding='utf-8')); url='http://%s:%s/api/v1/health' % (cfg.get('Host', '127.0.0.1'), cfg.get('Port')); data=json.loads(urllib.request.urlopen(url, timeout=5).read().decode('utf-8')); ok=data.get('Status') == 'ok'; runtime=data.get('Runtime') or {}; print('Clipman Server health check: ' + ('ok' if ok else 'failed')); print('Requests: %s; Unique clients: %s; TLS enabled: %s' % (runtime.get('Requests', 0), runtime.get('UniqueClients', 0), data.get('TlsEnabled', False))); raise SystemExit(0 if ok else 1)" "$remoteConfig"
"@

    $remoteScript = Join-Path $env:TEMP ("clipman-server-deploy-" + [Guid]::NewGuid().ToString("N") + ".sh")
    try {
        [IO.File]::WriteAllText($remoteScript, ($remote -replace "`r`n", "`n" -replace "`r", ""), [Text.Encoding]::ASCII)
        & scp $remoteScript "${sshTarget}:/tmp/clipman-server-deploy.sh"
        if ($LASTEXITCODE -ne 0) {
            Fail "Could not copy live Clipman Server deploy script to $sshTarget."
        }

        & ssh $sshTarget 'bash /tmp/clipman-server-deploy.sh; status=$?; rm -f /tmp/clipman-server-deploy.sh; exit $status'
        if ($LASTEXITCODE -ne 0) {
            Fail "Live Clipman Server deployment or health check failed on $sshTarget."
        }
    }
    finally {
        Remove-Item -LiteralPath $remoteScript -Force -ErrorAction SilentlyContinue
    }

    Write-Host "Deployed live Clipman Server to ${sshTarget}:${remoteDir}"
}

function Invoke-RemoteInteractiveStartSmoke {
    $computerName = $env:CLIPMAN_REMOTE_START_HOST
    if ([string]::IsNullOrWhiteSpace($computerName)) {
        Write-Host 'Remote interactive start smoke skipped because CLIPMAN_REMOTE_START_HOST was not set.'
        return
    }

    $scriptPath = $env:CLIPMAN_REMOTE_START_SCRIPT
    if ([string]::IsNullOrWhiteSpace($scriptPath)) {
        $scriptPath = Join-Path $repoRoot 'tools\Start-ClipmanInteractive.ps1'
    }

    Assert-Exists $scriptPath 'Remote interactive Clipman launcher script'

    $arguments = @(
        '-ExecutionPolicy', 'Bypass',
        '-File', $scriptPath,
        '-ComputerName', $computerName
    )

    if (![string]::IsNullOrWhiteSpace($env:CLIPMAN_REMOTE_START_EXE)) {
        $arguments += @('-ExecutablePath', $env:CLIPMAN_REMOTE_START_EXE)
    }
    if (![string]::IsNullOrWhiteSpace($env:CLIPMAN_REMOTE_START_USER)) {
        $arguments += @('-UserId', $env:CLIPMAN_REMOTE_START_USER)
    }

    Write-Host "Checking remote interactive Clipman start on $computerName."
    & powershell @arguments
    if ($LASTEXITCODE -ne 0) {
        Fail "Remote interactive Clipman start failed on $computerName."
    }
}

function Read-AppVersion {
    $exe = Join-Path $portable 'clipman.exe'
    Assert-Exists $exe 'Portable executable for version read'
    $version = (Get-Item -LiteralPath $exe).VersionInfo.ProductVersion
    if ([string]::IsNullOrWhiteSpace($version)) {
        $version = (Get-Item -LiteralPath $exe).VersionInfo.FileVersion
    }
    if ([string]::IsNullOrWhiteSpace($version)) {
        Fail 'Could not read Clipman version from portable executable.'
    }
    return $version.Trim()
}

function Read-AppFileVersion {
    $exe = Join-Path $portable 'clipman.exe'
    Assert-Exists $exe 'Portable executable for file version read'
    $version = (Get-Item -LiteralPath $exe).VersionInfo.FileVersion
    if ([string]::IsNullOrWhiteSpace($version)) {
        Fail 'Could not read Clipman file version from portable executable.'
    }
    return $version.Trim()
}

function Read-WindowsBuildStamp {
    $buildInfo = Join-Path $repoRoot 'src\BuildInfo.cs'
    Assert-Exists $buildInfo 'Windows build stamp source'
    $text = Get-Content -LiteralPath $buildInfo -Raw -Encoding UTF8
    $match = [regex]::Match($text, 'BuildStampUtcMs\s*=\s*(?<stamp>\d+)L')
    if (!$match.Success) {
        Fail 'Could not read Windows BuildStampUtcMs from src\BuildInfo.cs.'
    }
    return $match.Groups['stamp'].Value
}

function Get-ZipEntry($zip, [string]$entryName) {
    $normalized = $entryName -replace '\\', '/'
    return $zip.Entries | Where-Object {
        ($_.FullName -replace '\\', '/') -eq $normalized
    } | Select-Object -First 1
}

function Assert-ZipEntry($zip, [string]$entryName, [string]$description) {
    $entry = Get-ZipEntry $zip $entryName
    if ($null -eq $entry) {
        Fail "$description is missing from Mac release ZIP: $entryName"
    }
    return $entry
}

function Read-ZipEntryText($zip, [string]$entryName, [string]$description) {
    $entry = Assert-ZipEntry $zip $entryName $description
    $stream = $entry.Open()
    try {
        $reader = [IO.StreamReader]::new($stream, [Text.Encoding]::UTF8, $true)
        try {
            return $reader.ReadToEnd()
        }
        finally {
            $reader.Dispose()
        }
    }
    finally {
        $stream.Dispose()
    }
}

function Assert-ZipTextMatches($zip, [string]$entryName, [string]$pattern, [string]$description) {
    $text = Read-ZipEntryText $zip $entryName $description
    if ($text -notmatch $pattern) {
        Fail "$description does not match expected content in Mac release ZIP."
    }
}

function Assert-ZipEntryTextEquals($zip, [string]$leftEntryName, [string]$rightEntryName, [string]$description) {
    $leftText = Read-ZipEntryText $zip $leftEntryName $description
    $rightText = Read-ZipEntryText $zip $rightEntryName $description
    if ($leftText -ne $rightText) {
        Fail "$description differs between '$leftEntryName' and '$rightEntryName'."
    }
}

function Get-LatestInputFile([string[]]$paths) {
    $files = @()
    foreach ($path in $paths) {
        if (!(Test-Path -LiteralPath $path)) {
            continue
        }
        $item = Get-Item -LiteralPath $path -Force
        if ($item.PSIsContainer) {
            $files += @(Get-ChildItem -LiteralPath $path -Recurse -File -Force | Where-Object {
                $_.FullName -notmatch '\\(\.build|\.swiftpm|build|dist)\\'
            })
        } else {
            $files += $item
        }
    }

    return $files | Sort-Object LastWriteTimeUtc -Descending | Select-Object -First 1
}

function Assert-MacReleaseAsset([string]$expectedVersion) {
    if ($SkipMacReleaseAsset) {
        Write-Host 'Mac release asset parity check skipped explicitly.'
        return
    }

    Write-Host 'Checking Mac release asset parity.'
    $expectedBundleVersion = Read-AppFileVersion
    $expectedBuildStamp = Read-WindowsBuildStamp
    $macZip = Join-Path $repoRoot "ClipmanMac\dist\ClipmanMac-$expectedVersion.zip"
    Assert-Exists $macZip 'Versioned Mac release ZIP'

    $zipItem = Get-Item -LiteralPath $macZip
    $latestInput = Get-LatestInputFile @(
        (Join-Path $repoRoot 'ClipmanMac\Package.swift'),
        (Join-Path $repoRoot 'ClipmanMac\Sources'),
        (Join-Path $repoRoot 'ClipmanMac\Scripts'),
        (Join-Path $repoRoot 'Manual.html'),
        (Join-Path $repoRoot 'LICENSE.txt'),
        (Join-Path $repoRoot 'src\AssemblyInfo.cs'),
        (Join-Path $repoRoot 'Assets\sounds'),
        (Join-Path $repoRoot 'ClipmanMac\Sources\Clipman\Resources\sounds')
    )
    if ($null -ne $latestInput -and $latestInput.LastWriteTimeUtc -gt $zipItem.LastWriteTimeUtc.AddSeconds(2)) {
        Fail "Mac release ZIP is stale. Newer input: $($latestInput.FullName) at $($latestInput.LastWriteTimeUtc.ToString('u')); ZIP: $macZip at $($zipItem.LastWriteTimeUtc.ToString('u'))."
    }

    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $zip = [System.IO.Compression.ZipFile]::OpenRead($macZip)
    try {
        Assert-ZipEntry $zip 'Clipman.app/Contents/Info.plist' 'Mac app Info.plist' | Out-Null
        Assert-ZipEntry $zip 'Clipman.app/Contents/Resources/Manual.html' 'Bundled Mac manual' | Out-Null
        Assert-ZipEntry $zip 'Clipman.app/Contents/Resources/LICENSE.txt' 'Bundled Mac license' | Out-Null
        foreach ($sound in @('copy.wav', 'exclude.wav', 'off.wav', 'on.wav', 'remote.wav', 'skip.wav')) {
            Assert-ZipEntry $zip "Clipman.app/Contents/Resources/sounds/$sound" "Bundled Mac sound $sound" | Out-Null
        }

        Assert-ZipTextMatches $zip 'Clipman.app/Contents/Info.plist' "<key>CFBundleShortVersionString</key>\s*<string>$([regex]::Escape($expectedVersion))</string>" 'Mac short version'
        Assert-ZipTextMatches $zip 'Clipman.app/Contents/Info.plist' "<key>CFBundleVersion</key>\s*<string>$([regex]::Escape($expectedBundleVersion))</string>" 'Mac bundle version'
        Assert-ZipTextMatches $zip 'Clipman.app/Contents/Info.plist' "<key>ClipmanBuildStampUtcMs</key>\s*<string>$([regex]::Escape($expectedBuildStamp))</string>" 'Mac build stamp parity'

        $rootManual = Get-Content -LiteralPath (Join-Path $repoRoot 'Manual.html') -Raw -Encoding UTF8
        $zipManual = Read-ZipEntryText $zip 'Clipman.app/Contents/Resources/Manual.html' 'Bundled Mac manual'
        if ($zipManual -ne $rootManual) {
            Fail 'Bundled Mac manual does not match root Manual.html.'
        }

        $rootLicense = Get-Content -LiteralPath (Join-Path $repoRoot 'LICENSE.txt') -Raw -Encoding UTF8
        $zipLicense = Read-ZipEntryText $zip 'Clipman.app/Contents/Resources/LICENSE.txt' 'Bundled Mac license'
        if ($zipLicense -ne $rootLicense) {
            Fail 'Bundled Mac license does not match root LICENSE.txt.'
        }
    }
    finally {
        $zip.Dispose()
    }
}

function Invoke-SshCapture([string]$target, [string]$command) {
    $output = & ssh $target $command 2>&1
    return [pscustomobject]@{
        ExitCode = $LASTEXITCODE
        Output = ($output -join "`n")
    }
}

function Assert-InstalledMacApp([string]$expectedVersion) {
    if ($SkipInstalledMacAppCheck) {
        Write-Host 'Installed Mac app parity check skipped explicitly.'
        return
    }

    $target = if ([string]::IsNullOrWhiteSpace($env:CLIPMAN_MAC_SSH)) { 'mac' } else { $env:CLIPMAN_MAC_SSH }
    $probe = Invoke-SshCapture $target 'test -d /Applications/Clipman.app'
    if ($probe.ExitCode -ne 0) {
        if ($RequireMacReleaseAsset) {
            Fail "Installed Mac app parity check required but /Applications/Clipman.app was not found on $target."
        }
        Write-Host "Installed Mac app not found on $target, skipping installed-app parity check."
        return
    }

    Write-Host "Checking installed Mac app parity on $target."
    $expectedBundleVersion = Read-AppFileVersion
    $expectedBuildStamp = Read-WindowsBuildStamp
    $script = @"
set -e
APP="/Applications/Clipman.app"
/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "`$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "`$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Print :ClipmanBuildStampUtcMs' "`$APP/Contents/Info.plist"
pgrep -fl '/Applications/Clipman.app/Contents/MacOS/Clipman' | head -n 1 || true
"@
    $result = Invoke-SshCapture $target $script
    if ($result.ExitCode -ne 0) {
        Fail "Could not inspect installed Mac app on $target. $($result.Output)"
    }

    $lines = @($result.Output -split "`n" | Where-Object { $_ -ne $null })
    if ($lines.Count -lt 4) {
        Fail "Installed Mac app inspection did not return version, build, stamp, and process lines. Output: $($result.Output)"
    }

    $actualVersion = $lines[0].Trim()
    $actualBundleVersion = $lines[1].Trim()
    $actualBuildStamp = $lines[2].Trim()
    $processLine = $lines[3].Trim()
    if ($actualVersion -ne $expectedVersion) {
        Fail "Installed Mac app version is stale. Expected $expectedVersion, got $actualVersion."
    }
    if ($actualBundleVersion -ne $expectedBundleVersion) {
        Fail "Installed Mac app bundle version is stale. Expected $expectedBundleVersion, got $actualBundleVersion."
    }
    if ($actualBuildStamp -ne $expectedBuildStamp) {
        Fail "Installed Mac app build stamp is stale. Expected $expectedBuildStamp, got $actualBuildStamp."
    }
    if ($processLine -notmatch '/Applications/Clipman\.app/Contents/MacOS/Clipman') {
        Fail "Installed Mac app is not the running Clipman process. Output: $($result.Output)"
    }
}

function New-PortableZip([string]$zipPath) {
    if (Test-Path -LiteralPath $zipPath) {
        Remove-Item -LiteralPath $zipPath -Force
    }
    $items = Get-ChildItem -LiteralPath $portable -Force
    $lastError = $null
    for ($attempt = 1; $attempt -le 20; $attempt++) {
        try {
            Compress-Archive -LiteralPath $items.FullName -DestinationPath $zipPath -CompressionLevel Optimal
            return
        }
        catch {
            $lastError = $_
            Remove-Item -LiteralPath $zipPath -Force -ErrorAction SilentlyContinue
            Start-Sleep -Milliseconds 500
        }
    }

    throw $lastError
}

function Set-SmokeSettings([string]$appDir) {
    $settingsDir = Join-Path $appDir 'Settings'
    $logs = Join-Path $appDir 'Logs'
    New-Item -ItemType Directory -Force -Path $settingsDir,$logs | Out-Null
    $sentinel = 'clipman-update-smoke-' + [Guid]::NewGuid().ToString('N')
    $settings = [ordered]@{
        ShowHistoryHotkey = 'Ctrl+Alt+\'
        ToggleActiveHotkey = 'Ctrl+Alt+`'
        RemoveDuplicates = $true
        SoundsEnabled = $false
        SaveListPosition = $true
        Active = $true
        DatabasePath = (Join-Path $settingsDir 'clipman-history.clipdb')
        UseDefaultDatabasePath = $true
        LastSelectedIndex = -1
        LastSelectedTab = 0
        LastPreferencesTab = 0
        MaxHistoryEntries = 1000
        MaxHistoryDays = 0
        IgnoredProcesses = @()
        SortMode = 'LastUsed'
        SortDescending = $true
        SendToEnabled = $false
        ShowHistoryAfterSendTo = $false
        GroupFilter = $sentinel
        DuplicateMode = 'MoveToTop'
        AutoGroupByApp = $true
        AutoRemoveUrlTracking = $false
        RunAtStartup = $false
        UpdateCheckFrequency = 'Startup'
        InstallUpdatesSilently = $true
        DatabaseEncryptionEnabled = $false
        ProtectedDatabasePassword = ''
    }
    $settings | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $settingsDir "$env:COMPUTERNAME-settings.json") -Encoding UTF8
    Set-Content -LiteralPath (Join-Path $logs 'smoke-preserve.log') -Value $sentinel -Encoding UTF8
    Assert-SmokeSettingsCannotPrompt $appDir
    return $sentinel
}

function Assert-SmokeSettingsCannotPrompt([string]$appDir) {
    $settingsPath = Join-Path (Join-Path $appDir 'Settings') "$env:COMPUTERNAME-settings.json"
    $settings = Get-Content -LiteralPath $settingsPath -Raw | ConvertFrom-Json
    $databasePath = [string]$settings.DatabasePath
    $useDefault = [bool]$settings.UseDefaultDatabasePath
    if (!$useDefault -and !(Test-Path -LiteralPath $databasePath)) {
        Fail "Smoke settings would trigger an interactive missing-database prompt: $databasePath"
    }
}

function Assert-SmokeUpdateTarget([string]$appDir, [string]$sentinel, [string]$expectedVersion, [string]$label) {
    $exe = Join-Path $appDir 'clipman.exe'
    Assert-Exists $exe "$label executable"
    $actualVersion = (Get-Item -LiteralPath $exe).VersionInfo.ProductVersion
    if ($actualVersion -ne $expectedVersion) {
        Fail "$label executable version is $actualVersion, expected $expectedVersion."
    }
    Assert-Exists (Join-Path $appDir 'Settings') "$label preserved Settings folder"
    Assert-Exists (Join-Path $appDir "Settings\$env:COMPUTERNAME-settings.json") "$label preserved machine settings"
    Assert-Exists (Join-Path $appDir 'Logs\smoke-preserve.log') "$label preserved log file"
    Assert-NotExists (Join-Path $appDir 'README.md') "$label stale README"
    Assert-NotExists (Join-Path $appDir 'Update Temp') "$label legacy update temp"
    Assert-NotExists (Join-Path $appDir 'Update Backups') "$label legacy update backups"
    Assert-NotExists (Join-Path $appDir 'Backups') "$label app-root update backups"
    Assert-NotExists (Join-Path $appDir 'sounds\sounds') "$label nested sounds folder"
    Assert-NoFactorySoundBackups $appDir $label
    $settingsText = Get-Content -LiteralPath (Join-Path $appDir "Settings\$env:COMPUTERNAME-settings.json") -Raw
    if ($settingsText -notmatch [regex]::Escape($sentinel)) {
        Fail "$label did not preserve smoke sentinel settings."
    }
    $logText = Get-Content -LiteralPath (Join-Path $appDir 'Logs\smoke-preserve.log') -Raw
    if ($logText -notmatch [regex]::Escape($sentinel)) {
        Fail "$label did not preserve smoke sentinel log."
    }
}

function Assert-NoFactorySoundBackups([string]$appDir, [string]$label) {
    foreach ($root in @((Join-Path $appDir 'Backups\Updates'), (Join-Path $appDir 'Update Backups'))) {
        if (!(Test-Path -LiteralPath $root)) {
            continue
        }

        $matches = @(
            Get-ChildItem -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue |
                Where-Object { $_.Name -like 'Previous-sounds*' }
        )
        if ($matches.Count -gt 0) {
            Fail "$label left factory sound update backups: $(@($matches | ForEach-Object { $_.FullName }) -join '; ')"
        }
    }
}

function Invoke-LocalUpdaterSmoke([string]$expectedVersion) {
    Write-Host "Running local updater smoke."
    $root = Join-Path ([IO.Path]::GetTempPath()) ('clipman-local-update-smoke-' + [Guid]::NewGuid().ToString('N'))
    $target = Join-Path $root 'target'
    $zip = Join-Path $root 'Clipman-update.zip'
    $temp = Join-Path $root 'updater-temp'
    New-Item -ItemType Directory -Force -Path $target,$temp | Out-Null
    try {
        Copy-Item -LiteralPath (Get-ChildItem -LiteralPath $portable -Force).FullName -Destination $target -Recurse -Force
        Set-Content -LiteralPath (Join-Path $target 'README.md') -Value 'stale file should be removed' -Encoding UTF8
        New-Item -ItemType Directory -Force -Path (Join-Path $target 'Update Temp\old'),(Join-Path $target 'Update Backups\old') | Out-Null
        Set-Content -LiteralPath (Join-Path $target 'Update Temp\old\temp.txt') -Value 'old temp' -Encoding UTF8
        Set-Content -LiteralPath (Join-Path $target 'Update Backups\old\backup.txt') -Value 'old backup' -Encoding UTF8
        $staleSoundBackup = Join-Path $target 'Backups\Updates\old-sounds'
        New-Item -ItemType Directory -Force -Path $staleSoundBackup | Out-Null
        Set-Content -LiteralPath (Join-Path $staleSoundBackup 'Previous-sounds.zip') -Value 'stale factory sound backup' -Encoding UTF8
        $sentinel = Set-SmokeSettings $target
        New-PortableZip $zip
        $updater = Join-Path $portable 'clipman.exe'
        $targetExe = Join-Path $target 'clipman.exe'
        $updateUrl = ([Uri]$zip).AbsoluteUri
        $arguments = @(
            '--apply-update',
            '--update-url', ('"' + $updateUrl + '"'),
            '--update-target', ('"' + $target + '"'),
            '--update-exe', ('"' + $targetExe + '"'),
            '--update-temp', ('"' + $temp + '"'),
            '--update-wait-pid', '0',
            '--update-no-restart'
        ) -join ' '
        $process = Start-Process -FilePath $updater -ArgumentList $arguments -WorkingDirectory $repoRoot -WindowStyle Hidden -Wait -PassThru
        if ($process.ExitCode -ne 0) {
            Fail "Local updater smoke exited with code $($process.ExitCode)."
        }
        Assert-NotExists (Join-Path $target 'Logs\Updater.log') 'Local updater smoke error log'
        Assert-SmokeUpdateTarget $target $sentinel $expectedVersion 'Local updater smoke'
    }
    finally {
        Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
    }
}

function Get-GitHubReleases {
    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor 3072
    } catch {
    }
    $client = New-Object Net.WebClient
    $client.Headers['User-Agent'] = 'Clipman smoke test'
    $json = $client.DownloadString('https://api.github.com/repos/OnjLouis/Clipman/releases?per_page=100')
    $items = $json | ConvertFrom-Json
    foreach ($item in $items) {
        Write-Output $item
    }
}

function Invoke-GitHubJsonArray([string]$uri, [hashtable]$headers) {
    $items = Invoke-RestMethod -Uri $uri -Headers $headers
    foreach ($item in $items) {
        Write-Output $item
    }
}

function Resolve-PreviousGitHubRelease([string]$currentVersion) {
    $current = [Version]$currentVersion
    $candidates = @()
    foreach ($release in Get-GitHubReleases) {
        $tag = if ($release.tag_name) { [string]$release.tag_name } else { '' }
        $text = $tag.Trim()
        if ($text -notmatch '^[vV]?(\d+(?:\.\d+){1,3})$') {
            continue
        }
        $text = $Matches[1]
        $parsed = $null
        if (![Version]::TryParse($text, [ref]$parsed)) {
            continue
        }
        if ($parsed -lt $current) {
            $asset = @(@($release.assets) | Where-Object { $_.name -match '^Clipman-.*\.zip$' } | Select-Object -First 1)
            if ($asset.Count -gt 0) {
                $candidates += [pscustomobject]@{ Version = $parsed; Text = $text; Release = $release; Asset = $asset[0] }
            }
        }
    }
    $previous = @($candidates | Sort-Object Version -Descending | Select-Object -First 1)
    if ($previous.Count -eq 0) {
        $seen = @()
        foreach ($release in Get-GitHubReleases) {
            $assetNames = @(@($release.assets) | ForEach-Object { $_.name }) -join ', '
            $seen += "$($release.tag_name): $assetNames"
        }
        Fail "Could not find a previous GitHub release ZIP before $currentVersion. Seen releases: $($seen -join '; ')"
    }
    return $previous[0]
}

function Invoke-PostPublishUpdateSmoke([string]$expectedVersion) {
    if (!$RunPostPublishUpdateSmoke) {
        return
    }

    $previous = Resolve-PreviousGitHubRelease $expectedVersion
    Write-Host "Running post-publish updater smoke: $($previous.Text) -> $expectedVersion."

    $root = Join-Path ([IO.Path]::GetTempPath()) ('clipman-github-update-smoke-' + [Guid]::NewGuid().ToString('N'))
    $previousZip = Join-Path $root ('Clipman-' + $previous.Text + '.zip')
    $target = Join-Path $root 'target'
    New-Item -ItemType Directory -Force -Path $root,$target | Out-Null

    $startedProcess = $null
    try {
        $client = New-Object Net.WebClient
        $client.Headers['User-Agent'] = 'Clipman smoke test'
        $client.DownloadFile([string]$previous.Asset.browser_download_url, $previousZip)
        Expand-Archive -LiteralPath $previousZip -DestinationPath $target -Force
        $sentinel = Set-SmokeSettings $target
        New-Item -ItemType Directory -Force -Path (Join-Path $target 'Update Temp\old'),(Join-Path $target 'Update Backups\old') | Out-Null
        Set-Content -LiteralPath (Join-Path $target 'Update Temp\old\temp.txt') -Value 'old temp' -Encoding UTF8
        Set-Content -LiteralPath (Join-Path $target 'Update Backups\old\backup.txt') -Value 'old backup' -Encoding UTF8
        $staleSoundBackup = Join-Path $target 'Backups\Updates\old-sounds'
        New-Item -ItemType Directory -Force -Path $staleSoundBackup | Out-Null
        Set-Content -LiteralPath (Join-Path $staleSoundBackup 'Previous-sounds.zip') -Value 'stale factory sound backup' -Encoding UTF8

        if (Get-Process clipman -ErrorAction SilentlyContinue) {
            if (![string]::IsNullOrWhiteSpace($LivePath) -and (Test-Path -LiteralPath (Join-Path $LivePath 'clipman.exe'))) {
                & (Join-Path $LivePath 'clipman.exe') --close | Out-Null
            }
            else {
                & (Join-Path $target 'clipman.exe') --close | Out-Null
            }
            Start-Sleep -Seconds 3
        }

        $exe = Join-Path $target 'clipman.exe'
        $startedProcess = Start-Process -FilePath $exe -WorkingDirectory $target -WindowStyle Hidden -PassThru
        $deadline = (Get-Date).AddMinutes(4)
        do {
            Start-Sleep -Seconds 3
            $actualVersion = if (Test-Path -LiteralPath $exe) { (Get-Item -LiteralPath $exe).VersionInfo.ProductVersion } else { '' }
            if ($actualVersion -eq $expectedVersion) {
                break
            }
        } while ((Get-Date) -lt $deadline)

        $cleanupDeadline = (Get-Date).AddSeconds(30)
        while ((Get-Date) -lt $cleanupDeadline -and (Test-Path -LiteralPath (Join-Path $target 'Backups'))) {
            Start-Sleep -Milliseconds 500
        }

        & $exe --close | Out-Null
        Start-Sleep -Seconds 2
        Assert-SmokeUpdateTarget $target $sentinel $expectedVersion 'Post-publish updater smoke'
    }
    finally {
        try {
            $exe = Join-Path $target 'clipman.exe'
            if (Test-Path -LiteralPath $exe) { & $exe --close | Out-Null }
        } catch {
        }
        if ($startedProcess -ne $null) {
            try {
                $current = Get-Process -Id $startedProcess.Id -ErrorAction SilentlyContinue
                if ($current -ne $null -and (Is-SmokePath $current.Path)) {
                    $current.CloseMainWindow() | Out-Null
                    if (!$current.WaitForExit(2000)) {
                        $current.Kill()
                        $current.WaitForExit(5000)
                    }
                }
            }
            catch {
            }
        }
        Stop-SmokeClipmanProcesses
        Start-Sleep -Seconds 1
        Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
    }
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

function Invoke-LinuxServerSmoke {
    $python = Get-Command python -ErrorAction SilentlyContinue
    if ($null -eq $python) {
        Fail 'Python is required for the Linux Clipman Server smoke test.'
    }

    $root = Join-Path $env:TEMP ('clipman-linux-server-smoke-' + [Guid]::NewGuid().ToString('N'))
    $config = Join-Path $root 'Settings\clipman-server-settings.json'
    $dataRoot = Join-Path $root 'Data'
    $databasePath = Join-Path $dataRoot 'clipman-history.clipdb'
    $logPath = Join-Path $root 'Logs\clipman-server.log'
    $stdout = Join-Path $root 'stdout.txt'
    $stderr = Join-Path $root 'stderr.txt'
    $port = 49152 + (Get-Random -Minimum 0 -Maximum 12000)
    $token = 'smoke-token-' + [Guid]::NewGuid().ToString('N')
    $script = Join-Path $repoRoot 'ClipmanServerLinux\clipman_server.py'
    New-Item -ItemType Directory -Path (Split-Path -Parent $config), $dataRoot, (Split-Path -Parent $logPath) -Force | Out-Null

    $firstRunConfig = Join-Path $root 'FirstRun\Settings\clipman-server-settings.json'
    $firstRunConnection = Join-Path (Split-Path -Parent $firstRunConfig) 'clipman-server-connection.txt'
    & $python.Source $script --config $firstRunConfig --host 127.0.0.1 --write-connection-info | Out-Null
    if ($LASTEXITCODE -ne 0) {
        Fail 'Linux Clipman Server could not write first-run connection details.'
    }
    Assert-Exists $firstRunConnection 'Linux Clipman Server first-run connection details file'
    $connectionText = Get-Content -LiteralPath $firstRunConnection -Raw
    if ($connectionText -notmatch 'Server address:\s+clipman://127\.0\.0\.1:\d+' -or
        $connectionText -notmatch 'Port:\s+\d+' -or
        $connectionText -notmatch 'Token:\s+\S+') {
        Fail 'Linux Clipman Server connection details file did not contain server address, port, and token.'
    }
    Remove-Item -LiteralPath $firstRunConnection -Force
    & $python.Source $script --config $firstRunConfig --show-token | Out-Null
    if ($LASTEXITCODE -ne 0) {
        Fail 'Linux Clipman Server could not read token after connection details deletion.'
    }
    Assert-NotExists $firstRunConnection 'Linux Clipman Server connection details file should stay deleted unless explicitly recreated'
    & $python.Source $script --config $firstRunConfig --write-connection-info | Out-Null
    if ($LASTEXITCODE -ne 0) {
        Fail 'Linux Clipman Server could not intentionally recreate connection details.'
    }
    Assert-Exists $firstRunConnection 'Linux Clipman Server explicitly recreated connection details file'

    @{
        Host = '127.0.0.1'
        Port = $port
        DatabasePath = $databasePath
        AuthToken = $token
        LogPath = $logPath
        BackupIntervalMinutes = 0
        BackupRetentionHours = 24
        MaxBackups = 48
        CreateBackupBeforeEveryUpload = $false
    } | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $config -Encoding UTF8

    $proc = $null
    try {
        $proc = Start-Process -FilePath $python.Source -ArgumentList @($script, '--config', $config) -PassThru -WindowStyle Hidden -RedirectStandardOutput $stdout -RedirectStandardError $stderr
        $base = "http://127.0.0.1:$port"
        $ready = $false
        for ($i = 0; $i -lt 40; $i++) {
            try {
                Invoke-WebRequest -UseBasicParsing -Uri "$base/api/v1/health" -Method Get -TimeoutSec 2 | Out-Null
                $ready = $true
                break
            }
            catch {
                Start-Sleep -Milliseconds 250
            }
        }
        if (!$ready) {
            $exitText = if ($proc.HasExited) { "Exited with code $($proc.ExitCode)." } else { 'Still running.' }
            $stdoutText = if (Test-Path -LiteralPath $stdout) { Get-Content -LiteralPath $stdout -Raw } else { '' }
            $stderrText = if (Test-Path -LiteralPath $stderr) { Get-Content -LiteralPath $stderr -Raw } else { '' }
            $logText = if (Test-Path -LiteralPath $logPath) { Get-Content -LiteralPath $logPath -Raw } else { '' }
            Fail "Linux Clipman Server smoke did not become ready. $exitText Stdout: $stdoutText Stderr: $stderrText Log: $logText"
        }

        $headers = @{ Authorization = "Bearer $token" }
        $id1 = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
        $id2 = 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb'
        Invoke-WebRequest -UseBasicParsing -Uri "$base/api/v1/database/$id1" -Method Put -Headers $headers -Body ([Text.Encoding]::UTF8.GetBytes('database-one')) -ContentType 'application/octet-stream' | Out-Null
        Invoke-WebRequest -UseBasicParsing -Uri "$base/api/v1/database/$id2" -Method Put -Headers $headers -Body ([Text.Encoding]::UTF8.GetBytes('database-two')) -ContentType 'application/octet-stream' | Out-Null

        $db1 = Join-Path $dataRoot "Databases\$id1\clipman-history.clipdb"
        $db2 = Join-Path $dataRoot "Databases\$id2\clipman-history.clipdb"
        Assert-Exists $db1 'Linux Clipman Server first database bucket'
        Assert-Exists $db2 'Linux Clipman Server second database bucket'
        if ((Get-Content -LiteralPath $db1 -Raw) -ne 'database-one') { Fail 'Linux Clipman Server first bucket stored wrong data.' }
        if ((Get-Content -LiteralPath $db2 -Raw) -ne 'database-two') { Fail 'Linux Clipman Server second bucket stored wrong data.' }

        $head1 = Invoke-WebRequest -UseBasicParsing -Uri "$base/api/v1/database/$id1" -Method Head -Headers $headers
        $head2 = Invoke-WebRequest -UseBasicParsing -Uri "$base/api/v1/database/$id2" -Method Head -Headers $headers
        if ([string]::IsNullOrWhiteSpace($head1.Headers['X-Clipman-Revision']) -or [string]::IsNullOrWhiteSpace($head2.Headers['X-Clipman-Revision'])) {
            Fail 'Linux Clipman Server did not return database revisions.'
        }

        Assert-Exists $logPath 'Linux Clipman Server configured log file'
        $logText = Get-Content -LiteralPath $logPath -Raw
        if ($logText.Contains($id1) -or $logText.Contains($id2)) {
            Fail 'Linux Clipman Server log exposed database IDs.'
        }
        if ($logText -notmatch '<database-id>') {
            Fail 'Linux Clipman Server log did not redact database API paths.'
        }

        $listJson = & $python.Source $script --config $config --list-databases-json
        if ($LASTEXITCODE -ne 0) {
            Fail 'Linux Clipman Server list-databases-json command failed.'
        }
        $databaseList = ($listJson -join "`n") | ConvertFrom-Json
        $databaseIds = @($databaseList.Databases | ForEach-Object { $_.DatabaseId })
        if (!($databaseIds -contains $id1) -or !($databaseIds -contains $id2)) {
            Fail 'Linux Clipman Server database list did not include both smoke database buckets.'
        }
        $firstInfo = @($databaseList.Databases | Where-Object { $_.DatabaseId -eq $id1 })[0]
        if ($firstInfo.LastSeenUnixMs -le 0 -or $firstInfo.LastWrittenUnixMs -le 0) {
            Fail 'Linux Clipman Server database metadata did not record last seen and last written timestamps.'
        }

        $oldErrorActionPreference = $ErrorActionPreference
        $ErrorActionPreference = 'Continue'
        try {
            $blockedDelete = & $python.Source $script --config $config --delete-database $id2 --confirm 2>&1
            $blockedDeleteExitCode = $LASTEXITCODE
        }
        finally {
            $ErrorActionPreference = $oldErrorActionPreference
        }
        if ($blockedDeleteExitCode -eq 0) {
            Fail 'Linux Clipman Server delete-database moved a recently active bucket without --force-recent.'
        }
        if (($blockedDelete -join "`n") -notmatch 'recently active database bucket') {
            Fail 'Linux Clipman Server delete-database did not explain the 24-hour recent-activity guard.'
        }
        Assert-Exists $db2 'Linux Clipman Server recent database bucket should remain after guarded delete'

        & $python.Source $script --config $config --delete-database $id2 --confirm --force-recent | Out-Null
        if ($LASTEXITCODE -ne 0) {
            Fail 'Linux Clipman Server force-recent delete-database command failed.'
        }
        Assert-NotExists $db2 'Linux Clipman Server deleted database bucket should move out of active Databases'
        $deletedMatches = @(Get-ChildItem -LiteralPath (Join-Path $dataRoot 'DeletedDatabases') -Directory -ErrorAction SilentlyContinue | Where-Object { $_.Name -like "$id2*" })
        if ($deletedMatches.Count -ne 1) {
            Fail 'Linux Clipman Server did not move deleted database bucket to DeletedDatabases.'
        }
    }
    finally {
        if ($proc -ne $null -and !$proc.HasExited) {
            try { $proc.Kill() } catch { }
            try { $proc.WaitForExit(5000) | Out-Null } catch { }
        }
        Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
    }
}

function Assert-ServerSmokeSurface {
    Assert-TextMatches (Join-Path $repoRoot 'Build-ServerBundle.ps1') 'ClipmanServer-\$version\.zip' 'Separate Clipman Server bundle builder names server ZIP by app version'
    Assert-TextMatches (Join-Path $repoRoot 'ClipmanServerMac\Scripts\package-combined-server.sh') 'clipman_server\.py' 'Separate Clipman Server bundle includes Python reference server'
    Assert-TextMatches (Join-Path $repoRoot 'ClipmanServerMac\Scripts\package-combined-server.sh') 'Linux/install-clipman-server\.sh' 'Separate Clipman Server bundle includes Linux installer'
    Assert-TextMatches (Join-Path $repoRoot 'ClipmanServerMac\Scripts\package-combined-server.sh') 'clipman-server-settings\.example\.jsonc' 'Separate Clipman Server bundle includes commented settings example'
    Assert-TextMatches (Join-Path $repoRoot 'Build-ServerBundle.ps1') 'Build-WindowsServerWrapper' 'Separate Clipman Server bundle builds the Windows notification-area wrapper'
    Assert-TextMatches (Join-Path $repoRoot 'Build-ServerBundle.ps1') 'AssemblyInformationalVersion' 'Windows server wrapper build stamps version metadata'
    Assert-TextMatches (Join-Path $repoRoot 'Build-ServerBundle.ps1') 'AssemblyProduct\("Clipman Server"\)' 'Windows server wrapper build stamps product metadata'
    Assert-TextMatches (Join-Path $repoRoot 'ClipmanServerMac\Scripts\package-combined-server.sh') 'Windows/Clipman Server\.exe' 'Separate Clipman Server bundle includes the Windows wrapper app'
    Assert-TextMatches (Join-Path $repoRoot 'Build-ServerBundle.ps1') '/resource:\$serverScript,ClipmanServerWrapper\.clipman_server\.py' 'Windows server wrapper embeds the shared Python server script'
    Assert-TextMatches (Join-Path $repoRoot 'ClipmanServerMac\Scripts\package-combined-server.sh') 'macOS/Clipman Server\.app' 'Separate Clipman Server bundle includes the macOS wrapper app'
    Assert-TextMatches (Join-Path $repoRoot 'Build-ServerBundle.ps1') 'package-combined-server\.sh' 'Windows server bundle build delegates final ZIP creation to macOS so app bundles remain launchable'
    Assert-TextDoesNotMatch (Join-Path $repoRoot 'Build-ServerBundle.ps1') "Join-Path \`$staging 'README\.md'" 'Separate Clipman Server bundle must not ship both README and Manual'
    Assert-TextDoesNotMatch (Join-Path $repoRoot 'ClipmanServerLinux\install-clipman-server.sh') 'README\.md' 'Linux server installer must not copy README into installed runtime'
    Assert-TextMatches (Join-Path $repoRoot 'ClipmanServerLinux\clipman_server.py') 'LOCALAPPDATA' 'Server uses native Windows data and log defaults'
    Assert-TextMatches (Join-Path $repoRoot 'ClipmanServerLinux\clipman_server.py') 'Library.+Application Support.+Clipman Server' 'Server uses native macOS data defaults'
    Assert-TextMatches (Join-Path $repoRoot 'ClipmanServerLinux\clipman_server.py') 'AdvertiseHost' 'Server can advertise a TLS DNS host separately from the bind host'
    Assert-TextMatches (Join-Path $repoRoot 'ClipmanServer\Manual.html') '%LOCALAPPDATA%\\Clipman Server' 'Server manual documents Windows data and log defaults'
    Assert-TextMatches (Join-Path $repoRoot 'ClipmanServer\Manual.html') 'Library/Application Support/Clipman Server' 'Server manual documents macOS data defaults'
    Assert-TextMatches (Join-Path $repoRoot 'ClipmanServer\Manual.html') '--advertise-host' 'Server manual documents advertised host for direct TLS'
    Assert-TextMatches (Join-Path $repoRoot 'ClipmanServer\Manual.html') 'Windows\\Clipman Server\.exe' 'Server manual documents the Windows wrapper app'
    Assert-TextMatches (Join-Path $repoRoot 'ClipmanServer\Manual.html') 'Windows EXE contains the shared server script' 'Server manual explains that Windows users do not need a loose Python script beside the EXE'
    Assert-TextMatches (Join-Path $repoRoot 'ClipmanServer\Manual.html') 'Python 3 must still be installed' 'Server manual explains Windows Python runtime requirement'
    Assert-TextMatches (Join-Path $repoRoot 'ClipmanServer\Manual.html') 'macOS/Clipman Server\.app' 'Server manual documents the macOS wrapper app'
    Assert-TextMatches (Join-Path $repoRoot 'ClipmanServer\Manual.html') 'Run at System Start' 'Server manual documents startup behavior'
    Assert-TextMatches (Join-Path $repoRoot 'ClipmanServer\Manual.html') '<h2 id="updates">Updates</h2>' 'Server manual documents server update behavior'
    Assert-TextMatches (Join-Path $repoRoot 'ClipmanServer\Manual.html') '<h2 id="settings-example">Commented Settings Example</h2>' 'Server manual documents the commented settings example'
    Assert-TextMatches (Join-Path $repoRoot 'ClipmanServer\Manual.html') 'clipman-server-settings\.example\.jsonc' 'Server manual names the commented settings example'
    Assert-TextMatches (Join-Path $repoRoot 'ClipmanServer\clipman-server-settings.example.jsonc') '"Host"' 'Server example config documents Host'
    Assert-TextMatches (Join-Path $repoRoot 'ClipmanServer\clipman-server-settings.example.jsonc') '"AdvertiseHost"' 'Server example config documents AdvertiseHost'
    Assert-TextMatches (Join-Path $repoRoot 'ClipmanServer\clipman-server-settings.example.jsonc') '"AuthToken"' 'Server example config documents AuthToken'
    Assert-TextMatches (Join-Path $repoRoot 'ClipmanServer\clipman-server-settings.example.jsonc') '"CertFile"' 'Server example config documents TLS certificate'
    Assert-TextMatches (Join-Path $repoRoot 'ClipmanServer\clipman-server-settings.example.jsonc') '"BackupIntervalMinutes"' 'Server example config documents backup interval'
    Assert-TextMatches (Join-Path $repoRoot 'ClipmanServer\Manual.html') '--install-update --silent' 'Server manual documents silent server update switch'
    Assert-TextMatches (Join-Path $repoRoot 'README.md') 'Clipman Server has its own update path' 'README documents separate server update path'
    Assert-TextMatches (Join-Path $repoRoot 'ClipmanServerWindows\Program.cs') 'CreateNoWindow = true' 'Windows server wrapper starts Python without a console window'
    Assert-TextMatches (Join-Path $repoRoot 'ClipmanServerWindows\Program.cs') 'NotifyIcon' 'Windows server wrapper runs from the notification area'
    Assert-TextMatches (Join-Path $repoRoot 'ClipmanServerWindows\Program.cs') 'Check for updates' 'Windows server wrapper exposes update checks from the tray menu'
    Assert-TextMatches (Join-Path $repoRoot 'ClipmanServerWindows\Program.cs') '--install-update' 'Windows server wrapper exposes CLI update install switch'
    Assert-TextMatches (Join-Path $repoRoot 'ClipmanServerWindows\Program.cs') 'ClipmanServer-' 'Windows server wrapper searches for the separate server release ZIP'
    Assert-TextDoesNotMatch (Join-Path $repoRoot 'ClipmanServerWindows\Program.cs') '--write-connection-info' 'Windows server wrapper must not start Python with an exit-after-writing command'
    Assert-TextMatches (Join-Path $repoRoot 'ClipmanServerMac\Sources\ClipmanServer\main.swift') 'setActivationPolicy\(\.accessory\)' 'Mac server wrapper does not appear as a normal foreground app'
    Assert-TextMatches (Join-Path $repoRoot 'ClipmanServerMac\Sources\ClipmanServer\main.swift') 'Check for Updates' 'Mac server wrapper exposes update checks from the menu bar'
    Assert-TextMatches (Join-Path $repoRoot 'ClipmanServerMac\Sources\ClipmanServer\main.swift') '--install-update' 'Mac server wrapper exposes CLI update install switch'
    Assert-TextMatches (Join-Path $repoRoot 'ClipmanServerMac\Sources\ClipmanServer\main.swift') 'ClipmanServer-' 'Mac server wrapper searches for the separate server release ZIP'
    Assert-TextDoesNotMatch (Join-Path $repoRoot 'ClipmanServerMac\Sources\ClipmanServer\main.swift') '--write-connection-info' 'Mac server wrapper must not start Python with an exit-after-writing command'
    Assert-TextMatches (Join-Path $repoRoot 'ClipmanServerMac\Scripts\package-release.sh') '<key>LSUIElement</key>' 'Mac server wrapper is packaged as a menu-bar app'
    Assert-TextDoesNotMatch (Join-Path $repoRoot 'Build-ServerBundle.ps1') 'Windows\\Run-ClipmanServer\.cmd' 'Separate Clipman Server bundle must not ship a second normal Windows entry point'
    Assert-TextMatches (Join-Path $repoRoot 'ClipmanServerMac\Scripts\package-combined-server.sh') 'Linux/run-clipman-server\.sh' 'Separate Clipman Server bundle includes Linux launcher'
    Assert-TextDoesNotMatch (Join-Path $repoRoot 'ClipmanServerMac\Scripts\package-combined-server.sh') 'macOS/run-clipman-server\.command' 'Separate Clipman Server bundle must not rely on a macOS terminal launcher'
    Assert-TextMatches (Join-Path $repoRoot 'SmokeTest.ps1') 'Manual\.html\.new' 'Live server deployment includes the HTML manual'
    Assert-TextMatches (Join-Path $repoRoot 'SmokeTest.ps1') 'rm -f README\.md' 'Live server deployment removes stale server README from shipping folder'
    Assert-TextMatches (Join-Path $repoRoot 'ClipmanServer\Manual.html') '<title>Clipman Server Manual</title>' 'Separate server manual exists as HTML'
    Assert-TextMatches (Join-Path $repoRoot 'ClipmanServer\Manual.html') 'same server program is used across platforms' 'Separate server manual documents cross-platform server parity'
    Assert-TextDoesNotMatch (Join-Path $repoRoot 'ClipmanServer\Manual.html') 'reference implementation|experimental native server|repository may contain' 'Separate server manual must not expose development wording'
    Assert-TextMatches (Join-Path $repoRoot 'ClipmanServer\Manual.html') 'clipman-server-connection\.txt' 'Separate server manual documents connection details file'
    Assert-TextMatches (Join-Path $repoRoot 'ClipmanServer\Manual.html') 'sh Linux/install-clipman-server\.sh' 'Separate server manual documents Linux installer'
    Assert-TextMatches (Join-Path $repoRoot 'ClipmanServer\Manual.html') 'Do not manually copy an existing <code>\.clipdb</code>' 'Separate server manual documents safe existing-history bootstrap'
    Assert-NotExists (Join-Path $repoRoot 'ClipmanServer\README.md') 'Duplicate Windows server README in source tree'
    Assert-NotExists (Join-Path $repoRoot 'ClipmanServerLinux\README.md') 'Duplicate Linux server README in source tree'
    Assert-TextMatches (Join-Path $repoRoot 'ClipmanServerLinux\install-clipman-server.sh') '\.local/lib/clipman-server' 'Linux server installer uses user-local application directory'
    Assert-TextMatches (Join-Path $repoRoot 'ClipmanServerLinux\install-clipman-server.sh') '\.local/bin' 'Linux server installer creates user-local launcher'
    Assert-TextMatches (Join-Path $repoRoot 'ClipmanServerLinux\clipman_server.py') 'database_id_from_path' 'Linux Clipman Server validates database-scoped paths'
    Assert-TextMatches (Join-Path $repoRoot 'ClipmanServerLinux\clipman_server.py') 'write_connection_info' 'Linux Clipman Server writes plain text connection details on first run'
    Assert-TextMatches (Join-Path $repoRoot 'ClipmanServerLinux\clipman_server.py') 'clipman-server-connection\.txt' 'Linux Clipman Server names connection details file'
    Assert-TextMatches (Join-Path $repoRoot 'ClipmanServerLinux\clipman_server.py') 'Databases' 'Linux Clipman Server stores password-scoped database buckets'
    Assert-TextMatches (Join-Path $repoRoot 'ClipmanServerLinux\clipman_server.py') 'st_mtime_ns' 'Linux Clipman Server revision uses cheap file metadata for polling'
    Assert-TextMatches (Join-Path $repoRoot 'ClipmanServerLinux\clipman_server.py') 'HEAD /api/v1/database/' 'Linux Clipman Server suppresses routine poll logging'
    Assert-TextMatches (Join-Path $repoRoot 'ClipmanServerLinux\clipman_server.py') 'os\.chmod\(path, 0o700\)' 'Linux Clipman Server creates private data directories where supported'
    Assert-TextMatches (Join-Path $repoRoot 'ClipmanServerLinux\clipman_server.py') 'os\.chmod\(path, 0o600\)' 'Linux Clipman Server creates private settings/database files where supported'
    Assert-TextMatches (Join-Path $repoRoot 'ClipmanServerLinux\clipman_server.py') 'ssl\.SSLContext\(ssl\.PROTOCOL_TLS_SERVER\)' 'Linux Clipman Server supports direct TLS'
    Assert-TextMatches (Join-Path $repoRoot 'ClipmanServerLinux\clipman_server.py') 'AllowInsecureRemote' 'Linux Clipman Server requires an explicit insecure remote override'
    Assert-TextMatches (Join-Path $repoRoot 'ClipmanServerLinux\clipman_server.py') 'RotatingFileHandler' 'Linux Clipman Server writes managed log files'
    Assert-TextMatches (Join-Path $repoRoot 'ClipmanServerLinux\clipman_server.py') 'DATABASE_LOG_PATTERN' 'Linux Clipman Server redacts database IDs from logs'
    Assert-TextMatches (Join-Path $repoRoot 'ClipmanServerLinux\clipman_server.py') 'except KeyboardInterrupt' 'Linux Clipman Server exits cleanly on Ctrl+C'
    Assert-TextMatches (Join-Path $repoRoot 'ClipmanServerLinux\clipman_server.py') 'server\.server_close\(\)' 'Linux Clipman Server closes socket on shutdown'
    Assert-TextMatches (Join-Path $repoRoot 'ClipmanServerLinux\clipman_server.py') 'METADATA_TOUCH_INTERVAL_MS' 'Linux Clipman Server throttles database metadata writes'
    Assert-TextMatches (Join-Path $repoRoot 'ClipmanServerLinux\clipman_server.py') '--list-databases' 'Linux Clipman Server can list database buckets'
    Assert-TextMatches (Join-Path $repoRoot 'ClipmanServerLinux\clipman_server.py') '--list-databases-json' 'Linux Clipman Server can list database buckets as JSON'
    Assert-TextMatches (Join-Path $repoRoot 'ClipmanServerLinux\clipman_server.py') '--delete-database' 'Linux Clipman Server can move a selected database bucket aside'
    Assert-TextMatches (Join-Path $repoRoot 'ClipmanServerLinux\clipman_server.py') '--prune-databases-days' 'Linux Clipman Server has dry-run stale database pruning'
    Assert-TextMatches (Join-Path $repoRoot 'ClipmanServerLinux\clipman_server.py') '--force-recent' 'Linux Clipman Server requires deliberate override for recently active bucket deletion'
    Assert-TextMatches (Join-Path $repoRoot 'ClipmanServerLinux\clipman_server.py') 'DeletedDatabases' 'Linux Clipman Server moves removed buckets to DeletedDatabases'
    Assert-TextMatches (Join-Path $repoRoot 'ClipmanServerLinux\install-clipman-server.sh') 'clipmanserver' 'Linux server installer creates friendly helper command'
    Assert-TextMatches (Join-Path $repoRoot 'ClipmanServerLinux\install-clipman-server.sh') 'clipmanserver start' 'Linux server installer documents helper start command'
    Assert-TextMatches (Join-Path $repoRoot 'ClipmanServerLinux\install-clipman-server.sh') 'list-json' 'Linux server helper exposes JSON database list command'
    Assert-TextMatches (Join-Path $repoRoot 'ClipmanServerLinux\install-clipman-server.sh') 'force-delete' 'Linux server helper exposes deliberate force-delete command'
    Assert-TextMatches (Join-Path $repoRoot 'ClipmanServer\Manual.html') 'Linux Helper Commands' 'Server manual documents Linux helper commands'
    Assert-TextMatches (Join-Path $repoRoot 'ClipmanServer\Manual.html') 'clipmanserver list' 'Server manual documents database list helper command'
    Assert-TextMatches (Join-Path $repoRoot 'ClipmanServer\Manual.html') 'clipmanserver delete' 'Server manual documents database delete helper command'
    Assert-TextMatches (Join-Path $repoRoot 'ClipmanServer\Manual.html') '--list-databases-json' 'Server manual documents JSON database listing'
    Assert-TextMatches (Join-Path $repoRoot 'ClipmanServer\Manual.html') '--prune-databases-days' 'Server manual documents stale database pruning'
    Assert-TextMatches (Join-Path $repoRoot 'ClipmanServer\Manual.html') '24 hours' 'Server manual documents recent database deletion safety guard'
    Assert-TextMatches (Join-Path $repoRoot 'ClipmanServer\Manual.html') 'DeletedDatabases' 'Server manual documents safe deleted bucket holding area'
    Assert-TextMatches (Join-Path $repoRoot 'README.md') 'clipmanserver list' 'README documents Linux database list helper'
    Assert-TextMatches (Join-Path $repoRoot 'README.md') 'force-delete' 'README documents Linux helper force-delete safeguard'
    Assert-TextMatches (Join-Path $repoRoot 'README.md') 'DeletedDatabases' 'README documents safe server bucket cleanup'
    Assert-NotExists (Join-Path $repoRoot 'ClipmanServerLinux\__pycache__') 'Python bytecode cache in server source tree'
    Invoke-LinuxServerSmoke
}

function Assert-ServerBundleZipParity([string]$expectedVersion) {
    $serverZip = Join-Path $repoRoot "release\Server\ClipmanServer-$expectedVersion.zip"
    Assert-Exists $serverZip 'Built Clipman Server release ZIP'
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $zip = [System.IO.Compression.ZipFile]::OpenRead($serverZip)
    try {
        $root = 'ClipmanServer'
        Assert-ZipEntry $zip "$root/clipman_server.py" 'Top-level server script' | Out-Null
        Assert-ZipEntry $zip "$root/Manual.html" 'Top-level server manual' | Out-Null
        Assert-ZipEntry $zip "$root/clipman-server-settings.example.jsonc" 'Commented server settings example' | Out-Null
        Assert-ZipEntry $zip "$root/macOS/Clipman Server.app/Contents/Resources/clipman_server.py" 'Bundled macOS server script' | Out-Null
        Assert-ZipEntry $zip "$root/macOS/Clipman Server.app/Contents/Resources/Manual.html" 'Bundled macOS server manual' | Out-Null
        Assert-ZipEntry $zip "$root/macOS/Clipman Server.app/Contents/Resources/LICENSE.txt" 'Bundled macOS server license' | Out-Null
        Assert-ZipEntryTextEquals $zip "$root/clipman_server.py" "$root/macOS/Clipman Server.app/Contents/Resources/clipman_server.py" 'macOS server app embedded Python script'
        Assert-ZipEntryTextEquals $zip "$root/Manual.html" "$root/macOS/Clipman Server.app/Contents/Resources/Manual.html" 'macOS server app embedded manual'
        Assert-ZipTextMatches $zip "$root/clipman-server-settings.example.jsonc" '"AuthToken"\s*:' 'Commented server settings example AuthToken entry'
        Assert-ZipTextMatches $zip "$root/clipman-server-settings.example.jsonc" '"BackupIntervalMinutes"\s*:' 'Commented server settings example backup interval entry'
    }
    finally {
        $zip.Dispose()
    }
}

function Assert-UniqueWindowsControlMnemonics([string]$path, [string]$description) {
    Assert-Exists $path $description
    $text = Get-Content -LiteralPath $path -Raw
    $matches = [regex]::Matches($text, 'Text\s*=\s*"((?:[^"\\]|\\.)*)"')
    Assert-UniqueMnemonicLabels ($matches | ForEach-Object { $_.Groups[1].Value }) $description
}

function Assert-UniqueWindowsMenuMnemonics([string]$path, [string]$description, [string[]]$MenuNames = @()) {
    Assert-Exists $path $description
    $text = Get-Content -LiteralPath $path -Raw
    $labelsByVariable = @{}

    foreach ($match in [regex]::Matches($text, 'var\s+(?<name>[A-Za-z_][A-Za-z0-9_]*)\s*=\s*new\s+ToolStripMenuItem\("(?<label>(?:[^"\\]|\\.)*)"')) {
        $labelsByVariable[$match.Groups['name'].Value] = $match.Groups['label'].Value
    }

    $menuItems = @{}
    foreach ($match in [regex]::Matches($text, '(?<parent>[A-Za-z_][A-Za-z0-9_]*)\.DropDownItems\.Add\("(?<label>(?:[^"\\]|\\.)*)"')) {
        $parent = $match.Groups['parent'].Value
        if (!$menuItems.ContainsKey($parent)) {
            $menuItems[$parent] = New-Object System.Collections.Generic.List[string]
        }
        $menuItems[$parent].Add($match.Groups['label'].Value)
    }

    foreach ($match in [regex]::Matches($text, '(?<parent>[A-Za-z_][A-Za-z0-9_]*)\.DropDownItems\.Add\((?<child>[A-Za-z_][A-Za-z0-9_]*)\)')) {
        $parent = $match.Groups['parent'].Value
        $child = $match.Groups['child'].Value
        if (!$labelsByVariable.ContainsKey($child)) {
            continue
        }
        if (!$menuItems.ContainsKey($parent)) {
            $menuItems[$parent] = New-Object System.Collections.Generic.List[string]
        }
        $menuItems[$parent].Add($labelsByVariable[$child])
    }

    foreach ($parent in $menuItems.Keys) {
        if ($MenuNames.Count -gt 0 -and !($MenuNames -contains $parent)) {
            continue
        }
        $seen = @{}
        foreach ($label in $menuItems[$parent]) {
            $cleanLabel = ($label -split '\\t')[0]
            $mnemonicMatches = [regex]::Matches($cleanLabel, '&(?!&)([A-Za-z0-9])')
            foreach ($mnemonicMatch in $mnemonicMatches) {
                $key = $mnemonicMatch.Groups[1].Value.ToUpperInvariant()
                if ($seen.ContainsKey($key)) {
                    Fail "$description menu '$parent' has duplicate Alt+$key mnemonic: '$($seen[$key])' and '$cleanLabel'"
                }
                $seen[$key] = $cleanLabel
            }
        }
    }
}

function Assert-UniqueMnemonicLabels([object[]]$labels, [string]$description) {
    $seen = @{}
    foreach ($labelObject in $labels) {
        $label = ConvertTo-StringLabel $labelObject
        if ([string]::IsNullOrWhiteSpace($label) -or $label -eq '-') {
            continue
        }

        $cleanLabel = ($label -split '\\t')[0]
        $mnemonicMatches = [regex]::Matches($cleanLabel, '&(?!&)([A-Za-z0-9])')
        foreach ($mnemonicMatch in $mnemonicMatches) {
            $key = $mnemonicMatch.Groups[1].Value.ToUpperInvariant()
            if ($seen.ContainsKey($key)) {
                Fail "$description has duplicate Alt+$key mnemonic: '$($seen[$key])' and '$cleanLabel'"
            }
            $seen[$key] = $cleanLabel
        }
    }
}

function ConvertTo-StringLabel($value) {
    if ($null -eq $value) {
        return ''
    }
    return [regex]::Unescape([string]$value)
}

function Get-CSharpStringLabels([string]$text) {
    $labels = New-Object System.Collections.Generic.List[string]
    foreach ($match in [regex]::Matches($text, '"(?<label>(?:[^"\\]|\\.)*)"')) {
        $label = $match.Groups['label'].Value
        if ($label.Contains('&')) {
            $labels.Add($label)
        }
    }
    return $labels
}

function Get-SourceRange([string]$text, [string]$start, [string]$end) {
    $startIndex = $text.IndexOf($start, [StringComparison]::Ordinal)
    if ($startIndex -lt 0) {
        Fail "Could not find source range start: $start"
    }
    $endIndex = $text.IndexOf($end, $startIndex, [StringComparison]::Ordinal)
    if ($endIndex -lt 0) {
        Fail "Could not find source range end after $start`: $end"
    }
    return $text.Substring($startIndex, $endIndex - $startIndex)
}

function Assert-HistoryMenuMnemonics([string]$path) {
    Assert-Exists $path 'History form source'
    $text = Get-Content -LiteralPath $path -Raw
    Assert-UniqueWindowsMenuMnemonics $path 'History menu' @('file', 'actions', 'lineEndings', 'options', 'view', 'sortMenuItem', 'help')

    $editMethodBlock = Get-SourceRange $text 'private void PopulateEditMenu(ToolStripMenuItem edit)' 'private static void SetMenuItemsEnabled'

    $textEditStart = $editMethodBlock.IndexOf('edit.DropDownItems.Add("Copy and c&lose', [StringComparison]::Ordinal)
    if ($textEditStart -lt 0) {
        Fail 'Could not find text history Edit menu block'
    }
    $textEditBlock = $editMethodBlock.Substring($textEditStart)
    Assert-UniqueMnemonicLabels (Get-CSharpStringLabels $textEditBlock) 'Text history Edit menu'

    $fileEditBlock = Get-SourceRange $editMethodBlock 'if (IsFileClipboardTabActive())' 'return;'
    $filePinLabels = @('Pin or unp&in\tShift+Enter', 'Unp&in selected\tShift+Enter', 'P&in selected\tShift+Enter', 'Toggle p&inned state\tShift+Enter')
    foreach ($pinLabel in $filePinLabels) {
        Assert-UniqueMnemonicLabels (@(Get-CSharpStringLabels $fileEditBlock) + @($pinLabel)) "File history Edit menu with '$pinLabel'"
    }

    $textContextBlock = Get-SourceRange $text 'private void PopulateContextMenu(ContextMenuStrip menu)' 'private void PopulateFileEventsContextMenu'
    foreach ($pinLabel in $filePinLabels) {
        Assert-UniqueMnemonicLabels (@(Get-CSharpStringLabels $textContextBlock) + @($pinLabel)) "Text history context menu with '$pinLabel'"
    }

    $fileContextBlock = Get-SourceRange $text 'private void PopulateFileEventsContextMenu(ContextMenuStrip menu)' 'private int SelectedPinnedEntryShortcutPosition'
    foreach ($pinLabel in $filePinLabels) {
        Assert-UniqueMnemonicLabels (@(Get-CSharpStringLabels $fileContextBlock) + @($pinLabel)) "File history context menu with '$pinLabel'"
    }
}

function Assert-PreferencesTabMnemonics([string]$path) {
    Assert-Exists $path 'Preferences source'
    $text = Get-Content -LiteralPath $path -Raw
    $ranges = @(
        @('General preferences tab', 'active = NewCheckBox', 'general.Controls.Add(generalLayout);'),
        @('File history preferences tab', 'autoRemoveUnavailableFileHistoryEvents = NewCheckBox', 'fileHistory.Controls.Add(fileHistoryLayout);'),
        @('Hotkeys preferences tab', 'showHotkey = NewHotkeyBox', 'hotkeys.Controls.Add(hotkeyLayout);'),
        @('Storage and Password preferences tab', 'databasePath = NewTextBox', 'storage.Controls.Add(storageLayout);'),
        @('Startup and updates preferences tab', 'runAtStartup = NewCheckBox', 'integration.Controls.Add(integrationLayout);'),
        @('Sensitive data preferences tab', 'sensitiveDataMode = NewComboBox', 'sensitiveData.Controls.Add(sensitiveLayout);')
    )

    foreach ($range in $ranges) {
        $block = Get-SourceRange $text $range[1] $range[2]
        Assert-UniqueMnemonicLabels (Get-CSharpStringLabels $block) $range[0]
    }
}

function Get-GitHubHeaders {
    $token = $env:GH_TOKEN
    if ([string]::IsNullOrWhiteSpace($token)) {
        $token = $env:GITHUB_TOKEN
    }
    if ([string]::IsNullOrWhiteSpace($token)) {
        $candidate = $env:CODEX_GITHUB_TOKEN_FILE
        if (![string]::IsNullOrWhiteSpace($candidate) -and (Test-Path -LiteralPath $candidate)) {
            $token = (Get-Content -LiteralPath $candidate -Raw).Trim()
        }
    }

    $headers = @{
        'User-Agent' = 'Clipman smoke test'
        'Accept' = 'application/vnd.github+json'
    }
    if (![string]::IsNullOrWhiteSpace($token)) {
        $headers['Authorization'] = "Bearer $token"
    }
    return $headers
}

function Get-ChangelogEntry([string]$releaseVersion) {
    $manual = Join-Path $repoRoot 'Manual.html'
    $text = Get-Content -LiteralPath $manual -Raw
    $escaped = [regex]::Escape($releaseVersion)
    $match = [regex]::Match($text, "(?is)<h3>\s*$escaped\s*</h3>(.*?)(?=<h3>|<h2)")
    if (!$match.Success) {
        return ''
    }
    return $match.Groups[1].Value
}

function Get-ChangelogClosedIssueNumbers([string]$releaseVersion) {
    $entry = Get-ChangelogEntry $releaseVersion
    $numbers = @()
    foreach ($match in [regex]::Matches($entry, '(?i)\b(?:closes|fixes|resolves)\s+(?:github\s+)?(?:issue\s+)?#(\d+)\b')) {
        $numbers += [int]$match.Groups[1].Value
    }
    foreach ($match in [regex]::Matches($entry, 'https://github\.com/OnjLouis/Clipman/issues/(\d+)')) {
        $prefix = $entry.Substring([Math]::Max(0, $match.Index - 80), [Math]::Min(80, $match.Index))
        if ($prefix -match '(?i)\b(?:closes|fixes|resolves)\b') {
            $numbers += [int]$match.Groups[1].Value
        }
    }
    return @($numbers | Select-Object -Unique)
}

function Assert-GitHubActivityChecked([string]$releaseVersion) {
    if ($SkipGitHubActivityCheck) {
        Write-Host 'GitHub activity check skipped by request.'
        return
    }

    Write-Host 'Checking GitHub issues and pull requests.'
    $headers = Get-GitHubHeaders
    try {
        $repo = 'OnjLouis/Clipman'
        $issues = @(Invoke-GitHubJsonArray "https://api.github.com/repos/$repo/issues?state=open&per_page=100" $headers)
        $realIssues = @($issues | Where-Object { -not $_.pull_request })
        $closedByThisRelease = @(Get-ChangelogClosedIssueNumbers $releaseVersion)
        $reviewedIssueNumbers = @($ReviewedOpenIssue | ForEach-Object { [int]$_ })
        $blockingIssues = @($realIssues | Where-Object {
            [int]$_.number -notin $closedByThisRelease -and [int]$_.number -notin $reviewedIssueNumbers
        })
        if ($blockingIssues.Count -gt 0) {
            $summary = ($blockingIssues | ForEach-Object { "#$($_.number) $($_.title)" }) -join '; '
            Fail "Open GitHub issues need review before release: $summary"
        }
        $coveredIssues = @($realIssues | Where-Object { [int]$_.number -in $closedByThisRelease })
        if ($coveredIssues.Count -gt 0) {
            $summary = ($coveredIssues | ForEach-Object { "#$($_.number) $($_.title)" }) -join '; '
            Write-Host "Open GitHub issues are covered by this release changelog: $summary"
        }
        $reviewedIssues = @($realIssues | Where-Object { [int]$_.number -in $reviewedIssueNumbers -and [int]$_.number -notin $closedByThisRelease })
        if ($reviewedIssues.Count -gt 0) {
            $summary = ($reviewedIssues | ForEach-Object { "#$($_.number) $($_.title)" }) -join '; '
            Write-Host "Open GitHub issues were reviewed and intentionally left open: $summary"
        }
        if ($realIssues.Count -eq 0) {
            Write-Host 'No open GitHub issues.'
        } else {
            Write-Host 'No unreviewed open GitHub issues.'
        }

        $pulls = @(Invoke-GitHubJsonArray "https://api.github.com/repos/$repo/pulls?state=open&per_page=100" $headers | Where-Object { $_ -and $_.number })
        if ($pulls.Count -gt 0) {
            $summary = ($pulls | ForEach-Object { "#$($_.number) $($_.title)" }) -join '; '
            Fail "Open GitHub pull requests need review before release: $summary"
        }
        Write-Host 'No open GitHub pull requests.'
    }
    catch {
        Fail "Could not check GitHub activity: $($_.Exception.Message)"
    }
}

function Write-CommunityMentionReminder {
    Write-Host 'Community mention check: search the web and public community spaces for Clipman mentions before release.'
    Write-Host 'Suggested searches: "Clipman" "OnjLouis", "OnjLouis/Clipman", "Clipman" "Accessible Clipboard Management Tool", "Clipman" "Andre Louis" clipboard, "Clipman" "NVDA", "Clipman" "JAWS", "Clipman" "screen reader", and public podcast/email-list/community sites.'
    Write-Host 'Expect false positives from Linux clipboard managers named clipman. Look for feedback about this Windows project, and for repeated clipboard-manager themes such as setup friction, file clipboard formats, sync, encryption, hotkeys, search, pinning, and screen-reader behavior.'
    Write-Host 'For a repeatable checklist, run: powershell -ExecutionPolicy Bypass -File .\CommunitySearch.ps1'
}

function Assert-HandoverParity([string]$releaseVersion) {
    $handover = $env:CLIPMAN_PRIVATE_HANDOVER
    if ([string]::IsNullOrWhiteSpace($handover) -or !(Test-Path -LiteralPath $handover)) {
        Write-Host 'Private handover parity check skipped because CLIPMAN_PRIVATE_HANDOVER was not set or did not point to a file.'
        return
    }

    Assert-TextMatches $handover "Current development version: $([regex]::Escape($releaseVersion))" 'Private handover current development version'
    Assert-TextMatches $handover "Current $([regex]::Escape($releaseVersion)) development context" 'Private handover current development context'
    Assert-TextMatches $handover 'CommunitySearch\.ps1' 'Private handover community search workflow'
    Assert-TextMatches $handover 'machine-specific \.clipdb file' 'Private handover persistent file history'
    Assert-TextMatches $handover 'Save list position only writes LastSelectedIndex' 'Private handover save-position context'
    Assert-TextMatches $handover 'history window is hidden, closed, or toggled away' 'Private handover save-position hide context'
    Assert-TextMatches $handover 'still-live in-session ListView selection' 'Private handover in-session save-position context'
    Assert-TextMatches $handover 'Play sounds and Save list position both using Alt\+P' 'Private handover mnemonic regression context'
    Assert-TextMatches $handover 'Ctrl\+Enter goes to one selected file or folder' 'Private handover file-history go-to-file context'
    Assert-TextMatches $handover 'Shift\+Enter pins or unpins selected file-history events' 'Private handover file-history pin context'
    Assert-TextDoesNotMatch $handover 'File history is session-only and held in RAM|Current public release: 1\.5\.1(?!\d)|Current development version: 1\.5\.1(?!\d)|Current development version: 1\.5\.4(?!\d)|Current development version: 1\.5\.5(?!\d)|Current development version: 1\.5\.6(?!\d)' 'Private handover stale facts'
}

function Assert-ManualAndReadmeClean {
    $manual = Join-Path $repoRoot 'Manual.html'
    $readme = Join-Path $repoRoot 'README.md'
    $serverManual = Join-Path $repoRoot 'ClipmanServer\Manual.html'

    Assert-TextMatches $manual '<h2 id="contents">Contents</h2>' 'Manual table of contents'
    Assert-TextMatches $manual 'Project page: <a href="https://github.com/OnjLouis/Clipman">' 'Manual project page link'
    Assert-TextMatches $manual 'Add, remove, move, rename, group, pin, or edit text entries on one machine' 'Manual opening shared database explanation'
    Assert-TextMatches $manual 'Remove URL tracking' 'Manual URL tracking documentation'
    Assert-TextMatches $manual 'Clean link for sharing' 'Manual clean-link documentation'
    Assert-TextMatches $manual 'line endings' 'Manual line-ending transform documentation'
    Assert-TextMatches $manual 'machine-specific database named like <code>Settings\\Desktop-file-history\.clipdb</code>' 'Manual persistent file-history documentation'
    Assert-TextMatches $manual 'Remove selected unpinned file-history events</td><td><code>Del</code></td><td><code>Command\+Backspace</code>' 'Manual file-history delete shortcut'
    Assert-TextMatches $manual 'remove unavailable events' 'Manual unavailable event cleanup documentation'
    Assert-TextMatches $manual 'Run Clipman at Windows startup' 'Manual startup documentation'
    Assert-TextMatches $manual 'Install updates silently when possible' 'Manual silent update documentation'
    Assert-TextMatches $manual 'Settings\\sounds' 'Manual user sound override documentation'
    Assert-TextMatches $manual 'remote\.wav' 'Manual remote sync sound documentation'
    Assert-TextMatches $manual 'Shift\+F1' 'Manual update shortcut'
    Assert-TextMatches $manual 'Ctrl\+F1' 'Manual project shortcut'
    Assert-TextMatches $manual 'Alt\+F1' 'Manual diagnostics shortcut'
    Assert-TextMatches $manual 'Help, Contact' 'Manual contact documentation'
    Assert-TextMatches $manual 'Help, Donate' 'Manual donate documentation'
    Assert-TextMatches $manual 'https://onj\.me/donate' 'Manual donate URL'
    Assert-TextMatches $manual 'Multiple running Clipman instances can use the same history database' 'Manual shared history explanation'
    Assert-TextMatches $manual 'During an online or automatic update' 'Manual seamless update explanation'
    Assert-TextMatches $manual 'Storage and Password' 'Manual storage/password tab documentation'
    Assert-TextMatches $manual '<h2 id="links-history">Links History</h2>' 'Manual Links history section'
    Assert-TextMatches $manual 'Show Links history tab' 'Manual Links history preference documentation'
    Assert-TextMatches $manual 'single absolute <code>http</code> or <code>https</code> URL' 'Manual Links history classification documentation'
    Assert-TextMatches $manual 'Links are not stored in a separate database' 'Manual Links history filtered-view documentation'
    Assert-TextMatches $manual 'With Links history disabled, File history remains the second history area' 'Manual Links disabled shortcut behavior'
    Assert-TextMatches $manual 'With Links history enabled, Links history becomes the second area and File history moves to the third' 'Manual Links enabled shortcut behavior'
    Assert-TextMatches $manual 'Control\+3</code> switches File history' 'Manual Mac Links history Control+3 documentation'
    Assert-TextMatches $manual '<h3>1\.9\.0</h3>' 'Manual 1.9.0 changelog'
    Assert-TextMatches $manual 'Closes <a href="https://github\.com/OnjLouis/Clipman/issues/18">issue #18</a>' 'Manual issue #18 closure'
    Assert-TextMatches $manual '<h3>1\.8\.2</h3>' 'Manual 1.8.2 changelog'
    Assert-TextMatches $manual 'Move to top' 'Manual 1.8.2 duplicate handling label changelog'
    Assert-TextMatches $manual 'Closes <a href="https://github\.com/OnjLouis/Clipman/issues/14">issue #14</a>' 'Manual issue #14 closure'
    Assert-TextMatches $manual 'closes <a href="https://github\.com/OnjLouis/Clipman/issues/15">issue #15</a>' 'Manual issue #15 closure'
    Assert-TextMatches $manual 'Closes <a href="https://github\.com/OnjLouis/Clipman/issues/16">issue #16</a>' 'Manual issue #16 closure'
    Assert-TextMatches $manual 'Closes <a href="https://github\.com/OnjLouis/Clipman/issues/17">issue #17</a>' 'Manual issue #17 closure'
    Assert-TextMatches $manual '<h3>1\.8\.1</h3>' 'Manual 1.8.1 changelog'
    Assert-TextMatches $manual 'Clipboard privacy signals' 'Manual clipboard privacy signal documentation'
    Assert-TextMatches $manual 'Clipboard Viewer Ignore' 'Manual Clipboard Viewer Ignore documentation'
    Assert-TextMatches $manual 'ExcludeClipboardContentFromMonitorProcessing' 'Manual Windows cloud clipboard exclusion documentation'
    Assert-TextMatches $manual 'CanIncludeInClipboardHistory' 'Manual Windows clipboard history signal documentation'
    Assert-TextMatches $manual 'CanUploadToCloudClipboard' 'Manual Windows cloud clipboard sync signal documentation'
    Assert-TextMatches $manual '<h3>1\.8\.0</h3>' 'Manual 1.8.0 changelog'
    Assert-TextMatches $manual 'Sensitive Data preferences' 'Manual sensitive data changelog'
    Assert-TextMatches $manual 'international phone numbers' 'Manual international phone preset documentation'
    Assert-TextMatches $manual '\+447890123456' 'Manual E.164-style phone example'
    Assert-TextMatches $manual 'Software license key' 'Manual software license key preset documentation'
    Assert-TextMatches $manual 'AAAAA-BBBBB-CCCCC-DDDDD-EEEEE' 'Manual software license key test value'
    Assert-TextMatches $manual 'Copy credit-card test number' 'Manual sensitive data copy test button'
    Assert-TextMatches $manual 'data-copy-test' 'Manual sensitive data copy test wiring'
    Assert-TextMatches $manual 'Insert sample' 'Manual template preset insertion documentation'
    Assert-TextMatches $manual 'Insert field' 'Manual template field insertion documentation'
    Assert-TextMatches $manual '<h3>1\.7\.2</h3>' 'Manual 1.7.2 changelog'
    Assert-TextMatches $manual 'Retry Storage command to the status menu' 'Manual Mac unavailable storage retry documentation'
    Assert-TextMatches $manual 'notification-area menu and tooltip report that storage is unavailable' 'Manual Windows unavailable storage retry documentation'
    Assert-TextMatches $manual 'no longer shows blocking storage alerts or plays the success sound for a failed write' 'Manual unavailable storage changelog'
    Assert-TextMatches $manual '<h3>1\.7\.1</h3>' 'Manual 1.7.1 changelog'
    Assert-TextMatches $manual 'asks for that import file''s password' 'Manual encrypted import password documentation'
    Assert-TextMatches $manual 'new export-only password' 'Manual export password choice documentation'
    Assert-TextMatches $manual 'before creating any <code>\.clipdb</code> export' 'Manual encrypted-history export confirmation documentation'
    Assert-TextMatches $manual 'duplicated <code>\.clipdb\.clipdb</code> extension' 'Manual Mac duplicate export extension changelog'
    Assert-TextDoesNotMatch $manual 'Mac tester|tester build|test build|test-only' 'Manual must not describe Mac as a test build'
    Assert-TextMatches $manual '<h3>1\.7\.0</h3>' 'Manual 1.7.0 changelog'
    Assert-TextMatches $manual 'Template entries' 'Manual template entries documentation'
    Assert-TextMatches $manual '\{\{year_full\}\}' 'Manual template year variable documentation'
    Assert-TextMatches $manual '\{\{os_version\}\}' 'Manual template OS version variable documentation'
    Assert-TextMatches $manual 'stored text remains unchanged' 'Manual template storage behavior documentation'
    Assert-TextMatches $manual 'Closes <a href="https://github\.com/OnjLouis/Clipman/issues/12">issue #12</a>' 'Manual issue #12 closure'
    Assert-TextMatches $manual '<h3>1\.6\.6</h3>' 'Manual 1.6.6 changelog'
    Assert-TextMatches $manual 'one-modifier hotkeys are now allowed for function keys and grave/backslash-style punctuation keys' 'Manual 1.6.6 safe single-modifier changelog'
    Assert-TextMatches $manual '<h3>1\.6\.5</h3>' 'Manual 1.6.5 changelog'
    Assert-TextMatches $manual 'helper windows and helper processes can be ignored' 'Manual 1.6.5 ignored helper changelog'
    Assert-TextMatches $manual 'standard edit shortcuts such as <code>Command\+V</code> work in settings text fields' 'Manual 1.6.5 Mac Preferences paste changelog'
    Assert-TextMatches $manual 'whether the selected history database is encrypted and whether the password is saved in Keychain' 'Manual 1.6.5 Mac password status changelog'
    Assert-TextMatches $manual 'Ctrl\+1</code> to <code>Ctrl\+6' 'Manual preferences tab shortcut documentation'
    Assert-TextMatches $manual 'File history preferences' 'Manual File history preferences documentation'
    Assert-TextMatches $manual 'diagnostics event limit' 'Manual diagnostics event limit documentation'
    Assert-TextMatches $manual 'Ctrl\+I' 'Manual import shortcut documentation'
    Assert-TextMatches $manual 'Ctrl\+E' 'Manual export shortcut documentation'
    Assert-TextMatches $manual 'Sort Text history or File history entries from the Sort by submenu' 'Manual sort submenu documentation'
    Assert-TextMatches $manual 'Close or hide the history window' 'Manual Esc close shortcut documentation'
    Assert-TextMatches $manual 'Ctrl\+Del' 'Manual file-history clear shortcut documentation'
    Assert-TextMatches $manual 'Alt\+Del' 'Manual file-history remove-missing shortcut documentation'
    Assert-TextMatches $manual 'Ctrl\+Shift\+1' 'Manual pinned file path shortcut documentation'
    Assert-TextMatches $manual 'first pinned entry starts with 1' 'Manual pinned text row numbering documentation'
    Assert-TextMatches $manual 'Move up by one visible page</td><td><code>Page Up</code></td><td><code>Page Up</code>' 'Manual Page Up shortcut documentation'
    Assert-TextMatches $manual 'Move down by one visible page</td><td><code>Page Down</code></td><td><code>Page Down</code>' 'Manual Page Down shortcut documentation'
    Assert-TextMatches $manual 'They are numbered when they can be restored by shortcut' 'Manual pinned file row numbering documentation'
    Assert-TextMatches $manual 'Use no password button clears the saved history password' 'Manual no-password button documentation'
    Assert-TextMatches $manual 'History password' 'Manual encryption documentation'
    Assert-TextMatches $manual '<h3>1\.6\.0</h3>' 'Manual 1.6.0 changelog'
    Assert-TextMatches $manual 'Updated the Windows and Mac builds together' 'Manual 1.6.0 release summary'
    Assert-TextMatches $manual 'Fixed Windows Alt\+number group-filter shortcuts' 'Manual 1.6 Alt+number menu-focus changelog'
    Assert-TextMatches $manual '<h3>1\.5\.12</h3>' 'Manual 1.5.12 changelog'
    Assert-TextMatches $manual 'history password remembering to be explicit and optional' 'Manual 1.5.12 password remembering changelog'
    Assert-TextMatches $manual 'Closes <a href="https://github\.com/OnjLouis/Clipman/issues/5">issue #5</a>' 'Manual issue #5 closure'
    Assert-TextMatches $manual 'Mac VoiceOver labels' 'Manual 1.5.12 Mac VoiceOver changelog'
    Assert-TextMatches $manual '<h3>1\.5\.11</h3>' 'Manual 1.5.11 changelog'
    Assert-TextMatches $manual 'oldest first, newest first, A first, Z first' 'Manual 1.5.11 sort direction wording'
    Assert-TextMatches $manual 'choose a Clipman data folder instead of an individual <code>\.clipdb</code> file' 'Manual 1.5.11 data-folder changelog'
    Assert-TextMatches $manual 'Clipman stores shared text history as <code>clipman-history\.clipdb</code> inside the chosen folder' 'Manual data-folder storage documentation'
    Assert-TextMatches $manual 'settings-location\.json' 'Manual data-folder pointer documentation'
    Assert-TextMatches $manual 'pointer stores locations per computer name' 'Manual per-computer data-folder pointer documentation'
    Assert-TextMatches $manual 'merges the known clients back into one pointer file' 'Manual pointer conflict merge documentation'
    Assert-TextMatches $manual '<h2 id="secrets">Secrets</h2>' 'Manual Secrets section'
    Assert-TextMatches $manual '&lt;computer-name&gt;-secrets\.clipdb' 'Manual per-machine Secrets database documentation'
    Assert-TextMatches $manual 'Opening the Secrets manager asks for the current history password' 'Manual Secrets unlock documentation'
    Assert-TextMatches $manual 'Insert</code> to add a secret' 'Manual Secrets command documentation'
    Assert-TextMatches $manual 'Ctrl\+A</code> on Windows and <code>Command\+A</code> on Mac' 'Manual Secrets select-all documentation'
    Assert-TextMatches $manual 'Ctrl\+Shift\+E' 'Manual Windows Secrets shortcut'
    Assert-TextMatches $manual 'Command\+Shift\+E' 'Manual Mac Secrets shortcut'
    Assert-TextMatches $manual 'Alt\+I' 'Manual Windows File history shortcut'
    Assert-TextMatches (Join-Path $repoRoot 'src\HistoryForm.cs') 'key == Keys\.I[\s\S]{0,120}SelectFileClipboardTab\(\);' 'Windows Alt+I opens File history'
    Assert-TextMatches (Join-Path $repoRoot 'src\HistoryForm.cs') 'Text history\\tAlt\+T' 'Windows View menu advertises Text history shortcut'
    Assert-TextMatches (Join-Path $repoRoot 'src\HistoryForm.cs') 'Links history\\tAlt\+L' 'Windows View menu advertises Links history shortcut'
    Assert-TextMatches (Join-Path $repoRoot 'src\HistoryForm.cs') 'File history\\tAlt\+I' 'Windows View menu advertises File history shortcut'
    Assert-TextMatches $manual 'View menu on Windows includes Text history, Links history, and File history commands' 'Manual documents Windows View history commands'
    Assert-TextMatches $readme 'pointer stores locations per computer name' 'README per-computer data-folder pointer documentation'
    Assert-TextMatches $readme 'merges the known clients back into one pointer file' 'README pointer conflict merge documentation'
    Assert-TextMatches $readme 'Optional Secrets area' 'README Secrets feature summary'
    Assert-TextMatches $readme '<computer-name>-secrets\.clipdb' 'README per-machine Secrets database documentation'
    Assert-TextMatches $readme 'Opening the Secrets manager asks for the current history password' 'README Secrets unlock documentation'
    Assert-TextMatches $readme 'Enter quick-pastes, Insert adds, F2 edits, Delete removes, and Esc closes' 'README Secrets command documentation'
    Assert-TextMatches $readme 'Ctrl\+Shift\+E' 'README Windows Secrets shortcut'
    Assert-TextMatches $readme 'Command\+Shift\+E' 'README Mac Secrets shortcut'
    Assert-TextMatches (Join-Path $repoRoot 'src\PasswordPromptForm.cs') 'TextBoxSelectAllKeyDown' 'Windows password prompt supports Ctrl+A'
    Assert-TextMatches (Join-Path $repoRoot 'src\SecretEditorForm.cs') 'TextBoxSelectAllKeyDown' 'Windows secret editor supports Ctrl+A'
    Assert-TextMatches (Join-Path $repoRoot 'ClipmanMac\Sources\Clipman\AppController.swift') 'runModalWithTextEditingShortcuts' 'Mac Secrets unlock prompt supports Command+A'
    Assert-TextMatches (Join-Path $repoRoot 'ClipmanMac\Sources\Clipman\SecretsWindowController.swift') 'runModalWithTextEditingShortcuts' 'Mac Secrets editor supports Command+A'
    Assert-TextMatches $manual 'active settings in that folder beside <code>clipman-history\.clipdb</code>' 'Manual active settings in selected data folder'
    Assert-TextDoesNotMatch $manual 'between ascending and descending|toggle ascending or descending order' 'Manual avoids unclear ascending/descending sort wording'
    Assert-TextMatches $manual '<h3>1\.5\.10</h3>' 'Manual 1.5.10 changelog'
    Assert-TextMatches $manual 'File history sorting from the View menu' 'Manual 1.5.10 file-history sort changelog'
    Assert-TextMatches $manual 'Backspace</code> on the File history tab' 'Manual 1.5.10 file-history Backspace changelog'
    Assert-TextMatches $manual 'restored file events also place the file paths on the clipboard as text' 'Manual 1.5.10 file restore text-path changelog'
    Assert-TextMatches $manual '<h3>1\.5\.9</h3>' 'Manual 1.5.9 changelog'
    Assert-TextMatches $manual 'deleting the last visible row' 'Manual 1.5.9 delete-selection changelog'
    Assert-TextMatches $manual 'delayed or duplicate focus resets' 'Manual 1.5.9 delayed focus changelog'
    Assert-TextMatches $manual '<h3>1\.5\.8</h3>' 'Manual 1.5.8 changelog'
    Assert-TextMatches $manual 'File history parity with Text history' 'Manual 1.5.8 file-history parity changelog'
    Assert-TextMatches $manual 'file and folder names now come first in each row' 'Manual 1.5.8 file-history filename-first changelog'
    Assert-TextMatches $manual 'buffered type-to-jump by full filename prefix' 'Manual 1.5.8 file-history buffered navigation changelog'
    Assert-TextMatches $manual 'File history rows start with the file or folder name' 'Manual file-history filename-first documentation'
    Assert-TextMatches $manual 'File history supports buffered type-to-jump by full filename prefix' 'Manual file-history type-to-jump documentation'
    Assert-TextMatches $manual 'Changed File history Go to file from <code>Shift\+Enter</code> to <code>Ctrl\+Enter</code>' 'Manual 1.5.8 go-to-file shortcut changelog'
    Assert-TextMatches $manual 'Save list position no longer pulls focus back to an older saved row' 'Manual 1.5.8 delete-position changelog'
    Assert-TextMatches $manual '<h3>1\.5\.7</h3>' 'Manual 1.5.7 changelog'
    Assert-TextMatches $manual 'reopening Text history now resets the live selection' 'Manual 1.5.7 save-position live-selection changelog'
    Assert-TextMatches $manual '<h3>1\.5\.6</h3>' 'Manual 1.5.6 changelog'
    Assert-TextMatches $manual 'Save list position now updates when the history window is hidden' 'Manual 1.5.6 save position changelog'
    Assert-TextMatches $manual 'Play sounds and Save list position no longer share the same mnemonic' 'Manual 1.5.6 mnemonic changelog'
    Assert-TextMatches $manual '<h3>1\.5\.5</h3>' 'Manual 1.5.5 changelog'
    Assert-TextMatches $manual 'Save list position now only saves and restores list position when enabled' 'Manual 1.5.5 save position changelog'
    Assert-TextMatches $manual 'Press <code>Enter</code> to restore all existing files and folders from the selected file events' 'Manual file-history multi-selection documentation'
    Assert-TextMatches $manual 'Go to file with <code>Shift\+Enter</code>' 'Manual 1.5.5 go-to-file historical changelog'
    Assert-TextMatches $manual '<h3>1\.5\.4</h3>' 'Manual 1.5.4 changelog'
    Assert-TextMatches $manual 'non-restorable non-file clipboard events' 'Manual 1.5.4 unavailable file-history cleanup changelog'
    Assert-TextMatches $manual 'configurable diagnostics event limit' 'Manual 1.5.4 diagnostics limit changelog'
    Assert-TextDoesNotMatch $manual 'build guard so changed source cannot build under a version number that has already been released' 'Manual changelog internal build guard'
    Assert-TextDoesNotMatch $manual 'release-time community search checklist' 'Manual changelog internal community search'
    Assert-TextMatches $manual '<h3>1\.5\.3</h3>' 'Manual 1.5.3 changelog'
    Assert-TextMatches $manual 'Preferences now opens as an owned dialog' 'Manual 1.5.3 preferences ownership changelog'
    Assert-TextMatches $manual 'Ctrl\+Del</code> clears file history' 'Manual 1.5.3 file history shortcut changelog'
    Assert-TextMatches $manual '<h3>1\.5\.2</h3>' 'Manual 1.5.2 changelog'
    Assert-TextMatches $manual 'persistent machine-specific File history storage' 'Manual persistent file history changelog'
    Assert-TextMatches $manual '<h3>1\.5\.1</h3>' 'Manual 1.5.1 changelog'
    Assert-TextMatches $manual 'Bundled factory sounds are now replaced cleanly' 'Manual factory sounds update cleanup changelog'
    Assert-TextMatches $manual 'Closes <a href="https://github\.com/OnjLouis/Clipman/issues/1">issue #1</a>' 'Manual issue #1 closure'
    Assert-TextMatches $manual 'See <a href="https://github\.com/OnjLouis/Clipman/issues/2">issue #2</a>' 'Manual issue #2 review note'
    Assert-TextMatches $manual 'Closes <a href="https://github\.com/OnjLouis/Clipman/issues/3">issue #3</a>' 'Manual issue #3 closure'
    Assert-TextMatches $manual '<h3>1\.1\.1</h3>' 'Manual 1.1.1 changelog'
    Assert-TextMatches $manual 'deliberately ignores that generated password copy' 'Manual generated password documentation'
    Assert-TextMatches $manual 'same name or bundle/process prefix' 'Manual ignored helper matching documentation'
    Assert-TextMatches $manual 'Preferences reports whether database encryption is on and whether the password is saved in Keychain' 'Manual Mac encryption status documentation'
    Assert-TextMatches $manual '<h2 id="application-files">Application Files</h2>' 'Manual application files section'
    Assert-TextMatches $manual '<li><a href="#clipman-server">Clipman Server</a></li>' 'Manual Clipman Server contents entry'
    Assert-TextMatches $manual '<h2 id="clipman-server">Clipman Server</h2>' 'Manual Clipman Server section'
    Assert-TextDoesNotMatch $manual '<code>ClipmanServer\.exe</code>' 'Manual must not document ClipmanServer.exe as part of the normal app package'
    Assert-TextMatches $manual 'Linux/install-clipman-server\.sh' 'Manual documents the Linux server installer'
    Assert-TextMatches $manual 'clipman-server-connection\.txt' 'Manual documents server connection details file'
    Assert-TextMatches $manual 'Do not manually copy a <code>\.clipdb</code>' 'Manual documents safe existing-history server bootstrap'
    Assert-TextMatches $manual 'normal Clipman app packages are client-only' 'Manual server separate-package documentation'
    Assert-TextMatches $manual 'separate cross-platform server package' 'Manual cross-platform server package documentation'
    Assert-TextMatches $manual 'same Python server on Linux, macOS, and Windows' 'Manual cross-platform server parity documentation'
    Assert-TextDoesNotMatch $manual 'reference implementation|experimental native server|repository may contain' 'Manual must not expose server development wording'
    Assert-TextMatches $manual 'random high port and random bearer token' 'Manual Clipman Server random port/token documentation'
    Assert-TextMatches $manual 'set <strong>Storage type</strong> to <strong>Clipman Server</strong>' 'Manual Clipman Server client storage setting documentation'
    Assert-TextMatches $manual '<code>Settings\\Databases\\&lt;database-id&gt;\\ServerBackups</code>|under each database bucket' 'Manual Clipman Server scoped backup documentation'
    Assert-TextMatches $manual 'does not know, request, or store the history password' 'Manual Clipman Server password boundary documentation'
    Assert-TextMatches $manual 'server token plus each history password maps to a separate server-side database bucket' 'Manual Clipman Server password-scoped bucket documentation'
    Assert-TextMatches $manual 'host can be typed as <code>home-server:49152</code>' 'Manual Clipman Server host without protocol documentation'
    Assert-TextDoesNotMatch $manual 'pi:62673|100\.113\.210\.31|OutsidePi' 'Manual must not contain private server details'
    Assert-TextMatches $manual '<h3>2\.0\.0</h3>' 'Manual 2.0.0 changelog'
    Assert-TextDoesNotMatch $manual 'Server sync now|Server clients now|Server uploads now|Server configs now|Server database buckets can now|Linux server installer now' 'Manual 2.0.0 changelog must not expose internal server iteration wording'
    Assert-TextMatches $manual 'Clipman 2\.0 introduces optional Clipman Server support' 'Manual 2.0.0 server feature changelog'
    Assert-TextMatches $manual 'rolling hourly backups' 'Manual Clipman Server backup changelog'
    Assert-TextMatches $manual 'password-scoped database buckets' 'Manual 2.0.0 password-scoped bucket changelog'
    Assert-TextMatches $manual 'delete propagation' 'Manual 2.0.0 server delete sync changelog'
    Assert-TextMatches $manual '<code>sqlite3\.dll</code>' 'Manual SQLite runtime file documentation'
    Assert-TextMatches $manual '<code>LICENSE\.txt</code>' 'Manual license file documentation'
    Assert-TextMatches $manual '<h2 id="license">License</h2>' 'Manual license section'
    Assert-TextMatches $manual 'old Clipman <code>clipman\.db</code> or Ditto SQLite databases' 'Manual SQLite import documentation'
    Assert-TextMatches $manual 'SQLite import support uses the public-domain SQLite runtime' 'Manual SQLite credit'
    Assert-TextMatches $manual 'Jump to first normal item below pinned items</td><td><code>Backspace</code></td><td><code>Backspace</code>' 'Manual Backspace normal-entry shortcut'
    Assert-TextMatches $manual 'Ctrl\+Shift\+R' 'Manual URL tracking shortcut'
    Assert-TextMatches $manual 'Ctrl\+Shift\+S' 'Manual clean-link shortcut'
    Assert-TextMatches $manual 'Ctrl\+A' 'Manual select-all/viewer shortcut'
    Assert-TextMatches $manual 'Tyler Spivey' 'Manual credits'
    Assert-TextMatches $readme 'Project page: <https://github.com/OnjLouis/Clipman>' 'README project page link'
    Assert-TextMatches $readme 'Clipman is a small portable accessible clipboard management tool for Windows and macOS' 'README cross-platform project summary'
    Assert-TextMatches $readme 'Add, remove, move, rename, group, pin, or edit text entries on one machine' 'README opening shared database explanation'
    Assert-TextMatches $readme '## Clipman Server' 'README Clipman Server section'
    Assert-TextDoesNotMatch $readme '`ClipmanServer\.exe`' 'README must not document ClipmanServer.exe as part of the normal app package'
    Assert-TextMatches $readme 'Linux/install-clipman-server\.sh' 'README documents the Linux server installer'
    Assert-TextMatches $readme 'clipman-server-connection\.txt' 'README documents server connection details file'
    Assert-TextMatches $readme 'Do not manually copy a `\.clipdb`' 'README documents safe existing-history server bootstrap'
    Assert-TextMatches $readme 'normal Clipman app packages are client-only' 'README server separate-package documentation'
    Assert-TextMatches $readme 'separate cross-platform server package' 'README cross-platform server package documentation'
    Assert-TextMatches $readme 'same Python server on Linux, macOS, and Windows' 'README cross-platform server parity documentation'
    Assert-TextDoesNotMatch $readme 'reference implementation|experimental native server|repository may contain' 'README must not expose server development wording'
    Assert-TextMatches $readme 'random high port and random bearer token' 'README Clipman Server random port/token documentation'
    Assert-TextMatches $readme 'Storage type to `Clipman Server`' 'README Clipman Server client storage setting documentation'
    Assert-TextMatches $readme 'under each database bucket|Settings\\Databases\\<database-id>\\ServerBackups' 'README Clipman Server scoped backup documentation'
    Assert-TextMatches $readme 'does not know, request, or store the history password' 'README Clipman Server password boundary documentation'
    Assert-TextMatches $readme 'server token plus each history password maps to a separate server-side database bucket' 'README Clipman Server password-scoped bucket documentation'
    Assert-TextMatches $readme 'host can be typed as `home-server:49152`' 'README Clipman Server host without protocol documentation'
    Assert-TextDoesNotMatch $readme 'pi:62673|100\.113\.210\.31|OutsidePi' 'README must not contain private server details'
    Assert-TextMatches $readme '### 2\.0\.0' 'README 2.0.0 changelog'
    Assert-TextDoesNotMatch $readme 'Server sync now|Server clients now|Server uploads now|Server configs now|Server database buckets can now|Linux server installer now' 'README 2.0.0 changelog must not expose internal server iteration wording'
    Assert-TextMatches $readme 'Clipman 2\.0 introduces optional Clipman Server support' 'README 2.0.0 server feature changelog'
    Assert-TextMatches $readme 'rolling hourly backups' 'README Clipman Server backup changelog'
    Assert-TextMatches $readme 'password-scoped database buckets' 'README 2.0.0 password-scoped bucket changelog'
    Assert-TextMatches $readme 'Optional Links history tab for whole-entry HTTP and HTTPS links' 'README Links history feature'
    Assert-TextMatches $readme 'Links history is optional and off by default' 'README Links history preference documentation'
    Assert-TextMatches $readme 'With Links history enabled, Links becomes the second area and File history moves to the third' 'README Links enabled shortcut behavior'
    Assert-TextMatches $readme '### 1\.9\.0' 'README 1.9.0 changelog'
    Assert-TextMatches $readme 'Closes issue #18' 'README issue #18 closure'
    Assert-TextMatches $readme '### 1\.8\.2' 'README 1.8.2 changelog'
    Assert-TextMatches $readme 'Move to top' 'README 1.8.2 duplicate handling label changelog'
    Assert-TextMatches $readme 'issue #14 and closes issue #15' 'README 1.8.2 duplicate handling issue closures'
    Assert-TextMatches $readme 'issue #16' 'README 1.8.2 tray Preferences issue closure'
    Assert-TextMatches $readme 'issue #17' 'README 1.8.2 settings folder issue closure'
    Assert-TextMatches $readme 'Mac menu bar, status menu, and in-window Clipman menu' 'README 1.8.2 Mac settings folder parity'
    Assert-TextMatches $readme '### 1\.8\.1' 'README 1.8.1 changelog'
    Assert-TextMatches $readme 'clipboard privacy signals' 'README clipboard privacy signal documentation'
    Assert-TextMatches $readme 'Clipboard Viewer Ignore' 'README Clipboard Viewer Ignore documentation'
    Assert-TextMatches $readme 'ExcludeClipboardContentFromMonitorProcessing' 'README Windows cloud clipboard exclusion documentation'
    Assert-TextMatches $readme 'CanIncludeInClipboardHistory' 'README Windows clipboard history signal documentation'
    Assert-TextMatches $readme 'CanUploadToCloudClipboard' 'README Windows cloud clipboard sync signal documentation'
    Assert-TextMatches $readme '### 1\.8\.0' 'README 1.8.0 changelog'
    Assert-TextMatches $readme 'Sensitive Data preferences' 'README sensitive data changelog'
    Assert-TextMatches $readme 'international phone numbers' 'README international phone preset documentation'
    Assert-TextMatches $readme '\+447890123456' 'README E.164-style phone example'
    Assert-TextMatches $readme 'software license keys' 'README software license key preset documentation'
    Assert-TextMatches $readme 'AAAAA-BBBBB-CCCCC-DDDDD-EEEEE' 'README software license key test value'
    Assert-TextMatches $readme 'Insert sample' 'README template preset insertion documentation'
    Assert-TextMatches $readme 'Insert field' 'README template field insertion documentation'
    Assert-TextMatches $readme '### 1\.7\.2' 'README 1.7.2 changelog'
    Assert-TextMatches $readme 'Retry Storage command to the status menu' 'README Mac unavailable storage retry documentation'
    Assert-TextMatches $readme 'notification-area menu and tooltip report that storage is unavailable' 'README Windows unavailable storage retry documentation'
    Assert-TextMatches $readme 'line endings' 'README line-ending transform documentation'
    Assert-TextMatches $readme 'no longer shows blocking storage alerts or plays the success sound for a failed write' 'README unavailable storage changelog'
    Assert-TextMatches $readme '### 1\.7\.1' 'README 1.7.1 changelog'
    Assert-TextMatches $readme 'asks for that import file''s password' 'README encrypted import password documentation'
    Assert-TextMatches $readme 'new export-only password' 'README export password choice documentation'
    Assert-TextMatches $readme 'before creating any `\.clipdb` export' 'README encrypted-history export confirmation documentation'
    Assert-TextMatches $readme 'duplicated `\.clipdb\.clipdb` extension' 'README Mac duplicate export extension changelog'
    Assert-TextDoesNotMatch $readme 'Mac tester|tester build|test build|test-only' 'README must not describe Mac as a test build'
    Assert-TextMatches $readme '### 1\.7\.0' 'README 1.7.0 changelog'
    Assert-TextMatches $readme 'Optional template entries' 'README template entries feature'
    Assert-TextMatches $readme '\{\{username\}\}' 'README template username variable documentation'
    Assert-TextMatches $readme 'Unknown variables are left alone' 'README template unknown-variable behavior'
    Assert-TextMatches $readme 'Closes issue #12' 'README issue #12 closure'
    Assert-TextMatches $readme '### 1\.6\.6' 'README 1.6.6 changelog'
    Assert-TextMatches $readme 'one-modifier hotkeys are now allowed for function keys and grave/backslash-style punctuation keys' 'README 1.6.6 safe single-modifier changelog'
    Assert-TextMatches $readme '### 1\.6\.0' 'README 1.6.0 changelog'
    Assert-TextMatches $readme '### 1\.6\.5' 'README 1.6.5 changelog'
    Assert-TextMatches $readme 'helper windows and helper processes can be ignored' 'README 1.6.5 ignored helper changelog'
    Assert-TextMatches $readme 'standard edit shortcuts such as Command\+V work in settings text fields' 'README 1.6.5 Mac Preferences paste changelog'
    Assert-TextMatches $readme 'whether the selected history database is encrypted and whether the password is saved in Keychain' 'README 1.6.5 Mac password status changelog'
    Assert-TextMatches $readme 'Updated the Windows and Mac builds together' 'README 1.6.0 release summary'
    Assert-TextMatches $readme 'Fixed Windows Alt\+number group-filter shortcuts' 'README 1.6 Alt+number menu-focus changelog'
    Assert-TextMatches $readme '### 1\.5\.12' 'README 1.5.12 changelog'
    Assert-TextMatches $readme 'history password remembering to be explicit and optional' 'README 1.5.12 password remembering changelog'
    Assert-TextMatches $readme 'Closes issue #5' 'README issue #5 closure'
    Assert-TextMatches $readme 'Mac VoiceOver labels' 'README 1.5.12 Mac VoiceOver changelog'
    Assert-TextMatches $readme '### 1\.5\.11' 'README 1.5.11 changelog'
    Assert-TextMatches $readme 'oldest first, newest first, A first, Z first' 'README 1.5.11 sort direction wording'
    Assert-TextMatches $readme 'choose a Clipman data folder instead of an individual `\.clipdb` file' 'README 1.5.11 data-folder changelog'
    Assert-TextMatches $readme 'set the data folder to the same synced or network-shared folder' 'README data-folder sharing documentation'
    Assert-TextMatches $readme 'small pointer remains in the app''s `Settings` folder' 'README data-folder pointer documentation'
    Assert-TextMatches $readme '### 1\.5\.10' 'README 1.5.10 changelog'
    Assert-TextMatches $readme 'File history sorting from the View menu' 'README 1.5.10 file-history sort changelog'
    Assert-TextMatches $readme 'Backspace` on the File history tab' 'README 1.5.10 file-history Backspace changelog'
    Assert-TextMatches $readme 'Ctrl\+Shift\+S' 'README clean-link shortcut'
    Assert-TextMatches $readme 'Ctrl\+Shift\+1' 'README pinned file path shortcut'
    Assert-TextMatches $readme 'first ten pinned entries are numbered' 'README pinned row numbering'
    Assert-TextMatches $readme 'Home, End, Page Up, and Page Down' 'README large list navigation'
    Assert-TextMatches $readme '### 1\.5\.9' 'README 1.5.9 changelog'
    Assert-TextMatches $readme 'deleting the last visible row' 'README 1.5.9 delete-selection changelog'
    Assert-TextMatches $readme 'delayed or duplicate focus resets' 'README 1.5.9 delayed focus changelog'
    Assert-TextMatches $readme '<code>Ctrl\+Alt\+`</code>' 'README backtick hotkey formatting'
    Assert-TextMatches $readme 'automatic update checks' 'README update preferences'
    Assert-TextMatches $readme 'Switch Preferences tabs' 'README preferences tab shortcut'
    Assert-TextMatches $readme 'Ctrl\+1` to `Ctrl\+6' 'README preferences tab range'
    Assert-TextMatches $readme 'File history preferences' 'README file-history preferences documentation'
    Assert-TextMatches $readme 'standard Windows multi-selection' 'README file-history multi-selection documentation'
    Assert-TextMatches $readme 'File history rows start with the file or folder name' 'README file-history filename-first documentation'
    Assert-TextMatches $readme 'buffered type-to-jump navigation by file name' 'README file-history type-to-jump documentation'
    Assert-TextMatches $readme 'Shift\+Enter` to pin or unpin selected file events' 'README file-history pin documentation'
    Assert-TextMatches $readme 'Ctrl\+Enter` to open Explorer' 'README file-history go-to-file documentation'
    Assert-TextMatches $readme 'Import clipboard entries: `Ctrl\+I`' 'README import shortcut'
    Assert-TextMatches $readme 'Export clipboard entries: `Ctrl\+E`' 'README export shortcut'
    Assert-TextMatches $readme 'CommunitySearch\.ps1' 'README community search checklist'
    Assert-TextMatches $readme 'Close history or Preferences' 'README Esc close shortcut'
    Assert-TextMatches $readme 'Ctrl\+Del' 'README file-history clear shortcut'
    Assert-TextMatches $readme 'Alt\+Del' 'README file-history remove-missing shortcut'
    Assert-TextMatches $readme 'Storage and Password' 'README storage/password tab documentation'
    Assert-TextMatches $readme 'LICENSE\.txt' 'README license file documentation'
    Assert-TextMatches $readme 'Sort direction uses clearer first-style labels' 'README sort direction documentation'
    Assert-TextMatches $readme 'Settings\\sounds' 'README user sound override documentation'
    Assert-TextMatches $readme 'remote\.wav' 'README remote sync sound documentation'
    Assert-TextMatches $readme 'Bundled sounds in the root `sounds` folder are factory files' 'README factory sound update behavior'
    Assert-TextMatches $readme 'start a copy from a different folder' 'README different folder takeover behavior'
    Assert-TextMatches $readme 'Multiple machines can write to the same history database' 'README shared history explanation'
    Assert-TextMatches $readme 'Optional history password encryption' 'README encryption documentation'
    Assert-TextMatches $readme 'Mac Preferences reports whether database encryption is on and whether the password is saved in Keychain' 'README Mac encryption status documentation'
    Assert-TextMatches $readme 'Desktop-file-history\.clipdb' 'README persistent file-history documentation'
    Assert-TextMatches $readme 'remove unavailable unpinned events' 'README unavailable event cleanup documentation'
    Assert-TextMatches $readme 'deliberately ignores that generated password copy' 'README generated password documentation'
    Assert-TextMatches $readme 'old Clipman `clipman\.db` and Ditto SQLite databases' 'README SQLite import documentation'
    Assert-TextMatches $readme 'Press Backspace in the history list' 'README Backspace normal-entry shortcut'
    Assert-TextMatches $readme 'Help` > `Contact`' 'README contact documentation'
    Assert-TextMatches $readme 'Help` > `Donate`' 'README donate documentation'
    Assert-TextMatches $readme 'https://onj\.me/donate' 'README donate URL'
    Assert-TextMatches (Join-Path $repoRoot 'src\UpdateService.cs') 'https://onj\.me/donate' 'Windows donate URL'
    Assert-TextDoesNotMatch (Join-Path $repoRoot 'src\UpdateService.cs') 'paypal\.me' 'Windows donate URL does not use old PayPal URL'
    Assert-TextMatches (Join-Path $repoRoot 'ClipmanMac\Sources\Clipman\AppController.swift') 'https://onj\.me/donate' 'Mac donate URL'
    Assert-TextDoesNotMatch (Join-Path $repoRoot 'ClipmanMac\Sources\Clipman\AppController.swift') 'paypal\.me' 'Mac donate URL does not use old PayPal URL'
    Assert-TextMatches (Join-Path $repoRoot 'src\Program.Updater.cs') 'PublishCloseRequest' 'Updater shared close request code'
    Assert-TextMatches (Join-Path $repoRoot 'src\Program.Updater.cs') 'TryRestartUpdatedApp' 'Updater restart code'
    Assert-TextMatches (Join-Path $repoRoot 'src\Program.Updater.cs') 'ReplaceFactoryDirectory' 'Updater factory folder replacement code'
    Assert-TextMatches (Join-Path $repoRoot 'src\Program.Updater.cs') 'CleanupObsoleteFactorySoundBackups' 'Updater factory sound backup cleanup code'
    Assert-TextDoesNotMatch (Join-Path $repoRoot 'src\Program.Updater.cs') 'NewBackupZip|CreateFromDirectory' 'Updater app-root backup creation'
    Assert-TextMatches (Join-Path $repoRoot 'src\Program.cs') 'InstanceStateStore\.IsSameRunningFolder' 'Cross-folder instance takeover code'
    Assert-TextMatches (Join-Path $repoRoot 'src\ClipmanApplicationContext.cs') 'ClipDatabaseFile\.IsEncryptedFile\(settings\.DatabasePath\)' 'Startup encrypted database detection'
    Assert-TextMatches (Join-Path $repoRoot 'src\ClipmanApplicationContext.cs') 'IgnoredProcessMatches' 'Windows ignored process helper-prefix matching'
    Assert-TextMatches (Join-Path $repoRoot 'src\ClipmanApplicationContext.cs') 'processName\.StartsWith\(ignoredProcessName \+ "-"' 'Windows ignored process prefix separator matching'
    Assert-TextMatches (Join-Path $repoRoot 'src\ClipmanApplicationContext.cs') 'DefaultFileHistoryDatabasePath\(\)' 'Machine-specific file history database path'
    Assert-TextMatches (Join-Path $repoRoot 'src\FileClipboardEventStore.cs') 'FileClipboardDatabase' 'Persistent file history store'
    Assert-TextMatches (Join-Path $repoRoot 'src\FileClipboardEventStore.cs') 'TogglePinned' 'File history pinning store'
    Assert-TextMatches (Join-Path $repoRoot 'src\FileClipboardEventStore.cs') 'MoveEvents' 'File history move store'
    Assert-TextMatches (Join-Path $repoRoot 'src\FileClipboardEventStore.cs') 'RemoveAll\(e => !e\.Pinned' 'File history cleanup protects pinned events'
    Assert-TextMatches (Join-Path $repoRoot 'src\Models.cs') 'class ShortcutButton' 'Shortcut button accessible object'
    Assert-TextMatches (Join-Path $repoRoot 'src\Models.cs') 'override string KeyboardShortcut' 'Shortcut button keyboard shortcut accessibility'
    Assert-TextMatches (Join-Path $repoRoot 'src\HistoryForm.cs') 'ShortcutText = "Esc"' 'History close button shortcut accessibility'
    Assert-TextMatches (Join-Path $repoRoot 'src\PreferencesForm.cs') 'ShortcutText = "Esc"' 'Preferences close button shortcut accessibility'
    Assert-TextMatches (Join-Path $repoRoot 'src\ClipmanApplicationContext.cs') 'ShowDialog\(historyForm\)' 'Preferences opens as owned modal dialog'
    Assert-TextMatches (Join-Path $repoRoot 'src\HistoryForm.cs') 'Clear file history' 'File history clear UI'
    Assert-TextDoesNotMatch (Join-Path $repoRoot 'src\HistoryForm.cs') 'Text = "Clear file history \(Ctrl\+Del\)"|Text = "Remove missing files \(Alt\+Del\)"' 'No visible shortcut captions on file history buttons'
    Assert-TextMatches (Join-Path $repoRoot 'src\HistoryForm.cs') 'Ctrl\+Del' 'File history clear shortcut exposure'
    Assert-TextMatches (Join-Path $repoRoot 'src\HistoryForm.cs') 'Remove unavailable file-history events' 'File history unavailable cleanup UI'
    Assert-TextMatches (Join-Path $repoRoot 'src\HistoryForm.cs') 'Alt\+Del' 'File history unavailable cleanup shortcut exposure'
    Assert-TextMatches (Join-Path $repoRoot 'src\FileClipboardEventStore.cs') 'RemoveUnavailableEvents' 'File history unavailable cleanup store'
    Assert-TextMatches (Join-Path $repoRoot 'src\FileClipboardEventStore.cs') 'Files == null \|\| item\.Files\.Count == 0' 'File history cleanup removes non-file events'
    Assert-TextMatches (Join-Path $repoRoot 'src\HistoryForm.cs') 'Clear text &history' 'Clear text history menu item'
    Assert-TextMatches (Join-Path $repoRoot 'src\HistoryForm.cs') '&Import\.\.\.\\tCtrl\+I' 'Import menu shortcut'
    Assert-TextMatches (Join-Path $repoRoot 'src\HistoryForm.cs') '&Export\.\.\.\\tCtrl\+E' 'Export menu shortcut'
    Assert-TextMatches (Join-Path $repoRoot 'src\HistoryForm.cs') 'S&ort by' 'View sort submenu mnemonic'
    Assert-TextMatches (Join-Path $repoRoot 'src\HistoryForm.cs') 'Mac&hine' 'Sort by machine unique mnemonic'
    Assert-TextMatches (Join-Path $repoRoot 'src\HistoryForm.cs') 'Sort text history oldest &first' 'Text history oldest-first menu label'
    Assert-TextMatches (Join-Path $repoRoot 'src\HistoryForm.cs') 'Sort text history newest &first' 'Text history newest-first menu label'
    Assert-TextMatches (Join-Path $repoRoot 'src\HistoryForm.cs') 'Sort text history A &first' 'Text history A-first menu label'
    Assert-TextMatches (Join-Path $repoRoot 'src\HistoryForm.cs') 'Sort text history Z &first' 'Text history Z-first menu label'
    Assert-TextMatches (Join-Path $repoRoot 'src\HistoryForm.cs') 'Sort file history fewest files &first' 'File history fewest-files-first menu label'
    Assert-TextMatches (Join-Path $repoRoot 'src\HistoryForm.cs') 'Sort file history most files &first' 'File history most-files-first menu label'
    Assert-TextDoesNotMatch (Join-Path $repoRoot 'src\HistoryForm.cs') 'Switch to de&scending sort|Sort text history &ascending|Sort text history de&scending|Sort file history &ascending|Sort file history de&scending' 'Old sort direction wording'
    Assert-TextMatches (Join-Path $repoRoot 'src\HistoryForm.cs') 'Copy and c&lose' 'Copy and close unique mnemonic'
    Assert-TextMatches (Join-Path $repoRoot 'src\HistoryForm.cs') 'Paste &after selected' 'Paste after selected unique mnemonic'
    Assert-TextDoesNotMatch (Join-Path $repoRoot 'src\HistoryForm.cs') '&Paste after selected' 'Old Paste after selected duplicate mnemonic'
    Assert-TextMatches (Join-Path $repoRoot 'src\HistoryForm.cs') 'Find previou&s' 'Find previous unique mnemonic'
    Assert-TextMatches (Join-Path $repoRoot 'src\HistoryForm.cs') 'HTML enc&ode' 'Actions menu HTML encode unique mnemonic'
    Assert-TextMatches (Join-Path $repoRoot 'src\HistoryForm.cs') 'Clean link for sharin&g' 'Actions menu clean-link unique mnemonic'
    Assert-TextMatches (Join-Path $repoRoot 'src\HistoryForm.cs') 'Pin or unp&in' 'Pin menu text uses non-conflicting mnemonic'
    Assert-TextDoesNotMatch (Join-Path $repoRoot 'src\HistoryForm.cs') 'Sort by &machine|&Trim leading|HTML &encode|Clean link for &sharing|&URL encode|Find &previous|&Copy and close|&Clear file history|Pin or &unpin|&Unpin selected|&Pin selected|Toggle &pinned state' 'Avoid duplicate menu mnemonics'
    Assert-TextMatches (Join-Path $repoRoot 'src\PreferencesForm.cs') 'Add runn&ing app' 'Storage tab Add running app unique mnemonic'
    Assert-TextDoesNotMatch (Join-Path $repoRoot 'src\PreferencesForm.cs') 'Add &running app' 'Storage tab avoids duplicate Alt+R mnemonic'
    Assert-HistoryMenuMnemonics (Join-Path $repoRoot 'src\HistoryForm.cs')
    Assert-PreferencesTabMnemonics (Join-Path $repoRoot 'src\PreferencesForm.cs')
    Assert-TextMatches (Join-Path $repoRoot 'Build.ps1') 'Version .* has already been released as tag' 'Build guard for released version reuse'
    Assert-TextMatches (Join-Path $repoRoot 'Build.ps1') 'AssemblyInformationalVersion' 'Build guard reads assembly version'
    Assert-TextMatches (Join-Path $repoRoot 'CommunitySearch.ps1') 'Clipman community search' 'Community search helper heading'
    Assert-TextMatches (Join-Path $repoRoot 'CommunitySearch.ps1') 'OnjLouis/Clipman' 'Community search helper repo query'
    Assert-TextMatches (Join-Path $repoRoot 'CommunitySearch.ps1') 'screen reader' 'Community search helper accessibility query'
    Assert-TextMatches (Join-Path $repoRoot 'CommunitySearch.ps1') 'forum\.audiogames\.net' 'Community search helper community query'
    Assert-TextMatches (Join-Path $repoRoot 'src\ClipmanApplicationContext.cs') 'CopySensitiveTextToClipboard' 'Sensitive clipboard copy suppression'
    Assert-TextMatches (Join-Path $repoRoot 'src\ClipmanApplicationContext.cs') 'if \(IsClipmanProcess\(sourceProcessName\)\)\s*\{\s*return;\s*\}\s*if \(IsIgnoredProcess\(sourceProcessName\)\)\s*\{\s*sounds\.Skip' 'Clipman-owned clipboard updates are silent, not skip-sounded'
    Assert-TextMatches (Join-Path $repoRoot 'src\ClipmanApplicationContext.cs') 'sounds\.Remote\(settings\.SoundsEnabled\)' 'Remote clipboard sync uses remote sound'
    Assert-TextMatches (Join-Path $repoRoot 'src\SoundService.cs') 'Remote\(bool enabled\).*remote\.wav' 'Remote sound service method'
    Assert-TextMatches (Join-Path $repoRoot 'src\ClipmanApplicationContext.cs') 'LastPreferencesTab' 'Preferences tab persistence application'
    Assert-TextMatches (Join-Path $repoRoot 'src\ClipmanApplicationContext.cs') 'AutoRemoveUnavailableFileHistoryEvents = updated\.AutoRemoveUnavailableFileHistoryEvents' 'File history auto cleanup preference applies live'
    Assert-TextMatches (Join-Path $repoRoot 'src\ClipmanApplicationContext.cs') 'DiagnosticsFileHistoryLimit = updated\.DiagnosticsFileHistoryLimit' 'Diagnostics file-history limit preference applies live'
    Assert-TextMatches (Join-Path $repoRoot 'src\ClipmanApplicationContext.cs') 'saveListPositionTurnedOff' 'Save position disables stale saved index'
    Assert-TextMatches (Join-Path $repoRoot 'src\PreferencesForm.cs') 'SelectPreferencesTabByShortcut' 'Preferences tab shortcut code'
    Assert-TextMatches (Join-Path $repoRoot 'src\PreferencesForm.cs') 'Shortcut Ctrl\+1' 'Preferences tab shortcut accessibility text'
    Assert-TextMatches (Join-Path $repoRoot 'src\PreferencesForm.cs') 'Shortcut Ctrl\+5' 'Preferences fifth tab shortcut accessibility text'
    Assert-TextMatches (Join-Path $repoRoot 'src\PreferencesForm.cs') 'Shortcut Ctrl\+6' 'Preferences sixth tab shortcut accessibility text'
    Assert-TextMatches (Join-Path $repoRoot 'src\PreferencesForm.cs') 'Automatically remove &unavailable file-history events' 'File history preference auto cleanup checkbox'
    Assert-TextMatches (Join-Path $repoRoot 'src\PreferencesForm.cs') 'Automatically group &new clips by source application' 'General preference auto-group unique mnemonic'
    Assert-TextMatches (Join-Path $repoRoot 'src\PreferencesForm.cs') 'Run Clipman at Windows &startup' 'Startup tab Run at startup unique mnemonic'
    Assert-TextMatches (Join-Path $repoRoot 'src\PreferencesForm.cs') 'Add current &clipboard item to Clipman on start' 'Startup tab startup clipboard capture unique mnemonic'
    Assert-TextDoesNotMatch (Join-Path $repoRoot 'src\PreferencesForm.cs') 'Add current clipboard item to Clipman on &start' 'Startup tab avoids duplicate Alt+S mnemonic'
    Assert-TextMatches (Join-Path $repoRoot 'src\PreferencesForm.cs') 'Diagnostics event limit' 'File history preference diagnostics limit'
    Assert-TextMatches (Join-Path $repoRoot 'src\Models.cs') 'LastPreferencesTab' 'Preferences tab persistence setting'
    Assert-TextMatches (Join-Path $repoRoot 'src\Models.cs') 'AutoRemoveUnavailableFileHistoryEvents' 'Auto unavailable file-history cleanup setting'
    Assert-TextMatches (Join-Path $repoRoot 'src\Models.cs') 'DiagnosticsFileHistoryLimit' 'Diagnostics file-history limit setting'
    Assert-TextMatches (Join-Path $repoRoot 'src\ClipmanApplicationContext.cs') 'Details omitted by diagnostics preference' 'Diagnostics file-history detail cap'
    Assert-TextMatches (Join-Path $repoRoot 'src\HistoryForm.cs') 'SaveCurrentListPositionIfEnabled' 'Save position preference gates list position writes'
    Assert-TextMatches (Join-Path $repoRoot 'src\HistoryForm.cs') 'ResetListPositionIfDisabled' 'Save position off resets live ListView selection on show'
    Assert-TextMatches (Join-Path $repoRoot 'src\HistoryForm.cs') 'if \(settings\.SaveListPosition\) return;\s*if \(IsFileClipboardTabActive\(\)\) return;\s*SelectDefaultHistoryIndex\(\);' 'Save position reset only applies when disabled on text history'
    Assert-TextMatches (Join-Path $repoRoot 'src\HistoryForm.cs') 'private void CloseHistoryWindow\(\)\s*\{\s*SaveCurrentListPositionIfEnabled\(\);\s*Hide\(\);' 'Close history saves selected position before hiding'
    Assert-TextMatches (Join-Path $repoRoot 'src\HistoryForm.cs') '(?s)protected override void OnVisibleChanged\(EventArgs e\).*SaveCurrentListPositionIfEnabled\(\);' 'Any history hide saves selected position'
    Assert-TextDoesNotMatch (Join-Path $repoRoot 'src\HistoryForm.cs') 'settings\.LastSelectedIndex = list\.SelectedIndices\.Count > 0 \? list\.SelectedIndices\[0\] : -1;\s*saveSettings\(\);' 'No unconditional list-position save'
    Assert-TextMatches (Join-Path $repoRoot 'src\PreferencesForm.cs') 'Play &sounds' 'Preferences Play sounds unique mnemonic'
    Assert-TextMatches (Join-Path $repoRoot 'src\PreferencesForm.cs') 'Save list &position' 'Preferences Save list position unique mnemonic'
    Assert-TextDoesNotMatch (Join-Path $repoRoot 'src\PreferencesForm.cs') '&Play sounds' 'Preferences old duplicate Play sounds mnemonic'
    Assert-TextMatches (Join-Path $repoRoot 'src\HistoryForm.cs') 'GoToSelectedFileClipboardEvent' 'File history go-to-file command'
    Assert-TextMatches (Join-Path $repoRoot 'src\HistoryForm.cs') 'fileEventsList\.KeyPress \+= FileEventsListKeyPress' 'File history keypress navigation hook'
    Assert-TextMatches (Join-Path $repoRoot 'src\HistoryForm.cs') 'TypeSearchFileHistory' 'File history buffered type-to-jump implementation'
    Assert-TextMatches (Join-Path $repoRoot 'src\HistoryForm.cs') 'FileEventSearchText' 'File history filename search target'
    Assert-TextMatches (Join-Path $repoRoot 'src\HistoryForm.cs') 'return string\.IsNullOrWhiteSpace\(first\) \? "File clipboard event" : first;' 'File history primary column contains filename only'
    Assert-TextMatches (Join-Path $repoRoot 'src\HistoryForm.cs') 'fileEventsList\.Columns\.Add\("Operation", 90\);[\s\S]*fileEventsList\.Columns\.Add\("Files", 70\);[\s\S]*fileEventsList\.Columns\.Add\("Source", 120\);' 'File history columns read filename, operation, files, then source'
    Assert-TextMatches (Join-Path $repoRoot 'src\HistoryForm.cs') 'Ctrl\+Enter' 'File history go-to-file shortcut text'
    Assert-TextMatches (Join-Path $repoRoot 'src\HistoryForm.cs') 'FilePinMenuText' 'File history pin menu text'
    Assert-TextMatches (Join-Path $repoRoot 'src\HistoryForm.cs') 'RestorePinnedFileClipboardEventByPosition' 'File history Ctrl+number pinned restore'
    Assert-TextMatches (Join-Path $repoRoot 'src\HistoryForm.cs') 'CopyPinnedFileClipboardEventPathsByPosition' 'File history Ctrl+Shift+number pinned path copy'
    Assert-TextMatches (Join-Path $repoRoot 'src\HistoryForm.cs') 'SelectedPinnedEntryShortcutPosition' 'Pinned text context menu shortcut detection'
    Assert-TextMatches (Join-Path $repoRoot 'src\HistoryForm.cs') 'SelectedPinnedFileEventShortcutPosition' 'Pinned file context menu shortcut detection'
    Assert-TextMatches (Join-Path $repoRoot 'src\HistoryForm.cs') 'Copy pinned entry' 'Pinned text context menu shortcut item'
    Assert-TextMatches (Join-Path $repoRoot 'src\HistoryForm.cs') 'Copy pinned file paths' 'Pinned file context menu path shortcut item'
    Assert-TextMatches (Join-Path $repoRoot 'src\HistoryForm.cs') 'Entry &properties\.\.\.\\tF2' 'Entry Properties is exposed on F2'
    Assert-TextMatches (Join-Path $repoRoot 'src\HistoryForm.cs') '(?s)e\.KeyCode == Keys\.F2.*ShowEntryProperties\(\);' 'F2 opens full Entry Properties workflow'
    Assert-TextMatches (Join-Path $repoRoot 'src\HistoryForm.cs') '(?s)e\.Alt && e\.KeyCode == Keys\.Enter.*SuppressKeyPress = true.*Use F2 for Entry Properties' 'Removed Alt Enter shortcut is blocked rather than falling through to copy'
    Assert-TextMatches (Join-Path $repoRoot 'src\HistoryForm.cs') '(?s)key >= Keys\.D1 && key <= Keys\.D9.*JumpToGroupByPosition\(key - Keys\.D1\).*return true;.*key == Keys\.D0.*JumpToGroupByPosition\(9\).*return true;' 'Alt+number group shortcuts are consumed before the menu bar receives them'
    Assert-TextMatches (Join-Path $repoRoot 'src\HistoryForm.cs') 'groupMenuItem = new ToolStripMenuItem\("Grou&ps"\)' 'Windows menu bar exposes Groups without stealing Alt+G'
    Assert-TextMatches (Join-Path $repoRoot 'src\HistoryForm.cs') 'private void PopulateGroupMenu\(\)' 'Windows Groups menu is populated dynamically'
    Assert-TextMatches (Join-Path $repoRoot 'src\HistoryForm.cs') 'return "&" \+ shortcutNumber \+ " " \+ \(group \?\? string\.Empty\) \+ "\\tAlt\+" \+ shortcutNumber;' 'Windows Groups menu displays Alt+number filter shortcuts'
    Assert-TextMatches (Join-Path $repoRoot 'src\ClipmanApplicationContext.cs') 'new HistoryForm\(store, settings, SaveSettings, RegisterHotkeys' 'Entry Properties can refresh Quick Paste hotkey registrations'
    Assert-TextMatches (Join-Path $repoRoot 'src\HistoryForm.cs') 'QuickCopyAssignmentChanged' 'Quick Paste assignment changes are detected'
    Assert-TextMatches (Join-Path $repoRoot 'src\HistoryForm.cs') 'refreshHotkeys\(\);' 'Quick Paste assignment changes refresh registered hotkeys'
    Assert-TextMatches (Join-Path $repoRoot 'src\Models.cs') 'public string Mode \{ get; set; \}' 'Quick Paste bindings store per-target mode'
    Assert-TextMatches (Join-Path $repoRoot 'src\EntryPropertiesForm.cs') 'Paste and &restore previous clipboard' 'Entry Properties exposes paste-and-restore mode'
    Assert-TextMatches (Join-Path $repoRoot 'src\EntryPropertiesForm.cs') 'Paste and &keep target on clipboard' 'Entry Properties exposes paste-and-keep mode'
    Assert-TextMatches (Join-Path $repoRoot 'src\EntryPropertiesForm.cs') 'Copy to clipboard &only' 'Entry Properties exposes copy-only mode'
    Assert-TextMatches (Join-Path $repoRoot 'src\TextBoundaryNavigator.cs') 'public static int NextBoundary' 'Windows text boundary navigation exposes testable next-boundary logic'
    Assert-TextMatches (Join-Path $repoRoot 'src\TextBoundaryNavigator.cs') 'public static int PreviousBoundary' 'Windows text boundary navigation exposes testable previous-boundary logic'
    Assert-TextMatches (Join-Path $repoRoot 'src\TextBoundaryNavigator.cs') 'SelectionState' 'Windows text boundary navigation tracks selection anchor and caret separately'
    Assert-TextDoesNotMatch (Join-Path $repoRoot 'src\TextBoundaryNavigator.cs') 'NotifyWinEvent' 'Windows text boundary navigation leaves edit selection announcements to NVDA'
    Assert-TextMatches (Join-Path $repoRoot 'src\clipman.exe.manifest') 'Microsoft\.Windows\.Common-Controls' 'Windows manifest enables Common Controls v6 for accessible native controls'
    Assert-TextMatches (Join-Path $repoRoot 'src\clipman.exe.manifest') '<dpiAware>true</dpiAware>' 'Windows manifest declares DPI awareness for reliable screen-reader caret geometry'
    Assert-TextMatches (Join-Path $repoRoot 'src\TextViewerForm.cs') 'TextBoundaryNavigator\.Attach\(textBox\)' 'Windows F4 text viewer uses URL/code boundary navigation'
    Assert-TextMatches (Join-Path $repoRoot 'src\EntryPropertiesForm.cs') 'TextBoundaryNavigator\.Attach\(textBox\)' 'Windows Entry Properties clipboard text uses URL/code boundary navigation'
    Assert-TextMatches $manual 'URL/code-friendly word navigation' 'Manual documents URL/code boundary navigation'
    Assert-TextMatches $readme 'URL/code-friendly word navigation' 'README documents URL/code boundary navigation'
    Assert-TextMatches (Join-Path $repoRoot 'src\ClipmanApplicationContext.cs') 'mode == QuickPasteModes\.CopyOnly' 'Quick Paste copy-only mode does not send paste'
    Assert-TextMatches (Join-Path $repoRoot 'src\ClipmanApplicationContext.cs') 'mode == QuickPasteModes\.PasteKeep' 'Quick Paste paste-and-keep mode sends paste without restore'
    Assert-TextDoesNotMatch (Join-Path $repoRoot 'src\HistoryForm.cs') 'list\.Columns\.Add\("Quick Paste"' 'Windows history list does not expose Quick Paste as a noisy per-row column'
    Assert-TextMatches (Join-Path $repoRoot 'src\HistoryForm.cs') 'EntryDisplayText\(entry, ref pinnedEntryPosition\)' 'Windows history rows include pinned and Quick Paste status only when applicable'
    Assert-TextMatches (Join-Path $repoRoot 'src\HistoryForm.cs') 'QuickPasteModeDisplayText\(binding\.Mode\)' 'Windows history rows include Quick Paste mode for assigned targets'
    Assert-TextMatches (Join-Path $repoRoot 'src\HistoryForm.cs') 'quickPasteMenuItem = new ToolStripMenuItem\("&Quick Paste"\)' 'Windows menu bar exposes Quick Paste targets'
    Assert-TextMatches (Join-Path $repoRoot 'src\HistoryForm.cs') 'private void PopulateQuickPasteMenu\(\)' 'Windows Quick Paste target menu is populated dynamically'
    Assert-TextMatches (Join-Path $repoRoot 'src\HistoryForm.cs') 'FocusEntry\(selected\)' 'Windows Quick Paste target menu jumps to the assigned entry'
    Assert-TextMatches (Join-Path $repoRoot 'src\ClipmanApplicationContext.cs') 'private void QuickPasteEntry\(string entryId\)' 'Quick Paste hotkey uses paste workflow'
    Assert-TextMatches (Join-Path $repoRoot 'src\ClipmanApplicationContext.cs') 'SnapshotClipboardData\(\)' 'Quick Paste snapshots the current clipboard before replacing it'
    Assert-TextMatches (Join-Path $repoRoot 'src\ClipmanApplicationContext.cs') 'CloneClipboardFormatData' 'Quick Paste clones clipboard payloads before restore'
    Assert-TextMatches (Join-Path $repoRoot 'src\ClipmanApplicationContext.cs') 'WaitForHotkeyModifiersReleased' 'Quick Paste waits for global hotkey modifiers to be released'
    Assert-TextMatches (Join-Path $repoRoot 'src\ClipmanApplicationContext.cs') 'SendCtrlVPaste' 'Quick Paste sends Ctrl+V to active app'
    Assert-TextMatches (Join-Path $repoRoot 'src\ClipmanApplicationContext.cs') 'RestoreClipboard\(previousClipboard\)' 'Quick Paste restores previous clipboard where possible'
    Assert-TextMatches (Join-Path $repoRoot 'src\ClipmanApplicationContext.cs') 'PruneInvalidQuickPasteBindings\(\)' 'Quick Paste drops stale bindings before registering global hotkeys'
    Assert-TextMatches (Join-Path $repoRoot 'src\ClipmanApplicationContext.cs') 'entry == null \|\|\s+string\.IsNullOrEmpty\(entry\.Text\)' 'Quick Paste stale binding cleanup verifies target entries still contain text'
    Assert-TextMatches (Join-Path $repoRoot 'src\ClipmanApplicationContext.cs') '(?s)internal void HandleHotkey\(int id\).*quickCopyHotkeyEntryIds\.ContainsKey\(id\).*QuickPasteEntry\(quickCopyHotkeyEntryIds\[id\]\);' 'Quick Paste hotkeys are handled directly, not gated by monitoring state'
    Assert-TextMatches (Join-Path $repoRoot 'src\ClipmanApplicationContext.cs') '(?s)internal void HandleClipboardUpdate\(\).*ignoredClipboardChangeCount > 0.*return;.*if \(!settings\.Active\)' 'Quick Paste internal clipboard writes are ignored before monitoring-off handling'
    Assert-TextMatches (Join-Path $repoRoot 'src\NativeMethods.cs') 'GetAsyncKeyState' 'Quick Paste modifier-release check uses Win32 key state'
    Assert-TextMatches (Join-Path $repoRoot 'src\NativeMethods.cs') 'keybd_event' 'Quick Paste sends low-level paste keystrokes'
    Assert-TextMatches (Join-Path $repoRoot 'src\Hotkey.cs') 'if \(windowsModifierPressed\) parts\.Add\("Win"\)' 'Windows hotkey capture can include Windows key modifier'
    Assert-TextMatches (Join-Path $repoRoot 'src\Hotkey.cs') 'IsWindowsKeyPressed\(\)' 'Windows hotkey capture checks Windows key state'
    Assert-TextMatches (Join-Path $repoRoot 'src\Hotkey.cs') 'private static bool IsAllowedSingleModifierKey\(Keys key\)' 'Windows hotkey validation has a narrow single-modifier allowlist'
    Assert-TextMatches (Join-Path $repoRoot 'src\Hotkey.cs') 'case Keys\.Oem3:' 'Windows single-modifier hotkeys allow Grave'
    Assert-TextMatches (Join-Path $repoRoot 'src\Hotkey.cs') 'case Keys\.Oem5:' 'Windows single-modifier hotkeys allow Backslash'
    Assert-TextDoesNotMatch (Join-Path $repoRoot 'src\Hotkey.cs') 'IsAllowedSingleModifierKey[\s\S]{0,220}Oemcomma' 'Windows single-modifier hotkeys do not allow Ctrl comma'
    Assert-TextMatches (Join-Path $repoRoot 'ClipmanMac\Sources\Clipman\HotkeyDescriptor.swift') 'isSingleModifierPunctuationKey' 'Mac hotkey validation has a narrow single-modifier allowlist'
    Assert-TextMatches (Join-Path $repoRoot 'ClipmanMac\Sources\Clipman\HotkeyDescriptor.swift') 'kVK_ANSI_Backslash, kVK_ANSI_Grave, kVK_ISO_Section' 'Mac single-modifier hotkeys allow Backslash, Grave, and ISO section only'
    Assert-TextMatches (Join-Path $repoRoot 'ClipmanMac\Sources\Clipman\HotkeyDescriptor.swift') 'modifiers == \[\.command\], keyCode == UInt32\(kVK_ANSI_Grave\)' 'Mac rejects Command Grave as a global hotkey'
    Assert-TextMatches $manual 'Single-modifier letters, numbers, comma, space, Tab, Delete, Backspace, Escape, and reserved operating-system shortcuts are rejected' 'Manual documents blocked single-modifier shortcuts'
    Assert-TextMatches $readme 'Single-modifier letters, numbers, comma, space, Tab, Delete, Backspace, Escape, and reserved operating-system shortcuts are rejected' 'README documents blocked single-modifier shortcuts'
    Assert-TextMatches (Join-Path $repoRoot 'src\PreferencesForm.cs') 'ReadOnly = false' 'Preferences hotkey fields are not exposed as read-only'
    Assert-TextMatches (Join-Path $repoRoot 'src\PreferencesForm.cs') '\(\(TextBox\)sender\)\.Clear\(\);' 'Preferences hotkey fields clear with Delete or Backspace'
    Assert-TextMatches (Join-Path $repoRoot 'src\EntryPropertiesForm.cs') 'ReadOnly = false' 'Entry Properties Quick Paste hotkey field is not exposed as read-only'
    Assert-TextMatches (Join-Path $repoRoot 'src\EntryPropertiesForm.cs') '\(\(TextBox\)sender\)\.Clear\(\);' 'Entry Properties Quick Paste hotkey clears with Delete or Backspace'
    Assert-TextMatches (Join-Path $repoRoot 'src\EntryPropertiesForm.cs') 'quickCopyTargetBox\.Checked = false;' 'Clearing Entry Properties Quick Paste hotkey removes the assignment'
    Assert-UniqueWindowsControlMnemonics (Join-Path $repoRoot 'src\EntryPropertiesForm.cs') 'Entry Properties dialog'
    Assert-TextMatches (Join-Path $repoRoot 'src\Models.cs') 'public bool IsTemplate \{ get; set; \}' 'Windows shared entries store template flag'
    Assert-TextMatches (Join-Path $repoRoot 'src\TemplateResolver.cs') 'class TemplateResolver|static class TemplateResolver' 'Windows template resolver exists'
    Assert-TextMatches (Join-Path $repoRoot 'src\TemplateResolver.cs') 'month_name_full' 'Windows template resolver supports month_name_full alias'
    Assert-TextMatches (Join-Path $repoRoot 'src\EntryPropertiesForm.cs') 'Template entry' 'Windows Entry Properties exposes template entry checkbox'
    Assert-TextMatches (Join-Path $repoRoot 'src\EntryPropertiesForm.cs') 'Insert &sample' 'Windows Entry Properties exposes template sample insertion'
    Assert-TextMatches (Join-Path $repoRoot 'src\EntryPropertiesForm.cs') 'Insert &field' 'Windows Entry Properties exposes template field insertion'
    Assert-TextMatches (Join-Path $repoRoot 'src\TemplateResolver.cs') '\{\{year_full\}\} - four-digit year' 'Windows template variable reference is line-oriented'
    Assert-TextMatches (Join-Path $repoRoot 'src\TemplateResolver.cs') 'Date, year/month/day' 'Windows template presets include year/month/day'
    Assert-TextMatches (Join-Path $repoRoot 'src\TemplateResolver.cs') 'Date, day short-month year' 'Windows template presets include non-US date'
    Assert-TextMatches (Join-Path $repoRoot 'src\SensitiveDataExclusion.cs') 'international-phone' 'Windows sensitive data presets include international phone'
    Assert-TextMatches (Join-Path $repoRoot 'src\SensitiveDataExclusion.cs') 'if \(IsFullHttpUrl\(text\)\) return null;' 'Windows sensitive data exclusions bypass complete HTTP URLs'
    Assert-TextMatches (Join-Path $repoRoot 'src\SensitiveDataExclusion.cs') 'software-license-key' 'Windows sensitive data presets include software license key'
    Assert-TextMatches (Join-Path $repoRoot 'src\SensitiveDataExclusion.cs') 'PassesLuhn' 'Windows sensitive data credit-card preset validates Luhn'
    Assert-TextMatches (Join-Path $repoRoot 'src\PreferencesForm.cs') 'Sensitive data preferences' 'Windows Preferences exposes sensitive data tab'
    Assert-TextMatches (Join-Path $repoRoot 'src\ClipboardPrivacySignals.cs') 'Clipboard Viewer Ignore' 'Windows privacy signal checks Clipboard Viewer Ignore'
    Assert-TextMatches (Join-Path $repoRoot 'src\ClipboardPrivacySignals.cs') 'ExcludeClipboardContentFromMonitorProcessing' 'Windows privacy signal checks Microsoft monitor exclusion'
    Assert-TextMatches (Join-Path $repoRoot 'src\ClipboardPrivacySignals.cs') 'CanIncludeInClipboardHistory' 'Windows privacy signal checks clipboard history opt-out'
    Assert-TextMatches (Join-Path $repoRoot 'src\ClipboardPrivacySignals.cs') 'CanUploadToCloudClipboard' 'Windows privacy signal checks cloud clipboard upload opt-out'
    Assert-TextMatches (Join-Path $repoRoot 'src\ClipmanApplicationContext.cs') 'ClipboardPrivacySignals\.Detect' 'Windows capture path checks clipboard privacy signals'
    Assert-TextMatches (Join-Path $repoRoot 'src\ClipmanApplicationContext.cs') 'SensitiveDataExclusion\.FindMatch' 'Windows capture path checks sensitive data exclusions'
    Assert-TextMatches (Join-Path $repoRoot 'src\ClipmanApplicationContext.cs') 'sounds\.Exclude' 'Windows sensitive data exclusion plays exclude sound'
    Assert-TextMatches (Join-Path $repoRoot 'src\HistoryForm.cs') 'PasteAfterSelected' 'Windows history exposes intentional paste into history'
    Assert-TextDoesNotMatch (Join-Path $repoRoot 'src\HistoryForm.cs') 'PasteAfterSelected[\s\S]{0,2200}SensitiveDataExclusion\.FindMatch' 'Intentional paste into Windows history bypasses automatic sensitive-data exclusion'
    Assert-TextMatches (Join-Path $repoRoot 'src\ServerSettingsSanitizer.cs') 'CleanUrl' 'Windows server settings sanitizer cleans pasted URL text'
    Assert-TextMatches (Join-Path $repoRoot 'src\ServerSettingsSanitizer.cs') 'AuthToken' 'Windows server settings sanitizer extracts copied JSON token lines'
    Assert-TextMatches (Join-Path $repoRoot 'src\ServerSettingsSanitizer.cs') '"clipman://" \+ cleaned' 'Windows server settings sanitizer infers local Clipman protocol for host:port values'
    Assert-TextMatches (Join-Path $repoRoot 'src\ServerSettingsSanitizer.cs') 'CleanTransportUrl' 'Windows server storage converts clipman protocol to transport URL internally'
    Assert-TextMatches (Join-Path $repoRoot 'src\PreferencesForm.cs') 'ServerSettingsSanitizer\.CleanUrl' 'Windows Preferences cleans server host before saving'
    Assert-TextMatches (Join-Path $repoRoot 'src\PreferencesForm.cs') 'Server &host:' 'Windows Preferences labels server connection as host rather than URL'
    Assert-TextDoesNotMatch (Join-Path $repoRoot 'src\PreferencesForm.cs') 'Server &URL:' 'Windows Preferences no longer exposes URL wording for server host'
    Assert-TextMatches (Join-Path $repoRoot 'src\SettingsStore.cs') 'ServerSettingsSanitizer\.CleanToken' 'Windows SettingsStore cleans server token before saving'
    Assert-TextMatches (Join-Path $repoRoot 'src\Models.cs') '\[ScriptIgnore\]\s*public string ServerToken' 'Windows settings do not serialize raw server token'
    Assert-TextMatches (Join-Path $repoRoot 'src\Models.cs') 'ProtectedServerToken' 'Windows settings store protected server token'
    Assert-TextMatches (Join-Path $repoRoot 'src\SettingsStore.cs') 'ServerTokenProtector\.Protect' 'Windows SettingsStore protects server token before saving'
    Assert-TextMatches (Join-Path $repoRoot 'src\SettingsStore.cs') 'ReadStringProperty\(SettingsPath, "ServerToken"\)' 'Windows SettingsStore migrates old plaintext server token'
    Assert-TextMatches (Join-Path $repoRoot 'src\PreferencesForm.cs') 'serverToken\.UseSystemPasswordChar = true' 'Windows Preferences hides server token field'
    Assert-TextMatches (Join-Path $repoRoot 'src\ServerTokenProtector.cs') 'ProtectedData\.Protect' 'Windows server token uses DPAPI user protection'
    Assert-TextMatches (Join-Path $repoRoot 'src\ServerTokenProtector.cs') 'DataProtectionScope\.CurrentUser' 'Windows server token protection is per Windows user'
    Assert-TextMatches (Join-Path $repoRoot 'src\ServerDatabaseIdentity.cs') 'HMACSHA256' 'Windows server database identity is derived without exposing the history password'
    Assert-TextMatches (Join-Path $repoRoot 'src\ServerDatabaseIdentity.cs') 'NoPasswordMarker' 'Windows server database identity separates no-password histories'
    Assert-TextMatches (Join-Path $repoRoot 'src\ServerStorageClient.cs') 'api/v1/database/' 'Windows server client uses database-scoped endpoints'
    Assert-TextMatches (Join-Path $repoRoot 'src\ClipmanApplicationContext.cs') 'EffectiveTextHistoryDatabasePath' 'Windows server mode has an effective local text-history cache path'
    Assert-TextMatches (Join-Path $repoRoot 'src\ClipmanApplicationContext.cs') 'ServerCache' 'Windows server mode cache avoids reusing the shared-folder database path'
    Assert-TextMatches (Join-Path $repoRoot 'src\ClipmanApplicationContext.cs') 'SeedServerCacheFromConfiguredDatabase' 'Windows server mode seeds local cache from the configured database before first server upload'
    Assert-TextMatches (Join-Path $repoRoot 'src\ClipStore.cs') 'server-download\.tmp' 'Server downloads validate in a temp file before replacing local cache'
    Assert-TextMatches (Join-Path $repoRoot 'src\ClipStore.cs') 'HasLocalStateMissingFromServer' 'Windows server sync merges local state into server downloads before upload'
    Assert-TextMatches (Join-Path $repoRoot 'src\ClipStore.cs') 'AddDeletedEntryLocked' 'Windows server sync records text-history deletions'
    Assert-TextMatches (Join-Path $repoRoot 'src\ClipStore.cs') 'MergeDeletedEntries' 'Windows server sync merges text-history deletion markers'
    Assert-TextMatches (Join-Path $repoRoot 'src\Models.cs') 'DeletedClipEntry' 'Shared text-history database stores deletion markers'
    Assert-TextMatches (Join-Path $repoRoot 'src\ClipStore.cs') 'SyncFromServerLocked\(false\)' 'Reload retries server sync when server storage is configured'
    Assert-TextMatches (Join-Path $repoRoot 'src\ClipStore.cs') 'QueueInitialServerSync\(\)' 'Windows first server sync is queued outside the Preferences apply path'
    Assert-TextMatches (Join-Path $repoRoot 'src\ClipStore.cs') 'ThreadPool\.QueueUserWorkItem' 'Windows first server sync uses a background worker'
    Assert-TextMatches (Join-Path $repoRoot 'ClipmanMac\Sources\ClipmanCore\Models.swift') 'DeletedClipEntry' 'Mac shared model stores text-history deletion markers'
    Assert-TextMatches (Join-Path $repoRoot 'ClipmanMac\Sources\ClipmanCore\SyncConflictResolver.swift') 'mergeDeletedEntries' 'Mac conflict resolver merges text-history deletion markers'
    Assert-TextMatches (Join-Path $repoRoot 'ClipmanMac\Sources\ClipmanCore\ServerDatabaseIdentity.swift') 'Clipman\.ServerDatabaseId\.v1' 'Mac server database identity uses the shared server purpose string'
    Assert-TextMatches (Join-Path $repoRoot 'ClipmanMac\Sources\Clipman\ServerSettingsSanitizer.swift') 'cleanURL' 'Mac server settings sanitizer cleans pasted host text'
    Assert-TextMatches (Join-Path $repoRoot 'ClipmanMac\Sources\Clipman\ServerStorageClient.swift') 'api/v1/database/' 'Mac server client uses database-scoped endpoints'
    Assert-TextMatches (Join-Path $repoRoot 'ClipmanMac\Sources\Clipman\ServerStorageClient.swift') 'ServerStorageError\.timeout' 'Mac server client has a hard timeout instead of hanging the store queue'
    Assert-TextMatches (Join-Path $repoRoot 'ClipmanMac\Sources\Clipman\ServerStorageClient.swift') 'rawHTTPRequestWithTimeout' 'Mac raw socket transport is wrapped in a hard timeout for local clipman server URLs'
    Assert-TextMatches (Join-Path $repoRoot 'ClipmanMac\Sources\Clipman\AppController.swift') 'enforceSingleRunningInstance' 'Mac app enforces a single running Clipman instance before starting the clipboard monitor'
    Assert-TextMatches (Join-Path $repoRoot 'ClipmanMac\Sources\Clipman\AppController.swift') 'NSRunningApplication\.runningApplications\(withBundleIdentifier:' 'Mac app detects another running Clipman instance by bundle identifier'
    Assert-TextMatches (Join-Path $repoRoot 'ClipmanMac\Sources\Clipman\AppController.swift') 'existing\.terminate\(\)' 'Mac app gracefully asks the existing Clipman instance to quit before takeover'
    Assert-TextMatches (Join-Path $repoRoot 'ClipmanMac\Sources\Clipman\AppController.swift') 'two clipboard monitors do not run at the same time' 'Mac single-instance failure warning explains why the new copy exits'
    Assert-TextMatches (Join-Path $repoRoot 'ClipmanMac\Sources\Clipman\ClipmanSettings.swift') 'StorageMode' 'Mac settings store server storage mode'
    Assert-TextDoesNotMatch (Join-Path $repoRoot 'ClipmanMac\Sources\Clipman\ClipmanSettings.swift') 'encode\(serverToken' 'Mac settings do not serialize raw server token'
    Assert-TextMatches (Join-Path $repoRoot 'ClipmanMac\Sources\Clipman\PreferencesWindowController.swift') 'serverTokenField = NSSecureTextField' 'Mac Preferences hides server token field'
    Assert-TextMatches (Join-Path $repoRoot 'ClipmanMac\Sources\Clipman\AppController.swift') 'KeychainPasswordStore\(service: "Clipman\.server\.token"\)' 'Mac stores server token in Keychain'
    Assert-TextMatches (Join-Path $repoRoot 'ClipmanMac\Sources\Clipman\AppController.swift') 'migrateServerTokenToKeychainIfNeeded' 'Mac migrates old plaintext server token to Keychain'
    Assert-TextMatches (Join-Path $repoRoot 'ClipmanMac\Sources\Clipman\PreferencesWindowController.swift') 'Clipman Server' 'Mac Preferences exposes Clipman Server storage'
    Assert-TextMatches (Join-Path $repoRoot 'ClipmanMac\Sources\Clipman\AppController.swift') 'ServerCache' 'Mac server mode cache avoids reusing the shared-folder database path'
    Assert-TextMatches (Join-Path $repoRoot 'ClipmanMac\Sources\Clipman\AppController.swift') 'configureTextHistoryServerStorage' 'Mac AppController configures text-history server sync'
    Assert-TextMatches (Join-Path $repoRoot 'ClipmanMac\Sources\Clipman\ClipStore.swift') 'configureServerStorage' 'Mac ClipStore exposes server sync configuration'
    Assert-TextMatches (Join-Path $repoRoot 'ClipmanMac\Sources\Clipman\ClipStore.swift') '(?s)func configureServerStorage\(enabled: Bool, serverURL: String, serverToken: String\).*?queue\.async' 'Mac initial server sync is queued off the UI path'
    Assert-TextMatches (Join-Path $repoRoot 'ClipmanMac\Sources\Clipman\ClipStore.swift') 'syncFromServerLocked' 'Mac ClipStore downloads and merges server state'
    Assert-TextMatches (Join-Path $repoRoot 'Build.ps1') 'Remove-Item -LiteralPath \(Join-Path \$portable ''ClipmanServer\.exe''\)' 'Normal Windows client build removes stale server executable'
    Assert-TextDoesNotMatch (Join-Path $repoRoot 'Build.ps1') 'Server build failed' 'Normal Windows client build must not build the server executable'
    Assert-TextMatches (Join-Path $repoRoot 'Build.ps1') 'CLIPMAN_REMOTE_WINDOWS_TARGETS' 'Windows build supports configured remote WinRM deployment targets'
    Assert-TextMatches (Join-Path $repoRoot 'Build.ps1') 'New-PSSession -ComputerName' 'Windows build deploys remote targets through WinRM'
    Assert-TextDoesNotMatch (Join-Path $repoRoot 'Build.ps1') 'Start-Process -FilePath \$liveExe -WorkingDirectory \$targetPath' 'Remote Windows deployment must not WinRM-launch the tray app'
    Assert-TextMatches (Join-Path $repoRoot 'Build.ps1') 'WinRM cannot reliably start an interactive notification-area process' 'Remote Windows deployment explains skipped tray launch'
    Assert-TextMatches (Join-Path $repoRoot 'Build.ps1') 'Copy-Item[\s\S]{0,120}-ToSession' 'Windows build copies live files through the remote session'
    Assert-TextMatches (Join-Path $repoRoot 'Build.ps1') 'Deploy-RemoteWindowsCopies' 'Windows build invokes remote deployment after local live deployment'
    Assert-TextMatches (Join-Path $repoRoot 'Build-ServerBundle.ps1') 'ClipmanServer-\$version\.zip' 'Separate Clipman Server bundle builder names server ZIP by app version'
    Assert-TextMatches (Join-Path $repoRoot 'ClipmanServerMac\Scripts\package-combined-server.sh') 'clipman_server\.py' 'Separate Clipman Server bundle includes Python reference server'
    Assert-TextMatches (Join-Path $repoRoot 'ClipmanServerMac\Scripts\package-combined-server.sh') 'Linux/install-clipman-server\.sh' 'Separate Clipman Server bundle includes Linux installer'
    Assert-TextMatches (Join-Path $repoRoot 'ClipmanServerMac\Scripts\package-combined-server.sh') 'clipman-server-settings\.example\.jsonc' 'Separate Clipman Server bundle includes commented settings example'
    Assert-TextMatches (Join-Path $repoRoot 'Build-ServerBundle.ps1') 'Build-WindowsServerWrapper' 'Separate Clipman Server bundle builds the Windows notification-area wrapper'
    Assert-TextMatches (Join-Path $repoRoot 'Build-ServerBundle.ps1') 'AssemblyInformationalVersion' 'Windows server wrapper build stamps version metadata'
    Assert-TextMatches (Join-Path $repoRoot 'Build-ServerBundle.ps1') 'AssemblyProduct\("Clipman Server"\)' 'Windows server wrapper build stamps product metadata'
    Assert-TextMatches (Join-Path $repoRoot 'ClipmanServerMac\Scripts\package-combined-server.sh') 'Windows/Clipman Server\.exe' 'Separate Clipman Server bundle includes the Windows wrapper app'
    Assert-TextMatches (Join-Path $repoRoot 'Build-ServerBundle.ps1') '/resource:\$serverScript,ClipmanServerWrapper\.clipman_server\.py' 'Windows server wrapper embeds the shared Python server script'
    Assert-TextMatches (Join-Path $repoRoot 'ClipmanServerMac\Scripts\package-combined-server.sh') 'macOS/Clipman Server\.app' 'Separate Clipman Server bundle includes the macOS wrapper app'
    Assert-TextMatches (Join-Path $repoRoot 'Build-ServerBundle.ps1') 'package-combined-server\.sh' 'Windows server bundle build delegates final ZIP creation to macOS so app bundles remain launchable'
    Assert-TextDoesNotMatch (Join-Path $repoRoot 'Build-ServerBundle.ps1') "Join-Path \`$staging 'README\.md'" 'Separate Clipman Server bundle must not ship both README and Manual'
    Assert-TextDoesNotMatch (Join-Path $repoRoot 'ClipmanServerLinux\install-clipman-server.sh') 'README\.md' 'Linux server installer must not copy README into installed runtime'
    Assert-TextMatches (Join-Path $repoRoot 'ClipmanServerLinux\clipman_server.py') 'LOCALAPPDATA' 'Server uses native Windows data and log defaults'
    Assert-TextMatches (Join-Path $repoRoot 'ClipmanServerLinux\clipman_server.py') 'Library.+Application Support.+Clipman Server' 'Server uses native macOS data defaults'
    Assert-TextMatches (Join-Path $repoRoot 'ClipmanServerLinux\clipman_server.py') 'AdvertiseHost' 'Server can advertise a TLS DNS host separately from the bind host'
    Assert-TextMatches (Join-Path $repoRoot 'ClipmanServer\Manual.html') '%LOCALAPPDATA%\\Clipman Server' 'Server manual documents Windows data and log defaults'
    Assert-TextMatches (Join-Path $repoRoot 'ClipmanServer\Manual.html') 'Library/Application Support/Clipman Server' 'Server manual documents macOS data defaults'
    Assert-TextMatches (Join-Path $repoRoot 'ClipmanServer\Manual.html') '--advertise-host' 'Server manual documents advertised host for direct TLS'
    Assert-TextMatches (Join-Path $repoRoot 'ClipmanServer\Manual.html') 'Windows\\Clipman Server\.exe' 'Server manual documents the Windows wrapper app'
    Assert-TextMatches (Join-Path $repoRoot 'ClipmanServer\Manual.html') 'Windows EXE contains the shared server script' 'Server manual explains that Windows users do not need a loose Python script beside the EXE'
    Assert-TextMatches (Join-Path $repoRoot 'ClipmanServer\Manual.html') 'Python 3 must still be installed' 'Server manual explains Windows Python runtime requirement'
    Assert-TextMatches (Join-Path $repoRoot 'ClipmanServer\Manual.html') 'macOS/Clipman Server\.app' 'Server manual documents the macOS wrapper app'
    Assert-TextMatches (Join-Path $repoRoot 'ClipmanServer\Manual.html') 'Run at System Start' 'Server manual documents startup behavior'
    Assert-TextMatches (Join-Path $repoRoot 'ClipmanServer\Manual.html') '<h2 id="updates">Updates</h2>' 'Server manual documents server update behavior'
    Assert-TextMatches (Join-Path $repoRoot 'ClipmanServer\Manual.html') '--install-update --silent' 'Server manual documents silent server update switch'
    Assert-TextMatches (Join-Path $repoRoot 'README.md') 'Clipman Server has its own update path' 'README documents separate server update path'
    Assert-TextMatches (Join-Path $repoRoot 'ClipmanServerWindows\Program.cs') 'CreateNoWindow = true' 'Windows server wrapper starts Python without a console window'
    Assert-TextMatches (Join-Path $repoRoot 'ClipmanServerWindows\Program.cs') 'NotifyIcon' 'Windows server wrapper runs from the notification area'
    Assert-TextMatches (Join-Path $repoRoot 'ClipmanServerWindows\Program.cs') 'Check for updates' 'Windows server wrapper exposes update checks from the tray menu'
    Assert-TextMatches (Join-Path $repoRoot 'ClipmanServerWindows\Program.cs') '--install-update' 'Windows server wrapper exposes CLI update install switch'
    Assert-TextMatches (Join-Path $repoRoot 'ClipmanServerWindows\Program.cs') 'ClipmanServer-' 'Windows server wrapper searches for the separate server release ZIP'
    Assert-TextDoesNotMatch (Join-Path $repoRoot 'ClipmanServerWindows\Program.cs') '--write-connection-info' 'Windows server wrapper must not start Python with an exit-after-writing command'
    Assert-TextMatches (Join-Path $repoRoot 'ClipmanServerMac\Sources\ClipmanServer\main.swift') 'setActivationPolicy\(\.accessory\)' 'Mac server wrapper does not appear as a normal foreground app'
    Assert-TextMatches (Join-Path $repoRoot 'ClipmanServerMac\Sources\ClipmanServer\main.swift') 'Check for Updates' 'Mac server wrapper exposes update checks from the menu bar'
    Assert-TextMatches (Join-Path $repoRoot 'ClipmanServerMac\Sources\ClipmanServer\main.swift') '--install-update' 'Mac server wrapper exposes CLI update install switch'
    Assert-TextMatches (Join-Path $repoRoot 'ClipmanServerMac\Sources\ClipmanServer\main.swift') 'ClipmanServer-' 'Mac server wrapper searches for the separate server release ZIP'
    Assert-TextDoesNotMatch (Join-Path $repoRoot 'ClipmanServerMac\Sources\ClipmanServer\main.swift') '--write-connection-info' 'Mac server wrapper must not start Python with an exit-after-writing command'
    Assert-TextMatches (Join-Path $repoRoot 'ClipmanServerMac\Scripts\package-release.sh') '<key>LSUIElement</key>' 'Mac server wrapper is packaged as a menu-bar app'
    Assert-TextDoesNotMatch (Join-Path $repoRoot 'Build-ServerBundle.ps1') 'Windows\\Run-ClipmanServer\.cmd' 'Separate Clipman Server bundle must not ship a second normal Windows entry point'
    Assert-TextMatches (Join-Path $repoRoot 'ClipmanServerMac\Scripts\package-combined-server.sh') 'Linux/run-clipman-server\.sh' 'Separate Clipman Server bundle includes Linux launcher'
    Assert-TextDoesNotMatch (Join-Path $repoRoot 'ClipmanServerMac\Scripts\package-combined-server.sh') 'macOS/run-clipman-server\.command' 'Separate Clipman Server bundle must not rely on a macOS terminal launcher'
    Assert-TextMatches (Join-Path $repoRoot 'SmokeTest.ps1') 'Manual\.html\.new' 'Live server deployment includes the HTML manual'
    Assert-TextMatches (Join-Path $repoRoot 'SmokeTest.ps1') 'rm -f README\.md' 'Live server deployment removes stale server README from shipping folder'
    Assert-TextMatches (Join-Path $repoRoot 'ClipmanServer\Manual.html') '<title>Clipman Server Manual</title>' 'Separate server manual exists as HTML'
    Assert-TextMatches (Join-Path $repoRoot 'ClipmanServer\Manual.html') 'same server program is used across platforms' 'Separate server manual documents cross-platform server parity'
    Assert-TextDoesNotMatch (Join-Path $repoRoot 'ClipmanServer\Manual.html') 'reference implementation|experimental native server|repository may contain' 'Separate server manual must not expose development wording'
    Assert-TextMatches (Join-Path $repoRoot 'ClipmanServer\Manual.html') 'clipman-server-connection\.txt' 'Separate server manual documents connection details file'
    Assert-TextMatches (Join-Path $repoRoot 'ClipmanServer\Manual.html') 'sh Linux/install-clipman-server\.sh' 'Separate server manual documents Linux installer'
    Assert-TextMatches (Join-Path $repoRoot 'ClipmanServer\Manual.html') 'Do not manually copy an existing <code>\.clipdb</code>' 'Separate server manual documents safe existing-history bootstrap'
    Assert-NotExists (Join-Path $repoRoot 'ClipmanServer\README.md') 'Duplicate Windows server README in source tree'
    Assert-NotExists (Join-Path $repoRoot 'ClipmanServerLinux\README.md') 'Duplicate Linux server README in source tree'
    Assert-TextMatches (Join-Path $repoRoot 'ClipmanServerLinux\install-clipman-server.sh') '\.local/lib/clipman-server' 'Linux server installer uses user-local application directory'
    Assert-TextMatches (Join-Path $repoRoot 'ClipmanServerLinux\install-clipman-server.sh') '\.local/bin' 'Linux server installer creates user-local launcher'
    Assert-TextMatches (Join-Path $repoRoot 'ClipmanServerLinux\clipman_server.py') 'database_id_from_path' 'Linux Clipman Server validates database-scoped paths'
    Assert-TextMatches (Join-Path $repoRoot 'ClipmanServerLinux\clipman_server.py') 'write_connection_info' 'Linux Clipman Server writes plain text connection details on first run'
    Assert-TextMatches (Join-Path $repoRoot 'ClipmanServerLinux\clipman_server.py') 'clipman-server-connection\.txt' 'Linux Clipman Server names connection details file'
    Assert-TextMatches (Join-Path $repoRoot 'ClipmanServerLinux\clipman_server.py') 'Databases' 'Linux Clipman Server stores password-scoped database buckets'
    Assert-TextMatches (Join-Path $repoRoot 'ClipmanServerLinux\clipman_server.py') 'st_mtime_ns' 'Linux Clipman Server revision uses cheap file metadata for polling'
    Assert-TextMatches (Join-Path $repoRoot 'ClipmanServerLinux\clipman_server.py') 'HEAD /api/v1/database/' 'Linux Clipman Server suppresses routine poll logging'
    Assert-TextMatches (Join-Path $repoRoot 'ClipmanServerLinux\clipman_server.py') 'os\.chmod\(path, 0o700\)' 'Linux Clipman Server creates private data directories where supported'
    Assert-TextMatches (Join-Path $repoRoot 'ClipmanServerLinux\clipman_server.py') 'os\.chmod\(path, 0o600\)' 'Linux Clipman Server creates private settings/database files where supported'
    Assert-TextMatches (Join-Path $repoRoot 'ClipmanServerLinux\clipman_server.py') 'ssl\.SSLContext\(ssl\.PROTOCOL_TLS_SERVER\)' 'Linux Clipman Server supports direct TLS'
    Assert-TextMatches (Join-Path $repoRoot 'ClipmanServerLinux\clipman_server.py') 'AllowInsecureRemote' 'Linux Clipman Server requires an explicit insecure remote override'
    Assert-TextMatches (Join-Path $repoRoot 'ClipmanServerLinux\clipman_server.py') 'RotatingFileHandler' 'Linux Clipman Server writes managed log files'
    Assert-TextMatches (Join-Path $repoRoot 'ClipmanServerLinux\clipman_server.py') 'DATABASE_LOG_PATTERN' 'Linux Clipman Server redacts database IDs from logs'
    Assert-TextMatches (Join-Path $repoRoot 'ClipmanServerLinux\clipman_server.py') 'except KeyboardInterrupt' 'Linux Clipman Server exits cleanly on Ctrl+C'
    Assert-TextMatches (Join-Path $repoRoot 'ClipmanServerLinux\clipman_server.py') 'server\.server_close\(\)' 'Linux Clipman Server closes socket on shutdown'
    Assert-TextMatches (Join-Path $repoRoot 'ClipmanServerLinux\clipman_server.py') 'METADATA_TOUCH_INTERVAL_MS' 'Linux Clipman Server throttles database metadata writes'
    Assert-TextMatches (Join-Path $repoRoot 'ClipmanServerLinux\clipman_server.py') '--list-databases' 'Linux Clipman Server can list database buckets'
    Assert-TextMatches (Join-Path $repoRoot 'ClipmanServerLinux\clipman_server.py') '--list-databases-json' 'Linux Clipman Server can list database buckets as JSON'
    Assert-TextMatches (Join-Path $repoRoot 'ClipmanServerLinux\clipman_server.py') '--delete-database' 'Linux Clipman Server can move a selected database bucket aside'
    Assert-TextMatches (Join-Path $repoRoot 'ClipmanServerLinux\clipman_server.py') '--prune-databases-days' 'Linux Clipman Server has dry-run stale database pruning'
    Assert-TextMatches (Join-Path $repoRoot 'ClipmanServerLinux\clipman_server.py') '--force-recent' 'Linux Clipman Server requires deliberate override for recently active bucket deletion'
    Assert-TextMatches (Join-Path $repoRoot 'ClipmanServerLinux\clipman_server.py') 'DeletedDatabases' 'Linux Clipman Server moves removed buckets to DeletedDatabases'
    Assert-TextMatches (Join-Path $repoRoot 'ClipmanServerLinux\install-clipman-server.sh') 'clipmanserver' 'Linux server installer creates friendly helper command'
    Assert-TextMatches (Join-Path $repoRoot 'ClipmanServerLinux\install-clipman-server.sh') 'clipmanserver start' 'Linux server installer documents helper start command'
    Assert-TextMatches (Join-Path $repoRoot 'ClipmanServerLinux\install-clipman-server.sh') 'list-json' 'Linux server helper exposes JSON database list command'
    Assert-TextMatches (Join-Path $repoRoot 'ClipmanServerLinux\install-clipman-server.sh') 'force-delete' 'Linux server helper exposes deliberate force-delete command'
    Assert-TextMatches (Join-Path $repoRoot 'ClipmanServer\Manual.html') 'Linux Helper Commands' 'Server manual documents Linux helper commands'
    Assert-TextMatches (Join-Path $repoRoot 'ClipmanServer\Manual.html') 'clipmanserver list' 'Server manual documents database list helper command'
    Assert-TextMatches (Join-Path $repoRoot 'ClipmanServer\Manual.html') 'clipmanserver delete' 'Server manual documents database delete helper command'
    Assert-TextMatches (Join-Path $repoRoot 'ClipmanServer\Manual.html') '--list-databases-json' 'Server manual documents JSON database listing'
    Assert-TextMatches (Join-Path $repoRoot 'ClipmanServer\Manual.html') '--prune-databases-days' 'Server manual documents stale database pruning'
    Assert-TextMatches (Join-Path $repoRoot 'ClipmanServer\Manual.html') '24 hours' 'Server manual documents recent database deletion safety guard'
    Assert-TextMatches (Join-Path $repoRoot 'ClipmanServer\Manual.html') 'DeletedDatabases' 'Server manual documents safe deleted bucket holding area'
    Assert-TextMatches (Join-Path $repoRoot 'README.md') 'clipmanserver list' 'README documents Linux database list helper'
    Assert-TextMatches (Join-Path $repoRoot 'README.md') 'force-delete' 'README documents Linux helper force-delete safeguard'
    Assert-TextMatches (Join-Path $repoRoot 'README.md') 'DeletedDatabases' 'README documents safe server bucket cleanup'
    Assert-NotExists (Join-Path $repoRoot 'ClipmanServerLinux\__pycache__') 'Python bytecode cache in server source tree'
    Invoke-LinuxServerSmoke
    Assert-TextMatches (Join-Path $repoRoot 'src\ClipmanApplicationContext.cs') 'ResolvedEntryText\(entry\)' 'Windows copy and Quick Paste resolve template entries at output time'
    Assert-TextMatches (Join-Path $repoRoot 'src\HistoryForm.cs') 'store\.SetTemplate\(entry\.Id, dialog\.EntryIsTemplate\)' 'Windows Entry Properties saves template flag'
    Assert-TextMatches (Join-Path $repoRoot 'ClipmanMac\Sources\ClipmanCore\Models.swift') 'public var IsTemplate: Bool' 'Mac shared entries store template flag'
    Assert-TextMatches (Join-Path $repoRoot 'ClipmanMac\Sources\Clipman\TemplateResolver.swift') 'enum TemplateResolver' 'Mac template resolver exists'
    Assert-TextMatches (Join-Path $repoRoot 'ClipmanMac\Sources\Clipman\TemplateResolver.swift') 'variableReferenceText' 'Mac template variable reference exists'
    Assert-TextMatches (Join-Path $repoRoot 'ClipmanMac\Sources\Clipman\HistoryWindowController.swift') 'Preview template' 'Mac Entry Properties exposes template preview'
    Assert-TextMatches (Join-Path $repoRoot 'ClipmanMac\Sources\Clipman\HistoryWindowController.swift') 'Insert sample' 'Mac Entry Properties exposes template sample insertion'
    Assert-TextMatches (Join-Path $repoRoot 'ClipmanMac\Sources\Clipman\HistoryWindowController.swift') 'Insert field' 'Mac Entry Properties exposes template field insertion'
    Assert-TextMatches (Join-Path $repoRoot 'ClipmanMac\Sources\Clipman\HistoryWindowController.swift') 'Template variables' 'Mac Entry Properties exposes template variable reference'
    Assert-TextMatches (Join-Path $repoRoot 'ClipmanMac\Sources\Clipman\TemplateResolver.swift') 'Date, year/month/day' 'Mac template presets include year/month/day'
    Assert-TextMatches (Join-Path $repoRoot 'ClipmanMac\Sources\Clipman\TemplateResolver.swift') 'Date, day short-month year' 'Mac template presets include non-US date'
    Assert-TextMatches (Join-Path $repoRoot 'ClipmanMac\Sources\Clipman\SensitiveDataExclusion.swift') 'international-phone' 'Mac sensitive data presets include international phone'
    Assert-TextMatches (Join-Path $repoRoot 'ClipmanMac\Sources\Clipman\SensitiveDataExclusion.swift') 'if isFullHTTPURL\(text\) \{ return nil \}' 'Mac sensitive data exclusions bypass complete HTTP URLs'
    Assert-TextMatches (Join-Path $repoRoot 'ClipmanMac\Sources\Clipman\SensitiveDataExclusion.swift') 'software-license-key' 'Mac sensitive data presets include software license key'
    Assert-TextMatches (Join-Path $repoRoot 'ClipmanMac\Sources\Clipman\SensitiveDataExclusion.swift') 'passesLuhn' 'Mac sensitive data credit-card preset validates Luhn'
    Assert-TextMatches (Join-Path $repoRoot 'ClipmanMac\Sources\Clipman\PreferencesWindowController.swift') 'Sensitive data mode' 'Mac Preferences exposes sensitive data mode'
    Assert-TextMatches (Join-Path $repoRoot 'ClipmanMac\Sources\Clipman\AppController.swift') 'SensitiveDataExclusion\.matchName' 'Mac capture path checks sensitive data exclusions'
    Assert-TextMatches (Join-Path $repoRoot 'ClipmanMac\Sources\Clipman\AppController.swift') 'if settings\.captureClipboardOnStartup \{\s*monitor\.captureCurrentContents\(\)\s*\}' 'Mac launch captures existing clipboard only when opted in'
    Assert-TextDoesNotMatch (Join-Path $repoRoot 'ClipmanMac\Sources\Clipman\AppController.swift') 'monitor\.start\(\)\s*monitor\.captureCurrentContents\(\)' 'Mac launch must not unconditionally capture existing clipboard'
    Assert-TextMatches (Join-Path $repoRoot 'ClipmanMac\Sources\Clipman\PreferencesWindowController.swift') 'Add current clipboard item to Clipman on start' 'Mac Preferences exposes startup clipboard capture'
    Assert-TextMatches (Join-Path $repoRoot 'src\PreferencesForm.cs') 'Add current &clipboard item to Clipman on start' 'Windows Preferences exposes startup clipboard capture'
    Assert-TextMatches (Join-Path $repoRoot 'src\ClipmanApplicationContext.cs') 'if \(settings\.CaptureClipboardOnStartup\)\s*\{\s*HandleClipboardUpdate\(\);\s*\}' 'Windows launch captures existing clipboard only when opted in'
    Assert-TextMatches (Join-Path $repoRoot 'src\ClipmanApplicationContext.cs') '(?s)public void CopyEntryToClipboard\(ClipEntry entry\).*?sounds\.Copy\(settings\.SoundsEnabled\);' 'Windows history entry copy plays confirmation sound'
    Assert-TextMatches (Join-Path $repoRoot 'src\ClipmanApplicationContext.cs') '(?s)public void CopyEntriesToClipboard\(List<ClipEntry> entries\).*?sounds\.Copy\(settings\.SoundsEnabled\);' 'Windows multi-entry copy plays confirmation sound'
    Assert-TextMatches (Join-Path $repoRoot 'ClipmanMac\Sources\Clipman\AppController.swift') 'TemplateResolver\.resolveEntryText' 'Mac copy and Quick Paste resolve template entries at output time'
    Assert-TextMatches (Join-Path $repoRoot 'ClipmanMac\Sources\Clipman\HistoryWindowController.swift') 'Template entry' 'Mac Entry Properties exposes template entry checkbox'
    Assert-TextMatches (Join-Path $repoRoot 'ClipmanMac\Sources\Clipman\AppController.swift') 'private func quickPasteEntry\(id: String\)' 'Mac Quick Paste hotkey uses paste workflow'
    Assert-TextMatches (Join-Path $repoRoot 'ClipmanMac\Sources\Clipman\ClipmanSettings.swift') 'var quickPasteModes: \[String: String\]' 'Mac settings store per-target Quick Paste modes'
    Assert-TextMatches (Join-Path $repoRoot 'ClipmanMac\Sources\Clipman\ClipmanSettings.swift') 'enum QuickPasteMode' 'Mac defines shared Quick Paste mode strings'
    Assert-TextMatches (Join-Path $repoRoot 'ClipmanMac\Sources\Clipman\AppController.swift') 'case \.pasteKeep:' 'Mac Quick Paste supports paste-and-keep mode'
    Assert-TextMatches (Join-Path $repoRoot 'ClipmanMac\Sources\Clipman\AppController.swift') 'case \.copyOnly:' 'Mac Quick Paste supports copy-only mode'
    Assert-TextMatches (Join-Path $repoRoot 'ClipmanMac\Sources\Clipman\HistoryWindowController.swift') 'Paste and restore previous clipboard' 'Mac Entry Properties exposes paste-and-restore mode'
    Assert-TextMatches (Join-Path $repoRoot 'ClipmanMac\Sources\Clipman\HistoryWindowController.swift') 'Paste and keep target on clipboard' 'Mac Entry Properties exposes paste-and-keep mode'
    Assert-TextMatches (Join-Path $repoRoot 'ClipmanMac\Sources\Clipman\HistoryWindowController.swift') 'Copy to clipboard only' 'Mac Entry Properties exposes copy-only mode'
    Assert-TextMatches (Join-Path $repoRoot 'ClipmanMac\Sources\Clipman\HistoryWindowController.swift') 'private class BoundaryAwareTextView: NSTextView' 'Mac text dialogs use custom URL/code boundary navigation'
    Assert-TextMatches (Join-Path $repoRoot 'ClipmanMac\Sources\Clipman\HistoryWindowController.swift') 'private final class DialogTabTextView: BoundaryAwareTextView' 'Mac Entry Properties clipboard text uses boundary-aware text view'
    Assert-TextMatches (Join-Path $repoRoot 'ClipmanMac\Sources\Clipman\HistoryWindowController.swift') 'let textView = BoundaryAwareTextView' 'Mac read-only text viewer uses boundary-aware text view'
    Assert-TextMatches (Join-Path $repoRoot 'ClipmanMac\Sources\Clipman\AppController.swift') 'sendPasteKeystroke\(\)' 'Mac Quick Paste sends paste keystroke'
    Assert-TextMatches (Join-Path $repoRoot 'ClipmanMac\Sources\Clipman\ClipboardMonitor.swift') 'writeTemporaryInternalText' 'Mac Quick Paste restores previous pasteboard where possible'
    Assert-TextMatches (Join-Path $repoRoot 'ClipmanMac\Sources\Clipman\HistoryWindowController.swift') 'addQuickPasteTargetItems\(to: menu\)' 'Mac Clipman menu exposes Quick Paste targets'
    Assert-TextMatches (Join-Path $repoRoot 'ClipmanMac\Sources\Clipman\HistoryWindowController.swift') 'menuQuickPasteTargetSelected' 'Mac Quick Paste target menu jumps to the assigned entry'
    Assert-TextMatches (Join-Path $repoRoot 'ClipmanMac\Sources\Clipman\HistoryWindowController.swift') 'quickPasteLabel\(for: entry\)' 'Mac text rows expose Quick Paste hotkeys'
    Assert-TextMatches (Join-Path $repoRoot 'ClipmanMac\Sources\Clipman\ClipmanSettings.swift') 'soundsEnabled' 'Mac settings include Play sounds parity'
    Assert-TextMatches (Join-Path $repoRoot 'ClipmanMac\Sources\Clipman\PreferencesWindowController.swift') 'Play sounds' 'Mac Preferences exposes Play sounds'
    Assert-TextMatches (Join-Path $repoRoot 'ClipmanMac\Sources\Clipman\SoundService.swift') 'func useDataFolder' 'Mac sound service can use selected data/settings folder'
    Assert-TextMatches (Join-Path $repoRoot 'ClipmanMac\Sources\Clipman\AppController.swift') 'sounds\.useDataFolder\(settingsStore\.dataFolder\(for: settings\)\)' 'Mac custom sound overrides follow the active data/settings folder'
    Assert-TextMatches (Join-Path $repoRoot 'ClipmanMac\Sources\Clipman\PreferencesWindowController.swift') '#selector\(NSText\.paste' 'Mac Preferences supports Command+V in text fields'
    Assert-TextMatches (Join-Path $repoRoot 'ClipmanMac\Sources\Clipman\PreferencesWindowController.swift') 'Database encryption is on\. The password is saved in Keychain' 'Mac Preferences explains remembered encrypted password status'
    Assert-TextMatches (Join-Path $repoRoot 'ClipmanMac\Sources\Clipman\PreferencesWindowController.swift') 'Database encryption is off' 'Mac Preferences explains unencrypted status'
    Assert-TextMatches (Join-Path $repoRoot 'ClipmanMac\Sources\Clipman\ClipboardMonitor.swift') 'ignoredApplicationMatches' 'Mac ignored app helper-prefix matching'
    Assert-TextMatches (Join-Path $repoRoot 'ClipmanMac\Sources\Clipman\ClipboardMonitor.swift') 'candidate\.hasPrefix' 'Mac ignored app bundle prefix matching'
    Assert-TextMatches (Join-Path $repoRoot 'ClipmanMac\Sources\Clipman\ClipboardMonitor.swift') 'org\.nspasteboard\.concealedtype' 'Mac skips concealed pasteboard types'
    Assert-TextMatches (Join-Path $repoRoot 'ClipmanMac\Sources\Clipman\ClipboardMonitor.swift') 'com\.agilebits\.onepassword' 'Mac maps 1Password pasteboard type marker'
    Assert-TextMatches (Join-Path $repoRoot 'ClipmanMac\Sources\Clipman\ClipboardMonitor.swift') 'shouldSkipPasteboardTypes' 'Mac ignored app matching can use pasteboard type metadata'
    Assert-TextMatches (Join-Path $repoRoot 'ClipmanMac\Sources\Clipman\HotkeyCaptureField.swift') 'clearHotkeyIfNeeded' 'Mac hotkey fields clear with Delete or Backspace'
    Assert-TextMatches (Join-Path $repoRoot 'ClipmanMac\Sources\Clipman\HotkeyCaptureField.swift') 'Delete or Backspace to clear this hotkey' 'Mac hotkey field exposes clear hint'
    Assert-TextMatches (Join-Path $repoRoot 'ClipmanMac\Sources\Clipman\HistoryWindowController.swift') 'requestedQuickCopy && capturedHotkey == nil' 'Mac cleared Quick Paste hotkey removes the assignment instead of trapping validation'
    Assert-TextDoesNotMatch $manual 'Fixed Windows Quick Paste assignments made from Entry Properties' 'Manual does not describe new Quick Paste behavior as a prior Windows fix'
    Assert-TextDoesNotMatch $readme 'Fixed Windows Quick Paste assignments made from Entry Properties' 'README does not describe new Quick Paste behavior as a prior Windows fix'
    Assert-TextMatches $manual 'paste and leave the target on the clipboard' 'Manual 1.6.1 Quick Paste mode changelog'
    Assert-TextMatches $readme 'paste and leave the target on the clipboard' 'README 1.6.1 Quick Paste mode changelog'
    Assert-TextMatches $manual 'Quick Paste still works while clipboard monitoring is off' 'Manual documents Quick Paste monitoring-off behavior'
    Assert-TextMatches $readme 'Quick Paste still works while clipboard monitoring is off' 'README documents Quick Paste monitoring-off behavior'
    Assert-TextMatches $manual 'Copy to clipboard only' 'Manual documents Quick Paste copy-only mode'
    Assert-TextMatches $readme 'copy to clipboard only' 'README documents Quick Paste copy-only mode'
    Assert-TextMatches $manual 'Use the <strong>Quick Paste</strong> menu on Windows' 'Manual documents Quick Paste target menu'
    Assert-TextMatches $readme 'Use the Quick Paste menu on Windows' 'README documents Quick Paste target menu'
    Assert-TextMatches $manual 'Added Quick Paste target discovery' 'Manual changelog documents Quick Paste target discovery'
    Assert-TextMatches $readme 'Added Quick Paste target discovery' 'README changelog documents Quick Paste target discovery'
    Assert-TextMatches $manual 'Improved hotkey editing: hotkey fields can now be cleared with Delete or Backspace' 'Manual 1.6.2 hotkey clear changelog'
    Assert-TextMatches $readme 'Improved hotkey editing: hotkey fields can now be cleared with Delete or Backspace' 'README 1.6.2 hotkey clear changelog'
    Assert-TextMatches $manual 'screen readers no longer announce the fields as read-only' 'Manual 1.6.2 hotkey accessibility changelog'
    Assert-TextMatches $readme 'screen readers no longer announce the fields as read-only' 'README 1.6.2 hotkey accessibility changelog'
    Assert-TextMatches $manual 'the <strong>Groups</strong> menu lists the same filters as the Group field' 'Manual documents Windows Groups menu'
    Assert-TextMatches $manual 'deliberately does not use <code>Alt\+G</code>' 'Manual documents why Groups menu does not steal Alt+G'
    Assert-TextMatches $manual 'Added a Windows Groups menu' 'Manual changelog documents Windows Groups menu'
    Assert-TextMatches $readme 'Added a Windows Groups menu' 'README changelog documents Windows Groups menu'
    Assert-TextDoesNotMatch (Join-Path $repoRoot 'src\EntryPropertiesForm.cs') 'Read-only clipboard text' 'Entry Properties clipboard text description is not stale'
    Assert-TextDoesNotMatch (Join-Path $repoRoot 'src\HistoryForm.cs') 'Alt\\+Enter|Keys\.Enter\)[\s\S]{0,80}ShowEntryProperties|NameSelectedEntry|EntryNameForm' 'No stale Alt+Enter or edit-only entry properties path'
    Assert-TextDoesNotMatch (Join-Path $repoRoot 'LICENSE.txt') 'Sensor Readout|SensorReadout|AccessibleSensorReadout' 'License does not contain Sensor Readout leftovers'
    Assert-TextMatches (Join-Path $repoRoot 'src\HistoryForm.cs') 'NumberedPinnedDisplayText\(DisplayText\(entry\), pinnedEntryPosition\+\+\)' 'Pinned text rows display shortcut number'
    Assert-TextMatches (Join-Path $repoRoot 'src\HistoryForm.cs') 'NumberedPinnedDisplayText\(FileEventDisplayText\(item\), pinnedEventPosition\+\+\)' 'Pinned file rows display shortcut number'
    Assert-TextMatches (Join-Path $repoRoot 'src\HistoryForm.cs') 'var pinnedEntries = TextEntriesForActiveTab\(store\.GetEntries\(settings\.SortMode, "Pinned", settings\.SortDescending\)\);' 'Pinned text shortcuts are scoped to the active Text or Links tab'
    Assert-TextMatches (Join-Path $repoRoot 'ClipmanMac\Sources\Clipman\HistoryWindowController.swift') 'case \.text, \.links: return filteredEntries\.filter\(\\\.Pinned\)\.map\(Row\.entry\)' 'Mac pinned text shortcuts are scoped to the active Text or Links mode'
    Assert-TextDoesNotMatch (Join-Path $repoRoot 'src\HistoryForm.cs') 'SubItems\.Add\(entry\.Pinned \? "Pinned" : string\.Empty\)' 'Pinned text state is not repeated in a noisy per-row column'
    Assert-TextMatches (Join-Path $repoRoot 'src\HistoryForm.cs') 'SubItems\.Add\(item\.Pinned \? "Pinned" : string\.Empty\)' 'Pinned file state remains in pinned column'
    Assert-TextMatches (Join-Path $repoRoot 'src\HistoryForm.cs') 'Pinned entries are protected\. Unpin before deleting\.' 'Pinned text delete guard'
    Assert-TextMatches (Join-Path $repoRoot 'src\HistoryForm.cs') 'Pinned file-history events are protected\. Unpin before deleting\.' 'Pinned file delete guard'
    Assert-TextMatches (Join-Path $repoRoot 'src\ClipStore.cs') 'OrderByDescending\(e => e\.CreatedUnixMs\)' 'Remote auto-copy chooses newest remote entry by created time'
    Assert-TextMatches (Join-Path $repoRoot 'src\ClipmanApplicationContext.cs') 'lastAutoCopiedRemoteEntryStamp = entry\.CreatedUnixMs' 'Remote auto-copy baseline uses created time'
    Assert-TextMatches (Join-Path $repoRoot 'src\ClipmanApplicationContext.cs') 'var stamp = entry\.CreatedUnixMs' 'Remote auto-copy trigger uses created time'
    Assert-TextDoesNotMatch (Join-Path $repoRoot 'src\ClipStore.cs') 'Math\.Max\(e\.LastUsedUnixMs, e\.CreatedUnixMs\)' 'Remote auto-copy does not use last-used time'
    Assert-TextMatches (Join-Path $repoRoot 'src\ClipStore.cs') 'PushEntriesToOtherMachines' 'Windows store exposes explicit remote push'
    Assert-TextMatches (Join-Path $repoRoot 'src\ClipStore.cs') 'if \(!keepDuplicateEntries\)' 'Windows remote push respects duplicate-removal mode'
    Assert-TextMatches (Join-Path $repoRoot 'src\HistoryForm.cs') 'settings\.DuplicateMode, "KeepBoth"' 'Windows remote push keeps clones only when duplicate mode is KeepBoth'
    Assert-TextMatches (Join-Path $repoRoot 'src\HistoryForm.cs') 'Push to other &machines\\tCtrl\+P' 'Windows menu exposes remote push shortcut'
    Assert-TextMatches (Join-Path $repoRoot 'src\HistoryForm.cs') 'e\.Control && e\.KeyCode == Keys\.P' 'Windows Ctrl+P pushes selected text entry'
    Assert-TextMatches (Join-Path $repoRoot 'ClipmanMac\Sources\Clipman\ClipStore.swift') 'pushEntriesToOtherMachines' 'Mac store exposes explicit remote push'
    Assert-TextMatches (Join-Path $repoRoot 'ClipmanMac\Sources\Clipman\ClipStore.swift') 'CreatedUnixMs = now' 'Mac remote push re-stamps selected entry for de-duped history'
    Assert-TextMatches (Join-Path $repoRoot 'ClipmanMac\Sources\Clipman\HistoryWindowController.swift') 'Push To Other Machines' 'Mac Clipman menu exposes remote push'
    Assert-TextMatches (Join-Path $repoRoot 'ClipmanMac\Sources\Clipman\HistoryWindowController.swift') 'kVK_ANSI_P\), modifiers == \[\.command\]' 'Mac Command+P pushes selected text entry'
    Assert-TextMatches $manual 'Push selected text entry to other synced machines' 'Manual documents remote push shortcut'
    Assert-TextMatches $readme 'Push an existing selected text entry to other synced machines' 'README documents remote push feature'
    Assert-TextMatches (Join-Path $repoRoot 'src\HistoryForm.cs') 'data\.SetText\(string\.Join\(Environment\.NewLine, existing\), TextDataFormat\.UnicodeText\)' 'File history restore includes text paths'
    Assert-TextMatches (Join-Path $repoRoot 'src\HistoryForm.cs') 'SaveListPositionIndex\(preferredIndex\)' 'Delete/cut updates saved position before store refresh'
    Assert-TextMatches (Join-Path $repoRoot 'src\HistoryForm.cs') 'if \(index >= list\.Items\.Count\)\s*\{\s*index = list\.Items\.Count - 1;\s*\}' 'Reload clamps preferred index after deleting the last row'
    Assert-TextDoesNotMatch (Join-Path $repoRoot 'src\HistoryForm.cs') 'if \(index < 0 \|\| index >= list\.Items\.Count\)\s*\{\s*index = DefaultHistoryIndex\(\);\s*\}' 'Reload must not send an out-of-range preferred index to the default top row'
    Assert-TextDoesNotMatch (Join-Path $repoRoot 'src\HistoryForm.cs') 'BeginDelayedReset' 'No delayed reset after showing history'
    Assert-TextDoesNotMatch (Join-Path $repoRoot 'src\HistoryForm.cs') 'BeginDelayedFocus\(100\)|BeginDelayedFocus\(300\)|BeginDelayedFocus\(firstShow \? 900 : 500\)' 'No stacked delayed focus calls after showing history'
    Assert-TextMatches (Join-Path $repoRoot 'src\HistoryForm.cs') 'pendingHistoryFocus' 'FocusHistoryList coalesces duplicate show-time focus requests'
    Assert-TextDoesNotMatch (Join-Path $repoRoot 'src\HistoryForm.cs') 'Go to file\\tShift\+Enter' 'No current file-history Shift+Enter go-to-file shortcut'
    Assert-TextMatches (Join-Path $repoRoot 'src\HistoryForm.cs') 'SelectedFileClipboardEvents' 'File history multi-selection helper'
    Assert-TextMatches (Join-Path $repoRoot 'src\HistoryForm.cs') 'ExistingFileClipboardPaths\(selected\)' 'File history restore uses all selected events'
    Assert-TextDoesNotMatch (Join-Path $repoRoot 'src\HistoryForm.cs') 'fileRange|RangeMarker|RestoreMarked|CopyMarked|marked range|Set range &start|Set range &end' 'No stale file-history marker implementation'
    Assert-TextDoesNotMatch (Join-Path $repoRoot 'src\PreferencesForm.cs') 'encryptDatabase|Clipboard\.SetText\(password\)' 'Preferences encryption checkbox and raw password clipboard copy'
    Assert-TextMatches (Join-Path $repoRoot 'src\Program.cs') 'Logs\\\\Startup\.log' 'Startup failure log message'
    Assert-TextMatches (Join-Path $repoRoot 'src\Program.cs') 'WriteStartupLog\("Startup failed\."' 'Startup failure logging'
    Assert-TextMatches (Join-Path $repoRoot 'src\Program.cs') 'Application\.ThreadException' 'Windows runtime UI exception logging'
    Assert-TextMatches (Join-Path $repoRoot 'src\Program.cs') 'Runtime\.log' 'Windows runtime log file'
    Assert-TextMatches (Join-Path $repoRoot 'src\Program.cs') 'CleanupStartupArtifacts\(\)' 'Windows startup cleanup for stale app-root backup folders'
    Assert-TextMatches (Join-Path $repoRoot 'src\Program.cs') 'CleanupObsoleteRootUpdateFolders\(appDirectory\)' 'Windows startup cleanup removes obsolete update backup folders'
    Assert-TextMatches (Join-Path $repoRoot 'src\Program.Updater.cs') 'Backups\\\\Updates' 'Windows update cleanup removes obsolete app-root update backups'
    Assert-TextMatches (Join-Path $repoRoot 'src\Program.cs') 'CleanupEmptyBackupFolders\(appDirectory\)' 'Windows startup cleanup deletes stale app-root backup folders'
    Assert-TextMatches (Join-Path $repoRoot 'src\Program.Updater.cs') 'CopyFactoryDirectoryBestEffort' 'Windows updater uses tolerant factory folder copy'
    Assert-TextMatches (Join-Path $repoRoot 'src\Program.Updater.cs') 'could not update factory file' 'Windows updater logs factory asset copy warnings'
    Assert-TextMatches (Join-Path $repoRoot 'src\ClipmanApplicationContext.cs') 'Runtime crash log: ' 'Windows diagnostics runtime log path'
    Assert-TextMatches (Join-Path $repoRoot 'ClipmanMac\Sources\Clipman\RuntimeLogger.swift') 'Runtime\.log' 'Mac runtime log file'
    Assert-TextMatches (Join-Path $repoRoot 'ClipmanMac\Sources\Clipman\main.swift') 'RuntimeLogger\.install\(\)' 'Mac runtime logger install'
    Assert-TextMatches (Join-Path $repoRoot 'ClipmanMac\Sources\Clipman\AppController.swift') 'Runtime crash log: ' 'Mac diagnostics runtime log path'
    Assert-TextMatches (Join-Path $repoRoot 'src\Models.cs') 'UseDefaultDatabasePath' 'Default database path setting'
    Assert-TextMatches (Join-Path $repoRoot 'src\SettingsStore.cs') 'ShouldTreatAsDefaultDatabasePath' 'Portable default database path detection'
    Assert-TextMatches (Join-Path $repoRoot 'src\PreferencesForm.cs') 'FolderBrowserDialog' 'Preferences uses folder picker for data folder'
    Assert-TextMatches (Join-Path $repoRoot 'src\PreferencesForm.cs') 'DatabasePathFromFolderOrFile' 'Preferences derives database path from data folder'
    Assert-TextDoesNotMatch (Join-Path $repoRoot 'src\PreferencesForm.cs') 'Choose Clipman database file|Clipman compressed database\|\\*\.clipdb' 'Preferences no longer exposes database-file picker'
    Assert-TextMatches (Join-Path $repoRoot 'src\PreferencesForm.cs') 'Move to top' 'Preferences duplicate mode displays Move to top with spaces'
    Assert-TextMatches (Join-Path $repoRoot 'src\PreferencesForm.cs') 'Keep both' 'Preferences duplicate mode displays Keep both with spaces'
    Assert-TextMatches (Join-Path $repoRoot 'src\PreferencesForm.cs') 'StoredDuplicateMode' 'Preferences maps duplicate-mode display text back to stored values'
    Assert-TextMatches (Join-Path $repoRoot 'src\ClipmanApplicationContext.cs') 'Clipman database not found' 'Missing explicit database prompt'
    Assert-TextMatches (Join-Path $repoRoot 'src\ClipmanApplicationContext.cs') 'ShowPreferencesFromTray' 'Tray Preferences keeps hidden history hidden'
    Assert-TextMatches (Join-Path $repoRoot 'src\ClipmanApplicationContext.cs') 'Open &settings folder' 'Tray menu opens settings folder'
    Assert-TextMatches (Join-Path $repoRoot 'src\HistoryForm.cs') 'Open &settings folder' 'Options menu opens settings folder'
    Assert-TextDoesNotMatch (Join-Path $repoRoot 'src\HistoryForm.cs') 'optionsMenuItem\.ShowDropDown\(\)' 'Standard Options menu mnemonic handling'
    Assert-TextMatches (Join-Path $repoRoot 'src\ClipmanApplicationContext.cs') 'DescribeDropEffect\(int value\)' 'Drop effect display helper'
    Assert-TextMatches (Join-Path $repoRoot 'src\ClipmanApplicationContext.cs') 'string\.Join\(" or ", parts\)' 'Combined drop effect wording'
    Assert-TextMatches (Join-Path $repoRoot 'src\LinkClassifier.cs') 'UriSchemeHttps' 'Windows Links history classifier accepts HTTPS links'
    Assert-TextMatches (Join-Path $repoRoot 'src\HistoryTabs.cs') 'Normalize\(string value, bool linksEnabled\)' 'Windows history tab identity normalization'
    Assert-TextMatches (Join-Path $repoRoot 'src\PreferencesForm.cs') 'Show &Links history tab' 'Windows Preferences exposes Links history toggle'
    Assert-TextMatches (Join-Path $repoRoot 'src\HistoryForm.cs') 'Links history' 'Windows history window exposes Links history tab'
    Assert-TextMatches (Join-Path $repoRoot 'src\HistoryForm.cs') 'AccessibleName = "Text history"' 'Windows text history list has distinct accessible name'
    Assert-TextMatches (Join-Path $repoRoot 'src\HistoryForm.cs') 'list\.AccessibleName = "Links history"' 'Windows links history list has distinct accessible name'
    Assert-TextDoesNotMatch (Join-Path $repoRoot 'src\HistoryForm.cs') 'Text clipboard history, links history, and file clipboard history|Text clipboard history and file clipboard history' 'Windows tab control does not expose verbose section descriptions'
    Assert-TextMatches (Join-Path $repoRoot 'src\HistoryForm.cs') 'FocusHistoryTabControlNow' 'Windows tab control can retain focus during arrow-key tab navigation'
    Assert-TextMatches (Join-Path $repoRoot 'src\HistoryForm.cs') 'var keepTabControlFocus = tabs\.Focused' 'Windows tab control focus is detected before tab reload'
    Assert-TextMatches (Join-Path $repoRoot 'src\HistoryForm.cs') 'if \(keepTabControlFocus\)\s*\{\s*FocusHistoryTabControlNow\(\);' 'Windows tab control arrow navigation keeps focus on tabs'
    Assert-TextMatches (Join-Path $repoRoot 'src\HistoryForm.cs') 'private void SelectMainTab\(\)\s*\{[\s\S]{0,260}FocusHistoryListNow\(\);' 'Windows text tab shortcut lands in text history list'
    Assert-TextMatches (Join-Path $repoRoot 'src\HistoryForm.cs') 'private void SelectLinksTab\(\)\s*\{[\s\S]{0,360}FocusHistoryListNow\(\);' 'Windows links tab shortcut lands in links history list'
    Assert-TextMatches (Join-Path $repoRoot 'src\HistoryForm.cs') 'private void SelectFileClipboardTab\(\)\s*\{[\s\S]{0,260}FocusFileClipboardListNow\(\);' 'Windows file tab shortcut lands in file history list'
    Assert-TextMatches (Join-Path $repoRoot 'ClipmanMac\Sources\Clipman\LinkClassifier.swift') 'scheme == "http" \|\| scheme == "https"' 'Mac Links history classifier accepts HTTP and HTTPS links'
    Assert-TextMatches (Join-Path $repoRoot 'ClipmanMac\Sources\Clipman\HistoryTabs.swift') 'static let links = "Links"' 'Mac history tab identity constants include Links'
    Assert-TextMatches (Join-Path $repoRoot 'ClipmanMac\Sources\Clipman\PreferencesWindowController.swift') 'Show Links history tab' 'Mac Preferences exposes Links history toggle'
    Assert-TextMatches (Join-Path $repoRoot 'ClipmanMac\Sources\Clipman\HistoryWindowController.swift') 'Control\+3' 'Mac history mode accessibility documents Control+3 when Links is enabled'
    Assert-TextMatches (Join-Path $repoRoot 'ClipmanMac\Sources\Clipman\HistoryWindowController.swift') 'private let modeControl = NSSegmentedControl\(\)' 'Mac history mode control is not initialized with stale two-tab labels'
    Assert-TextMatches (Join-Path $repoRoot 'ClipmanMac\Sources\Clipman\AppController.swift') '(?s)func preferencesWindow\(_ controller: PreferencesWindowController, didUpdate settings: ClipmanSettings, passwordToSave: String\?\).*?historyWindow\.configureSort\(' 'Mac Preferences updates reconfigure visible history tabs'
    Assert-TextMatches (Join-Path $repoRoot 'src\AssemblyInfo.cs') 'AssemblyCompany\("Andre Louis"\)' 'Executable company metadata'
    Assert-TextMatches (Join-Path $repoRoot 'src\AssemblyInfo.cs') 'Copyright \(c\) Andre Louis' 'Executable copyright metadata'
    Assert-TextMatches (Join-Path $repoRoot 'src\HistoryForm.cs') 'Build stamp: ' 'About build stamp'
    Assert-TextMatches (Join-Path $repoRoot 'src\HistoryForm.cs') 'Based on earlier Clipman work by Tyler Spivey' 'About credits'
    Assert-TextMatches (Join-Path $repoRoot 'ClipmanMac\Scripts\shared-version.sh') 'AssemblyInformationalVersion' 'Mac shared version script reads Windows informational version'
    Assert-TextMatches (Join-Path $repoRoot 'ClipmanMac\Scripts\shared-version.sh') 'AssemblyFileVersion' 'Mac shared version script reads Windows file version'
    Assert-TextMatches (Join-Path $repoRoot 'ClipmanMac\Scripts\shared-version.sh') 'BuildStampUtcMs' 'Mac shared version script reads Windows build stamp'
    Assert-TextMatches (Join-Path $repoRoot 'ClipmanMac\Scripts\package-release.sh') 'zsh "\$ROOT/Scripts/shared-version\.sh" version' 'Mac release package reads shared short version'
    Assert-TextMatches (Join-Path $repoRoot 'ClipmanMac\Scripts\package-release.sh') 'zsh "\$ROOT/Scripts/shared-version\.sh" build' 'Mac release package reads shared build version'
    Assert-TextMatches (Join-Path $repoRoot 'ClipmanMac\Scripts\package-release.sh') 'zsh "\$ROOT/Scripts/shared-version\.sh" stamp' 'Mac release package reads shared build stamp'
    Assert-TextMatches (Join-Path $repoRoot 'ClipmanMac\Sources\Clipman\AppController.swift') 'ClipmanBuildStampUtcMs' 'Mac diagnostics include shared build stamp'
    Assert-TextMatches (Join-Path $repoRoot 'ClipmanMac\Sources\Clipman\RuntimeLogger.swift') 'ClipmanBuildStampUtcMs' 'Mac runtime log includes shared build stamp'
    Assert-TextMatches (Join-Path $repoRoot 'ClipmanMac\Scripts\package-release.sh') 'cp "\$ROOT/\.\./LICENSE\.txt" "\$APP/Contents/Resources/LICENSE\.txt"' 'Mac release package bundles root license'
    Assert-TextDoesNotMatch (Join-Path $repoRoot 'ClipmanMac\Scripts\package-release.sh') '<string>0\.1</string>|<string>1</string>' 'Mac release package must not hard-code bundle version'
    Assert-TextMatches (Join-Path $repoRoot 'ClipmanMac\Scripts\build-dev-app.sh') 'pkill -f "\$APP/Contents/MacOS/Clipman\|swift run\.\*Clipman"' 'Mac dev build restart closes the old app process before relaunch'
    Assert-TextMatches (Join-Path $repoRoot 'ClipmanMac\Scripts\build-dev-app.sh') 'zsh "\$ROOT/Scripts/shared-version\.sh" version' 'Mac dev package reads shared short version'
    Assert-TextMatches (Join-Path $repoRoot 'ClipmanMac\Scripts\build-dev-app.sh') 'cp "\$ROOT/\.\./LICENSE\.txt" "\$APP/Contents/Resources/LICENSE\.txt"' 'Mac dev package bundles root license'
    Assert-TextDoesNotMatch (Join-Path $repoRoot 'ClipmanMac\Scripts\build-dev-app.sh') '<string>0\.1</string>|<string>1</string>' 'Mac dev package must not hard-code bundle version'
    Assert-TextMatches (Join-Path $repoRoot '.gitignore') 'ClipmanMac/dist/' 'Root gitignore ignores Mac release dist'
    Assert-TextMatches (Join-Path $repoRoot '.gitignore') 'ClipmanMac/\.build/' 'Root gitignore ignores Swift build products'

    $privateMachineOne = 'Mer' + 'jille'
    $privateMachineTwo = 'Ko' + 'bo'
    $privateMachineThree = 'VIP' + '40'
    $bs = [string][char]92
    $forbidden = [regex]::Escape($privateMachineOne) + '|' +
        [regex]::Escape($privateMachineTwo) + '|' +
        [regex]::Escape($privateMachineThree) + '|' +
        'D:' + [regex]::Escape($bs) + '|' +
        'E:' + [regex]::Escape($bs) + '|' +
        '\bolder installs\b|\bolder versions\b|migration|migrate automatically|temporary workaround|2\.0 test|Future Linux helper|Drop' + 'box'
    Assert-TextDoesNotMatch $manual $forbidden 'Manual'
    Assert-TextDoesNotMatch $readme $forbidden 'README'
    Assert-TextDoesNotMatch $serverManual $forbidden 'Server manual'
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

        var youtubeShare = UrlTrackingCleaner.CleanForSharing("https://www.youtube.com/watch?v=A4jvHpegXHk&t=4s&pp=ygUVQXJlIHRoZSBmdW5kcyBnbGFyZGVk");
        Assert(youtubeShare == "https://www.youtube.com/watch?v=A4jvHpegXHk", "Share cleaner did not remove YouTube timestamp and share metadata.");

        var boundaryText = "https://example.com/a-b?x=1";
        Assert(TextBoundaryNavigator.NextBoundary(boundaryText, 0) == 5, "Text boundary navigator did not stop after URL scheme text.");
        Assert(TextBoundaryNavigator.NextBoundary(boundaryText, 5) == 8, "Text boundary navigator did not stop after URL punctuation.");
        Assert(TextBoundaryNavigator.NextBoundary(boundaryText, 21) == 22, "Text boundary navigator did not stop at URL dash.");
        Assert(TextBoundaryNavigator.PreviousBoundary(boundaryText, 22) == 21, "Text boundary navigator did not move back to URL dash.");

        Assert(LineEndingNormalizer.ToWindows("a\nb\rc\r\nd\u2028e\u2029f\u0085g") == "a\r\nb\r\nc\r\nd\r\ne\r\nf\r\ng", "Windows line-ending normalization failed.");
        Assert(LineEndingNormalizer.ToUnix("a\r\nb\rc") == "a\nb\nc", "Unix line-ending normalization failed.");
        Assert(LineEndingNormalizer.ToOldMac("a\r\nb\nc") == "a\rb\rc", "Old Mac line-ending normalization failed.");

        var sensitiveOffSettings = new AppSettings
        {
            SensitiveDataMode = SensitiveDataExclusion.ModeOff,
            SensitiveDataPresetIds = { "credit-card", "international-phone" }
        };
        Assert(SensitiveDataExclusion.FindMatch("Card 4111 1111 1111 1111", sensitiveOffSettings) == null, "Sensitive data exclusions matched while disabled.");

        var creditCardSettings = new AppSettings
        {
            SensitiveDataMode = SensitiveDataExclusion.ModeExclude,
            SensitiveDataPresetIds = { "credit-card" }
        };
        Assert(SensitiveDataExclusion.FindMatch("Card 4111 1111 1111 1111", creditCardSettings) != null, "Sensitive data exclusions did not match a valid Luhn card number.");
        Assert(SensitiveDataExclusion.FindMatch("Card 4111 1111 1111 1112", creditCardSettings) == null, "Sensitive data exclusions matched an invalid Luhn card number.");

        var phoneSettings = new AppSettings
        {
            SensitiveDataMode = SensitiveDataExclusion.ModeExclude,
            SensitiveDataPresetIds = { "international-phone" }
        };
        Assert(SensitiveDataExclusion.FindMatch("Call +447890123456", phoneSettings) != null, "Sensitive data exclusions did not match a compact international phone number.");
        Assert(SensitiveDataExclusion.FindMatch("Call +44 7890 123 456", phoneSettings) != null, "Sensitive data exclusions did not match a spaced international phone number.");
        Assert(SensitiveDataExclusion.FindMatch("Reference 447890123456", phoneSettings) == null, "Sensitive data exclusions matched a phone number without an international plus prefix.");

        var licenseSettings = new AppSettings
        {
            SensitiveDataMode = SensitiveDataExclusion.ModeExclude,
            SensitiveDataPresetIds = { "software-license-key" }
        };
        Assert(SensitiveDataExclusion.FindMatch("Key AAAAA-BBBBB-CCCCC-DDDDD-EEEEE", licenseSettings) != null, "Sensitive data exclusions did not match a software license key shape.");
        Assert(SensitiveDataExclusion.FindMatch("Key AAAAABBBBBCCCCCDDDDDEEEEE", licenseSettings) == null, "Sensitive data exclusions matched a software license key without hyphen groups.");

        var tokenSettings = new AppSettings
        {
            SensitiveDataMode = SensitiveDataExclusion.ModeExclude,
            SensitiveDataPresetIds = { "api-token" }
        };
        Assert(SensitiveDataExclusion.FindMatch("Token abcdefghijklmnopqrstuvwxyzABCDEF", tokenSettings) != null, "Sensitive data exclusions did not match a raw long API token.");
        var amazonUrl = "https://www.amazon.co.uk/EM7345-Module-Thinkpad-T431s-T440p-default/dp/B07QQZ899Y/ref=sr_1_1?crid=19SLV6CUQAJRO&dib=eyJ2IjoiMSJ9.IwA4NYkA3RbfsXGnAR-_nuQChbG5SN9bZYkUvhTgjSR6XBSPGX8GKZxD60U01mj9Dz5nLht6uFs-wXpXGCbVDEBhkWzUQ4oNhVAHpkY3bYRH2rkNZOax53v29X9hBD8guA1artIrv20knKx4qF7eu0tNQN0hXDosaGvi1Q3840cYapl55rYnW09VmW41D17dKGxLBDsc6zhUg6uSh330E8C8d3KuLBQ0mldFSug8N5g.boDRMrutCGh7SV-UoZjDNmNqglQ_cTbTnt9ihkmMTu0&dib_tag=se&keywords=Lenovo+WAN+card&qid=1783960991&sprefix=lenovo+wan+car%2Caps%2C165&sr=8-1";
        Assert(SensitiveDataExclusion.FindMatch(amazonUrl, tokenSettings) == null, "Sensitive data exclusions matched an ordinary Amazon URL as a long API token.");
        var archiveUrl = "https://web.archive.org/web/20260714160005/https://www.erininthemorning.com/p/terf-activist-jk-rowling-threatens";
        Assert(SensitiveDataExclusion.FindMatch(archiveUrl, new AppSettings { SensitiveDataMode = SensitiveDataExclusion.ModeExclude, SensitiveDataPresetIds = { "credit-card", "us-ssn", "international-phone", "api-token", "software-license-key", "us-drivers-license" } }) == null, "Sensitive data exclusions matched an ordinary full URL.");

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

        var deleteSyncPath = Path.Combine(Path.GetTempPath(), "clipman-delete-sync-" + Guid.NewGuid().ToString("N") + ".clipdb");
        using (var deleteStore = new ClipStore(deleteSyncPath, string.Empty))
        {
            var deleteEntry = deleteStore.AddText("delete marker smoke", "KeepBoth", 100, 0);
            deleteStore.Delete(deleteEntry.Id);
        }
        var deleteSyncDatabase = ClipDatabaseFile.Load(deleteSyncPath);
        Assert(deleteSyncDatabase.Entries.All(e => e.Text != "delete marker smoke"), "Deleted text entry remained in the local database.");
        Assert(deleteSyncDatabase.DeletedEntries.Any(e => e.Id.Length > 0), "Deleted text entry did not leave a sync delete marker.");
        File.Delete(deleteSyncPath);

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

        var fileHistoryPath = Path.Combine(Path.GetTempPath(), "clipman-file-history-test-" + Guid.NewGuid().ToString("N") + ".clipdb");
        ClipDatabaseFile.SaveAtomic(fileHistoryPath, new FileClipboardDatabase
        {
            Events =
            {
                new ClipboardEventSummary
                {
                    Source = "Smoke",
                    SourceMachine = "TestMachine",
                    Operation = "Copy",
                    FileCount = 1,
                    Files = { Path.Combine(Path.GetTempPath(), "example.txt") },
                    Formats = { "FileDrop" }
                }
            }
        }, password);
        Assert(ClipDatabaseFile.IsEncryptedFile(fileHistoryPath), "Encrypted file-history .clipdb file was not recognized as encrypted.");
        var fileHistoryLoaded = ClipDatabaseFile.Load<FileClipboardDatabase>(fileHistoryPath, password);
        Assert(fileHistoryLoaded.Events.Count == 1 && fileHistoryLoaded.Events[0].Files.Count == 1, "File-history .clipdb round trip failed.");
        File.Delete(fileHistoryPath);

        var cleanupHistoryPath = Path.Combine(Path.GetTempPath(), "clipman-file-history-cleanup-" + Guid.NewGuid().ToString("N") + ".clipdb");
        var existingFile = Path.Combine(Path.GetTempPath(), "clipman-existing-" + Guid.NewGuid().ToString("N") + ".tmp");
        File.WriteAllText(existingFile, "exists");
        using (var fileStore = new FileClipboardEventStore(cleanupHistoryPath, () => string.Empty))
        {
            fileStore.Add(new ClipboardEventSummary
            {
                Source = "Explorer",
                Operation = "Copy",
                FileCount = 1,
                Files = { existingFile },
                Formats = { "FileDrop" }
            });
            fileStore.Add(new ClipboardEventSummary
            {
                Source = "Explorer",
                Operation = "Copy",
                FileCount = 1,
                Files = { Path.Combine(Path.GetTempPath(), "clipman-missing-" + Guid.NewGuid().ToString("N") + ".tmp") },
                Formats = { "FileDrop" }
            });
            fileStore.Add(new ClipboardEventSummary
            {
                Source = "Forge16",
                Operation = "",
                FileCount = 0,
                Formats = { "WaveAudio" }
            });
            var pinnedNonFile = fileStore.GetEvents().First(e => e.Source == "Forge16");
            Assert(fileStore.TogglePinned(pinnedNonFile.Id), "File-history TogglePinned did not pin the selected event.");
            var removedUnavailable = fileStore.RemoveUnavailableEvents();
            Assert(removedUnavailable == 1, "File-history unavailable cleanup did not protect pinned unavailable events.");
            var remainingFileEvents = fileStore.GetEvents();
            Assert(remainingFileEvents.Count == 2, "File-history unavailable cleanup returned the wrong event count when a pinned unavailable event was present.");
            Assert(remainingFileEvents.Any(e => e.Pinned && e.Source == "Forge16"), "File-history unavailable cleanup removed a pinned event.");
            Assert(remainingFileEvents.Any(e => e.Files.Count == 1 && e.Files[0] == existingFile), "File-history unavailable cleanup removed the existing file event.");
            var beforeMove = remainingFileEvents.Select(e => e.Id).ToList();
            fileStore.MoveEvents(new[] { beforeMove.Last() }, -1);
            var afterMove = fileStore.GetEvents().Select(e => e.Id).ToList();
            Assert(beforeMove.Count == afterMove.Count, "File-history move changed the event count.");
        }
        File.Delete(cleanupHistoryPath);
        File.Delete(existingFile);

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

        var pushMergeTarget = new ClipDatabase
        {
            Entries =
            {
                new ClipEntry { Id = "push-after-use", Text = "same text", SourceMachine = "Desktop", CreatedUnixMs = 100, LastUsedUnixMs = 500, ManualOrder = 1 }
            }
        };
        var pushedMergeSource = new ClipDatabase
        {
            Entries =
            {
                new ClipEntry { Id = "push-after-use", Text = "same text", SourceMachine = "Laptop", CreatedUnixMs = 600, LastUsedUnixMs = 200, ManualOrder = 1 }
            }
        };
        SyncConflictResolver.MergeInto(pushMergeTarget, pushedMergeSource);
        Assert(pushMergeTarget.Entries[0].CreatedUnixMs == 600, "Newer pushed entry timestamp did not win merge when local last-used was newer.");
        Assert(pushMergeTarget.Entries[0].SourceMachine == "Laptop", "Newer pushed entry source machine did not win merge when local last-used was newer.");

        var storeMergeTarget = new ClipDatabase
        {
            Entries =
            {
                new ClipEntry { Id = "store-push-after-use", Text = "same store text", SourceMachine = "Desktop", CreatedUnixMs = 100, LastUsedUnixMs = 500, ManualOrder = 1 }
            }
        };
        var storeMergeSource = new ClipDatabase
        {
            Entries =
            {
                new ClipEntry { Id = "store-push-after-use", Text = "same store text", SourceMachine = "Laptop", CreatedUnixMs = 600, LastUsedUnixMs = 200, ManualOrder = 1 }
            }
        };
        var storeMergeMethod = typeof(ClipStore).GetMethod("MergeDatabaseIntoLocked", System.Reflection.BindingFlags.NonPublic | System.Reflection.BindingFlags.Static);
        Assert(storeMergeMethod != null, "Could not locate ClipStore server merge method for regression test.");
        var storeMergeChanged = (bool)storeMergeMethod.Invoke(null, new object[] { storeMergeTarget, storeMergeSource });
        Assert(storeMergeChanged, "ClipStore server merge did not report a changed pushed entry.");
        Assert(storeMergeTarget.Entries[0].CreatedUnixMs == 600, "ClipStore server merge did not keep newer pushed timestamp.");
        Assert(storeMergeTarget.Entries[0].SourceMachine == "Laptop", "ClipStore server merge did not keep newer pushed source machine.");

        var mainSettings = Path.Combine(conflictDir, "Desktop-settings.json");
        var conflictSettings = Path.Combine(conflictDir, "Desktop-settings (Laptop).json");
        JsonUtil.SaveAtomic(mainSettings, new AppSettings { MaxHistoryEntries = 111 });
        System.Threading.Thread.Sleep(20);
        JsonUtil.SaveAtomic(conflictSettings, new AppSettings { MaxHistoryEntries = 222 });
        SyncConflictResolver.ResolveSettingsConflicts(mainSettings);
        var settings = JsonUtil.Load<AppSettings>(mainSettings);
        Assert(settings.MaxHistoryEntries == 222, "Settings conflict resolver did not keep newest settings.");
        Assert(!File.Exists(conflictSettings), "Settings conflict file was not removed.");

        var portableApp = Path.Combine(conflictDir, "PortableApp");
        var oldApp = Path.Combine(conflictDir, "OldPortableApp");
        Directory.CreateDirectory(Path.Combine(portableApp, "Settings"));
        Directory.CreateDirectory(Path.Combine(oldApp, "Settings"));
        var portableStore = new SettingsStore(portableApp);
        var defaultSettings = portableStore.Load();
        Assert(defaultSettings.UseDefaultDatabasePath, "Fresh settings did not mark the database path as default.");
        Assert(defaultSettings.DatabasePath == portableStore.DefaultDatabasePath(), "Fresh settings did not use the current default database path.");

        File.WriteAllText(portableStore.SettingsPath, "{\"DatabasePath\":\"" + EscapeJson(Path.Combine(oldApp, "Settings", "clipman-history.clipdb")) + "\"}");
        var movedDefaultSettings = portableStore.Load();
        Assert(movedDefaultSettings.UseDefaultDatabasePath, "Old default-looking database path was not treated as default.");
        Assert(movedDefaultSettings.DatabasePath == portableStore.DefaultDatabasePath(), "Moved default database path did not follow the app folder.");

        var explicitDb = Path.Combine(conflictDir, "Shared", "history.clipdb");
        Directory.CreateDirectory(Path.GetDirectoryName(explicitDb));
        File.WriteAllText(portableStore.SettingsPath, "{\"DatabasePath\":\"" + EscapeJson(explicitDb) + "\",\"UseDefaultDatabasePath\":false}");
        var explicitSettings = portableStore.Load();
        Assert(!explicitSettings.UseDefaultDatabasePath, "Explicit database path was incorrectly marked as default.");
        Assert(explicitSettings.DatabasePath == explicitDb, "Explicit database path was not preserved.");
        var explicitSettingsFolder = Path.GetDirectoryName(explicitDb);
        Assert(portableStore.SettingsDirectory == explicitSettingsFolder, "Explicit data folder did not become the active settings folder.");
        Assert(portableStore.SettingsPath == Path.Combine(explicitSettingsFolder, Environment.MachineName + "-settings.json"), "Explicit data folder did not get the machine settings file.");
        Assert(File.Exists(Path.Combine(portableApp, "Settings", "settings-location.json")), "Settings location pointer was not written beside the app.");
        Assert(File.Exists(portableStore.SettingsPath), "Machine settings were not written into the explicit data folder.");
        var reloadedExplicitStore = new SettingsStore(portableApp);
        var reloadedExplicitSettings = reloadedExplicitStore.Load();
        Assert(reloadedExplicitSettings.DatabasePath == explicitDb, "Settings location pointer did not reload the explicit database path.");
        Assert(reloadedExplicitStore.SettingsDirectory == explicitSettingsFolder, "Settings location pointer did not reload the explicit data folder.");
        var settingsLocationPointer = File.ReadAllText(Path.Combine(portableApp, "Settings", "settings-location.json"), Encoding.UTF8);
        Assert(settingsLocationPointer.Contains("\"clients\""), "Settings location pointer did not use per-client storage.");
        Assert(settingsLocationPointer.Contains(Environment.MachineName), "Settings location pointer did not include this machine.");

        var windOnjFolder = Path.Combine(conflictDir, "WindOnjSettings");
        Directory.CreateDirectory(windOnjFolder);
        var pointerConflict = Path.Combine(portableApp, "Settings", "settings-location (WindOnj).json");
        File.WriteAllText(pointerConflict, "{\"clients\":{\"WindOnj\":\"" + EscapeJson(windOnjFolder) + "\"}}", Encoding.UTF8);
        var conflictMergedStore = new SettingsStore(portableApp);
        conflictMergedStore.Load();
        var mergedPointer = File.ReadAllText(Path.Combine(portableApp, "Settings", "settings-location.json"), Encoding.UTF8);
        Assert(mergedPointer.Contains(Environment.MachineName), "Settings location pointer merge lost this machine.");
        Assert(mergedPointer.Contains("WindOnj"), "Settings location pointer merge lost WindOnj.");
        Assert(mergedPointer.Contains(EscapeJson(windOnjFolder)), "Settings location pointer merge lost WindOnj folder.");
        Assert(!File.Exists(pointerConflict), "Settings location pointer conflict file was not removed.");

        var pastedServerSettingsStore = new SettingsStore(Path.Combine(conflictDir, "pasted-server-settings"));
        var pastedServerSettings = new AppSettings
        {
            StorageMode = "Server",
            ServerUrl = "http://home-server:49152, and using the token from that settings file.",
            ServerToken = "\"AuthToken\": \"token-from-json-line\",",
            UseDefaultDatabasePath = true
        };
        pastedServerSettingsStore.Save(pastedServerSettings);
        var cleanedServerSettings = pastedServerSettingsStore.Load();
        Assert(cleanedServerSettings.ServerUrl == "clipman://home-server:49152", "Pasted server URL prose was not cleaned.");
        Assert(cleanedServerSettings.ServerToken == "token-from-json-line", "Copied server token JSON line was not cleaned.");
        var cleanedServerSettingsJson = File.ReadAllText(pastedServerSettingsStore.SettingsPath);
        Assert(!cleanedServerSettingsJson.Contains("\"ServerToken\""), "Raw server token was serialized to settings.");
        Assert(!cleanedServerSettingsJson.Contains("token-from-json-line"), "Server token plaintext remained in settings.");
        Assert(cleanedServerSettingsJson.Contains("\"ProtectedServerToken\""), "Protected server token was not serialized to settings.");
        var reloadedProtectedServerSettingsStore = new SettingsStore(Path.Combine(conflictDir, "pasted-server-settings"));
        var reloadedProtectedServerSettings = reloadedProtectedServerSettingsStore.Load();
        Assert(reloadedProtectedServerSettings.ServerToken == "token-from-json-line", "Protected server token did not reload.");

        var legacyServerSettingsStore = new SettingsStore(Path.Combine(conflictDir, "legacy-server-settings"));
        Directory.CreateDirectory(legacyServerSettingsStore.AppSettingsDirectory);
        var legacyServerSettingsPath = Path.Combine(legacyServerSettingsStore.AppSettingsDirectory, Environment.MachineName + "-settings.json");
        File.WriteAllText(legacyServerSettingsPath, "{\"StorageMode\":\"Server\",\"ServerUrl\":\"home-server:49152\",\"ServerToken\":\"legacy-plaintext-token\"}");
        var migratedLegacyServerSettings = legacyServerSettingsStore.Load();
        Assert(migratedLegacyServerSettings.ServerToken == "legacy-plaintext-token", "Legacy plaintext server token did not migrate.");
        var migratedLegacyServerJson = File.ReadAllText(legacyServerSettingsStore.SettingsPath);
        Assert(!migratedLegacyServerJson.Contains("\"ServerToken\""), "Legacy raw server token property survived migration.");
        Assert(!migratedLegacyServerJson.Contains("legacy-plaintext-token"), "Legacy raw server token value survived migration.");

        var secretPath = Path.Combine(conflictDir, "Secrets", Environment.MachineName + "-secrets.clipdb");
        Directory.CreateDirectory(Path.GetDirectoryName(secretPath));
        var secretStore = new SecretStore(secretPath, () => "secret-password");
        secretStore.SaveEntry(new SecretEntry { Id = "secret-one", Name = "Router", Value = "private-value", Hotkey = "Ctrl+Alt+F1" });
        var reloadedSecretStore = new SecretStore(secretPath, () => "secret-password");
        var secrets = reloadedSecretStore.GetEntries().ToList();
        Assert(secrets.Count == 1, "Secret store did not reload saved secret.");
        Assert(secrets[0].Name == "Router", "Secret store did not preserve secret name.");
        Assert(secrets[0].Value == "private-value", "Secret store did not preserve secret value.");
        Assert(secrets[0].Hotkey == "Ctrl+Alt+F1", "Secret store did not preserve quick-paste hotkey.");
        Assert(!File.ReadAllText(secretPath, Encoding.UTF8).Contains("private-value"), "Secret store wrote secret value as plain text.");
        var noPasswordSecretStore = new SecretStore(Path.Combine(conflictDir, "SecretsNoPassword", Environment.MachineName + "-secrets.clipdb"), () => "");
        var secretPasswordRequired = false;
        try
        {
            noPasswordSecretStore.SaveEntry(new SecretEntry { Name = "NoPassword", Value = "must-not-save" });
        }
        catch (DatabasePasswordRequiredException)
        {
            secretPasswordRequired = true;
        }
        Assert(secretPasswordRequired, "Secret store allowed saving without a history password.");

        var sessionApp = Path.Combine(conflictDir, "SessionOnlyApp");
        var sessionDb = Path.Combine(conflictDir, "SessionOnlyData", "clipman-history.clipdb");
        Directory.CreateDirectory(Path.GetDirectoryName(sessionDb));
        Directory.CreateDirectory(Path.Combine(sessionApp, "Settings"));
        var sessionStore = new SettingsStore(sessionApp);
        var sessionSettingsPath = Path.Combine(sessionApp, "Settings", Environment.MachineName + "-settings.json");
        var sessionOnlySettings = new AppSettings
        {
            DatabasePath = sessionDb,
            UseDefaultDatabasePath = false,
            DatabaseEncryptionEnabled = true,
            RememberDatabasePassword = false,
            ProtectedDatabasePassword = "should-not-survive",
            PlainDatabasePassword = "session-only-secret"
        };
        JsonUtil.SaveAtomic(sessionSettingsPath, sessionOnlySettings);
        var sessionOnlyJson = File.ReadAllText(sessionSettingsPath, Encoding.UTF8);
        Assert(!sessionOnlyJson.Contains("PlainDatabasePassword"), "Session-only database password was serialized to settings.");
        var normalizedSessionOnly = sessionStore.Load();
        Assert(normalizedSessionOnly.DatabaseEncryptionEnabled, "Session-only encrypted settings did not keep encryption enabled.");
        Assert(!normalizedSessionOnly.RememberDatabasePassword, "Session-only encrypted settings incorrectly enabled password remembering.");
        Assert(string.IsNullOrEmpty(normalizedSessionOnly.ProtectedDatabasePassword), "Session-only encrypted settings kept a protected password.");

        var legacyPasswordApp = Path.Combine(conflictDir, "LegacyPasswordApp");
        var legacyPasswordDb = Path.Combine(conflictDir, "LegacyPasswordData", "clipman-history.clipdb");
        Directory.CreateDirectory(Path.Combine(legacyPasswordApp, "Settings"));
        Directory.CreateDirectory(Path.GetDirectoryName(legacyPasswordDb));
        var legacyPasswordStore = new SettingsStore(legacyPasswordApp);
        var legacyPasswordSettingsPath = Path.Combine(legacyPasswordApp, "Settings", Environment.MachineName + "-settings.json");
        var legacyJson = "{\"DatabasePath\":\"" + EscapeJson(legacyPasswordDb) + "\",\"UseDefaultDatabasePath\":false,\"DatabaseEncryptionEnabled\":true,\"ProtectedDatabasePassword\":\"legacy-protected-placeholder\"}";
        File.WriteAllText(legacyPasswordSettingsPath, legacyJson, Encoding.UTF8);
        var legacyLoaded = legacyPasswordStore.Load();
        Assert(legacyLoaded.RememberDatabasePassword, "Legacy protected settings were not treated as remembered-password settings.");

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

    private static string EscapeJson(string text)
    {
        return (text ?? string.Empty).Replace("\\", "\\\\").Replace("\"", "\\\"");
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
            (Join-Path $repoRoot 'src\HistoryTabs.cs'),
            (Join-Path $repoRoot 'src\LinkClassifier.cs'),
            (Join-Path $repoRoot 'src\JsonUtil.cs'),
            (Join-Path $repoRoot 'src\ClipDatabaseFile.cs'),
            (Join-Path $repoRoot 'src\FileClipboardEventStore.cs'),
            (Join-Path $repoRoot 'src\UrlTrackingCleaner.cs'),
            (Join-Path $repoRoot 'src\TextBoundaryNavigator.cs'),
            (Join-Path $repoRoot 'src\LineEndingNormalizer.cs'),
            (Join-Path $repoRoot 'src\SensitiveDataExclusion.cs'),
            (Join-Path $repoRoot 'src\SqliteClipboardImporter.cs'),
            (Join-Path $repoRoot 'src\SyncConflictResolver.cs'),
            (Join-Path $repoRoot 'src\SharedUpdateState.cs'),
            (Join-Path $repoRoot 'src\ServerSettingsSanitizer.cs'),
            (Join-Path $repoRoot 'src\ServerDatabaseIdentity.cs'),
            (Join-Path $repoRoot 'src\ServerStorageClient.cs'),
            (Join-Path $repoRoot 'src\ClipStore.cs'),
            (Join-Path $repoRoot 'src\SettingsStore.cs'),
            (Join-Path $repoRoot 'src\SecretStore.cs'),
            (Join-Path $repoRoot 'src\DatabasePasswordProtector.cs'),
            (Join-Path $repoRoot 'src\ServerTokenProtector.cs'),
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

Clear-OldSmokeFolders

if ($ServerOnly) {
    if ([string]::IsNullOrWhiteSpace($Version)) {
        $Version = Read-AppVersion
    }

    Assert-ServerSmokeSurface
    powershell -ExecutionPolicy Bypass -File (Join-Path $repoRoot 'Test-ReleasePrivacy.ps1')
    if ($LASTEXITCODE -ne 0) {
        Fail 'Release privacy check failed.'
    }
    if (!$SkipBuild) {
        powershell -ExecutionPolicy Bypass -File (Join-Path $repoRoot 'Build-ServerBundle.ps1')
        if ($LASTEXITCODE -ne 0) {
            Fail 'Server bundle build failed.'
        }
    }
    Assert-ServerBundleZipParity $Version
    Invoke-LiveServerDeploy
    Write-Host 'Clipman Server smoke test passed.'
    return
}

if (!$SkipBuild) {
    & (Join-Path $repoRoot 'Build.ps1')
}

if ([string]::IsNullOrWhiteSpace($Version)) {
    $Version = Read-AppVersion
}

Assert-ManualAndReadmeClean
powershell -ExecutionPolicy Bypass -File (Join-Path $repoRoot 'Test-ReleasePrivacy.ps1')
if ($LASTEXITCODE -ne 0) {
    Fail 'Release privacy check failed.'
}
if (!$ClientOnly -and (Test-Path -LiteralPath (Join-Path $repoRoot 'Build-ServerBundle.ps1'))) {
    powershell -ExecutionPolicy Bypass -File (Join-Path $repoRoot 'Build-ServerBundle.ps1')
    if ($LASTEXITCODE -ne 0) {
        Fail 'Server bundle build failed.'
    }
    Assert-ServerBundleZipParity $Version
}
if (!$ClientOnly) {
    Invoke-LiveServerDeploy
}
Assert-GitHubActivityChecked $Version
Write-CommunityMentionReminder
Assert-HandoverParity $Version
Assert-MacReleaseAsset $Version
Assert-InstalledMacApp $Version
Assert-CodeBehavior
Assert-CleanPortable $portable
Invoke-LocalUpdaterSmoke $Version
Invoke-PostPublishUpdateSmoke $Version
Deploy-LiveCopy $LivePath
Assert-LiveCopyReasonable $LivePath
Invoke-RemoteInteractiveStartSmoke

Write-Host 'Clipman smoke test passed.'
