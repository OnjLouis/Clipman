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
    @{ Source = Join-Path $PSScriptRoot 'Manual.html'; Destination = 'Manual.html' },
    @{ Source = Join-Path $PSScriptRoot 'clipman-cli.1'; Destination = 'clipman-cli.1' },
    @{ Source = Join-Path (Split-Path -Parent $PSScriptRoot) 'LICENSE.txt'; Destination = 'LICENSE.txt' }
)
foreach ($file in $packageFiles) {
    if (-not (Test-Path -LiteralPath $file.Source -PathType Leaf)) {
        throw "Required package file is missing: $($file.Source)"
    }
}
$targets = @(
    @{ os = 'windows'; arch = 'amd64'; arm = '';  output = 'clipman-cli-windows-amd64.exe' },
    @{ os = 'linux';   arch = 'amd64'; arm = '';  output = 'clipman-cli-linux-amd64' },
    @{ os = 'linux';   arch = 'arm';   arm = '7'; output = 'clipman-cli-linux-armv7' },
    @{ os = 'linux';   arch = 'arm64'; arm = '';  output = 'clipman-cli-linux-arm64' },
    @{ os = 'darwin';  arch = 'amd64'; arm = '';  output = 'clipman-cli-macos-amd64' },
    @{ os = 'darwin';  arch = 'arm64'; arm = '';  output = 'clipman-cli-macos-arm64' }
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
    foreach ($target in $targets) {
        $env:CGO_ENABLED = '0'
        $env:GOOS = $target.os
        $env:GOARCH = $target.arch
        if ($target.arm) { $env:GOARM = $target.arm }
        else { Remove-Item Env:GOARM -ErrorAction SilentlyContinue }
        $destination = Join-Path $staging $target.output
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

$records = foreach ($target in $targets) {
    $path = Join-Path $staging $target.output
    $hash = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant()
    "$hash  $($target.output)"
}
[IO.File]::WriteAllText((Join-Path $staging 'SHA256SUMS'), (($records | Sort-Object) -join "`n") + "`n", [Text.UTF8Encoding]::new($false))
foreach ($file in $packageFiles) {
    Copy-Item -LiteralPath $file.Source -Destination (Join-Path $staging $file.Destination)
}

$final = Join-Path $outputRoot "ClipmanCli-$version"
if (Test-Path -LiteralPath $final) { Remove-Item -LiteralPath $final -Recurse -Force }
Move-Item -LiteralPath $staging -Destination $final
Write-Output "Built $final"
