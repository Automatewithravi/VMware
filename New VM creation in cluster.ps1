<#
Author          : Ravindrakumar.narayanan
Project         : Implement automation for repeatable tasks in vSphere infrastructure
Task Name       : New VM creation from the template
Version         : 2.0
Blog            : https://automatewithravi.com
GitHub          : https://github.com/Automatewithravi/VMware
Description     : Creates a new VM from a vSphere template with full disk, network, and
                  guest OS configuration. Designed for Jenkins Parameterised Build execution.
#>

#region --- Logging ---
Start-Transcript -Path "C:\vSphere_Automation\Logs\NewVM_Provisioning\Logfile_$((Get-Date).ToString('MM-dd-yyyy_hhmmss')).txt" -NoClobber -IncludeInvocationHeader
#endregion

#region --- Configuration ---
$Prod_Vcenter_Name = "vcenterserver01"    # Production vCenter
$DR_Vcenter_Name   = "vcenterserver02"    # DR vCenter
$SmtpServer        = "172.0.2.35"
$MailFrom          = "vmware-automation@automatewithravi.com"
$MailTo            = "it-alerts@automatewithravi.com"
$GuestAdminUser    = "administrator"
$GuestAdminPass    = $Env:GuestPassword   # Injected via Jenkins credentials binding

# Environment flags (set via Jenkins Choice Parameters)
$Production      = $Env:Production
$DR              = $Env:DR
$Username        = $Env:Username
$Password        = $Env:Password

# VM Parameters (all injected from Jenkins build parameters)
$VM_Name                    = $Env:VMName
$VM_Guest_Name              = $Env:VMGuestname
$VM_IPAddress               = $Env:IPAddress
$VM_SubnetMask              = $Env:SubnetMask
$VM_Gateway                 = $Env:GatewayIP
$VM_DNSServers              = $Env:DNSServerIP
$VM_Portgroup_Name          = $Env:VM_Networkname
$VM_Vcenter_Folder          = $Env:VMFolder
$VM_Vcenter_Template_Name   = $Env:VMTemplate
$VM_Vcenter_Datastore_Name  = $Env:VMDatastoreName
$VM_Mem                     = $Env:VM_Memory
$VM_CPU                     = $Env:VM_CPU
$VM_HDD1_Size               = $Env:VM_Cdrive
$VM_VMHost_Prod             = "prodesx103"   # Production ESXi host
$VM_VMHost_DR               = "dresx103"     # DR ESXi host

# Additional HDD flags and sizes
$AdditionalDisks = @(
    @{ Flag = $Env:VM_HDD1; Size = $Env:VM_HDD1_Size; DiskNum = 1; DriveLetter = "E"; Label = "E drive" },
    @{ Flag = $Env:VM_HDD2; Size = $Env:VM_HDD2_Size; DiskNum = 2; DriveLetter = "F"; Label = "F drive" },
    @{ Flag = $Env:VM_HDD3; Size = $Env:VM_HDD3_Size; DiskNum = 3; DriveLetter = "G"; Label = "G drive" },
    @{ Flag = $Env:VM_HDD4; Size = $Env:VM_HDD4_Size; DiskNum = 4; DriveLetter = "H"; Label = "H drive" },
    @{ Flag = $Env:VM_HDD5; Size = $Env:VM_HDD5_Size; DiskNum = 5; DriveLetter = "I"; Label = "I drive" }
)
#endregion

#region --- Functions ---

function Send-AlertEmail {
    <#
    .SYNOPSIS
        Sends an HTML or plain-text alert email to the operations team.
    #>
    param(
        [string]$Subject,
        [string]$Body,
        [switch]$AsHtml
    )
    $params = @{
        SmtpServer = $SmtpServer
        From       = $MailFrom
        To         = $MailTo
        Subject    = $Subject
        Body       = $Body
    }
    if ($AsHtml) { $params['BodyAsHtml'] = $true }
    Send-MailMessage @params
}

function Connect-ToVCenter {
    <#
    .SYNOPSIS
        Connects to a vCenter server and validates the connection.
    .OUTPUTS
        Returns $true if connected, exits with code 1 on failure.
    #>
    param(
        [string]$VCenterName,
        [string]$User,
        [string]$Pass,
        [string]$Label = "vCenter"
    )
    $conn = Connect-VIServer -Server $VCenterName -User $User -Password $Pass
    if (-not $conn.IsConnected) {
        Write-Host " Unable to connect to $Label ($VCenterName). Verify credentials." -ForegroundColor Red
        Exit 1
    }
    Write-Host " $Label ($VCenterName) connected successfully." -ForegroundColor Green
    return $true
}

