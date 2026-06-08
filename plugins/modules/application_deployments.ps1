#!powershell

# Copyright: (c) 2025, Ansible Project
# GNU General Public License v3.0+ (see COPYING or https://www.gnu.org/licenses/gpl-3.0.txt)

#AnsibleRequires -CSharpUtil Ansible.Basic
#AnsibleRequires -PowerShell ..module_utils._CMPsSetupUtils


# SMS_ApplicationAssignment.DesiredConfigType
$DEPLOY_PURPOSE_MAP = @{
    'Required' = 1
    'Available' = 2
}

# SMS_ApplicationAssignment.OfferTypeID
$DEPLOY_ACTION_MAP = @{
    'Install' = 0
    'Uninstall' = 2
}


function Assert-DateTimeParam {
    param (
        [Parameter(Mandatory = $true)][object]$module,
        [Parameter(Mandatory = $true)][string]$param_name,
        [Parameter(Mandatory = $true)][string]$value
    )
    $parsed = [datetime]::MinValue
    $valid = [datetime]::TryParseExact(
        $value,
        'MM/dd/yyyy HH:mm:ss',
        [System.Globalization.CultureInfo]::InvariantCulture,
        [System.Globalization.DateTimeStyles]::None,
        [ref]$parsed
    )
    if (-not $valid) {
        $module.FailJson(
            "$param_name ('$value') is not a valid date/time or does not match the required " +
            "format MM/DD/YYYY HH:MM:SS (e.g. 01/31/2025 08:00:00). " +
            "Ensure month is 01-12, day is valid for the month, hour is 00-23, and minutes/seconds are 00-59."
        )
    }
    return $parsed
}


function Assert-DeploymentDate {
    param (
        [Parameter(Mandatory = $true)][object]$module
    )
    $avail_dt = $null
    $deadline_dt = $null

    if (-not [string]::IsNullOrEmpty($module.Params.available_date_time)) {
        $avail_dt = Assert-DateTimeParam -module $module -param_name 'available_date_time' -value $module.Params.available_date_time
    }

    if (-not [string]::IsNullOrEmpty($module.Params.deadline_date_time)) {
        if ([string]::IsNullOrEmpty($module.Params.available_date_time)) {
            $module.FailJson(
                "deadline_date_time cannot be used without available_date_time. " +
                "Please provide available_date_time alongside deadline_date_time."
            )
        }
        $deadline_dt = Assert-DateTimeParam -module $module -param_name 'deadline_date_time' -value $module.Params.deadline_date_time
    }

    if ($null -ne $avail_dt -and $null -ne $deadline_dt -and $deadline_dt -lt $avail_dt) {
        $module.FailJson(
            "deadline_date_time ('$($module.Params.deadline_date_time)') must not be before " +
            "available_date_time ('$($module.Params.available_date_time)')."
        )
    }
}


function Format-DeploymentResult {
    param ([Parameter(Mandatory = $true)][object]$deployment)
    $purpose_int = [int]$deployment.DesiredConfigType
    $action_int = [int]$deployment.OfferTypeID
    $purpose_key = ($DEPLOY_PURPOSE_MAP.GetEnumerator() | Where-Object { $_.Value -eq $purpose_int } | Select-Object -First 1).Key
    $action_key = ($DEPLOY_ACTION_MAP.GetEnumerator() | Where-Object { $_.Value -eq $action_int } | Select-Object -First 1).Key
    return @{
        name = $deployment.ApplicationName
        collection_name = $deployment.CollectionName
        deploy_purpose = if ($purpose_key) { $purpose_key } else { $purpose_int.ToString() }
        deploy_action = if ($action_key) { $action_key } else { $action_int.ToString() }
        available_date_time = Format-DateTimeAsStringSafely -dateTimeObject $deployment.StartTime
        deadline_date_time = Format-DateTimeAsStringSafely -dateTimeObject $deployment.EnforcementDeadline
    }
}


