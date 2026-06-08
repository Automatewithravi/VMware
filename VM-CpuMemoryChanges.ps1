<#
.SYNOPSIS
    VM Config Change Tracker — CPU and Memory Operations

.DESCRIPTION
    Connects to a vCenter server and uses the vSphere Task Manager and Event
    Manager APIs to detect all ReconfigVM_Task events in the past 36 hours.
    Filters for VmReconfiguredEvent entries where CPU count or memory was
    changed and exports results to a timestamped CSV. Sends email notification
    on completion.

.NOTES
    Author  : admin@automatewithravi.com
    Version : 1.0
    Requires: VMware.PowerCLI 13.x or later
#>

# ── Credentials injected by Jenkins Credentials Binding plugin ──────────────
$vcServer   = $Env:VCENTER_SERVER
$vcUsername = $Env:VCENTER_USERNAME
$vcPassword = $Env:VCENTER_PASSWORD

Connect-VIServer -Server $vcServer -User $vcUsername -Password $vcPassword
Set-PowerCLIConfiguration -DefaultVIServerMode multiple -Confirm:$false

# ── Configuration ───────────────────────────────────────────────────────────
$hours         = 36
$taskPageSize  = 999
$eventPageSize = 100

$report   = @()
$taskMgr  = Get-View TaskManager
$eventMgr = Get-View eventManager

# ── Build task filter ────────────────────────────────────────────────────────
$tFilter                = New-Object VMware.Vim.TaskFilterSpec
$tFilter.Time           = New-Object VMware.Vim.TaskFilterSpecByTime
$tFilter.Time.beginTime = (Get-Date).AddHours(-$hours)
$tFilter.Time.timeType  = "startedTime"

$tCollector = Get-View ($taskMgr.CreateCollectorForTasks($tFilter))
$null       = $tCollector.RewindCollector
$tasks      = $tCollector.ReadNextTasks($taskPageSize)

# ── Iterate tasks and extract CPU / memory changes ───────────────────────────
while ($tasks) {
    $tasks | Where-Object { $_.Name -eq 'ReconfigVM_Task' } | ForEach-Object {
        $task = $_

        $eFilter              = New-Object VMware.Vim.EventFilterSpec
        $eFilter.eventChainId = $task.EventChainId

        $eCollector = Get-View ($eventMgr.CreateCollectorForEvents($eFilter))
        $events     = $eCollector.ReadNextEvents($eventPageSize)

        while ($events) {
            $events | ForEach-Object {
                switch ($_.GetType().Name) {
                    'VmReconfiguredEvent' {
                        $_.ConfigSpec | Where-Object { $_.NumCPUs -ne 0 -or $_.MemoryMB -ne 0 } | ForEach-Object {
                            $report += [PSCustomObject]@{
                                VMname    = $task.EntityName
                                Start     = $task.StartTime
                                Finish    = $task.CompleteTime
                                Result    = $task.State
                                User      = $task.Reason.UserName
                                Memory_MB = if ($_.MemoryMB -ne 0) { $_.MemoryMB } else { '' }
                                NumCPU    = if ($_.NumCPUs  -ne 0) { $_.NumCPUs  } else { '' }
                            }
                        }
                    }
                }
            }
            $events = $eCollector.ReadNextEvents($eventPageSize)
        }
        $eCollector.DestroyCollector()
    }
    $tasks = $tCollector.ReadNextTasks($taskPageSize)
}

$tCollector.DestroyCollector()

# ── Export to timestamped CSV ────────────────────────────────────────────────
$timestamp  = (Get-Date).ToString('yyyy-MM-dd_HHmm')
$outputPath = "C:\VM_Config_Changes\VM-CpuMemoryChanges_$timestamp.csv"

$report | Sort-Object Start | Export-Csv $outputPath -NoTypeInformation -UseCulture

Write-Output "[INFO] Report saved: $outputPath — $($report.Count) record(s)"

Disconnect-VIServer -Confirm:$false -ErrorAction SilentlyContinue

# ── Email notification to operations team ────────────────────────────────────
$smtpServer  = $Env:SMTP_SERVER
$fromAddress = 'vcenter-alerts@automatewithravi.com'
$toAddresses = 'ops-team@automatewithravi.com', 'infra-lead@automatewithravi.com'
$subject     = "vCenter VM Config Change Report — " + (Get-Date -Format 'dd-MM-yyyy')

$body = @"
Hi Team,

The VM reconfiguration audit job has completed successfully.

Please find attached the timestamped CSV reports covering disk, CPU,
and memory changes detected in the last 36 hours across PROD and DR vCenters.

Reports are also archived in: C:\VM_Config_Changes\

Please do not reply to this email — this mailbox is unmonitored.

Thank you
"@

Send-MailMessage -SmtpServer $smtpServer `
    -From $fromAddress `
    -To $toAddresses `
    -Subject $subject `
    -Body $body `
    -Attachments $outputPath

Write-Output "[INFO] Email sent to: $($toAddresses -join ', ')"
