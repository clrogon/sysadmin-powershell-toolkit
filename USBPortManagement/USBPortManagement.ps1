<#
.SYNOPSIS
    USB Port and Storage Card Management Tool.

.DESCRIPTION
    A graphical tool (and command-line action set) for managing USB storage and
    storage card access on Windows. Includes enabling/disabling access, live
    status refresh, event-log auditing, device whitelisting, time-based access
    control, and policy-based management (High/Medium/Low).

.EXAMPLE
    .\USBPortManagement.ps1
    Launches the GUI.

.EXAMPLE
    .\USBPortManagement.ps1 -LogUserActions -SecurityLevel High -ApplyPolicy High
    Applies the High security policy immediately and exits.

.EXAMPLE
    .\USBPortManagement.ps1 -NoGUI
    Prints the current USB status and exits without launching the GUI.

.NOTES
    Version: 3.0
    Author: Claudio Gonçalves
#>

#Requires -Version 5.1

[CmdletBinding()]
param(
    [switch]$LogUserActions,
    [ValidateSet('High', 'Medium', 'Low')]
    [string]$SecurityLevel = 'Medium',
    [ValidateSet('High', 'Medium', 'Low')]
    [string]$ApplyPolicy,
    [switch]$NoGUI
)

Import-Module "$PSScriptRoot\..\modules\ErrorHandling.psm1" -Force

Initialize-ScriptConfiguration -DefaultConfig (Get-DefaultConfiguration)
Initialize-Logging -Component "USBPortManagement"

function Write-EventLogEntry {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)]
        [string]$eventSource,
        [Parameter(Mandatory=$true)]
        [string]$logName,
        [Parameter(Mandatory=$true)]
        [int]$eventID,
        [Parameter(Mandatory=$true)]
        [System.Diagnostics.EventLogEntryType]$entryType,
        [Parameter(Mandatory=$true)]
        [string]$message
    )

    if (-not [System.Diagnostics.EventLog]::SourceExists($eventSource)) {
        try {
            [System.Diagnostics.EventLog]::CreateEventSource($eventSource, $logName)
            Start-Sleep -Seconds 2
        }
        catch {
            Write-ScriptLog -Level Warning -Message "Failed to create event source '$eventSource': $($_.Exception.Message)"
            return
        }
    }

    try {
        [System.Diagnostics.EventLog]::WriteEntry($eventSource, $message, $entryType, $eventID)
    }
    catch {
        Write-ScriptLog -Level Warning -Message "Failed to write event log entry: $($_.Exception.Message)"
    }
}

function Show-BalloonTip {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)]
        [string]$Title,
        [Parameter(Mandatory=$true)]
        [string]$Text,
        [ValidateSet('None', 'Info', 'Warning', 'Error')]
        [string]$Icon = 'Info',
        [int]$Timeout = 10000
    )

    process {
        Add-Type -AssemblyName System.Windows.Forms
        Add-Type -AssemblyName System.Drawing

        if ($null -eq $script:PopUp) {
            $script:PopUp = New-Object System.Windows.Forms.NotifyIcon
        }

        $script:PopUp.Icon = [System.Drawing.SystemIcons]::Information
        $script:PopUp.BalloonTipIcon = $Icon
        $script:PopUp.BalloonTipText = $Text
        $script:PopUp.BalloonTipTitle = $Title
        $script:PopUp.Visible = $true
        $script:PopUp.ShowBalloonTip($Timeout)

        Start-Sleep -Milliseconds $Timeout
        $script:PopUp.Visible = $false
        $script:PopUp.Dispose()
        $script:PopUp = $null
    }
}

