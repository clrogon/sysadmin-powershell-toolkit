<#
.Synopsis
    PowerShell script for Windows 11/Intune reboot reminders with a native pop-up window or toast notifications
.Description
    Enhanced reboot reminder system fully compatible with Windows 11 and Microsoft Intune.
    By default, shows a topmost Windows Forms pop-up window (like the classic Windows Update
    restart prompt) with working Restart/Snooze/Dismiss buttons and an easy-to-close title bar.
    This avoids the reliability problems of toast notifications, which users can silence via
    Focus Assist or per-app notification settings without the script ever knowing. Toast
    notifications (BurntToast, with a native fallback) remain available via -NotificationStyle
    Toast, and are used automatically if the window cannot be displayed.
    Supports user and system context, includes compliance reporting, and works seamlessly
    with Intune Proactive Remediations.
.Example
    .\RebootReminder.ps1 -DaysLimit 7 -IntuneMode
    Runs in Intune-compatible mode with user context notifications
.Example
    .\RebootReminder.ps1 -DaysLimit 7 -CheckOnly
    Performs compliance check without notifications (for Intune detection script)
.Example
    .\RebootReminder.ps1 -DaysLimit 7 -ForceReboot
    Forces immediate reboot after grace period
.Example
    .\RebootReminder.ps1 -DaysLimit 7 -NotificationStyle Toast
    Uses the legacy toast notification instead of the pop-up window
.Parameter DaysLimit
    Maximum days before requiring a reboot (default: 7)
.Parameter HoursLimit
    Grace period in hours after reminder before forced reboot (default: 5)
.Parameter LogPath
    Custom log file path (default: user profile or temp)
.Parameter WorkStart
    Work hour start (0-23, default: 8)
.Parameter WorkEnd
    Work hour end (0-23, default: 17)
.Parameter IntuneMode
    Run in Intune-compatible mode (no long-running processes)
.Parameter CheckOnly
    Return exit code based on compliance only (for detection scripts)
.Parameter ForceReboot
    Force reboot after grace period
.Parameter NotificationStyle
    'Window' (default) shows a topmost pop-up window with Restart/Snooze/Dismiss buttons.
    'Toast' uses the legacy BurntToast/native toast notification instead.
.Parameter DismissTimeHours
    Hours user can dismiss reminders (default: 24)
.Notes
    Version: 6.1
    Author: Cláudio Gonçalves
    Compatible: Windows 10/11, Intune Proactive Remediations, SCCM
    Dependencies: BurntToast module (optional, only used with -NotificationStyle Toast).
    The pop-up window uses System.Windows.Forms, which ships with Windows PowerShell/.NET
    and requires no additional module. Windows Forms requires a Single-Threaded Apartment
    (STA); the script detects this automatically and relaunches itself with -Sta if needed.
#>

[CmdletBinding()]
param (
    [Parameter(Mandatory=$false)]
    [ValidateRange(1,365)]
    [int]$DaysLimit = 7,

    [Parameter(Mandatory=$false)]
    [ValidateRange(0,48)]
    [int]$HoursLimit = 5,

    [Parameter(Mandatory=$false)]
    [string]$LogPath = $(if (Test-Path "$env:USERPROFILE\RebootLog.log") { "$env:USERPROFILE\RebootLog.log" } else { "$env:TEMP\RebootLog.log" }),

    [Parameter(Mandatory=$false)]
    [ValidateRange(0,23)]
    [int]$WorkStart = 8,

    [Parameter(Mandatory=$false)]
    [ValidateRange(0,23)]
    [int]$WorkEnd = 17,

    [Parameter(Mandatory=$false)]
    [switch]$IntuneMode,

    [Parameter(Mandatory=$false)]
    [switch]$CheckOnly,

    [Parameter(Mandatory=$false)]
    [switch]$ForceReboot,

    [Parameter(Mandatory=$false)]
    [ValidateSet('Window','Toast')]
    [string]$NotificationStyle = 'Window',

    [Parameter(Mandatory=$false)]
    [ValidateRange(0,168)]
    [int]$DismissTimeHours = 24,

    [Parameter(Mandatory=$false)]
    [string[]]$DismissedUsers,

    [Parameter(Mandatory=$false)]
    [string]$ComplianceReportPath = "$env:ProgramData\RebootCompliance.json"
)

#region Helper Functions

