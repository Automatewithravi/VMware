# =============================================================
# Script  : UserVars_ProductLockerLocation_update.ps1
# Author  : automatewithravi.com
# Purpose : Update UserVars.ProductLockerLocation on all ESXi
#           hosts in a specified vCenter cluster.
#
# How it works
# ─────────────────────────────────────────────────────────────
# 1. Prompts the operator for the vCenter FQDN/IP and the
#    datastore path where VMware Tools files are stored.
# 2. Prompts for a cluster name (defaults to all clusters if
#    left blank).
# 3. Connects to vCenter using a secure credential prompt.
# 4. For every ESXi host in the selected cluster(s) it uses
#    the vSphere API (AdvancedOption) to set:
#       UserVars.ProductLockerLocation = <your datastore path>
# 5. Prints a summary of updated and failed hosts.
#
# NOTE: ESXi host restarts are NOT performed by this script.
#       After the setting is applied across all hosts, schedule
#       reboots manually during your next maintenance window so
#       the /productLocker symlink is refreshed at boot time.
#
# Once hosts are rebooted, copy the latest VMware Tools depot
# files (currently v13.0.1) from Broadcom into the datastore
# path — every VM that powers on will pick up the new version.
#
# Broadcom references:
#   VMware Tools build numbers & versions:
#     https://knowledge.broadcom.com/external/article/304809/build-numbers-and-versions-of-vmware-too.html
#   ProductLocker shared datastore setup (KB 313876):
#     https://knowledge.broadcom.com/external/article/313876
# =============================================================

# ─────────────────────────────────────────────────────────────
# 1. USER INPUT – vCenter & ProductLocker path
# ─────────────────────────────────────────────────────────────
$vcenter = Read-Host -Prompt "Enter vCenter Server FQDN or IP (e.g. vcsa01.domain.local)"
if ([string]::IsNullOrWhiteSpace($vcenter)) {
    Write-Error "vCenter address cannot be empty. Exiting."
    exit 1
}

$productLockerPath = Read-Host -Prompt "Enter ProductLocker datastore path (e.g. /vmfs/volumes/<datastore-id>/.vmwaretools)"
if ([string]::IsNullOrWhiteSpace($productLockerPath)) {
    Write-Error "ProductLocker path cannot be empty. Exiting."
    exit 1
}

$clusterInput = Read-Host -Prompt "Enter Cluster name (leave blank to target ALL clusters in vCenter)"

# ─────────────────────────────────────────────────────────────
# 2. CONNECT TO vCENTER
# ─────────────────────────────────────────────────────────────
$cred = Get-Credential -Message "Enter vCenter credentials for $vcenter"
Set-PowerCLIConfiguration -InvalidCertificateAction Prompt -Confirm:$false | Out-Null

Write-Host "`nConnecting to vCenter: $vcenter ..." -ForegroundColor Cyan
Connect-VIServer -Server $vcenter -Credential $cred -ErrorAction Stop
Write-Host "Connected successfully.`n" -ForegroundColor Green

# ─────────────────────────────────────────────────────────────
# 3. RESOLVE CLUSTER(S)
# ─────────────────────────────────────────────────────────────
if ([string]::IsNullOrWhiteSpace($clusterInput)) {
    Write-Host "No cluster specified – targeting ALL clusters." -ForegroundColor Yellow
    $clusters = Get-Cluster
} else {
    $clusters = Get-Cluster -Name $clusterInput -ErrorAction Stop
}

if ($null -eq $clusters -or $clusters.Count -eq 0) {
    Write-Error "No clusters found. Check the name or permissions."
    Disconnect-VIServer -Confirm:$false
    exit 1
}

# ─────────────────────────────────────────────────────────────
# 4. UPDATE ProductLockerLocation ON EVERY HOST
# ─────────────────────────────────────────────────────────────
$updatedHosts   = @()
$failedHosts    = @()

foreach ($cluster in $clusters) {
    Write-Host "Processing cluster: $($cluster.Name)" -ForegroundColor Cyan
    $clusterHosts = Get-Cluster -Name $cluster.Name | Get-VMHost

    foreach ($esxiHost in $clusterHosts) {
        try {
            # Get the host's View object
            $hostView = Get-VMHost -Name $esxiHost | Get-View

            # Build the OptionValue object
            $option       = New-Object VMware.Vim.OptionValue
            $option.Key   = "UserVars.ProductLockerLocation"
            $option.Value = $productLockerPath

            # Apply via AdvancedOption API
            $adv = Get-View $hostView.ConfigManager.AdvancedOption
            $adv.UpdateOptions(@($option))

            Write-Host "  [OK] $esxiHost  →  $productLockerPath" -ForegroundColor Green
            $updatedHosts += $esxiHost
        }
        catch {
            Write-Warning "  [FAILED] $esxiHost  – $($_.Exception.Message)"
            $failedHosts += $esxiHost
        }
    }
}

# ─────────────────────────────────────────────────────────────
# 5. SUMMARY
# ─────────────────────────────────────────────────────────────
Write-Host "`n========== SUMMARY ==========" -ForegroundColor Cyan
Write-Host "vCenter          : $vcenter"
Write-Host "ProductLocker    : $productLockerPath"
Write-Host "Hosts updated    : $($updatedHosts.Count)"
Write-Host "Hosts failed     : $($failedHosts.Count)"
if ($failedHosts.Count -gt 0) {
    Write-Warning "Failed hosts: $($failedHosts -join ', ')"
}
Write-Host "==============================`n" -ForegroundColor Cyan
Write-Host "ACTION REQUIRED: Reboot all updated hosts at your next maintenance window" -ForegroundColor Yellow
Write-Host "to refresh the /productLocker symlink, then copy the latest VMware Tools" -ForegroundColor Yellow
Write-Host "depot files (v13.0.1) into: $productLockerPath" -ForegroundColor Yellow
Write-Host "`nBroadcom VMware Tools versions reference:" -ForegroundColor Cyan
Write-Host "https://knowledge.broadcom.com/external/article/304809/build-numbers-and-versions-of-vmware-too.html`n" -ForegroundColor Cyan

Disconnect-VIServer -Confirm:$false
Write-Host "Disconnected from $vcenter." -ForegroundColor Gray
