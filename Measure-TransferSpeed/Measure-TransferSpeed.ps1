<#
.SYNOPSIS
    Measures SMB transfer speeds between servers and logs performance metrics.

.DESCRIPTION
    Creates a test file of the requested size on the source server's admin share
    and copies it to the destination server's admin share for the requested
    number of iterations, recording duration and speed per iteration. Supports
    historical comparison, multi-path testing, throttling analysis, and HTML
    report generation. Requires administrative access to both servers.

.EXAMPLE
    .\Measure-TransferSpeed.ps1 -SourceServer ABC -DestinationServer XYZ -FileSizeMB 100 -Iterations 5

.EXAMPLE
    .\Measure-TransferSpeed.ps1 -SourceServer ABC -DestinationServers XYZ,PDQ -FileSizeMB 100 -MultiPathTest

.EXAMPLE
    $cred = Get-Credential
    .\Measure-TransferSpeed.ps1 -SourceServer ABC -DestinationServer XYZ -FileSizeMB 100 -Credential $cred -IncludeHistoricalComparison

.NOTES
    Version: 3.0
    Author: Claudio Gonçalves
#>

#Requires -Version 5.1

[CmdletBinding()]
param(
    [string]$SourceServer,
    [string]$DestinationServer,
    [string[]]$DestinationServers,
    [switch]$MultiPathTest,
    [int]$FileSizeMB = 100,
    [int]$Iterations = 1,
    [PSCredential]$Credential,
    [string]$HistoricalDataPath = "$env:USERPROFILE\TransferSpeedHistory.csv",
    [switch]$IncludeHistoricalComparison,
    [switch]$GenerateReport,
    [string]$ReportPath = "$env:USERPROFILE\TransferSpeedReport.html"
)

Import-Module "$PSScriptRoot\..\modules\ErrorHandling.psm1" -Force

Initialize-ScriptConfiguration -DefaultConfig (Get-DefaultConfiguration)
Initialize-Logging -Component "Measure-TransferSpeed"

function New-TestFile {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)]
        [string]$Path,
        [long]$SizeBytes
    )

    if (Test-Path $Path) {
        Remove-Item $Path -Force -ErrorAction SilentlyContinue
    }

    if ($SizeBytes -le 0) {
        return
    }

    & fsutil.exe file createnew "$Path" "$SizeBytes" 2>$null | Out-Null

    if (-not (Test-Path $Path)) {
        $stream = [System.IO.File]::Open($Path, [System.IO.FileMode]::CreateNew)
        try {
            $buffer = New-Object byte[] 65536
            $remaining = $SizeBytes
            while ($remaining -gt 0) {
                $chunk = [math]::Min($remaining, $buffer.Length)
                $stream.Write($buffer, 0, $chunk)
                $remaining -= $chunk
            }
        }
        finally {
            $stream.Close()
        }
    }
}

