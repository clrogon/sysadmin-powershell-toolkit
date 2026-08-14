# Requires Pester
Import-Module (Join-Path $PSScriptRoot '..\modules\Logging.psm1') -Force
Import-Module (Join-Path $PSScriptRoot '..\modules\Configuration.psm1') -Force

Describe 'Logging module' {
    BeforeAll {
        $script:testLog = Join-Path $env:TEMP 'PowerShellScripts_Test_Logging.log'
        if (Test-Path $script:testLog) { Remove-Item $script:testLog -Force -ErrorAction SilentlyContinue }

        Initialize-ScriptConfiguration -ConfigPath (Join-Path $env:TEMP 'PowerShellScripts_Test_Config.xml') -DefaultConfig (Get-DefaultConfiguration)
        Initialize-Logging -LogPath $script:testLog -Component 'LoggingTests'
    }

    It 'Writes a log entry and returns a structured object' {
        $entry = Write-ScriptLog -Level Info -Message 'Test log entry' -NoConsole -NoEventLog
        $entry | Should -BeOfType PSCustomObject
        $entry.Level | Should -Be 'Info'
        $entry.Message | Should -Be 'Test log entry'
        $entry.Component | Should -Be 'LoggingTests'
        $entry.ComputerName | Should -Be $env:COMPUTERNAME
    }

    It 'Appends the entry to the CSV log file' {
        Write-ScriptLog -Level Warning -Message 'Second entry' -NoConsole -NoEventLog
        $lines = Get-Content $script:testLog
        $lines.Count | Should -BeGreaterOrEqual 2
        $last = $lines[-1]
        $last | Should -Match 'Warning'
        $last | Should -Match 'Second entry'
    }

    It 'CSV log file can be parsed with Import-Csv' {
        $rows = Import-Csv $script:testLog
        $rows | Should -Not -BeNullOrEmpty
        $rows[0].Level | Should -Be 'Info'
    }

    It 'Get-LogSummary reports counts' {
        $summary = Get-LogSummary -LogPath $script:testLog -StartDate (Get-Date).AddDays(-1)
        $summary | Should -Not -BeNullOrEmpty
        $summary.TotalEntries | Should -BeGreaterOrEqual 2
        $summary.WarningCount | Should -BeGreaterOrEqual 1
    }

    It 'Log rotation archives an oversized log file' {
        $rotationLog = Join-Path $env:TEMP 'PowerShellScripts_Test_Rotation.log'
        if (Test-Path $rotationLog) { Remove-Item $rotationLog -Force -ErrorAction SilentlyContinue }

        Set-ScriptConfiguration -Key 'Logging' -Value @{
            DefaultPath   = "$env:ProgramData\PowerShellScripts\Logs"
            MaxSize       = 2KB
            RetentionDays = 30
        } -ConfigPath (Join-Path $env:TEMP 'PowerShellScripts_Test_Config.xml')

        Initialize-Logging -LogPath $rotationLog -Component 'RotationTests'

        $bigLine = 'X' * 500
        for ($i = 0; $i -lt 20; $i++) {
            Write-ScriptLog -Level Info -Message $bigLine -NoConsole -NoEventLog
        }

        Check-LogRotation -LogPath $rotationLog

        $backups = @(Get-ChildItem "$rotationLog.*" -ErrorAction SilentlyContinue)
        $backups.Count | Should -BeGreaterOrEqual 1
        $backups[0].Length | Should -BeGreaterOrEqual 2KB

        if (Test-Path $rotationLog) {
            Remove-Item $rotationLog -Force
        }
    }

    It 'Transaction lifecycle logs start and completion' {
        Initialize-Logging -LogPath $script:testLog -Component 'LoggingTests'

        Start-LogTransaction -TransactionName 'TestTransaction'
        Add-LogTransactionStep -StepName 'StepOne'
        Complete-LogTransaction -Status 'Completed'

        $summary = Get-LogSummary -LogPath $script:testLog -StartDate (Get-Date).AddDays(-1)
        $summary.TotalEntries | Should -BeGreaterOrEqual 3
    }
}
