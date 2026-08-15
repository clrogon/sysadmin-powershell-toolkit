# Requires Pester
Import-Module (Join-Path $PSScriptRoot '..\modules\ErrorHandling') -Force

Describe 'USBPortManagement.ps1' {
    BeforeAll {
        . (Join-Path $PSScriptRoot 'Import-ScriptFunctions.ps1') -ScriptPath (Join-Path $PSScriptRoot '..\USBPortManagement\USBPortManagement.ps1')
        Mock Write-ScriptLog { }

        $script:deviceWhitelist = @{
            AllowedDevices = @()
        }

        $script:usbPolicies = @{
            SecurityLevel = @{
                High = @{
                    EnableUSBStorage = $false
                    AllowRemovableMedia = $false
                    RequireEncryption = $true
                    LogAllEvents = $true
                    WhitelistMode = $true
                }
                Medium = @{
                    EnableUSBStorage = $true
                    AllowRemovableMedia = $true
                    RequireEncryption = $false
                    LogAllEvents = $true
                    WhitelistMode = $false
                }
                Low = @{
                    EnableUSBStorage = $true
                    AllowRemovableMedia = $true
                    RequireEncryption = $false
                    LogAllEvents = $false
                    WhitelistMode = $false
                }
            }
        }
    }

    Describe 'Set-USBAccessSchedule' {
        It 'returns a schedule with default values' {
            Mock Export-Clixml { }
            $schedule = Set-USBAccessSchedule
            $schedule.AllowedStart | Should -Be ([TimeSpan]::Parse('09:00'))
            $schedule.AllowedEnd | Should -Be ([TimeSpan]::Parse('17:00'))
            $schedule.AllowedDays.Count | Should -Be 5
        }

        It 'returns the requested schedule values' {
            Mock Export-Clixml { }
            $schedule = Set-USBAccessSchedule -AllowedStart '08:30' -AllowedEnd '18:00' -AllowedDays @('Monday', 'Friday')
            $schedule.AllowedStart | Should -Be ([TimeSpan]::Parse('08:30'))
            $schedule.AllowedEnd | Should -Be ([TimeSpan]::Parse('18:00'))
            $schedule.AllowedDays | Should -Be @([DayOfWeek]::Monday, [DayOfWeek]::Friday)
        }

        It 'persists the schedule to disk' {
            Mock Export-Clixml { }
            Set-USBAccessSchedule
            Should -Invoke Export-Clixml -Times 1 -Exactly
        }
    }

    Describe 'Test-USBAccessAllowed' {
        It 'allows access when no schedule file exists' {
            Mock Test-Path { $false }
            Test-USBAccessAllowed | Should -BeTrue
        }

        It 'blocks access on a day outside the schedule' {
            Mock Test-Path { $true }
            Mock Get-Date { [DateTime]::new(2026, 8, 15, 12, 0, 0) }
            Mock Import-Clixml {
                [PSCustomObject]@{
                    AllowedStart = [TimeSpan]::Parse('09:00')
                    AllowedEnd = [TimeSpan]::Parse('17:00')
                    AllowedDays = @([DayOfWeek]::Monday, [DayOfWeek]::Tuesday)
                }
            }
            Test-USBAccessAllowed | Should -BeFalse
        }

        It 'blocks access outside the allowed time window' {
            Mock Test-Path { $true }
            Mock Get-Date { [DateTime]::new(2026, 8, 10, 18, 0, 0) }
            Mock Import-Clixml {
                [PSCustomObject]@{
                    AllowedStart = [TimeSpan]::Parse('09:00')
                    AllowedEnd = [TimeSpan]::Parse('17:00')
                    AllowedDays = @([DayOfWeek]::Monday)
                }
            }
            Test-USBAccessAllowed | Should -BeFalse
        }

        It 'allows access within the schedule' {
            Mock Test-Path { $true }
            Mock Get-Date { [DateTime]::new(2026, 8, 10, 12, 0, 0) }
            Mock Import-Clixml {
                [PSCustomObject]@{
                    AllowedStart = [TimeSpan]::Parse('09:00')
                    AllowedEnd = [TimeSpan]::Parse('17:00')
                    AllowedDays = @([DayOfWeek]::Monday)
                }
            }
            Test-USBAccessAllowed | Should -BeTrue
        }
    }

    Describe 'Test-USBDeviceAllowed' {
        It 'allows any device when no whitelist exists' {
            Mock Test-Path { $false }
            Test-USBDeviceAllowed -DeviceID 'USB\VID_1234&PID_5678' | Should -BeTrue
        }

        It 'allows a device present in the whitelist' {
            Mock Test-Path { $true }
            Mock Import-Clixml {
                [PSCustomObject]@{ AllowedDevices = @('USB\VID_1234&PID_5678', 'USB\VID_9999') }
            }
            Test-USBDeviceAllowed -DeviceID 'USB\VID_1234&PID_5678' | Should -BeTrue
        }

        It 'blocks a device absent from the whitelist' {
            Mock Test-Path { $true }
            Mock Import-Clixml {
                [PSCustomObject]@{ AllowedDevices = @('USB\VID_1234&PID_5678') }
            }
            Test-USBDeviceAllowed -DeviceID 'USB\VID_0000' | Should -BeFalse
        }
    }

    Describe 'Add/Remove-USBDeviceWhitelist' {
        It 'adds a device to the whitelist' {
            Mock Export-Clixml { }
            $script:deviceWhitelist.AllowedDevices = @('USB\VID_OLD')
            Add-USBDeviceWhitelist -DeviceID 'USB\VID_NEW'
            $script:deviceWhitelist.AllowedDevices | Should -Contain 'USB\VID_NEW'
        }

        It 'removes a device from the whitelist' {
            Mock Export-Clixml { }
            $script:deviceWhitelist.AllowedDevices = @('USB\VID_A', 'USB\VID_B')
            Remove-USBDeviceWhitelist -DeviceID 'USB\VID_A'
            $script:deviceWhitelist.AllowedDevices | Should -Not -Contain 'USB\VID_A'
            $script:deviceWhitelist.AllowedDevices | Should -Contain 'USB\VID_B'
        }
    }

    Describe 'Set-USBPolicy' {
        It 'writes Start=4 for High security level' {
            Mock Set-ItemProperty { }
            Mock Export-Clixml { }
            Set-USBPolicy -SecurityLevel High
            Should -Invoke Set-ItemProperty -Times 1 -Exactly -ParameterFilter {
                $Path -like 'HKLM:\SYSTEM\CurrentControlSet\Services\USBSTOR' -and
                $Name -eq 'Start' -and
                $Value -eq 4
            }
        }

        It 'writes Start=3 for Medium security level' {
            Mock Set-ItemProperty { }
            Mock Export-Clixml { }
            Set-USBPolicy -SecurityLevel Medium
            Should -Invoke Set-ItemProperty -Times 1 -Exactly -ParameterFilter {
                $Path -like 'HKLM:\SYSTEM\CurrentControlSet\Services\USBSTOR' -and
                $Name -eq 'Start' -and
                $Value -eq 3
            }
        }

        It 'does not apply policy immediately by default' {
            Mock Set-ItemProperty { }
            Mock Export-Clixml { }
            Mock Apply-USBPolicy { }
            Set-USBPolicy -SecurityLevel Low
            Should -Invoke Apply-USBPolicy -Times 0 -Exactly
        }
    }

    Describe 'Get-USBPolicyStatus' {
        It 'returns null when no policy file exists' {
            Mock Test-Path { $false }
            Get-USBPolicyStatus | Should -BeNullOrEmpty
        }

        It 'identifies a High policy' {
            Mock Test-Path { $true }
            Mock Import-Clixml {
                [PSCustomObject]@{
                    EnableUSBStorage = $false
                    AllowRemovableMedia = $false
                    RequireEncryption = $true
                }
            }
            $status = Get-USBPolicyStatus
            $status.SecurityLevel | Should -Be 'High'
        }

        It 'identifies a Medium policy' {
            Mock Test-Path { $true }
            Mock Import-Clixml {
                [PSCustomObject]@{
                    EnableUSBStorage = $true
                    AllowRemovableMedia = $true
                    RequireEncryption = $false
                }
            }
            $status = Get-USBPolicyStatus
            $status.SecurityLevel | Should -Be 'Medium'
        }

        It 'returns null for an unrecognised policy' {
            Mock Test-Path { $true }
            Mock Import-Clixml {
                [PSCustomObject]@{
                    EnableUSBStorage = $false
                    AllowRemovableMedia = $true
                }
            }
            Get-USBPolicyStatus | Should -BeNullOrEmpty
        }
    }

    Describe 'Get-USBDeviceEvents' {
        It 'maps event ID 2003 to USBInserted and extracts the device ID' {
            Mock Get-WinEvent {
                [PSCustomObject]@{
                    Id = 2003
                    TimeCreated = [DateTime]::new(2026, 8, 10, 10, 0, 0)
                    Message = 'Device inserted. Device ID: USB\VID_1234&PID_5678\Serial123'
                    MachineName = 'PC-01'
                    UserId = 'S-1-5-21-1'
                }
            }
            $events = @(Get-USBDeviceEvents)
            $events.Count | Should -Be 1
            $events[0].EventType | Should -Be 'USBInserted'
            $events[0].DeviceID | Should -Be 'USB\VID_1234&PID_5678\Serial123'
        }

        It 'maps event ID 2004 to USBRemoved' {
            Mock Get-WinEvent {
                [PSCustomObject]@{
                    Id = 2004
                    TimeCreated = [DateTime]::new(2026, 8, 10, 11, 0, 0)
                    Message = 'Device removed. Device ID: USB\VID_9999&PID_0000\SerialABC'
                    MachineName = 'PC-01'
                    UserId = 'S-1-5-21-2'
                }
            }
            $events = @(Get-USBDeviceEvents)
            $events[0].EventType | Should -Be 'USBRemoved'
        }

        It 'returns an empty array when no events are found' {
            Mock Get-WinEvent { }
            $events = Get-USBDeviceEvents
            @($events).Count | Should -Be 0
        }
    }

    Describe 'Get-PhysicalDiskInfo' {
        It 'returns null when no partition is associated with the drive' {
            Mock Get-CimInstance { $null } -ParameterFilter { $Query -like '*Win32_LogicalDiskToPartition*' }
            Get-PhysicalDiskInfo -DriveLetter 'D:' | Should -BeNullOrEmpty
        }

        It 'returns the PNPDeviceID of the parent disk' {
            Mock Get-CimInstance {
                [PSCustomObject]@{ DeviceID = 'Disk #0, Partition #0' }
            } -ParameterFilter { $Query -like '*Win32_LogicalDiskToPartition*' }
            Mock Get-CimInstance {
                [PSCustomObject]@{ PNPDeviceID = 'USB\VID_1234&PID_5678\DiskSerial' }
            } -ParameterFilter { $Query -like '*Win32_DiskDriveToDiskPartition*' }
            Get-PhysicalDiskInfo -DriveLetter 'D:' | Should -Be 'USB\VID_1234&PID_5678\DiskSerial'
        }

        It 'returns null when the CIM query fails' {
            Mock Get-CimInstance { throw 'Access denied' } -ParameterFilter { $Query -like '*Win32_LogicalDiskToPartition*' }
            Get-PhysicalDiskInfo -DriveLetter 'D:' | Should -BeNullOrEmpty
        }
    }
}