function Refresh-Status {
    try {
        $usbStatus = (Get-ItemProperty "HKLM:\SYSTEM\CurrentControlSet\Services\USBSTOR").Start
        if ($null -ne $usbStatusLabel) {
            $usbStatusLabel.Text = "USB Storage Status: " + $(if ($usbStatus -eq 3) { "Enabled" } else { "Disabled" })
            $usbStatusLabel.ForeColor = $(if ($usbStatus -eq 3) { [System.Drawing.Color]::Green } else { [System.Drawing.Color]::Red })
        }
    }
    catch {
        if ($null -ne $usbStatusLabel) {
            $usbStatusLabel.Text = "USB Storage Status: Check Failed"
            $usbStatusLabel.ForeColor = [System.Drawing.Color]::Yellow
        }
        Write-EventLogEntry -eventSource "USBManagementTool" -logName "Application" -eventID 2000 -entryType "Error" -message "Failed to check USB storage status."
    }

    try {
        $path = "HKLM:\SOFTWARE\Microsoft\PolicyManager\current\device\System"
        $name = "AllowStorageCard"
        $storageCardValue = (Get-ItemProperty -Path $path -Name $name -ErrorAction SilentlyContinue).$name
        if ($null -ne $storageCardStatusLabel) {
            $storageCardStatusLabel.Text = "Storage Card Status: " + $(if ($storageCardValue -eq 1) { "Allowed" } else { "Not Allowed" })
            $storageCardStatusLabel.ForeColor = $(if ($storageCardValue -eq 1) { [System.Drawing.Color]::Green } else { [System.Drawing.Color]::Red })
        }
    }
    catch {
        if ($null -ne $storageCardStatusLabel) {
            $storageCardStatusLabel.Text = "Storage Card Status: Check Failed"
            $storageCardStatusLabel.ForeColor = [System.Drawing.Color]::Yellow
        }
        Write-EventLogEntry -eventSource "USBManagementTool" -logName "Application" -eventID 2001 -entryType "Error" -message "Failed to check Storage Card status."
    }
}

function Enable-USBStorageAccess {
    try {
        $usbStatus = (Get-ItemProperty "HKLM:\SYSTEM\CurrentControlSet\Services\USBSTOR").Start
        $beforeState = $(if ($usbStatus -eq 3) { "Enabled" } else { "Disabled" })

        if ($usbStatus -eq 3) {
            $message = "USB storage devices are already enabled."
        }
        else {
            Set-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Services\USBSTOR" -Name "Start" -Value 3
            $message = "USB storage devices have been enabled."

            $logMessage = "USB storage devices state changed from $beforeState to Enabled"
            if ($LogUserActions) {
                $logMessage += " by user $env:USERNAME"
            }
            Write-EventLogEntry -eventSource "USBManagementTool" -logName "Application" -eventID 1002 -entryType "Information" -message $logMessage
        }

        if ($null -ne $form) {
            [System.Windows.Forms.MessageBox]::Show($message, "Success", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Information)
        }
        Refresh-Status
    }
    catch {
        $errorMessage = "An error occurred while enabling USB storage devices: $($_.Exception.Message)"
        if ($null -ne $form) {
            [System.Windows.Forms.MessageBox]::Show($errorMessage, "Error", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Error)
        }
        Write-EventLogEntry -eventSource "USBManagementTool" -logName "Application" -eventID 1003 -entryType "Error" -message $errorMessage
    }
}

function Disable-USBStorageAccess {
    try {
        $usbStatus = (Get-ItemProperty "HKLM:\SYSTEM\CurrentControlSet\Services\USBSTOR").Start
        $scStatus = (Get-Service SCPolicySvc -ErrorAction SilentlyContinue).StartType

        $alreadyDisabled = ($usbStatus -eq 4 -and $scStatus -eq 'Disabled')
        $beforeState = $(if ($alreadyDisabled) { "already disabled" } else { "enabled" })

        if ($alreadyDisabled) {
            $message = "USB storage and storage cards are already disabled."
        }
        else {
            Set-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Services\USBSTOR" -Name "Start" -Value 4
            Set-Service SCPolicySvc -StartupType Disabled -ErrorAction SilentlyContinue
            Stop-Service SCPolicySvc -Force -ErrorAction SilentlyContinue
            $message = "USB storage and storage cards have been disabled."
        }

        if ($null -ne $form) {
            [System.Windows.Forms.MessageBox]::Show($message, "Information", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Information)
        }

        $logMessage = "USB storage access and storage cards were $beforeState. $message"
        if ($LogUserActions) {
            $logMessage += " by user $env:USERNAME"
        }
        $eventID = if ($alreadyDisabled) { 1003 } else { 1001 }
        Write-EventLogEntry -eventSource "USBManagementTool" -logName "Application" -eventID $eventID -entryType "Warning" -message $logMessage

        Refresh-Status
    }
    catch {
        $errorMessage = "An error occurred while disabling USB storage devices: $($_.Exception.Message)"
        if ($null -ne $form) {
            [System.Windows.Forms.MessageBox]::Show($errorMessage, "Error", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Error)
        }
        Write-EventLogEntry -eventSource "USBManagementTool" -logName "Application" -eventID 1002 -entryType "Error" -message $errorMessage
    }
}

