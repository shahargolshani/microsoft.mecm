# Copyright: (c) 2025, Ansible Project
# GNU General Public License v3.0+ (see COPYING or https://www.gnu.org/licenses/gpl-3.0.txt)

# NOTE: "return" in powershell does not work as many people expect. Read the PS docs before using it.


function Get-AutoDeploymentProp {
    <#
    .SYNOPSIS
    Returns the text value of a named element from the AutoDeploymentProperties XML, or $null.
    #>
    param (
        [Parameter(Mandatory = $true)][object]$adr,
        [Parameter(Mandatory = $true)][string]$element_name
    )
    if ([string]::IsNullOrEmpty($adr.AutoDeploymentProperties)) {
        return $null
    }
    try {
        [xml]$xml = $adr.AutoDeploymentProperties
        return $xml.AutoDeploymentRule.$element_name
    }
    catch {
        return $null
    }
}


function Get-DeploymentTemplateProp {
    <#
    .SYNOPSIS
    Returns the text value of a named element from the DeploymentTemplate XML, or $null.
    #>
    param (
        [Parameter(Mandatory = $true)][object]$adr,
        [Parameter(Mandatory = $true)][string]$element_name
    )
    if ([string]::IsNullOrEmpty($adr.DeploymentTemplate)) {
        return $null
    }
    try {
        [xml]$xml = $adr.DeploymentTemplate
        return $xml.DeploymentCreationActionXML.$element_name
    }
    catch {
        return $null
    }
}


function Format-ADRResult {
    <#
    .SYNOPSIS
    Converts a raw ADR object into a normalized hashtable for module output.
    #>
    param (
        [Parameter(Mandatory = $true)][object]$adr
    )
    $run_type_map = @{
        'DoNotRunThisRuleAutomatically' = 0
        'RunTheRuleOnSchedule' = 1
        'RunTheRuleAfterAnySoftwareUpdatePointSynchronization' = 2
    }
    $current_run_type_str = Get-CurrentRunType -adr $adr
    return @{
        name = $adr.Name
        id = $adr.AutoDeploymentID.ToString()
        description = $adr.Description
        collection_id = $adr.CollectionID
        is_enabled = [bool]$adr.AutoDeploymentEnabled
        run_type = $run_type_map[$current_run_type_str]
        last_run_time = Format-DateTimeAsStringSafely -dateTimeObject $adr.LastRunTime
    }
}


function Get-CurrentRunType {
    <#
    .SYNOPSIS
    Derives the effective run_type string from the stored ADR properties.
    #>
    param (
        [Parameter(Mandatory = $true)][object]$adr
    )

    $align_with_sync = Get-AutoDeploymentProp -adr $adr -element_name 'AlignWithSyncSchedule'

    if ($align_with_sync -eq 'true') {
        return 'RunTheRuleAfterAnySoftwareUpdatePointSynchronization'
    }

    if (-not [string]::IsNullOrEmpty($adr.Schedule)) {
        return 'RunTheRuleOnSchedule'
    }

    return 'DoNotRunThisRuleAutomatically'
}
