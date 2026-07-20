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
    $assemblyInfo = Join-Path $PSScriptRoot 'src\AssemblyInfo.cs'
    $text = Get-Content -LiteralPath $assemblyInfo -Raw
    $match = [regex]::Match($text, 'AssemblyInformationalVersion\("(?<version>[^"]+)"\)')
    if (-not $match.Success) {
        throw "Could not find AssemblyInformationalVersion in $assemblyInfo"
    }

    return $match.Groups['version'].Value
}

function Build-WindowsServerWrapper([string]$outputPath) {
    $csc = Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
    if (-not (Test-Path -LiteralPath $csc)) {
        throw "Could not find the .NET Framework C# compiler at $csc"
    }

    $version = Get-ClipmanVersion
    $assemblyVersion = if ($version -match '^\d+\.\d+\.\d+$') { "$version.0" } else { $version }
    $generatedDirectory = Join-Path ([IO.Path]::GetTempPath()) 'Clipman-server-build'
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

    & $csc /nologo /target:winexe /platform:x64 /out:$outputPath /reference:$references /resource:$serverScript,ClipmanServerWrapper.clipman_server.py $sources
    if ($LASTEXITCODE -ne 0) {
        throw "Windows Clipman Server wrapper build failed with exit code $LASTEXITCODE"
    }
}

$version = Get-ClipmanVersion
$zipPath = Join-Path $OutputDirectory "ClipmanServer-$version.zip"

New-Item -ItemType Directory -Force -Path $OutputDirectory | Out-Null

$windowsWrapperDist = Join-Path ([IO.Path]::GetTempPath()) 'Clipman-server-build\Clipman Server.exe'
New-Item -ItemType Directory -Force -Path (Split-Path -Parent $windowsWrapperDist) | Out-Null
Build-WindowsServerWrapper $windowsWrapperDist

Remove-Item -LiteralPath $zipPath -Force -ErrorAction SilentlyContinue

$remoteTempWindowsExe = "/tmp/clipman-server-wrapper-$version.exe"
$remoteMacDist = "/tmp/clipman-server-mac-$version"
$remoteCombinedDist = "/tmp/clipman-server-combined-$version"
$remoteTempZip = "/tmp/ClipmanServer-$version.zip"

& ssh $MacHost "rm -rf '$remoteMacDist' '$remoteCombinedDist'; mkdir -p '$remoteMacDist' '$remoteCombinedDist'"
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

& ssh $MacHost "rm -rf '$remoteTempZip' '$remoteTempWindowsExe' '$remoteMacDist' '$remoteCombinedDist'"

if (-not (Test-Path -LiteralPath $zipPath)) {
    throw "Server bundle ZIP was not created: $zipPath"
}

if (![string]::IsNullOrWhiteSpace($env:CLIPMAN_SERVER_BUILDS)) {
    New-Item -ItemType Directory -Force -Path $env:CLIPMAN_SERVER_BUILDS | Out-Null
    Copy-Item -LiteralPath $zipPath -Destination (Join-Path $env:CLIPMAN_SERVER_BUILDS (Split-Path -Leaf $zipPath)) -Force
}

Remove-Item -LiteralPath ([IO.Path]::GetDirectoryName($windowsWrapperDist)) -Recurse -Force -ErrorAction SilentlyContinue
Write-Host "Built $zipPath"
