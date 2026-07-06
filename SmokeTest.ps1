param(
    [string]$LivePath = '',
    [switch]$SkipBuild,
    [switch]$RunPostPublishUpdateSmoke,
    [switch]$RequireMacReleaseAsset,
    [string]$Version = '',
    [int[]]$ReviewedOpenIssue = @(),
    [switch]$SkipGitHubActivityCheck
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

    Assert-NotExists (Join-Path $path 'README.md') 'Source README in portable output'
    Assert-NotExists (Join-Path $path 'clipman-history.clipdb') 'Root compressed history database in portable output'
    Assert-NotExists (Join-Path $path 'clipman-history.json') 'Root history database in portable output'
    Assert-NotExists (Join-Path $path 'clipman-settings.json') 'Root settings file in portable output'
    Assert-NotExists (Join-Path $path 'Settings') 'Runtime Settings folder in clean portable output'
    Assert-NotExists (Join-Path $path 'Logs') 'Runtime Logs folder in clean portable output'
    Assert-NotExists (Join-Path $path 'Reports') 'Runtime Reports folder in clean portable output'
    Assert-NotExists (Join-Path $path 'Backups') 'Runtime Backups folder in clean portable output'
    Assert-NotExists (Join-Path $path 'sounds\sounds') 'Nested duplicate sounds folder'

    $expectedSounds = @('copy.wav', 'off.wav', 'on.wav', 'remote.wav', 'skip.wav')
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
    if (!$RequireMacReleaseAsset) {
        return
    }

    Write-Host 'Checking Mac release asset parity.'
    $expectedBundleVersion = Read-AppFileVersion
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
        foreach ($sound in @('copy.wav', 'off.wav', 'on.wav', 'remote.wav', 'skip.wav')) {
            Assert-ZipEntry $zip "Clipman.app/Contents/Resources/sounds/$sound" "Bundled Mac sound $sound" | Out-Null
        }

        Assert-ZipTextMatches $zip 'Clipman.app/Contents/Info.plist' "<key>CFBundleShortVersionString</key>\s*<string>$([regex]::Escape($expectedVersion))</string>" 'Mac short version'
        Assert-ZipTextMatches $zip 'Clipman.app/Contents/Info.plist' "<key>CFBundleVersion</key>\s*<string>$([regex]::Escape($expectedBundleVersion))</string>" 'Mac bundle version'

        $rootManual = Get-Content -LiteralPath (Join-Path $repoRoot 'Manual.html') -Raw
        $zipManual = Read-ZipEntryText $zip 'Clipman.app/Contents/Resources/Manual.html' 'Bundled Mac manual'
        if ($zipManual -ne $rootManual) {
            Fail 'Bundled Mac manual does not match root Manual.html.'
        }

        $rootLicense = Get-Content -LiteralPath (Join-Path $repoRoot 'LICENSE.txt') -Raw
        $zipLicense = Read-ZipEntryText $zip 'Clipman.app/Contents/Resources/LICENSE.txt' 'Bundled Mac license'
        if ($zipLicense -ne $rootLicense) {
            Fail 'Bundled Mac license does not match root LICENSE.txt.'
        }
    }
    finally {
        $zip.Dispose()
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

function Assert-UniqueWindowsControlMnemonics([string]$path, [string]$description) {
    Assert-Exists $path $description
    $text = Get-Content -LiteralPath $path -Raw
    $matches = [regex]::Matches($text, 'Text\s*=\s*"((?:[^"\\]|\\.)*)"')
    $seen = @{}
    foreach ($match in $matches) {
        $label = $match.Groups[1].Value
        $mnemonicMatches = [regex]::Matches($label, '&(?!&)([A-Za-z0-9])')
        foreach ($mnemonicMatch in $mnemonicMatches) {
            $key = $mnemonicMatch.Groups[1].Value.ToUpperInvariant()
            if ($seen.ContainsKey($key)) {
                Fail "$description has duplicate Alt+$key mnemonic: '$($seen[$key])' and '$label'"
            }
            $seen[$key] = $label
        }
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
    Assert-TextMatches (Join-Path $repoRoot 'GITHUB-RELEASE-RULES.md') 'GitHub Issue Gate' 'Release rules GitHub issue gate section'
    Assert-TextMatches (Join-Path $repoRoot 'GITHUB-RELEASE-RULES.md') 'Do not publish first and inspect issues afterward' 'Release rules no-publish-before-issues wording'
    Assert-TextMatches (Join-Path $repoRoot 'GITHUB-RELEASE-RULES.md') 'Private Handover Parity' 'Release rules handover parity section'
    Assert-TextDoesNotMatch (Join-Path $repoRoot 'GITHUB-RELEASE-RULES.md') '[A-Z]:\\' 'Release rules must not contain local Windows paths'
}

function Assert-ManualAndReadmeClean {
    $manual = Join-Path $repoRoot 'Manual.html'
    $readme = Join-Path $repoRoot 'README.md'

    Assert-TextMatches $manual '<h2 id="contents">Contents</h2>' 'Manual table of contents'
    Assert-TextMatches $manual 'Project page: <a href="https://github.com/OnjLouis/Clipman">' 'Manual project page link'
    Assert-TextMatches $manual 'Add, remove, move, rename, group, pin, or edit text entries on one machine' 'Manual opening shared database explanation'
    Assert-TextMatches $manual 'Remove URL tracking' 'Manual URL tracking documentation'
    Assert-TextMatches $manual 'Clean link for sharing' 'Manual clean-link documentation'
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
    Assert-TextMatches $manual 'Ctrl\+1</code> to <code>Ctrl\+5' 'Manual preferences tab shortcut documentation'
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
    Assert-TextMatches $readme 'Ctrl\+1` to `Ctrl\+5' 'README preferences tab range'
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
    Assert-TextDoesNotMatch (Join-Path $repoRoot 'src\HistoryForm.cs') 'Sort by &machine|&Trim leading|&URL encode|Find &previous|&Copy and close|&Clear file history' 'Avoid duplicate menu mnemonics'
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
    Assert-TextMatches (Join-Path $repoRoot 'src\PreferencesForm.cs') 'Automatically remove &unavailable file-history events' 'File history preference auto cleanup checkbox'
    Assert-TextMatches (Join-Path $repoRoot 'src\PreferencesForm.cs') 'Automatically group &new clips by source application' 'General preference auto-group unique mnemonic'
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
    Assert-TextMatches (Join-Path $repoRoot 'src\TemplateResolver.cs') '\{\{year_full\}\} - four-digit year' 'Windows template variable reference is line-oriented'
    Assert-TextMatches (Join-Path $repoRoot 'src\ClipmanApplicationContext.cs') 'ResolvedEntryText\(entry\)' 'Windows copy and Quick Paste resolve template entries at output time'
    Assert-TextMatches (Join-Path $repoRoot 'src\HistoryForm.cs') 'store\.SetTemplate\(entry\.Id, dialog\.EntryIsTemplate\)' 'Windows Entry Properties saves template flag'
    Assert-TextMatches (Join-Path $repoRoot 'ClipmanMac\Sources\ClipmanCore\Models.swift') 'public var IsTemplate: Bool' 'Mac shared entries store template flag'
    Assert-TextMatches (Join-Path $repoRoot 'ClipmanMac\Sources\Clipman\TemplateResolver.swift') 'enum TemplateResolver' 'Mac template resolver exists'
    Assert-TextMatches (Join-Path $repoRoot 'ClipmanMac\Sources\Clipman\TemplateResolver.swift') 'variableReferenceText' 'Mac template variable reference exists'
    Assert-TextMatches (Join-Path $repoRoot 'ClipmanMac\Sources\Clipman\HistoryWindowController.swift') 'Preview template' 'Mac Entry Properties exposes template preview'
    Assert-TextMatches (Join-Path $repoRoot 'ClipmanMac\Sources\Clipman\HistoryWindowController.swift') 'Template variables' 'Mac Entry Properties exposes template variable reference'
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
    Assert-TextMatches (Join-Path $repoRoot 'src\ClipmanApplicationContext.cs') 'Clipman database not found' 'Missing explicit database prompt'
    Assert-TextDoesNotMatch (Join-Path $repoRoot 'src\HistoryForm.cs') 'optionsMenuItem\.ShowDropDown\(\)' 'Standard Options menu mnemonic handling'
    Assert-TextMatches (Join-Path $repoRoot 'src\ClipmanApplicationContext.cs') 'DescribeDropEffect\(int value\)' 'Drop effect display helper'
    Assert-TextMatches (Join-Path $repoRoot 'src\ClipmanApplicationContext.cs') 'string\.Join\(" or ", parts\)' 'Combined drop effect wording'
    Assert-TextMatches (Join-Path $repoRoot 'src\AssemblyInfo.cs') 'AssemblyCompany\("Andre Louis"\)' 'Executable company metadata'
    Assert-TextMatches (Join-Path $repoRoot 'src\AssemblyInfo.cs') 'Copyright \(c\) Andre Louis' 'Executable copyright metadata'
    Assert-TextMatches (Join-Path $repoRoot 'src\HistoryForm.cs') 'Build stamp: ' 'About build stamp'
    Assert-TextMatches (Join-Path $repoRoot 'src\HistoryForm.cs') 'Based on earlier Clipman work by Tyler Spivey' 'About credits'
    Assert-TextMatches (Join-Path $repoRoot 'GITHUB-RELEASE-RULES.md') 'sqlite3\.dll' 'GitHub release rules SQLite runtime packaging'
    Assert-TextMatches (Join-Path $repoRoot 'GITHUB-RELEASE-RULES.md') 'LICENSE\.txt' 'GitHub release rules license packaging'
    Assert-TextMatches (Join-Path $repoRoot 'GITHUB-RELEASE-RULES.md') 'ClipmanMac/dist/ClipmanMac-<version>\.zip' 'GitHub release rules Mac release ZIP packaging'
    Assert-TextMatches (Join-Path $repoRoot 'GITHUB-RELEASE-RULES.md') '-RequireMacReleaseAsset' 'GitHub release rules require Mac release asset smoke gate'
    Assert-TextMatches (Join-Path $repoRoot 'GITHUB-RELEASE-RULES.md') 'CFBundleShortVersionString.*AssemblyInformationalVersion' 'GitHub release rules Mac version parity'
    Assert-TextMatches (Join-Path $repoRoot 'CLIPMAN_AGENT_SYNC.md') 'shared-version\.sh' 'Agent sync Mac version workflow'
    Assert-TextMatches (Join-Path $repoRoot 'CLIPMAN_AGENT_SYNC.md') 'Windows remains the source of truth' 'Agent sync Windows release source of truth'
    Assert-TextMatches (Join-Path $repoRoot 'ClipmanMac\Scripts\shared-version.sh') 'AssemblyInformationalVersion' 'Mac shared version script reads Windows informational version'
    Assert-TextMatches (Join-Path $repoRoot 'ClipmanMac\Scripts\shared-version.sh') 'AssemblyFileVersion' 'Mac shared version script reads Windows file version'
    Assert-TextMatches (Join-Path $repoRoot 'ClipmanMac\Scripts\package-release.sh') 'zsh "\$ROOT/Scripts/shared-version\.sh" version' 'Mac release package reads shared short version'
    Assert-TextMatches (Join-Path $repoRoot 'ClipmanMac\Scripts\package-release.sh') 'zsh "\$ROOT/Scripts/shared-version\.sh" build' 'Mac release package reads shared build version'
    Assert-TextMatches (Join-Path $repoRoot 'ClipmanMac\Scripts\package-release.sh') 'cp "\$ROOT/\.\./LICENSE\.txt" "\$APP/Contents/Resources/LICENSE\.txt"' 'Mac release package bundles root license'
    Assert-TextDoesNotMatch (Join-Path $repoRoot 'ClipmanMac\Scripts\package-release.sh') '<string>0\.1</string>|<string>1</string>' 'Mac release package must not hard-code bundle version'
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
        '\bolder installs\b|\bolder versions\b|migration|migrate automatically|temporary workaround|Drop' + 'box'
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

        var youtubeShare = UrlTrackingCleaner.CleanForSharing("https://www.youtube.com/watch?v=A4jvHpegXHk&t=4s&pp=ygUVQXJlIHRoZSBmdW5kcyBnbGFyZGVk");
        Assert(youtubeShare == "https://www.youtube.com/watch?v=A4jvHpegXHk", "Share cleaner did not remove YouTube timestamp and share metadata.");

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

        var sessionOnlySettings = new AppSettings
        {
            DatabasePath = explicitDb,
            UseDefaultDatabasePath = false,
            DatabaseEncryptionEnabled = true,
            RememberDatabasePassword = false,
            ProtectedDatabasePassword = "should-not-survive",
            PlainDatabasePassword = "session-only-secret"
        };
        JsonUtil.SaveAtomic(reloadedExplicitStore.SettingsPath, sessionOnlySettings);
        var sessionOnlyJson = File.ReadAllText(reloadedExplicitStore.SettingsPath, Encoding.UTF8);
        Assert(!sessionOnlyJson.Contains("PlainDatabasePassword"), "Session-only database password was serialized to settings.");
        var normalizedSessionOnly = reloadedExplicitStore.Load();
        Assert(normalizedSessionOnly.DatabaseEncryptionEnabled, "Session-only encrypted settings did not keep encryption enabled.");
        Assert(!normalizedSessionOnly.RememberDatabasePassword, "Session-only encrypted settings incorrectly enabled password remembering.");
        Assert(string.IsNullOrEmpty(normalizedSessionOnly.ProtectedDatabasePassword), "Session-only encrypted settings kept a protected password.");

        var legacyJson = "{\"DatabasePath\":\"" + EscapeJson(explicitDb) + "\",\"UseDefaultDatabasePath\":false,\"DatabaseEncryptionEnabled\":true,\"ProtectedDatabasePassword\":\"legacy-protected-placeholder\"}";
        File.WriteAllText(reloadedExplicitStore.SettingsPath, legacyJson, Encoding.UTF8);
        var legacyLoaded = reloadedExplicitStore.Load();
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
            (Join-Path $repoRoot 'src\JsonUtil.cs'),
            (Join-Path $repoRoot 'src\ClipDatabaseFile.cs'),
            (Join-Path $repoRoot 'src\FileClipboardEventStore.cs'),
            (Join-Path $repoRoot 'src\UrlTrackingCleaner.cs'),
            (Join-Path $repoRoot 'src\SqliteClipboardImporter.cs'),
            (Join-Path $repoRoot 'src\SyncConflictResolver.cs'),
            (Join-Path $repoRoot 'src\SharedUpdateState.cs'),
            (Join-Path $repoRoot 'src\SettingsStore.cs'),
            (Join-Path $repoRoot 'src\DatabasePasswordProtector.cs'),
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
Assert-GitHubActivityChecked $Version
Write-CommunityMentionReminder
Assert-HandoverParity $Version
Assert-MacReleaseAsset $Version
Assert-CodeBehavior
Assert-CleanPortable $portable
Invoke-LocalUpdaterSmoke $Version
Invoke-PostPublishUpdateSmoke $Version
Deploy-LiveCopy $LivePath
Assert-LiveCopyReasonable $LivePath

Write-Host 'Clipman smoke test passed.'
