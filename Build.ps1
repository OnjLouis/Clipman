param(
    [string]$OutputPath = "$PSScriptRoot\portable\clipman.exe",
    [string]$LivePath = '',
    [switch]$NoLiveDeploy,
    [switch]$DesktopOnly
)

$ErrorActionPreference = 'Stop'

$csc = Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
if (-not (Test-Path -LiteralPath $csc)) {
    throw "Could not find the .NET Framework C# compiler at $csc"
}

$portable = Split-Path -Parent ([IO.Path]::GetFullPath($OutputPath))
New-Item -ItemType Directory -Force -Path $portable | Out-Null

function Get-ClipmanVersion {
    $assemblyInfo = Join-Path $PSScriptRoot 'src\AssemblyInfo.cs'
    $text = Get-Content -LiteralPath $assemblyInfo -Raw
    $match = [regex]::Match($text, 'AssemblyInformationalVersion\("(?<version>[^"]+)"\)')
    if (-not $match.Success) {
        throw "Could not find AssemblyInformationalVersion in $assemblyInfo"
    }

    return $match.Groups['version'].Value
}

function Assert-VersionCanBuild {
    $version = Get-ClipmanVersion
    $tag = "v$version"
    $git = Get-Command git -ErrorAction SilentlyContinue
    if ($null -eq $git) {
        return
    }

    $insideWorkTree = & git -C $PSScriptRoot rev-parse --is-inside-work-tree 2>$null
    if ($LASTEXITCODE -ne 0 -or $insideWorkTree -ne 'true') {
        return
    }

    $status = & git -C $PSScriptRoot status --porcelain --untracked-files=all
    if ([string]::IsNullOrWhiteSpace(($status -join ''))) {
        return
    }

    $releasedTag = & git -C $PSScriptRoot tag --list $tag
    if (-not [string]::IsNullOrWhiteSpace(($releasedTag -join ''))) {
        throw "Version $version has already been released as tag $tag, but this working tree has new changes. Bump AssemblyInformationalVersion, AssemblyVersion, and AssemblyFileVersion before building. If the next version is unclear, ask Andre what it should be and tell him the current version is $version."
    }
}

function Assert-PortableShape {
    $forbiddenFiles = @(
        'README.md',
        'clipman-history.clipdb',
        'clipman-history.json',
        'clipman-settings.json'
    )
    foreach ($fileName in $forbiddenFiles) {
        $path = Join-Path $portable $fileName
        if (Test-Path -LiteralPath $path) {
            throw "Stale portable file found: $path"
        }
    }

    foreach ($folderName in @('Settings', 'Logs', 'Reports', 'Backups')) {
        $path = Join-Path $portable $folderName
        if (Test-Path -LiteralPath $path) {
            throw "User/runtime folder found in clean portable output: $path"
        }
    }

    foreach ($nested in @('sounds\sounds', 'Settings\Settings')) {
        $path = Join-Path $portable $nested
        if (Test-Path -LiteralPath $path) {
            throw "Nested duplicate folder found in portable output: $path"
        }
    }
}

function Stop-LiveClipman([string]$path) {
    $liveExe = Join-Path $path 'clipman.exe'
    if (-not (Test-Path -LiteralPath $liveExe)) {
        return
    }

    try {
        & $liveExe --close | Out-Null
    } catch {
        Write-Host "Could not ask live Clipman to close before deployment: $($_.Exception.Message)"
    }

    $deadline = [DateTime]::UtcNow.AddSeconds(5)
    while ([DateTime]::UtcNow -lt $deadline) {
        $running = @(Get-Process clipman -ErrorAction SilentlyContinue | Where-Object { $_.Path -eq $liveExe })
        if ($running.Count -eq 0) {
            return
        }
        Start-Sleep -Milliseconds 150
    }

    foreach ($process in @(Get-Process clipman -ErrorAction SilentlyContinue | Where-Object { $_.Path -eq $liveExe })) {
        Stop-Process -Id $process.Id -Force
    }
}

