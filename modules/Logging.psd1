@{
    RootModule        = 'Logging.psm1'
    ModuleVersion     = '3.0.0'
    GUID              = 'bf088250-75f8-4a36-80a1-aa3c7fa914e4'
    Author            = 'Cláudio Gonçalves'
    CompanyName       = ''
    Copyright         = '(c) Cláudio Gonçalves. All rights reserved.'
    Description       = 'Unified logging for sysadmin-powershell-toolkit scripts: multi-output (console, CSV file, event log), rotation, transactions, searchable summaries.'
    PowerShellVersion = '5.1'
    CompatiblePSEditions = @('Desktop', 'Core')
    FunctionsToExport = @(
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
    CmdletsToExport   = @()
    VariablesToExport = @()
    AliasesToExport   = @()
    PrivateData       = @{
        PSData = @{
            Tags       = @('Logging', 'SysAdmin', 'PSEdition_Desktop', 'PSEdition_Core')
            ProjectUri = 'https://github.com/clrogon/sysadmin-powershell-toolkit'
        }
    }
}