function Write-RebootLog {
    param(
        [Parameter(Mandatory=$true)]
        [ValidateSet('Info','Warning','Error','Debug')]
        [string]$Level,
        [Parameter(Mandatory=$true)]
        [string]$Message
    )

    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $logEntry = "[$timestamp] [$Level] $Message"

    try {
        Add-Content -Path $LogPath -Value $logEntry -ErrorAction Stop
    }
    catch {
        Write-Error "Failed to write to log: $_"
    }

    switch ($Level) {
        'Info' { Write-Host $logEntry }
        'Warning' { Write-Warning $logEntry }
        'Error' { Write-Error $logEntry }
        'Debug' { Write-Debug $logEntry }
    }
}

function Get-SystemUptime {
    $OS = Get-CimInstance -ClassName Win32_OperatingSystem
    $LastBoot = $OS.LastBootUpTime
    $Uptime = Get-Date - $LastBoot
    return [PSCustomObject]@{
        LastBoot = $LastBoot
        UptimeDays = [math]::Round($Uptime.TotalDays, 1)
        UptimeHours = [math]::Round($Uptime.TotalHours, 0)
        TotalUptime = $Uptime
    }
}

function Test-IsWeekend {
    $today = (Get-Date).DayOfWeek
    return $today -in @([DayOfWeek]::Saturday, [DayOfWeek]::Sunday)
}

function Test-IsWorkHours {
    $currentHour = (Get-Date).Hour
    return $currentHour -ge $WorkStart -and $currentHour -lt $WorkEnd
}

function Get-ActiveUserSessions {
    try {
        $sessions = Get-CimInstance -ClassName Win32_LoggedOnUser -ErrorAction SilentlyContinue |
            Select-Object -ExpandProperty Antecedent |
            ForEach-Object { $_.Split('"')[1] } |
            Sort-Object -Unique
        return $sessions
    }
    catch {
        return @($env:USERNAME)
    }
}

function Get-RegistryForUser {
    param(
        [string]$UserName,
        [string]$RegistryPath
    )

    if ($UserName -eq $env:USERNAME) {
        return Get-Item -Path $RegistryPath -ErrorAction SilentlyContinue
    }

    $userSID = try {
        (New-Object System.Security.Principal.NTAccount($UserName)).Translate([System.Security.Principal.SecurityIdentifier]).Value
    }
    catch {
        return $null
    }

    $userRegPath = "Registry::HKEY_USERS\$userSID$($RegistryPath.Replace('HKCU:\',''))"
    return Get-Item -Path $userRegPath -ErrorAction SilentlyContinue
}

function Set-RegistryForUser {
    param(
        [string]$UserName,
        [string]$RegistryPath,
        [string]$Name,
        $Value,
        [string]$PropertyType = 'String'
    )

    if ($UserName -eq $env:USERNAME) {
        Set-ItemProperty -Path $RegistryPath -Name $Name -Value $Value -Type $PropertyType -Force
        return
    }

    $userSID = try {
        (New-Object System.Security.Principal.NTAccount($UserName)).Translate([System.Security.Principal.SecurityIdentifier]).Value
    }
    catch {
        return
    }

    $userRegPath = "Registry::HKEY_USERS\$userSID$($RegistryPath.Replace('HKCU:\',''))"

    if (-not (Test-Path $userRegPath)) {
        New-Item -Path $userRegPath -Force | Out-Null
    }

    Set-ItemProperty -Path $userRegPath -Name $Name -Value $Value -Type $PropertyType -Force
}

function Initialize-RebootTracking {
    $trackingPath = "HKCU:\SOFTWARE\RebootReminder"

    if (-not (Test-Path $trackingPath)) {
        New-Item -Path $trackingPath -Force | Out-Null
        Set-ItemProperty -Path $trackingPath -Name "LastReminder" -Value ([DateTime]::MinValue) -Force
        Set-ItemProperty -Path $trackingPath -Name "DismissCount" -Value 0 -Force
        Set-ItemProperty -Path $trackingPath -Name "FirstReminder" -Value ([DateTime]::MinValue) -Force
    }

    return Get-Item -Path $trackingPath
}

function Get-RebootTrackingData {
    $trackingPath = "HKCU:\SOFTWARE\RebootReminder"

    if (-not (Test-Path $trackingPath)) {
        return $null
    }

    return [PSCustomObject]@{
        LastReminder = [DateTime](Get-ItemProperty -Path $trackingPath -Name "LastReminder" -ErrorAction SilentlyContinue).LastReminder
        DismissCount = [int](Get-ItemProperty -Path $trackingPath -Name "DismissCount" -ErrorAction SilentlyContinue).DismissCount
        FirstReminder = [DateTime](Get-ItemProperty -Path $trackingPath -Name "FirstReminder" -ErrorAction SilentlyContinue).FirstReminder
    }
}

