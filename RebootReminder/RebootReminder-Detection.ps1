<#
.SYNOPSIS
    Intune Detection Script for Reboot Reminder
.DESCRIPTION
    Checks if system uptime exceeds the configured threshold
    Exit Code 0 = Compliant (uptime within limit)
    Exit Code 1 = Non-compliant (uptime exceeds limit)
#>

param(
    [Parameter(Mandatory=$false)]
    [ValidateRange(1,365)]
    [int]$DaysLimit = 7
)

$ErrorActionPreference = "Stop"

function Test-RebootCompliance {
    param(
        [Parameter(Mandatory=$true)]
        [double]$UptimeDays,
        [Parameter(Mandatory=$true)]
        [int]$DaysLimit
    )

    return ($UptimeDays -ge $DaysLimit)
}

try {
    # Get system uptime
    $OS = Get-CimInstance -ClassName Win32_OperatingSystem
    $LastBoot = $OS.LastBootUpTime
    $Uptime = (Get-Date) - $LastBoot
    $UptimeDays = [math]::Round($Uptime.TotalDays, 1)

    Write-Host "Checking reboot compliance..."
    Write-Host "Last Boot: $LastBoot"
    Write-Host "Uptime: $UptimeDays days"
    Write-Host "Threshold: $DaysLimit days"

    if (Test-RebootCompliance -UptimeDays $UptimeDays -DaysLimit $DaysLimit) {
        Write-Host "System is non-compliant: uptime exceeds $DaysLimit days"
        exit 1
    } else {
        Write-Host "System is compliant: uptime within limit"
        exit 0
    }
}
catch {
    Write-Error "Detection script failed: $_"
    exit 1
}