function Enable-StorageCard {
    try {
        $path = "HKLM:\SOFTWARE\Microsoft\PolicyManager\current\device\System"
        $name = "AllowStorageCard"
        $currentValue = (Get-ItemProperty -Path $path -Name $name -ErrorAction Stop).$name
        $beforeState = $(if ($currentValue -eq 1) { "already enabled" } else { "disabled" })

        if ($currentValue -eq 1) {
            $message = "Storage Card usage is already enabled."
        }
        else {
            Set-ItemProperty -Path $path -Name $name -Value 1
            $message = "Storage Card usage has been enabled."
        }

        if ($null -ne $form) {
            [System.Windows.Forms.MessageBox]::Show($message, "Information", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Information)
        }

        $logMessage = "Storage Card usage was $beforeState. $message"
        if ($LogUserActions) {
            $logMessage += " by user $env:USERNAME"
        }
        $eventID = if ($currentValue -eq 1) { 1004 } else { 1005 }
        Write-EventLogEntry -eventSource "USBManagementTool" -logName "Application" -eventID $eventID -entryType "Information" -message $logMessage

        Refresh-Status
    }
    catch {
        $errorMessage = "Failed to modify Storage Card usage setting: $($_.Exception.Message)"
        if ($null -ne $form) {
            [System.Windows.Forms.MessageBox]::Show($errorMessage, "Error", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Error)
        }
        Write-EventLogEntry -eventSource "USBManagementTool" -logName "Application" -eventID 1006 -entryType "Error" -message $errorMessage
    }
}

function Disable-StorageCard {
    try {
        $path = "HKLM:\SOFTWARE\Microsoft\PolicyManager\current\device\System"
        $name = "AllowStorageCard"
        $currentValue = (Get-ItemProperty -Path $path -Name $name -ErrorAction Stop).$name
        $beforeState = $(if ($currentValue -eq 0) { "already disabled" } else { "enabled" })

        if ($currentValue -eq 0) {
            $message = "Storage Card usage is already disabled."
        }
        else {
            Set-ItemProperty -Path $path -Name $name -Value 0
            $message = "Storage Card usage has been disabled."
        }

        if ($null -ne $form) {
            [System.Windows.Forms.MessageBox]::Show($message, "Information", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Information)
        }

        $logMessage = "Storage Card usage was $beforeState. $message"
        if ($LogUserActions) {
            $logMessage += " by user $env:USERNAME"
        }
        $eventID = if ($currentValue -eq 0) { 1007 } else { 1008 }
        Write-EventLogEntry -eventSource "USBManagementTool" -logName "Application" -eventID $eventID -entryType "Information" -message $logMessage

        Refresh-Status
    }
    catch {
        $errorMessage = "Failed to modify Storage Card usage setting: $($_.Exception.Message)"
        if ($null -ne $form) {
            [System.Windows.Forms.MessageBox]::Show($errorMessage, "Error", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Error)
        }
        Write-EventLogEntry -eventSource "USBManagementTool" -logName "Application" -eventID 1009 -entryType "Error" -message $errorMessage
    }
}

#region Policy and Device Management Functions

$script:deviceWhitelist = @{
    AllowedDevices = @()
}

function Set-USBAccessSchedule {
    [CmdletBinding()]
    param(
        [TimeSpan]$AllowedStart = "09:00",
        [TimeSpan]$AllowedEnd = "17:00",
        [DayOfWeek[]]$AllowedDays = @('Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday')
    )

    $schedule = @{
        AllowedStart = $AllowedStart
        AllowedEnd = $AllowedEnd
        AllowedDays = $AllowedDays
    }

    $schedule | Export-Clixml "$env:ProgramData\PowerShellScripts\USBAccessSchedule.xml" -Force

    Write-ScriptLog -Level Info -Message "USB access schedule configured"

    return $schedule
}

