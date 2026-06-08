<#
.SYNOPSIS
    VM Config Change Tracker — Disk Device Operations

.DESCRIPTION
    Connects to a vCenter server and uses the vSphere Task Manager and Event
    Manager APIs to detect all ReconfigVM_Task events in the past 36 hours.
    Filters for VmReconfiguredEvent entries and extracts disk device changes
    (add, edit, remove). Exports results to a timestamped CSV file.

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
$hours       = 36    # Rolling window in hours
$taskPageSize  = 999  # Task collector page size (max supported)
$eventPageSize = 100  # Event collector page size

$report   = @()
$taskMgr  = Get-View TaskManager
$eventMgr = Get-View eventManager

# ── Build task filter for the rolling time window ───────────────────────────
$tFilter                    = New-Object VMware.Vim.TaskFilterSpec
$tFilter.Time               = New-Object VMware.Vim.TaskFilterSpecByTime
$tFilter.Time.beginTime     = (Get-Date).AddHours(-$hours)
$tFilter.Time.timeType      = "startedTime"

$tCollector = Get-View ($taskMgr.CreateCollectorForTasks($tFilter))
$null       = $tCollector.RewindCollector
$tasks      = $tCollector.ReadNextTasks($taskPageSize)

# ── Iterate tasks, match ReconfigVM_Task, fetch linked events ────────────────
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
                        $_.ConfigSpec.DeviceChange | Where-Object { $_.Device -ne $null } | ForEach-Object {
                            $report += [PSCustomObject]@{
                                VMname         = $task.EntityName
                                Start          = $task.StartTime
                                Finish         = $task.CompleteTime
                                Result         = $task.State
                                User           = $task.Reason.UserName
                                Device         = $_.Device.GetType().Name
                                Operation      = $_.Operation
                                HDDLabel       = $_.Device.DeviceInfo.Label
                                HDDCapacity_GB = [math]::Round($_.Device.CapacityInKb / 1MB, 0)
                            }
                        }
                    }
                }
            }
            $events = $eCollector.ReadNextEvents($eventPageSize)
        }
        # Destroy event collector — vCenter allows max 32 per session
        $eCollector.DestroyCollector()
    }
    $tasks = $tCollector.ReadNextTasks($taskPageSize)
}

# Destroy task collector
$tCollector.DestroyCollector()

# ── Export to timestamped CSV ────────────────────────────────────────────────
$timestamp  = (Get-Date).ToString('yyyy-MM-dd_HHmm')
$outputPath = "C:\VM_Config_Changes\VM-DeviceChanges_$timestamp.csv"

$report | Sort-Object Start | Export-Csv $outputPath -NoTypeInformation -UseCulture

Write-Output "[INFO] Report saved: $outputPath — $($report.Count) record(s)"

Disconnect-VIServer -Confirm:$false -ErrorAction SilentlyContinue
