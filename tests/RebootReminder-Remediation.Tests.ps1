# Requires Pester

Describe 'RebootReminder-Remediation.ps1' {
    BeforeAll {
        . (Join-Path $PSScriptRoot 'Import-ScriptFunctions.ps1') -ScriptPath (Join-Path $PSScriptRoot '..\RebootReminder\RebootReminder-Remediation.ps1')
    }

    Describe 'Test-IsWeekend' {
        It 'returns True on a Saturday' {
            Mock Get-Date { [DateTime]::new(2026, 8, 15, 12, 0, 0) }
            Test-IsWeekend | Should -BeTrue
        }

        It 'returns True on a Sunday' {
            Mock Get-Date { [DateTime]::new(2026, 8, 16, 12, 0, 0) }
            Test-IsWeekend | Should -BeTrue
        }

        It 'returns False on a weekday' {
            Mock Get-Date { [DateTime]::new(2026, 8, 14, 12, 0, 0) }
            Test-IsWeekend | Should -BeFalse
        }
    }

    Describe 'Test-IsWorkHours' {
        It 'returns True within work hours' {
            Mock Get-Date { [DateTime]::new(2026, 8, 14, 10, 0, 0) }
            Test-IsWorkHours | Should -BeTrue
        }

        It 'returns False before work hours' {
            Mock Get-Date { [DateTime]::new(2026, 8, 14, 7, 0, 0) }
            Test-IsWorkHours | Should -BeFalse
        }

        It 'returns False after work hours' {
            Mock Get-Date { [DateTime]::new(2026, 8, 14, 18, 0, 0) }
            Test-IsWorkHours | Should -BeFalse
        }

        It 'returns True at the start boundary (08:00)' {
            Mock Get-Date { [DateTime]::new(2026, 8, 14, 8, 0, 0) }
            Test-IsWorkHours | Should -BeTrue
        }

        It 'returns False at the end boundary (17:00)' {
            Mock Get-Date { [DateTime]::new(2026, 8, 14, 17, 0, 0) }
            Test-IsWorkHours | Should -BeFalse
        }
    }

    Describe 'Write-Log' {
        It 'writes a timestamped line to the log file' {
            Mock Write-Host { }
            Mock Out-File { }
            Write-Log -Message 'Unit test message' -Level 'INFO'
            Should -Invoke Out-File -Times 1 -Exactly
        }

        It 'defaults the level to INFO' {
            Mock Write-Host { }
            Mock Out-File { }
            Write-Log -Message 'No level provided'
            Should -Invoke Out-File -Times 1 -Exactly
        }
    }
}
