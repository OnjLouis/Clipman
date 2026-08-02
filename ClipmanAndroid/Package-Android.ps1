param(
    [string]$Configuration = "Release",
    [string]$OutputDirectory = "",
    [string]$GradlePath = "",
    [string]$ScratchDirectory = "",
    [ValidateRange(30, 900)]
    [int]$GradleNetworkTimeoutSeconds = 600
)

$ErrorActionPreference = "Stop"

$projectRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
if ([string]::IsNullOrWhiteSpace($ScratchDirectory)) {
    $ScratchDirectory = if (![string]::IsNullOrWhiteSpace($env:CLIPMAN_TEMP_ROOT)) {
        $env:CLIPMAN_TEMP_ROOT
    } else {
        Join-Path ([IO.Path]::GetTempPath()) 'Clipman'
    }
}
if ([string]::IsNullOrWhiteSpace($OutputDirectory)) {
    $OutputDirectory = Join-Path $ScratchDirectory 'Android-package'
}

if ([string]::IsNullOrWhiteSpace($env:JAVA_HOME)) {
    throw 'JAVA_HOME must point to a JDK 17 or newer installation.'
}
$androidSdk = if (![string]::IsNullOrWhiteSpace($env:ANDROID_SDK_ROOT)) { $env:ANDROID_SDK_ROOT } else { $env:ANDROID_HOME }
if ([string]::IsNullOrWhiteSpace($androidSdk)) {
    throw 'ANDROID_SDK_ROOT or ANDROID_HOME must point to the Android SDK.'
}
if ([string]::IsNullOrWhiteSpace($GradlePath)) {
    $gradleCommand = Get-Command gradle.bat, gradle -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($null -eq $gradleCommand) {
        throw 'Gradle was not found. Add Gradle to PATH or pass -GradlePath.'
    }
    $GradlePath = $gradleCommand.Source
}
if (!(Test-Path -LiteralPath $GradlePath)) {
    throw "Gradle was not found at $GradlePath"
}
$buildWorkRoot = Join-Path $ScratchDirectory ('Android-build-' + [guid]::NewGuid().ToString('N'))
$projectCache = Join-Path $buildWorkRoot 'project-cache'
$kotlinCache = Join-Path $buildWorkRoot 'kotlin-cache'
$externalBuildRoot = Join-Path $buildWorkRoot 'outputs'
$originalGradleUserHome = $env:GRADLE_USER_HOME
if ([string]::IsNullOrWhiteSpace($env:GRADLE_USER_HOME)) {
    $env:GRADLE_USER_HOME = Join-Path $buildWorkRoot 'gradle-user-home'
}
$gradleUserHomeForBuild = [IO.Path]::GetFullPath($env:GRADLE_USER_HOME)
$scratchRoot = [IO.Path]::GetFullPath($ScratchDirectory).TrimEnd('\')
$ownsGradleUserHome = [string]::IsNullOrWhiteSpace($originalGradleUserHome) -or
    $gradleUserHomeForBuild.StartsWith($scratchRoot + '\Android-build-', [StringComparison]::OrdinalIgnoreCase) -or
    $gradleUserHomeForBuild -match '[\\/]Codex[\\/]temp[\\/]clipman([\\/]|$)'

try {
    New-Item -ItemType Directory -Force -Path $projectCache, $kotlinCache, $env:GRADLE_USER_HOME | Out-Null

    $taskName = if ($Configuration.Equals("Release", [StringComparison]::OrdinalIgnoreCase)) {
        ":app:assembleRelease"
    } else {
        ":app:assembleDebug"
    }

    $networkTimeoutMilliseconds = $GradleNetworkTimeoutSeconds * 1000
    Write-Host "Gradle dependency connection and read timeout: $GradleNetworkTimeoutSeconds seconds."
    & $GradlePath -p $projectRoot ':app:testDebugUnitTest' ':app:compileDebugAndroidTestKotlin' $taskName --no-daemon --stacktrace `
        "-Dorg.gradle.internal.http.connectionTimeout=$networkTimeoutMilliseconds" `
        "-Dorg.gradle.internal.http.socketTimeout=$networkTimeoutMilliseconds" `
        --project-cache-dir $projectCache "-Pkotlin.project.persistent.dir=$kotlinCache" `
        "-PclipmanBuildRoot=$externalBuildRoot"
    if ($LASTEXITCODE -ne 0) {
        throw "Android build failed with exit code $LASTEXITCODE."
    }

    $buildFile = Join-Path $projectRoot "app\build.gradle.kts"
    $versionText = Get-Content -Raw -Path $buildFile
    $versionMatch = [regex]::Match($versionText, 'versionName\s*=\s*"([^"]+)"')
    if (!$versionMatch.Success) {
        throw "Could not determine Android versionName."
    }
    $versionName = $versionMatch.Groups[1].Value

    $variantFolder = if ($Configuration.Equals("Release", [StringComparison]::OrdinalIgnoreCase)) { "release" } else { "debug" }
    $sourceApk = Join-Path $externalBuildRoot "app\outputs\apk\$variantFolder\app-$variantFolder.apk"
    if (!(Test-Path -LiteralPath $sourceApk)) {
        throw "Expected APK not found: $sourceApk"
    }

    New-Item -ItemType Directory -Force -Path $OutputDirectory | Out-Null
    $targetApk = Join-Path $OutputDirectory "Clipman-Android-$versionName.apk"
    Copy-Item -LiteralPath $sourceApk -Destination $targetApk -Force

    $aapt = Get-ChildItem -LiteralPath (Join-Path $androidSdk 'build-tools') -Filter aapt.exe -Recurse -ErrorAction SilentlyContinue |
        Sort-Object FullName -Descending |
        Select-Object -First 1
    if ($null -ne $aapt) {
        & $aapt.FullName dump badging $targetApk | Select-String -Pattern "package:|application-label:"
    }

    Write-Host "Packaged $targetApk"
}
finally {
    if ($null -eq $originalGradleUserHome) {
        Remove-Item Env:GRADLE_USER_HOME -ErrorAction SilentlyContinue
    } else {
        $env:GRADLE_USER_HOME = $originalGradleUserHome
    }

    $generatedPaths = @(
        (Join-Path $projectRoot 'app\build'),
        (Join-Path $projectRoot '.gradle'),
        (Join-Path $projectRoot '.kotlin'),
        $buildWorkRoot
    )
    if ($ownsGradleUserHome -and $gradleUserHomeForBuild -ne $buildWorkRoot) {
        $generatedPaths += $gradleUserHomeForBuild
    }
    foreach ($generatedPath in $generatedPaths) {
        for ($attempt = 1; $attempt -le 10 -and (Test-Path -LiteralPath $generatedPath); $attempt++) {
            try {
                Remove-Item -LiteralPath $generatedPath -Recurse -Force -ErrorAction Stop
            }
            catch {
                if ($attempt -eq 10) {
                    throw "Could not clean generated Android build output: $generatedPath"
                }
                Start-Sleep -Milliseconds 500
            }
        }
        if (Test-Path -LiteralPath $generatedPath) {
            throw "Generated Android build output remains: $generatedPath"
        }
    }
}
