#!powershell

# Copyright: (c) 2025, Ansible Project
# GNU General Public License v3.0+ (see COPYING or https://www.gnu.org/licenses/gpl-3.0.txt)

#AnsibleRequires -CSharpUtil Ansible.Basic
#AnsibleRequires -PowerShell ..module_utils._CMPsSetupUtils


# Maps module parameter names to New-CMApplication / Set-CMApplication cmdlet parameter names
$APPLICATION_PARAMS = @{
    name = "Name"
    description = "Description"
    publisher = "Publisher"
    software_version = "SoftwareVersion"
    optional_reference = "OptionalReference"
    owners = "AddOwner"
    support_contacts = "AddSupportContact"
    localized_name = "LocalizedApplicationName"
    localized_description = "LocalizedDescription"
    user_documentation = "UserDocumentation"
    link_text = "LinkText"
    keyword = "Keyword"
    privacy_url = "PrivacyUrl"
    default_language_id = "DefaultLanguageId"
}

$SWITCH_PARAMS = @{
    auto_install = "AutoInstall"
    is_featured = "IsFeatured"
}

$DATETIME_PARAMS = @{
    release_date = "ReleaseDate"
}

# Maps module parameter names to CMApplication object property names returned by Get-CMApplication
# Used to compare user input against the existing object for idempotency
$GET_APPLICATION_PARAMS = @{
    name = { param($app, $xml) $app.LocalizedDisplayName }
    description = { param($app, $xml) $app.LocalizedDescription }
    publisher = { param($app, $xml) $app.Manufacturer }
    software_version = { param($app, $xml) $app.SoftwareVersion }
    optional_reference = { param($app, $xml) $xml.AppMgmtDigest.Application.CustomId.'#text' }
    auto_install = { param($app, $xml)
        $val = $xml.AppMgmtDigest.Application.AutoInstall
        if ($null -eq $val -or $val -eq '') { return $false }
        return [System.Convert]::ToBoolean($val)
    }
    owners = { param($app, $xml) $xml.AppMgmtDigest.Application.Owners.User.Id }
    support_contacts = { param($app, $xml) $xml.AppMgmtDigest.Application.Contacts.User.Id }
    localized_name = { param($app, $xml) $xml.AppMgmtDigest.Application.DisplayInfo.Info.Title }
    localized_description = { param($app, $xml) $xml.AppMgmtDigest.Application.DisplayInfo.Info.Description }
    user_documentation = { param($app, $xml) $xml.AppMgmtDigest.Application.DisplayInfo.Info.InfoUrl }
    link_text = { param($app, $xml) $xml.AppMgmtDigest.Application.DisplayInfo.Info.InfoUrlText }
    keyword = { param($app, $xml) $xml.AppMgmtDigest.Application.DisplayInfo.Info.Tags.Tag }
    privacy_url = { param($app, $xml) $xml.AppMgmtDigest.Application.DisplayInfo.Info.PrivacyUrl }
    is_featured = { param($app, $xml) [bool]$app.Featured }
    default_languages = { param($app, $xml) $xml.AppMgmtDigest.Application.DisplayInfo.Info.Language }
    default_language_id = { param($app, $xml) $xml.AppMgmtDigest.Application.DisplayInfo.DefaultLanguage }
    release_date = { param($app, $xml) $xml.AppMgmtDigest.Application.DisplayInfo.Info.ReleaseDate }
}

# List parameters that use set comparison (add/remove) during updates
# Maps module param name to @(AddCmdletParam, RemoveCmdletParam)
$LIST_DIFF_PARAMS = @{
    owners = @("AddOwner", "RemoveOwner")
    support_contacts = @("AddSupportContact", "RemoveSupportContact")
}

# List parameters that use full-set replacement (no add/remove cmdlet params)
# Maps module param name to the cmdlet parameter name
$LIST_SET_PARAMS = @{
    keyword = "Keyword"
}


