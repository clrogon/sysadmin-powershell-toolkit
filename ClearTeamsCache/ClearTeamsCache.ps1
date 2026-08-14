<#
.SYNOPSIS
    Clears Microsoft Teams cache and restarts the application.

.DESCRIPTION
    Improves Microsoft Teams performance by clearing the cache folders that grow
    over time. Supports local clearing, remote clearing over WinRM, cache
    analytics, scheduled maintenance, and a troubleshooting flow.

.EXAMPLE
    .\ClearTeamsCache.ps1
    Clears the local Teams cache and restarts Teams.

.EXAMPLE
    .\ClearTeamsCache.ps1 -ComputerNames PC-01, PC-02 -ClearRemotely -NotifyUser
    Clears Teams cache remotely on the given computers and notifies the users first.

.EXAMPLE
    .\ClearTeamsCache.ps1 -Force
    Forces the script to continue even if it encounters issues like low disk space.

.NOTES
    Version: 3.0
    Author: Claudio Gonçalves
#>

#Requires -Version 5.1

[CmdletBinding()]
param(
    [string]$LogFolder = "$env:ProgramData\PowerShellScripts\Logs",
    [switch]$Force,
    [string[]]$ComputerNames,
    [PSCredential]$Credential,
    [switch]$ClearRemotely,
    [switch]$NotifyUser,
    [int]$WarningMinutes = 5
)

Import-Module "$PSScriptRoot\..\modules\ErrorHandling.psm1" -Force

Initialize-ScriptConfiguration -DefaultConfig (Get-DefaultConfiguration)
Initialize-Logging -Component "ClearTeamsCache"

function Test-AdminRights {
    return (Test-AdministrativePrivileges)
}

function Test-DiskSpace {
    try {
        $free = (Get-PSDrive C -ErrorAction Stop).Free / 1GB
        return ($free -ge 1)
    }
    catch {
        return $true
    }
}

function Stop-TeamsProcess {
    try {
        $teamsProcess = Get-Process -Name Teams -ErrorAction SilentlyContinue
        if ($teamsProcess) {
            Stop-Process -Name Teams -Force
            Write-ScriptLog -Level Info -Message "Stopped Teams process"
            return $true
        }
    }
    catch {
        Write-ScriptLog -Level Warning -Message "Failed to stop Teams: $($_.Exception.Message)"
        return $false
    }
}

