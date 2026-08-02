param(
    [string]$OutputDirectory = $(if ([string]::IsNullOrWhiteSpace($env:CLIPMAN_SERVER_PACKAGE_DIR)) { Join-Path ([IO.Path]::GetTempPath()) 'Clipman-server-package' } else { $env:CLIPMAN_SERVER_PACKAGE_DIR }),
    [string]$MacHost = $(if ([string]::IsNullOrWhiteSpace($env:CLIPMAN_MAC_HOST)) { 'mac' } else { $env:CLIPMAN_MAC_HOST }),
    [string]$MacRepo = $(if ([string]::IsNullOrWhiteSpace($env:CLIPMAN_MAC_REPO)) { '$HOME/clipman' } else { $env:CLIPMAN_MAC_REPO })
)

$ErrorActionPreference = 'Stop'
$OutputDirectory = [IO.Path]::GetFullPath($OutputDirectory)
$repoFullPath = [IO.Path]::GetFullPath($PSScriptRoot).TrimEnd('\')
if ($OutputDirectory.TrimEnd('\').StartsWith($repoFullPath + '\', [StringComparison]::OrdinalIgnoreCase)) {
    throw "OutputDirectory must be outside the source repository: $OutputDirectory"
}

function Get-ClipmanVersion {
    $versionFile = Join-Path $PSScriptRoot 'ClipmanServer\version.txt'
    $version = (Get-Content -LiteralPath $versionFile -Raw).Trim()
    if ($version -notmatch '^\d+\.\d+\.\d+$') {
        throw "Clipman Server version is invalid in $versionFile"
    }
    return $version
}

function Build-WindowsServerWrapper([string]$outputPath) {
    $csc = Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
    if (-not (Test-Path -LiteralPath $csc)) {
        throw "Could not find the .NET Framework C# compiler at $csc"
    }

    $version = Get-ClipmanVersion
    $assemblyVersion = if ($version -match '^\d+\.\d+\.\d+$') { "$version.0" } else { $version }
    $generatedDirectory = Split-Path -Parent $outputPath
    $generatedAssemblyInfo = Join-Path $generatedDirectory 'GeneratedAssemblyInfo.cs'
    New-Item -ItemType Directory -Force -Path $generatedDirectory | Out-Null
    @(
        'using System.Reflection;',
        'using System.Runtime.InteropServices;',
        '',
        '[assembly: AssemblyTitle("Clipman Server")]',
        '[assembly: AssemblyDescription("Background server wrapper for Clipman")]',
        '[assembly: AssemblyCompany("Andre Louis")]',
        '[assembly: AssemblyProduct("Clipman Server")]',
        '[assembly: AssemblyCopyright("Copyright (c) Andre Louis")]',
        '[assembly: ComVisible(false)]',
        "[assembly: AssemblyVersion(`"$assemblyVersion`")]",
        "[assembly: AssemblyFileVersion(`"$assemblyVersion`")]",
        "[assembly: AssemblyInformationalVersion(`"$version`")]"
    ) -join [Environment]::NewLine | Set-Content -LiteralPath $generatedAssemblyInfo -Encoding UTF8

    $sources = @(Get-ChildItem -LiteralPath (Join-Path $PSScriptRoot 'ClipmanServerWindows') -Filter '*.cs' | Sort-Object Name | ForEach-Object { $_.FullName })
    $sources += $generatedAssemblyInfo
    if ($sources.Count -eq 0) {
        throw 'Windows Clipman Server wrapper source is missing.'
    }

    $references = @(
        'System.dll',
        'System.Core.dll',
        'System.Drawing.dll',
        'System.IO.Compression.FileSystem.dll',
        'System.Windows.Forms.dll',
        'System.Web.Extensions.dll'
    ) -join ','

    $serverScript = Join-Path $PSScriptRoot 'ClipmanServerLinux\clipman_server.py'
    if (-not (Test-Path -LiteralPath $serverScript)) {
        throw "Shared Python server script is missing: $serverScript"
    }

    & $csc /nologo /target:winexe /platform:x64 /out:$outputPath /reference:$references "/resource:$serverScript,ClipmanServerWrapper.clipman_server.py" $sources
    if ($LASTEXITCODE -ne 0) {
        throw "Windows Clipman Server wrapper build failed with exit code $LASTEXITCODE"
    }

    # Use a child process so loading the EXE for verification does not lock build scratch.
    $verificationScript = Join-Path $generatedDirectory 'VerifyServerUpdater.ps1'
    @'
param([string]$AssemblyPath, [string]$Version)
$ErrorActionPreference = 'Stop'
$assembly = [Reflection.Assembly]::LoadFile($AssemblyPath)
$updateType = $assembly.GetType('ClipmanServerWrapper.ServerUpdateService', $true)
$versionText = $updateType.GetMethod('VersionText', [Reflection.BindingFlags]'NonPublic,Static')
if ($null -eq $versionText) {
    throw 'Windows Clipman Server updater tag validator was not found in the built executable.'
}
if ([string]$versionText.Invoke($null, @("v$Version")) -ne '') {
    throw 'Windows Clipman Server updater incorrectly accepted a Clipman client release tag.'
}
if ([string]$versionText.Invoke($null, @("server-v$Version")) -ne $Version) {
    throw 'Windows Clipman Server updater rejected its versioned server release tag.'
}
'@ | Set-Content -LiteralPath $verificationScript -Encoding UTF8
    & powershell -NoProfile -ExecutionPolicy Bypass -File $verificationScript -AssemblyPath $outputPath -Version $version
    if ($LASTEXITCODE -ne 0) {
        throw "Windows Clipman Server updater verification failed with exit code $LASTEXITCODE"
    }
}

$version = Get-ClipmanVersion
$zipPath = Join-Path $OutputDirectory "ClipmanServer-$version.zip"
$localBuildDirectory = Join-Path ([IO.Path]::GetTempPath()) ('Clipman-server-build-' + [guid]::NewGuid().ToString('N'))
$windowsWrapperDist = Join-Path $localBuildDirectory 'Clipman Server.exe'
$remoteTempWindowsExe = "/tmp/clipman-server-wrapper-$version-$([guid]::NewGuid().ToString('N')).exe"
$remoteMacDist = "/tmp/clipman-server-mac-$version-$([guid]::NewGuid().ToString('N'))"
$remoteCombinedDist = "/tmp/clipman-server-combined-$version-$([guid]::NewGuid().ToString('N'))"
$remoteTempZip = "/tmp/ClipmanServer-$version-$([guid]::NewGuid().ToString('N')).zip"

New-Item -ItemType Directory -Force -Path $OutputDirectory | Out-Null

try {
    New-Item -ItemType Directory -Force -Path $localBuildDirectory | Out-Null
    Build-WindowsServerWrapper $windowsWrapperDist

    Remove-Item -LiteralPath $zipPath -Force -ErrorAction SilentlyContinue

    & ssh $MacHost "/bin/rm -rf '$remoteMacDist' '$remoteCombinedDist'; /bin/mkdir -p '$remoteMacDist' '$remoteCombinedDist'"
    if ($LASTEXITCODE -ne 0) {
        throw "Could not prepare Mac server bundle folders on $MacHost."
    }

    & scp $windowsWrapperDist "${MacHost}:$remoteTempWindowsExe"
    if ($LASTEXITCODE -ne 0) {
        throw "Could not copy Windows server wrapper to $MacHost."
    }

    & ssh $MacHost "cd `"$MacRepo`" && CLIPMAN_SERVER_MAC_DIST_DIR='$remoteMacDist' zsh ClipmanServerMac/Scripts/package-release.sh && CLIPMAN_SERVER_WINDOWS_EXE='$remoteTempWindowsExe' CLIPMAN_SERVER_MAC_APP='$remoteMacDist/Clipman Server.app' CLIPMAN_SERVER_COMBINED_OUTPUT_DIR='$remoteCombinedDist' zsh ClipmanServerMac/Scripts/package-combined-server.sh && cp '$remoteCombinedDist/ClipmanServer-$version.zip' '$remoteTempZip'"
    if ($LASTEXITCODE -ne 0) {
        throw "Mac-side Clipman Server bundle build failed on $MacHost."
    }

    & scp "${MacHost}:$remoteTempZip" $zipPath
    if ($LASTEXITCODE -ne 0) {
        throw "Could not copy Mac-built server bundle from $MacHost."
    }

    if (-not (Test-Path -LiteralPath $zipPath)) {
        throw "Server bundle ZIP was not created: $zipPath"
    }

    if (![string]::IsNullOrWhiteSpace($env:CLIPMAN_SERVER_BUILDS)) {
        New-Item -ItemType Directory -Force -Path $env:CLIPMAN_SERVER_BUILDS | Out-Null
        Copy-Item -LiteralPath $zipPath -Destination (Join-Path $env:CLIPMAN_SERVER_BUILDS (Split-Path -Leaf $zipPath)) -Force
    }

    Write-Host "Built $zipPath"
}
finally {
    for ($attempt = 1; $attempt -le 10 -and (Test-Path -LiteralPath $localBuildDirectory); $attempt++) {
        try {
            Remove-Item -LiteralPath $localBuildDirectory -Recurse -Force -ErrorAction Stop
        }
        catch {
            if ($attempt -eq 10) {
                throw "Could not clean local Clipman Server build scratch: $localBuildDirectory"
            }
            Start-Sleep -Milliseconds 300
        }
    }
    & ssh $MacHost "/bin/rm -rf '$remoteTempZip' '$remoteTempWindowsExe' '$remoteMacDist' '$remoteCombinedDist'" 2>$null
    if ($LASTEXITCODE -ne 0) {
        Write-Warning "Could not remove one or more remote Clipman Server scratch paths from $MacHost."
    }
    $LASTEXITCODE = 0
}
