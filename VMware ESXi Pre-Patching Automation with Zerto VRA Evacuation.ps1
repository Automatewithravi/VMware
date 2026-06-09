<#
.SYNOPSIS
    VMware ESXi Pre-Patching Automation with Zerto VRA Evacuation

.DESCRIPTION
    This script automates the full lifecycle of ESXi host patching within a vSphere DRS cluster.
    It performs the following steps in sequence:

    PHASE 1 - PRE-PATCHING:
        1. Validates connectivity to vCenter Server
        2. Sets DRS cluster automation mode to "Manual" (prevents accidental VM moves during migration)
        3. Disables all DRS rules and VM Host rules (except Zerto rules which are left intact)
        4. Migrates all powered-on VMs (excluding Zerto VRAs) off the target ESXi host
           - Uses memory and CPU threshold checks before placing each VM on a destination host
        5. Evacuates the Zerto VRA from the target host via Zerto REST API
        6. Powers off the Zerto VRA VM and places the ESXi host into Maintenance Mode

    PHASE 2 - PATCHING:
        7. Uses ESXCLI to apply the target ESXi software profile from a datastore ISO/depot
        8. Reboots the host if required after patching
        9. Waits for the host to become pingable again

    PHASE 3 - POST-PATCHING:
        10. Verifies the correct ESXi profile is applied post-reboot
        11. Re-enables DRS (Fully Automated) and all previously disabled DRS/VM Host rules
        12. Takes the host out of Maintenance Mode and reconnects it to the cluster
        13. Sends email notifications at each key milestone

.PARAMETER FromVMHostName
    FQDN of the ESXi host to patch, passed as an environment variable.
    Example: esx101.yourdomain.local

.NOTES
    Author      : Ravindrakumar Narayanan | automatewithravi.com
    Blog        : https://automatewithravi.com
    GitHub      : https://github.com/automatewithravi
    Version     : 1.3
    Requires    : VMware PowerCLI, Zerto API v1 access

    USAGE:
        Set the following environment variables before running:
            $Env:Username       = "vcenter-service-account"
            $Env:Password       = "YourPassword"
            $Env:FromVMHostName = "esx101.yourdomain.local"

        Then execute:
            .\VMware-ESXi-PrePatching-Automation.ps1

    IMPORTANT:
        - Zerto VRA identifiers in this script are environment-specific.
          Run 'GET /v1/vras' against your Zerto Virtual Manager (ZVM) to retrieve
          the correct VraIdentifier values for your environment.
        - The patch depot path must be accessible from the ESXi host (shared datastore).
        - SMTP relay must be reachable from the machine running this script.
#>

# ─────────────────────────────────────────────────────────────────────────────
# TRANSCRIPT LOGGING
# Captures all console output to a log file for audit and troubleshooting.
# ─────────────────────────────────────────────────────────────────────────────
Start-Transcript -Path "C:\Patching\PS-logs.txt" -Append


# ─────────────────────────────────────────────────────────────────────────────
# CONFIGURATION — READ FROM ENVIRONMENT VARIABLES
# Credentials and the target host FQDN are injected via environment variables.
# This avoids hardcoding sensitive values into the script.
# ─────────────────────────────────────────────────────────────────────────────
$Username       = $Env:Username
$Password       = $Env:Password
$FromVMHostName = $Env:FromVMHostName   # FQDN of the ESXi host to patch

# vCenter connection details — update $vcserver for your environment
$vcserver   = "vcenter.yourdomain.local"
$vcusername = $Username
$vcpassword = $Password

# Target DRS cluster name
$ClusterName = "Cluster01"

# Memory utilisation ceiling — do not migrate a VM to a host already above this %
[int]$MaxMemAllowed = 85

# ─────────────────────────────────────────────────────────────────────────────
# ZERTO VIRTUAL MANAGER (ZVM) CONNECTION DETAILS
# The Zerto REST API is used to trigger VRA (Virtual Replication Appliance)
# evacuation before the host is placed into maintenance mode.
# ─────────────────────────────────────────────────────────────────────────────
$strZVMIP   = "172.16.130.10"   # IP of your Zerto Virtual Manager
$strZVMPort = "9669"            # Default Zerto API port
$strZVMUser = $Username
$strZVMPwd  = $Password

