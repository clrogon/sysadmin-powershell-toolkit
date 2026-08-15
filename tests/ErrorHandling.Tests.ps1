# Requires Pester
Import-Module (Join-Path $PSScriptRoot '..\modules\ErrorHandling') -Force

Describe 'ErrorHandling module' {
    BeforeAll {
        Initialize-ScriptConfiguration -ConfigPath (Join-Path ([System.IO.Path]::GetTempPath()) 'PowerShellScripts_Test_Config.xml') -DefaultConfig (Get-DefaultConfiguration)
        Initialize-Logging -LogPath (Join-Path ([System.IO.Path]::GetTempPath()) 'PowerShellScripts_Test_ErrorHandling.log') -Component 'ErrorHandlingTests'
    }

    It 'Test-AdministrativePrivileges returns a boolean' {
        $result = Test-AdministrativePrivileges
        $result | Should -BeOfType [bool]
    }

    It 'Invoke-RetryCommand succeeds on valid script block' {
        $result = Invoke-RetryCommand -ScriptBlock { 2 + 2 } -MaxRetries 1 -RetryDelaySeconds 0
        $result | Should -Be 4
    }

    It 'Invoke-RetryCommand throws after exhausting retries' {
        { Invoke-RetryCommand -ScriptBlock { throw 'boom' } -MaxRetries 2 -RetryDelaySeconds 0 } | Should -Throw
    }

    It 'Get-ScriptStackTrace returns a string from an error record' {
        try {
            throw 'test error'
        }
        catch {
            $trace = Get-ScriptStackTrace -ErrorRecord $_
            $trace | Should -Not -BeNullOrEmpty
            $trace | Should -BeOfType [string]
        }
    }

    It 'Test-NetworkConnectivity returns a structured result' {
        $result = Test-NetworkConnectivity -ComputerName 'localhost' -Count 1
        $result | Should -BeOfType PSCustomObject
        $result.Connected | Should -BeOfType [bool]
        $result.PacketsSent | Should -Be 1
        $result.PacketsReceived | Should -BeGreaterOrEqual 0
    }

    It 'Invoke-GracefulShutdown without -Force does not shut down' {
        { Invoke-GracefulShutdown -ComputerName $env:COMPUTERNAME -Reason 'Test' -DelaySeconds 0 } |
            Should -Not -Throw
    }
}