function Update-RebootTracking {
    param(
        [string]$Action = 'Reminder'
    )

    $trackingPath = "HKCU:\SOFTWARE\RebootReminder"

    if (-not (Test-Path $trackingPath)) {
        Initialize-RebootTracking | Out-Null
    }

    $current = Get-RebootTrackingData

    switch ($Action) {
        'Reminder' {
            Set-ItemProperty -Path $trackingPath -Name "LastReminder" -Value (Get-Date) -Force
            if ($current.FirstReminder -eq [DateTime]::MinValue) {
                Set-ItemProperty -Path $trackingPath -Name "FirstReminder" -Value (Get-Date) -Force
            }
        }
        'Dismiss' {
            $dismissCount = ($current.DismissCount) + 1
            Set-ItemProperty -Path $trackingPath -Name "DismissCount" -Value $dismissCount -Force
        }
        'Rebooted' {
            Set-ItemProperty -Path $trackingPath -Name "LastReminder" -Value ([DateTime]::MinValue) -Force
            Set-ItemProperty -Path $trackingPath -Name "DismissCount" -Value 0 -Force
            Set-ItemProperty -Path $trackingPath -Name "FirstReminder" -Value ([DateTime]::MinValue) -Force
        }
    }
}

#endregion

#region Notification Functions

function Test-BurntToastAvailable {
    return $null -ne (Get-Module -ListAvailable -Name BurntToast)
}

function Show-Windows11Toast {
    param(
        [string]$Title,
        [string]$Message,
        [string]$LogoPath = $null,
        [hashtable]$Buttons = @{}
    )

    if (Test-BurntToastAvailable) {
        try {
            Import-Module BurntToast -ErrorAction Stop

            $toastParams = @{
                Text = $Title, $Message
            }

            if ($LogoPath -and (Test-Path $LogoPath)) {
                $toastParams.AppLogo = $LogoPath
            }

            if ($Buttons.Count -gt 0) {
                $buttonObjects = foreach ($btn in $Buttons.GetEnumerator()) {
                    New-BTButton -Content $btn.Key -Arguments $btn.Value
                }
                $toastParams.Button = $buttonObjects
            }

            Submit-BTNotification @toastParams
            return $true
        }
        catch {
            Write-RebootLog -Level Warning -Message "BurntToast failed: $_. Falling back to native notifications."
        }
    }

    return Show-NativeToast -Title $Title -Message $Message
}

function Show-NativeToast {
    param(
        [string]$Title,
        [string]$Message
    )

    try {
        $template = @"
<toast>
    <visual>
        <binding template="ToastGeneric">
            <text>$Title</text>
            <text>$Message</text>
        </binding>
    </visual>
</toast>
"@

        $xml = New-Object Windows.Data.Xml.Dom.XmlDocument
        $xml.LoadXml($template)

        $appId = '{1AC14E77-02E7-4E5D-B744-2EB1AE5198B7}\WindowsPowerShell\v1.0\powershell.exe'
        $notifier = [Windows.UI.Notifications.ToastNotificationManager]::CreateToastNotifier($appId)
        $notifier.Show($xml)

        return $true
    }
    catch {
        Write-RebootLog -Level Error -Message "Native toast failed: $_"
        return $false
    }
}

function Get-ReminderButtonSet {
    param(
        [Parameter(Mandatory=$false)]
        [switch]$FinalWarning
    )

    if ($FinalWarning) {
        return [ordered]@{
            'Restart Now' = 'Restart'
            'Dismiss'     = 'Dismiss'
        }
    }

    return [ordered]@{
        'Restart Now'     = 'Restart'
        'Remind Me Later' = 'Snooze'
        'Dismiss'         = 'Dismiss'
    }
}

function Test-RequiresStaRelaunch {
    try {
        return [System.Threading.Thread]::CurrentThread.GetApartmentState() -ne [System.Threading.ApartmentState]::STA
    }
    catch {
        return $false
    }
}

