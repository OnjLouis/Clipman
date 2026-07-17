param(
    [string]$ComputerName = '',
    [string]$ExecutablePath = '',
    [string]$UserId = '',
    [string]$TaskPrefix = 'Clipman One Shot Launcher',
    [int]$WaitSeconds = 3
)

$ErrorActionPreference = 'Stop'

$launcher = {
    param(
        [string]$ExecutablePath,
        [string]$UserId,
        [string]$TaskPrefix,
        [int]$WaitSeconds
    )

    $ErrorActionPreference = 'Stop'

    function Resolve-ClipmanExecutable([string]$ConfiguredPath) {
        if (![string]::IsNullOrWhiteSpace($ConfiguredPath)) {
            return [Environment]::ExpandEnvironmentVariables($ConfiguredPath)
        }

        $defaultPath = Join-Path $env:APPDATA 'Clipman\clipman.exe'
        if (Test-Path -LiteralPath $defaultPath) {
            return $defaultPath
        }

        $runKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
        try {
            $runValue = (Get-ItemProperty -Path $runKey -Name 'Clipman' -ErrorAction Stop).Clipman
            if ($runValue -match '^\s*"([^"]+)"') {
                return [Environment]::ExpandEnvironmentVariables($Matches[1])
            }
            if ($runValue -match '^\s*(\S+)') {
                return [Environment]::ExpandEnvironmentVariables($Matches[1])
            }
        }
        catch {
        }

        return $defaultPath
    }

    function Get-ClipmanProcessByPath([string]$Path) {
        $fullPath = [IO.Path]::GetFullPath($Path)
        @(Get-CimInstance Win32_Process -Filter "Name = 'clipman.exe'" -ErrorAction SilentlyContinue |
            Where-Object {
                ![string]::IsNullOrWhiteSpace($_.ExecutablePath) -and
                ([IO.Path]::GetFullPath($_.ExecutablePath) -ieq $fullPath)
            })
    }

    $resolvedExe = Resolve-ClipmanExecutable $ExecutablePath
    if (!(Test-Path -LiteralPath $resolvedExe)) {
        throw "Clipman executable was not found: $resolvedExe"
    }

    $existing = @(Get-ClipmanProcessByPath $resolvedExe)
    if ($existing.Count -gt 0) {
        return [pscustomobject]@{
            ComputerName = $env:COMPUTERNAME
            ExecutablePath = $resolvedExe
            AlreadyRunning = $true
            CreatedTask = $false
            TaskRemoved = $true
            ProcessId = $existing[0].ProcessId
        }
    }

    if ([string]::IsNullOrWhiteSpace($UserId)) {
        $UserId = (Get-CimInstance Win32_ComputerSystem).UserName
    }
    if ([string]::IsNullOrWhiteSpace($UserId)) {
        throw 'No interactive user is logged on, so Clipman cannot be started interactively.'
    }

    $taskName = ('{0} {1}' -f $TaskPrefix, ([guid]::NewGuid().ToString('N')))
    $taskRegistered = $false

    try {
        $action = New-ScheduledTaskAction -Execute $resolvedExe
        $principal = New-ScheduledTaskPrincipal -UserId $UserId -LogonType Interactive -RunLevel Limited
        $settings = New-ScheduledTaskSettingsSet -MultipleInstances IgnoreNew -ExecutionTimeLimit (New-TimeSpan -Minutes 0)
        $task = New-ScheduledTask -Action $action -Principal $principal -Settings $settings

        Register-ScheduledTask -TaskName $taskName -InputObject $task -Force | Out-Null
        $taskRegistered = $true
        Start-ScheduledTask -TaskName $taskName
        Start-Sleep -Seconds ([Math]::Max(1, $WaitSeconds))

        $started = @(Get-ClipmanProcessByPath $resolvedExe)
        if ($started.Count -eq 0) {
            throw "Clipman did not appear to start from $resolvedExe."
        }

        return [pscustomobject]@{
            ComputerName = $env:COMPUTERNAME
            ExecutablePath = $resolvedExe
            AlreadyRunning = $false
            CreatedTask = $true
            TaskRemoved = $false
            ProcessId = $started[0].ProcessId
        }
    }
    finally {
        if ($taskRegistered) {
            Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue
        }
    }
}

if ([string]::IsNullOrWhiteSpace($ComputerName) -or $ComputerName -ieq $env:COMPUTERNAME -or $ComputerName -ieq 'localhost') {
    $result = & $launcher $ExecutablePath $UserId $TaskPrefix $WaitSeconds
}
else {
    $result = Invoke-Command -ComputerName $ComputerName -ScriptBlock $launcher -ArgumentList $ExecutablePath, $UserId, $TaskPrefix, $WaitSeconds
}

$remainingTask = if ([string]::IsNullOrWhiteSpace($ComputerName) -or $ComputerName -ieq $env:COMPUTERNAME -or $ComputerName -ieq 'localhost') {
    @(Get-ScheduledTask -TaskName "$TaskPrefix*" -ErrorAction SilentlyContinue)
}
else {
    @(Invoke-Command -ComputerName $ComputerName -ScriptBlock {
        param([string]$TaskPrefix)
        Get-ScheduledTask -TaskName "$TaskPrefix*" -ErrorAction SilentlyContinue
    } -ArgumentList $TaskPrefix)
}

if ($remainingTask.Count -gt 0) {
    throw "Temporary Clipman launch task was not removed: $($remainingTask[0].TaskName)"
}

$result.TaskRemoved = $true
$result
