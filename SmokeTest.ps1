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

function Write-CommunityMentionReminder {
    Write-Host 'Community mention check: search the web and public community spaces for Clipman mentions before release.'
    Write-Host 'Suggested searches: "Clipman" "OnjLouis", "OnjLouis/Clipman", "Clipman" "Accessible Clipboard Management Tool", "Clipman" "Andre Louis" clipboard, "Clipman" "NVDA", "Clipman" "JAWS", "Clipman" "screen reader", and public podcast/email-list/community sites.'
    Write-Host 'Expect false positives from Linux clipboard managers named clipman. Look for feedback about this Windows project, and for repeated clipboard-manager themes such as setup friction, file clipboard formats, sync, encryption, hotkeys, search, pinning, and screen-reader behavior.'
    Write-Host 'For a repeatable checklist, run: powershell -ExecutionPolicy Bypass -File .\CommunitySearch.ps1'
}

function Assert-HandoverParity([string]$releaseVersion) {
    $handover = 'D:\Dropbox\txt\codex\Clipman.txt'
    if (!(Test-Path -LiteralPath $handover)) {
        Write-Host "Private handover parity check skipped because $handover was not found."
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
    Assert-TextDoesNotMatch $handover 'File history is session-only and held in RAM|Current public release: 1\.5\.1|Current development version: 1\.5\.1|Current development version: 1\.5\.4|Current development version: 1\.5\.5|Current development version: 1\.5\.6' 'Private handover stale facts'
    Assert-TextMatches (Join-Path $repoRoot 'GITHUB-RELEASE-RULES.md') 'Private Handover Parity' 'Release rules handover parity section'
    Assert-TextMatches (Join-Path $repoRoot 'GITHUB-RELEASE-RULES.md') 'D:\\Dropbox\\txt\\codex\\Clipman\.txt' 'Release rules handover path'
}

function Assert-ManualAndReadmeClean {
    $manual = Join-Path $repoRoot 'Manual.html'
    $readme = Join-Path $repoRoot 'README.md'

    Assert-TextMatches $manual '<h2 id="contents">Contents</h2>' 'Manual table of contents'
    Assert-TextMatches $manual 'Project page: <a href="https://github.com/OnjLouis/Clipman">' 'Manual project page link'
    Assert-TextMatches $manual 'Remove URL tracking' 'Manual URL tracking documentation'
    Assert-TextMatches $manual 'machine-specific database named like <code>Settings\\Desktop-file-history\.clipdb</code>' 'Manual persistent file-history documentation'
    Assert-TextMatches $manual 'Press <code>Del</code> to remove selected unpinned file-history events' 'Manual file-history delete shortcut'
    Assert-TextMatches $manual 'remove unavailable events' 'Manual unavailable event cleanup documentation'
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
    Assert-TextMatches $manual 'Ctrl\+1</code> to <code>Ctrl\+5' 'Manual preferences tab shortcut documentation'
    Assert-TextMatches $manual 'File history preferences' 'Manual File history preferences documentation'
    Assert-TextMatches $manual 'diagnostics event limit' 'Manual diagnostics event limit documentation'
    Assert-TextMatches $manual 'Ctrl\+I' 'Manual import shortcut documentation'
    Assert-TextMatches $manual 'Ctrl\+E' 'Manual export shortcut documentation'
    Assert-TextMatches $manual 'Sort Text history entries from the Sort by submenu' 'Manual sort submenu documentation'
    Assert-TextMatches $manual 'Close history or Preferences window' 'Manual Esc close shortcut documentation'
    Assert-TextMatches $manual 'Ctrl\+Del' 'Manual file-history clear shortcut documentation'
    Assert-TextMatches $manual 'Alt\+Del' 'Manual file-history remove-missing shortcut documentation'
    Assert-TextMatches $manual 'Use no password button clears the saved history password' 'Manual no-password button documentation'
    Assert-TextMatches $manual 'History password' 'Manual encryption documentation'
    Assert-TextMatches $manual 'ascending and descending' 'Manual sort direction documentation'
    Assert-TextMatches $manual '<h3>1\.5\.8</h3>' 'Manual 1.5.8 changelog'
    Assert-TextMatches $manual 'File history parity with Text history' 'Manual 1.5.8 file-history parity changelog'
    Assert-TextMatches $manual 'file and folder names now come first in each row' 'Manual 1.5.8 file-history filename-first changelog'
    Assert-TextMatches $manual 'buffered type-to-jump by full filename prefix' 'Manual 1.5.8 file-history buffered navigation changelog'
    Assert-TextMatches $manual 'File history rows start with the file or folder name' 'Manual file-history filename-first documentation'
    Assert-TextMatches $manual 'supports buffered type-to-jump navigation by file name' 'Manual file-history type-to-jump documentation'
    Assert-TextMatches $manual 'Changed File history Go to file from <code>Shift\+Enter</code> to <code>Ctrl\+Enter</code>' 'Manual 1.5.8 go-to-file shortcut changelog'
    Assert-TextMatches $manual 'Save list position no longer pulls focus back to an older saved row' 'Manual 1.5.8 delete-position changelog'
    Assert-TextMatches $manual '<h3>1\.5\.7</h3>' 'Manual 1.5.7 changelog'
    Assert-TextMatches $manual 'reopening Text history now resets the live selection' 'Manual 1.5.7 save-position live-selection changelog'
    Assert-TextMatches $manual '<h3>1\.5\.6</h3>' 'Manual 1.5.6 changelog'
    Assert-TextMatches $manual 'Save list position now updates when the history window is hidden' 'Manual 1.5.6 save position changelog'
    Assert-TextMatches $manual 'Play sounds and Save list position no longer share the same mnemonic' 'Manual 1.5.6 mnemonic changelog'
    Assert-TextMatches $manual '<h3>1\.5\.5</h3>' 'Manual 1.5.5 changelog'
    Assert-TextMatches $manual 'Save list position now only saves and restores list position when enabled' 'Manual 1.5.5 save position changelog'
    Assert-TextMatches $manual 'standard Windows multi-selection' 'Manual file-history multi-selection documentation'
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
    Assert-TextMatches $readme 'Sort direction can be toggled' 'README sort direction documentation'
    Assert-TextMatches $readme 'Settings\\sounds' 'README user sound override documentation'
    Assert-TextMatches $readme 'Bundled sounds in the root `sounds` folder are factory files' 'README factory sound update behavior'
    Assert-TextMatches $readme 'start a copy from a different folder' 'README different folder takeover behavior'
    Assert-TextMatches $readme 'Multiple machines can write to the same history database' 'README shared history explanation'
    Assert-TextMatches $readme 'Optional history password encryption' 'README encryption documentation'
    Assert-TextMatches $readme 'Desktop-file-history\.clipdb' 'README persistent file-history documentation'
    Assert-TextMatches $readme 'remove unavailable unpinned events' 'README unavailable event cleanup documentation'
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
    Assert-TextMatches (Join-Path $repoRoot 'src\HistoryForm.cs') 'Sort de&scending' 'Sort descending menu label'
    Assert-TextMatches (Join-Path $repoRoot 'src\HistoryForm.cs') 'Sort &ascending' 'Sort ascending menu label'
    Assert-TextDoesNotMatch (Join-Path $repoRoot 'src\HistoryForm.cs') 'Switch to de&scending sort' 'Old sort direction wording'
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
    Assert-TextMatches (Join-Path $repoRoot 'src\HistoryForm.cs') 'SaveListPositionIndex\(preferredIndex\)' 'Delete/cut updates saved position before store refresh'
    Assert-TextDoesNotMatch (Join-Path $repoRoot 'src\HistoryForm.cs') 'Go to file\\tShift\+Enter' 'No current file-history Shift+Enter go-to-file shortcut'
    Assert-TextMatches (Join-Path $repoRoot 'src\HistoryForm.cs') 'SelectedFileClipboardEvents' 'File history multi-selection helper'
    Assert-TextMatches (Join-Path $repoRoot 'src\HistoryForm.cs') 'ExistingFileClipboardPaths\(selected\)' 'File history restore uses all selected events'
    Assert-TextDoesNotMatch (Join-Path $repoRoot 'src\HistoryForm.cs') 'fileRange|RangeMarker|RestoreMarked|CopyMarked|marked range|Set range &start|Set range &end' 'No stale file-history marker implementation'
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
Assert-GitHubActivityChecked $Version
Write-CommunityMentionReminder
Assert-HandoverParity $Version
Assert-CodeBehavior
Assert-CleanPortable $portable
Invoke-LocalUpdaterSmoke $Version
Invoke-PostPublishUpdateSmoke $Version
Deploy-LiveCopy $LivePath
Assert-LiveCopyReasonable $LivePath

Write-Host 'Clipman smoke test passed.'
