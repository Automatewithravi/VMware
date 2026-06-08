<#
.SYNOPSIS
    VMware Snapshot Report — PowerCLI + Email Alert
.DESCRIPTION
    Connects to a specified vCenter (Prod or DR), identifies all VMs
    with snapshots, exports a timestamped CSV, and emails the report.
.NOTES
    Author  : automatewithravi.com
    Version : 1.0
    All credentials and server names are injected via Jenkins env vars.
#>

# ── Initialise transcript log ──────────────────────────────────────────────
$Timestamp  = Get-Date -Format 'MM-dd-yyyy_HHmmss'
$LogPath    = "C:\Jenkins_Logs\SnapshotReport_$Timestamp.txt"
$CsvPath    = "C:\Jenkins_Reports\VMSnapshots_$Timestamp.csv"
New-Item -ItemType Directory -Force -Path "C:\Jenkins_Logs"    | Out-Null
New-Item -ItemType Directory -Force -Path "C:\Jenkins_Reports" | Out-Null
Start-Transcript -Path $LogPath -NoClobber -IncludeInvocationHeader

# ── Read credentials from Jenkins environment variables ────────────────────
$vCenter  = $Env:VCENTER_SERVER   # e.g. prod-vcenter.corp.local or dr-vcenter.corp.local
$Username = $Env:VCENTER_USER
$Password = $Env:VCENTER_PASS
$SmtpServer   = $Env:SMTP_SERVER      # e.g. smtp.corp.local
$EmailFrom    = $Env:SMTP_FROM        # e.g. alerts@automatewithravi.com
$EmailTo      = $Env:SMTP_TO          # e.g. infra-team@automatewithravi.com
$Environment  = $Env:ENVIRONMENT      # "Prod" or "DR"

# ── Connect to vCenter ─────────────────────────────────────────────────────
Write-Host "[INFO] Connecting to $Environment vCenter: $vCenter"

try {
    $Connection = Connect-VIServer -Server $vCenter -User $Username -Password $Password -ErrorAction Stop
} catch {
    Write-Error "[ERROR] Unable to connect to $Environment vCenter ($vCenter). $_"
    Stop-Transcript
    exit 1
}

if (-not $Connection.IsConnected) {
    Write-Error "[ERROR] vCenter connection check failed."
    Stop-Transcript
    exit 1
}
Write-Host "[INFO] Successfully connected to $Environment vCenter."

# ── Collect snapshot data ──────────────────────────────────────────────────
Write-Host "[INFO] Retrieving VM snapshots..."

$Snapshots = Get-VM | Get-Snapshot | Select-Object `
    VM,
    Name,
    Description,
    @{Label = "SizeGB";  Expression = { "{0:N2} GB" -f $_.SizeGB }},
    Created,
    @{Label = "AgeDays"; Expression = { (New-TimeSpan -Start $_.Created -End (Get-Date)).Days }},
    @{Label = "Environment"; Expression = { $Environment }}

Write-Host "[INFO] Total snapshots found: $($Snapshots.Count)"

# ── Export CSV ─────────────────────────────────────────────────────────────
$Snapshots | Export-Csv -Path $CsvPath -NoTypeInformation -UseCulture
Write-Host "[INFO] CSV exported to: $CsvPath"

# ── Send email alert ───────────────────────────────────────────────────────
if ($Snapshots.Count -gt 0) {
    $Subject = "[$Environment] VMware Snapshot Report — $($Snapshots.Count) snapshot(s) found — $(Get-Date -Format 'dd MMM yyyy')"
    $Body = @"
Hi Team,

The automated snapshot audit has completed for the <b>$Environment</b> vCenter environment.

Summary:
  - vCenter   : $vCenter
  - Environment : $Environment
  - Total Snapshots : $($Snapshots.Count)
  - Report Date  : $(Get-Date -Format 'dd MMMM yyyy HH:mm')

Please review the attached CSV report and action any snapshots older than your retention policy.

-- Automated Report via Jenkins | automatewithravi.com
"@

    Send-MailMessage `
        -From       $EmailFrom `
        -To         ($EmailTo -split ",") `
        -Subject    $Subject `
        -Body       $Body `
        -BodyAsHtml `
        -Attachments $CsvPath `
        -SmtpServer $SmtpServer

    Write-Host "[INFO] Email alert sent to: $EmailTo"
} else {
    Write-Host "[INFO] No snapshots found. No email sent."
}

# ── Disconnect and cleanup ─────────────────────────────────────────────────
Disconnect-VIServer -Server $vCenter -Confirm:$false
Write-Host "[INFO] Disconnected from vCenter. Job complete."
Stop-Transcript
