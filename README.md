# BluetoothDeviceCacheFix

While working on my [galaxybookenabler](https://github.com/Bananz0/GalaxyBookEnabler) repo, i came into an issue where my earbuds were duplicated in windows, after a warranty repair and was always duplicated in Samsung Settings. This was to fix that.

## Description
This tool purges the hidden "Device Association Framework" (DAF) cache in the Windows Registry (`HKLM\SYSTEM\ControlSet001\Services\DeviceAssociationService\State\Store`). This cache can hold onto stale device associations ("ghost devices") that are no longer present in the standard Plug and Play list or Windows Settings, but still appear in apps using WindowsRT Bluetooth APIs.

The solution consists of two scripts:
1. `RemoveGhostDevice.ps1`: The payload script that takes ownership of the protected Registry keys and deletes them.
2. `RunAsSystem.ps1`: A launcher that creates a temporary Scheduled Task to execute the payload as the `NT AUTHORITY\SYSTEM` account, which is required to bypass "Access Denied" errors even for Administrators.

## Usage
1. Open **PowerShell** as **Administrator**.
2. Navigate to the directory containing these scripts.
3. Run the launcher script:
   ```powershell
   .\RunAsSystem.ps1
   ```
4. The script will create a temporary task, run the cleanup, and then delete the task.
5. Check the `cleanup_log.txt` file for the results.

This script purges **ALL** cached device associations in the DAF store. Windows will re-create associations for currently connected active devices, but you may need to re-pair some devices if they disappear completely.

## Related Tools
This specific fix addresses the "Device Association Framework" (DAF) cache (`HKLM\...\DeviceAssociationService\...\Store`). If you are still facing issues, or want a more general Bluetooth cleanup, check out these projects:

*   **[m-a-x-s-e-e-l-i-g/powerBTremover](https://github.com/m-a-x-s-e-e-l-i-g/powerBTremover)**: Uses Windows APIs to remove stubborn Bluetooth devices.
