<#
.SYNOPSIS
    Centralized configuration management for PowerShell scripts

.DESCRIPTION
    Provides unified configuration management across all scripts with support for
    default configurations, environment-specific overrides, and persistence.
    Configuration is stored as CliXML in a well-known location; missing files
    and unwritable directories are handled gracefully.

.NOTES
    Version: 3.0.0
    Author: Cláudio Gonçalves
#>

function Initialize-ScriptConfiguration {
    [CmdletBinding()]
    param(
        [string]$ConfigPath = "$env:ProgramData\PowerShellScripts\ScriptConfig.xml",
        [hashtable]$DefaultConfig
    )

    $configDir = Split-Path -Parent $ConfigPath
    if (-not (Test-Path $configDir)) {
        try {
            New-Item -ItemType Directory -Path $configDir -Force -ErrorAction Stop | Out-Null
        }
        catch {
            Write-Warning "Could not create configuration directory '$configDir': $($_.Exception.Message)"
        }
    }

    $global:ScriptConfiguration = if (Test-Path $ConfigPath) {
        try {
            Import-Clixml $ConfigPath -ErrorAction Stop
        }
        catch {
            Write-Warning "Could not read configuration file '$ConfigPath': $($_.Exception.Message)"
            @{}
        }
    } else {
        @{}
    }

    if ($DefaultConfig) {
        foreach ($key in $DefaultConfig.Keys) {
            if (-not $global:ScriptConfiguration.ContainsKey($key)) {
                $global:ScriptConfiguration[$key] = $DefaultConfig[$key]
            }
        }
    }

    Save-ScriptConfiguration -ConfigPath $ConfigPath
    return $global:ScriptConfiguration
}

function Get-ScriptConfiguration {
    [CmdletBinding()]
    param(
        [string]$Key,
        $DefaultValue = $null
    )

    if (-not $global:ScriptConfiguration -or $global:ScriptConfiguration.Count -eq 0) {
        Initialize-ScriptConfiguration | Out-Null
    }

    if ($Key) {
        if ($global:ScriptConfiguration.ContainsKey($Key)) {
            return $global:ScriptConfiguration[$Key]
        }
        return $DefaultValue
    }

    return $global:ScriptConfiguration
}

function Set-ScriptConfiguration {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)]
        [string]$Key,
        [Parameter(Mandatory=$true)]
        $Value,
        [string]$ConfigPath = "$env:ProgramData\PowerShellScripts\ScriptConfig.xml"
    )

    if (-not $global:ScriptConfiguration -or $global:ScriptConfiguration.Count -eq 0) {
        Initialize-ScriptConfiguration -ConfigPath $ConfigPath | Out-Null
    }

    $global:ScriptConfiguration[$Key] = $Value
    Save-ScriptConfiguration -ConfigPath $ConfigPath
}

function Save-ScriptConfiguration {
    [CmdletBinding()]
    param(
        [string]$ConfigPath = "$env:ProgramData\PowerShellScripts\ScriptConfig.xml"
    )

    if (-not $global:ScriptConfiguration) {
        return
    }

    try {
        $global:ScriptConfiguration | Export-Clixml -Path $ConfigPath -Force -ErrorAction Stop
    }
    catch {
        Write-Warning "Could not save configuration file '$ConfigPath': $($_.Exception.Message)"
    }
}

function Get-DefaultConfiguration {
    return @{
        Logging = @{
            DefaultPath = "$env:ProgramData\PowerShellScripts\Logs"
            MaxSize = 10MB
            RetentionDays = 30
            Level = "Info"
            EventLogName = "Application"
            EventLogSource = "PowerShellScripts"
        }
        Notifications = @{
            SMTPServer = "smtp.company.com"
            SMTPPort = 587
            FromAddress = "noreply@company.com"
            UseSSL = $true
            QuietHours = $true
            QuietStart = "18:00"
            QuietEnd = "08:00"
        }
        Deployment = @{
            Stages = @('Pilot', 'Phase1', 'Phase2', 'Production')
            SuccessThreshold = 0.9
            WarningMinutes = @(60, 30, 15, 5)
            MaxRetries = 3
        }
        Security = @{
            RequireSSL = $true
            ValidateCertificates = $true
            MaxLoginAttempts = 3
            SessionTimeoutMinutes = 30
        }
        Performance = @{
            MaxConcurrentOperations = 10
            TimeoutSeconds = 300
            RetryDelaySeconds = 5
        }
    }
}

Export-ModuleMember -Function @(
    'Initialize-ScriptConfiguration',
    'Get-ScriptConfiguration',
    'Set-ScriptConfiguration',
    'Save-ScriptConfiguration',
    'Get-DefaultConfiguration'
)