function Format-ApplicationResult {
    param (
        [Parameter(Mandatory = $true)][object]$app
    )
    return @{
        name = $app.LocalizedDisplayName
        id = $app.CI_ID.ToString()
        publisher = $app.Manufacturer
        software_version = $app.SoftwareVersion
        is_deployed = $app.IsDeployed
        is_enabled = $app.IsEnabled
    }
}


function Test-ApplicationNeedsUpdate {
    param (
        [Parameter(Mandatory = $true)][object]$module,
        [Parameter(Mandatory = $true)][object]$app
    )
    try {
        [xml]$xml = $app.SDMPackageXML
    }
    catch {
        $module.FailJson("Failed to parse application XML metadata: $($_.Exception.Message)", $_)
    }

    foreach ($key in $GET_APPLICATION_PARAMS.Keys) {
        if ($key -eq 'name') { continue }
        if ($LIST_DIFF_PARAMS.ContainsKey($key)) { continue }
        if ($LIST_SET_PARAMS.ContainsKey($key)) { continue }
        if ($null -eq $module.Params.$key) { continue }

        $current_value = & $GET_APPLICATION_PARAMS[$key] $app $xml
        if ($key -eq 'default_language_id' -and $current_value) {
            $current_value = [System.Globalization.CultureInfo]::GetCultureInfo($current_value).LCID
        }
        if ($module.Params.$key -is [array]) {
            if (Compare-Object @($module.Params.$key) @($current_value)) {
                return $true
            }
        }
        elseif ($module.Params.$key -ne $current_value) {
            return $true
        }
    }

    foreach ($key in $LIST_DIFF_PARAMS.Keys) {
        if ($null -eq $module.Params.$key) { continue }
        $current = @(& $GET_APPLICATION_PARAMS[$key] $app $xml | Where-Object { $_ })
        $desired = @($module.Params.$key)
        $to_add = @($desired | Where-Object { $_ -notin $current })
        $to_remove = @($current | Where-Object { $_ -notin $desired })
        if ($to_add.Count -gt 0 -or $to_remove.Count -gt 0) {
            return $true
        }
    }

    foreach ($key in $LIST_SET_PARAMS.Keys) {
        if ($null -eq $module.Params.$key) { continue }
        $current = @(& $GET_APPLICATION_PARAMS[$key] $app $xml | Where-Object { $_ })
        $desired = @($module.Params.$key)
        $to_add = @($desired | Where-Object { $_ -notin $current })
        $to_remove = @($current | Where-Object { $_ -notin $desired })
        if ($to_add.Count -gt 0 -or $to_remove.Count -gt 0) {
            return $true
        }
    }

    return $false
}


function Complete-ApplicationCreation {
    param (
        [Parameter(Mandatory = $true)][object]$module
    )
    $module.result.changed = $true
    $cmdlet_params = Format-ModuleParamAsCmdletArgument `
        -module $module -direct_mapped_params $APPLICATION_PARAMS `
        -datetime_params $DATETIME_PARAMS -switch_params $SWITCH_PARAMS

    try {
        $newApp = New-CMApplication @cmdlet_params -WhatIf:$module.CheckMode
    }
    catch {
        $module.FailJson("Failed to create application: $($_.Exception.Message)", $_)
    }

    if (-not $module.CheckMode) {
        $module.result.application = Format-ApplicationResult -app $newApp
    }
}


