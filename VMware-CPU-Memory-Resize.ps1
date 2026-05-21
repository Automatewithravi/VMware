<#
.SYNOPSIS
    VMware vSphere - VM CPU and Memory Resize Automation

.DESCRIPTION
    Automates CPU and/or Memory resizing for VMs across PROD and DR vCenter environments.
    Designed to be triggered via Jenkins Parameterised Build for safe, auditable changes.

.AUTHOR
    Ravindrakumar Narayanan | automatewithravi.com

.PROJECT
    Implement automation for repeatable tasks in vSphere infrastructure

.TASK
    Memory and CPU modify in PROD and DR

.VERSION
    2.0

.PARAMETERS (Jenkins Environment Variables)
    PROD_Vcenter_Name   - PROD vCenter hostname
    DR_Vcenter_Name     - DR vCenter hostname
    Username            - vCenter service account username
    Password            - vCenter service account password
    VM_Name             - Target VM name
    CPU                 - Set to "yes" to modify CPU
    Memory              - Set to "yes" to modify Memory
    CPU_Increase        - Desired number of vCPUs
    Memory_Increase     - Desired memory in GB
#>

# ─────────────────────────────────────────────────────────────
# LOGGING
# ─────────────────────────────────────────────────────────────
Start-Transcript -Path "C:\vSphere_Patching\CPU_Memory_PS_Logs\Logfile_$((Get-Date).ToString('MM-dd-yyyy_hhmmss')).txt" -NoClobber -IncludeInvocationHeader

# ─────────────────────────────────────────────────────────────
# ENVIRONMENT VARIABLES
# ─────────────────────────────────────────────────────────────
$PROD_Vcenter_Name     = $Env:PROD_Vcenter_Name
$DR_Vcenter_Name       = $Env:DR_Vcenter_Name
$Username              = $Env:Username
$Password              = $Env:Password
$VMName                = $Env:VM_Name
$CPU                   = $Env:CPU
$Memory                = $Env:Memory
$NumberofCPU_required  = $Env:CPU_Increase
$Memory_Size_required  = $Env:Memory_Increase

$SMTP_Server           = "172.0.2.35"
$Mail_From             = "vmware@automatewithravi.com"
$Mail_To               = "admin@automatewithravi.com"

# ─────────────────────────────────────────────────────────────
# HELPER FUNCTIONS
# ─────────────────────────────────────────────────────────────

function Send-AlertEmail {
    <#
    .SYNOPSIS Sends an alert email on failure.
    #>
    param (
        [string]$Subject,
        [string]$Body
    )
    $MailSubject = $Subject + " - " + (Get-Date -Format "dd-MM-yyyy")
    Send-MailMessage -SmtpServer $SMTP_Server `
        -From $Mail_From `
        -To $Mail_To `
        -Subject $MailSubject `
        -Body $Body
}

function Connect-VCenter {
    <#
    .SYNOPSIS Connects to a vCenter server and validates the connection.
    .OUTPUTS Returns $true if connected, exits on failure.
    #>
    param (
        [string]$VCenterName,
        [string]$Label
    )
    $Connection = Connect-VIServer -Server $VCenterName -User $Username -Password $Password
    if ($Connection.IsConnected -ne $true) {
        Write-Host " Unable to connect to $Label vCenter. Check credentials and network." -ForegroundColor Red
        Exit 1
    }
    Write-Host " $Label vCenter connected successfully." -ForegroundColor Green
}

function Stop-VMSafely {
    <#
    .SYNOPSIS Gracefully shuts down a VM, then force-powers off if still running after timeout.
    #>
    param (
        [string]$VMName,
        [int]$GraceSeconds = 180
    )
    Write-Host " Initiating graceful shutdown for $VMName..." -ForegroundColor Yellow
    Get-VM | Where-Object { $_.Name -like $VMName } | Stop-VMGuest -Confirm:$false

    Write-Host " Waiting $GraceSeconds seconds for shutdown to complete..."
    Start-Sleep -Seconds $GraceSeconds

    # Force power off if still running
    Get-VM | Where-Object { $_.Name -like $VMName -and $_.PowerState -like "*On" } | Stop-VM -Confirm:$false
}

function Get-VMPowerState {
    <#
    .SYNOPSIS Returns the power state of a named VM.
    #>
    param ([string]$VMName)
    return (Get-VM -Name $VMName).PowerState
}

function Set-VMCPU {
    <#
    .SYNOPSIS Sets the number of vCPUs on a VM (VM must be powered off).
    #>
    param (
        [string]$VMName,
        [int]$NumCPU
    )
    Write-Host " Setting CPU to $NumCPU vCPU(s) for $VMName..." -ForegroundColor Cyan
    Get-VM -Name $VMName | Set-VM -NumCpu $NumCPU -Confirm:$false
}

function Set-VMMemory {
    <#
    .SYNOPSIS Sets the memory (GB) on a VM (VM must be powered off).
    #>
    param (
        [string]$VMName,
        [int]$MemoryGB
    )
    Write-Host " Setting Memory to $MemoryGB GB for $VMName..." -ForegroundColor Cyan
    Get-VM -Name $VMName | Set-VM -MemoryGB $MemoryGB -Confirm:$false
}

