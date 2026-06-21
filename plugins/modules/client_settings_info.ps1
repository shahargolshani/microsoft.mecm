#!powershell

# Copyright: (c) 2025, Ansible Project
# GNU General Public License v3.0+ (see COPYING or https://www.gnu.org/licenses/gpl-3.0.txt)

#AnsibleRequires -CSharpUtil Ansible.Basic
#AnsibleRequires -PowerShell ..module_utils._CMPsSetupUtils


# Maps integer Type values returned by Get-CMClientSetting to human-readable strings.
# 0 = default (read-only, cannot be created via this module)
# 1 = device
# 2 = user
$CLIENT_SETTING_TYPE_INT = @{
    0 = 'default'
    1 = 'device'
    2 = 'user'
}


function Format-ClientSettingResult {
    param (
        [Parameter(Mandatory = $true)][object]$setting
    )
    $type_int = [int]$setting.Type
    $type_str = if ($CLIENT_SETTING_TYPE_INT.ContainsKey($type_int)) { $CLIENT_SETTING_TYPE_INT[$type_int] } else { $type_int.ToString() }

    return @{
        name = $setting.Name
        description = if ($null -ne $setting.Description) { $setting.Description } else { '' }
        type = $type_str
        priority = [int]$setting.Priority
        settings_id = $setting.SettingsID.ToString()
    }
}


$spec = @{
    options = @{
        site_code = @{ type = 'str'; required = $true }
        name = @{ type = 'str'; required = $false }
    }
    supports_check_mode = $true
}

$module = [Ansible.Basic.AnsibleModule]::Create($args, $spec)
$module.result.changed = $false

$site_code = $module.Params.site_code
$name = $module.Params.name

Import-CMPsModule -module $module
Test-CMSiteNameAndConnect -module $module -SiteCode $site_code

try {
    if ($null -ne $name -and $name -ne '') {
        $all_settings = @(Get-CMClientSetting -Name $name -ErrorAction Stop)
    }
    else {
        $all_settings = @(Get-CMClientSetting -ErrorAction Stop)
    }
}
catch {
    $module.FailJson("Failed to retrieve client settings: $($_.Exception.Message)", $_)
}

$results = @()
foreach ($setting in $all_settings) {
    $results += Format-ClientSettingResult -setting $setting
}

$module.result.client_settings = $results
$module.ExitJson()