function Start-StaRelaunch {
    param(
        [Parameter(Mandatory=$true)]
        [string]$ScriptPath,

        [Parameter(Mandatory=$true)]
        [System.Collections.IDictionary]$BoundParameters
    )

    $hostExePath = try {
        (Get-Process -Id $PID -ErrorAction Stop).Path
    }
    catch {
        'powershell.exe'
    }

    $arguments = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-Sta', '-File', $ScriptPath)

    foreach ($key in $BoundParameters.Keys) {
        $value = $BoundParameters[$key]

        if ($value -is [switch]) {
            if ($value.IsPresent) {
                $arguments += "-$key"
            }
        }
        elseif ($value -is [array]) {
            $arguments += "-$key"
            $arguments += ($value -join ',')
        }
        else {
            $arguments += "-$key"
            $arguments += [string]$value
        }
    }

    Write-RebootLog -Level Info -Message "Relaunching under a Single-Threaded Apartment for the reminder window"

    $process = Start-Process -FilePath $hostExePath -ArgumentList $arguments -WindowStyle Hidden -PassThru -Wait
    exit $process.ExitCode
}

function Show-RebootReminderWindow {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)]
        [string]$Title,

        [Parameter(Mandatory=$true)]
        [string]$Message,

        [Parameter(Mandatory=$false)]
        [System.Collections.Specialized.OrderedDictionary]$Buttons = (Get-ReminderButtonSet),

        [Parameter(Mandatory=$false)]
        [ValidateRange(0,3600)]
        [int]$TimeoutSeconds = 180,

        [Parameter(Mandatory=$false)]
        [switch]$FinalWarning
    )

    try {
        Add-Type -AssemblyName System.Windows.Forms -ErrorAction Stop
        Add-Type -AssemblyName System.Drawing -ErrorAction Stop
    }
    catch {
        Write-RebootLog -Level Error -Message "Windows Forms is unavailable, cannot display the reminder window: $_"
        return 'Unavailable'
    }

    $form = New-Object -TypeName System.Windows.Forms.Form
    $form.Text = $Title
    $form.ClientSize = New-Object -TypeName System.Drawing.Size -ArgumentList 480, 260
    $form.StartPosition = [System.Windows.Forms.FormStartPosition]::CenterScreen
    $form.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::FixedDialog
    $form.MaximizeBox = $false
    $form.MinimizeBox = $false
    $form.ControlBox = $true
    $form.TopMost = $true
    $form.ShowInTaskbar = $true
    $form.Tag = $null

    $textLeft = 20

    $iconPath = Join-Path -Path $PSScriptRoot -ChildPath 'reboot.gif'
    if (Test-Path -LiteralPath $iconPath) {
        try {
            $pictureBox = New-Object -TypeName System.Windows.Forms.PictureBox
            $pictureBox.Image = [System.Drawing.Image]::FromFile($iconPath)
            $pictureBox.SizeMode = [System.Windows.Forms.PictureBoxSizeMode]::Zoom
            $pictureBox.Location = New-Object -TypeName System.Drawing.Point -ArgumentList 20, 20
            $pictureBox.Size = New-Object -TypeName System.Drawing.Size -ArgumentList 64, 64
            $form.Controls.Add($pictureBox)
            $textLeft = 100
        }
        catch {
            Write-RebootLog -Level Warning -Message "Unable to load reminder icon '$iconPath': $_"
        }
    }

    $titleLabel = New-Object -TypeName System.Windows.Forms.Label
    $titleLabel.Text = $Title
    $titleLabel.Font = New-Object -TypeName System.Drawing.Font -ArgumentList 'Segoe UI', 12, [System.Drawing.FontStyle]::Bold
    $titleLabel.ForeColor = if ($FinalWarning) { [System.Drawing.Color]::FromArgb(168, 0, 0) } else { [System.Drawing.Color]::FromArgb(0, 90, 158) }
    $titleLabel.Location = New-Object -TypeName System.Drawing.Point -ArgumentList $textLeft, 20
    $titleLabel.Size = New-Object -TypeName System.Drawing.Size -ArgumentList (460 - $textLeft), 30
    $form.Controls.Add($titleLabel)

    $messageLabel = New-Object -TypeName System.Windows.Forms.Label
    $messageLabel.Text = $Message
    $messageLabel.Font = New-Object -TypeName System.Drawing.Font -ArgumentList 'Segoe UI', 9
    $messageLabel.Location = New-Object -TypeName System.Drawing.Point -ArgumentList $textLeft, 55
    $messageLabel.Size = New-Object -TypeName System.Drawing.Size -ArgumentList (460 - $textLeft), 100
    $form.Controls.Add($messageLabel)

    $countdownLabel = New-Object -TypeName System.Windows.Forms.Label
    $countdownLabel.Font = New-Object -TypeName System.Drawing.Font -ArgumentList 'Segoe UI', 8, [System.Drawing.FontStyle]::Italic
    $countdownLabel.ForeColor = [System.Drawing.Color]::Gray
    $countdownLabel.Location = New-Object -TypeName System.Drawing.Point -ArgumentList 20, 165
    $countdownLabel.Size = New-Object -TypeName System.Drawing.Size -ArgumentList 440, 20
    $form.Controls.Add($countdownLabel)

    $buttonPanel = New-Object -TypeName System.Windows.Forms.FlowLayoutPanel
    $buttonPanel.FlowDirection = [System.Windows.Forms.FlowDirection]::RightToLeft
    $buttonPanel.Location = New-Object -TypeName System.Drawing.Point -ArgumentList 20, 200
    $buttonPanel.Size = New-Object -TypeName System.Drawing.Size -ArgumentList 440, 40

    $isPrimaryButton = $true

    foreach ($entry in $Buttons.GetEnumerator()) {
        $button = New-Object -TypeName System.Windows.Forms.Button
        $button.Text = $entry.Key
        $button.Tag = $entry.Value
        $button.Width = 135
        $button.Height = 32
        $button.DialogResult = [System.Windows.Forms.DialogResult]::OK
        $button.Add_Click({
            param($sender)
            $sender.FindForm().Tag = $sender.Tag
        })

        if ($isPrimaryButton) {
            $button.BackColor = [System.Drawing.Color]::FromArgb(0, 120, 212)
            $button.ForeColor = [System.Drawing.Color]::White
            $button.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
            $form.AcceptButton = $button
            $isPrimaryButton = $false
        }

        $buttonPanel.Controls.Add($button)
    }

    $form.Controls.Add($buttonPanel)

    $timer = $null

    if ($TimeoutSeconds -gt 0) {
        $timer = New-Object -TypeName System.Windows.Forms.Timer
        $timer.Interval = 1000
        $remaining = $TimeoutSeconds

        $timer.Add_Tick({
            $remaining--
            $countdownLabel.Text = "This reminder closes automatically in $remaining second(s)."
            if ($remaining -le 0) {
                $form.Tag = 'Timeout'
                $timer.Stop()
                $form.Close()
            }
        }.GetNewClosure())

        $form.Add_Shown({ $timer.Start() }.GetNewClosure())
        $form.Add_FormClosed({ $timer.Dispose() }.GetNewClosure())
    }

    try {
        [void]$form.ShowDialog()
    }
    catch {
        Write-RebootLog -Level Error -Message "Failed to display the reminder window: $_"
        if ($null -ne $timer) {
            $timer.Dispose()
        }
        $form.Dispose()
        return 'Unavailable'
    }

    $finalResult = if ([string]::IsNullOrEmpty([string]$form.Tag)) { 'Dismiss' } else { [string]$form.Tag }
    $form.Dispose()

    Write-RebootLog -Level Info -Message "Reminder window closed with result: $finalResult"
    return $finalResult
}

