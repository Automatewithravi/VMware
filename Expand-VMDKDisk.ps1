<#
.SYNOPSIS
    Automates VMDK disk expansion and new disk creation for VMs across Prod and DR vCenter environments.

.DESCRIPTION
    This script connects to one or both vCenter servers (Prod / DR), validates datastore free space,
    expands up to five existing VMDK disks per VM, and optionally creates a new hard disk.
    Designed to run as a Jenkins Parameterised Build — all inputs are supplied via environment variables.

.AUTHOR
    automatewithravi.com

.VERSION
    2.0

.NOTES
    - Requires VMware PowerCLI to be installed on the Jenkins agent.
    - All sensitive credentials are injected by Jenkins (never hardcoded).
    - CD/ISO drive is automatically disconnected before datastore capacity checks.
#>

# ─── Transcript Logging ──────────────────────────────────────────────────────
Start-Transcript -Path "C:\AWR_vSphere_Automation\Disk_Modify_PS_Logs\Logfile_$((Get-Date).ToString('MM-dd-yyyy_hhmmss')).txt" `
                 -NoClobber -IncludeInvocationHeader

# ─── Environment Variables ────────────────────────────────────────────────────
$Prod_Vcenter      = $Env:Prod_Vcenter        # "yes" or "no"
$DR_Vcenter        = $Env:DR_Vcenter          # "yes" or "no"
$Prod_VCenter_Name = "prod-vcenter.automatewithravi.com"
$DR_VCenter_Name   = "dr-vcenter.automatewithravi.com"
$Username          = $Env:Username
$Password          = $Env:Password

# ─── Helper: Send Alert Email ─────────────────────────────────────────────────
function Send-AlertEmail {
    param(
        [string]$Subject,
        [string]$Body
    )
    Send-MailMessage -SmtpServer "smtp.automatewithravi.com" `
                     -From "vmware-automation@automatewithravi.com" `
                     -To   "it-admin@automatewithravi.com" `
                     -Subject $Subject `
                     -Body $Body
}

# ─── Helper: Connect to vCenter ───────────────────────────────────────────────
function Connect-VCenter {
    param(
        [string]$Server,
        [string]$Label
    )
    $conn = Connect-VIServer -Server $Server -User $Username -Password $Password
    if (-not $conn.IsConnected) {
        Write-Host " Unable to connect to $Label vCenter ($Server). Check credentials." -ForegroundColor Red
        Send-AlertEmail -Subject "vCenter Connection Failure - $Label $(Get-Date -Format dd-MM-yyyy)" `
                        -Body "Hi Team,`n`nFailed to connect to $Label vCenter ($Server).`nPlease investigate before retrying the disk expansion job."
        Exit 1
    }
    Write-Host " Connected to $Label vCenter — ready to expand VMDK disks." -ForegroundColor Green
    return $conn
}

# ─── Helper: Get Hard Disk Size (rounded, null-safe) ─────────────────────────
function Get-DiskSizeGB {
    param([string]$VMName, [string]$DiskName)
    $cap = (Get-HardDisk -VM $VMName | Where-Object { $_.Name -eq $DiskName }).CapacityGB
    if ($null -ne $cap) { return [Math]::Round($cap, 2) } else { return $null }
}

# ─── Helper: Expand a Single Hard Disk ───────────────────────────────────────
function Expand-HardDisk {
    param(
        [string] $VMName,
        [object] $VM,
        [string] $DiskLabel,          # e.g. "Hard disk 2"
        [string] $InputFlag,          # "yes" / "no"
        [double] $ExpectedCurrentGB,  # from Jenkins param
        [double] $TargetGB,           # new total size in GB
        [double] $ActualCurrentGB     # read live from vCenter
    )

    if ($null -eq $ActualCurrentGB) {
        Write-Host "$DiskLabel is not attached to $VMName — skipping." -ForegroundColor Yellow
        return
    }

    if ($InputFlag -eq "yes" -and $ExpectedCurrentGB -eq $ActualCurrentGB -and $TargetGB -gt $ActualCurrentGB) {
        Write-Host " Expanding $DiskLabel from $ActualCurrentGB GB → $TargetGB GB ..." -ForegroundColor Cyan
        $disk = Get-HardDisk -VM $VM -Name $DiskLabel
        Set-HardDisk -HardDisk $disk -CapacityGB $TargetGB -Confirm:$false | Out-Null
        $newSize = (Get-HardDisk -VM $VMName | Where-Object { $_.Name -eq $DiskLabel }).CapacityGB
        Write-Host " $DiskLabel expanded successfully. New capacity: $newSize GB" -ForegroundColor Green
    } else {
        Write-Host " $DiskLabel skipped — either not selected (yes), size mismatch, or target <= current. Current: $ActualCurrentGB GB" -ForegroundColor Gray
    }
}

