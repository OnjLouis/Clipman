# Builds and runs the Clipman interoperability fixture generator.
#
# The generator compiles against the real Windows client sources, so the
# fixtures it writes come from the canonical ClipDatabaseFile and
# ServerDatabaseIdentity implementations. It uses the same .NET Framework 4.0
# compiler as Build.ps1, which means the generator itself is C# 5.
#
#   .\tools\ClipmanFixtures\Build-Fixtures.ps1
#   .\tools\ClipmanFixtures\Build-Fixtures.ps1 -Verify .\some\directory
#
# -Verify loads every .clipdb in a directory through the Windows reader instead
# of generating anything, which is how blobs written by another client are
# checked in the other direction. A sibling <name>.password file supplies the
# history password for an encrypted blob.

[CmdletBinding()]
param(
    [string]$OutputPath,
    [string]$Verify
)

$ErrorActionPreference = 'Stop'

$repoRoot = Resolve-Path (Join-Path $PSScriptRoot '..\..')
$csc = Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
if (-not (Test-Path -LiteralPath $csc)) {
    throw "The .NET Framework 4.0 C# compiler was not found at $csc."
}

# The whole client is compiled, exactly as Build.ps1 does it. Picking out
# individual files looks tidier but drags in a chain of dependencies that
# changes every time the client grows a type, and it risks compiling a
# different ClipDatabaseFile than the one that ships.
$clientSources = Get-ChildItem -LiteralPath (Join-Path $repoRoot 'src') -Filter '*.cs' |
    Sort-Object Name | ForEach-Object { $_.FullName }
if (-not $clientSources) { throw "No client sources found under $repoRoot\src." }

$generator = Join-Path $PSScriptRoot 'Program.cs'
if (-not (Test-Path -LiteralPath $generator)) { throw "Missing source file: $generator" }
$sources = @($generator) + $clientSources

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

$binary = Join-Path $PSScriptRoot 'ClipmanFixtures.exe'
# The client carries its own Main, so the entry point is named explicitly.
& $csc /nologo /target:exe /platform:x64 /main:Clipman.Fixtures.Program /out:$binary /reference:$references $sources
if ($LASTEXITCODE -ne 0) { throw 'The fixture generator failed to compile.' }

if ($Verify) {
    & $binary verify (Resolve-Path -LiteralPath $Verify)
    if ($LASTEXITCODE -ne 0) { throw 'Fixture verification failed.' }
    return
}

if (-not $OutputPath) {
    $OutputPath = Join-Path $repoRoot 'ClipmanCli\testdata\fixtures\windows'
}
New-Item -ItemType Directory -Force $OutputPath | Out-Null
& $binary (Resolve-Path -LiteralPath $OutputPath)
if ($LASTEXITCODE -ne 0) { throw 'Fixture generation failed.' }