function Show-RebootReminder {
    param(
        [int]$UptimeDays,
        [int]$HoursRemaining,
        [switch]$FinalWarning
    )

    $title = if ($FinalWarning) {
        "FINAL WARNING: Reboot Required"
    } else {
        "System Reboot Needed"
    }

    $message = if ($FinalWarning) {
        "Your system hasn't been rebooted in $UptimeDays days. Reboot will be enforced in $HoursRemaining hours. Please save your work and restart now."
    } else {
        "Your system hasn't been rebooted in $UptimeDays days. Please restart to ensure security updates are applied. You have $HoursRemaining hours before a forced reboot."
    }

    if ($NotificationStyle -eq 'Toast') {
        $buttons = @{
            "Restart Now" = "reboot-now"
            "Snooze 1 Hour" = "snooze-1h"
            "Dismiss" = "dismiss"
        }
        Show-Windows11Toast -Title $title -Message $message -Buttons $buttons
        return 'ToastSent'
    }

    $response = Show-RebootReminderWindow -Title $title -Message $message -Buttons (Get-ReminderButtonSet -FinalWarning:$FinalWarning) -FinalWarning:$FinalWarning

    if ($response -eq 'Unavailable') {
        Write-RebootLog -Level Warning -Message "Reminder window unavailable, falling back to a toast notification"
        $buttons = @{
            "Restart Now" = "reboot-now"
            "Snooze 1 Hour" = "snooze-1h"
            "Dismiss" = "dismiss"
        }
        Show-Windows11Toast -Title $title -Message $message -Buttons $buttons
    }

    return $response
}

