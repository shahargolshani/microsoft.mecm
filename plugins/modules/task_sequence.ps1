#!powershell

# Copyright: (c) 2025, Ansible Project
# GNU General Public License v3.0+ (see COPYING or https://www.gnu.org/licenses/gpl-3.0.txt)

#AnsibleRequires -CSharpUtil Ansible.Basic
#AnsibleRequires -PowerShell ..module_utils._CMPsSetupUtils


function Format-TaskSequenceResult {
    param ([Parameter(Mandatory = $true)][object]$ts)
    return @{
        name = $ts.Name
        package_id = $ts.PackageID
        description = $ts.Description
        boot_image_id = $ts.BootImageID
    }
}


function Add-NonNullParam {
    param (
        [Parameter(Mandatory = $true)][hashtable]$target,
        [Parameter(Mandatory = $true)][hashtable]$optional
    )
    foreach ($key in $optional.Keys) {
        if ($null -ne $optional[$key]) {
            $target[$key] = $optional[$key]
        }
    }
}


$spec = @{
    options = @{
        site_code = @{ type = 'str'; required = $true }
        state = @{ type = 'str'; required = $false; default = 'present'; choices = @('present', 'absent') }
        create_method = @{ type = 'str'; required = $false; choices = @('import', 'custom') }
        import_path = @{ type = 'str'; required = $false }
        name = @{ type = 'str'; required = $false }
        description = @{ type = 'str'; required = $false }
        boot_image_package_id = @{ type = 'str'; required = $false }
        package_id = @{ type = 'str'; required = $false }
    }
    supports_check_mode = $true
}

$module = [Ansible.Basic.AnsibleModule]::Create($args, $spec)
$module.result.changed = $false
$module.result.task_sequence = @{}

$site_code = $module.Params.site_code
$state = $module.Params.state
$create_method = $module.Params.create_method
$import_path = $module.Params.import_path
$name = $module.Params.name
$description = $module.Params.description
$boot_image_package_id = $module.Params.boot_image_package_id
$package_id = $module.Params.package_id

if ($null -ne $package_id -and $state -ne 'absent') {
    $module.FailJson("'package_id' can only be set with state: absent.")
}
if ($state -eq 'absent') {
    if ($null -eq $package_id) {
        $module.FailJson("'package_id' is required when state: absent.")
    }
    $present_only_params = @('boot_image_package_id', 'create_method', 'description', 'name', 'import_path')
    $invalid = @($present_only_params | Where-Object { $null -ne $module.Params[$_] })
    if ($invalid.Count -gt 0) {
        $module.FailJson(
            "The following parameters cannot be set with state: absent: $($invalid -join ', '). " +
            "Use state: absent with package_id only."
        )
    }
}
if ($state -eq 'present' -and $null -eq $create_method) {
    $module.FailJson("'create_method' is required when state: present.")
}
if ($null -ne $import_path -and $create_method -ne 'import') {
    $module.FailJson("'import_path' can only be set with create_method: import.")
}
if ($create_method -eq 'import' -and $null -eq $import_path) {
    $module.FailJson("'import_path' is required when create_method: import.")
}
foreach ($custom_param in @('name', 'description', 'boot_image_package_id')) {
    if ($null -ne $module.Params[$custom_param] -and $create_method -ne 'custom') {
        $module.FailJson("'$custom_param' can only be set with create_method: custom.")
    }
}
if ($create_method -eq 'custom' -and $null -eq $name) {
    $module.FailJson("'name' is required when create_method: custom.")
}

Import-CMPsModule -module $module
Test-CMSiteNameAndConnect -SiteCode $site_code -Module $module

if ($state -eq 'absent') {
    $ts = Get-CMTaskSequence -TaskSequencePackageId $package_id -ErrorAction SilentlyContinue
    if ($null -ne $ts) {
        $module.result.task_sequence = Format-TaskSequenceResult -ts $ts
        $module.result.changed = $true
        try {
            Remove-CMTaskSequence -TaskSequencePackageId $package_id -Force -Confirm:$false -WhatIf:$module.CheckMode
        }
        catch {
            $module.FailJson("Failed to remove task sequence '$package_id': $($_.Exception.Message)", $_)
        }
    }
    $module.ExitJson()
}

