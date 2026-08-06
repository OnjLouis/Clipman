param(
    [string]$OutputDirectory = $(if ([string]::IsNullOrWhiteSpace($env:CLIPMAN_CLI_BUILD_DIR)) { Join-Path ([IO.Path]::GetTempPath()) 'clipman-cli-build' } else { $env:CLIPMAN_CLI_BUILD_DIR }),
    [string]$GoExecutable = $(if ([string]::IsNullOrWhiteSpace($env:CLIPMAN_CLI_GO)) { 'go' } else { $env:CLIPMAN_CLI_GO })
)

$ErrorActionPreference = 'Stop'
$sourceRoot = [IO.Path]::GetFullPath($PSScriptRoot).TrimEnd('\')
$outputRoot = [IO.Path]::GetFullPath($OutputDirectory).TrimEnd('\')
if ($outputRoot -eq [IO.Path]::GetPathRoot($outputRoot).TrimEnd('\')) {
    throw 'OutputDirectory cannot be a filesystem root.'
}
if ($outputRoot -eq $sourceRoot -or $outputRoot.StartsWith($sourceRoot + '\', [StringComparison]::OrdinalIgnoreCase)) {
    throw 'OutputDirectory must be outside the Clipman CLI source tree.'
}

$version = (Get-Content -LiteralPath (Join-Path $PSScriptRoot 'VERSION') -Raw).Trim()
if ([string]::IsNullOrWhiteSpace($version)) { throw 'VERSION is empty.' }
$packageFiles = @(
    @{ Source = Join-Path $PSScriptRoot 'Manual.html'; Destination = 'manual/Manual.html' },
    @{ Source = Join-Path $PSScriptRoot 'clipman-cli.1'; Destination = 'manual/clipman-cli.1' },
    @{ Source = Join-Path (Split-Path -Parent $PSScriptRoot) 'LICENSE.txt'; Destination = 'LICENSE.txt' }
)
foreach ($file in $packageFiles) {
    if (-not (Test-Path -LiteralPath $file.Source -PathType Leaf)) {
        throw "Required package file is missing: $($file.Source)"
    }
}
# Every binary is named clipman-cli and identified by its directory, so
# installing one is a move rather than a rename.
$targets = @(
    @{ os = 'windows'; arch = 'amd64'; arm = '';  directory = 'windows-amd64'; binary = 'clipman-cli.exe' },
    @{ os = 'windows'; arch = 'arm64'; arm = '';  directory = 'windows-arm64'; binary = 'clipman-cli.exe' },
    @{ os = 'linux';   arch = 'amd64'; arm = '';  directory = 'linux-amd64';   binary = 'clipman-cli' },
    @{ os = 'linux';   arch = 'arm';   arm = '7'; directory = 'linux-armv7';   binary = 'clipman-cli' },
    @{ os = 'linux';   arch = 'arm64'; arm = '';  directory = 'linux-arm64';   binary = 'clipman-cli' },
    @{ os = 'darwin';  arch = 'amd64'; arm = '';  directory = 'macos-amd64';   binary = 'clipman-cli' },
    @{ os = 'darwin';  arch = 'arm64'; arm = '';  directory = 'macos-arm64';   binary = 'clipman-cli' }
)

$staging = Join-Path $outputRoot 'staging'
if (Test-Path -LiteralPath $staging) { Remove-Item -LiteralPath $staging -Recurse -Force }
New-Item -ItemType Directory -Path $staging -Force | Out-Null

$saved = @{
    CGO_ENABLED = $env:CGO_ENABLED
    GOOS = $env:GOOS
    GOARCH = $env:GOARCH
    GOARM = $env:GOARM
}
Push-Location $PSScriptRoot
try {
    & $GoExecutable test ./...
    if ($LASTEXITCODE -ne 0) { throw 'Go tests failed.' }
    & $GoExecutable vet ./...
    if ($LASTEXITCODE -ne 0) { throw 'Go vet failed.' }
    foreach ($target in $targets) {
        $env:CGO_ENABLED = '0'
        $env:GOOS = $target.os
        $env:GOARCH = $target.arch
        if ($target.arm) { $env:GOARM = $target.arm }
        else { Remove-Item Env:GOARM -ErrorAction SilentlyContinue }
        $targetDirectory = Join-Path $staging $target.directory
        New-Item -ItemType Directory -Path $targetDirectory -Force | Out-Null
        $destination = Join-Path $targetDirectory $target.binary
        & $GoExecutable build -trimpath -ldflags "-s -w -X main.version=$version" -o $destination ./cmd/clipman-cli
        if ($LASTEXITCODE -ne 0) { throw "Build failed for $($target.os)/$($target.arch)." }
    }
}
finally {
	Pop-Location
    foreach ($name in $saved.Keys) {
        if ($null -eq $saved[$name]) { Remove-Item "Env:$name" -ErrorAction SilentlyContinue }
        else { Set-Item "Env:$name" $saved[$name] }
    }
}

# Paths stay relative with forward slashes so that `sha256sum -c SHA256SUMS`
# verifies the whole package from its root on any platform.
$records = foreach ($target in $targets) {
    $relative = "$($target.directory)/$($target.binary)"
    $path = Join-Path $staging $relative
    $hash = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant()
    "$hash  $relative"
}
[IO.File]::WriteAllText((Join-Path $staging 'SHA256SUMS'), (($records | Sort-Object) -join "`n") + "`n", [Text.UTF8Encoding]::new($false))
foreach ($file in $packageFiles) {
    $destination = Join-Path $staging $file.Destination
    New-Item -ItemType Directory -Path (Split-Path -Parent $destination) -Force | Out-Null
    Copy-Item -LiteralPath $file.Source -Destination $destination
}

$final = Join-Path $outputRoot "ClipmanCli-$version"
if (Test-Path -LiteralPath $final) { Remove-Item -LiteralPath $final -Recurse -Force }
Move-Item -LiteralPath $staging -Destination $final
Write-Output "Built $final"