function Test-USBAccessAllowed {
    [CmdletBinding()]
    param()

    $schedulePath = "$env:ProgramData\PowerShellScripts\USBAccessSchedule.xml"

    if (-not (Test-Path $schedulePath)) {
        return $true
    }

    $now = Get-Date
    $schedule = Import-Clixml $schedulePath

    if ($schedule.AllowedDays -notcontains $now.DayOfWeek) {
        Write-ScriptLog -Level Warning -Message "USB access not allowed on $($now.DayOfWeek)"
        return $false
    }

    if ($now.TimeOfDay -lt $schedule.AllowedStart -or $now.TimeOfDay -gt $schedule.AllowedEnd) {
        Write-ScriptLog -Level Warning -Message "USB access not allowed at this time"
        return $false
    }

    return $true
}

function Add-USBDeviceWhitelist {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)]
        [string]$DeviceID
    )

    $script:deviceWhitelist.AllowedDevices += $DeviceID
    $script:deviceWhitelist | Export-Clixml "$env:ProgramData\PowerShellScripts\USBDeviceWhitelist.xml" -Force

    Write-ScriptLog -Level Info -Message "Added device to whitelist: $DeviceID"
}

function Remove-USBDeviceWhitelist {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)]
        [string]$DeviceID
    )

    $script:deviceWhitelist.AllowedDevices = @($script:deviceWhitelist.AllowedDevices | Where-Object { $_ -ne $DeviceID })
    $script:deviceWhitelist | Export-Clixml "$env:ProgramData\PowerShellScripts\USBDeviceWhitelist.xml" -Force

    Write-ScriptLog -Level Info -Message "Removed device from whitelist: $DeviceID"
}

function Test-USBDeviceAllowed {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)]
        [string]$DeviceID
    )

    $whitelistPath = "$env:ProgramData\PowerShellScripts\USBDeviceWhitelist.xml"

    if (-not (Test-Path $whitelistPath)) {
        return $true
    }

    $whitelist = Import-Clixml $whitelistPath

    if ($whitelist.AllowedDevices -contains $DeviceID) {
        return $true
    }

    Write-ScriptLog -Level Warning -Message "Blocked unauthorized USB device: $DeviceID"

    return $false
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

function Set-USBPolicy {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)]
        [ValidateSet('High', 'Medium', 'Low')]
        [string]$SecurityLevel,
        [switch]$ApplyNow
    )

    $policy = $script:usbPolicies.SecurityLevel[$SecurityLevel]

    Set-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Services\USBSTOR" -Name "Start" `
        -Value $(if ($policy.EnableUSBStorage) { 3 } else { 4 })

    $policy | Export-Clixml "$env:ProgramData\PowerShellScripts\USBPolicy.xml" -Force

    Write-ScriptLog -Level Info -Message "USB policy set to $SecurityLevel level"

    if ($ApplyNow) {
        Apply-USBPolicy -Policy $policy
    }
}

function Apply-USBPolicy {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)]
        [hashtable]$Policy
    )

    if ($Policy.EnableUSBStorage) {
        Enable-USBStorageAccess
    }
    else {
        Disable-USBStorageAccess
    }

    Write-ScriptLog -Level Info -Message "USB policy applied"
}

function Get-USBDeviceEvents {
    [CmdletBinding()]
    param(
        [DateTime]$StartDate = (Get-Date).AddDays(-7),
        [DateTime]$EndDate = (Get-Date)
    )

    $events = Get-WinEvent -FilterHashtable @{
        LogName = 'System'
        ID = 2003, 2004
        StartTime = $StartDate
        EndTime = $EndDate
    } -ErrorAction SilentlyContinue

    $deviceEvents = @()

    foreach ($evt in @($events)) {
        $deviceEvents += [PSCustomObject]@{
            Timestamp = $evt.TimeCreated
            EventType = if ($evt.Id -eq 2003) { "USBInserted" } else { "USBRemoved" }
            DeviceID = $evt.Message -replace '.*Device ID: ([^\s]+).*', '$1'
            ComputerName = $evt.MachineName
            UserName = $evt.UserId
        }
    }

    return $deviceEvents
}