function Complete-ApplicationUpdate {
    param (
        [Parameter(Mandatory = $true)][object]$module,
        [Parameter(Mandatory = $true)][object]$app
    )
    $needs_update = Test-ApplicationNeedsUpdate -module $module -app $app
    $module.result.changed = $needs_update

    if ($needs_update) {
        $update_params = @{}
        foreach ($key in $APPLICATION_PARAMS.Keys) {
            if ($key -eq 'name') { continue }
            if ($LIST_DIFF_PARAMS.ContainsKey($key)) { continue }
            if ($LIST_SET_PARAMS.ContainsKey($key)) { continue }
            $update_params[$key] = $APPLICATION_PARAMS[$key]
        }
        $cmdlet_params = Format-ModuleParamAsCmdletArgument `
            -module $module -direct_mapped_params $update_params `
            -datetime_params $DATETIME_PARAMS -switch_params $SWITCH_PARAMS

        try {
            [xml]$xml = $app.SDMPackageXML
        }
        catch {
            $module.FailJson("Failed to parse application XML metadata: $($_.Exception.Message)", $_)
        }

        foreach ($key in $LIST_DIFF_PARAMS.Keys) {
            if ($null -eq $module.Params.$key) { continue }
            $current = @(& $GET_APPLICATION_PARAMS[$key] $app $xml | Where-Object { $_ })
            $desired = @($module.Params.$key)
            $to_add = @($desired | Where-Object { $_ -notin $current })
            $to_remove = @($current | Where-Object { $_ -notin $desired })
            if ($to_add.Count -gt 0) { $cmdlet_params[$LIST_DIFF_PARAMS[$key][0]] = $to_add }
            if ($to_remove.Count -gt 0) { $cmdlet_params[$LIST_DIFF_PARAMS[$key][1]] = $to_remove }
        }

        foreach ($key in $LIST_SET_PARAMS.Keys) {
            if ($null -eq $module.Params.$key) { continue }
            $current = @(& $GET_APPLICATION_PARAMS[$key] $app $xml | Where-Object { $_ })
            $desired = @($module.Params.$key)
            $to_add = @($desired | Where-Object { $_ -notin $current })
            $to_remove = @($current | Where-Object { $_ -notin $desired })
            if ($to_add.Count -gt 0 -or $to_remove.Count -gt 0) {
                $cmdlet_params[$LIST_SET_PARAMS[$key]] = $desired
            }
        }

        try {
            Set-CMApplication -InputObject $app @cmdlet_params -Confirm:$false -WhatIf:$module.CheckMode
        }
        catch {
            $module.FailJson("Failed to update application: $($_.Exception.Message)", $_)
        }
    }
    $module.result.application = Format-ApplicationResult -app $app
}


$spec = @{
    options = @{
        site_code = @{ type = 'str'; required = $true }
        name = @{ type = 'str'; required = $true }
        state = @{ type = 'str'; required = $false; default = 'present'; choices = @('present', 'absent') }
        description = @{ type = 'str'; required = $false }
        publisher = @{ type = 'str'; required = $false }
        software_version = @{ type = 'str'; required = $false }
        optional_reference = @{ type = 'str'; required = $false }
        release_date = @{ type = 'str'; required = $false }
        auto_install = @{ type = 'bool'; required = $false }
        owners = @{ type = 'list'; elements = 'str'; required = $false }
        support_contacts = @{ type = 'list'; elements = 'str'; required = $false }
        localized_name = @{ type = 'str'; required = $false }
        localized_description = @{ type = 'str'; required = $false }
        user_documentation = @{ type = 'str'; required = $false }
        link_text = @{ type = 'str'; required = $false }
        keyword = @{ type = 'list'; elements = 'str'; required = $false; no_log = $false }
        privacy_url = @{ type = 'str'; required = $false }
        is_featured = @{ type = 'bool'; required = $false }
        default_language_id = @{ type = 'int'; required = $false }
    }
    supports_check_mode = $true
}

$module = [Ansible.Basic.AnsibleModule]::Create($args, $spec)
$module.result.changed = $false
$module.result.application = @{}

$site_code = $module.Params.site_code
$state = $module.Params.state
$name = $module.Params.name

Import-CMPsModule -module $module
Test-CMSiteNameAndConnect -module $module -SiteCode $site_code

$application = Get-CMApplication -Name "$name"

if (($state -eq "absent") -and ($null -ne $application)) {
    try {
        Remove-CMApplication -InputObject $application -Force -Confirm:$false -WhatIf:$module.CheckMode
    }
    catch {
        $module.FailJson("Failed to remove application: $($_.Exception.Message)", $_)
    }
    $module.result.changed = $true
    $module.result.application = Format-ApplicationResult -app $application
}
elseif ($state -eq "present") {
    if ($null -ne $application) {
        Complete-ApplicationUpdate -module $module -app $application
    }
    else {
        Complete-ApplicationCreation -module $module
    }
}

$module.ExitJson()