# ═══════════════════════════════════════════════════════════════════════════════
#  PHASE 1 — vCenter Connections
# ═══════════════════════════════════════════════════════════════════════════════
try {
    $Prod_Connection = $null
    $DR_Connection   = $null

    if ($Prod_Vcenter -eq "yes") { $Prod_Connection = Connect-VCenter -Server $Prod_VCenter_Name -Label "Prod" }
    if ($DR_Vcenter   -eq "yes") { $DR_Connection   = Connect-VCenter -Server $DR_VCenter_Name   -Label "DR"   }
}
catch {
    Write-Host $_.Exception.Message -ForegroundColor Red
    Send-AlertEmail -Subject "vCenter Connection Error $(Get-Date -Format dd-MM-yyyy)" `
                    -Body "Hi Team,`n`nException while connecting to vCenter:`n$($_.Exception.Message)"
    Stop-Transcript; Exit 1
}

# ═══════════════════════════════════════════════════════════════════════════════
#  PHASE 2 — Disk Operations
# ═══════════════════════════════════════════════════════════════════════════════
try {
    # ── Target VM ──────────────────────────────────────────────────────────────
    $VMName = $Env:VM_Name
    $VM     = Get-VM -Name $VMName

    Write-Host "`n── Current OS-level disk info for $VMName ──────────────────────────────────"
    (Get-VMGuestDisk -VM $VMName).VMGuest.Disks | Format-Table -AutoSize

    # ── Jenkins Input Parameters ───────────────────────────────────────────────
    $hddFlags  = @($Env:HDD1, $Env:HDD2, $Env:HDD3, $Env:HDD4, $Env:HDD5)
    $hddCurrent = @([double]$Env:HDD1_CurrentSize, [double]$Env:HDD2_CurrentSize,
                    [double]$Env:HDD3_CurrentSize, [double]$Env:HDD4_CurrentSize, [double]$Env:HDD5_CurrentSize)
    $hddTarget  = @([double]$Env:HDD1_Disk_Size_Total_Increase, [double]$Env:HDD2_Disk_Size_Total_Increase,
                    [double]$Env:HDD3_Disk_Size_Total_Increase, [double]$Env:HDD4_Disk_Size_Total_Increase,
                    [double]$Env:HDD5_Disk_Size_Total_Increase)
    $hddIncrease = @([double]$Env:HDD1_Size_Increaserequired, [double]$Env:HDD2_Size_Increaserequired,
                     [double]$Env:HDD3_Size_Increaserequired, [double]$Env:HDD4_Size_Increaserequired,
                     [double]$Env:HDD5_Size_Increaserequired)

    $New_HDD_required  = $Env:New_HDD_required
    $disksizeGB_newHDD = [double]$Env:disksizeGB_new_HDD

    # ── Live disk sizes from vCenter ────────────────────────────────────────────
    $diskNames   = @("Hard disk 1","Hard disk 2","Hard disk 3","Hard disk 4","Hard disk 5")
    $liveSize    = $diskNames | ForEach-Object { Get-DiskSizeGB -VMName $VMName -DiskName $_ }

    # ── CD Drive: disconnect ISO before datastore check ────────────────────────
    $cd = Get-CDDrive -VM $VMName
    if ($cd.ConnectionState.Connected -or $cd.ConnectionState.StartConnected -or ($null -ne $cd.IsoPath)) {
        Get-VM -Name $VMName | Get-CDDrive | Set-CDDrive -NoMedia -Confirm:$false | Out-Null
        Write-Host " ISO disconnected from CD drive — datastore calculation will be accurate." -ForegroundColor Yellow
    }

    # ── Datastore Free-Space Validation ────────────────────────────────────────
    $totalRequired = ($hddIncrease | Measure-Object -Sum).Sum + $disksizeGB_newHDD
    $datastores    = Get-Datastore -RelatedObject $VM

    foreach ($ds in $datastores) {
        $freeGB      = $ds.FreeSpaceGB
        $totalGB     = $ds.CapacityGB
        $afterFreeGB = $freeGB - $totalRequired
        $afterFreePct = [Math]::Round(($afterFreeGB / $totalGB) * 100, 1)

        Write-Host "`n Datastore: $($ds.Name)  |  Free: $([Math]::Round($freeGB,1)) GB  |  After expansion: $afterFreeGB GB ($afterFreePct %)"

        if ($afterFreePct -le 10) {
            Write-Host " ABORT: Post-expansion free space would fall below 10% on $($ds.Name)." -ForegroundColor Red
            Stop-Transcript; Exit 1
        }
        Write-Host " Datastore check passed — proceeding." -ForegroundColor Green
    }

    # ── New Hard Disk Creation ─────────────────────────────────────────────────
    if ($New_HDD_required -eq "yes") {
        $VM | New-HardDisk -CapacityGB $disksizeGB_newHDD -Persistence persistent | Out-Null
        Write-Host " New $disksizeGB_newHDD GB disk created successfully." -ForegroundColor Green
    }

    # ── Expand Existing Disks 1–5 ─────────────────────────────────────────────
    for ($i = 0; $i -lt 5; $i++) {
        Expand-HardDisk -VMName         $VMName `
                        -VM             $VM `
                        -DiskLabel      $diskNames[$i] `
                        -InputFlag      $hddFlags[$i] `
                        -ExpectedCurrentGB $hddCurrent[$i] `
                        -TargetGB       $hddTarget[$i] `
                        -ActualCurrentGB   $liveSize[$i]
    }

    # ── Final Disk Summary ─────────────────────────────────────────────────────
    Write-Host "`n── Post-Operation Disk Summary for $VMName ─────────────────────────────────"
    Get-HardDisk -VM $VMName | Select-Object Name, CapacityGB | Format-Table -AutoSize

    Get-VMGuestDisk -VM $VMName | ForEach-Object {
        $gd = $_
        $hd = Get-HardDisk -VMGuestDisk $gd
        [PSCustomObject]@{
            VMName      = $hd.Parent
            DrivePath   = $gd.DiskPath
            CapacityGB  = $gd.CapacityGB
            FreeSpaceGB = $gd.FreeSpaceGB
            DiskName    = $hd.Name
            VMDK        = $hd.Filename
            SCSIid      = $hd.ExtensionData.UnitNumber
            Filesystem  = $gd.FileSystemType
            VMDKType    = $hd.StorageFormat
        }
    } | Format-Table -AutoSize

    # ── Disconnect vCenter Sessions ────────────────────────────────────────────
    if ($DR_Connection)   { Disconnect-VIServer -Server $DR_VCenter_Name   -Confirm:$false; Write-Host " DR vCenter session disconnected."   }
    if ($Prod_Connection) { Disconnect-VIServer -Server $Prod_VCenter_Name -Confirm:$false; Write-Host " Prod vCenter session disconnected." }
}
catch {
    Write-Error ($_.Exception | Format-List -Force | Out-String) -ErrorAction Continue
    Write-Error ($_.InvocationInfo | Format-List -Force | Out-String) -ErrorAction Continue
    $errMsg = "Exception on line $($_.InvocationInfo.ScriptLineNumber): $($_.Exception.Message)"
    Write-Host "Caught exception: $errMsg" -ForegroundColor Red

    Send-AlertEmail -Subject "VMDK Expansion Failed - $VMName $(Get-Date -Format dd-MM-yyyy)" `
                    -Body "Hi Team,`n`nAn exception occurred while processing $VMName.`n`n$errMsg`n`nPlease review the transcript log for full details."
}

Stop-Transcript
