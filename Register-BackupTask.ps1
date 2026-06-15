# Register-BackupTask.ps1
# Run this once in an elevated PowerShell prompt on Windows to create a
# scheduled Task that calls the WSL backup script on a recurring schedule.
#
# Usage (in an elevated PowerShell):
#   .\Register-BackupTask.ps1
#
# Customise the variables in the CONFIG section before running.

#Requires -RunAsAdministrator

# ---------------------------------------------------------------------------
# CONFIG
# ---------------------------------------------------------------------------

$WslDistro     = "Ubuntu"               # WSL distro name (run `wsl -l` to list)
$ScriptPath    = "/home/<youruser>/backup-to-s3.sh"  # Path INSIDE WSL
$Bucket        = "my-backup-bucket"
$Prefix        = "backups/mymachine"    # No trailing slash
$AwsProfile    = "default"

# Schedule: daily at 2:00 AM. Change trigger as needed.
$TriggerTime   = "02:00"

# Task identity: runs as the current user; set to SYSTEM for headless.
$RunAsUser     = $env:USERNAME

$TaskName      = "WSL-S3-Backup"
$TaskFolder    = "\Custom"

# ---------------------------------------------------------------------------
# BUILD THE ACTION
# ---------------------------------------------------------------------------

$envVars = "BUCKET=$Bucket PREFIX=$Prefix AWS_PROFILE=$AwsProfile"

# wsl.exe -d <distro> -- env VAR=val bash /path/to/script.sh
$wslArgs = "-d `"$WslDistro`" -- env $envVars bash `"$ScriptPath`""

$action = New-ScheduledTaskAction `
    -Execute "wsl.exe" `
    -Argument $wslArgs

# ---------------------------------------------------------------------------
# TRIGGER — daily at $TriggerTime
# ---------------------------------------------------------------------------

$trigger = New-ScheduledTaskTrigger -Daily -At $TriggerTime

# ---------------------------------------------------------------------------
# SETTINGS
# ---------------------------------------------------------------------------

$settings = New-ScheduledTaskSettingsSet `
    -ExecutionTimeLimit (New-TimeSpan -Hours 6) `
    -StartWhenAvailable `              # Run ASAP if missed (machine was off)
    -RunOnlyIfNetworkAvailable `
    -MultipleInstances IgnoreNew

# ---------------------------------------------------------------------------
# PRINCIPAL (who runs the task)
# ---------------------------------------------------------------------------

$principal = New-ScheduledTaskPrincipal `
    -UserId $RunAsUser `
    -LogonType S4U `                   # Runs whether logged in or not
    -RunLevel Highest

# ---------------------------------------------------------------------------
# REGISTER
# ---------------------------------------------------------------------------

$existingTask = Get-ScheduledTask -TaskName $TaskName -TaskPath $TaskFolder -ErrorAction SilentlyContinue

if ($existingTask) {
    Write-Host "Task '$TaskFolder\$TaskName' already exists — updating..." -ForegroundColor Yellow
    Set-ScheduledTask `
        -TaskName  $TaskName `
        -TaskPath  $TaskFolder `
        -Action    $action `
        -Trigger   $trigger `
        -Settings  $settings `
        -Principal $principal
} else {
    Register-ScheduledTask `
        -TaskName  $TaskName `
        -TaskPath  $TaskFolder `
        -Action    $action `
        -Trigger   $trigger `
        -Settings  $settings `
        -Principal $principal `
        -Description "Incremental backup of WSL and Windows drives to S3 via aws s3 sync"
}

Write-Host ""
Write-Host "Done. Task registered: $TaskFolder\$TaskName" -ForegroundColor Green
Write-Host "Next run: $((Get-ScheduledTask -TaskName $TaskName -TaskPath $TaskFolder | Get-ScheduledTaskInfo).NextRunTime)"
Write-Host ""
Write-Host "To run immediately:"
Write-Host "  Start-ScheduledTask -TaskName '$TaskName' -TaskPath '$TaskFolder'"
