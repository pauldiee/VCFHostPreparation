<#
.SYNOPSIS
    Commissions ESXi hosts into SDDC Manager as part of a VMware Cloud Foundation deployment.

.DESCRIPTION
    Reads the commissioning CSV produced by HostPrep.ps1, prompts for SDDC Manager
    credentials and the target network pool, then submits all hosts to the SDDC Manager
    commission API in a single batch. The script polls the resulting task until it
    completes or times out and prints a per-host result summary.

    Workflow
    --------
      1. Read host list and thumbprints from the HostPrep CSV
      2. Prompt for SDDC Manager FQDN, username and password
      3. Authenticate and retrieve a Bearer token
      4. Detect API version from SDDC Manager
      5. Retrieve available network pools and prompt for selection
      6. Prompt for storage type (per-deployment or per-host override from CSV)
      7. Validate hosts via POST /v1/hosts/validations with per-check output
         (if -ValidateOnly is set: print summary and exit without commissioning)
      8. Commission hosts via POST /v1/hosts
      9. Poll task status until SUCCESSFUL, FAILED, or timeout
     10. Query GET /v1/hosts to retrieve the SDDC Manager host IDs
     11. Print colourised result summary with host IDs
     12. Write results CSV and dark-mode HTML report

    CSV Format (produced by HostPrep.ps1)
    --------------------------------------
    FQDN,Thumbprint,StorageType
    esxi01.vcf.lab,SHA256:abc123...,VSAN
    esxi02.vcf.lab,SHA256:def456...,VSAN

    The StorageType column in the CSV is used as the default. You can override it
    interactively when prompted.

.PARAMETER CsvPath
    Path to the commissioning CSV file produced by HostPrep.ps1.
    If not specified the script will prompt for it.

.PARAMETER SddcManager
    FQDN of the SDDC Manager appliance.
    If not specified the script will prompt for it.

.PARAMETER TimeoutMinutes
    Maximum minutes to wait for the commission task to complete. Default: 30.

.PARAMETER ValidateOnly
    Runs the SDDC Manager pre-commissioning validation (POST /v1/hosts/validations)
    and prints a detailed per-check result for every host -- without commissioning
    anything. Use this to verify readiness before committing to the commission step.
    The ESXi root password is still required as SDDC Manager needs it for validation.

.PARAMETER SkipCertificateCheck
    Ignore TLS certificate errors when connecting to SDDC Manager.
    Useful in lab environments where SDDC Manager uses a self-signed certificate.

.PARAMETER ReportPath
    Path for the HTML commissioning report. Defaults to the script folder with a
    timestamp filename: Commission_<timestamp>_Report.html.

.PARAMETER OutputCsvPath
    Path for the commissioning results CSV. Defaults to the script folder with a
    timestamp filename: Commission_<timestamp>_Results.csv.

.EXAMPLE
    .\Commission-VCFHosts.ps1

.EXAMPLE
    .\Commission-VCFHosts.ps1 -CsvPath "C:\VCF\HostPrep_20260320_Commissioning.csv" -SddcManager sddc-manager.vcf.lab

.EXAMPLE
    .\Commission-VCFHosts.ps1 -ValidateOnly

.NOTES
    Script  : Commission-VCFHosts.ps1
    Version : 2.4.0
    Author  : Paul van Dieen
    Blog    : https://www.hollebollevsan.nl
    Date    : 2026-03-20

    Changelog:
        1.0.0 - Initial release. Reads HostPrep CSV, authenticates to SDDC Manager,
                retrieves network pools, validates and commissions hosts, polls task
                to completion and prints colourised result summary.
        1.1.0 - After task completion, query GET /v1/hosts to retrieve
                SDDC Manager host UUIDs per commissioned host; HostID
                column added to summary table and printed in footer
        1.2.0 - Added -ValidateOnly switch: runs POST /v1/hosts/validations
                and prints a full per-check breakdown per host without
                commissioning; validation results now always printed with
                pass/fail/warn icons regardless of mode
        1.3.0 - Added HTML dark-mode commissioning report and results CSV
                after each run; -ReportPath and -OutputCsvPath parameters
                added; Write-CommissionReport and Write-CommissionCsv
                helper functions added
        1.4.0 - Storage type is now per-host from the CSV (detected by
                HostPrep.ps1); interactive per-host override prompt at
                runtime replaces the single batch-level storage prompt
        1.5.0 - On validation failure: sanitised JSON payload (password
                masked) and full validation response always saved to disk;
                -SavePayload switch saves payload on every run regardless;
                -PayloadPath parameter controls output path; per-check
                output now drills into nested validation checks and prints
                all available error/message properties per check
        1.6.0 - Added Write-ValidationReport: dark-mode HTML report generated
                after -ValidateOnly runs (pass or fail) and after validation
                failure during normal runs; shows per-check results with
                nested check detail, host list, overall status, and SDDC
                Manager metadata; -ValidateReportPath parameter added
        1.7.0 - Fixed Get-SddcManagerVersion: now queries GET /v1/sddc-managers
                (correct endpoint, returns elements[].version) with fallback
                to GET /v1/system/about; resolves "Unknown" version display
        1.8.0 - Fixed validation failure detection: was checking executionStatus
                which SDDC Manager always sets to COMPLETED even when checks
                fail; now checks validationChecks[].resultStatus directly;
                payload and validation response always saved to disk regardless
                of outcome; per-check drilling extended to 3 levels deep and
                covers checkItems property; executionStatus and check counts
                printed for transparency
        1.9.0 - Write-ValidationReport rebuilt: per-host failure summary table
                added at the top showing which hosts have issues and the
                specific failure messages extracted from nested checks; nested
                check rendering refactored into recursive helper functions;
                all HTML reports auto-open in the default browser after writing
        2.0.0 - Fixed failure message extraction for SDDC Manager VCF 9 API
                response structure: error detail is in errorResponse.message
                and host FQDN in errorResponse.context.fqdn, not in flat
                properties; Get-CheckFqdn and Get-CheckMessages helpers updated;
                Collect-HostFailures now matches top-level per-host check
                entries directly; console output also shows errorResponse fields
        2.1.0 - Fixed validation check counts: wrapper check "Validating input
                specification" excluded from pass/fail/warn counts as its
                resultStatus differs from the per-host checks beneath it;
                overall status now taken from top-level resultStatus field
                rather than derived from counts; same fix applied to console
                validationFailed logic; footer branding updated with clickable
                blog link and script version in both HTML reports
        2.2.0 - Removed per-host interactive storage type prompt; storage type
                is now read directly from the CSV without prompting; script
                displays detected values and warns on unrecognised types;
                user edits the CSV StorageType column before running if any
                value needs changing
        2.3.0 - Fixed validation check counts and table: per-host checks are
                nested inside wrapper entries in the SDDC Manager VCF 9 API
                response, not siblings; Get-AllLeafChecks recursive helper
                flattens the structure; counts, HTML check rows, console
                summary, and validationFailed detection all now use flattened
                leaf checks
        2.4.0 - Moved Get-AllLeafChecks to Helper Functions region so it is
                accessible from all call sites; removed duplicate inline
                flatten functions (Get-FlatChecks, Flatten-Checks) that were
                scoped inside other functions and caused "not recognized"
                errors at runtime
#>

[CmdletBinding()]
param (
    [string]$CsvPath,
    [string]$SddcManager,
    [int]$TimeoutMinutes = 30,
    [switch]$ValidateOnly,
    [switch]$SkipCertificateCheck,
    [switch]$SavePayload,

    [string]$ReportPath = [System.IO.Path]::Combine(
        (Split-Path -Parent $MyInvocation.MyCommand.Path),
        "Commission_$(Get-Date -Format 'yyyyMMdd_HHmmss')_Report.html"
    ),

    [string]$OutputCsvPath = [System.IO.Path]::Combine(
        (Split-Path -Parent $MyInvocation.MyCommand.Path),
        "Commission_$(Get-Date -Format 'yyyyMMdd_HHmmss')_Results.csv"
    ),

    [string]$PayloadPath = [System.IO.Path]::Combine(
        (Split-Path -Parent $MyInvocation.MyCommand.Path),
        "Commission_$(Get-Date -Format 'yyyyMMdd_HHmmss')_Payload.json"
    ),

    [string]$ValidateReportPath = [System.IO.Path]::Combine(
        (Split-Path -Parent $MyInvocation.MyCommand.Path),
        "Commission_$(Get-Date -Format 'yyyyMMdd_HHmmss')_ValidationReport.html"
    )
)