function Show-RebootEnforced {
    $title = "System Rebooting"
    $message = "Your system will reboot in 10 minutes to apply critical updates. Please save your work immediately."

    if ($NotificationStyle -eq 'Toast') {
        Show-Windows11Toast -Title $title -Message $message
        return 'ToastSent'
    }

    $response = Show-RebootReminderWindow -Title $title -Message $message -Buttons (Get-ReminderButtonSet -FinalWarning) -TimeoutSeconds 30 -FinalWarning

    if ($response -eq 'Unavailable') {
        Write-RebootLog -Level Warning -Message "Reminder window unavailable, falling back to a toast notification"
        Show-Windows11Toast -Title $title -Message $message
    }

    return $response
}

#endregion

#region Intune Functions

function Get-IntuneComplianceStatus {
    $uptime = Get-SystemUptime
    $tracking = Get-RebootTrackingData

    $isCompliant = $uptime.UptimeDays -lt $DaysLimit

    $status = [PSCustomObject]@{
        Compliant = $isCompliant
        UptimeDays = $uptime.UptimeDays
        UptimeHours = $uptime.UptimeHours
        LastBoot = $uptime.LastBoot
        LastReminder = if ($tracking) { $tracking.LastReminder } else { $null }
        DismissCount = if ($tracking) { $tracking.DismissCount } else { 0 }
        DaysLimit = $DaysLimit
        HoursLimit = $HoursLimit
        ComputerName = $env:COMPUTERNAME
        UserName = $env:USERNAME
        Timestamp = Get-Date
    }

    return $status
}

function Update-ComplianceReport {
    param(
        [PSCustomObject]$ComplianceStatus
    )

    try {
        $reportPath = $ComplianceReportPath
        $reportDir = Split-Path $reportPath -Parent

        if (-not (Test-Path $reportDir)) {
            New-Item -Path $reportDir -ItemType Directory -Force | Out-Null
        }

        $existingReport = if (Test-Path $reportPath) {
            Get-Content $reportPath | ConvertFrom-Json
        } else {
            @()
        }

        $newEntry = $ComplianceStatus | Select-Object Compliant, UptimeDays, UptimeHours, LastBoot, ComputerName, UserName, Timestamp

        $existingReport += $newEntry

        $existingReport | ConvertTo-Json -Depth 10 | Set-Content $reportPath -Force

        Write-RebootLog -Level Info -Message "Compliance report updated: $reportPath"
    }
    catch {
        Write-RebootLog -Level Error -Message "Failed to update compliance report: $_"
    }
}

function Invoke-IntuneDetection {
    $status = Get-IntuneComplianceStatus

    if ($status.Compliant) {
        Write-Host "System is compliant (Uptime: $($status.UptimeDays) days)"
        exit 0
    }
    else {
        Write-Host "System is non-compliant (Uptime: $($status.UptimeDays) days)"
        exit 1
    }
}

function Invoke-IntuneRemediation {
    $status = Get-IntuneComplianceStatus

    if ($status.Compliant) {
        Write-RebootLog -Level Info -Message "System is compliant. No action needed."
        return
    }

    if (Test-IsWeekend) {
        Write-RebootLog -Level Info -Message "Skipping notification on weekend"
        return
    }

    if (-not (Test-IsWorkHours)) {
        Write-RebootLog -Level Info -Message "Skipping notification outside work hours"
        return
    }

    $tracking = Get-RebootTrackingData
    $hoursSinceReminder = if ($tracking -and $tracking.LastReminder -gt [DateTime]::MinValue) {
        ((Get-Date) - $tracking.LastReminder).TotalHours
    } else {
        $HoursLimit + 1
    }

    if ($hoursSinceReminder -lt 1) {
        Write-RebootLog -Level Info -Message "Reminder shown less than 1 hour ago. Skipping."
        return
    }

    Update-RebootTracking -Action 'Reminder'

    $hoursRemaining = $HoursLimit
    $isFinalWarning = $hoursRemaining -le 1

    $response = Show-RebootReminder -UptimeDays $status.UptimeDays -HoursRemaining $hoursRemaining -FinalWarning:$isFinalWarning

    switch ($response) {
        'Restart' {
            Write-RebootLog -Level Warning -Message "User chose to restart immediately from the reminder window"
            Update-RebootTracking -Action 'Rebooted'
            Restart-Computer -Force
        }
        'Dismiss' {
            Update-RebootTracking -Action 'Dismiss'
        }
    }

    Update-ComplianceReport -ComplianceStatus $status

    Write-RebootLog -Level Info -Message "Reboot reminder displayed to user (response: $response)"
}

