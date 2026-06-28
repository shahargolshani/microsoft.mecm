#!powershell

# Copyright: (c) 2025, Ansible Project
# GNU General Public License v3.0+ (see COPYING or https://www.gnu.org/licenses/gpl-3.0.txt)

#AnsibleRequires -CSharpUtil Ansible.Basic
#AnsibleRequires -PowerShell ..module_utils._CMPsSetupUtils


$DEPLOY_PURPOSE_MAP = @{
    'Required' = 1
    'Available' = 2
}

$DEPLOY_ACTION_MAP = @{
    'Install' = 0
    'Uninstall' = 2
}


$spec = @{
    options = @{
        site_code = @{ type = 'str'; required = $true }
        name = @{ type = 'str'; required = $false }
        collection_name = @{ type = 'str'; required = $false }
    }
    supports_check_mode = $true
}

$module = [Ansible.Basic.AnsibleModule]::Create($args, $spec)
$module.result.deployments = @()
$module.result.changed = $false

$site_code = $module.Params.site_code
$name = $module.Params.name
$collection_name = $module.Params.collection_name

if (-not [string]::IsNullOrEmpty($collection_name) -and [string]::IsNullOrEmpty($name)) {
    $module.FailJson("collection_name requires name to also be specified.")
}

Import-CMPsModule -module $module
Test-CMSiteNameAndConnect -SiteCode $site_code -Module $module

$results = [System.Collections.ArrayList]@()

if (-not [string]::IsNullOrEmpty($name)) {
    try {
        $deployments = @(Get-CMApplicationDeployment -Name $name -ErrorAction SilentlyContinue)
    }
    catch {
        $module.FailJson("Failed to query deployments for application '$name': $($_.Exception.Message)", $_)
    }
    if (-not $deployments) {
        $module.Warn("No deployments found for application '$name'.")
        $module.ExitJson()
    }
    if (-not [string]::IsNullOrEmpty($collection_name)) {
        $deployments = @($deployments | Where-Object { $_.CollectionName -eq $collection_name })
        if (-not $deployments) {
            $module.Warn("No deployment found for application '$name' targeting collection '$collection_name'.")
            $module.ExitJson()
        }
    }
}
else {
    try {
        $deployments = @(Get-CMApplicationDeployment -ErrorAction Stop)
    }
    catch {
        $module.FailJson("Failed to query application deployments: $($_.Exception.Message)", $_)
    }
}

foreach ($dep in $deployments) {
    if ($null -eq $dep) { continue }

    $purpose_int = [int]$dep.DesiredConfigType
    $action_int = [int]$dep.OfferTypeID
    $purpose_key = ($DEPLOY_PURPOSE_MAP.GetEnumerator() | Where-Object { $_.Value -eq $purpose_int } | Select-Object -First 1).Key
    $action_key = ($DEPLOY_ACTION_MAP.GetEnumerator() | Where-Object { $_.Value -eq $action_int } | Select-Object -First 1).Key

    $entry = @{
        name = $dep.ApplicationName
        collection_name = $dep.CollectionName
        deploy_purpose = if ($purpose_key) { $purpose_key } else { $purpose_int.ToString() }
        deploy_action = if ($action_key) { $action_key } else { $action_int.ToString() }
        available_date_time = Format-DateTimeAsStringSafely -dateTimeObject $dep.StartTime
        deadline_date_time = Format-DateTimeAsStringSafely -dateTimeObject $dep.EnforcementDeadline
    }
    $results.Add($entry) | Out-Null
}

$module.result.deployments = @($results)

$module.ExitJson()
