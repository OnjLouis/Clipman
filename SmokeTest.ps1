param(
    [string]$LivePath = '',
    [switch]$SkipBuild,
    [switch]$RunPostPublishUpdateSmoke,
    [string]$Version = '',
    [int[]]$ReviewedOpenIssue = @(),
    [switch]$SkipGitHubActivityCheck
)

$ErrorActionPreference = 'Stop'
$repoRoot = $PSScriptRoot
$portable = Join-Path $repoRoot 'portable'
$programBuilds = 'D:\Dropbox\backups\Clipman\Program Builds'

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

function Get-GitHubHeaders {
    $token = $env:GH_TOKEN
    if ([string]::IsNullOrWhiteSpace($token)) {
        $token = $env:GITHUB_TOKEN
    }
    if ([string]::IsNullOrWhiteSpace($token)) {
        foreach ($candidate in @(
            (Join-Path $repoRoot 'token.txt'),
            'D:\Dropbox\backups\Codex\current\token.txt'
        )) {
            if (Test-Path -LiteralPath $candidate) {
                $token = (Get-Content -LiteralPath $candidate -Raw).Trim()
                if (![string]::IsNullOrWhiteSpace($token)) {
                    break
                }
            }
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
    Assert-TextMatches $manual '<h3>1\.5\.1</h3>' 'Manual 1.5.1 changelog'
    Assert-TextMatches $manual 'Bundled factory sounds are now replaced cleanly' 'Manual factory sounds update cleanup changelog'
    Assert-TextMatches $manual 'Closes <a href="https://github\.com/OnjLouis/Clipman/issues/1">issue #1</a>' 'Manual issue #1 closure'
    Assert-TextMatches $manual 'See <a href="https://github\.com/OnjLouis/Clipman/issues/2">issue #2</a>' 'Manual issue #2 review note'
    Assert-TextMatches $manual 'Closes <a href="https://github\.com/OnjLouis/Clipman/issues/3">issue #3</a>' 'Manual issue #3 closure'
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
    Assert-TextMatches $readme 'Bundled sounds in the root `sounds` folder are factory files' 'README factory sound update behavior'
    Assert-TextMatches $readme 'start a copy from a different folder' 'README different folder takeover behavior'
    Assert-TextMatches $readme 'Multiple machines can write to the same history database' 'README shared history explanation'
    Assert-TextMatches $readme 'Optional history password encryption' 'README encryption documentation'
    Assert-TextMatches $readme 'deliberately ignores that generated password copy' 'README generated password documentation'
    Assert-TextMatches $readme 'old Clipman `clipman\.db` and Ditto SQLite databases' 'README SQLite import documentation'
    Assert-TextMatches $readme 'Press Backspace in the history list' 'README Backspace normal-entry shortcut'
    Assert-TextMatches $readme 'Help` > `Contact`' 'README contact documentation'
    Assert-TextMatches $readme 'Help` > `Donate`' 'README donate documentation'
    Assert-TextMatches (Join-Path $repoRoot 'src\Program.Updater.cs') 'PublishCloseRequest' 'Updater shared close request code'
    Assert-TextMatches (Join-Path $repoRoot 'src\Program.Updater.cs') 'TryRestartUpdatedApp' 'Updater restart code'
    Assert-TextMatches (Join-Path $repoRoot 'src\Program.Updater.cs') 'ReplaceFactoryDirectory' 'Updater factory folder replacement code'
    Assert-TextMatches (Join-Path $repoRoot 'src\Program.Updater.cs') 'CleanupObsoleteFactorySoundBackups' 'Updater factory sound backup cleanup code'
    Assert-TextMatches (Join-Path $repoRoot 'src\Program.cs') 'InstanceStateStore\.IsSameRunningFolder' 'Cross-folder instance takeover code'
    Assert-TextMatches (Join-Path $repoRoot 'src\ClipmanApplicationContext.cs') 'ClipDatabaseFile\.IsEncryptedFile\(settings\.DatabasePath\)' 'Startup encrypted database detection'
    Assert-TextMatches (Join-Path $repoRoot 'src\ClipmanApplicationContext.cs') 'CopySensitiveTextToClipboard' 'Sensitive clipboard copy suppression'
    Assert-TextMatches (Join-Path $repoRoot 'src\ClipmanApplicationContext.cs') 'LastPreferencesTab' 'Preferences tab persistence application'
    Assert-TextMatches (Join-Path $repoRoot 'src\PreferencesForm.cs') 'SelectPreferencesTabByShortcut' 'Preferences tab shortcut code'
    Assert-TextMatches (Join-Path $repoRoot 'src\Models.cs') 'LastPreferencesTab' 'Preferences tab persistence setting'
    Assert-TextDoesNotMatch (Join-Path $repoRoot 'src\PreferencesForm.cs') 'encryptDatabase|Clipboard\.SetText\(password\)' 'Preferences encryption checkbox and raw password clipboard copy'
    Assert-TextMatches (Join-Path $repoRoot 'src\Program.cs') 'Logs\\\\Startup\.log' 'Startup failure log message'
    Assert-TextMatches (Join-Path $repoRoot 'src\Program.cs') 'WriteStartupLog\("Startup failed\."' 'Startup failure logging'
    Assert-TextMatches (Join-Path $repoRoot 'src\Models.cs') 'UseDefaultDatabasePath' 'Default database path setting'
    Assert-TextMatches (Join-Path $repoRoot 'src\SettingsStore.cs') 'ShouldTreatAsDefaultDatabasePath' 'Portable default database path detection'
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
Assert-GitHubActivityChecked $Version
Assert-CodeBehavior
Assert-CleanPortable $portable
Invoke-LocalUpdaterSmoke $Version
Deploy-LiveCopy $LivePath
Assert-LiveCopyReasonable $LivePath
Invoke-PostPublishUpdateSmoke $Version

Write-Host 'Clipman smoke test passed.'