function Start-VMAndVerify {
    <#
    .SYNOPSIS Powers on a VM after resource change and confirms it started.
    #>
    param ([string]$VMName)
    Write-Host " Starting VM $VMName..." -ForegroundColor Green
    Get-VM -Name $VMName | Start-VM -Confirm:$false
}

function Confirm-CPUChange {
    <#
    .SYNOPSIS Verifies the CPU count was applied correctly.
    #>
    param ([string]$VMName, [int]$Expected)
    $Actual = (Get-VM -Name $VMName).NumCpu
    if ($Actual -eq $Expected) {
        Write-Host " CPU verified: $Actual vCPU(s) set on $VMName." -ForegroundColor Green
        return $true
    }
    Write-Host " CPU mismatch: Expected $Expected, got $Actual. Please investigate." -ForegroundColor Red
    return $false
}

function Confirm-MemoryChange {
    <#
    .SYNOPSIS Verifies the memory value was applied correctly.
    #>
    param ([string]$VMName, [int]$Expected)
    $Actual = (Get-VM -Name $VMName).MemoryGB
    if ($Actual -eq $Expected) {
        Write-Host " Memory verified: $Actual GB set on $VMName." -ForegroundColor Green
        return $true
    }
    Write-Host " Memory mismatch: Expected $Expected GB, got $Actual GB. Please investigate." -ForegroundColor Red
    return $false
}

# ─────────────────────────────────────────────────────────────
# STEP 1 — VCENTER CONNECTIONS
# ─────────────────────────────────────────────────────────────
try {
    if ($PROD_Vcenter_Name) {
        Connect-VCenter -VCenterName $PROD_Vcenter_Name -Label "PROD"
    }

    if ($DR_Vcenter_Name) {
        Connect-VCenter -VCenterName $DR_Vcenter_Name -Label "DR"
    }
}
catch [Exception] {
    Write-Host $_.Exception.Message -ForegroundColor Red
    $Body = @"
Hi Team,

There is an issue connecting to the vCenter. Please fix this before retrying the CPU/Memory resize.

Exception:
$($_.Exception.Message)
"@
    Send-AlertEmail -Subject "VMware CPU/Memory Resize - vCenter Connection Failure" -Body $Body
    Stop-Transcript
    Break
}

# ─────────────────────────────────────────────────────────────
# STEP 2 — RESOURCE MODIFICATION
# ─────────────────────────────────────────────────────────────
try {
    $VM_PowerStatus = Get-VMPowerState -VMName $VMName

    # ── CPU ONLY ──────────────────────────────────────────────
    if ($CPU -eq "yes" -and $Memory -ne "yes") {

        if ($VM_PowerStatus -eq "PoweredOn") {
            Stop-VMSafely -VMName $VMName
        }

        Set-VMCPU -VMName $VMName -NumCPU $NumberofCPU_required

        if (Confirm-CPUChange -VMName $VMName -Expected $NumberofCPU_required) {
            Start-VMAndVerify -VMName $VMName
        }
    }

    # ── MEMORY ONLY ───────────────────────────────────────────
    elseif ($Memory -eq "yes" -and $CPU -ne "yes") {

        if ($VM_PowerStatus -eq "PoweredOn") {
            Stop-VMSafely -VMName $VMName
        }

        Set-VMMemory -VMName $VMName -MemoryGB $Memory_Size_required

        if (Confirm-MemoryChange -VMName $VMName -Expected $Memory_Size_required) {
            Start-VMAndVerify -VMName $VMName
        }
    }

    # ── CPU + MEMORY ──────────────────────────────────────────
    elseif ($CPU -eq "yes" -and $Memory -eq "yes") {

        if ($VM_PowerStatus -eq "PoweredOn") {
            Stop-VMSafely -VMName $VMName
        }

        Set-VMMemory -VMName $VMName -MemoryGB $Memory_Size_required
        Set-VMCPU    -VMName $VMName -NumCPU    $NumberofCPU_required

        $MemOK = Confirm-MemoryChange -VMName $VMName -Expected $Memory_Size_required
        $CPUOK = Confirm-CPUChange    -VMName $VMName -Expected $NumberofCPU_required

        if ($MemOK -and $CPUOK) {
            Start-VMAndVerify -VMName $VMName
        }
    }

    # ── NOTHING SELECTED ─────────────────────────────────────
    else {
        Write-Host " No resource selected. Set CPU and/or Memory parameter to 'yes' to proceed." -ForegroundColor Yellow
    }
}
catch [Exception] {
    Write-Host $_.Exception.Message -ForegroundColor Red
    $Body = @"
Hi Team,

An error occurred while modifying VM resources for: $VMName
Please review the Jenkins console log for details.

Exception:
$($_.Exception.Message)
"@
    Send-AlertEmail -Subject "VMware CPU/Memory Resize - Resource Modification Failure" -Body $Body
}

# ─────────────────────────────────────────────────────────────
Stop-Transcript
