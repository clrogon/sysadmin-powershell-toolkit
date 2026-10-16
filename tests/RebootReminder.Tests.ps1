# Requires Pester
Import-Module (Join-Path $PSScriptRoot '..\modules\ErrorHandling') -Force

Describe 'RebootReminder.ps1' {
    BeforeAll {
        . (Join-Path $PSScriptRoot 'Import-ScriptFunctions.ps1') -ScriptPath (Join-Path $PSScriptRoot '..\RebootReminder\RebootReminder.ps1')
        $script:WorkStart = 8
        $script:WorkEnd = 17
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
            Mock Get-Date { [DateTime]::new(2026, 8, 14, 12, 0, 0) }
            Test-IsWorkHours | Should -BeTrue
        }

        It 'returns False outside work hours' {
            Mock Get-Date { [DateTime]::new(2026, 8, 14, 19, 0, 0) }
            Test-IsWorkHours | Should -BeFalse
        }

        It 'returns False at or after WorkEnd' {
            Mock Get-Date { [DateTime]::new(2026, 8, 14, 17, 0, 0) }
            Test-IsWorkHours | Should -BeFalse
        }
    }

    Describe 'Get-ReminderButtonSet' {
        It 'offers Restart Now, Remind Me Later, and Dismiss for a normal reminder' {
            (Get-ReminderButtonSet).Keys | Should -Be @('Restart Now', 'Remind Me Later', 'Dismiss')
        }

        It 'omits Remind Me Later for a final warning' {
            (Get-ReminderButtonSet -FinalWarning).Keys | Should -Be @('Restart Now', 'Dismiss')
        }

        It 'always lists Restart Now first so it renders as the primary action' {
            (Get-ReminderButtonSet).Keys | Select-Object -First 1 | Should -Be 'Restart Now'
            (Get-ReminderButtonSet -FinalWarning).Keys | Select-Object -First 1 | Should -Be 'Restart Now'
        }

        It 'maps every button label to a valid action tag' {
            $validActions = @('Restart', 'Snooze', 'Dismiss')
            (Get-ReminderButtonSet).Values | ForEach-Object { $validActions | Should -Contain $_ }
            (Get-ReminderButtonSet -FinalWarning).Values | ForEach-Object { $validActions | Should -Contain $_ }
        }
    }
}

