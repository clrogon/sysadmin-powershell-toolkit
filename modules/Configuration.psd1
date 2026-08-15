@{
    RootModule        = 'Configuration.psm1'
    ModuleVersion     = '3.0.0'
    GUID              = 'bf00572a-8800-4ee9-972d-e9c1cd6f9274'
    Author            = 'Cláudio Gonçalves'
    CompanyName       = ''
    Copyright         = '(c) Cláudio Gonçalves. All rights reserved.'
    Description       = 'Centralized configuration management for sysadmin-powershell-toolkit scripts: default templates, environment overrides, CliXML persistence.'
    PowerShellVersion = '5.1'
    CompatiblePSEditions = @('Desktop', 'Core')
    FunctionsToExport = @(
        'Initialize-ScriptConfiguration',
        'Get-ScriptConfiguration',
        'Set-ScriptConfiguration',
        'Save-ScriptConfiguration',
        'Get-DefaultConfiguration'
    )
    CmdletsToExport   = @()
    VariablesToExport = @()
    AliasesToExport   = @()
    PrivateData       = @{
        PSData = @{
            Tags       = @('Configuration', 'SysAdmin', 'PSEdition_Desktop', 'PSEdition_Core')
            ProjectUri = 'https://github.com/clrogon/sysadmin-powershell-toolkit'
        }
    }
}