function Get-PhysicalDiskInfo {
    [CmdletBinding()]
    param(
        [string]$DriveLetter
    )

    try {
        $partition = Get-CimInstance -Query "ASSOCIATORS OF {Win32_LogicalDisk.DeviceID=`"$DriveLetter`"} WHERE AssocClass = Win32_LogicalDiskToPartition" -ErrorAction Stop
        if (-not $partition) {
            return $null
        }

        $disk = Get-CimInstance -Query "ASSOCIATORS OF {Win32_DiskPartition.DeviceID=`"$($partition.DeviceID)`"} WHERE AssocClass = Win32_DiskDriveToDiskPartition" -ErrorAction Stop

        if ($disk) {
            return $disk.PNPDeviceID
        }
    }
    catch {
        Write-ScriptLog -Level Error -Message "Failed to get disk info: $($_.Exception.Message)"
    }

    return $null
}

function Monitor-USBDeviceEvents {
    [CmdletBinding()]
    param(
        [TimeSpan]$MonitoringInterval = "00:05:00"
    )

    Write-ScriptLog -Level Info -Message "Starting USB device event monitoring"

    $query = "SELECT * FROM Win32_VolumeChangeEvent WHERE EventType = 2"

    Register-WmiEvent -Query $query -SourceIdentifier "USBMonitor" -Action {
        $driveLetter = $Event.SourceEventArgs.NewEvent.DriveName
        $deviceId = Get-PhysicalDiskInfo -DriveLetter $driveLetter

        $logEntry = [PSCustomObject]@{
            Timestamp = Get-Date
            EventType = "USBInserted"
            DeviceID = $deviceId
            DriveLetter = $driveLetter
            ComputerName = $env:COMPUTERNAME
            UserName = $env:USERNAME
        }

        $logEntry | Export-Csv "$env:ProgramData\PowerShellScripts\USBDeviceLog.csv" -Append -NoTypeInformation

        if (-not (Test-USBDeviceAllowed -DeviceID $deviceId)) {
            Write-ScriptLog -Level Warning -Message "Blocking unauthorized USB device: $deviceId"

            try {
                Disable-USBStorageAccess
            }
            catch {
                Write-ScriptLog -Level Error -Message "Failed to disable USB storage: $($_.Exception.Message)"
            }
        }
    }

    Write-Host "USB device monitoring active. Press Ctrl+C to stop."
    while ($true) {
        Start-Sleep -Seconds $MonitoringInterval.TotalSeconds
    }
}

function Get-USBPolicyStatus {
    [CmdletBinding()]
    param()

    $policyPath = "$env:ProgramData\PowerShellScripts\USBPolicy.xml"

    if (-not (Test-Path $policyPath)) {
        return $null
    }

    $policy = Import-Clixml $policyPath

    foreach ($level in @('High', 'Medium', 'Low')) {
        $currentPolicy = $script:usbPolicies.SecurityLevel[$level]

        if ($currentPolicy.EnableUSBStorage -eq $policy.EnableUSBStorage -and
            $currentPolicy.AllowRemovableMedia -eq $policy.AllowRemovableMedia) {
            return @{
                SecurityLevel = $level
                Policy = $policy
            }
        }
    }

    return $null
}

function Initialize-USBPolicy {
    [CmdletBinding()]
    param()

    if (-not (Test-Path "$env:ProgramData\PowerShellScripts\USBPolicy.xml")) {
        Set-USBPolicy -SecurityLevel $SecurityLevel
    }

    if (-not (Test-Path "$env:ProgramData\PowerShellScripts\USBDeviceWhitelist.xml")) {
        $script:deviceWhitelist | Export-Clixml "$env:ProgramData\PowerShellScripts\USBDeviceWhitelist.xml" -Force
    }

    if (-not (Test-Path "$env:ProgramData\PowerShellScripts\USBAccessSchedule.xml")) {
        Set-USBAccessSchedule
    }

    Write-ScriptLog -Level Info -Message "USB policy components initialized"
}

#endregion

# ---- Main ----

if (-not (Test-AdministrativePrivileges)) {
    Write-ScriptLog -Level Error -Message "Please run the application as an administrator."
    exit 1
}

$script:form = $null
$script:usbStatusLabel = $null
$script:storageCardStatusLabel = $null

if ($ApplyPolicy) {
    Set-USBPolicy -SecurityLevel $ApplyPolicy -ApplyNow
    Write-Host "USB policy applied: $ApplyPolicy"
    exit 0
}

Initialize-USBPolicy

