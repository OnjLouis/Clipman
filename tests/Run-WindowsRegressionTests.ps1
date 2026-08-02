$ErrorActionPreference = 'Stop'

$repositoryRoot = Split-Path -Parent $PSScriptRoot
$compiler = Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
if (-not (Test-Path -LiteralPath $compiler)) {
    throw "Could not find the .NET Framework C# compiler at $compiler"
}

$workingDirectory = Join-Path ([IO.Path]::GetTempPath()) ('ClipmanWindowsRegression-' + [Guid]::NewGuid().ToString('N'))
$testExecutable = Join-Path $workingDirectory 'ClipmanWindowsRegressionTests.exe'
New-Item -ItemType Directory -Force -Path $workingDirectory | Out-Null

try {
    $references = @(
        'System.dll',
        'System.Core.dll',
        'System.Drawing.dll',
        'System.IO.Compression.dll',
        'System.IO.Compression.FileSystem.dll',
        'System.Net.Http.dll',
        'System.Security.dll',
        'System.Windows.Forms.dll',
        'System.Web.dll',
        'System.Web.Extensions.dll'
    ) -join ','
    $sources = @(Get-ChildItem -LiteralPath (Join-Path $repositoryRoot 'src') -Filter '*.cs' | Sort-Object Name | ForEach-Object { $_.FullName })
    $sources += Join-Path $PSScriptRoot 'WindowsRegressionTests.cs'
    $arguments = @(
        '/nologo',
        '/target:exe',
        '/platform:x64',
        '/main:Clipman.Tests.WindowsRegressionTests',
        ('/out:' + $testExecutable),
        ('/reference:' + $references)
    ) + $sources

    & $compiler @arguments
    if ($LASTEXITCODE -ne 0) {
        throw "Windows regression test compilation failed with exit code $LASTEXITCODE"
    }
    & $testExecutable
    if ($LASTEXITCODE -ne 0) {
        throw "Windows regression tests failed with exit code $LASTEXITCODE"
    }
}
finally {
    Remove-Item -LiteralPath $workingDirectory -Recurse -Force -ErrorAction SilentlyContinue
}
