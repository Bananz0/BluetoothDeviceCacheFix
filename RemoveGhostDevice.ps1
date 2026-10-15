$ErrorActionPreference = "Stop"
$logFile       = "$PSScriptRoot\cleanup_log.txt"
$selectionFile = "$PSScriptRoot\selected_devices.json"
Set-Content -Path $logFile -Value "--- Log Reset ---"

function Log {
    param([string]$Message, [string]$Color = "White")
    $ts = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    Add-Content -Path $logFile -Value "[$ts] $Message"
    Write-Host $Message -ForegroundColor $Color
}

# ── Selective vs full-purge mode ──────────────────────────────────────────────
if (Test-Path $selectionFile) {
    $targetMacs = @(Get-Content $selectionFile -Raw | ConvertFrom-Json | ForEach-Object { $_.ToLower() })
    $modeLabel  = "SELECTIVE ($($targetMacs.Count) device(s): $($targetMacs -join ', '))"
} else {
    $targetMacs = $null   # null = process everything
    $modeLabel  = "FULL PURGE"
}

Log "Starting purge as: $([System.Security.Principal.WindowsIdentity]::GetCurrent().Name)"
Log "Mode: $modeLabel"

# Returns true if $mac should be processed given the current target list.
function Should-Process ([string]$mac) {
    if ($null -eq $targetMacs) { return $true }
    return $targetMacs -contains $mac.ToLower()
}

# Returns true if a PnP DeviceID belongs to any targeted device.
function DeviceId-Matches ([string]$deviceId) {
    if ($null -eq $targetMacs) { return $true }
    foreach ($mac in $targetMacs) {
        if ($deviceId -match $mac) { return $true }
    }
    return $false
}

# ── P/Invoke definitions ──────────────────────────────────────────────────────
Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;

public class TokenManipulator {
    [DllImport("advapi32.dll", ExactSpelling = true, SetLastError = true)]
    internal static extern bool AdjustTokenPrivileges(IntPtr htok, bool disall, ref TokPriv1Luid newst, int len, IntPtr prev, IntPtr relen);
    [DllImport("kernel32.dll", ExactSpelling = true)]
    internal static extern IntPtr GetCurrentProcess();
    [DllImport("advapi32.dll", ExactSpelling = true, SetLastError = true)]
    internal static extern bool OpenProcessToken(IntPtr h, int acc, ref IntPtr phtok);
    [DllImport("advapi32.dll", SetLastError = true)]
    internal static extern bool LookupPrivilegeValue(string host, string name, ref long pluid);
    [StructLayout(LayoutKind.Sequential, Pack = 1)]
    internal struct TokPriv1Luid {
        public int Count;
        public long Luid;
        public int Attr;
    }
    internal const int SE_PRIVILEGE_ENABLED    = 0x00000002;
    internal const int TOKEN_QUERY             = 0x00000008;
    internal const int TOKEN_ADJUST_PRIVILEGES = 0x00000020;
    public static bool AddPrivilege(string privilege) {
        TokPriv1Luid tp;
        IntPtr hproc = GetCurrentProcess();
        IntPtr htok  = IntPtr.Zero;
        OpenProcessToken(hproc, TOKEN_ADJUST_PRIVILEGES | TOKEN_QUERY, ref htok);
        tp.Count = 1; tp.Luid = 0; tp.Attr = SE_PRIVILEGE_ENABLED;
        LookupPrivilegeValue(null, privilege, ref tp.Luid);
        return AdjustTokenPrivileges(htok, false, ref tp, 0, IntPtr.Zero, IntPtr.Zero);
    }
}

public class BluetoothHelper {
    [StructLayout(LayoutKind.Sequential)]
    public struct BLUETOOTH_ADDRESS { public ulong ullLong; }

    [DllImport("BluetoothAPIs.dll", SetLastError = true, CallingConvention = CallingConvention.StdCall)]
    public static extern uint BluetoothRemoveDevice(ref BLUETOOTH_ADDRESS pAddress);

