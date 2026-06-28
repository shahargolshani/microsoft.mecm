# Copyright: (c) 2025, Ansible Project
# GNU General Public License v3.0+ (see COPYING or https://www.gnu.org/licenses/gpl-3.0.txt)

# NOTE: "return" in powershell does not work as many people expect. Read the PS docs before using it.

# Maps boundary type string names (as accepted by New/Set-CMBoundary -Type) to the integer
# values stored in the BoundaryType property returned by Get-CMBoundary.
$BOUNDARY_TYPE_INT = @{
    IPSubnet = 0
    ADSite = 1
    IPV6Prefix = 2
    IPRange = 3
    Vpn = 4
}


function ConvertTo-BoundaryTypeInt {
    param (
        [Parameter(Mandatory = $true)][string]$TypeStr
    )
    return $BOUNDARY_TYPE_INT[$TypeStr]
}


function Format-BoundaryResult {
    param (
        [Parameter(Mandatory = $true)][object]$boundary
    )
    $type_int = [int]$boundary.BoundaryType
    $type_str = ($BOUNDARY_TYPE_INT.GetEnumerator() | Where-Object { $_.Value -eq $type_int } | Select-Object -First 1).Key

    return @{
        boundary_id = $boundary.BoundaryID.ToString()
        name = $boundary.DisplayName
        type = $type_str
        type_id = $type_int
        value = $boundary.Value
        group_count = [int]$boundary.GroupCount
    }
}
