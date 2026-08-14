<#
.SYNOPSIS
    Unified logging framework for PowerShell scripts

.DESCRIPTION
    Provides consistent logging across all scripts with support for multiple
    outputs (file, event log, console), log rotation, and structured data.
    Log files are CSV so they can be inspected with Import-Csv.

.NOTES
    Version: 3.0.0
    Author: Cláudio Gonçalves
#>

Import-Module (Join-Path $PSScriptRoot 'Configuration.psm1') -Force

function Get-LoggingConfigValue {
    [CmdletBinding()]
    param(
        [string]$Section,
        [string]$Key,
        $Default
    )

    $config = Get-ScriptConfiguration
    if ($config -and $config.$Section -and $null -ne $config.$Section.$Key) {
        return $config.$Section.$Key
    }
    return $Default
}

function Initialize-Logging {
    [CmdletBinding()]
    param(
        [string]$LogPath,
        [string]$Component = $MyInvocation.MyCommand.Name,
        [string]$EventLogName = "Application",
        [string]$EventLogSource = "PowerShellScripts"
    )

    if (-not $LogPath) {
        $logDir = Get-LoggingConfigValue -Section 'Logging' -Key 'DefaultPath' -Default "$env:ProgramData\PowerShellScripts\Logs"

        if (-not $logDir) {
            $logDir = Join-Path $env:TEMP 'PowerShellScripts\Logs'
        }

        if (-not (Test-Path $logDir)) {
            try {
                New-Item -ItemType Directory -Path $logDir -Force -ErrorAction Stop | Out-Null
            }
            catch {
                $logDir = Join-Path $env:TEMP 'PowerShellScripts\Logs'
                New-Item -ItemType Directory -Path $logDir -Force -ErrorAction Stop | Out-Null
            }
        }

        $LogPath = Join-Path $logDir "$Component.log"
    }

    $script:LogPath = $LogPath
    $script:LogComponent = $Component
    $script:EventLogName = $EventLogName
    $script:EventLogSource = $EventLogSource
    $script:EventLogReady = $null

    Ensure-LogFileHeader -LogPath $LogPath

    Register-EventLogSource -EventLogName $EventLogName -EventLogSource $EventLogSource
}

function Get-LogHeaderLine {
    return '"Timestamp","Component","Level","Message","ComputerName","UserName","ProcessID","Metadata"'
}

function Ensure-LogFileHeader {
    [CmdletBinding()]
    param(
        [string]$LogPath
    )

    if (-not $LogPath) {
        return
    }

    if (-not (Test-Path $LogPath)) {
        $logDir = Split-Path -Parent $LogPath
        if ($logDir -and -not (Test-Path $logDir)) {
            try {
                New-Item -ItemType Directory -Path $logDir -Force -ErrorAction Stop | Out-Null
            }
            catch {
                Write-Debug "Could not create log directory '$logDir': $($_.Exception.Message)"
            }
        }
        Add-Content -Path $LogPath -Value (Get-LogHeaderLine) -ErrorAction SilentlyContinue
    }
}

function Register-EventLogSource {
    [CmdletBinding()]
    param(
        [string]$EventLogName = "Application",
        [string]$EventLogSource = "PowerShellScripts"
    )

    if (-not ('System.Diagnostics.EventLog' -as [type])) {
        $script:EventLogReady = $false
        Write-Debug "Event log API unavailable on this platform; event log writes disabled."
        return
    }

    if ([System.Diagnostics.EventLog]::SourceExists($EventLogSource)) {
        $script:EventLogReady = $true
        return
    }

    try {
        [System.Diagnostics.EventLog]::CreateEventSource($EventLogSource, $EventLogName) | Out-Null
        $script:EventLogReady = $true
    }
    catch {
        $script:EventLogReady = $false
    }
}