function Invoke-GracefulReboot {
    param(
        [int]$WarningMinutes = 10,
        [string]$WarningMessage = "System will reboot in {0} minutes. Please save your work."
    )

    Write-RebootLog -Level Warning -Message "Initiating graceful reboot sequence"

    $response = Show-RebootEnforced

    if ($response -eq 'Restart') {
        Write-RebootLog -Level Warning -Message "User chose to restart immediately from the final warning window"
        Update-RebootTracking -Action 'Rebooted'
        Restart-Computer -Force
        return
    }

    $endTime = (Get-Date).AddMinutes($WarningMinutes)

    while ((Get-Date) -lt $endTime) {
        $remaining = [math]::Round(($endTime - (Get-Date)).TotalMinutes)

        if ($remaining -le 5 -or $remaining % 5 -eq 0) {
            Write-RebootLog -Level Info -Message ($WarningMessage -f $remaining)
        }

        Start-Sleep -Seconds 30
    }

    Write-RebootLog -Level Warning -Message "Executing system reboot"

    try {
        Restart-Computer -Force -ErrorAction Stop
    }
    catch {
        Write-RebootLog -Level Error -Message "Failed to restart computer: $_"
        shutdown /g /f /t 0
    }
}

#endregion

#region Scheduled Task Functions

function Register-RebootReminderTask {
    param(
        [string]$ScriptPath,
        [string]$TaskName = "RebootReminder",
        [string]$Schedule = "Daily"
    )

    try {
        $action = New-ScheduledTaskAction -Execute "PowerShell.exe" -Argument "-NoProfile -ExecutionPolicy Bypass -Sta -File `"$ScriptPath`" -IntuneMode"
        $trigger = switch ($Schedule) {
            "Hourly" { New-ScheduledTaskTrigger -Once -At (Get-Date) -RepetitionInterval (New-TimeSpan -Hours 1) }
            "Daily" { New-ScheduledTaskTrigger -Daily -At 9am }
            "Weekly" { New-ScheduledTaskTrigger -Weekly -DaysOfWeek Monday, Tuesday, Wednesday, Thursday, Friday -At 9am }
            Default { New-ScheduledTaskTrigger -Daily -At 9am }
        }
        $principal = New-ScheduledTaskPrincipal -UserId "NT AUTHORITY\SYSTEM" -LogonType ServiceAccount -RunLevel Highest
        $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable

        Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger -Principal $principal -Settings $settings -Force -ErrorAction Stop

        Write-RebootLog -Level Info -Message "Scheduled task '$TaskName' registered successfully"
        return $true
    }
    catch {
        Write-RebootLog -Level Error -Message "Failed to register scheduled task: $_"
        return $false
    }
}

function Unregister-RebootReminderTask {
    param(
        [string]$TaskName = "RebootReminder"
    )

    try {
        Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction Stop
        Write-RebootLog -Level Info -Message "Scheduled task '$TaskName' unregistered successfully"
        return $true
    }
    catch {
        Write-RebootLog -Level Warning -Message "Failed to unregister scheduled task: $_"
        return $false
    }
}

function Register-UserContextTask {
    param(
        [string]$ScriptPath,
        [string]$TaskName = "RebootReminderUser"
    )

    try {
        $action = New-ScheduledTaskAction -Execute "PowerShell.exe" -Argument "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -Sta -File `"$ScriptPath`" -IntuneMode"
        $trigger = New-ScheduledTaskTrigger -AtLogon
        $principal = New-ScheduledTaskPrincipal -GroupId "S-1-5-32-545" -RunLevel Highest

        Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger -Principal $principal -Force -ErrorAction Stop

        Write-RebootLog -Level Info -Message "User context task '$TaskName' registered successfully"
        return $true
    }
    catch {
        Write-RebootLog -Level Error -Message "Failed to register user context task: $_"
        return $false
    }
}

#endregion

#region Main Execution

