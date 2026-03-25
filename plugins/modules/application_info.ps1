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
$module.result.applications = @()
$module.result.changed = $false

$site_code = $module.Params.site_code

Import-CMPsModule -module $module
Test-CMSiteNameAndConnect -SiteCode $site_code -Module $module

$applications = @()
if (-not [string]::IsNullOrEmpty($module.Params.name)) {
    try {
        $app = Get-CMApplication -Name "$($module.Params.name)"
        if ($null -ne $app) {
            if ($app -is [array]) {
                $applications = $app
            }
            else {
                $applications += $app
            }
        }
    }
    catch {
        $module.FailJson("Failed to query application with Name '$($module.Params.name)': $($_.Exception.Message)", $_)
    }
}
else {
    try {
        $allApps = Get-CMApplication
        if ($null -ne $allApps) {
            if ($allApps -is [array]) {
                $applications = $allApps
            }
            else {
                $applications += $allApps
            }
        }
    }
    catch {
        $module.FailJson("Failed to query applications: $($_.Exception.Message)", $_)
    }
}

foreach ($app in $applications) {
    if ($null -eq $app) {
        continue
    }
    try {
        [xml]$xml = $app.SDMPackageXML
    }
    catch {
        $module.FailJson("Failed to parse application XML metadata: $($_.Exception.Message)", $_)
    }
    $module.result.applications += @{
        name = $app.LocalizedDisplayName
        id = $app.CI_ID.ToString()
        description = $app.LocalizedDescription
        publisher = $app.Manufacturer
        software_version = $app.SoftwareVersion
        optional_reference = $xml.AppMgmtDigest.Application.CustomId.'#text'
        auto_install = if ($xml.AppMgmtDigest.Application.AutoInstall) { $true } else { $false }
        owners = @($xml.AppMgmtDigest.Application.Owners.User.Id | Where-Object { $_ })
        support_contacts = @($xml.AppMgmtDigest.Application.Contacts.User.Id | Where-Object { $_ })
        localized_name = $xml.AppMgmtDigest.Application.DisplayInfo.Info.Title
        localized_description = $xml.AppMgmtDigest.Application.DisplayInfo.Info.Description
        user_documentation = $xml.AppMgmtDigest.Application.DisplayInfo.Info.InfoUrl
        link_text = $xml.AppMgmtDigest.Application.DisplayInfo.Info.InfoUrlText
        keyword = @($xml.AppMgmtDigest.Application.DisplayInfo.Info.Tags.Tag | Where-Object { $_ })
        privacy_url = $xml.AppMgmtDigest.Application.DisplayInfo.Info.PrivacyUrl
        is_featured = [bool]$app.Featured
        default_language_id = if ($xml.AppMgmtDigest.Application.DisplayInfo.DefaultLanguage) {
            [System.Globalization.CultureInfo]::GetCultureInfo($xml.AppMgmtDigest.Application.DisplayInfo.DefaultLanguage).LCID
        }
        else {
            $null
        }
        release_date = $xml.AppMgmtDigest.Application.DisplayInfo.Info.ReleaseDate
        is_deployed = $app.IsDeployed
        is_enabled = $app.IsEnabled
        is_expired = $app.IsExpired
        is_superseded = $app.IsSuperseded
        date_created = Format-DateTimeAsStringSafely -dateTimeObject $app.DateCreated
        date_last_modified = Format-DateTimeAsStringSafely -dateTimeObject $app.DateLastModified
        created_by = $app.CreatedBy
        number_of_deployments = $app.NumberOfDeployments
    }
}

$module.ExitJson()