function Find-LiveClipmanPath {
    if (![string]::IsNullOrWhiteSpace($LivePath)) {
        return $LivePath
    }

    if (![string]::IsNullOrWhiteSpace($env:CLIPMAN_LIVE_PATH)) {
        return $env:CLIPMAN_LIVE_PATH
    }

    $sourceRoot = [IO.Path]::GetFullPath($PSScriptRoot).TrimEnd('\')
    foreach ($process in @(Get-Process clipman -ErrorAction SilentlyContinue)) {
        try {
            if ([string]::IsNullOrWhiteSpace($process.Path)) {
                continue
            }
            $processDirectory = [IO.Path]::GetDirectoryName($process.Path)
            if ([string]::IsNullOrWhiteSpace($processDirectory)) {
                continue
            }
            $processDirectory = [IO.Path]::GetFullPath($processDirectory).TrimEnd('\')
            if ($processDirectory.Equals($sourceRoot, [StringComparison]::OrdinalIgnoreCase)) {
                continue
            }
            if (Test-Path -LiteralPath (Join-Path $processDirectory 'clipman.exe')) {
                return $processDirectory
            }
        }
        catch {
        }
    }

    foreach ($drive in [IO.DriveInfo]::GetDrives()) {
        if (-not $drive.IsReady) {
            continue
        }

        $candidate = Join-Path $drive.RootDirectory.FullName 'Dropbox\SOFTWARE\clipman'
        if (Test-Path -LiteralPath (Join-Path $candidate 'clipman.exe')) {
            return $candidate
        }
    }

    return ''
}

function Deploy-LiveCopy([string]$path) {
    if ([string]::IsNullOrWhiteSpace($path)) {
        Write-Host 'No live path supplied; skipping live deployment.'
        return
    }
    if (-not (Test-Path -LiteralPath $path)) {
        Write-Host "Live path not found; skipping live deployment: $path"
        return
    }

    $resolvedLive = (Resolve-Path -LiteralPath $path).Path
    $sourceDirectory = Split-Path -Parent $OutputPath

    Stop-LiveClipman $resolvedLive

    foreach ($fileName in @('clipman.exe', 'Manual.html', 'LICENSE.txt', 'sqlite3.dll')) {
        $source = Join-Path $sourceDirectory $fileName
        if (Test-Path -LiteralPath $source) {
            Copy-Item -LiteralPath $source -Destination (Join-Path $resolvedLive $fileName) -Force
        }
    }

    Remove-Item -LiteralPath (Join-Path $resolvedLive 'ClipmanServer.exe') -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath (Join-Path $resolvedLive 'ClipmanServerLinux') -Recurse -Force -ErrorAction SilentlyContinue

    Start-Sleep -Milliseconds 250
    $liveExe = Join-Path $resolvedLive 'clipman.exe'
    if (Test-Path -LiteralPath $liveExe) {
        Start-Process -FilePath $liveExe -WorkingDirectory $resolvedLive -WindowStyle Hidden | Out-Null
    }

    Write-Host "Deployed live copy to $resolvedLive"
}

function Get-RemoteWindowsTargets {
    $value = $env:CLIPMAN_REMOTE_WINDOWS_TARGETS
    if ([string]::IsNullOrWhiteSpace($value)) {
        return @()
    }

    $targets = New-Object System.Collections.Generic.List[object]
    foreach ($entry in $value -split ';') {
        if ([string]::IsNullOrWhiteSpace($entry)) {
            continue
        }

        $separator = $entry.IndexOf('=')
        if ($separator -le 0 -or $separator -ge ($entry.Length - 1)) {
            throw "Invalid CLIPMAN_REMOTE_WINDOWS_TARGETS entry '$entry'. Use ComputerName=FullRemotePath;OtherComputer=FullRemotePath."
        }

        $targets.Add([pscustomobject]@{
            ComputerName = $entry.Substring(0, $separator).Trim()
            Path = $entry.Substring($separator + 1).Trim()
        }) | Out-Null
    }

    return $targets.ToArray()
}

function Stop-RemoteClipman([System.Management.Automation.Runspaces.PSSession]$session, [string]$path) {
    Invoke-Command -Session $session -ScriptBlock {
        param($targetPath)
        $liveExe = Join-Path $targetPath 'clipman.exe'
        if (Test-Path -LiteralPath $liveExe) {
            try { & $liveExe --close | Out-Null } catch { }
        }

        $deadline = [DateTime]::UtcNow.AddSeconds(5)
        while ([DateTime]::UtcNow -lt $deadline) {
            $running = @(Get-Process clipman -ErrorAction SilentlyContinue | Where-Object {
                try { $_.Path -eq $liveExe } catch { $false }
            })
            if ($running.Count -eq 0) {
                return
            }
            Start-Sleep -Milliseconds 150
        }

        foreach ($process in @(Get-Process clipman -ErrorAction SilentlyContinue | Where-Object {
            try { $_.Path -eq $liveExe } catch { $false }
        })) {
            Stop-Process -Id $process.Id -Force
        }
    } -ArgumentList $path
}

function Deploy-RemoteWindowsCopy([string]$computerName, [string]$path) {
    if ([string]::IsNullOrWhiteSpace($computerName) -or [string]::IsNullOrWhiteSpace($path)) {
        return
    }

    $sourceDirectory = Split-Path -Parent $OutputPath
    $session = $null
    try {
        $session = New-PSSession -ComputerName $computerName
        Invoke-Command -Session $session -ScriptBlock {
            param($targetPath)
            New-Item -ItemType Directory -Force -Path $targetPath | Out-Null
        } -ArgumentList $path

        Stop-RemoteClipman $session $path

        foreach ($fileName in @('clipman.exe', 'Manual.html', 'LICENSE.txt', 'sqlite3.dll')) {
            $source = Join-Path $sourceDirectory $fileName
            if (Test-Path -LiteralPath $source) {
                Copy-Item -LiteralPath $source -Destination (Join-Path $path $fileName) -ToSession $session -Force
            }
        }

        $soundSource = Join-Path $sourceDirectory 'sounds'
        if (Test-Path -LiteralPath $soundSource) {
            Invoke-Command -Session $session -ScriptBlock {
                param($targetPath)
                $soundTarget = Join-Path $targetPath 'sounds'
                if (Test-Path -LiteralPath $soundTarget) {
                    Get-ChildItem -LiteralPath $soundTarget -Force | Remove-Item -Recurse -Force
                } else {
                    New-Item -ItemType Directory -Force -Path $soundTarget | Out-Null
                }
            } -ArgumentList $path
            Copy-Item -LiteralPath (Get-ChildItem -LiteralPath $soundSource -File).FullName -Destination (Join-Path $path 'sounds') -ToSession $session -Force
        }

        Invoke-Command -Session $session -ScriptBlock {
            param($targetPath)
            Remove-Item -LiteralPath (Join-Path $targetPath 'ClipmanServer.exe') -Force -ErrorAction SilentlyContinue
            Remove-Item -LiteralPath (Join-Path $targetPath 'ClipmanServerLinux') -Recurse -Force -ErrorAction SilentlyContinue
            Remove-Item -LiteralPath (Join-Path $targetPath 'README.md') -Force -ErrorAction SilentlyContinue
        } -ArgumentList $path

        Write-Host "Deployed remote Windows copy to ${computerName}:$path. Remote tray app launch is skipped because WinRM cannot reliably start an interactive notification-area process; the registered startup entry will run it at login."
    }
    finally {
        if ($session -ne $null) {
            Remove-PSSession $session
        }
    }
}

function Deploy-RemoteWindowsCopies {
    foreach ($target in Get-RemoteWindowsTargets) {
        Deploy-RemoteWindowsCopy $target.ComputerName $target.Path
    }
}

Assert-VersionCanBuild

$manifest = Join-Path $PSScriptRoot 'src\clipman.exe.manifest'
$references = @(
    'System.dll',
    'System.Core.dll',
    'System.Drawing.dll',
    'System.IO.Compression.dll',
    'System.IO.Compression.FileSystem.dll',
    'System.Security.dll',
    'System.Windows.Forms.dll',
    'System.Web.Extensions.dll'
) -join ','

$buildInfoPath = Join-Path $PSScriptRoot 'src\BuildInfo.cs'
$buildStamp = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
@(
    'namespace Clipman',
    '{',
    '    internal static class BuildInfo',
    '    {',
    "        public const long BuildStampUtcMs = ${buildStamp}L;",
    '    }',
    '}'
) -join [Environment]::NewLine | Set-Content -LiteralPath $buildInfoPath -Encoding UTF8

$iOSInfoPath = Join-Path $PSScriptRoot 'ClipmanIOS\ClipmanIOS\Support\Info.plist'
if (!$DesktopOnly) {
    $iOSInfoText = [IO.File]::ReadAllText($iOSInfoPath)
    $iOSBuildPattern = '(<key>ClipmanBuildStampUtcMs</key>\s*<string>)\d+(</string>)'
    $iOSBuildMatches = [regex]::Matches($iOSInfoText, $iOSBuildPattern)
    if ($iOSBuildMatches.Count -ne 1) {
        throw "Expected one iOS ClipmanBuildStampUtcMs value; found $($iOSBuildMatches.Count)."
    }
    $iOSInfoText = [regex]::Replace(
        $iOSInfoText,
        $iOSBuildPattern,
        { param($match) $match.Groups[1].Value + [string]$buildStamp + $match.Groups[2].Value }
    )
    [IO.File]::WriteAllText($iOSInfoPath, $iOSInfoText, [Text.UTF8Encoding]::new($false))
}
try {
    $validatedIOSInfo = [Xml.XmlDocument]::new()
    $validatedIOSInfo.Load($iOSInfoPath)
}
catch {
    throw "The updated iOS Info.plist is invalid: $($_.Exception.Message)"
}

$sources = Get-ChildItem -LiteralPath (Join-Path $PSScriptRoot 'src') -Filter '*.cs' | Sort-Object Name | ForEach-Object { $_.FullName }

& $csc /nologo /target:winexe /platform:x64 /win32manifest:$manifest /out:$OutputPath /reference:$references $sources
if ($LASTEXITCODE -ne 0) {
    throw "Build failed with exit code $LASTEXITCODE"
}

$soundSource = Join-Path $PSScriptRoot 'Assets\sounds'
if (Test-Path -LiteralPath $soundSource) {
    $outputDirectory = Split-Path -Parent $OutputPath
    $soundTarget = Join-Path $outputDirectory 'sounds'
    if (Test-Path -LiteralPath $soundTarget) {
        Get-ChildItem -LiteralPath $soundTarget -Force | Remove-Item -Recurse -Force
    } else {
        New-Item -ItemType Directory -Force -Path $soundTarget | Out-Null
    }
    Copy-Item -LiteralPath (Get-ChildItem -LiteralPath $soundSource -File).FullName -Destination $soundTarget -Force
}

$sqliteSource = Join-Path $PSScriptRoot 'Assets\sqlite\sqlite3.dll'
if (Test-Path -LiteralPath $sqliteSource) {
    Copy-Item -LiteralPath $sqliteSource -Destination (Join-Path (Split-Path -Parent $OutputPath) 'sqlite3.dll') -Force
}

foreach ($doc in @('Manual.html', 'LICENSE.txt')) {
    $source = Join-Path $PSScriptRoot $doc
    if (Test-Path -LiteralPath $source) {
        Copy-Item -LiteralPath $source -Destination (Join-Path $portable $doc) -Force
    }
}

Remove-Item -LiteralPath (Join-Path $portable 'README.md') -Force -ErrorAction SilentlyContinue
Remove-Item -LiteralPath (Join-Path $portable 'clipman-history.clipdb') -Force -ErrorAction SilentlyContinue
Remove-Item -LiteralPath (Join-Path $portable 'clipman-history.json') -Force -ErrorAction SilentlyContinue
Remove-Item -LiteralPath (Join-Path $portable 'clipman-settings.json') -Force -ErrorAction SilentlyContinue
Remove-Item -LiteralPath (Join-Path $portable 'ClipmanServer.exe') -Force -ErrorAction SilentlyContinue
foreach ($folderName in @('Settings', 'Logs', 'Reports', 'Backups')) {
    Remove-Item -LiteralPath (Join-Path $portable $folderName) -Recurse -Force -ErrorAction SilentlyContinue
}
Remove-Item -LiteralPath (Join-Path $portable 'ClipmanServerLinux') -Recurse -Force -ErrorAction SilentlyContinue

Assert-PortableShape

if (-not $NoLiveDeploy) {
    Deploy-LiveCopy (Find-LiveClipmanPath)
    Deploy-RemoteWindowsCopies
}

Write-Host "Built $OutputPath"