function Write-ScriptLog {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)]
        [string]$Message,
        [ValidateSet('Info', 'Warning', 'Error', 'Debug', 'Verbose')]
        [string]$Level = 'Info',
        [string]$Component = $script:LogComponent,
        [hashtable]$Metadata = @{},
        [switch]$NoConsole,
        [switch]$NoFile,
        [switch]$NoEventLog
    )

    $timestamp = Get-Date

    $metadataText = if ($Metadata.Count -gt 0) {
        ($Metadata.GetEnumerator() | ForEach-Object { "$($_.Key)=$($_.Value)" }) -join '; '
    } else {
        ''
    }

    $logEntry = [PSCustomObject]@{
        Timestamp    = $timestamp
        Component    = $Component
        Level        = $Level
        Message      = $Message
        ComputerName = $env:COMPUTERNAME
        UserName     = $env:USERNAME
        ProcessID    = $PID
        Metadata     = $metadataText
    }

    if (-not $NoConsole) {
        $infoLine = "[$timestamp] [$Level] [$Component] $Message"
        Write-Host $infoLine
    }

    if (-not $NoFile -and $script:LogPath) {
        Check-LogRotation -LogPath $script:LogPath
        Ensure-LogFileHeader -LogPath $script:LogPath

        $csvLine = ConvertTo-CsvLine -Fields @(
            $logEntry.Timestamp.ToString('yyyy-MM-dd HH:mm:ss.fff'),
            $Component,
            $Level,
            $Message,
            $logEntry.ComputerName,
            $logEntry.UserName,
            $logEntry.ProcessID,
            $logEntry.Metadata
        )

        $csvLine | Add-Content -Path $script:LogPath -ErrorAction SilentlyContinue
    }

    if (-not $NoEventLog -and $script:EventLogReady) {
        $eventType = switch ($Level) {
            'Error'   { 'Error' }
            'Warning' { 'Warning' }
            default   { 'Information' }
        }

        $eventId = switch ($Level) {
            'Error'   { 1001 }
            'Warning' { 1002 }
            'Debug'   { 1003 }
            'Verbose' { 1004 }
            default   { 1000 }
        }

        try {
            Write-EventLog -LogName $script:EventLogName -Source $script:EventLogSource `
                -EntryType $eventType -Message $Message -EventId $eventId -ErrorAction SilentlyContinue
        }
        catch {
            Write-Debug "Event log write failed: $($_.Exception.Message)"
        }
    }

    return $logEntry
}

function ConvertTo-CsvLine {
    [CmdletBinding()]
    param(
        [string[]]$Fields
    )

    return (($Fields | ForEach-Object {
        '"' + ($_ -replace '"', '""') + '"'
    }) -join ',')
}

function Check-LogRotation {
    [CmdletBinding()]
    param(
        [string]$LogPath
    )

    if (-not (Test-Path $LogPath)) {
        return
    }

    $maxSize = Get-LoggingConfigValue -Section 'Logging' -Key 'MaxSize' -Default 10MB

    $logFile = Get-Item $LogPath
    if ($logFile.Length -le $maxSize) {
        return
    }

    $timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
    $backupPath = "$LogPath.$timestamp"
    Move-Item -Path $LogPath -Destination $backupPath -Force

    Write-ScriptLog -Level Warning -Message "Log rotated to $backupPath" -NoConsole -NoEventLog

    Clean-OldLogs -LogDirectory (Split-Path -Parent $LogPath)
}

function Clean-OldLogs {
    [CmdletBinding()]
    param(
        [string]$LogDirectory,
        [int]$RetentionDays = 30
    )

    $RetentionDays = Get-LoggingConfigValue -Section 'Logging' -Key 'RetentionDays' -Default $RetentionDays

    if (-not (Test-Path $LogDirectory)) {
        return
    }

    $cutoffDate = (Get-Date).AddDays(-$RetentionDays)

    Get-ChildItem -Path $LogDirectory -Filter "*.log.*" -ErrorAction SilentlyContinue |
        Where-Object { $_.LastWriteTime -lt $cutoffDate } |
        Remove-Item -Force -ErrorAction SilentlyContinue
}

function Start-LogTransaction {
    [CmdletBinding()]
    param(
        [string]$TransactionName,
        [hashtable]$InitialData = @{}
    )

    $script:CurrentTransaction = @{
        Name      = $TransactionName
        StartTime = Get-Date
        Steps     = @()
        Data      = $InitialData
    }

    Write-ScriptLog -Level Info -Message "Transaction started: $TransactionName"
}

function Complete-LogTransaction {
    [CmdletBinding()]
    param(
        [string]$Status = 'Completed',
        [string]$AdditionalInfo = ''
    )

    if (-not $script:CurrentTransaction) {
        return
    }

    $duration = (Get-Date) - $script:CurrentTransaction.StartTime

    $summary = "Transaction '$($script:CurrentTransaction.Name)' $Status in $([math]::Round($duration.TotalSeconds, 2)) seconds"

    if ($AdditionalInfo) {
        $summary += " - $AdditionalInfo"
    }

    if ($script:CurrentTransaction.Steps.Count -gt 0) {
        $summary += " ($($script:CurrentTransaction.Steps.Count) steps)"
    }

    Write-ScriptLog -Level Info -Message $summary

    $script:CurrentTransaction = $null
}

function Add-LogTransactionStep {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)]
        [string]$StepName,
        [string]$StepType = 'Info',
        [hashtable]$StepData = @{}
    )

    if (-not $script:CurrentTransaction) {
        return
    }

    $step = [PSCustomObject]@{
        Name      = $StepName
        Type      = $StepType
        Timestamp = Get-Date
        Data      = $StepData
    }

    $script:CurrentTransaction.Steps += $step

    Write-ScriptLog -Level $StepType -Message "Transaction step: $StepName"
}

function Get-LogSummary {
    [CmdletBinding()]
    param(
        [string]$LogPath,
        [DateTime]$StartDate = (Get-Date).AddDays(-7),
        [DateTime]$EndDate = (Get-Date)
    )

    if (-not (Test-Path $LogPath)) {
        return $null
    }

    $logEntries = Import-Csv $LogPath -ErrorAction SilentlyContinue | Where-Object {
        $timestamp = [DateTime]::Parse($_.Timestamp)
        $timestamp -ge $StartDate -and $timestamp -le $EndDate
    }

    $entries = @($logEntries)

    $summary = [PSCustomObject]@{
        TotalEntries     = $entries.Count
        InfoCount        = @($entries | Where-Object Level -eq 'Info').Count
        WarningCount     = @($entries | Where-Object Level -eq 'Warning').Count
        ErrorCount       = @($entries | Where-Object Level -eq 'Error').Count
        DebugCount       = @($entries | Where-Object Level -eq 'Debug').Count
        UniqueComponents = @($entries | Select-Object Component -Unique).Count
        DateRange        = "$StartDate to $EndDate"
    }

    return $summary
}

function Search-ScriptLogs {
    [CmdletBinding()]
    param(
        [string]$SearchTerm,
        [ValidateSet('Info', 'Warning', 'Error', 'Debug', 'Verbose', 'All')]
        [string]$Level = 'All',
        [DateTime]$StartDate = (Get-Date).AddDays(-7),
        [DateTime]$EndDate = (Get-Date)
    )

    $logDir = Get-LoggingConfigValue -Section 'Logging' -Key 'DefaultPath' -Default "$env:ProgramData\PowerShellScripts\Logs"

    if (-not $logDir -or -not (Test-Path $logDir)) {
        return @()
    }

    $results = @()

    Get-ChildItem -Path $logDir -Filter "*.log" -File -ErrorAction SilentlyContinue | ForEach-Object {
        $logEntries = Import-Csv $_.FullName -ErrorAction SilentlyContinue | Where-Object {
            $timestamp = [DateTime]::Parse($_.Timestamp)
            $timestamp -ge $StartDate -and $timestamp -le $EndDate
        }

        if ($SearchTerm) {
            $logEntries = $logEntries | Where-Object { $_.Message -like "*$SearchTerm*" }
        }

        if ($Level -ne 'All') {
            $logEntries = $logEntries | Where-Object Level -eq $Level
        }

        $results += $logEntries
    }

    return $results
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
    'Search-ScriptLogs'
)