    public static uint RemoveByMac(string mac) {
        byte[] b = new byte[6];
        for (int i = 0; i < 6; i++)
            b[i] = Convert.ToByte(mac.Substring(i * 2, 2), 16);
        ulong addr = 0;
        for (int i = 0; i < 6; i++)
            addr = (addr << 8) | b[i];
        BLUETOOTH_ADDRESS btAddr = new BLUETOOTH_ADDRESS { ullLong = addr };
        return BluetoothRemoveDevice(ref btAddr);
    }
}
"@

try {
    [TokenManipulator]::AddPrivilege("SeTakeOwnershipPrivilege") | Out-Null
    [TokenManipulator]::AddPrivilege("SeRestorePrivilege") | Out-Null
    Log "Privileges enabled." "Green"
} catch {
    Log "Failed to enable privileges: $_" "Red"
}

function Remove-ProtectedKey ([string]$KeyPath) {
    try {
        $acl = Get-Acl -Path $KeyPath
        $acl.SetOwner([System.Security.Principal.NTAccount]"Administrators")
        Set-Acl -Path $KeyPath -AclObject $acl
        $acl = Get-Acl -Path $KeyPath
        $rule = New-Object System.Security.AccessControl.RegistryAccessRule(
            "Administrators", "FullControl",
            "ContainerInherit,ObjectInherit", "None", "Allow")
        $acl.SetAccessRule($rule)
        Set-Acl -Path $KeyPath -AclObject $acl
        Remove-Item -Path $KeyPath -Recurse -Force
        return $true
    } catch {
        try { Remove-Item -Path $KeyPath -Recurse -Force; return $true } catch { return $false }
    }
}

# ── LAYER 1: BluetoothRemoveDevice API ───────────────────────────────────────
Log ""
Log "=== LAYER 1: BluetoothRemoveDevice API ===" "Yellow"

$seen = @{}
Get-PnpDevice -Class Bluetooth -ErrorAction SilentlyContinue |
    Where-Object { $_.DeviceID -match 'DEV_([0-9A-Fa-f]{12})' } |
    ForEach-Object {
        $mac = $Matches[1].ToLower()
        if ($seen[$mac]) { return }
        $seen[$mac] = $true
        if (-not (Should-Process $mac)) {
            Log "  Skipping [$mac] $($_.FriendlyName)" "DarkGray"
            return
        }
        $result = [BluetoothHelper]::RemoveByMac($mac)
        if ($result -eq 0 -or $result -eq 1168) {
            Log "  Unpaired [$mac] $($_.FriendlyName)" "Green"
        } else {
            Log "  RemoveDevice code $result for [$mac] $($_.FriendlyName)" "DarkGray"
        }
    }

# ── LAYER 2: PnP node removal ─────────────────────────────────────────────────
Log ""
Log "=== LAYER 2: PnP node removal (pnputil) ===" "Yellow"

Get-PnpDevice -Class Bluetooth -ErrorAction SilentlyContinue |
    Where-Object { $_.Status -ne 'Unknown' } |
    ForEach-Object {
        if (-not (DeviceId-Matches $_.InstanceId)) {
            Log "  Skipping: $($_.FriendlyName)" "DarkGray"
            return
        }
        Log "  Removing: $($_.FriendlyName)" "Cyan"
        $out = & pnputil /remove-device "$($_.InstanceId)" 2>&1
        if ($LASTEXITCODE -eq 0) {
            Log "    OK" "Green"
        } else {
            Log "    $out" "DarkGray"
        }
    }

# ── LAYER 3: BTHPORT device metadata ─────────────────────────────────────────
Log ""
Log "=== LAYER 3: BTHPORT device metadata ===" "Yellow"