# ─────────────────────────────────────────────────────────────────────────────
# ZERTO VRA IDENTIFIERS — ENVIRONMENT SPECIFIC
# Each ESXi host has a unique VRA with a unique VraIdentifier in Zerto.
# To find these values, authenticate to your ZVM and call:
#   GET https://<ZVM_IP>:9669/v1/vras
# Then match the VraName or HostDisplayName field to your ESXi hosts.
# ─────────────────────────────────────────────────────────────────────────────
$ZertoVraIds = @{
    "esx101.yourdomain.local" = "2724388199262172525"
    "esx102.yourdomain.local" = "2724388199262170715"
    "esx103.yourdomain.local" = "2724388199262168037"
    "esx104.yourdomain.local" = "2724388199262150817"
    "esx105.yourdomain.local" = "2724388199262166431"
    "esx106.yourdomain.local" = "2724388199262167455"
    "esx107.yourdomain.local" = "2724388199262167460"
    "esx108.yourdomain.local" = "2724388199262171628"
    "esx109.yourdomain.local" = "2724388199262174116"
    "esx110.yourdomain.local" = "2724388199262174986"
}

# ─────────────────────────────────────────────────────────────────────────────
# EMAIL NOTIFICATION SETTINGS
# A simple SMTP relay is used for milestone notifications.
# Update SmtpServer, From, and To addresses for your environment.
# ─────────────────────────────────────────────────────────────────────────────
$SmtpServer   = "172.0.2.35"
$MailFrom     = "vmware-automation@yourdomain.local"
$MailTo       = "infra-alerts@yourdomain.local"

# ─────────────────────────────────────────────────────────────────────────────
# ESXi PATCH DEPOT DETAILS
# The patch depot is a ZIP file hosted on a shared datastore accessible by ESXCLI.
# Update $PatchDepotPath to point to the correct image on your environment's datastore.
# ─────────────────────────────────────────────────────────────────────────────
$PatchDepotPath = "/vmfs/volumes/Datastore-Library/ISO/Patches/VMware-ESXi-7.0.3-XXXXXXX-OEM-YYYYMMDD.zip"


# ─────────────────────────────────────────────────────────────────────────────
# HELPER FUNCTION — SEND EMAIL
# Wraps Send-MailMessage so that sending notifications stays DRY (Don't Repeat Yourself).
# ─────────────────────────────────────────────────────────────────────────────
function Send-Notification {
    param(
        [string]$Subject,
        [string]$Body
    )
    Send-MailMessage -SmtpServer $SmtpServer `
                     -From $MailFrom `
                     -To $MailTo `
                     -Subject $Subject `
                     -Body $Body
}