#region --- Script Metadata ---

$ScriptMeta = @{
    Name    = "Commission-VCFHosts.ps1"
    Version = "2.4.0"
    Author  = "Paul van Dieen"
    Blog    = "https://www.hollebollevsan.nl"
    Date    = "2026-03-20"
}

#endregion

#region --- Initialisation ---

# Allow self-signed certificates if requested
if ($SkipCertificateCheck) {
    if (-not ([System.Management.Automation.PSTypeName]'TrustAllCerts').Type) {
        Add-Type @"
using System.Net;
using System.Security.Cryptography.X509Certificates;
public class TrustAllCerts : ICertificatePolicy {
    public bool CheckValidationResult(ServicePoint sp, X509Certificate cert,
        WebRequest req, int problem) { return true; }
}
"@
    }
    [System.Net.ServicePointManager]::CertificatePolicy = New-Object TrustAllCerts
}
[System.Net.ServicePointManager]::SecurityProtocol = [System.Net.SecurityProtocolType]::Tls12

# Required for HTML entity encoding in the commissioning report
Add-Type -AssemblyName System.Web

$bannerWidth = 62
Write-Host ""
Write-Host ("=" * $bannerWidth) -ForegroundColor DarkCyan
Write-Host ("  {0,-35} {1}" -f $ScriptMeta.Name, ("v" + $ScriptMeta.Version)) -ForegroundColor Cyan
Write-Host ("  Author : {0}" -f $ScriptMeta.Author) -ForegroundColor Cyan
Write-Host ("  Blog   : {0}" -f $ScriptMeta.Blog) -ForegroundColor Cyan
Write-Host ("  Date   : {0}" -f $ScriptMeta.Date) -ForegroundColor DarkGray
Write-Host ("=" * $bannerWidth) -ForegroundColor DarkCyan
Write-Host ""

if ($ValidateOnly) {
    Write-Host "  *** VALIDATE ONLY MODE -- no hosts will be commissioned ***" -ForegroundColor Yellow
    Write-Host ""
}

#endregion

#region --- Helper Functions ---

function Invoke-SddcManagerApi {
    <#
    .SYNOPSIS
        Wrapper for Invoke-RestMethod calls to SDDC Manager with consistent
        error handling and Bearer token injection.
    #>
    param (
        [string]$Uri,
        [string]$Method = "GET",
        [string]$Token,
        [object]$Body,
        [string]$ContentType = "application/json"
    )

    $headers = @{
        "Authorization" = "Bearer $Token"
        "Content-Type"  = $ContentType
        "Accept"        = "application/json"
    }

    $params = @{
        Uri     = $Uri
        Method  = $Method
        Headers = $headers
    }

    if ($Body) {
        $params["Body"] = ($Body | ConvertTo-Json -Depth 10 -Compress)
    }

    try {
        return Invoke-RestMethod @params -ErrorAction Stop
    } catch {
        $statusCode = $_.Exception.Response.StatusCode.value__
        $detail     = $_.ErrorDetails.Message
        throw "API call failed [$Method $Uri] HTTP $statusCode -- $detail"
    }
}