if ($NoGUI) {
    $usbStatus = (Get-ItemProperty "HKLM:\SYSTEM\CurrentControlSet\Services\USBSTOR").Start
    $usbMessage = if ($usbStatus -eq 3) { "USB Storage: Enabled" } else { "USB Storage: Disabled" }

    $storageCardValue = (Get-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\PolicyManager\current\device\System" -Name "AllowStorageCard" -ErrorAction SilentlyContinue).AllowStorageCard
    $storageCardMessage = if ($storageCardValue -eq 1) { "Storage Card: Allowed" } else { "Storage Card: Not Allowed" }

    Write-Host $usbMessage
    Write-Host $storageCardMessage
    exit 0
}

# ---- GUI mode ----
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

$usbStatus = (Get-ItemProperty "HKLM:\SYSTEM\CurrentControlSet\Services\USBSTOR").Start
$usbMessage = if ($usbStatus -eq 3) { "USB Storage: Enabled" } else { "USB Storage: Disabled" }

try {
    $storageCardValue = (Get-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\PolicyManager\current\device\System" -Name "AllowStorageCard").AllowStorageCard
    $storageCardMessage = if ($storageCardValue -eq 1) { "Storage Card: Allowed" } else { "Storage Card: Not Allowed" }
}
catch {
    $storageCardMessage = "Storage Card: Status Check Failed"
}

$combinedMessage = "$usbMessage`n$storageCardMessage"

Show-BalloonTip -Title "Device Status" -Text $combinedMessage -Icon Info -Timeout 15000

$script:form = New-Object System.Windows.Forms.Form
$script:form.Text = 'USB Port Management'
$script:form.Size = New-Object System.Drawing.Size(400,300)
$script:form.StartPosition = 'CenterScreen'

$label = New-Object System.Windows.Forms.Label
$label.Location = New-Object System.Drawing.Point(10,20)
$label.Size = New-Object System.Drawing.Size(280,20)
$label.Text = 'Select an action for USB ports:'
$script:form.Controls.Add($label)

$script:usbStatusLabel = New-Object System.Windows.Forms.Label
$script:usbStatusLabel.Location = New-Object System.Drawing.Point(10,210)
$script:usbStatusLabel.Size = New-Object System.Drawing.Size(380,20)
$script:form.Controls.Add($script:usbStatusLabel)

$script:storageCardStatusLabel = New-Object System.Windows.Forms.Label
$script:storageCardStatusLabel.Location = New-Object System.Drawing.Point(10,240)
$script:storageCardStatusLabel.Size = New-Object System.Drawing.Size(380,20)
$script:form.Controls.Add($script:storageCardStatusLabel)

$enableButton = New-Object System.Windows.Forms.Button
$enableButton.Location = New-Object System.Drawing.Point(10,50)
$enableButton.Size = New-Object System.Drawing.Size(150,30)
$enableButton.Text = 'Enable USB Storage'
$enableButton.Add_Click({ Enable-USBStorageAccess })
$script:form.Controls.Add($enableButton)

$disableButton = New-Object System.Windows.Forms.Button
$disableButton.Location = New-Object System.Drawing.Point(170,50)
$disableButton.Size = New-Object System.Drawing.Size(150,30)
$disableButton.Text = 'Disable USB Storage'
$disableButton.Add_Click({ Disable-USBStorageAccess })
$script:form.Controls.Add($disableButton)

$enableStorageCardButton = New-Object System.Windows.Forms.Button
$enableStorageCardButton.Location = New-Object System.Drawing.Point(10,170)
$enableStorageCardButton.Size = New-Object System.Drawing.Size(150,30)
$enableStorageCardButton.Text = 'Enable Storage Card'
$enableStorageCardButton.Add_Click({ Enable-StorageCard })
$script:form.Controls.Add($enableStorageCardButton)

$disableStorageCardButton = New-Object System.Windows.Forms.Button
$disableStorageCardButton.Location = New-Object System.Drawing.Point(170,170)
$disableStorageCardButton.Size = New-Object System.Drawing.Size(150,30)
$disableStorageCardButton.Text = 'Disable Storage Card'
$disableStorageCardButton.Add_Click({ Disable-StorageCard })
$script:form.Controls.Add($disableStorageCardButton)

$refreshTimer = New-Object System.Windows.Forms.Timer
$refreshTimer.Interval = 5000
$refreshTimer.Add_Tick({ Refresh-Status })
$refreshTimer.Start()

Refresh-Status

$script:form.ShowDialog()
exit 0
