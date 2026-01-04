$ErrorActionPreference = "Stop"

$scriptToRun = "$PSScriptRoot\RemoveGhostDevice.ps1"
$taskName = "GhostBusterCleanup"

Write-Host "Creating Scheduled Task '$taskName' to run as SYSTEM using schtasks..." -ForegroundColor Cyan

# Use schtasks.exe which is often more robust for SYSTEM tasks
# /sc ONCE /st 00:00 is a dummy trigger, we will run it manually immediately.
# /RL HIGHEST ensures highest privileges.
# /RU SYSTEM runs as Local System.
$command = "powershell.exe -ExecutionPolicy Bypass -File `"$scriptToRun`""

# Delete if exists
schtasks /delete /tn $taskName /f 2>$null

# Create
schtasks /create /tn $taskName /tr $command /sc ONCE /st 00:00 /ru "SYSTEM" /rl HIGHEST /f

if ($LASTEXITCODE -eq 0) {
    Write-Host "Task registered successfully. Starting task..." -ForegroundColor Green
    schtasks /run /tn $taskName
    
    Write-Host "Task started. Waiting 10 seconds..." -ForegroundColor Yellow
    Start-Sleep -Seconds 10
    
    Write-Host "Checking log file..."
    if (Test-Path "$PSScriptRoot\cleanup_log.txt") {
        Get-Content "$PSScriptRoot\cleanup_log.txt" | Select-Object -Last 20
    }
    else {
        Write-Host "Log file not found yet." -ForegroundColor Red
    }
    
    Write-Host "Cleaning up task..."
    schtasks /delete /tn $taskName /f
}
else {
    Write-Host "Failed to create task." -ForegroundColor Red
}
