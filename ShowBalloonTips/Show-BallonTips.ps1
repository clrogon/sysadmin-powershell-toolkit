<#
.SYNOPSIS
    Shows a balloon tip from the PowerShell icon in the notification area.

.DESCRIPTION
    Displays text in a notification-area balloon tip using the classic WinForms
    NotifyIcon API. Balloon tips are deprecated on Windows 10 and later; new
    implementations should use Show-Notification.ps1 for modern toast
    notifications.

    *** DEPRECATED NOTICE ***
    Balloon tip notifications are deprecated in Windows 10 and later.
    Please use Show-Notification.ps1 for modern toast notifications instead.

.EXAMPLE
    Show-BalloonTip -Text 'Look at me!' -Title 'Tip from Guy'
.EXAMPLE
    Show-BalloonTip -Text 'Look at me!' -Title 'Tip from Guy' -Icon Error -Timeout 20000

.NOTES
    Deprecated since: Windows 10
    Replacement: Show-Notification.ps1
    Version: 3.0
    Author: Claudio Gonçalves
#>

function Global:Show-BalloonTip {
    [CmdletBinding()]
    [OutputType([int])]
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
        Write-Warning "Show-BalloonTip is deprecated and will be removed in a future release. Use Show-Notification.ps1 for modern Windows toast notifications instead."

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

        return 0
    }
}