function Test-DeploymentNeedsUpdate {
    param (
        [Parameter(Mandatory = $true)][object]$module,
        [Parameter(Mandatory = $true)][object]$deployment
    )
    # available_date_time - MECM stores StartTime in local time; compare as local
    if (-not [string]::IsNullOrEmpty($module.Params.available_date_time)) {
        $desired_dt = Get-Date $module.Params.available_date_time
        $stored_dt = $deployment.StartTime
        if ($null -eq $stored_dt -or $desired_dt.ToString('yyyy-MM-dd HH:mm') -ne ([datetime]$stored_dt).ToString('yyyy-MM-dd HH:mm')) {
            return $true
        }
    }

    # deadline_date_time - not applicable for Available deployments; MECM ignores it
    $is_available_deployment = [int]$deployment.DesiredConfigType -eq $DEPLOY_PURPOSE_MAP['Available']
    if (-not $is_available_deployment -and -not [string]::IsNullOrEmpty($module.Params.deadline_date_time)) {
        # MECM stores EnforcementDeadline in UTC; convert desired to UTC before comparing
        $desired_dt_utc = (Get-Date $module.Params.deadline_date_time).ToUniversalTime()
        $stored_dt = $deployment.EnforcementDeadline
        if ($null -eq $stored_dt -or $desired_dt_utc.ToString('yyyy-MM-dd HH:mm') -ne ([datetime]$stored_dt).ToString('yyyy-MM-dd HH:mm')) {
            return $true
        }
    }

    return $false
}


$spec = @{
    options = @{
        site_code = @{ type = 'str'; required = $true }
        name = @{ type = 'str'; required = $true }
        collection_name = @{ type = 'str'; required = $true }
        available_date_time = @{ type = 'str'; required = $false }
        deadline_date_time = @{ type = 'str'; required = $false }
        deploy_action = @{ type = 'str'; required = $false; choices = @('Install', 'Uninstall') }
        deploy_purpose = @{ type = 'str'; required = $false; choices = @('Available', 'Required') }
        distribute_content = @{ type = 'bool'; required = $false; default = $false }
        distribution_point_group_name = @{ type = 'str'; required = $false }
        state = @{ type = 'str'; required = $false; default = 'present'; choices = @('present', 'absent') }
    }
    required_if = @(
        , @('state', 'present', @('deploy_action', 'deploy_purpose'))
    )
    supports_check_mode = $true
}

$module = [Ansible.Basic.AnsibleModule]::Create($args, $spec)
$module.result.changed = $false
$module.result.deployment = @{}

$site_code = $module.Params.site_code
$name = $module.Params.name
$collection_name = $module.Params.collection_name
$state = $module.Params.state

Import-CMPsModule -module $module
Test-CMSiteNameAndConnect -module $module -SiteCode $site_code

# Look up existing deployment for this application + collection combination
$all_app_deployments = @(Get-CMApplicationDeployment -Name $name -ErrorAction SilentlyContinue)
$existing = $all_app_deployments | Where-Object { $_.CollectionName -eq $collection_name } | Select-Object -First 1