if ($state -eq 'present') {

    if ($create_method -eq 'import') {
        try {
            $null = Import-CMTaskSequence -ImportFilePath $import_path -ImportActionType Overwrite -WhatIf:$module.CheckMode
            $module.result.changed = $true
            $null = $module.result.Remove('task_sequence')
        }
        catch {
            $err_msg = $_.Exception.Message
            if ($err_msg -match "does not exist or could not be found") {
                $module.FailJson("Import failed: task sequence file '$import_path' does not exist or could not be found.", $_)
            }
            else {
                $module.FailJson("Failed to import task sequence from '$import_path': $err_msg", $_)
            }
        }
    }
    elseif ($create_method -eq 'custom') {
        if ($null -ne $boot_image_package_id) {
            $boot_image = Get-CMBootImage -Id $boot_image_package_id -ErrorAction SilentlyContinue
            if ($null -eq $boot_image) {
                $module.FailJson("Boot image package '$boot_image_package_id' does not exist in site '$site_code'.")
            }
        }

        $ts = Get-CMTaskSequence -Name $name -ErrorAction SilentlyContinue
        if ($null -eq $ts) {
            $create_params = @{
                CustomTaskSequence = $true
                Name = $name
            }
            Add-NonNullParam -target $create_params -optional @{
                Description = $description
                BootImagePackageId = $boot_image_package_id
            }

            try {
                $new_ts = New-CMTaskSequence @create_params -WhatIf:$module.CheckMode
            }
            catch {
                $module.FailJson("Failed to create task sequence '$name': $($_.Exception.Message)", $_)
            }

            $module.result.changed = $true

            if (-not $module.CheckMode -and $null -ne $new_ts) {
                $module.result.task_sequence = Format-TaskSequenceResult -ts $new_ts
            }
            else {
                $module.result.task_sequence = @{
                    name = $name
                    description = if ($null -ne $description) { $description } else { '' }
                    boot_image_id = if ($null -ne $boot_image_package_id) { $boot_image_package_id } else { '' }
                }
            }
        }
        else {
            if ($ts.GetType().Name -eq 'Object[]') {
                $module.FailJson(
                    "Task sequence name '$name' is ambiguous: $($ts.Length) task sequences share this name. " +
                    "Cannot determine which one to operate on. package_id is not supported for method custom at this point."
                )
            }

            $needs_update = $false
            $update_checks = @(
                @{ desired = $description; current = $ts.Description }
                @{ desired = $boot_image_package_id; current = $ts.BootImageID }
            )
            foreach ($check in $update_checks) {
                if ($null -ne $check.desired -and $check.desired -ne $check.current) {
                    $needs_update = $true
                    break
                }
            }

            if ($needs_update) {

                $update_params = @{}
                Add-NonNullParam -target $update_params -optional @{
                    Description = $description
                    BootImageId = $boot_image_package_id
                }
                if ($null -ne $boot_image_package_id) {
                    $update_params.UseBootImage = $true
                }

                try {
                    Set-CMTaskSequence -InputObject $ts @update_params -WhatIf:$module.CheckMode
                }
                catch {
                    $module.FailJson("Failed to update task sequence '$name': $($_.Exception.Message)", $_)
                }

                $module.result.changed = $true

                if (-not $module.CheckMode) {
                    $updated_ts = Get-CMTaskSequence -TaskSequencePackageId $ts.PackageID -ErrorAction SilentlyContinue
                    if ($null -ne $updated_ts) {
                        $module.result.task_sequence = Format-TaskSequenceResult -ts $updated_ts
                    }
                }
                else {
                    $module.result.task_sequence = @{
                        name = $ts.Name
                        package_id = $ts.PackageID
                        description = if ($null -ne $description) { $description } else { $ts.Description }
                        boot_image_id = if ($null -ne $boot_image_package_id) { $boot_image_package_id } else { $ts.BootImageID }
                    }
                }
            }
            else {
                $module.result.task_sequence = Format-TaskSequenceResult -ts $ts
            }
        }
    }

}

$module.ExitJson()
