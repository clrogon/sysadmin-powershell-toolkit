<#
.SYNOPSIS
    Intune Remediation Script for Reboot Reminder
.DESCRIPTION
    Displays a reboot reminder to the user when the system is non-compliant.
    Shows a native pop-up window by default (reliable even when Windows toast
    notifications are disabled or suppressed by Focus Assist); falls back to a
    toast notification if Windows Forms cannot be loaded, or if -NotificationStyle
    Toast is requested explicitly.
    Designed to run in user context so the window renders on the user's desktop.
#>

param(
    [Parameter(Mandatory=$false)]
    [ValidateRange(1,365)]
    [int]$DaysLimit = 7,

    [Parameter(Mandatory=$false)]
    [ValidateRange(0,48)]
    [int]$HoursLimit = 5,

    [Parameter(Mandatory=$false)]
    [ValidateSet('Window','Toast')]
    [string]$NotificationStyle = 'Window'
)

$ErrorActionPreference = "Stop"

function Write-Log {
    param([string]$Message, [string]$Level = "INFO")
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $logPath = "$env:TEMP\RebootReminder-Intune.log"
    "[$timestamp] [$Level] $Message" | Out-File -FilePath $logPath -Append
    Write-Host $Message
}

function Test-IsWeekend {
    return (Get-Date).DayOfWeek -in @([DayOfWeek]::Saturday, [DayOfWeek]::Sunday)
}

function Test-IsWorkHours {
    $hour = (Get-Date).Hour
    return $hour -ge 8 -and $hour -lt 17
}