# ─────────────────────────────────────────────────────────────────────────────
# HELPER FUNCTION — ZERTO AUTHENTICATION
# Obtains an x-zerto-session token using Basic authentication.
# This token must be included in the header of all subsequent Zerto API calls.
# ─────────────────────────────────────────────────────────────────────────────
function Get-ZertoSession {
    param(
        [string]$ZvmUser,
        [string]$ZvmPassword
    )
    $baseURL            = "https://$strZVMIP`:$strZVMPort"
    $sessionURI         = "$baseURL/v1/session/add"

    # Encode credentials as Base64 for Basic auth header
    $authBytes          = [System.Text.Encoding]::UTF8.GetBytes("$ZvmUser`:$ZvmPassword")
    $authBase64         = [System.Convert]::ToBase64String($authBytes)
    $authHeader         = @{ Authorization = "Basic $authBase64" }

    $body               = '{"AuthenticationMethod": "1"}'
    $response           = Invoke-WebRequest -Uri $sessionURI `
                                            -Headers $authHeader `
                                            -Method POST `
                                            -Body $body `
                                            -ContentType "application/json" `
                                            -SkipCertificateCheck

    # Return the session token from the response header
    return $response.Headers.get_item("x-zerto-session")
}


# ─────────────────────────────────────────────────────────────────────────────
# HELPER FUNCTION — EVACUATE ZERTO VRA
# Calls the Zerto API to move all VPGs protected by the VRA on the target host
# to a different VRA on another host. Polls for task completion.
# ─────────────────────────────────────────────────────────────────────────────
function Invoke-ZertoVRAEvacuation {
    param(
        [string]$VraIdentifier,
        [hashtable]$ZertoHeader,
        [object]$EvacuatePayload
    )

    $baseURL    = "https://$strZVMIP`:$strZVMPort"
    $executeURI = "$baseURL/v1/vras/$VraIdentifier/changerecoveryvra/execute"

    Write-Host "Triggering Zerto VRA evacuation for host: $FromVMHostName" -ForegroundColor Cyan

    # POST to kick off the evacuation — returns a task ID
    $taskId     = Invoke-RestMethod -Uri $executeURI `
                                    -Headers $ZertoHeader `
                                    -Body ($EvacuatePayload | ConvertTo-Json) `
                                    -ContentType "application/json" `
                                    -Method Post `
                                    -SkipCertificateCheck

    $taskURI    = "$baseURL/v1/tasks/$taskId"

    # Poll 1 — wait ~90 seconds and check task progress
    Write-Host "Waiting 90 seconds for VRA evacuation to progress..."
    Start-Sleep -Seconds 90

    $taskStatus = (Invoke-RestMethod -Uri $taskURI -Headers $ZertoHeader -ContentType "application/json" -SkipCertificateCheck).Status.Progress

    if ($taskStatus -eq 100) {
        Write-Host "Zerto VRA evacuation completed successfully." -ForegroundColor Green
        return $true
    }

    # Poll 2 — wait an additional 2 minutes if not yet complete
    Write-Host "Evacuation still in progress — waiting an additional 2 minutes..."
    Start-Sleep -Seconds 120

    $taskStatus2 = (Invoke-RestMethod -Uri $taskURI -Headers $ZertoHeader -ContentType "application/json" -SkipCertificateCheck).Status.Progress

    if ($taskStatus2 -eq 100) {
        Write-Host "Zerto VRA evacuation completed successfully (after second poll)." -ForegroundColor Green
        return $true
    }

    Write-Host "ERROR: VRA evacuation did not complete within the allowed time. Please check ZVM." -ForegroundColor Red
    return $false
}


# ═════════════════════════════════════════════════════════════════════════════
# PHASE 1 — VCENTER CONNECTION AND PRE-FLIGHT VALIDATION
# ═════════════════════════════════════════════════════════════════════════════

# Import required VMware PowerCLI modules
Import-Module "VMware.VimAutomation.Vds",
              "VMware.VimAutomation.Cloud",
              "VMware.VimAutomation.Storage",
              "VMware.VumAutomation",
              "VMware.DeployAutomation"

# Test TCP port 443 reachability to vCenter before attempting login
$VcenterNetTest   = Test-NetConnection -ComputerName $vcserver -Port 443
$VcenterReachable = $VcenterNetTest.TcpTestSucceeded

Try {
    if (-not $VcenterReachable) {
        Write-Host "ERROR: Cannot reach $vcserver on port 443. Exiting." -ForegroundColor Red
        Exit 1
    }
    Write-Host "$vcserver is reachable. Proceeding with login." -ForegroundColor Green

    # Connect to vCenter
    $VcenterConnection = Connect-VIServer -Server $vcserver -User $vcusername -Password $vcpassword
    Set-PowerCLIConfiguration -DefaultVIServerMode multiple -Confirm:$false

    if (-not $VcenterConnection.IsConnected) {
        Write-Host "ERROR: Failed to connect to $vcserver. Check credentials." -ForegroundColor Red
        Exit 1
    }
    Write-Host "Successfully connected to vCenter: $vcserver" -ForegroundColor Green

    # ─────────────────────────────────────────────────────────────────────────
    # DRS — SET TO MANUAL
    # Switching DRS to Manual prevents the cluster from automatically moving
    # VMs while we are doing controlled vMotions during the pre-patching phase.
    # ─────────────────────────────────────────────────────────────────────────
    $Cluster     = Get-Cluster -Name $ClusterName
    $Cluster_DRS = $Cluster.DrsEnabled

    if ($Cluster_DRS -eq $true -and $Cluster.Name -like $ClusterName) {
        Write-Host "Setting DRS to Manual on cluster: $ClusterName" -ForegroundColor Yellow
        Set-Cluster -Cluster $ClusterName -DRSEnabled:$true -DrsAutomationLevel "Manual" -Confirm:$false
    }
    else {
        Write-Host "DRS is not enabled on $ClusterName or cluster name mismatch. Exiting." -ForegroundColor Red
        Exit 1
    }
}
Catch [Exception] {
    Write-Host "EXCEPTION during vCenter connection/DRS setup: $($_.Exception.Message)" -ForegroundColor Red
    Break
}


# ─────────────────────────────────────────────────────────────────────────────
# DRS — DISABLE RULES (EXCEPT ZERTO)
# DRS VM rules and VM-Host rules can block vMotion.
# We disable all non-Zerto rules to allow free VM placement during evacuation.
# Zerto rules are left enabled because Zerto manages its own replication placement.
# ─────────────────────────────────────────────────────────────────────────────
Try {
    if ($Cluster_DRS -eq $true -and $Cluster.Name -like $ClusterName) {
        Write-Host "Disabling non-Zerto DRS VM Rules and VM Host Rules..." -ForegroundColor Yellow

        Get-Cluster -Name $ClusterName | Get-DrsRule        | Where-Object { $_.Name -notlike "*Zerto*" } | Set-DrsRule -Enabled:$false
        Get-Cluster -Name $ClusterName | Get-DrsVMHostRule  | Where-Object { $_.Name -notlike "Zerto*"  } | Set-DrsVMHostRule -Enabled:$false

        Write-Host "Non-Zerto DRS rules disabled successfully." -ForegroundColor Green
    }
    else {
        Write-Host "DRS is not enabled — cannot disable DRS rules. Exiting." -ForegroundColor Red
        Exit 1
    }
}
Catch [Exception] {
    Write-Host "EXCEPTION while disabling DRS rules: $($_.Exception.Message)" -ForegroundColor Red
    Break
}


# ═════════════════════════════════════════════════════════════════════════════
# PHASE 2 — VM EVACUATION (vMOTION)
# For each powered-on VM on the source host (excluding Z-VRA* appliances),
# find the least-loaded destination host that meets memory and CPU thresholds,
# then vMotion the VM to it.
# ═════════════════════════════════════════════════════════════════════════════

# Get all powered-on VMs on the target host, excluding Zerto VRAs (handled separately)
$VMsInHost = Get-VMHost -Name $FromVMHostName | Get-VM |
             Where-Object { $_.PowerState -like "*On" -and $_.Name -notlike "Z-VRA*" }

foreach ($SingleVM in $VMsInHost) {

    # Build a sorted list of eligible destination hosts:
    #   - Not the source host itself
    #   - Not in Maintenance mode
    #   - Not in NotResponding or Unknown state
    #   - Sorted by ascending MemoryUsageGB (least loaded first)
    $WorkingNodes = Get-Cluster -Name $ClusterName -ErrorAction Stop |
                    Get-VMHost |
                    Where-Object {
                        $_.Name            -notlike $FromVMHostName   -and
                        $_.ConnectionState -notlike "*ain*"           -and   # excludes "Maintenance"
                        $_.ConnectionState -notlike "NotResponding"   -and
                        $_.ConnectionState -notlike "Unknown"
                    } |
                    Sort-Object -Property MemoryUsageGB

    $Migrated = $false

    # Iterate through candidate hosts in order of free memory until a suitable one is found
    foreach ($DestHost in $WorkingNodes) {

        # Calculate projected memory usage on the destination after placing this VM
        [int]$ProjectedMemGB  = $DestHost.MemoryUsageGB + $SingleVM.MemoryGB
        [int]$MemPercent      = $ProjectedMemGB / (Get-VMHost -Name $DestHost.Name -ErrorAction Stop).MemoryTotalGB * 100

        # Calculate current CPU utilisation on the destination
        [int]$CPUPercent      = $DestHost.CpuUsageMhz / $DestHost.CpuTotalMhz * 100

        Write-Host "Evaluating destination [$($DestHost.Name)] — Projected Mem: $MemPercent%, CPU: $CPUPercent%"

        # Only migrate if both memory and CPU thresholds are within acceptable limits
        if ($MemPercent -lt $MaxMemAllowed -and $CPUPercent -lt 95) {
            Try {
                Write-Host "Migrating [$($SingleVM.Name)] to [$($DestHost.Name)]..." -ForegroundColor Green
                Move-VM -VM $SingleVM.Name -Destination $DestHost.Name -ErrorAction Stop
                Write-Host "[$($SingleVM.Name)] successfully moved to [$($DestHost.Name)]." -ForegroundColor Green
                $Migrated = $true
                Break   # Move to the next VM once this one is successfully migrated
            }
            Catch {
                Write-Host "FAILED to migrate [$($SingleVM.Name)] to [$($DestHost.Name)]: $($_.Exception.Message)" -ForegroundColor Red
            }
        }
        else {
            Write-Host "Skipping [$($DestHost.Name)] — thresholds exceeded (Mem: $MemPercent%, CPU: $CPUPercent%)" -ForegroundColor Yellow
        }
    }

    if (-not $Migrated) {
        Write-Host "WARNING: Could not find a suitable host for [$($SingleVM.Name)]. Manual intervention required." -ForegroundColor Red
    }
}

Write-Host "All non-VRA powered-on VMs have been processed for migration." -ForegroundColor Cyan

# Notify the team that vMotion phase is complete
Send-Notification `
    -Subject ("Pre-Patching vMotion Complete — " + (Get-Date -Format dd-MM-yyyy)) `
    -Body "Hi Team,`n`nvMotion of all powered-on VMs (excluding Zerto VRA appliances) from $FromVMHostName has completed.`nZerto VRA evacuation will now begin.`n`nThis is an automated notification — please do not reply."


# ═════════════════════════════════════════════════════════════════════════════
# PHASE 3 — ZERTO VRA EVACUATION
# Uses the Zerto REST API to move VPG protection to another VRA before
# putting the host into maintenance mode.
# ═════════════════════════════════════════════════════════════════════════════

Write-Host "Starting Zerto VRA evacuation from: $FromVMHostName" -ForegroundColor Cyan

# Authenticate to the Zerto Virtual Manager and obtain a session token
$xZertoSession    = Get-ZertoSession -ZvmUser $strZVMUser -ZvmPassword $strZVMPwd
$ZertoHeader      = @{ "x-zerto-session" = $xZertoSession }

# Load the evacuation request payload from a JSON file.
# This JSON specifies how Zerto should redistribute the VPGs off the source VRA.
#
# ─────────────────────────────────────────────────────────────────────────────
# FILE:  C:\Patching\Evacuate.json
# ─────────────────────────────────────────────────────────────────────────────
# Save the content below as Evacuate.json on the Jenkins Windows agent
# at C:\Patching\Evacuate.json before running this script.
#
# {
#   "vmsAllocations": [
#     {
#       "hostIdentifier": null,
#       "vmIdentifier"  : null
#     }
#   ]
# }
#
# EXPLANATION OF VALUES:
#   "vmsAllocations"  — Array of VM-to-host mappings for the evacuation.
#   "hostIdentifier"  — The Zerto host ID to move VPGs to.
#                       Set to null to let Zerto automatically select
#                       the best available host/VRA. This is the
#                       recommended value for routine host maintenance.
#   "vmIdentifier"    — The Zerto VM identifier.
#                       Set to null to evacuate ALL VMs protected by
#                       the source VRA (the full host evacuation).
#
# Setting both values to null is intentional — it is NOT a placeholder.
# It instructs the Zerto API to perform a full blanket evacuation and
# let its internal load-balancing decide the target VRA automatically.
#
# OPTIONAL — target a specific host instead:
# If you need to direct VPGs to a specific host rather than letting Zerto
# choose, replace the hostIdentifier null with the Zerto host identifier:
#   GET https://<ZVM_IP>:9669/v1/virtualizationsites/{siteId}/hosts
# ─────────────────────────────────────────────────────────────────────────────
$EvacuatePayload  = Get-Content -Raw "C:\Patching\Evacuate.json" | ConvertFrom-Json

# Look up this host's VRA identifier from the configuration hashtable
if (-not $ZertoVraIds.ContainsKey($FromVMHostName)) {
    Write-Host "ERROR: No VRA identifier configured for host '$FromVMHostName'. Please update `$ZertoVraIds." -ForegroundColor Red
    Exit 1
}

$VraId = $ZertoVraIds[$FromVMHostName]

# Execute the VRA evacuation and poll for completion
$EvacuationSuccess = Invoke-ZertoVRAEvacuation -VraIdentifier $VraId `
                                               -ZertoHeader $ZertoHeader `
                                               -EvacuatePayload $EvacuatePayload

if ($EvacuationSuccess) {
    Send-Notification `
        -Subject ("Zerto VRA Evacuation Complete — " + (Get-Date -Format dd-MM-yyyy)) `
        -Body "Hi Team,`n`nZerto VRA evacuation from $FromVMHostName has completed. All VPGs have been moved to alternate VRAs.`n`nThis is an automated notification — please do not reply."
}
else {
    Write-Host "ERROR: Zerto VRA evacuation did not complete. Exiting." -ForegroundColor Red
    Exit 1
}


# ═════════════════════════════════════════════════════════════════════════════
# PHASE 4 — POWER OFF ZERTO VRA VM AND ENTER MAINTENANCE MODE
# After the VRA has handed off its VPGs, we gracefully power it off and
# then place the ESXi host into Maintenance Mode.
# ═════════════════════════════════════════════════════════════════════════════

# Find any remaining powered-on VMs on the source host (should only be the VRA now)
$RemainingVMs     = Get-VMHost -Name $FromVMHostName | Get-VM | Where-Object { $_.PowerState -like "*On" }
$RemainingVMNames = $RemainingVMs.Name

# Find the VRA VM by name pattern (Zerto VRA names typically contain "VRA-")
$VRAVMName        = $RemainingVMNames | Select-String -SimpleMatch "VRA-"

if ($VRAVMName) {
    Write-Host "Sending graceful shutdown to Zerto VRA VM: $VRAVMName" -ForegroundColor Yellow

    # Stop-VMGuest sends a graceful OS-level shutdown (equivalent to clicking Shut Down in the guest)
    Get-VMHost -Name $FromVMHostName | Get-VM | Where-Object { $_.Name -like $VRAVMName } |
        Stop-VMGuest -Confirm:$false

    # Allow time for the guest OS to shut down cleanly
    Start-Sleep -Seconds 30
}

# Check how many VMs are still powered on after the graceful shutdown
$StillRunning = Get-VMHost -Name $FromVMHostName | Get-VM | Where-Object { $_.PowerState -like "*On" }
$StillCount   = ($StillRunning.Name).Count

# If exactly one VM remains (possibly the VRA didn't shut down via guest tools), force power it off
if ($StillCount -eq 1) {
    $LastVM = (Get-VMHost -Name $FromVMHostName | Get-VM | Where-Object { $_.PowerState -like "*On" }).Name
    Write-Host "Force-powering off remaining VM: $LastVM" -ForegroundColor Yellow
    Get-VMHost -Name $FromVMHostName | Get-VM | Where-Object { $_.Name -like $LastVM } |
        Stop-VM -Confirm:$false
}
elseif ($StillCount -gt 1) {
    Write-Host "ERROR: More than one VM still running on $FromVMHostName. Please investigate before entering maintenance mode." -ForegroundColor Red
    Exit 1
}

# Confirm no VMs remain powered on before setting maintenance mode
$FinalPoweredOn = (Get-VMHost -Name $FromVMHostName | Get-VM | Where-Object { $_.PowerState -like "*On" }).Count

if ($FinalPoweredOn -eq 0) {
    Write-Host "No VMs running on $FromVMHostName. Setting host to Maintenance Mode..." -ForegroundColor Cyan
    Get-VMHost -Name $FromVMHostName | Set-VMHost -State Maintenance
}
else {
    Write-Host "ERROR: Unable to confirm zero powered-on VMs. Aborting maintenance mode." -ForegroundColor Red
    Exit 1
}

# Verify Maintenance Mode was applied successfully
$MaintenanceState = (Get-VMHost -Name $FromVMHostName).ConnectionState

if ($MaintenanceState -eq "Maintenance") {
    Write-Host "$FromVMHostName is now in Maintenance Mode." -ForegroundColor Green
    Send-Notification `
        -Subject ("Maintenance Mode Active: $FromVMHostName — " + (Get-Date -Format dd-MM-yyyy)) `
        -Body "Hi Team,`n`n$FromVMHostName has successfully entered Maintenance Mode and is ready for patching.`n`nThis is an automated notification — please do not reply."
}
else {
    Write-Host "ERROR: $FromVMHostName did not enter Maintenance Mode." -ForegroundColor Red
    Send-Notification `
        -Subject ("ALERT: Maintenance Mode Failed — $FromVMHostName") `
        -Body "Hi Team,`n`nMaintenance Mode could NOT be set on $FromVMHostName. Please check the transcript logs and cluster status.`n`nThis is an automated notification — please do not reply."
    Exit 1
}


# ═════════════════════════════════════════════════════════════════════════════
# PHASE 5 — ESXi PATCHING VIA ESXCLI
# Uses the ESXCLI v2 interface (PowerCLI) to apply a software profile from
# a depot ZIP image stored on a shared datastore.
# The host must already be in Maintenance Mode before patching begins.
# ═════════════════════════════════════════════════════════════════════════════

if ($MaintenanceState -eq "Maintenance") {

    Write-Host "Initialising ESXCLI for host: $FromVMHostName" -ForegroundColor Cyan
    $ESXiCLI = Get-EsxCli -VMHost $FromVMHostName -V2

    # Confirm the host is reporting Maintenance Mode via ESXCLI (belt-and-suspenders check)
    $ESXiInMaintenance = $ESXiCLI.system.maintenanceMode.get.Invoke()

    # Enumerate available software profiles inside the depot ZIP
    # The depot is a self-contained offline bundle that includes profile metadata
    $TargetProfileName  = $ESXiCLI.software.sources.profile.list.Invoke(@{ 'depot' = $PatchDepotPath }).Name

    # Zerto example naming convention: the installed profile is suffixed with "(Updated)"
    # after upgrade — build the expected post-patch profile name for comparison
    $ExpectedPostPatch  = "(Updated) $TargetProfileName"

    # Get the currently installed profile name on the host
    $CurrentProfileName = ($ESXiCLI.software.profile.get.Invoke()).Name

    Write-Host "Current profile : $CurrentProfileName"
    Write-Host "Target profile  : $TargetProfileName"

    if ($ESXiInMaintenance -eq "Enabled" -and $ExpectedPostPatch -ne $CurrentProfileName) {

        Write-Host "Applying patch profile: $TargetProfileName" -ForegroundColor Yellow

        # software.profile.update applies the specified profile from the depot.
        # Unlike 'install', 'update' preserves VIB configuration and is the recommended
        # method for incremental patching.
        $UpdateResult        = $ESXiCLI.software.profile.update.invoke(@{
            'depot'   = $PatchDepotPath
            'profile' = $TargetProfileName
        })

        Write-Host "Patch result message : $($UpdateResult.Message)"
        Write-Host "Reboot required      : $($UpdateResult.RebootRequired)"

        # If the update requires a reboot (virtually always true for ESXi patches), restart the host
        if ($UpdateResult.RebootRequired -eq $true -and $ESXiInMaintenance -eq "Enabled") {
            Write-Host "Rebooting $FromVMHostName..." -ForegroundColor Yellow
            Restart-VMhost -VMHost $FromVMHostName -Force:$true -Confirm:$false
        }
    }
    else {
        Write-Host "Host is either not in maintenance mode or already running the target profile. Skipping patch." -ForegroundColor Yellow
    }

    # ─────────────────────────────────────────────────────────────────────────
    # WAIT FOR HOST TO REBOOT AND BECOME PINGABLE
    # Pause briefly then poll ICMP until the host responds.
    # The 60-second initial sleep gives the host time to begin shutting down
    # before we start pinging, avoiding a false "still up" positive.
    # ─────────────────────────────────────────────────────────────────────────
    Write-Host "Waiting for $FromVMHostName to come back online after reboot..."
    Start-Sleep -Seconds 60

    do {
        $HostPingable = Test-Connection -ComputerName $FromVMHostName -Quiet
    } until ($HostPingable -eq $true)

    Write-Host "$FromVMHostName is responding to ping." -ForegroundColor Green

    # Allow additional time for all ESXi services to fully initialise before reconnecting
    Start-Sleep -Seconds 120
}
else {
    Write-Host "ERROR: $FromVMHostName is not in Maintenance Mode. Cannot proceed with patching." -ForegroundColor Red
    Exit 1
}


# ═════════════════════════════════════════════════════════════════════════════
# PHASE 6 — POST-PATCH VERIFICATION
# Re-connect ESXCLI and confirm the correct profile is now installed.
# ═════════════════════════════════════════════════════════════════════════════

$ESXiCLI_Post           = Get-EsxCli -VMHost $FromVMHostName -V2
$ESXiInMaintenance_Post = $ESXiCLI_Post.system.maintenanceMode.get.Invoke()
$PostPatchProfile       = ($ESXiCLI_Post.software.profile.get.Invoke()).Name

if ($ESXiInMaintenance_Post -eq "Enabled" -and $PostPatchProfile -eq $ExpectedPostPatch) {
    Write-Host "$FromVMHostName successfully upgraded to profile: $PostPatchProfile" -ForegroundColor Green
}
else {
    Write-Host "WARNING: Post-patch profile check failed on $FromVMHostName. Expected: $ExpectedPostPatch | Found: $PostPatchProfile" -ForegroundColor Red
}


# ═════════════════════════════════════════════════════════════════════════════
# PHASE 7 — POST-PATCHING CLEANUP
# Re-enable DRS rules, restore DRS to Fully Automated, and exit Maintenance Mode.
# ═════════════════════════════════════════════════════════════════════════════

# Restore DRS to Fully Automated — cluster self-manages VM placement again
Write-Host "Restoring DRS to Fully Automated on cluster: $ClusterName" -ForegroundColor Cyan
Set-Cluster -Cluster $ClusterName -DRSEnabled:$true -DrsAutomationLevel "FullyAutomated" -Confirm:$false

Try {
    if ($Cluster_DRS -eq $true -and $Cluster.Name -like $ClusterName) {

        Write-Host "Re-enabling non-Zerto DRS VM Rules and VM Host Rules..." -ForegroundColor Yellow
        Get-Cluster -Name $ClusterName | Get-DrsRule       | Where-Object { $_.Name -notlike "*Zerto*" } | Set-DrsRule -Enabled:$true
        Get-Cluster -Name $ClusterName | Get-DrsVMHostRule | Where-Object { $_.Name -notlike "Zerto*"  } | Set-DrsVMHostRule -Enabled:$true
        Write-Host "Non-Zerto DRS rules re-enabled successfully." -ForegroundColor Green
    }
    else {
        Write-Host "ERROR: DRS cluster state mismatch. Manual rule re-enablement required." -ForegroundColor Red
        Exit 1
    }

    # Exit Maintenance Mode — host re-joins the cluster and becomes available for workloads
    $HostConnectionState = (Get-VMHost -Name $FromVMHostName).ConnectionState

    if ($HostConnectionState -eq 'Maintenance') {
        Write-Host "Taking $FromVMHostName out of Maintenance Mode..." -ForegroundColor Cyan
        Set-VMHost -VMHost $FromVMHostName -State Connected

        Send-Notification `
            -Subject ("ESXi Patching Complete: $FromVMHostName — " + (Get-Date -Format dd-MM-yyyy)) `
            -Body "Hi Team,`n`n$FromVMHostName has exited Maintenance Mode and ESXi patching is complete. The host has rejoined the cluster.`n`nThis is an automated notification — please do not reply."
    }
    else {
        Write-Host "ERROR: $FromVMHostName is not in Maintenance Mode — cannot exit cleanly." -ForegroundColor Red
        Send-Notification `
            -Subject ("ALERT: Exit Maintenance Mode Failed — $FromVMHostName") `
            -Body "Hi Team,`n`nAttempt to exit Maintenance Mode on $FromVMHostName was unsuccessful. Please investigate.`n`nThis is an automated notification — please do not reply."
    }
}
Catch [Exception] {
    Write-Host "EXCEPTION during post-patch cleanup: $($_.Exception.Message)" -ForegroundColor Red
    Break
}


# ─────────────────────────────────────────────────────────────────────────────
# DISCONNECT FROM VCENTER
# Always disconnect gracefully to free up the vCenter session slot.
# ─────────────────────────────────────────────────────────────────────────────
Disconnect-VIServer -Server $vcserver -Confirm:$false
Write-Host "Disconnected from vCenter: $vcserver" -ForegroundColor Cyan

# Stop capturing transcript output
Stop-Transcript
