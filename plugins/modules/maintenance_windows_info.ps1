#!powershell

# Copyright: (c) 2025, Ansible Project
# GNU General Public License v3.0+ (see COPYING or https://www.gnu.org/licenses/gpl-3.0.txt)

#AnsibleRequires -CSharpUtil Ansible.Basic
#AnsibleRequires -PowerShell ..module_utils._CMPsSetupUtils


$SERVICE_WINDOW_TYPE_MAP = @{
    1 = 'Any'
    4 = 'SoftwareUpdatesOnly'
    5 = 'TaskSequencesOnly'
}


function Format-MaintenanceWindowInfo {
    param (
        [Parameter(Mandatory = $true)][object]$mw
    )
    $type_int = [int]$mw.ServiceWindowType
    $apply_to_str = $SERVICE_WINDOW_TYPE_MAP[$type_int]
    if (-not $apply_to_str) {
        $apply_to_str = $type_int.ToString()
    }
    return @{
        name = $mw.Name
        service_window_id = $mw.ServiceWindowID.ToString()
        is_enabled = [bool]$mw.IsEnabled
        apply_to = $apply_to_str
        duration = [int]$mw.Duration
        service_window_schedules = $mw.ServiceWindowSchedules
    }
}


$spec = @{
    options = @{
        site_code = @{ type = 'str'; required = $true }
        device_collection_name = @{ type = 'str'; required = $true }
        name = @{ type = 'str'; required = $false }
    }
    supports_check_mode = $true
}

$module = [Ansible.Basic.AnsibleModule]::Create($args, $spec)
$module.result.maintenance_windows = @()
$module.result.changed = $false

$site_code = $module.Params.site_code
$device_collection_name = $module.Params.device_collection_name
$name = $module.Params.name

Import-CMPsModule -module $module
Test-CMSiteNameAndConnect -module $module -SiteCode $site_code

# Verify the device collection exists before querying its maintenance windows.
$collection = Get-CMCollection -Name $device_collection_name -ErrorAction SilentlyContinue
if ($null -eq $collection) {
    $module.FailJson("Device collection '$device_collection_name' does not exist.")
}
$collection_id = $collection.CollectionID

if (-not [string]::IsNullOrEmpty($name)) {
    # Retrieve a single named maintenance window.
    try {
        $mws = @(Get-CMMaintenanceWindow -CollectionID $collection_id -Name $name -ErrorAction Stop)
    }
    catch {
        $module.FailJson(
            "Failed to query maintenance window '$name' on collection '$device_collection_name': $($_.Exception.Message)",
            $_
        )
    }

    if (-not $mws) {
        $module.Warn("Maintenance window '$name' does not exist on collection '$device_collection_name'.")
        $module.ExitJson()
    }
}
else {
    # Retrieve all maintenance windows for the collection.
    try {
        $mws = @(Get-CMMaintenanceWindow -CollectionID $collection_id -ErrorAction Stop)
    }
    catch {
        $module.FailJson(
            "Failed to query maintenance windows on collection '$device_collection_name': $($_.Exception.Message)",
            $_
        )
    }
}

foreach ($mw in $mws) {
    if ($null -eq $mw) { continue }
    $module.result.maintenance_windows += Format-MaintenanceWindowInfo -mw $mw
}

$module.ExitJson()