function Measure-TransferSpeed {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)]
        [string]$SourceServer,
        [Parameter(Mandatory=$true)]
        [string]$DestinationServer,
        [Parameter(Mandatory=$true)]
        [int]$FileSizeMB,
        [int]$Iterations = 1,
        [PSCredential]$Credential,
        [string]$HistoricalDataPath = "$env:USERPROFILE\TransferSpeedHistory.csv",
        [switch]$IncludeHistoricalComparison,
        [switch]$GenerateReport,
        [string]$ReportPath = "$env:USERPROFILE\TransferSpeedReport.html"
    )

    try {
        if ($SourceServer -match '[^a-zA-Z0-9.\-]' -or $DestinationServer -match '[^a-zA-Z0-9.\-]') {
            throw "Invalid server name detected. Server names should only contain alphanumeric characters, dots, and hyphens."
        }

        $sourceFile = "\\$SourceServer\c`$\Windows\Temp\TransferSpeedTest.dat"
        $destFile = "\\$DestinationServer\c`$\Windows\Temp\TransferSpeedTest.dat"
        $sourceDriveName = "TSrc"
        $destDriveName = "TDst"
        $testFilePath = $sourceFile
        $destFilePath = $destFile

        if ($Credential) {
            $sourceDriveName = "TSrc_$PID"
            $destDriveName = "TDst_$PID"
            New-PSDrive -Name $sourceDriveName -PSProvider FileSystem -Root "\\$SourceServer\c`$" -Credential $Credential -ErrorAction Stop | Out-Null
            New-PSDrive -Name $destDriveName -PSProvider FileSystem -Root "\\$DestinationServer\c`$" -Credential $Credential -ErrorAction Stop | Out-Null
            $testFilePath = "$($sourceDriveName):\Windows\Temp\TransferSpeedTest.dat"
            $destFilePath = "$($destDriveName):\Windows\Temp\TransferSpeedTest.dat"
        }

        try {
            Write-ScriptLog -Level Info -Message "Creating $FileSizeMB MB test file on $SourceServer"
            New-TestFile -Path $testFilePath -SizeBytes ($FileSizeMB * 1MB)

            $results = @()
            for ($i = 1; $i -le $Iterations; $i++) {
                Write-ScriptLog -Level Info -Message "Iteration ${i}: Transferring file from $SourceServer to $DestinationServer"

                if (Test-Path $destFilePath) {
                    Remove-Item -Path $destFilePath -Force -ErrorAction SilentlyContinue
                }

                $iterationStartTime = Get-Date
                Copy-Item -Path $testFilePath -Destination $destFilePath -ErrorAction Stop
                $iterationEndTime = Get-Date

                $duration = ($iterationEndTime - $iterationStartTime).TotalSeconds
                $speed = if ($duration -gt 0) { ($FileSizeMB * 1MB) / $duration } else { 0 }

                $results += [PSCustomObject]@{
                    Iteration = $i
                    Duration = $duration
                    Speed = $speed
                }

                Write-ScriptLog -Level Info -Message "Iteration ${i} - Duration: $([math]::Round($duration,3)) seconds, Speed: $([math]::Round($speed/1MB,2)) MB/s"
            }

            $lowestSpeed = ($results | Measure-Object -Property Speed -Minimum).Minimum
            $highestSpeed = ($results | Measure-Object -Property Speed -Maximum).Maximum
            $averageSpeed = ($results | Measure-Object -Property Speed -Average).Average

            Write-ScriptLog -Level Info -Message "Lowest: $([math]::Round($lowestSpeed/1MB,2)) MB/s - Highest: $([math]::Round($highestSpeed/1MB,2)) MB/s - Average: $([math]::Round($averageSpeed/1MB,2)) MB/s"

            $finalResult = [PSCustomObject]@{
                LowestSpeed = $lowestSpeed
                HighestSpeed = $highestSpeed
                AverageSpeed = $averageSpeed
            }

            $historicalResult = [PSCustomObject]@{
                Timestamp = Get-Date
                SourceServer = $SourceServer
                DestinationServer = $DestinationServer
                AverageSpeed = $averageSpeed
                LowestSpeed = $lowestSpeed
                HighestSpeed = $highestSpeed
                Iterations = $Iterations
                FileSizeMB = $FileSizeMB
            }

            $historicalResult | Export-Csv -Path $HistoricalDataPath -Append -NoTypeInformation -ErrorAction SilentlyContinue

            if ($IncludeHistoricalComparison) {
                $historicalData = @(Import-Csv $HistoricalDataPath -ErrorAction SilentlyContinue |
                    Where-Object {
                        $_.SourceServer -eq $SourceServer -and
                        $_.DestinationServer -eq $DestinationServer -and
                        $_.Timestamp -ne $historicalResult.Timestamp.ToString()
                    })

                $pastSpeeds = @($historicalData | ForEach-Object { [double]$_.AverageSpeed })

                if ($pastSpeeds.Count -gt 0) {
                    $historicalAvgValue = ($pastSpeeds | Measure-Object -Average).Average
                    $trend = if ($averageSpeed -gt $historicalAvgValue * 1.1) { "IMPROVED" }
                             elseif ($averageSpeed -lt $historicalAvgValue * 0.9) { "DEGRADED" }
                             else { "STABLE" }

                    Write-ScriptLog -Level Info -Message "Performance Trend: $trend (Current: $([math]::Round($averageSpeed/1MB, 2)) MB/s vs Historical Avg: $([math]::Round($historicalAvgValue/1MB, 2)) MB/s)"
                }
            }

            if ($GenerateReport) {
                Generate-TransferSpeedReport -ReportPath $ReportPath -CurrentResult $finalResult -HistoricalPath $HistoricalDataPath
            }

            return $finalResult
        }
        finally {
            if ($Credential) {
                Remove-PSDrive -Name $sourceDriveName -Force -ErrorAction SilentlyContinue
                Remove-PSDrive -Name $destDriveName -Force -ErrorAction SilentlyContinue
            }
            Remove-Item -Path $testFilePath -Force -ErrorAction SilentlyContinue
            Remove-Item -Path $destFilePath -Force -ErrorAction SilentlyContinue
        }
    }
    catch {
        Write-ScriptLog -Level Error -Message "An error occurred: $($_.Exception.Message)"
        throw
    }
}