function Start-TeamsProcess {
    try {
        $updateExe = "$env:USERPROFILE\AppData\Local\Microsoft\Teams\Update.exe"
        if (Test-Path $updateExe) {
            Start-Process -FilePath $updateExe `
                -ArgumentList "--processStart `"Teams.exe`" --process-start-args `"--system-initiated`"" `
                -ErrorAction Stop
            Start-Sleep -Seconds 5
        }
        else {
            Write-ScriptLog -Level Warning -Message "Teams Update.exe not found; attempting to start Teams directly"
            Start-Process -FilePath "$env:LOCALAPPDATA\Microsoft\Teams\Current\Teams.exe" -ErrorAction Stop
            Start-Sleep -Seconds 5
        }

        if (Get-Process -Name Teams -ErrorAction SilentlyContinue) {
            Write-ScriptLog -Level Info -Message "MS Teams started successfully"
        }
        else {
            Write-ScriptLog -Level Warning -Message "MS Teams failed to start"
        }
    }
    catch {
        Write-ScriptLog -Level Error -Message "Failed to start MS Teams: $($_.Exception.Message)"
    }
}

function Clear-TeamsCacheFiles {
    $cachePaths = @(
        "$env:APPDATA\Microsoft\Teams\blob_storage",
        "$env:APPDATA\Microsoft\Teams\Cache",
        "$env:APPDATA\Microsoft\Teams\databases",
        "$env:APPDATA\Microsoft\Teams\GPUcache",
        "$env:APPDATA\Microsoft\Teams\IndexedDB",
        "$env:APPDATA\Microsoft\Teams\Local Storage",
        "$env:APPDATA\Microsoft\Teams\tmp"
    )

    $cleared = 0
    foreach ($path in $cachePaths) {
        if (Test-Path $path) {
            Remove-Item -Path $path -Recurse -Force -ErrorAction SilentlyContinue
            $cleared++
        }
    }

    Write-ScriptLog -Level Info -Message "Cleared $cleared of $($cachePaths.Count) Teams cache folders"
    return $cleared
}

function ClearTeamsCache {
    param (
        [string]$LogFolder = "$env:ProgramData\PowerShellScripts\Logs",
        [switch]$Force
    )

    if ($Force) {
        Write-ScriptLog -Level Warning -Message "Force flag set. Skipping some checks."
    }

    if ([string]::IsNullOrWhiteSpace($LogFolder)) {
        Write-ScriptLog -Level Error -Message "Invalid log folder path"
        return 1
    }

    if (-not (Test-Path $LogFolder)) {
        New-Item -Path $LogFolder -ItemType Directory -Force | Out-Null
    }

    if (-not (Test-AdminRights)) {
        Write-ScriptLog -Level Warning -Message "Not running with administrative privileges. Some tasks may fail."
    }

    if (-not (Test-DiskSpace) -and -not $Force) {
        Write-ScriptLog -Level Error -Message "Exiting script due to low disk space"
        return 3
    }

    Stop-TeamsProcess | Out-Null

    Clear-TeamsCacheFiles

    Start-TeamsProcess

    Write-ScriptLog -Level Info -Message "Teams cache clearing completed"
    return 0
}

#region Remote Functions

function Clear-TeamsCacheRemotely {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)]
        [string[]]$ComputerNames,
        [PSCredential]$Credential,
        [switch]$NotifyUser,
        [int]$WarningMinutes = 5
    )

    $results = @()

    $index = 0
    foreach ($computer in $ComputerNames) {
        $index++
        Write-Progress -Activity "Clearing Teams Cache" -Status "Processing: $computer" `
            -PercentComplete (($index / $ComputerNames.Count) * 100)

        $result = [PSCustomObject]@{
            ComputerName   = $computer
            Success        = $false
            Error          = $null
            CacheSizeBefore = 0
            CacheSizeAfter  = 0
        }

        try {
            if ($NotifyUser) {
                Invoke-Command -ComputerName $computer -Credential $Credential -ScriptBlock {
                    Add-Type -AssemblyName Windows.UI.Notifications
                    $xml = @"
<toast>
    <visual>
        <binding template="ToastGeneric">
            <text>Teams Maintenance</text>
            <text>Teams will restart in $using:WarningMinutes minutes to clear cache. Please save your work.</text>
        </binding>
    </visual>
</toast>
"@
                    $doc = New-Object Windows.Data.Xml.Dom.XmlDocument
                    $doc.LoadXml($xml)
                    [Windows.UI.Notifications.ToastNotificationManager]::CreateToastNotifier("Microsoft Teams").Show($doc)
                } -ErrorAction SilentlyContinue
            }

            $result.CacheSizeBefore = Invoke-Command -ComputerName $computer -Credential $Credential -ScriptBlock {
                $cachePath = "$env:APPDATA\Microsoft\Teams"
                if (Test-Path $cachePath) {
                    (Get-ChildItem $cachePath -Recurse -ErrorAction SilentlyContinue | Measure-Object -Property Length -Sum).Sum
                } else {
                    0
                }
            } -ErrorAction Stop

            Invoke-Command -ComputerName $computer -Credential $Credential -ScriptBlock {
                Get-Process -Name "Teams" -ErrorAction SilentlyContinue | Stop-Process -Force
            } -ErrorAction Stop

            Invoke-Command -ComputerName $computer -Credential $Credential -ScriptBlock {
                $cachePaths = @(
                    "$env:APPDATA\Microsoft\Teams\blob_storage",
                    "$env:APPDATA\Microsoft\Teams\Cache",
                    "$env:APPDATA\Microsoft\Teams\databases",
                    "$env:APPDATA\Microsoft\Teams\GPUcache",
                    "$env:APPDATA\Microsoft\Teams\IndexedDB",
                    "$env:APPDATA\Microsoft\Teams\Local Storage",
                    "$env:APPDATA\Microsoft\Teams\tmp"
                )

                foreach ($path in $cachePaths) {
                    if (Test-Path $path) {
                        Remove-Item $path -Recurse -Force
                    }
                }
            } -ErrorAction Stop

            Invoke-Command -ComputerName $computer -Credential $Credential -ScriptBlock {
                Start-Sleep -Seconds 3
                $updatePath = "$env:USERPROFILE\AppData\Local\Microsoft\Teams\Update.exe"
                if (Test-Path $updatePath) {
                    Start-Process -FilePath $updatePath `
                        -ArgumentList "--processStart `"Teams.exe`" --process-start-args `"--system-initiated`""
                }
            } -ErrorAction Stop

            Start-Sleep -Seconds 10

            $result.CacheSizeAfter = Invoke-Command -ComputerName $computer -Credential $Credential -ScriptBlock {
                $cachePath = "$env:APPDATA\Microsoft\Teams"
                if (Test-Path $cachePath) {
                    (Get-ChildItem $cachePath -Recurse -ErrorAction SilentlyContinue | Measure-Object -Property Length -Sum).Sum
                } else {
                    0
                }
            } -ErrorAction SilentlyContinue

            $result.Success = $true
            Write-ScriptLog -Level Info -Message "Teams cache cleared on ${computer}: before=$($result.CacheSizeBefore) after=$($result.CacheSizeAfter)"
        }
        catch {
            $result.Error = $_.Exception.Message
            Write-ScriptLog -Level Error -Message "Failed to clear cache on ${computer}: $($_.Exception.Message)"
        }

        $results += $result
    }

    Write-Progress -Activity "Clearing Teams Cache" -Completed
    return $results
}

function Get-TeamsCacheAnalytics {
    [CmdletBinding()]
    param(
        [string[]]$ComputerNames,
        [PSCredential]$Credential
    )

    $analytics = @()

    foreach ($computer in $ComputerNames) {
        try {
            $cacheInfo = Invoke-Command -ComputerName $computer -Credential $Credential -ScriptBlock {
                $cachePath = "$env:APPDATA\Microsoft\Teams"

                if (-not (Test-Path $cachePath)) {
                    return $null
                }

                $size = (Get-ChildItem $cachePath -Recurse -File -ErrorAction SilentlyContinue |
                    Measure-Object -Property Length -Sum).Sum

                $folders = Get-ChildItem $cachePath -Directory -ErrorAction SilentlyContinue
                $folderSizes = @{}

                foreach ($folder in $folders) {
                    $folderSize = (Get-ChildItem $folder.FullName -Recurse -File -ErrorAction SilentlyContinue |
                        Measure-Object -Property Length -Sum).Sum
                    $folderSizes[$folder.Name] = $folderSize
                }

                return [PSCustomObject]@{
                    TotalSizeMB = [math]::Round($size/1MB, 2)
                    FolderCount = $folders.Count
                    FolderSizes = $folderSizes
                }
            } -ErrorAction Stop

            if ($cacheInfo) {
                $largestFolder = $null
                if ($cacheInfo.FolderSizes.Count -gt 0) {
                    $largestFolder = ($cacheInfo.FolderSizes.GetEnumerator() |
                        Sort-Object Value -Descending | Select-Object -First 1).Key
                }

                $analytics += [PSCustomObject]@{
                    ComputerName = $computer
                    CacheSizeMB = $cacheInfo.TotalSizeMB
                    FolderCount = $cacheInfo.FolderCount
                    NeedsCleanup = $cacheInfo.TotalSizeMB -gt 500
                    LargestFolder = $largestFolder
                }
            }
        }
        catch {
            Write-ScriptLog -Level Warning -Message "Could not analyze ${computer}: $($_.Exception.Message)"
        }
    }

    $analytics | Sort-Object CacheSizeMB -Descending | Format-Table -AutoSize

    $totalSize = ($analytics | Measure-Object CacheSizeMB -Sum).Sum
    $avgSize = ($analytics | Measure-Object CacheSizeMB -Average).Average
    $needsCleanup = @($analytics | Where-Object NeedsCleanup).Count

    Write-Host "`nAnalytics Summary:"
    Write-Host "  Computers: $($analytics.Count)"
    Write-Host "  Total Cache: $([math]::Round($totalSize/1024, 2)) GB"
    Write-Host "  Average Cache: $([math]::Round($avgSize, 2)) MB"
    Write-Host "  Needs Cleanup: $needsCleanup"

    return $analytics
}

function Schedule-TeamsMaintenance {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)]
        [string[]]$ComputerNames,
        [string]$MaintenanceTime = "22:00",
        [ValidateSet('Daily', 'Weekly')]
        [string]$Frequency = 'Weekly'
    )

    $scriptPath = $PSCommandPath

    foreach ($computer in $ComputerNames) {
        $trigger = if ($Frequency -eq 'Daily') {
            New-ScheduledTaskTrigger -Daily -At $MaintenanceTime
        } else {
            New-ScheduledTaskTrigger -Weekly -DaysOfWeek Friday -At $MaintenanceTime
        }

        $action = New-ScheduledTaskAction -Execute "PowerShell.exe" `
            -Argument "-NoProfile -ExecutionPolicy Bypass -File `"$scriptPath`" -ComputerNames $computer -ClearRemotely -Force"

        $settings = New-ScheduledTaskSettingsSet -StartWhenAvailable -DontStopOnIdleEnd -AllowStartIfOnBatteries

        $taskName = "TeamsMaintenance_$computer"

        Register-ScheduledTask -TaskName $taskName -Trigger $trigger -Action $action -Settings $settings `
            -ComputerName $computer -Description "Teams cache maintenance" -Force | Out-Null

        Write-ScriptLog -Level Info -Message "Scheduled Teams maintenance on ${computer} ($Frequency at $MaintenanceTime)"
    }
}

function Invoke-TeamsTroubleshooting {
    [CmdletBinding()]
    param(
        [string]$ComputerName,
        [PSCredential]$Credential
    )

    Write-Host "=== Teams Troubleshooting for $ComputerName ===`n"

    $teamsPath = "\\$ComputerName\c`$\Users\*\AppData\Local\Microsoft\Teams\Update.exe"
    $teamsFound = Test-Path $teamsPath

    Write-Host "Teams Installed: $teamsFound"

    if (-not $teamsFound) {
        Write-Host "Teams is not installed on this computer."
        return
    }

    $teamsRunning = Invoke-Command -ComputerName $ComputerName -Credential $Credential -ScriptBlock {
        Get-Process -Name "Teams" -ErrorAction SilentlyContinue
    }

    Write-Host "Teams Running: $($teamsRunning.Count -gt 0)"

    $cacheSize = Invoke-Command -ComputerName $ComputerName -Credential $Credential -ScriptBlock {
        $cachePath = "$env:APPDATA\Microsoft\Teams"
        if (Test-Path $cachePath) {
            [math]::Round((Get-ChildItem $cachePath -Recurse -File -ErrorAction SilentlyContinue | Measure-Object -Property Length -Sum).Sum/1MB, 2)
        } else {
            0
        }
    } -ErrorAction SilentlyContinue

    Write-Host "Cache Size: $cacheSize MB"

    $errorsFound = Invoke-Command -ComputerName $ComputerName -Credential $Credential -ScriptBlock {
        $logPath = "$env:APPDATA\Microsoft\Teams\logs.txt"
        if (Test-Path $logPath) {
            Select-String -Path $logPath -Pattern "error|Error|ERROR" | Measure-Object | Select-Object -ExpandProperty Count
        } else {
            0
        }
    } -ErrorAction SilentlyContinue

    Write-Host "Errors in Logs: $errorsFound"

    Write-Host "`nRecommendations:"

    if ($cacheSize -gt 500) {
        Write-Host "  - Cache size is large ($cacheSize MB). Consider clearing cache."
    }

    if ($errorsFound -gt 10) {
        Write-Host "  - Multiple errors found in logs. Check logs.txt for details."
    }

    if (@($teamsRunning).Count -eq 0) {
        Write-Host "  - Teams is not running. Try starting Teams."
    }

    $clearCache = Read-Host "Clear Teams cache? (Y/N)"
    if ($clearCache -eq 'Y') {
        Clear-TeamsCacheRemotely -ComputerNames $ComputerName -Credential $Credential -NotifyUser -WarningMinutes 5
    }
}

#endregion

if ($ClearRemotely -and $ComputerNames.Count -gt 0) {
    Clear-TeamsCacheRemotely -ComputerNames $ComputerNames -Credential $Credential -NotifyUser:$NotifyUser -WarningMinutes $WarningMinutes
    exit
}

exit (ClearTeamsCache -LogFolder $LogFolder -Force:$Force)
