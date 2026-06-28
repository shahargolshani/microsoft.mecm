#!powershell

# Copyright: (c) 2025, Ansible Project
# GNU General Public License v3.0+ (see COPYING or https://www.gnu.org/licenses/gpl-3.0.txt)

#AnsibleRequires -CSharpUtil Ansible.Basic
#AnsibleRequires -PowerShell ..module_utils._CMPsSetupUtils
#AnsibleRequires -PowerShell ..module_utils._ADRUtils


$spec = @{
    options = @{
        site_code = @{ type = 'str'; required = $true }
        name = @{ type = 'str'; required = $false }
    }
    supports_check_mode = $true
}

$module = [Ansible.Basic.AnsibleModule]::Create($args, $spec)
$module.result.changed = $false
$module.result.software_update_adrs = @()

$site_code = $module.Params.site_code
$name = $module.Params.name

Import-CMPsModule -module $module
Test-CMSiteNameAndConnect -module $module -SiteCode $site_code

$cmdlet_params = @{}
if (-not [string]::IsNullOrEmpty($name)) {
    $cmdlet_params['Name'] = $name
}

try {
    $adrs = Get-CMSoftwareUpdateAutoDeploymentRule @cmdlet_params
}
catch {
    $module.FailJson("Failed to retrieve Software Update ADRs: $($_.Exception.Message)", $_)
}

if ($null -eq $adrs) {
    if (-not [string]::IsNullOrEmpty($name)) {
        $module.Warn("Software Update ADR '$name' was not found.")
    }
    $module.ExitJson()
}

$adrs_formatted = @($adrs | ForEach-Object { Format-ADRResult -adr $_ })
$module.result.software_update_adrs = $adrs_formatted

$module.ExitJson()