function Test-NetworkLatency {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)]
        [string]$DestinationServer,
        [int]$PingCount = 10
    )

    $pings = @()
    for ($i = 1; $i -le $PingCount; $i++) {
        $ping = Test-Connection -ComputerName $DestinationServer -Count 1 -ErrorAction SilentlyContinue
        if ($ping) {
            $pings += $ping.ResponseTime
        }
    }

    if ($pings.Count -eq 0) {
        return $null
    }

    return [PSCustomObject]@{
        AverageLatency = ($pings | Measure-Object -Average).Average
        MinLatency = ($pings | Measure-Object -Minimum).Minimum
        MaxLatency = ($pings | Measure-Object -Maximum).Maximum
        PacketLoss = [math]::Round(((($PingCount - $pings.Count) / $PingCount) * 100), 2)
    }
}

function Measure-MultiPathTransfer {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)]
        [string]$SourceServer,
        [Parameter(Mandatory=$true)]
        [string[]]$DestinationServers,
        [int]$FileSizeMB = 100,
        [int]$Iterations = 1,
        [PSCredential]$Credential
    )

    $results = @()
    $index = 0
    foreach ($dest in $DestinationServers) {
        $index++
        Write-Progress -Activity "Testing Multi-Path Transfer" -Status "Testing: $dest" `
            -PercentComplete (($index / $DestinationServers.Count) * 100)

        try {
            $result = Measure-TransferSpeed -SourceServer $SourceServer -DestinationServer $dest `
                -FileSizeMB $FileSizeMB -Iterations $Iterations -Credential $Credential -ErrorAction Stop

            $results += [PSCustomObject]@{
                Destination = $dest
                SpeedMBps = [math]::Round($result.AverageSpeed/1MB, 2)
                LowestSpeedMBps = [math]::Round($result.LowestSpeed/1MB, 2)
                HighestSpeedMBps = [math]::Round($result.HighestSpeed/1MB, 2)
                Status = if ($result.AverageSpeed -gt 10MB) { "FAST" } else { "SLOW" }
            }
        }
        catch {
            $results += [PSCustomObject]@{
                Destination = $dest
                SpeedMBps = $null
                LowestSpeedMBps = $null
                HighestSpeedMBps = $null
                Status = "FAILED"
                Error = $_.Exception.Message
            }
        }
    }

    Write-Progress -Activity "Testing Multi-Path Transfer" -Completed
    return $results
}

