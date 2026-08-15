# Requires Pester

Describe 'RebootReminder-Detection.ps1' {
    BeforeAll {
        . (Join-Path $PSScriptRoot 'Import-ScriptFunctions.ps1') -ScriptPath (Join-Path $PSScriptRoot '..\RebootReminder\RebootReminder-Detection.ps1')
    }

    Describe 'Test-RebootCompliance' {
        It 'returns True when uptime exceeds the limit' {
            Test-RebootCompliance -UptimeDays 8.5 -DaysLimit 7 | Should -BeTrue
        }

        It 'returns True when uptime equals the limit' {
            Test-RebootCompliance -UptimeDays 7 -DaysLimit 7 | Should -BeTrue
        }

        It 'returns False when uptime is within the limit' {
            Test-RebootCompliance -UptimeDays 3.2 -DaysLimit 7 | Should -BeFalse
        }

        It 'returns False at the boundary just under the limit' {
            Test-RebootCompliance -UptimeDays 6.9 -DaysLimit 7 | Should -BeFalse
        }

        It 'honours a custom DaysLimit' {
            Test-RebootCompliance -UptimeDays 5 -DaysLimit 30 | Should -BeFalse
            Test-RebootCompliance -UptimeDays 31 -DaysLimit 30 | Should -BeTrue
        }
    }
}
