#!powershell

# Copyright: (c) 2025, Ansible Project
# GNU General Public License v3.0+ (see COPYING or https://www.gnu.org/licenses/gpl-3.0.txt)

#AnsibleRequires -CSharpUtil Ansible.Basic
#AnsibleRequires -PowerShell ..module_utils._CMPsSetupUtils
#AnsibleRequires -PowerShell ..module_utils._BoundaryUtils


# Looks up a boundary by the unique type:value pair.
function Get-BoundaryByTypeAndValue {
    param (
        [Parameter(Mandatory = $true)][int]$type_int,
        [Parameter(Mandatory = $true)][string]$value
    )
    $found = Get-CMBoundary -ErrorAction SilentlyContinue |
        Where-Object { [int]$_.BoundaryType -eq $type_int -and $_.Value -eq $value } |
        Select-Object -First 1
    return $found
}


function Assert-VpnBoundaryValue {
    param (
        [Parameter(Mandatory = $true)][object]$module,
        [Parameter(Mandatory = $true)][string]$value
    )
    if ($value -eq 'Auto:On') { return }
    if ($value -match '^Name:.+') { return }
    if ($value -match '^Description:.+') { return }
    $module.FailJson(
        "Invalid value '$value' for type 'Vpn'. " +
        "Accepted formats: 'Auto:On', 'Name:<vpn_name>', 'Description:<vpn_description>'."
    )
}


$spec = @{
    options = @{
        site_code = @{ type = 'str'; required = $true }
        name = @{ type = 'str'; required = $false; default = '' }
        type = @{
            type = 'str'
            required = $true
            choices = @('IPSubnet', 'ADSite', 'IPV6Prefix', 'IPRange', 'Vpn')
        }
        value = @{ type = 'str'; required = $true }
        state = @{
            type = 'str'
            required = $false
            default = 'present'
            choices = @('present', 'absent')
        }
    }
    supports_check_mode = $true
}

$module = [Ansible.Basic.AnsibleModule]::Create($args, $spec)
$module.result.changed = $false
$module.result.boundary = @{}

$site_code = $module.Params.site_code
$name = $module.Params.name
$type = $module.Params.type
$value = $module.Params.value
$state = $module.Params.state

if ($type -eq 'Vpn') {
    Assert-VpnBoundaryValue -module $module -value $value
}

Import-CMPsModule -module $module
Test-CMSiteNameAndConnect -module $module -SiteCode $site_code

$desired_type_int = ConvertTo-BoundaryTypeInt -TypeStr $type
$boundary = Get-BoundaryByTypeAndValue -type_int $desired_type_int -value $value

if ($state -eq 'absent') {
    if ($null -ne $boundary) {
        try {
            Remove-CMBoundary -InputObject $boundary -Force -Confirm:$false -WhatIf:$module.CheckMode
        }
        catch {
            $module.FailJson("Failed to remove boundary (type='$type', value='$value'): $($_.Exception.Message)", $_)
        }
        $module.result.changed = $true
        $module.result.boundary = Format-BoundaryResult -boundary $boundary
    }
}
elseif ($state -eq 'present') {
    if ($null -eq $boundary) {
        $create_params = @{ Type = $type; Value = $value }
        if ($name -ne '') {
            $create_params['DisplayName'] = $name
        }
        try {
            $boundary = New-CMBoundary @create_params -WhatIf:$module.CheckMode
        }
        catch {
            $module.FailJson("Failed to create boundary (type='$type', value='$value'): $($_.Exception.Message)", $_)
        }
        $module.result.changed = $true
    }

    if (-not $module.CheckMode -and $null -ne $boundary) {
        $module.result.boundary = Format-BoundaryResult -boundary $boundary
    }
}

$module.ExitJson()