function Show-ToastNotification {
    param(
        [string]$Title,
        [string]$Message
    )

    try {
        # Try BurntToast first (if available)
        if (Get-Module -ListAvailable -Name BurntToast) {
            Import-Module BurntToast
            Submit-BTNotification -Text $Title, $Message
            return
        }

        # Fallback to native Windows toast
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
    }
    catch {
        Write-Log -Message "Failed to show toast: $_" -Level "ERROR"
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

function Show-ReminderWindow {
    param(
        [Parameter(Mandatory=$true)]
        [string]$Title,

        [Parameter(Mandatory=$true)]
        [string]$Message,

        [Parameter(Mandatory=$false)]
        [System.Collections.Specialized.OrderedDictionary]$Buttons = (Get-ReminderButtonSet)
    )

    try {
        Add-Type -AssemblyName System.Windows.Forms -ErrorAction Stop
        Add-Type -AssemblyName System.Drawing -ErrorAction Stop
    }
    catch {
        Write-Log -Message "Windows Forms is unavailable, cannot display the reminder window: $_" -Level "ERROR"
        return 'Unavailable'
    }

    $form = New-Object -TypeName System.Windows.Forms.Form
    $form.Text = $Title
    $form.ClientSize = New-Object -TypeName System.Drawing.Size -ArgumentList 460, 220
    $form.StartPosition = [System.Windows.Forms.FormStartPosition]::CenterScreen
    $form.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::FixedDialog
    $form.MaximizeBox = $false
    $form.MinimizeBox = $false
    $form.ControlBox = $true
    $form.TopMost = $true
    $form.ShowInTaskbar = $true
    $form.Tag = $null

    $titleLabel = New-Object -TypeName System.Windows.Forms.Label
    $titleLabel.Text = $Title
    $titleLabel.Font = New-Object -TypeName System.Drawing.Font -ArgumentList 'Segoe UI', 12, [System.Drawing.FontStyle]::Bold
    $titleLabel.Location = New-Object -TypeName System.Drawing.Point -ArgumentList 20, 20
    $titleLabel.Size = New-Object -TypeName System.Drawing.Size -ArgumentList 420, 30
    $form.Controls.Add($titleLabel)

    $messageLabel = New-Object -TypeName System.Windows.Forms.Label
    $messageLabel.Text = $Message
    $messageLabel.Font = New-Object -TypeName System.Drawing.Font -ArgumentList 'Segoe UI', 9
    $messageLabel.Location = New-Object -TypeName System.Drawing.Point -ArgumentList 20, 55
    $messageLabel.Size = New-Object -TypeName System.Drawing.Size -ArgumentList 420, 90
    $form.Controls.Add($messageLabel)

    $buttonPanel = New-Object -TypeName System.Windows.Forms.FlowLayoutPanel
    $buttonPanel.FlowDirection = [System.Windows.Forms.FlowDirection]::RightToLeft
    $buttonPanel.Location = New-Object -TypeName System.Drawing.Point -ArgumentList 20, 160
    $buttonPanel.Size = New-Object -TypeName System.Drawing.Size -ArgumentList 420, 40

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

    try {
        [void]$form.ShowDialog()
    }
    catch {
        Write-Log -Message "Failed to display the reminder window: $_" -Level "ERROR"
        $form.Dispose()
        return 'Unavailable'
    }

    $finalResult = if ([string]::IsNullOrEmpty([string]$form.Tag)) { 'Dismiss' } else { [string]$form.Tag }
    $form.Dispose()

    Write-Log -Message "Reminder window closed with result: $finalResult"
    return $finalResult
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
        $arguments += "-$key"
        $arguments += [string]$value
    }

    Write-Log -Message "Relaunching under a Single-Threaded Apartment for the reminder window"

    $process = Start-Process -FilePath $hostExePath -ArgumentList $arguments -WindowStyle Hidden -PassThru -Wait
    exit $process.ExitCode
}

if ($NotificationStyle -eq 'Window' -and (Test-RequiresStaRelaunch)) {
    Start-StaRelaunch -ScriptPath $PSCommandPath -BoundParameters $PSBoundParameters
}

try {
    Write-Log -Message "Reboot Reminder Remediation started"

    # Check weekend and work hours
    if (Test-IsWeekend) {
        Write-Log -Message "Skipping: Today is weekend"
        exit 0
    }

    if (-not (Test-IsWorkHours)) {
        Write-Log -Message "Skipping: Outside work hours"
        exit 0
    }

    # Get uptime
    $OS = Get-CimInstance -ClassName Win32_OperatingSystem
    $LastBoot = $OS.LastBootUpTime
    $Uptime = (Get-Date) - $LastBoot
    $UptimeDays = [math]::Round($Uptime.TotalDays, 1)

    Write-Log -Message "System uptime: $UptimeDays days"

    if ($UptimeDays -ge $DaysLimit) {
        # Check if we already showed a notification recently
        $trackingPath = "HKCU:\SOFTWARE\RebootReminder"
        $lastReminder = try {
            [DateTime](Get-ItemProperty -Path $trackingPath -Name "LastReminder" -ErrorAction SilentlyContinue).LastReminder
        } catch {
            [DateTime]::MinValue
        }

        $hoursSinceReminder = if ($lastReminder -gt [DateTime]::MinValue) {
            ((Get-Date) - $lastReminder).TotalHours
        } else {
            999
        }

        if ($hoursSinceReminder -ge 1) {
            Write-Log -Message "Displaying reboot reminder"

            $title = "System Reboot Required"
            $message = "Your system hasn't been rebooted in $UptimeDays days. Please restart to ensure security updates are applied."

            $response = 'ToastSent'

            if ($NotificationStyle -eq 'Window') {
                $response = Show-ReminderWindow -Title $title -Message $message
                if ($response -eq 'Unavailable') {
                    Write-Log -Message "Reminder window unavailable, falling back to a toast notification" -Level "WARN"
                    Show-ToastNotification -Title $title -Message $message
                }
            }
            else {
                Show-ToastNotification -Title $title -Message $message
            }

            # Update tracking
            if (-not (Test-Path $trackingPath)) {
                New-Item -Path $trackingPath -Force | Out-Null
            }
            Set-ItemProperty -Path $trackingPath -Name "LastReminder" -Value (Get-Date) -Force

            Write-Log -Message "Notification displayed successfully (response: $response)"

            if ($response -eq 'Restart') {
                Write-Log -Message "User chose to restart immediately" -Level "WARN"
                Restart-Computer -Force
            }
        } else {
            Write-Log -Message "Skipping: Notification shown less than 1 hour ago"
        }
    } else {
        Write-Log -Message "System is compliant"
    }

    exit 0
}
catch {
    Write-Log -Message "Remediation failed: $_" -Level "ERROR"
    exit 1
}
