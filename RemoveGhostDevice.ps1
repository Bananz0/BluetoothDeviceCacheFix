$ErrorActionPreference = "Stop"
$logFile = "$PSScriptRoot\cleanup_log.txt"
# Clear previous log
Set-Content -Path $logFile -Value "--- Log Reset for Full Purge ---"

function Log-Message {
    param([string]$Message, [string]$Color = "White")
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $fullMessage = "[$timestamp] $Message"
    Write-Host $Message -ForegroundColor $Color
    Add-Content -Path $logFile -Value $fullMessage
}

Log-Message "Starting FULL PURGE script running as: $([System.Security.Principal.WindowsIdentity]::GetCurrent().Name)"

# P/Invoke to enable Privileges
$definition = @"
using System;
using System.Runtime.InteropServices;
public class TokenManipulator
{
    [DllImport("advapi32.dll", ExactSpelling = true, SetLastError = true)]
    internal static extern bool AdjustTokenPrivileges(IntPtr htok, bool disall, ref TokPriv1Luid newst, int len, IntPtr prev, IntPtr relen);
    [DllImport("kernel32.dll", ExactSpelling = true)]
    internal static extern IntPtr GetCurrentProcess();
    [DllImport("advapi32.dll", ExactSpelling = true, SetLastError = true)]
    internal static extern bool OpenProcessToken(IntPtr h, int acc, ref IntPtr phtok);
    [DllImport("advapi32.dll", SetLastError = true)]
    internal static extern bool LookupPrivilegeValue(string host, string name, ref long pluid);
    [StructLayout(LayoutKind.Sequential, Pack = 1)]
    internal struct TokPriv1Luid
    {
        public int Count;
        public long Luid;
        public int Attr;
    }
    internal const int SE_PRIVILEGE_ENABLED = 0x00000002;
    internal const int TOKEN_QUERY = 0x00000008;
    internal const int TOKEN_ADJUST_PRIVILEGES = 0x00000020;
    public static bool AddPrivilege(string privilege)
    {
        try
        {
            bool retVal;
            TokPriv1Luid tp;
            IntPtr hproc = GetCurrentProcess();
            IntPtr htok = IntPtr.Zero;
            retVal = OpenProcessToken(hproc, TOKEN_ADJUST_PRIVILEGES | TOKEN_QUERY, ref htok);
            tp.Count = 1;
            tp.Luid = 0;
            tp.Attr = SE_PRIVILEGE_ENABLED;
            retVal = LookupPrivilegeValue(null, privilege, ref tp.Luid);
            retVal = AdjustTokenPrivileges(htok, false, ref tp, 0, IntPtr.Zero, IntPtr.Zero);
            return retVal;
        }
        catch (Exception ex)
        {
            throw ex;
        }
    }
}
"@

try {
    Add-Type -TypeDefinition $definition
    Log-Message "Enabling SeTakeOwnershipPrivilege..." "Cyan"
    [TokenManipulator]::AddPrivilege("SeTakeOwnershipPrivilege") | Out-Null
    [TokenManipulator]::AddPrivilege("SeRestorePrivilege") | Out-Null
    Log-Message "Privileges Enabled." "Green"
}
catch {
    Log-Message "Failed to add privileges: $_" "Red"
}

# NOTE: No target address filter. Targeting EVERYTHING in the Store.
$basePath = "HKLM:\SYSTEM\ControlSet001\Services\DeviceAssociationService\State\Store"

Log-Message "Processing ALL keys in $basePath..."

# Get immediate children.
$keys = Get-ChildItem -Path $basePath -ErrorAction SilentlyContinue 

if ($keys.Count -eq 0) {
    Log-Message "Store is already empty!" "Yellow"
}

foreach ($key in $keys) {
    $keyPath = $key.PSPath
    Log-Message "Processing key: $keyPath" "Cyan"

    try {
        # 1. Take Ownership
        $acl = Get-Acl -Path $keyPath
        $owner = [System.Security.Principal.NTAccount]"Administrators"
        $acl.SetOwner($owner)
        Set-Acl -Path $keyPath -AclObject $acl
        Log-Message "  - Ownership taken." "Green"

        # Refetch
        $acl = Get-Acl -Path $keyPath

        # 2. Grant Full Control to Administrators
        $rule = New-Object System.Security.AccessControl.RegistryAccessRule(
            "Administrators",
            "FullControl",
            "ContainerInherit,ObjectInherit",
            "None",
            "Allow"
        )
        $acl.SetAccessRule($rule)
        Set-Acl -Path $keyPath -AclObject $acl
        Log-Message "  - Permissions updated." "Green"

        # 3. Delete Key
        Remove-Item -Path $keyPath -Recurse -Force
        Log-Message "  - Key DELETED." "Green"
    }
    catch {
        Log-Message "  ! FAILED: $_" "Red"
        # Last ditch
        try { 
            Remove-Item -Path $keyPath -Recurse -Force
            Log-Message "  - Direct delete success." "Green"
        }
        catch {}
    }
}

Log-Message "Full Purge Complete."
