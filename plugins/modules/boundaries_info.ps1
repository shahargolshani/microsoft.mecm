#!powershell

# Copyright: (c) 2025, Ansible Project
# GNU General Public License v3.0+ (see COPYING or https://www.gnu.org/licenses/gpl-3.0.txt)

#AnsibleRequires -CSharpUtil Ansible.Basic
#AnsibleRequires -PowerShell ..module_utils._CMPsSetupUtils
#AnsibleRequires -PowerShell ..module_utils._BoundaryUtils


$spec = @{
    options = @{
        site_code = @{ type = 'str'; required = $true }
        name = @{ type = 'str'; required = $false }
        type = @{
            type = 'str'
            required = $false
            choices = @('IPSubnet', 'ADSite', 'IPV6Prefix', 'IPRange', 'Vpn')
        }
    }
    supports_check_mode = $true
}

$module = [Ansible.Basic.AnsibleModule]::Create($args, $spec)
$module.result.changed = $false

$site_code = $module.Params.site_code
$name = $module.Params.name
$type = $module.Params.type

Import-CMPsModule -module $module
Test-CMSiteNameAndConnect -module $module -SiteCode $site_code

try {
    if ($null -ne $name -and $name -ne '') {
        $all_boundaries = @(Get-CMBoundary -BoundaryName $name -ErrorAction Stop)
    }
    else {
        $all_boundaries = @(Get-CMBoundary -ErrorAction Stop)
    }
}
catch {
    $module.FailJson("Failed to retrieve boundaries: $($_.Exception.Message)", $_)
}

if ($null -ne $type -and $type -ne '') {
    $desired_type_int = ConvertTo-BoundaryTypeInt -TypeStr $type
    $all_boundaries = @($all_boundaries | Where-Object { [int]$_.BoundaryType -eq $desired_type_int })
}

$results = @()
foreach ($boundary in $all_boundaries) {
    $results += Format-BoundaryResult -boundary $boundary
}

$module.result.boundaries = $results
$module.ExitJson()