function Get-SddcManagerToken {
    <#
    .SYNOPSIS
        Authenticates to SDDC Manager and returns a Bearer access token.
    #>
    param (
        [string]$SddcManager,
        [System.Management.Automation.PSCredential]$Credential
    )

    $uri  = "https://$SddcManager/v1/tokens"
    $body = @{
        username = $Credential.UserName
        password = $Credential.GetNetworkCredential().Password
    }

    $headers = @{
        "Content-Type" = "application/json"
        "Accept"       = "application/json"
    }

    try {
        $response = Invoke-RestMethod -Uri $uri -Method POST -Headers $headers `
            -Body ($body | ConvertTo-Json -Compress) -ErrorAction Stop
        return $response.accessToken
    } catch {
        $statusCode = $_.Exception.Response.StatusCode.value__
        throw "Authentication failed (HTTP $statusCode). Check credentials and SDDC Manager address."
    }
}

function Get-SddcManagerVersion {
    <#
    .SYNOPSIS
        Retrieves the SDDC Manager product version.

    .DESCRIPTION
        Tries GET /v1/sddc-managers first (current API, returns elements[].version),
        then falls back to GET /v1/system/about (older API). Returns "Unknown" if
        neither endpoint responds.
    #>
    param ([string]$SddcManager, [string]$Token)

    # Primary: GET /v1/sddc-managers -- returns a singleton list; version is in elements[0]
    try {
        $response = Invoke-SddcManagerApi -Uri "https://$SddcManager/v1/sddc-managers" -Token $Token
        if ($response.elements -and @($response.elements).Count -gt 0) {
            $ver = $response.elements[0].version
            if ($ver) { return $ver }
        }
    } catch { }

    # Fallback: GET /v1/system/about (older VCF versions)
    try {
        $info = Invoke-SddcManagerApi -Uri "https://$SddcManager/v1/system/about" -Token $Token
        if ($info.version) { return $info.version }
    } catch { }

    return "Unknown"
}

function Get-NetworkPools {
    <#
    .SYNOPSIS
        Retrieves all network pools from SDDC Manager.
    #>
    param ([string]$SddcManager, [string]$Token)

    $response = Invoke-SddcManagerApi -Uri "https://$SddcManager/v1/network-pools" -Token $Token
    return $response.elements
}

function Get-CommissionedHostIds {
    <#
    .SYNOPSIS
        Queries SDDC Manager for the assigned host IDs of the commissioned hosts.
        Called after the commission task completes to retrieve the UUIDs assigned
        by SDDC Manager, which are required for subsequent VCF operations.
    #>
    param (
        [string]$SddcManager,
        [string]$Token,
        [string[]]$FQDNs
    )

    # Result hashtable: FQDN -> HostID
    $idMap = @{}
    try {
        $response = Invoke-SddcManagerApi -Uri "https://$SddcManager/v1/hosts" -Token $Token
        $allHosts = $response.elements
        foreach ($fqdn in $FQDNs) {
            $match = $allHosts | Where-Object { $_.fqdn -ieq $fqdn } | Select-Object -First 1
            $idMap[$fqdn] = if ($match) { $match.id } else { "N/A" }
        }
    } catch {
        Write-Host "  WARNING: Could not retrieve host IDs from SDDC Manager: $_" -ForegroundColor Yellow
        foreach ($fqdn in $FQDNs) { $idMap[$fqdn] = "N/A" }
    }
    return $idMap
}

function Get-AllLeafChecks {
    <#
    .SYNOPSIS
        Recursively flattens SDDC Manager validationChecks into a list of
        leaf check objects. In VCF 9 the per-host checks are nested inside
        a top-level wrapper entry rather than being siblings of it.
    #>
    param ([object[]]$Checks)

    $result = [System.Collections.Generic.List[object]]::new()
    foreach ($c in $Checks) {
        $hasNested = $false
        foreach ($np in @("nestedValidationChecks","nestedChecks","checkItems")) {
            if ($c.PSObject.Properties[$np] -and $c.$np -and @($c.$np).Count -gt 0) {
                $hasNested = $true
                foreach ($n in (Get-AllLeafChecks $c.$np)) { $result.Add($n) }
            }
        }
        if (-not $hasNested) { $result.Add($c) }
    }
    return $result
}

function Write-CommissionSummary {
    <#
    .SYNOPSIS
        Prints a colourised per-host commissioning result table.
    #>
    param (
        [System.Collections.Generic.List[PSCustomObject]]$Data
    )

    $columns = [ordered]@{
        FQDN        = 40
        HostID      = 38
        StorageType = 12
        NetworkPool = 24
        Status      = 14
        Detail      = 30
    }

    $divider = "+" + (($columns.Values | ForEach-Object { "-" * ($_ + 2) }) -join "+") + "+"

    Write-Host ""
    Write-Host $divider -ForegroundColor DarkCyan

    $headerLine = "|"
    foreach ($col in $columns.GetEnumerator()) {
        $headerLine += " {0,-$($col.Value)} |" -f $col.Key
    }
    Write-Host $headerLine -ForegroundColor Cyan
    Write-Host $divider -ForegroundColor DarkCyan

    foreach ($row in $Data) {
        Write-Host "|" -ForegroundColor DarkCyan -NoNewline
        foreach ($col in $columns.GetEnumerator()) {
            $val     = $row.($col.Key)
            $display = if ($null -eq $val) { "" } else { "$val" }
            if ($display.Length -gt $col.Value) { $display = $display.Substring(0, $col.Value - 1) + "~" }
            $padded  = " {0,-$($col.Value)} " -f $display

            $color = switch -Wildcard ($col.Key) {
                "Status" {
                    if     ($val -eq "SUCCESSFUL")  { "Green"  }
                    elseif ($val -eq "FAILED")       { "Red"    }
                    elseif ($val -eq "IN_PROGRESS")  { "Cyan"   }
                    elseif ($val -eq "PENDING")      { "Yellow" }
                    else                             { "White"  }
                }
                default { "White" }
            }

            Write-Host $padded -ForegroundColor $color -NoNewline
            Write-Host "|" -ForegroundColor DarkCyan -NoNewline
        }
        Write-Host ""
    }

    Write-Host $divider -ForegroundColor DarkCyan
}
function Write-ValidationReport {
    <#
    .SYNOPSIS
        Generates a dark-themed self-contained HTML validation report.
        Shows per-check results with nested detail AND a per-host failure
        summary so it is immediately clear which hosts failed which checks.
    #>
    param (
        [object]$ValidationStatus,
        [string]$Path,
        [string]$ValidationId,
        [string]$SddcManager,
        [string]$SddcVersion,
        [string]$NetworkPool,
        [string]$ScriptVersion,
        [array]$Hosts
    )

    $generatedAt   = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $passCount     = 0; $failCount = 0; $warnCount = 0

    # Use the top-level resultStatus from SDDC Manager for the overall result.
    # Do not re-derive from counts -- the wrapper check skews the numbers.
    $overallStatus = switch ($ValidationStatus.resultStatus) {
        "FAILED"  { "FAILED"  }
        "WARNING" { "WARNING" }
        default   { "PASSED"  }
    }

    if ($ValidationStatus -and $ValidationStatus.PSObject.Properties["validationChecks"]) {
        # Flatten all nested checks and count only the leaf/per-host entries.
        # Top-level validationChecks may only contain wrapper entries; the real
        # per-host checks live inside nestedValidationChecks.
        $leafChecks = Get-AllLeafChecks $ValidationStatus.validationChecks
        $hostChecks = $leafChecks | Where-Object {
            $_.description -notlike "*input specification*" -and
            $_.description -notlike "*Validating input*"
        }
        $passCount = [int]@($hostChecks | Where-Object { $_.resultStatus -eq "SUCCEEDED" } | Measure-Object).Count
        $failCount = [int]@($hostChecks | Where-Object { $_.resultStatus -eq "FAILED"    } | Measure-Object).Count
        $warnCount = [int]@($hostChecks | Where-Object { $_.resultStatus -eq "WARNING"   } | Measure-Object).Count
    }

    # ── Helper: collect all messages from a check object ──────────────────
    # Checks flat properties first, then errorResponse.message (SDDC Manager v9 structure)
    function Get-CheckMessages ($obj) {
        $list = [System.Collections.Generic.List[string]]::new()
        foreach ($p in @("errorMessage","message","resultMessage")) {
            if ($obj.PSObject.Properties[$p] -and $obj.$p) {
                $list.Add([System.Web.HttpUtility]::HtmlEncode($obj.$p))
            }
        }
        # SDDC Manager VCF 9 nests the message under errorResponse.message
        if ($obj.PSObject.Properties["errorResponse"] -and $obj.errorResponse) {
            if ($obj.errorResponse.PSObject.Properties["message"] -and $obj.errorResponse.message) {
                $list.Add([System.Web.HttpUtility]::HtmlEncode($obj.errorResponse.message))
            }
        }
        return $list
    }

    # ── Helper: extract FQDN from a check object ───────────────────────────
    # Checks flat fqdn/hostname properties, then errorResponse.context.fqdn
    function Get-CheckFqdn ($obj) {
        foreach ($fp in @("fqdn","hostname","hostName","host")) {
            if ($obj.PSObject.Properties[$fp] -and $obj.$fp) { return $obj.$fp }
        }
        # SDDC Manager VCF 9 puts the fqdn under errorResponse.context.fqdn
        if ($obj.PSObject.Properties["errorResponse"] -and $obj.errorResponse) {
            if ($obj.errorResponse.PSObject.Properties["context"] -and $obj.errorResponse.context) {
                foreach ($fp in @("fqdn","hostname","hostName","host")) {
                    if ($obj.errorResponse.context.PSObject.Properties[$fp] -and $obj.errorResponse.context.$fp) {
                        return $obj.errorResponse.context.$fp
                    }
                }
            }
        }
        return $null
    }

    # ── Helper: recursively render nested checks as HTML ──────────────────
    function Render-NestedChecks ($parentObj) {
        $html = ""
        foreach ($np in @("nestedValidationChecks","nestedChecks","validationChecks","checkItems")) {
            if ($parentObj.PSObject.Properties[$np] -and $parentObj.$np) {
                $html += "<ul style='margin:6px 0 0 0;padding-left:16px;list-style:none'>"
                foreach ($n in $parentObj.$np) {
                    $nIcon = switch ($n.resultStatus) {
                        "SUCCEEDED" { "<span style='color:#3fb950'>&#10004;</span>" }
                        "FAILED"    { "<span style='color:#f85149'>&#10008;</span>" }
                        "WARNING"   { "<span style='color:#d29922'>&#9888;</span>"  }
                        default     { "<span style='color:#8b949e'>&#9679;</span>"  }
                    }
                    $nMsgs = Get-CheckMessages $n
                    $nMsgHtml = if ($nMsgs.Count -gt 0) {
                        "<span style='color:#8b949e;font-size:0.78rem'> -- " + ($nMsgs -join "; ") + "</span>"
                    } else { "" }
                    $html += "<li style='padding:2px 0'>$nIcon $([System.Web.HttpUtility]::HtmlEncode($n.description))$nMsgHtml"
                    $html += Render-NestedChecks $n
                    $html += "</li>"
                }
                $html += "</ul>"
                break  # only process the first matching property per level
            }
        }
        return $html
    }

    # ── Build check rows ───────────────────────────────────────────────────
    # Use leaf checks so per-host entries are shown even when nested inside wrapper
    $checkRows = ""
    if ($ValidationStatus -and $ValidationStatus.PSObject.Properties["validationChecks"]) {
        $allChecksForTable = Get-AllLeafChecks $ValidationStatus.validationChecks
        foreach ($check in $allChecksForTable) {
            $rowClass = switch ($check.resultStatus) {
                "SUCCEEDED" { "ok"   }
                "FAILED"    { "fail" }
                "WARNING"   { "warn" }
                default     { ""     }
            }
            $statusDisplay = switch ($check.resultStatus) {
                "SUCCEEDED" { "<span style='color:#3fb950'>&#10004; PASS</span>" }
                "FAILED"    { "<span style='color:#f85149'>&#10008; FAIL</span>" }
                "WARNING"   { "<span style='color:#d29922'>&#9888; WARN</span>"  }
                default     { "<span style='color:#8b949e'>$([System.Web.HttpUtility]::HtmlEncode($check.resultStatus))</span>" }
            }
            $msgs    = Get-CheckMessages $check
            $msgHtml = if ($msgs.Count -gt 0) {
                "<div style='margin-top:4px;color:#8b949e;font-size:0.8rem'>" + ($msgs -join "<br>") + "</div>"
            } else { "" }
            $nested  = Render-NestedChecks $check
            $descCol = [System.Web.HttpUtility]::HtmlEncode($check.description) + $msgHtml + $nested

            $checkRows += "
        <tr class='$rowClass'>
            <td>$statusDisplay</td>
            <td>$descCol</td>
        </tr>"
        }
    }

    # ── Build per-host failure summary ─────────────────────────────────────
    # Walk all checks and nested checks to collect failures keyed by host FQDN.
    # SDDC Manager typically embeds the host FQDN in nested check descriptions
    # or in a dedicated fqdn/hostname property on the nested check object.
    $hostFailureMap = @{}  # FQDN -> list of failure strings
    foreach ($h in $Hosts) { $hostFailureMap[$h.FQDN] = [System.Collections.Generic.List[string]]::new() }

    function Collect-HostFailures ($obj, $depth) {
        if ($depth -gt 4) { return }

        # For VCF 9: top-level validationChecks have one entry per host.
        # The check description is "Validating host <fqdn>" and errorResponse
        # contains context.fqdn + message. Handle these directly first.
        $directFqdn = Get-CheckFqdn $obj
        if (-not $directFqdn) {
            # Try matching description "Validating host <fqdn>"
            foreach ($fqdn in $hostFailureMap.Keys) {
                if ($obj.PSObject.Properties["description"] -and $obj.description -like "*$fqdn*") {
                    $directFqdn = $fqdn; break
                }
            }
        }
        if ($directFqdn -and $hostFailureMap.ContainsKey($directFqdn) -and
            $obj.PSObject.Properties["resultStatus"] -and
            $obj.resultStatus -in @("FAILED","WARNING")) {
            $msgs = Get-CheckMessages $obj
            $detail = if ($msgs.Count -gt 0) { $msgs[0] } else { [System.Web.HttpUtility]::HtmlEncode($obj.description) }
            if ($hostFailureMap[$directFqdn] -notcontains $detail) {
                $hostFailureMap[$directFqdn].Add($detail)
            }
        }

        # Recurse into nested check arrays
        foreach ($np in @("nestedValidationChecks","nestedChecks","validationChecks","checkItems")) {
            if ($obj.PSObject.Properties[$np] -and $obj.$np) {
                foreach ($n in $obj.$np) {
                    Collect-HostFailures $n ($depth + 1)
                }
                break
            }
        }
    }

    if ($ValidationStatus -and $ValidationStatus.PSObject.Properties["validationChecks"]) {
        foreach ($check in $ValidationStatus.validationChecks) {
            Collect-HostFailures $check 0
        }
    }

    # Build per-host rows
    $hostRows = ""
    foreach ($h in $Hosts) {
        $failures = $hostFailureMap[$h.FQDN]
        $hostStatus = if ($failures -and $failures.Count -gt 0) {
            "<span style='color:#f85149'>&#10008; Issues found</span>"
        } else {
            "<span style='color:#3fb950'>&#10004; No issues detected</span>"
        }
        $failureDetail = if ($failures -and $failures.Count -gt 0) {
            "<ul style='margin:4px 0 0 0;padding-left:16px;color:#f85149;font-size:0.8rem'>" +
            ($failures | ForEach-Object { "<li>$_</li>" }) -join "" +
            "</ul>"
        } else { "" }

        $rowClass = if ($failures -and $failures.Count -gt 0) { "fail" } else { "ok" }
        $hostRows += "
        <tr class='$rowClass'>
            <td>$([System.Web.HttpUtility]::HtmlEncode($h.FQDN))</td>
            <td style='font-family:Consolas,monospace;font-size:0.72rem;color:#79c0ff;word-break:break-all'>$([System.Web.HttpUtility]::HtmlEncode($h.Thumbprint))</td>
            <td>$([System.Web.HttpUtility]::HtmlEncode($h.StorageType))</td>
            <td>$hostStatus$failureDetail</td>
        </tr>"
    }

    $overallColor = switch ($overallStatus) {
        "PASSED"  { "#3fb950" }
        "FAILED"  { "#f85149" }
        "WARNING" { "#d29922" }
        default   { "#c9d1d9" }
    }

    $html = @"
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>VCF Validation Report</title>
<style>
  * { box-sizing: border-box; margin: 0; padding: 0; }
  body { font-family: 'Segoe UI', Arial, sans-serif; background: #0d1117; color: #c9d1d9; padding: 32px; }
  header { margin-bottom: 28px; border-bottom: 2px solid #1f6feb; padding-bottom: 16px; }
  header h1 { font-size: 1.6rem; color: #58a6ff; letter-spacing: 0.5px; }
  header p  { font-size: 0.85rem; color: #8b949e; margin-top: 4px; }
  .meta { display: flex; gap: 20px; margin-bottom: 24px; flex-wrap: wrap; }
  .meta-item { background: #161b22; border: 1px solid #30363d; border-radius: 6px; padding: 12px 20px; min-width: 140px; }
  .meta-item .label { font-size: 0.72rem; color: #8b949e; text-transform: uppercase; letter-spacing: 0.5px; }
  .meta-item .value { font-size: 1.1rem; font-weight: 600; color: #c9d1d9; margin-top: 2px; }
  .info-bar { background: #161b22; border: 1px solid #30363d; border-radius: 6px; padding: 12px 20px; margin-bottom: 24px; font-size: 0.83rem; display: flex; gap: 32px; flex-wrap: wrap; }
  .info-bar span { color: #8b949e; }
  .info-bar strong { color: #c9d1d9; }
  h2 { font-size: 1rem; color: #58a6ff; margin: 24px 0 12px; }
  table { width: 100%; border-collapse: collapse; font-size: 0.85rem; background: #161b22; border-radius: 8px; overflow: hidden; border: 1px solid #30363d; margin-bottom: 24px; }
  thead th { background: #1f2937; color: #58a6ff; padding: 10px 14px; text-align: left; font-weight: 600; letter-spacing: 0.4px; border-bottom: 2px solid #1f6feb; }
  tbody tr { border-bottom: 1px solid #21262d; }
  tbody tr:hover { background: #1c2128; }
  tbody tr:last-child { border-bottom: none; }
  td { padding: 10px 14px; vertical-align: top; }
  tr.ok   td:first-child { border-left: 3px solid #3fb950; }
  tr.fail td:first-child { border-left: 3px solid #f85149; }
  tr.warn td:first-child { border-left: 3px solid #d29922; }
  .note { font-size: 0.8rem; color: #8b949e; background: #161b22; border: 1px solid #30363d; border-radius: 6px; padding: 12px 16px; margin-top: 8px; }
  footer { margin-top: 28px; font-size: 0.75rem; color: #6e7681; text-align: center; }
</style>
</head>
<body>

<header>
  <h1>&#128203; VCF Host Commissioning Validation Report</h1>
  <p>Generated by Commission-VCFHosts.ps1 v$ScriptVersion &bull; $generatedAt</p>
</header>

<div class="meta">
  <div class="meta-item">
    <div class="label">Overall</div>
    <div class="value" style="color:$overallColor">$overallStatus</div>
  </div>
  <div class="meta-item">
    <div class="label">Passed</div>
    <div class="value" style="color:#3fb950">$passCount</div>
  </div>
  <div class="meta-item">
    <div class="label">Warnings</div>
    <div class="value" style="color:#d29922">$warnCount</div>
  </div>
  <div class="meta-item">
    <div class="label">Failed</div>
    <div class="value" style="color:#f85149">$failCount</div>
  </div>
</div>

<div class="info-bar">
  <div><span>SDDC Manager: </span><strong>$([System.Web.HttpUtility]::HtmlEncode($SddcManager))</strong></div>
  <div><span>Version: </span><strong>$([System.Web.HttpUtility]::HtmlEncode($SddcVersion))</strong></div>
  <div><span>Network Pool: </span><strong>$([System.Web.HttpUtility]::HtmlEncode($NetworkPool))</strong></div>
  <div><span>Validation ID: </span><strong><code style='font-size:0.8rem;color:#79c0ff'>$([System.Web.HttpUtility]::HtmlEncode($ValidationId))</code></strong></div>
</div>

<h2>Per-Host Summary</h2>
<table>
  <thead>
    <tr>
      <th>Host FQDN</th>
      <th>Thumbprint</th>
      <th>Storage Type</th>
      <th>Issues</th>
    </tr>
  </thead>
  <tbody>
    $hostRows
  </tbody>
</table>

<h2>Validation Checks</h2>
<table>
  <thead>
    <tr>
      <th style="width:110px">Result</th>
      <th>Check</th>
    </tr>
  </thead>
  <tbody>
    $checkRows
  </tbody>
</table>

<div class="note">
  No hosts were commissioned. This report reflects the pre-commissioning validation
  only. $(if ($overallStatus -eq 'PASSED') { 'All checks passed -- run without -ValidateOnly to commission.' } else { 'Fix the failed checks above before commissioning.' })
</div>

<footer>Commission-VCFHosts.ps1 v$ScriptVersion &bull; <a href="https://www.hollebollevsan.nl" style="color:#58a6ff;text-decoration:none">Paul van Dieen &bull; HolleBollevSAN</a></footer>

</body>
</html>
"@

    $html | Out-File -FilePath $Path -Encoding UTF8
    Write-Host ("  Validation report written to: {0}" -f $Path) -ForegroundColor Cyan
    Start-Process $Path
}



function Write-CommissionCsv {
    <#
    .SYNOPSIS
        Exports commissioning results to a CSV file.
    #>
    param (
        [System.Collections.Generic.List[PSCustomObject]]$Data,
        [string]$Path,
        [string]$TaskId,
        [string]$SddcManager
    )

    $rows = $Data | Select-Object `
        @{ Name = "FQDN";        Expression = { $_.FQDN } },
        @{ Name = "HostID";      Expression = { $_.HostID } },
        @{ Name = "StorageType"; Expression = { $_.StorageType } },
        @{ Name = "NetworkPool"; Expression = { $_.NetworkPool } },
        @{ Name = "Status";      Expression = { $_.Status } },
        @{ Name = "Detail";      Expression = { $_.Detail } },
        @{ Name = "TaskID";      Expression = { $TaskId } },
        @{ Name = "SddcManager"; Expression = { $SddcManager } },
        @{ Name = "Timestamp";   Expression = { (Get-Date -Format "yyyy-MM-dd HH:mm:ss") } }

    $rows | Export-Csv -Path $Path -NoTypeInformation -Encoding UTF8
    Write-Host ("  Results CSV written to: {0}" -f $Path) -ForegroundColor Cyan
}

function Write-CommissionReport {
    <#
    .SYNOPSIS
        Generates a dark-themed self-contained HTML commissioning report.
    #>
    param (
        [System.Collections.Generic.List[PSCustomObject]]$Data,
        [string]$Path,
        [string]$TaskId,
        [string]$SddcManager,
        [string]$SddcVersion,
        [string]$NetworkPool,
        [string]$ScriptVersion
    )

    $generatedAt   = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $totalCount    = [int]$Data.Count
    $successCount  = [int]($Data | Where-Object { $_.Status -eq "SUCCESSFUL" } | Measure-Object).Count
    $failCount     = [int]($Data | Where-Object { $_.Status -eq "FAILED"     } | Measure-Object).Count
    $otherCount    = $totalCount - $successCount - $failCount

    $rows = foreach ($row in $Data) {
        $rowClass = switch ($row.Status) {
            "SUCCESSFUL" { "ok"   }
            "FAILED"     { "fail" }
            default      { "warn" }
        }
        $statusDisplay = switch ($row.Status) {
            "SUCCESSFUL" { "<span style='color:#3fb950'>&#10004; Successful</span>" }
            "FAILED"     { "<span style='color:#f85149'>&#10008; Failed</span>"     }
            default      { "<span style='color:#d29922'>&#9888; $([System.Web.HttpUtility]::HtmlEncode($row.Status))</span>" }
        }
        $hostIdDisplay = if ($row.HostID -eq "N/A") {
            "<span style='color:#6e7681;font-style:italic'>N/A</span>"
        } else {
            "<code style='font-size:0.75rem;color:#79c0ff'>$([System.Web.HttpUtility]::HtmlEncode($row.HostID))</code>"
        }
        "
        <tr class='$rowClass'>
            <td>$([System.Web.HttpUtility]::HtmlEncode($row.FQDN))</td>
            <td>$hostIdDisplay</td>
            <td>$([System.Web.HttpUtility]::HtmlEncode($row.StorageType))</td>
            <td>$([System.Web.HttpUtility]::HtmlEncode($row.NetworkPool))</td>
            <td>$statusDisplay</td>
            <td>$([System.Web.HttpUtility]::HtmlEncode($row.Detail))</td>
        </tr>"
    }

    $html = @"
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>VCF Commissioning Report</title>
<style>
  * { box-sizing: border-box; margin: 0; padding: 0; }
  body { font-family: 'Segoe UI', Arial, sans-serif; background: #0d1117; color: #c9d1d9; padding: 32px; }
  header { margin-bottom: 28px; border-bottom: 2px solid #1f6feb; padding-bottom: 16px; }
  header h1 { font-size: 1.6rem; color: #58a6ff; letter-spacing: 0.5px; }
  header p  { font-size: 0.85rem; color: #8b949e; margin-top: 4px; }
  .meta { display: flex; gap: 20px; margin-bottom: 24px; flex-wrap: wrap; }
  .meta-item { background: #161b22; border: 1px solid #30363d; border-radius: 6px; padding: 12px 20px; min-width: 140px; }
  .meta-item .label { font-size: 0.72rem; color: #8b949e; text-transform: uppercase; letter-spacing: 0.5px; }
  .meta-item .value { font-size: 1.1rem; font-weight: 600; color: #c9d1d9; margin-top: 2px; }
  .info-bar { background: #161b22; border: 1px solid #30363d; border-radius: 6px; padding: 12px 20px; margin-bottom: 24px; font-size: 0.83rem; display: flex; gap: 32px; flex-wrap: wrap; }
  .info-bar span { color: #8b949e; }
  .info-bar strong { color: #c9d1d9; }
  table { width: 100%; border-collapse: collapse; font-size: 0.85rem; background: #161b22; border-radius: 8px; overflow: hidden; border: 1px solid #30363d; }
  thead th { background: #1f2937; color: #58a6ff; padding: 10px 14px; text-align: left; font-weight: 600; letter-spacing: 0.4px; white-space: nowrap; border-bottom: 2px solid #1f6feb; }
  tbody tr { border-bottom: 1px solid #21262d; transition: background 0.15s; }
  tbody tr:hover { background: #1c2128; }
  tbody tr:last-child { border-bottom: none; }
  td { padding: 10px 14px; vertical-align: middle; }
  tr.ok   td:first-child { border-left: 3px solid #3fb950; }
  tr.fail td:first-child { border-left: 3px solid #f85149; }
  tr.warn td:first-child { border-left: 3px solid #d29922; }
  .note { margin-top: 20px; font-size: 0.8rem; color: #8b949e; background: #161b22; border: 1px solid #30363d; border-radius: 6px; padding: 12px 16px; }
  .note strong { color: #c9d1d9; }
  footer { margin-top: 28px; font-size: 0.75rem; color: #6e7681; text-align: center; }
</style>
</head>
<body>

<header>
  <h1>&#9989; VCF Host Commissioning Report</h1>
  <p>Generated by Commission-VCFHosts.ps1 v$ScriptVersion &bull; $generatedAt</p>
</header>

<div class="meta">
  <div class="meta-item">
    <div class="label">Hosts</div>
    <div class="value">$totalCount</div>
  </div>
  <div class="meta-item">
    <div class="label">Successful</div>
    <div class="value" style="color:#3fb950">$successCount</div>
  </div>
  <div class="meta-item">
    <div class="label">Failed</div>
    <div class="value" style="color:#f85149">$failCount</div>
  </div>
  <div class="meta-item">
    <div class="label">Other</div>
    <div class="value" style="color:#d29922">$otherCount</div>
  </div>
</div>

<div class="info-bar">
  <div><span>SDDC Manager: </span><strong>$([System.Web.HttpUtility]::HtmlEncode($SddcManager))</strong></div>
  <div><span>Version: </span><strong>$([System.Web.HttpUtility]::HtmlEncode($SddcVersion))</strong></div>
  <div><span>Network Pool: </span><strong>$([System.Web.HttpUtility]::HtmlEncode($NetworkPool))</strong></div>
  <div><span>Task ID: </span><strong><code style='font-size:0.8rem;color:#79c0ff'>$([System.Web.HttpUtility]::HtmlEncode($TaskId))</code></strong></div>
</div>

<table>
  <thead>
    <tr>
      <th>Host FQDN</th>
      <th>SDDC Manager Host ID</th>
      <th>Storage Type</th>
      <th>Network Pool</th>
      <th>Status</th>
      <th>Detail</th>
    </tr>
  </thead>
  <tbody>
    $($rows -join "`n")
  </tbody>
</table>

<div class="note">
  <strong>Note:</strong> The SDDC Manager Host ID is the UUID assigned to each host after
  successful commissioning. These IDs are required for subsequent VCF operations such as
  workload domain creation and cluster expansion.
</div>

<footer>Commission-VCFHosts.ps1 v$ScriptVersion &bull; <a href="https://www.hollebollevsan.nl" style="color:#58a6ff;text-decoration:none">Paul van Dieen &bull; HolleBollevSAN</a></footer>

</body>
</html>
"@

    $html | Out-File -FilePath $Path -Encoding UTF8
    Write-Host ("  HTML report written to: {0}" -f $Path) -ForegroundColor Cyan
}


#endregion

#region --- CSV Input ---

if (-not $CsvPath) {
    Write-Host "  Enter full path to the HostPrep commissioning CSV file." -ForegroundColor Cyan
    $raw = (Read-Host "  CSV path").Trim().Trim('"').Trim("'")
    $CsvPath = $raw
}

if (-not (Test-Path -LiteralPath $CsvPath -PathType Leaf)) {
    Write-Host "  File not found: '$CsvPath'" -ForegroundColor Red
    exit 1
}

$hosts = Import-Csv -LiteralPath $CsvPath

if (-not $hosts -or @($hosts).Count -eq 0) {
    Write-Host "  CSV is empty. Nothing to commission." -ForegroundColor Red
    exit 1
}

Write-Host ("  Loaded {0} host(s) from: {1}" -f @($hosts).Count, $CsvPath) -ForegroundColor Cyan
foreach ($h in $hosts) {
    Write-Host ("    {0,-40} {1}" -f $h.FQDN, $h.Thumbprint) -ForegroundColor DarkGray
}
Write-Host ""

#endregion

#region --- SDDC Manager Connection ---

if (-not $SddcManager) {
    $SddcManager = (Read-Host "  SDDC Manager FQDN").Trim()
}

Write-Host ""
Write-Host "  Authenticating to SDDC Manager: $SddcManager" -ForegroundColor Cyan

$sddcUser     = Read-Host "  SDDC Manager username (e.g. administrator@vsphere.local)"
$sddcPassword = Read-Host "  SDDC Manager password" -AsSecureString
$sddcCred     = New-Object System.Management.Automation.PSCredential($sddcUser, $sddcPassword)

try {
    $token = Get-SddcManagerToken -SddcManager $SddcManager -Credential $sddcCred
    Write-Host "  Authenticated successfully." -ForegroundColor Green
} catch {
    Write-Host "  ERROR: $_" -ForegroundColor Red
    exit 1
}

$sddcVersion = Get-SddcManagerVersion -SddcManager $SddcManager -Token $token
Write-Host ("  SDDC Manager version: {0}" -f $sddcVersion) -ForegroundColor DarkGray
Write-Host ""

#endregion

#region --- Network Pool Selection ---

Write-Host "  Retrieving network pools..." -ForegroundColor Cyan
try {
    $networkPools = Get-NetworkPools -SddcManager $SddcManager -Token $token
} catch {
    Write-Host "  ERROR retrieving network pools: $_" -ForegroundColor Red
    exit 1
}

if (-not $networkPools -or @($networkPools).Count -eq 0) {
    Write-Host "  No network pools found in SDDC Manager." -ForegroundColor Red
    exit 1
}

Write-Host ""
Write-Host "  Available network pools:" -ForegroundColor Cyan
for ($i = 0; $i -lt @($networkPools).Count; $i++) {
    Write-Host ("    [{0}] {1}  (ID: {2})" -f ($i + 1), $networkPools[$i].name, $networkPools[$i].id) -ForegroundColor White
}
Write-Host ""

$poolIndex = $null
while ($null -eq $poolIndex) {
    $input = Read-Host "  Select network pool number"
    if ($input -match '^\d+$') {
        $idx = [int]$input - 1
        if ($idx -ge 0 -and $idx -lt @($networkPools).Count) {
            $poolIndex = $idx
        } else {
            Write-Host "  Please enter a number between 1 and $(@($networkPools).Count)." -ForegroundColor Yellow
        }
    } else {
        Write-Host "  Please enter a valid number." -ForegroundColor Yellow
    }
}

$selectedPool = $networkPools[$poolIndex]
Write-Host ("  Selected: {0}  (ID: {1})" -f $selectedPool.name, $selectedPool.id) -ForegroundColor Green
Write-Host ""

#endregion

#region --- Storage Type ---

# Storage type is read directly from the CSV -- detected per host by HostPrep.ps1.
# VMFS_FC and NFS are auto-detected. Everything else defaults to VSAN.
# If any host needs VSAN_ESA or VVOL, edit the StorageType column in the CSV
# before running this script.
$validStorageTypes = @("VSAN","VSAN_ESA","NFS","VMFS_FC","VVOL")

Write-Host "  Storage types from CSV:" -ForegroundColor Cyan
Write-Host "  (To change a value, edit the StorageType column in the CSV and re-run)" -ForegroundColor DarkGray
Write-Host "  Valid values: VSAN, VSAN_ESA, NFS, VMFS_FC, VVOL" -ForegroundColor DarkGray
Write-Host ""

$hostStorageMap = @{}
$storageWarnings = $false
foreach ($h in $hosts) {
    $storageType = if ($h.StorageType -and $h.StorageType -ne "") { $h.StorageType.ToUpper() } else { "VSAN" }
    $hostStorageMap[$h.FQDN] = $storageType

    $typeColor = if ($storageType -notin $validStorageTypes) { "Yellow" } else { "DarkGray" }
    if ($storageType -notin $validStorageTypes) { $storageWarnings = $true }
    Write-Host ("    {0,-42} {1}" -f $h.FQDN, $storageType) -ForegroundColor $typeColor
}

if ($storageWarnings) {
    Write-Host ""
    Write-Host "  WARNING: One or more hosts have an unrecognised storage type." -ForegroundColor Yellow
    Write-Host "  Edit the CSV and correct the StorageType column before proceeding." -ForegroundColor Yellow
}
Write-Host ""

#endregion

#region --- ESXi Root Password for Commissioning ---

Write-Host "  SDDC Manager requires the ESXi root password to commission hosts." -ForegroundColor Cyan
$esxiPassword = Read-Host "  ESXi root password" -AsSecureString
$esxiPlain    = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto(
                    [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($esxiPassword))

#endregion

#region --- Build Host Payload ---

$hostPayload = foreach ($h in $hosts) {
    @{
        fqdn            = $h.FQDN
        username        = "root"
        password        = $esxiPlain
        storageType     = $hostStorageMap[$h.FQDN]
        networkPoolId   = $selectedPool.id
        networkPoolName = $selectedPool.name
    }
}

# Save sanitised payload to disk before clearing the password.
# The password field is masked -- the file is safe to share for debugging.
$sanitisedPayload = $hostPayload | ForEach-Object {
    $copy = $_.Clone()
    $copy["password"] = "********"
    $copy
}
$payloadJson = $sanitisedPayload | ConvertTo-Json -Depth 10

if ($SavePayload) {
    $payloadJson | Out-File -FilePath $PayloadPath -Encoding UTF8
    Write-Host ("  Payload saved to: {0}" -f $PayloadPath) -ForegroundColor DarkGray
}

# Clear plaintext password from memory immediately after payload is built
$esxiPlain = [string]::new('*', 16)
Remove-Variable esxiPlain -ErrorAction SilentlyContinue

#endregion

#region --- Validation ---

Write-Host "  Validating hosts with SDDC Manager..." -ForegroundColor Cyan
$validationUri = "https://$SddcManager/v1/hosts/validations"
$validationPassed = $false

try {
    $validation = Invoke-SddcManagerApi -Uri $validationUri -Method POST `
        -Token $token -Body $hostPayload
    Write-Host "  Validation submitted. Validation ID: $($validation.id)" -ForegroundColor DarkGray

    # Poll validation until complete
    $valDeadline = (Get-Date).AddMinutes(5)
    $valStatus   = $null
    while ((Get-Date) -lt $valDeadline) {
        Start-Sleep -Seconds 5
        $valStatus = Invoke-SddcManagerApi `
            -Uri "https://$SddcManager/v1/hosts/validations/$($validation.id)" `
            -Token $token
        if ($valStatus.executionStatus -in @("COMPLETED", "FAILED")) { break }
        Write-Host "  Validation in progress..." -ForegroundColor DarkGray
    }

    # Always save raw validation response and payload for inspection
    $valJsonPath = $PayloadPath -replace '_Payload\.json$', '_ValidationResponse.json'
    $valStatus | ConvertTo-Json -Depth 10 | Out-File -FilePath $valJsonPath -Encoding UTF8
    if (-not $SavePayload) {
        $payloadJson | Out-File -FilePath $PayloadPath -Encoding UTF8
    }
    Write-Host ("  Payload saved to     : {0}" -f $PayloadPath) -ForegroundColor DarkGray
    Write-Host ("  Validation response  : {0}" -f $valJsonPath) -ForegroundColor DarkGray
    Write-Host ""

    # Determine actual failure from individual check results, NOT executionStatus.
    # SDDC Manager returns executionStatus="COMPLETED" even when checks fail --
    # the real failure state is in validationChecks[].resultStatus.
    # Flatten nested checks and exclude wrappers for accurate failure detection
    $hostLevelChecks = Get-AllLeafChecks $valStatus.validationChecks | Where-Object {
        $_.description -notlike "*input specification*" -and
        $_.description -notlike "*Validating input*"
    }
    $checksFailed  = @($hostLevelChecks | Where-Object { $_.resultStatus -eq "FAILED"  })
    $checksWarned  = @($hostLevelChecks | Where-Object { $_.resultStatus -eq "WARNING" })
    # Also honour the top-level resultStatus from SDDC Manager
    $validationFailed = ($checksFailed.Count -gt 0) -or ($valStatus.resultStatus -eq "FAILED")

    # Print full per-check breakdown
    Write-Host "  Validation results:" -ForegroundColor Cyan
    if ($valStatus -and $valStatus.PSObject.Properties["validationChecks"]) {
        foreach ($check in $valStatus.validationChecks) {
            $checkColor = switch ($check.resultStatus) {
                "SUCCEEDED" { "Green"    }
                "FAILED"    { "Red"      }
                "WARNING"   { "Yellow"   }
                default     { "DarkGray" }
            }
            $icon = switch ($check.resultStatus) {
                "SUCCEEDED" { "[PASS]" }
                "FAILED"    { "[FAIL]" }
                "WARNING"   { "[WARN]" }
                default     { "[INFO]" }
            }
            Write-Host ("    {0} {1}" -f $icon, $check.description) -ForegroundColor $checkColor

            # Print all available message properties on the check
            foreach ($msgProp in @("errorMessage","message","resultMessage")) {
                if ($check.PSObject.Properties[$msgProp] -and $check.$msgProp) {
                    Write-Host ("           {0}: {1}" -f $msgProp, $check.$msgProp) -ForegroundColor DarkGray
                }
            }
            # VCF 9: error detail is under errorResponse.message, FQDN under errorResponse.context.fqdn
            if ($check.PSObject.Properties["errorResponse"] -and $check.errorResponse) {
                if ($check.errorResponse.PSObject.Properties["message"] -and $check.errorResponse.message) {
                    Write-Host ("           errorResponse.message: {0}" -f $check.errorResponse.message) -ForegroundColor Red
                }
                if ($check.errorResponse.PSObject.Properties["context"] -and $check.errorResponse.context) {
                    foreach ($fp in @("fqdn","hostname","hostName")) {
                        if ($check.errorResponse.context.PSObject.Properties[$fp] -and $check.errorResponse.context.$fp) {
                            Write-Host ("           errorResponse.context.{0}: {1}" -f $fp, $check.errorResponse.context.$fp) -ForegroundColor DarkGray
                            break
                        }
                    }
                }
            }

            # Drill into nested checks -- SDDC Manager nests per-host detail here
            foreach ($nestedProp in @("nestedValidationChecks","nestedChecks","validationChecks","checkItems")) {
                if ($check.PSObject.Properties[$nestedProp] -and $check.$nestedProp) {
                    foreach ($nested in $check.$nestedProp) {
                        $nestedColor = switch ($nested.resultStatus) {
                            "FAILED"    { "Red"    }
                            "WARNING"   { "Yellow" }
                            "SUCCEEDED" { "Green"  }
                            default     { "DarkGray" }
                        }
                        $nestedIcon = switch ($nested.resultStatus) {
                            "FAILED"    { "[FAIL]" }
                            "WARNING"   { "[WARN]" }
                            "SUCCEEDED" { "[PASS]" }
                            default     { "[INFO]" }
                        }
                        Write-Host ("      {0} {1}" -f $nestedIcon, $nested.description) -ForegroundColor $nestedColor
                        foreach ($msgProp in @("errorMessage","message","resultMessage")) {
                            if ($nested.PSObject.Properties[$msgProp] -and $nested.$msgProp) {
                                Write-Host ("             {0}: {1}" -f $msgProp, $nested.$msgProp) -ForegroundColor DarkGray
                            }
                        }
                        if ($nested.PSObject.Properties["errorResponse"] -and $nested.errorResponse) {
                            if ($nested.errorResponse.PSObject.Properties["message"] -and $nested.errorResponse.message) {
                                Write-Host ("             errorResponse.message: {0}" -f $nested.errorResponse.message) -ForegroundColor Red
                            }
                        }
                        # One more level deep -- some SDDC Manager versions nest 3 levels
                        foreach ($deepProp in @("nestedValidationChecks","nestedChecks","checkItems")) {
                            if ($nested.PSObject.Properties[$deepProp] -and $nested.$deepProp) {
                                foreach ($deep in $nested.$deepProp) {
                                    $deepColor = if ($deep.resultStatus -eq "FAILED") { "Red" } elseif ($deep.resultStatus -eq "WARNING") { "Yellow" } else { "DarkGray" }
                                    $deepIcon  = if ($deep.resultStatus -eq "FAILED") { "[FAIL]" } elseif ($deep.resultStatus -eq "WARNING") { "[WARN]" } else { "[INFO]" }
                                    Write-Host ("         {0} {1}" -f $deepIcon, $deep.description) -ForegroundColor $deepColor
                                    foreach ($msgProp in @("errorMessage","message","resultMessage")) {
                                        if ($deep.PSObject.Properties[$msgProp] -and $deep.$msgProp) {
                                            Write-Host ("                {0}: {1}" -f $msgProp, $deep.$msgProp) -ForegroundColor DarkGray
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }
    Write-Host ""
    Write-Host ("  executionStatus : {0}  (checks failed: {1}  warnings: {2})" -f $valStatus.executionStatus, $checksFailed.Count, $checksWarned.Count) -ForegroundColor DarkGray
    Write-Host ("  Validation ID   : {0}" -f $validation.id) -ForegroundColor DarkGray
    Write-Host ""

    if ($validationFailed) {
        Write-Host "  Validation FAILED -- $($checksFailed.Count) check(s) failed. Fix the errors above before commissioning." -ForegroundColor Red
        Write-ValidationReport `
            -ValidationStatus $valStatus `
            -Path             $ValidateReportPath `
            -ValidationId     $validation.id `
            -SddcManager      $SddcManager `
            -SddcVersion      $sddcVersion `
            -NetworkPool      $selectedPool.name `
            -ScriptVersion    $ScriptMeta.Version `
            -Hosts            @($hosts)
        if ($ValidateOnly) {
            Write-Host ("=" * 62) -ForegroundColor DarkCyan
            Write-Host ""
            exit 1
        }
        exit 1
    }

    $validationPassed = $true
    Write-Host "  Validation passed." -ForegroundColor Green
    Write-Host ""

    # In ValidateOnly mode, print summary and exit without commissioning
    if ($ValidateOnly) {
        $passCount = 0; $failCount = 0; $warnCount = 0
        if ($valStatus -and $valStatus.PSObject.Properties["validationChecks"]) {
            # Flatten nested checks and exclude wrappers -- mirrors Write-ValidationReport logic
            $hostChecks = Get-AllLeafChecks $valStatus.validationChecks | Where-Object {
                $_.description -notlike "*input specification*" -and
                $_.description -notlike "*Validating input*"
            }
            $passCount = @($hostChecks | Where-Object { $_.resultStatus -eq "SUCCEEDED" }).Count
            $failCount = @($hostChecks | Where-Object { $_.resultStatus -eq "FAILED"    }).Count
            $warnCount = @($hostChecks | Where-Object { $_.resultStatus -eq "WARNING"   }).Count
        }
        Write-Host ("=" * 62) -ForegroundColor DarkCyan
        Write-Host "  VALIDATION SUMMARY" -ForegroundColor Cyan
        Write-Host ("=" * 62) -ForegroundColor DarkCyan
        Write-Host ""
        Write-Host ("  Hosts checked  : {0}" -f @($hosts).Count)  -ForegroundColor White
        Write-Host ("  Checks passed  : {0}" -f $passCount)        -ForegroundColor Green
        Write-Host ("  Checks warned  : {0}" -f $warnCount)        -ForegroundColor $(if ($warnCount -gt 0) { "Yellow" } else { "DarkGray" })
        Write-Host ("  Checks failed  : {0}" -f $failCount)        -ForegroundColor $(if ($failCount -gt 0) { "Red" } else { "DarkGray" })
        Write-Host ""
        Write-Host "  No hosts were commissioned. Run without -ValidateOnly to proceed." -ForegroundColor DarkGray
        Write-Host ""
        Write-ValidationReport `
            -ValidationStatus $valStatus `
            -Path             $ValidateReportPath `
            -ValidationId     $validation.id `
            -SddcManager      $SddcManager `
            -SddcVersion      $sddcVersion `
            -NetworkPool      $selectedPool.name `
            -ScriptVersion    $ScriptMeta.Version `
            -Hosts            @($hosts)
        Write-Host ("=" * 62) -ForegroundColor DarkCyan
        Write-Host ""
        exit 0
    }

} catch {
    if ($ValidateOnly) {
        Write-Host "  ERROR: Validation endpoint unavailable: $_" -ForegroundColor Red
        exit 1
    }
    Write-Host "  WARNING: Validation endpoint unavailable ($_). Proceeding without pre-validation." -ForegroundColor Yellow
    Write-Host ""
}

#endregion

#region --- Commission ---

Write-Host ("  Commissioning {0} host(s) into network pool '{1}'..." -f @($hosts).Count, $selectedPool.name) -ForegroundColor Cyan

$commissionUri = "https://$SddcManager/v1/hosts"

try {
    $task = Invoke-SddcManagerApi -Uri $commissionUri -Method POST `
        -Token $token -Body $hostPayload
    Write-Host ("  Commission task submitted. Task ID: {0}" -f $task.id) -ForegroundColor Green
} catch {
    Write-Host "  ERROR submitting commission task: $_" -ForegroundColor Red
    exit 1
}

#endregion

#region --- Poll Task ---

Write-Host ""
Write-Host "  Polling task status (timeout: $TimeoutMinutes minutes)..." -ForegroundColor Cyan

$taskUri  = "https://$SddcManager/v1/tasks/$($task.id)"
$deadline = (Get-Date).AddMinutes($TimeoutMinutes)
$taskDone = $false

while ((Get-Date) -lt $deadline) {
    Start-Sleep -Seconds 15

    try {
        $taskStatus = Invoke-SddcManagerApi -Uri $taskUri -Token $token
    } catch {
        Write-Host "  WARNING: Could not poll task: $_" -ForegroundColor Yellow
        continue
    }

    $status    = $taskStatus.status
    $pct       = if ($taskStatus.PSObject.Properties["completionPercentage"]) { $taskStatus.completionPercentage } else { "--" }
    $timestamp = Get-Date -Format "HH:mm:ss"

    $statusColor = switch ($status) {
        "SUCCESSFUL"  { "Green"  }
        "FAILED"      { "Red"    }
        "IN_PROGRESS" { "Cyan"   }
        default       { "Yellow" }
    }

    Write-Host ("  [{0}] Status: " -f $timestamp) -NoNewline -ForegroundColor DarkGray
    Write-Host ("{0,-15}" -f $status) -NoNewline -ForegroundColor $statusColor
    Write-Host ("  Progress: {0}%" -f $pct) -ForegroundColor DarkGray

    if ($status -in @("SUCCESSFUL", "FAILED", "CANCELLED")) {
        $taskDone = $true
        break
    }
}

Write-Host ""

if (-not $taskDone) {
    Write-Host ("  Timed out after {0} minutes. Task may still be running." -f $TimeoutMinutes) -ForegroundColor Yellow
    Write-Host ("  Check SDDC Manager or VCF Operations for task ID: {0}" -f $task.id) -ForegroundColor Yellow
}

#endregion

#region --- Summary ---

Write-Host ""
Write-Host ("=" * 62) -ForegroundColor DarkCyan
Write-Host "  COMMISSIONING SUMMARY" -ForegroundColor Cyan
Write-Host ("=" * 62) -ForegroundColor DarkCyan

# Build per-host result rows
# If task subtasks are available use them, otherwise show overall task status for all hosts
$summaryRows = [System.Collections.Generic.List[PSCustomObject]]::new()

$subTasks = if ($taskStatus -and $taskStatus.PSObject.Properties["subTasks"]) { $taskStatus.subTasks } else { $null }

# Retrieve SDDC Manager host IDs for successfully commissioned hosts
Write-Host "  Retrieving host IDs from SDDC Manager..." -ForegroundColor Cyan
$hostIdMap = Get-CommissionedHostIds -SddcManager $SddcManager -Token $token `
    -FQDNs @($hosts | Select-Object -ExpandProperty FQDN)

foreach ($h in $hosts) {
    $hostStatus = $taskStatus.status
    $detail     = ""

    if ($subTasks) {
        $sub = $subTasks | Where-Object { $_.PSObject.Properties["name"] -and $_.name -like "*$($h.FQDN)*" } | Select-Object -First 1
        if ($sub) {
            $hostStatus = $sub.status
            $detail     = if ($sub.PSObject.Properties["description"]) { $sub.description } else { "" }
        }
    }

    $summaryRows.Add([PSCustomObject]@{
        FQDN        = $h.FQDN
        HostID      = $hostIdMap[$h.FQDN]
        StorageType = $hostStorageMap[$h.FQDN]
        NetworkPool = $selectedPool.name
        Status      = $hostStatus
        Detail      = $detail
    })
}

Write-CommissionSummary -Data $summaryRows

$successCount = @($summaryRows | Where-Object { $_.Status -eq "SUCCESSFUL" }).Count
$failCount    = @($summaryRows | Where-Object { $_.Status -eq "FAILED" }).Count

Write-Host ""
Write-Host ("  Successful : {0}" -f $successCount) -ForegroundColor Green
Write-Host ("  Failed     : {0}" -f $failCount)    -ForegroundColor $(if ($failCount -gt 0) { "Red" } else { "DarkGray" })
Write-Host ("  Task ID    : {0}" -f $task.id)      -ForegroundColor DarkGray
Write-Host ("  SDDC Mgr   : https://{0}" -f $SddcManager) -ForegroundColor DarkGray
Write-Host ""

# Print host ID list for easy reference
Write-Host "  Host IDs assigned by SDDC Manager:" -ForegroundColor Cyan
foreach ($row in $summaryRows) {
    $idColor = if ($row.HostID -eq "N/A") { "Yellow" } else { "Green" }
    Write-Host ("    {0,-42} {1}" -f $row.FQDN, $row.HostID) -ForegroundColor $idColor
}

Write-Host ""
Write-Host ("=" * 62) -ForegroundColor DarkCyan
Write-Host ""

# Write results CSV
Write-CommissionCsv -Data $summaryRows -Path $OutputCsvPath `
    -TaskId $task.id -SddcManager $SddcManager

# Write HTML report
Write-CommissionReport -Data $summaryRows -Path $ReportPath `
    -TaskId      $task.id `
    -SddcManager $SddcManager `
    -SddcVersion $sddcVersion `
    -NetworkPool $selectedPool.name `
    -ScriptVersion $ScriptMeta.Version
Start-Process $ReportPath

Write-Host ("=" * 62) -ForegroundColor DarkCyan
Write-Host ""

#endregion