function Initialize-RebootLogging {
    if (-not (Test-Path $LogPath)) {
        try {
            $logDir = Split-Path $LogPath -Parent
            if (-not (Test-Path $logDir)) {
                New-Item -Path $logDir -ItemType Directory -Force | Out-Null
            }
            New-Item -Path $LogPath -ItemType File -Force | Out-Null
            Write-RebootLog -Level Info -Message "Log file created: $LogPath"
        }
        catch {
            Write-Error "Failed to create log file: $_"
            exit 1
        }
    }

    $logFile = Get-Item $LogPath
    if ($logFile.Length -gt 10MB) {
        try {
            $archivePath = "$LogPath.old"
            Move-Item $LogPath $archivePath -Force
            New-Item -Path $LogPath -ItemType File -Force | Out-Null
            Write-RebootLog -Level Info -Message "Log file archived"
        }
        catch {
            Write-RebootLog -Level Error -Message "Failed to archive log file: $_"
        }
    }
}

function Main {
    Write-RebootLog -Level Info -Message "=== Reboot Reminder Script Started ==="
    Write-RebootLog -Level Info -Message "Parameters: DaysLimit=$DaysLimit, HoursLimit=$HoursLimit, IntuneMode=$IntuneMode, CheckOnly=$CheckOnly, NotificationStyle=$NotificationStyle"

    Initialize-RebootLogging

    if ($CheckOnly) {
        Invoke-IntuneDetection
        return
    }

    if ($IntuneMode) {
        Invoke-IntuneRemediation
        Write-RebootLog -Level Info -Message "=== Reboot Reminder Script Completed (Intune Mode) ==="
        return
    }

    $uptime = Get-SystemUptime
    Write-RebootLog -Level Info -Message "System uptime: $($uptime.UptimeDays) days ($($uptime.UptimeHours) hours)"

    if ($uptime.UptimeDays -lt $DaysLimit) {
        Write-RebootLog -Level Info -Message "System is within uptime limit. No action required."
        Update-RebootTracking -Action 'Rebooted'
        return
    }

    if (Test-IsWeekend) {
        Write-RebootLog -Level Info -Message "Skipping operation on weekend"
        return
    }

    if (-not (Test-IsWorkHours)) {
        Write-RebootLog -Level Info -Message "Skipping operation outside work hours"
        return
    }

    $tracking = Get-RebootTrackingData
    $hoursSinceFirstReminder = if ($tracking -and $tracking.FirstReminder -gt [DateTime]::MinValue) {
        ((Get-Date) - $tracking.FirstReminder).TotalHours
    } else {
        0
    }

    Initialize-RebootTracking | Out-Null

    if ($hoursSinceFirstReminder -ge $HoursLimit -or $ForceReboot) {
        Write-RebootLog -Level Warning -Message "Grace period exceeded or forced reboot requested"
        Invoke-GracefulReboot
    }
    else {
        $hoursRemaining = $HoursLimit - $hoursSinceFirstReminder
        Write-RebootLog -Level Info -Message "Displaying reboot reminder. Hours remaining: $hoursRemaining"

        Update-RebootTracking -Action 'Reminder'

        $isFinalWarning = $hoursRemaining -le 1
        $response = Show-RebootReminder -UptimeDays $uptime.UptimeDays -HoursRemaining $hoursRemaining -FinalWarning:$isFinalWarning

        switch ($response) {
            'Restart' {
                Write-RebootLog -Level Warning -Message "User chose to restart immediately from the reminder window"
                Update-RebootTracking -Action 'Rebooted'
                Restart-Computer -Force
            }
            'Dismiss' {
                Update-RebootTracking -Action 'Dismiss'
            }
        }

        Update-ComplianceReport -ComplianceStatus (Get-IntuneComplianceStatus)

        Write-RebootLog -Level Info -Message "Reboot reminder sent to user (response: $response)"
    }

    Write-RebootLog -Level Info -Message "=== Reboot Reminder Script Completed ==="
}

try {
    if (-not $CheckOnly -and $NotificationStyle -eq 'Window' -and (Test-RequiresStaRelaunch)) {
        Start-StaRelaunch -ScriptPath $PSCommandPath -BoundParameters $PSBoundParameters
    }

    Main
}
catch {
    Write-RebootLog -Level Error -Message "Script failed: $($_.Exception.Message)`nStackTrace: $($_.ScriptStackTrace)"
    exit 1
}

#endregion