function New-VMFromTemplate {
    <#
    .SYNOPSIS
        Deploys a new VM from a vSphere template on the specified host.
    #>
    param(
        [string]$VMName,
        [string]$Template,
        [string]$Location,
        [string]$Datastore,
        [string]$Network,
        [string]$VMHost
    )
    Write-Host " Deploying VM '$VMName' from template '$Template' on host '$VMHost'..." -ForegroundColor Cyan
    return New-VM -Name $VMName -Template $Template -Location $Location `
                  -Datastore $Datastore -NetworkName $Network -VMHost $VMHost
}

function Set-VMResources {
    <#
    .SYNOPSIS
        Adjusts CPU, memory, and resizes the primary (C:) disk inherited from the template.
    #>
    param(
        [VMware.VimAutomation.ViCore.Types.V1.Inventory.VirtualMachine]$VM,
        [string]$MemGB,
        [string]$NumCPU,
        [string]$CdriveSizeGB
    )
    if ($MemGB) {
        Write-Host " Setting memory to $MemGB GB"
        $VM | Set-VM -MemoryGB $MemGB -Confirm:$false
    } else {
        Write-Host " Memory not specified — using template default (4 GB)"
    }

    if ($NumCPU) {
        Write-Host " Setting CPU count to $NumCPU"
        $VM | Set-VM -NumCpu $NumCPU -Confirm:$false
    } else {
        Write-Host " CPU not specified — using template default (2 vCPU)"
    }

    if ($CdriveSizeGB) {
        Write-Host " Expanding Hard Disk 1 (C:) to $CdriveSizeGB GB"
        $hdd1 = Get-HardDisk -VM $VM -Name "Hard disk 1"
        Set-HardDisk -HardDisk $hdd1 -CapacityGB $CdriveSizeGB -Confirm:$false
    } else {
        Write-Host " C: drive size not specified — using template default (40 GB)"
    }
}

function Add-AdditionalDisks {
    <#
    .SYNOPSIS
        Attaches additional persistent hard disks to the VM based on the disk array.
    #>
    param(
        [VMware.VimAutomation.ViCore.Types.V1.Inventory.VirtualMachine]$VM,
        [array]$DiskConfig
    )
    foreach ($disk in $DiskConfig) {
        if ($disk.Flag -eq "yes") {
            Write-Host " Adding new disk: $($disk.Size) GB (Drive $($disk.DriveLetter):)"
            $VM | New-HardDisk -CapacityGB $disk.Size -Persistence persistent
        } else {
            Write-Host " Disk $($disk.DriveLetter): — not requested, skipping."
        }
    }
}

function Wait-ForVMwareTools {
    <#
    .SYNOPSIS
        Polls VMware Tools status until it reports 'toolsOK'.
    #>
    param(
        [VMware.VimAutomation.ViCore.Types.V1.Inventory.VirtualMachine]$VM
    )
    Write-Host " Waiting for VMware Tools to become ready..." -ForegroundColor Yellow
    do {
        Start-Sleep -Seconds 5
        $toolsStatus = ($VM | Get-View).Guest.toolsStatus
    } until ($toolsStatus -eq 'toolsOK')
    Write-Host " VMware Tools is ready." -ForegroundColor Green
}

function Set-VMGuestNetwork {
    <#
    .SYNOPSIS
        Configures the guest OS IP address and DNS via VMware Tools (netsh).
    #>
    param(
        [string]$VMName,
        [string]$IPAddress,
        [string]$SubnetMask,
        [string]$Gateway,
        [string]$DNS,
        [string]$GuestUser,
        [string]$GuestPass
    )
    # Connect NIC
    Get-VM $VMName | Get-NetworkAdapter | Set-NetworkAdapter -StartConnected:$true -Connected:$true -Confirm:$false

    if ($IPAddress) {
        Write-Host " Configuring static IP: $IPAddress"
        Invoke-VMScript -VM $VMName -GuestUser $GuestUser -GuestPassword $GuestPass `
            -ScriptText "netsh interface ipv4 set address 'Ethernet0' static $IPAddress $SubnetMask $Gateway 1"
    }
    if ($DNS) {
        Write-Host " Configuring DNS: $DNS"
        Invoke-VMScript -VM $VMName -GuestUser $GuestUser -GuestPassword $GuestPass `
            -ScriptText "netsh interface ipv4 set dnsservers 'Ethernet0' static $DNS primary"
    }
}

function Set-VMGuestHostname {
    <#
    .SYNOPSIS
        Renames the guest OS hostname and triggers an async restart.
    #>
    param(
        [string]$VMName,
        [string]$NewName,
        [string]$GuestUser,
        [string]$GuestPass
    )
    if ($NewName) {
        Write-Host " Renaming computer to '$NewName' and restarting..."
        Invoke-VMScript -VM $VMName -GuestUser $GuestUser -GuestPassword $GuestPass `
            -ScriptText "Rename-Computer -NewName $NewName -Force"
        Invoke-VMScript -VM $VMName -GuestUser $GuestUser -GuestPassword $GuestPass `
            -ScriptText "Restart-Computer -Force" -RunAsync
    }
}

function Expand-GuestDisks {
    <#
    .SYNOPSIS
        Extends the C: partition and initialises/formats all additional disks inside the guest OS.
    #>
    param(
        [VMware.VimAutomation.ViCore.Types.V1.Inventory.VirtualMachine]$VM,
        [string]$CdriveSizeGB,
        [array]$DiskConfig,
        [string]$GuestUser,
        [string]$GuestPass
    )
    # Extend C: drive using diskpart
    if ($CdriveSizeGB) {
        Write-Host " Extending C: drive inside guest OS..."
        $diskpartScript = "echo rescan > c:\diskpart.txt && echo select vol C >> c:\diskpart.txt && echo extend >> c:\diskpart.txt && diskpart.exe /s c:\diskpart.txt"
        Invoke-VMScript -VM $VM -ScriptText $diskpartScript -ScriptType BAT -GuestUser $GuestUser -GuestPassword $GuestPass
    }

    # Remove temp diskpart file if first additional disk is present
    $firstDisk = $DiskConfig | Where-Object { $_.Flag -eq "yes" } | Select-Object -First 1
    if ($firstDisk) {
        Invoke-VMScript -VM $VM -ScriptText "del c:\diskpart.txt" -ScriptType BAT -GuestUser $GuestUser -GuestPassword $GuestPass
    }

    # Initialise and format each additional disk
    foreach ($disk in $DiskConfig) {
        if ($disk.Flag -eq "yes") {
            Write-Host " Initialising disk $($disk.DiskNum) as $($disk.DriveLetter): ($($disk.Label))"
            $psScript = "get-disk | Where-Object Number -eq '$($disk.DiskNum)' | Initialize-Disk -PartitionStyle GPT -PassThru | New-Volume -FileSystem NTFS -DriveLetter $($disk.DriveLetter) -FriendlyName '$($disk.Label)'"
            Invoke-VMScript -VM $VM -ScriptText $psScript -ScriptType Powershell -GuestUser $GuestUser -GuestPassword $GuestPass
        }
    }
}

function Get-VMProvisioningReport {
    <#
    .SYNOPSIS
        Collects post-provisioning VM details and returns a summary hashtable.
    #>
    param([string]$VMName)
    $vm = Get-VM -Name $VMName
    return @{
        VMName      = $vm.Guest.VmName
        HostName    = $vm.Guest.HostName
        PowerState  = $vm.PowerState
        Folder      = $vm.Folder
        CPU         = $vm.NumCpu
        MemoryGB    = $vm.MemoryGB
        CreateDate  = $vm.CreateDate
        Disks       = $vm.Guest.Disks | Select-Object Path, @{N="CapacityGB"; E={[math]::Round([decimal]$_.CapacityGB)}}
        DatastorePath = Get-HardDisk -VM $vm | Select-Object Filename
    }
}

#endregion

#region --- Main Execution ---

# ── Step 1: Connect to vCenter(s) ──────────────────────────────────────────
try {
    $Prod_Connected = $false
    $DR_Connected   = $false

    if ($Production -eq "yes") {
        $Prod_Connected = Connect-ToVCenter -VCenterName $Prod_Vcenter_Name -User $Username -Pass $Password -Label "Production vCenter"
    }
    if ($DR -eq "yes") {
        $DR_Connected = Connect-ToVCenter -VCenterName $DR_Vcenter_Name -User $Username -Pass $Password -Label "DR vCenter"
    }
}
catch {
    Write-Host $_.Exception.Message -ForegroundColor Red
    Send-AlertEmail -Subject ("vSphere VM Creation - Connection Failure " + (Get-Date -Format "dd-MM-yyyy")) `
        -Body "Hi Team,`n`nUnable to connect to vCenter. Please investigate before retrying.`n`n$($_.Exception.Message)"
    Stop-Transcript
    exit 1
}

