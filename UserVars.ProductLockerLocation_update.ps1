# -----------------------------
# Variables (edit these)
# -----------------------------
$vcenter = "tn-vt-vcsa01.transit.local" 
$productLockerPath = "/vmfs/volumes/6424451e-72740fb8-bcab-0c42a15da24c/.vmwaretools"

# -----------------------------
# Connect to vCenter
# -----------------------------
$cred = Get-Credential
Set-PowerCLIConfiguration -InvalidCertificateAction Prompt -Confirm:$false
Connect-VIServer -Server $vcenter -Credential $cred

$cluster = "Transit"
$clusterHosts = Get-Cluster -Name $cluster | Get-VMHost
foreach($esxiHost in $clusterHosts)  {
# -----------------------------
# Get ESXi host VIEW object
# -----------------------------
$hostView = Get-VMHost -Name $esxiHost | Get-View

# -----------------------------
# Build the option value object
# -----------------------------
$option = New-Object VMware.Vim.OptionValue
$option.Key   = "UserVars.ProductLockerLocation"
$option.Value = $productLockerPath

# -----------------------------
# Update ESXi advanced settings
# -----------------------------
$adv = Get-View $hostView.ConfigManager.AdvancedOption
$adv.UpdateOptions(@($option))

Write-Host "Successfully updated UserVars.ProductLockerLocation on $esxiHost"

}

Disconnect-VIServer -Confirm:$false