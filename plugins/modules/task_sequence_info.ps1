#!powershell

# Copyright: (c) 2025, Ansible Project
# GNU General Public License v3.0+ (see COPYING or https://www.gnu.org/licenses/gpl-3.0.txt)

#AnsibleRequires -CSharpUtil Ansible.Basic
#AnsibleRequires -PowerShell ..module_utils._CMPsSetupUtils


$spec = @{
    options = @{
        site_code = @{ type = 'str'; required = $true }
        name = @{ type = 'str'; required = $false }
    }
    supports_check_mode = $true
}

$module = [Ansible.Basic.AnsibleModule]::Create($args, $spec)
$module.result.changed = $false
$module.result.task_sequences = @()

$site_code = $module.Params.site_code
$name = $module.Params.name

Import-CMPsModule -module $module
Test-CMSiteNameAndConnect -SiteCode $site_code -Module $module

if (-not [string]::IsNullOrEmpty($name)) {
    try {
        $sequences = @(Get-CMTaskSequence -Name $name -ErrorAction Stop)
    }
    catch {
        $module.FailJson("Failed to query task sequence '$name': $($_.Exception.Message)", $_)
    }
    if (-not $sequences) {
        $module.Warn("Task sequence '$name' does not exist.")
        $module.ExitJson()
    }
}
else {
    try {
        $sequences = @(Get-CMTaskSequence -ErrorAction Stop)
    }
    catch {
        $module.FailJson("Failed to query task sequences: $($_.Exception.Message)", $_)
    }
}

foreach ($ts in $sequences) {
    if ($null -eq $ts) { continue }
    $module.result.task_sequences += @{
        name = $ts.Name
        package_id = $ts.PackageID
        description = $ts.Description
        boot_image_id = $ts.BootImageID
        ts_enabled = $ts.TsEnabled
    }
}

$module.ExitJson()