# ── Step 2: Deploy VM from Template ────────────────────────────────────────
try {
    if ($Prod_Connected) {
        $vm = New-VMFromTemplate -VMName $VM_Name -Template $VM_Vcenter_Template_Name `
            -Location $VM_Vcenter_Folder -Datastore $VM_Vcenter_Datastore_Name `
            -Network $VM_Portgroup_Name -VMHost $VM_VMHost_Prod
    }
    elseif ($DR_Connected) {
        $vm = New-VMFromTemplate -VMName $VM_Name -Template $VM_Vcenter_Template_Name `
            -Location $VM_Vcenter_Folder -Datastore $VM_Vcenter_Datastore_Name `
            -Network $VM_Portgroup_Name -VMHost $VM_VMHost_DR
    }

    # ── Step 3: Adjust CPU / Memory / Primary Disk ─────────────────────────
    Set-VMResources -VM $vm -MemGB $VM_Mem -NumCPU $VM_CPU -CdriveSizeGB $VM_HDD1_Size

    # ── Step 4: Attach Additional Disks ────────────────────────────────────
    Add-AdditionalDisks -VM $vm -DiskConfig $AdditionalDisks

    # ── Step 5: Power On & Wait for Tools ──────────────────────────────────
    $vm | Start-VM
    Wait-ForVMwareTools -VM $vm

    # ── Step 6: Configure Guest Network ────────────────────────────────────
    Set-VMGuestNetwork -VMName $VM_Name -IPAddress $VM_IPAddress -SubnetMask $VM_SubnetMask `
        -Gateway $VM_Gateway -DNS $VM_DNSServers -GuestUser $GuestAdminUser -GuestPass $GuestAdminPass

    # ── Step 7: Rename Guest Hostname & Restart ─────────────────────────────
    Set-VMGuestHostname -VMName $VM_Name -NewName $VM_Guest_Name -GuestUser $GuestAdminUser -GuestPass $GuestAdminPass

    Start-Sleep -Seconds 25

    # ── Step 8: Wait for Tools after Restart ───────────────────────────────
    Wait-ForVMwareTools -VM $vm

    # ── Step 9: Extend Partitions Inside Guest OS ──────────────────────────
    Expand-GuestDisks -VM $vm -CdriveSizeGB $VM_HDD1_Size -DiskConfig $AdditionalDisks `
        -GuestUser $GuestAdminUser -GuestPass $GuestAdminPass

    Start-Sleep -Seconds 60

    # ── Step 10: Collect Provisioning Report ───────────────────────────────
    $report = Get-VMProvisioningReport -VMName $VM_Name

    Write-Host "`n===== VM Provisioning Summary =====" -ForegroundColor Cyan
    Write-Host " VM Name       : $($report.VMName)"
    Write-Host " Guest Hostname: $($report.HostName)"
    Write-Host " Power State   : $($report.PowerState)"
    Write-Host " Folder        : $($report.Folder)"
    Write-Host " CPU           : $($report.CPU) vCPU"
    Write-Host " Memory        : $($report.MemoryGB) GB"
    Write-Host " Created On    : $($report.CreateDate)"
    Write-Host " Disks:"
    $report.Disks | Format-Table -AutoSize
    Write-Host " Datastore Path:"
    $report.DatastorePath | Format-Table -AutoSize

    # ── Step 11: Send Success Email ────────────────────────────────────────
    $diskHtml = $report.Disks | ConvertTo-Html -Property Path, CapacityGB -As Table | Out-String
    $successBody = @"
<p>Hi Team,</p>
<p>The new VM <strong>$($report.VMName)</strong> has been provisioned successfully.</p>
<table border='1' cellpadding='5' cellspacing='0'>
  <tr><td><b>Guest Hostname</b></td><td>$($report.HostName)</td></tr>
  <tr><td><b>Power State</b></td><td>$($report.PowerState)</td></tr>
  <tr><td><b>Folder</b></td><td>$($report.Folder)</td></tr>
  <tr><td><b>CPU</b></td><td>$($report.CPU) vCPU</td></tr>
  <tr><td><b>Memory</b></td><td>$($report.MemoryGB) GB</td></tr>
  <tr><td><b>Created On</b></td><td>$($report.CreateDate)</td></tr>
</table>
<br/>
<h4>Disk Layout</h4>
$diskHtml
"@
    Send-AlertEmail -Subject ("vSphere VM Creation - Success " + (Get-Date -Format "dd-MM-yyyy")) -Body $successBody -AsHtml
}
catch {
    Write-Host $_.Exception.Message -ForegroundColor Red
    Send-AlertEmail -Subject ("vSphere VM Creation - Error " + (Get-Date -Format "dd-MM-yyyy")) `
        -Body "Hi Team,`n`nAn error occurred during VM creation. See below for details.`n`n$($_.Exception.Message)"
}
finally {
    # ── Step 12: Disconnect vCenter Sessions ───────────────────────────────
    if ($DR_Connected) {
        Disconnect-VIServer -Server $DR_Vcenter_Name -Confirm:$false
        Write-Host " $DR_Vcenter_Name session disconnected."
    }
    if ($Prod_Connected) {
        Disconnect-VIServer -Server $Prod_Vcenter_Name -Confirm:$false
        Write-Host " $Prod_Vcenter_Name session disconnected."
    }
    Stop-Transcript
}

#endregion