function Measure-TransferSpeedWithThrottling {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)]
        [string]$SourceServer,
        [Parameter(Mandatory=$true)]
        [string]$DestinationServer,
        [int]$FileSizeMB = 100,
        [ValidateRange(1, 100000)]
        [int]$BandwidthLimitMbps = 100,
        [PSCredential]$Credential
    )

    $expectedTime = ($FileSizeMB * 8) / $BandwidthLimitMbps
    $result = Measure-TransferSpeed -SourceServer $SourceServer -DestinationServer $DestinationServer `
        -FileSizeMB $FileSizeMB -Credential $Credential
    $actualSpeedMBps = [math]::Round($result.AverageSpeed/1MB, 2)

    Write-Host "Expected time at $BandwidthLimitMbps Mbps: $([math]::Round($expectedTime, 2)) seconds"
    Write-Host "Actual speed: $actualSpeedMBps MB/s"

    $efficiency = if ($actualSpeedMBps -gt 0) {
        [math]::Round(($actualSpeedMBps * 8) / $BandwidthLimitMbps * 100, 1)
    } else { 0 }

    Write-Host "Efficiency: $efficiency%"

    return [PSCustomObject]@{
        ExpectedTime = $expectedTime
        ActualTime = if ($actualSpeedMBps -gt 0) { ($FileSizeMB * 8) / $actualSpeedMBps } else { $null }
        ExpectedSpeed = $BandwidthLimitMbps
        ActualSpeedMBps = $actualSpeedMBps
        EfficiencyPercent = $efficiency
    }
}

function ConvertTo-HtmlEncoded {
    [CmdletBinding()]
    param([string]$Value)

    if ([string]::IsNullOrEmpty($Value)) {
        return ''
    }

    return $Value -replace '&', '&amp;' -replace '<', '&lt;' -replace '>', '&gt;' -replace '"', '&quot;' -replace "'", '&#39;'
}

function Generate-TransferSpeedReport {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)]
        [string]$ReportPath,
        [Parameter(Mandatory=$true)]
        [PSCustomObject]$CurrentResult,
        [string]$HistoricalPath = "$env:USERPROFILE\TransferSpeedHistory.csv"
    )

    $historicalData = if (Test-Path $HistoricalPath) { @(Import-Csv $HistoricalPath) } else { @() }

    $html = @"
<!DOCTYPE html>
<html>
<head>
    <title>Transfer Speed Report</title>
    <style>
        body { font-family: Arial, sans-serif; margin: 20px; background: #f5f5f5; }
        .container { background: white; padding: 20px; border-radius: 8px; box-shadow: 0 2px 4px rgba(0,0,0,0.1); }
        .summary { background: #4CAF50; color: white; padding: 15px; border-radius: 5px; margin-bottom: 20px; }
        .metric { display: inline-block; margin: 10px 20px; }
        .metric-label { display: block; font-size: 12px; opacity: 0.9; }
        .metric-value { font-size: 24px; font-weight: bold; }
        table { width: 100%; border-collapse: collapse; margin-top: 20px; }
        th, td { border: 1px solid #ddd; padding: 12px; text-align: left; }
        th { background: #4CAF50; color: white; }
        tr:nth-child(even) { background: #f2f2f2; }
        .fast { color: #4CAF50; font-weight: bold; }
        .slow { color: #f44336; font-weight: bold; }
        .timestamp { color: #666; font-size: 12px; }
    </style>
</head>
<body>
    <div class="container">
        <h1>Transfer Speed Report</h1>
        <div class="timestamp">Generated: $(Get-Date)</div>

        <div class="summary">
            <h2>Current Performance</h2>
            <div class="metric">
                <span class="metric-label">Average Speed</span>
                <span class="metric-value">$([math]::Round($CurrentResult.AverageSpeed/1MB, 2)) MB/s</span>
            </div>
            <div class="metric">
                <span class="metric-label">Lowest Speed</span>
                <span class="metric-value">$([math]::Round($CurrentResult.LowestSpeed/1MB, 2)) MB/s</span>
            </div>
            <div class="metric">
                <span class="metric-label">Highest Speed</span>
                <span class="metric-value">$([math]::Round($CurrentResult.HighestSpeed/1MB, 2)) MB/s</span>
            </div>
        </div>

        <h2>Historical Performance</h2>
        <table>
            <tr>
                <th>Timestamp</th>
                <th>Source</th>
                <th>Destination</th>
                <th>Average (MB/s)</th>
                <th>Trend</th>
            </tr>
"@

    foreach ($entry in $historicalData | Select-Object -Last 10 | Sort-Object Timestamp -Descending) {
        $timestamp = [DateTime]$entry.Timestamp
        $speed = [double]$entry.AverageSpeed
        $trend = if ($speed -gt 10MB) { '<span class="fast">FAST</span>' } else { '<span class="slow">SLOW</span>' }
        $src = ConvertTo-HtmlEncoded -Value $entry.SourceServer
        $dst = ConvertTo-HtmlEncoded -Value $entry.DestinationServer

        $html += @"
            <tr>
                <td>$($timestamp.ToString('yyyy-MM-dd HH:mm'))</td>
                <td>$src</td>
                <td>$dst</td>
                <td>$([math]::Round($speed/1MB, 2))</td>
                <td>$trend</td>
            </tr>
"@
    }

    $html += @"
        </table>
    </div>
</body>
</html>
"@

    $html | Out-File -FilePath $ReportPath -Force
    Write-Host "Report generated: $ReportPath"
}

# ---- Main ----

if ($MultiPathTest -and $DestinationServers.Count -gt 0) {
    if (-not $SourceServer) {
        Write-ScriptLog -Level Error -Message "Multi-path test requires -SourceServer."
        exit 1
    }
    Measure-MultiPathTransfer -SourceServer $SourceServer -DestinationServers $DestinationServers `
        -FileSizeMB $FileSizeMB -Iterations $Iterations -Credential $Credential
    exit 0
}

if (-not $SourceServer -or -not $DestinationServer) {
    Write-ScriptLog -Level Error -Message "Specify -SourceServer and -DestinationServer (or -SourceServer with -DestinationServers and -MultiPathTest)."
    exit 1
}

$result = Measure-TransferSpeed -SourceServer $SourceServer -DestinationServer $DestinationServer `
    -FileSizeMB $FileSizeMB -Iterations $Iterations -Credential $Credential `
    -HistoricalDataPath $HistoricalDataPath -IncludeHistoricalComparison:$IncludeHistoricalComparison `
    -GenerateReport:$GenerateReport -ReportPath $ReportPath

if ($result) {
    Write-Host -Object ""
    Write-Host -Object "Results: Average $([math]::Round($result.AverageSpeed/1MB,2)) MB/s, " `
        "Lowest $([math]::Round($result.LowestSpeed/1MB,2)) MB/s, " `
        "Highest $([math]::Round($result.HighestSpeed/1MB,2)) MB/s"
}

exit 0