$devicesPath = "HKLM:\SYSTEM\CurrentControlSet\Services\BTHPORT\Parameters\Devices"
if (Test-Path $devicesPath) {
    foreach ($dk in (Get-ChildItem $devicesPath -ErrorAction SilentlyContinue)) {
        $mac = $dk.PSChildName.ToLower()
        if (-not (Should-Process $mac)) {
            Log "  Skipping cache [$mac]" "DarkGray"
            continue
        }
        Log "  Deleting device cache [$mac]" "Cyan"
        if (Remove-ProtectedKey $dk.PSPath) {
            Log "    Deleted." "Green"
        } else {
            Log "    Failed." "Red"
        }
    }
} else {
    Log "  Path not found: $devicesPath" "Yellow"
}

# ── LAYER 4: BTHPORT link keys ────────────────────────────────────────────────
Log ""
Log "=== LAYER 4: BTHPORT link keys ===" "Yellow"

$keysPath = "HKLM:\SYSTEM\CurrentControlSet\Services\BTHPORT\Parameters\Keys"
if (Test-Path $keysPath) {
    foreach ($adapter in (Get-ChildItem $keysPath -ErrorAction SilentlyContinue)) {
        Log "  Adapter: $($adapter.PSChildName)" "Cyan"

        # Classic link keys are binary VALUES named by device MAC.
        # CentralIRK is adapter-level — only remove it in full-purge mode.
        try {
            $props = Get-Item $adapter.PSPath -ErrorAction SilentlyContinue
            foreach ($valueName in $props.Property) {
                if ($valueName -eq 'CentralIRK') {
                    if ($null -ne $targetMacs) {
                        Log "    Skipping CentralIRK (selective mode)" "DarkGray"
                        continue
                    }
                } elseif (-not (Should-Process $valueName)) {
                    Log "    Skipping link key value: $valueName" "DarkGray"
                    continue
                }
                Log "    Removing link key value: $valueName" "Cyan"
                try {
                    Remove-ItemProperty -Path $adapter.PSPath -Name $valueName -Force
                    Log "      Deleted." "Green"
                } catch {
                    Log "      Failed: $_" "Red"
                }
            }
        } catch {
            Log "    Could not read adapter values: $_" "Red"
        }

        # LE link keys and IRKs are SUBKEYS named by device MAC.
        foreach ($sk in (Get-ChildItem $adapter.PSPath -ErrorAction SilentlyContinue)) {
            $mac = $sk.PSChildName.ToLower()
            if (-not (Should-Process $mac)) {
                Log "    Skipping link key subkey: $mac" "DarkGray"
                continue
            }
            Log "    Removing link key subkey: $mac" "Cyan"
            if (Remove-ProtectedKey $sk.PSPath) {
                Log "      Deleted." "Green"
            } else {
                Log "      Failed." "Red"
            }
        }
    }
} else {
    Log "  Path not found: $keysPath" "Yellow"
}

# ── LAYER 5: DAF Store ────────────────────────────────────────────────────────
Log ""
Log "=== LAYER 5: DAF Store (WinRT device cache) ===" "Yellow"

$dafPath = "HKLM:\SYSTEM\ControlSet001\Services\DeviceAssociationService\State\Store"
$dafKeys = Get-ChildItem -Path $dafPath -ErrorAction SilentlyContinue

if ($dafKeys.Count -eq 0) {
    Log "  DAF Store is already empty." "Yellow"
} else {
    foreach ($key in $dafKeys) {
        # DAF keys look like: Bluetooth#Bluetoothc4:03:...-0c:32:3a:0f:3d:7e
        # Extract the device MAC (the part after the last '-', strip colons)
        $keyMac = ($key.PSChildName -split '-')[-1] -replace ':', ''
        if (-not (Should-Process $keyMac)) {
            Log "  Skipping: $($key.PSChildName)" "DarkGray"
            continue
        }
        Log "  Deleting: $($key.PSChildName)" "Cyan"
        if (Remove-ProtectedKey $key.PSPath) {
            Log "    Deleted." "Green"
        } else {
            Log "    Failed." "Red"
        }
    }
}

Log ""
Log "Purge complete. Reboot required to rebuild clean device state." "Green"
