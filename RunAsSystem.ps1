$scriptToRun  = "$PSScriptRoot\RemoveGhostDevice.ps1"
$selectionFile = "$PSScriptRoot\selected_devices.json"
$taskName      = "GhostBusterCleanup"

# ── Enumerate physical BT devices ────────────────────────────────────────────
Write-Host "Enumerating Bluetooth devices..." -ForegroundColor Cyan

$seen       = @{}
$deviceList = @()

Get-PnpDevice -Class Bluetooth -ErrorAction SilentlyContinue |
    Where-Object { $_.DeviceID -match 'DEV_([0-9A-Fa-f]{12})' } |
    Sort-Object FriendlyName |
    ForEach-Object {
        $mac = $Matches[1].ToLower()
        if (-not $seen[$mac]) {
            $seen[$mac] = $true
            $type = if ($_.DeviceID -match '^BTHLE\\') { 'BLE' } else { 'Classic' }
            $deviceList += [PSCustomObject]@{
                Name = $_.FriendlyName
                MAC  = $mac -replace '(..)(..)(..)(..)(..)(..)', '$1:$2:$3:$4:$5:$6'
                Type = $type
            }
        }
    }

if ($deviceList.Count -eq 0) {
    Write-Host "No Bluetooth devices found." -ForegroundColor Yellow
    exit 1
}

# ── Device selection (Out-GridView GUI) ───────────────────────────────────────
Write-Host "Opening device picker — Ctrl+Click to select multiple, then OK..." -ForegroundColor Yellow
$selected = $deviceList | Out-GridView -Title "Select Bluetooth devices to purge" -PassThru

if (-not $selected -or @($selected).Count -eq 0) {
    Write-Host "No devices selected. Aborting." -ForegroundColor Yellow
    exit 0
}

$selectedMacs = @($selected | ForEach-Object { $_.MAC -replace ':', '' })

Write-Host ""
Write-Host "Queued for purge:" -ForegroundColor Cyan
$selected | ForEach-Object {
    Write-Host "  $($_.Name)  [$($_.MAC)]  ($($_.Type))" -ForegroundColor White
}

# Write selection file for the SYSTEM task to read
$selectedMacs | ConvertTo-Json | Set-Content -Path $selectionFile -Encoding UTF8

# ── Create + run SYSTEM scheduled task ───────────────────────────────────────
Write-Host ""
Write-Host "Creating Scheduled Task '$taskName'..." -ForegroundColor Cyan

$command = "powershell.exe -ExecutionPolicy Bypass -File `"$scriptToRun`""
& schtasks /delete /tn $taskName /f 2>&1 | Out-Null
schtasks /create /tn $taskName /tr $command /sc ONCE /st 00:00 /ru "SYSTEM" /rl HIGHEST /f

if ($LASTEXITCODE -ne 0) {
    Write-Host "Failed to create task." -ForegroundColor Red
    Remove-Item $selectionFile -Force -ErrorAction SilentlyContinue
    exit 1
}

Write-Host "Task registered. Starting..." -ForegroundColor Green
schtasks /run /tn $taskName

Write-Host "Waiting 30 seconds for purge to complete..." -ForegroundColor Yellow
Start-Sleep -Seconds 30

# ── Show results ──────────────────────────────────────────────────────────────
Write-Host ""
if (Test-Path "$PSScriptRoot\cleanup_log.txt") {
    Get-Content "$PSScriptRoot\cleanup_log.txt" | Select-Object -Last 30
} else {
    Write-Host "Log file not found." -ForegroundColor Red
}

& schtasks /delete /tn $taskName /f 2>&1 | Out-Null
Remove-Item $selectionFile -Force -ErrorAction SilentlyContinue
