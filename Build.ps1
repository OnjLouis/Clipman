param(
    [string]$OutputPath = $(Join-Path ([IO.Path]::GetTempPath()) 'Clipman-portable\clipman.exe'),
    [switch]$DesktopOnly,
    [switch]$PreserveBuildStamp
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
        throw "Version $version has already been released as tag $tag, but this working tree has new changes. Bump AssemblyInformationalVersion, AssemblyVersion, and AssemblyFileVersion before building."
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
    'System.Web.dll',
    'System.Web.Extensions.dll'
) -join ','

$buildInfoPath = Join-Path $PSScriptRoot 'src\BuildInfo.cs'
if ($PreserveBuildStamp) {
    $buildInfoText = Get-Content -LiteralPath $buildInfoPath -Raw
    $buildStampMatch = [regex]::Match($buildInfoText, 'BuildStampUtcMs\s*=\s*(?<stamp>\d+)L')
    if (!$buildStampMatch.Success) {
        throw "Could not read the existing build stamp from $buildInfoPath"
    }
    $buildStamp = [long]$buildStampMatch.Groups['stamp'].Value
} else {
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
}

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
    $iOSInfoReaderSettings = [Xml.XmlReaderSettings]::new()
    $iOSInfoReaderSettings.DtdProcessing = [Xml.DtdProcessing]::Ignore
    $iOSInfoReaderSettings.XmlResolver = $null
    $iOSInfoReader = [Xml.XmlReader]::Create($iOSInfoPath, $iOSInfoReaderSettings)
    $validatedIOSInfo = [Xml.XmlDocument]::new()
    $validatedIOSInfo.XmlResolver = $null
    $validatedIOSInfo.Load($iOSInfoReader)
}
catch {
    throw "The updated iOS Info.plist is invalid: $($_.Exception.Message)"
}
finally {
    if ($null -ne $iOSInfoReader) {
        $iOSInfoReader.Dispose()
    }
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

Write-Host "Built $OutputPath"
