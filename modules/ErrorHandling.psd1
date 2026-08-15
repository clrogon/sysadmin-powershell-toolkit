@{
    RootModule        = 'ErrorHandling.psm1'
    ModuleVersion     = '3.0.0'
    GUID              = '2f342cca-fa99-482a-bcd7-d73a071a0477'
    Author            = 'Cláudio Gonçalves'
    CompanyName       = ''
    Copyright         = '(c) Cláudio Gonçalves. All rights reserved.'
    Description       = 'Unified error handling for sysadmin-powershell-toolkit scripts. Importing this module pulls in Configuration and Logging and re-exports the full framework contract.'
    PowerShellVersion = '5.1'
    CompatiblePSEditions = @('Desktop', 'Core')
    FunctionsToExport = @(
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
    CmdletsToExport   = @()
    VariablesToExport = @()
    AliasesToExport   = @()
    PrivateData       = @{
        PSData = @{
            Tags       = @('ErrorHandling', 'SysAdmin', 'PSEdition_Desktop', 'PSEdition_Core')
            ProjectUri = 'https://github.com/clrogon/sysadmin-powershell-toolkit'
        }
    }
}