if ($state -eq 'absent') {
    if ($null -ne $existing) {
        $module.result.changed = $true
        $module.result.deployment = Format-DeploymentResult -deployment $existing
        if (-not $module.CheckMode) {
            try {
                Remove-CMApplicationDeployment -InputObject $existing -Force -Confirm:$false | Out-Null
            }
            catch {
                $module.FailJson("Failed to remove deployment of '$name' to '$collection_name': $($_.Exception.Message)", $_)
            }
        }
    }
}
elseif ($state -eq 'present') {
    if ($module.Params.deploy_action -eq 'Uninstall' -and $module.Params.deploy_purpose -ne 'Required') {
        $module.FailJson(
            "deploy_purpose must be 'Required' when deploy_action is 'Uninstall'. " +
            "MECM does not support an 'Available' uninstall deployment."
        )
    }

    if ($module.Params.deploy_purpose -eq 'Available' -and
        -not [string]::IsNullOrEmpty($module.Params.deadline_date_time)) {
        $module.FailJson(
            "deadline_date_time is not applicable when deploy_purpose is 'Available'. " +
            "MECM ignores the deadline for Available deployments. Remove deadline_date_time from the task."
        )
    }

    Assert-DeploymentDate -module $module

    if (-not [string]::IsNullOrEmpty($module.Params.distribution_point_group_name) -and
        -not $module.Params.distribute_content) {
        $module.FailJson(
            "distribute_content must be set to true when distribution_point_group_name ('$($module.Params.distribution_point_group_name)') is specified."
        )
    }

    if (-not [string]::IsNullOrEmpty($module.Params.distribution_point_group_name)) {
        $dp_group_check = Get-CMDistributionPointGroup -Name $module.Params.distribution_point_group_name -ErrorAction SilentlyContinue
        if ($null -eq $dp_group_check) {
            $module.FailJson(
                "Distribution point group '$($module.Params.distribution_point_group_name)' does not exist in MECM."
            )
        }
    }

    if ($null -eq $existing) {
        # --- Create new deployment ---
        $module.result.changed = $true
        $new_params = @{
            Name = $name
            CollectionName = $collection_name
            DeployAction = $module.Params.deploy_action
            DeployPurpose = $module.Params.deploy_purpose
            Confirm = $false
        }
        if (-not [string]::IsNullOrEmpty($module.Params.available_date_time)) {
            $new_params.AvailableDateTime = Get-Date $module.Params.available_date_time
        }
        if (-not [string]::IsNullOrEmpty($module.Params.deadline_date_time)) {
            $new_params.DeadlineDateTime = (Get-Date $module.Params.deadline_date_time).ToUniversalTime()
        }
        if ($module.Params.distribute_content) {
            $dp_group_name = $module.Params.distribution_point_group_name
            $already_distributed = $false

            if (-not [string]::IsNullOrEmpty($dp_group_name)) {
                try {
                    $app_obj = Get-CMApplication -Name $name -ErrorAction SilentlyContinue
                    if ($null -ne $app_obj) {
                        # Get all content (packages/applications) distributed to this DP group
                        # and check if this application's PackageID appears in the list
                        $group_content = @(Get-CMDeploymentPackage -DistributionPointGroupName $dp_group_name -ErrorAction SilentlyContinue)
                        $app_pkg_id = $app_obj.PackageID
                        $already_distributed = ($group_content | Where-Object { $_.PackageID -eq $app_pkg_id }).Count -gt 0
                    }
                }
                catch {
                    $module.Warn("Content distribution pre-check failed: $($_.Exception.Message). Proceeding and letting MECM decide.")
                }
            }

            if ($already_distributed) {
                $module.Warn(
                    "Content for '$name' is already distributed to DP group '$dp_group_name'. " +
                    "Skipping content distribution and creating the deployment only."
                )
            }
            else {
                $new_params.DistributeContent = $true
                if (-not [string]::IsNullOrEmpty($dp_group_name)) {
                    $new_params.DistributionPointGroupName = $dp_group_name
                }
            }
        }

        try {
            New-CMApplicationDeployment @new_params -WhatIf:$module.CheckMode | Out-Null
        }
        catch {
            # Catch the case where content distribution was requested but already done
            if ($_.Exception.Message -like '*already been distributed*' -or
                $_.Exception.Message -like '*No content destination*') {
                $module.Warn(
                    "Content for '$name' is already distributed to '$($module.Params.distribution_point_group_name)'. " +
                    "Creating deployment without content distribution."
                )
                $new_params.Remove('DistributeContent')
                $new_params.Remove('DistributionPointGroupName')
                try {
                    New-CMApplicationDeployment @new_params -WhatIf:$module.CheckMode | Out-Null
                }
                catch {
                    $module.FailJson("Failed to create deployment of '$name' to '$collection_name': $($_.Exception.Message)", $_)
                }
            }
            else {
                $module.FailJson("Failed to create deployment of '$name' to '$collection_name': $($_.Exception.Message)", $_)
            }
        }

        if (-not $module.CheckMode) {
            $created = @(Get-CMApplicationDeployment -Name $name -ErrorAction SilentlyContinue) |
                Where-Object { $_.CollectionName -eq $collection_name } | Select-Object -First 1
            $module.result.deployment = Format-DeploymentResult -deployment $created
        }
        else {
            $module.result.deployment = @{
                name = $name
                collection_name = $collection_name
                deploy_action = $module.Params.deploy_action
                deploy_purpose = $module.Params.deploy_purpose
                available_date_time = $module.Params.available_date_time
                deadline_date_time = $module.Params.deadline_date_time
            }
        }
    }
    else {
        # --- Update existing deployment ---
        $creation_only_used = [System.Collections.Generic.List[string]]@()
        if (-not [string]::IsNullOrEmpty($module.Params.deploy_action)) {
            $creation_only_used.Add("deploy_action='$($module.Params.deploy_action)'")
        }
        if (-not [string]::IsNullOrEmpty($module.Params.deploy_purpose)) {
            $creation_only_used.Add("deploy_purpose='$($module.Params.deploy_purpose)'")
        }
        if (-not [string]::IsNullOrEmpty($module.Params.distribution_point_group_name)) {
            $creation_only_used.Add("distribution_point_group_name='$($module.Params.distribution_point_group_name)'")
        }
        if ($creation_only_used.Count -gt 0) {
            $module.Warn(
                "The following parameter(s) are creation-only and will be ignored because the deployment already exists: " +
                "$($creation_only_used -join ', '). "
            )
        }

        if ([int]$existing.DesiredConfigType -eq $DEPLOY_PURPOSE_MAP['Available'] -and
            -not [string]::IsNullOrEmpty($module.Params.deadline_date_time)) {
            $module.Warn(
                "deadline_date_time is ignored because this is an Available deployment. " +
                "Remove deadline_date_time from the task to suppress this warning."
            )
        }

        $needs_update = Test-DeploymentNeedsUpdate -module $module -deployment $existing
        $module.result.changed = $needs_update

        if ($needs_update) {
            $set_params = @{
                ApplicationName = $name
                CollectionName = $collection_name
                Confirm = $false
            }
            if (-not [string]::IsNullOrEmpty($module.Params.available_date_time)) {
                $set_params.AvailableDateTime = Get-Date $module.Params.available_date_time
            }
            if (-not [string]::IsNullOrEmpty($module.Params.deadline_date_time)) {
                $set_params.DeadlineDateTime = (Get-Date $module.Params.deadline_date_time).ToUniversalTime()
            }

            try {
                Set-CMApplicationDeployment @set_params -WhatIf:$module.CheckMode | Out-Null
            }
            catch {
                $module.FailJson("Failed to update deployment of '$name' to '$collection_name': $($_.Exception.Message)", $_)
            }
        }

        if (-not $module.CheckMode) {
            $updated = @(Get-CMApplicationDeployment -Name $name -ErrorAction SilentlyContinue) |
                Where-Object { $_.CollectionName -eq $collection_name } | Select-Object -First 1
            $module.result.deployment = Format-DeploymentResult -deployment $updated
        }
        else {
            $existing_formatted = Format-DeploymentResult -deployment $existing
            $module.result.deployment = @{
                name = $name
                collection_name = $collection_name
                deploy_action = $existing_formatted.deploy_action
                deploy_purpose = $existing_formatted.deploy_purpose
                available_date_time = if ($module.Params.available_date_time) {
                    $module.Params.available_date_time
                }
                else {
                    $existing_formatted.available_date_time
                }
                deadline_date_time = if ($module.Params.deadline_date_time) {
                    $module.Params.deadline_date_time
                }
                else {
                    $existing_formatted.deadline_date_time
                }
            }
        }
    }
}

$module.ExitJson()
