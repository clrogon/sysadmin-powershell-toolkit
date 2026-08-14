<#
.SYNOPSIS
    Centralized error handling for PowerShell scripts

.DESCRIPTION
    Provides unified error handling, retry logic, and resilience across all
    scripts. Depends on Logging and Configuration; importing this module pulls
    both in automatically.

.NOTES
    Version: 3.0.0
    Author: Cláudio Gonçalves
#>

Import-Module (Join-Path $PSScriptRoot 'Logging.psm1') -Force

function Test-AdministrativePrivileges {
    [CmdletBinding()]
    param()

    if ([System.Runtime.InteropServices.RuntimeInformation]::IsOSPlatform([System.Runtime.InteropServices.OSPlatform]::Windows)) {
        $currentUser = [Security.Principal.WindowsIdentity]::GetCurrent()
        $principal = New-Object Security.Principal.WindowsPrincipal($currentUser)
        return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    }

    return ((id -u) -eq 0)
}

function Get-ScriptStackTrace {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)]
        $ErrorRecord,
        [int]$MaxFrames = 10
    )

    if (-not $ErrorRecord.ScriptStackTrace) {
        return "No stack trace available"
    }

    $stackLines = @($ErrorRecord.ScriptStackTrace -split "`r?`n")

    $traceLines = @()
    for ($i = 0; $i -lt $stackLines.Count -and $i -lt $MaxFrames; $i++) {
        $traceLines += $stackLines[$i].Trim()
    }

    return ($traceLines -join "`n")
}

function Invoke-RetryCommand {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)]
        [scriptblock]$ScriptBlock,
        [int]$MaxRetries = 3,
        [int]$RetryDelaySeconds = 5,
        [string]$ErrorMessage = "Command failed"
    )

    $attempt = 0

    while ($true) {
        $attempt++

        try {
            return & $ScriptBlock
        }
        catch {
            if ($attempt -ge $MaxRetries) {
                throw
            }

            Write-ScriptLog -Level Warning -Message "$ErrorMessage - Attempt $attempt/$MaxRetries failed. Retrying in $RetryDelaySeconds seconds."

            if ($RetryDelaySeconds -gt 0) {
                Start-Sleep -Seconds $RetryDelaySeconds
            }
        }
    }
}

function Test-NetworkConnectivity {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)]
        [string]$ComputerName,
        [int]$Count = 2,
        [int]$TimeoutSeconds = 5
    )

    try {
        $result = Test-Connection -ComputerName $ComputerName -Count $Count -ErrorAction Stop

        $averageLatency = if ($result) {
            ($result | Measure-Object ResponseTime -Average).Average
        } else {
            $null
        }

        return [PSCustomObject]@{
            Connected = ($null -ne $result)
            LatencyMs = $averageLatency
            PacketsSent = $Count
            PacketsReceived = @($result).Count
        }
    }
    catch {
        return [PSCustomObject]@{
            Connected = $false
            LatencyMs = $null
            PacketsSent = $Count
            PacketsReceived = 0
        }
    }
}

function Invoke-GracefulShutdown {
    [CmdletBinding()]
    param(
        [string]$ComputerName = $env:COMPUTERNAME,
        [string]$Reason = "Scheduled maintenance",
        [int]$DelaySeconds = 300,
        [switch]$Force
    )

    Write-ScriptLog -Level Info -Message "Initiating graceful shutdown of $ComputerName in $DelaySeconds seconds. Reason: $Reason"

    if (-not $Force) {
        Write-ScriptLog -Level Warning -Message "Graceful shutdown requested. User confirmation required (pass -Force to skip)."
        return
    }

    try {
        Stop-Computer -ComputerName $ComputerName -Force -ErrorAction Stop
        Write-ScriptLog -Level Info -Message "Shutdown command issued for $ComputerName"
    }
    catch {
        Write-ScriptLog -Level Error -Message "Failed to shut down ${ComputerName}: $($_.Exception.Message)"
        throw
    }
}

Export-ModuleMember -Function @(
    'Initialize-ScriptConfiguration',
    'Get-ScriptConfiguration',
    'Set-ScriptConfiguration',
    'Save-ScriptConfiguration',
    'Get-DefaultConfiguration',
    'Initialize-Logging',
    'Register-EventLogSource',
    'Write-ScriptLog',
    'Check-LogRotation',
    'Clean-OldLogs',
    'Start-LogTransaction',
    'Complete-LogTransaction',
    'Add-LogTransactionStep',
    'Get-LogSummary',
    'Search-ScriptLogs',
    'Test-AdministrativePrivileges',
    'Get-ScriptStackTrace',
    'Invoke-RetryCommand',
    'Test-NetworkConnectivity',
    'Invoke-GracefulShutdown'
)
