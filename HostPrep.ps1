<#
.SYNOPSIS
    Prepares ESXi hosts for commissioning into SDDC Manager / VCF 9.

.DESCRIPTION
    Reads a plain text file containing one ESXi host FQDN per line and runs
    through the following steps on each host:

      1. DNS validation  --  forward (A record) and reverse (PTR) lookup
      2. Connect to the host using the root account via PowerCLI
      3. NTP  --  verify NTP servers are configured and ntpd is running
      4. Advanced Settings  --  set allowSelfSigned = true (required by SDDC Manager)
      5. Optional Advanced Settings  --  apply any settings enabled in the
         $OptionalAdvancedSettings block at the top of the script
      6. Storage type detection  --  detect VMFS_FC (FC HBA present) or NFS
         (NFS datastore mounted); defaults to VSAN otherwise. Note: vSAN OSA
         vs ESA cannot be auto-detected on unclaimed hosts -- override to
         VSAN_ESA in Commission-VCFHosts.ps1 if ESA is intended
      7. Certificate regeneration  --  check CN vs FQDN; if mismatched, enable
         SSH temporarily, run /sbin/generate-certificates via Posh-SSH, disable
         SSH, reboot, and wait for the host to return online
      8. Password reset (optional)  --  reset root password to a VCF 9 compliant
         value; always runs last so the existing credential is valid throughout

    After all hosts are processed:
      - A colourised summary table is printed to the console
      - An HTML commissioning report is saved next to the script containing the
        SHA256:<base64> thumbprint for each host (ready to paste into SDDC Manager)
      - A commissioning CSV is saved next to the script for use by the companion
        script Commission-VCFHosts.ps1 to automate the SDDC Manager commissioning step

    Storage Type Detection
    ----------------------
    The storage type per host is detected automatically after connecting:
      - VMFS_FC   : Fibre Channel HBA detected
      - NFS       : NFS datastore mounted
      - VSAN      : default for all other hosts (unclaimed disks)

    vSAN OSA vs ESA cannot be distinguished on a freshly prepped host because
    disks are unclaimed at commissioning time. If ESA is intended, override the
    storage type interactively in Commission-VCFHosts.ps1 or edit the CSV.

    Optional Advanced Settings
    --------------------------
    Near the top of the script, the $OptionalAdvancedSettings block contains
    extra settings that are disabled by default. Set Enabled = $true to apply:

      - Config.HostAgent.plugins.hostsvc.esxAdminsGroup (string)
          AD group whose members receive full ESXi admin access.
          Default: "ESX Admins"  --  change to match your AD group name.

      - LSOM.lsomEnableRebuildOnLSE (integer, 1/0)
          Enables vSAN automatic rebuild when a device is flagged as LSE.

      - DataMover.HardwareAcceleratedMove / HardwareAcceleratedInit (integer, 1/0)
          Enables SSD TRIM so ESXi issues UNMAP commands to compatible SSDs.

    Host List File
    --------------
    A plain text file with one ESXi FQDN per line. Lines starting with # are
    treated as comments and ignored. Surrounding quotes on the path are stripped
    automatically when pasted.

    Prerequisites
    -------------
    One-time PowerCLI setup (run once per user account):

        Set-PowerCLIConfiguration -Scope User -ParticipateInCEIP $false -Confirm:$false

    Posh-SSH is optional but required for automated certificate regeneration:

        Install-Module -Name Posh-SSH -Scope CurrentUser

    Without Posh-SSH the script will print per-host manual instructions for
    the certificate step instead of failing.

    VCF 9 Password Requirements
    ---------------------------
    If a password reset is requested the new password is validated before any
    host is touched:
      - 15 to 40 characters
      - At least 1 lowercase letter
      - At least 1 uppercase letter (not as the first character)
      - At least 1 digit (not as the last character)
      - At least 1 special character from: @ ! # $ % ? ^
      - Only letters, digits, and @ ! # $ % ? ^ are permitted
      - At least 3 of the 4 character classes must be present

.PARAMETER NtpServers
    One or more NTP server addresses. Defaults to 'pool.ntp.org'.

.PARAMETER LogPath
    Path to write the transcript log. Defaults to the Desktop.

.PARAMETER DryRun
    Simulates all steps without making any changes. All actions are logged
    as [DRY RUN]. Useful for validating the script against your environment.

.PARAMETER WhatIfReport
    Connects to each host, reads the certificate CN, thumbprint and expiry,
    then generates the HTML report and CSV without making any changes.
    Useful for a pre-commissioning inventory pass to collect thumbprints.

.PARAMETER ReportPath
    Path for the HTML commissioning report. Defaults to the script folder
    with a timestamp filename: HostPrep_<timestamp>_Report.html.

.PARAMETER CsvPath
    Path for the commissioning CSV consumed by Commission-VCFHosts.ps1.
    Defaults to the script folder: HostPrep_<timestamp>_Commissioning.csv.

.EXAMPLE
    .\HostPrep.ps1

.EXAMPLE
    .\HostPrep.ps1 -NtpServers "ntp1.example.com","ntp2.example.com"

.EXAMPLE
    .\HostPrep.ps1 -DryRun

.EXAMPLE
    .\HostPrep.ps1 -WhatIfReport

.NOTES
    Script  : HostPrep.ps1
    Version : 3.6.0
    Author  : Paul van Dieen
    Blog    : https://www.hollebollevsan.nl
    Date    : 2026-03-20

    Changelog:
        1.0.0 - Initial release
        1.1.0 - Genericised parameters, improved NTP/SSH checks, added error
                handling, colorised summary table, added versioning metadata
        1.2.0 - Added -DryRun switch for safe pre-flight testing
        1.3.0 - Hardened password reset: input validation, single plaintext
                extraction with immediate clear, throw-on-failure, stale
                session warning, and processed-host tracking
        1.4.0 - Replaced -ResetPassword switch with interactive Y/N prompt
        1.5.0 - Removed -ApplyAdvancedSettings switch; retained only
                allowSelfSigned setting applied by default
        1.6.0 - Added VCF 9 password compliance validation with detailed
                per-rule feedback; new password prompt loops until a
                compliant password is entered
        1.7.0 - Removed -EsxiUsername parameter; hardcoded to 'root'
        1.8.0 - Moved helper functions before credential gathering; replaced
                Get-Credential popup with Read-Host console prompts; added
                password confirmation; Reset-ESXiAccountPassword now accepts
                SecureString instead of PSCredential
        1.9.0 - Replaced file browser popup with command line Read-Host
                prompt; password reset step moved to run last per host
        2.0.0 - Expanded comment block: usage instructions, host list file
                format, password requirements
        2.1.0 - Added certificate regeneration and conditional reboot with
                port 443 polling; added CertRegen and Rebooted summary columns
        2.2.0 - Removed SSH enable/check; all operations use VMware API
        2.3.0 - Fixed Get-EsxCli null error by using VMHost objects throughout
                instead of plain strings
        2.4.0 - Certificate regeneration switched to temporary SSH via
                Posh-SSH running /sbin/generate-certificates
        2.5.0 - Added certificate check before regen (issuer vs subject)
        2.6.0 - Simplified cert check to CN vs hostname only
        2.7.0 - Posh-SSH made optional; missing module warns at startup and
                prints per-host manual instructions; 'Manual' summary state
        2.8.0 - PowerCLI CEIP opt-out persisted to User scope on first run;
                InvalidCertificateAction set to Ignore for the session;
                removed unused Windows.Forms assembly; cleaned up description
        2.9.0 - Test-ESXiCertificateNeedsRegen returns a structured object
                with SHA-256 thumbprint, CN and expiry; thumbprint re-read
                after cert regen to reflect new cert; HTML commissioning
                report generated after run; added -ReportPath parameter
        2.9.1 - Fixed HTML report Successful count; moved Add-Type System.Web
                to Initialisation region
        3.0.0 - Added $OptionalAdvancedSettings config hashtable with four
                optional settings (esxAdminsGroup, lsomEnableRebuildOnLSE,
                HardwareAcceleratedMove/Init); OptionalSettings column added
                to summary table; description expanded
        3.1.0 - Per-setting try/catch in optional settings loop with Partial
                state; type notes and re-run warning added to comments;
                added -WhatIfReport switch; HTML report gains clipboard copy
                button, cert expiry column with amber/red highlighting, and
                Optional Settings column; Expiry stored in $hostResult
        3.2.0 - Fixed $summaryWidth undefined; WhatIfReport overallOk logic
                corrected; CertRegen OK in WhatIfReport shows Not needed;
                password reset prompt and Posh-SSH warning skipped in
                WhatIfReport mode
        3.3.0 - Reboot timeout sets Rebooted=Timeout and surfaces a clear
                error in $hostResult.Error; prominent red banner on timeout;
                finally block skips disconnect when host never came back;
                Timeout state added to colour table, HTML report, and legend
        3.3.1 - Thumbprint format changed from colon-separated hex to
                SHA256:<base64> to match SDDC Manager commissioning UI;
                UTF-8 BOM added; em-dashes replaced with ASCII hyphens;
                Write-ColorSummaryTable, Write-HtmlReport and Get-CellColor
                moved to Helper Functions region to fix PS parse errors
        3.4.0 - Added Test-DNSResolution: forward A record and reverse PTR
                check per host before connect; DNS column in summary table
                and HTML report; WARN for PTR issues, FAILED for no A record
        3.5.0 - Added commissioning CSV export (HostPrep_<timestamp>_
                Commissioning.csv) with FQDN, thumbprint and storage type
                for hosts that connected successfully; added -CsvPath
                parameter; companion script Commission-VCFHosts.ps1 reads
                this CSV to automate the SDDC Manager commissioning step
        3.6.0 - Added Get-ESXiStorageType helper: detects VMFS_FC (FC HBA
                present) and NFS (NFS datastore mounted); defaults to VSAN
                for all other hosts; vSAN OSA vs ESA is not auto-detectable
                on unclaimed hosts and must be overridden manually in
                Commission-VCFHosts.ps1; detected type written per-host
                to the commissioning CSV
#>

[CmdletBinding()]
param (
    [string[]]$NtpServers = @("pool.ntp.org"),

    [switch]$DryRun,

    [switch]$WhatIfReport,

    [string]$LogPath = [System.IO.Path]::Combine(
        [Environment]::GetFolderPath('Desktop'),
        "HostPrep_$(Get-Date -Format 'yyyyMMdd_HHmmss').log"
    ),

    [string]$ReportPath = [System.IO.Path]::Combine(
        $PSScriptRoot,
        "HostPrep_$(Get-Date -Format 'yyyyMMdd_HHmmss')_Report.html"
    ),

    [string]$CsvPath = [System.IO.Path]::Combine(
        $PSScriptRoot,
        "HostPrep_$(Get-Date -Format 'yyyyMMdd_HHmmss')_Commissioning.csv"
    )
)

#region --- Script Metadata ---

$ScriptMeta = @{
    Name    = "HostPrep.ps1"
    Version = "3.6.0"
    Author  = "Paul van Dieen"
    Blog    = "https://www.hollebollevsan.nl"
    Date    = "2026-03-19"
}

#endregion

#region --- Optional Advanced Settings ---
#
# Set Enabled = $true for any setting you want to apply on every host.
# Settings with Enabled = $false are silently skipped.
# Value types: strings must be quoted ("like this"), integers unquoted (1 or 0),
# booleans as $true/$false. Using the wrong type will be silently accepted by
# Set-AdvancedSetting but may have no effect  --  check the type note per setting.
#
$OptionalAdvancedSettings = @(

    # ESX Admins group  --  the Active Directory group whose members are granted
    # full administrative access to the ESXi host. Change the value to match
    # your AD group name before enabling.
    # Value type: string
    # Note: if you re-run the script with a different value, the setting will
    # be overwritten. Verify the group name before enabling across all hosts.
    @{
        Name    = "Config.HostAgent.plugins.hostsvc.esxAdminsGroup"
        Value   = "ESX Admins"
        Enabled = $false
        Label   = "ESX Admins group"
    },

    # vSAN rebuild on Latency Sensitive Equipment (LSE)  --  controls whether
    # vSAN triggers an automatic rebuild when a device is marked as LSE.
    # Value type: integer (1 = enabled, 0 = disabled)
    @{
        Name    = "LSOM.lsomEnableRebuildOnLSE"
        Value   = 1
        Enabled = $false
        Label   = "vSAN rebuild on LSE"
    },

    # SSD TRIM support  --  instructs ESXi to issue TRIM/UNMAP commands to
    # compatible SSDs, allowing the drive firmware to reclaim freed blocks.
    # Value type: integer (1 = enabled, 0 = disabled)
    @{
        Name    = "DataMover.HardwareAcceleratedMove"
        Value   = 1
        Enabled = $false
        Label   = "SSD TRIM - HardwareAcceleratedMove"
    },
    @{
        Name    = "DataMover.HardwareAcceleratedInit"
        Value   = 1
        Enabled = $false
        Label   = "SSD TRIM - HardwareAcceleratedInit"
    }
)

#endregion

#region --- Initialisation ---

# Suppress PowerCLI CEIP nag. The warning fires on first module load in any
# new session, so we persist the opt-out to the User scope once and silently
# apply it to the current session. After the first run it will never appear.
$ceipConfig = Get-PowerCLIConfiguration -Scope User -WarningAction SilentlyContinue
if ($null -eq $ceipConfig.ParticipateInCEIP) {
    Set-PowerCLIConfiguration -Scope User -ParticipateInCEIP $false -Confirm:$false -WarningAction SilentlyContinue | Out-Null
}
Set-PowerCLIConfiguration -Scope Session -ParticipateInCEIP $false -InvalidCertificateAction Ignore -Confirm:$false -WarningAction SilentlyContinue | Out-Null

$bannerWidth = 62
Write-Host ""
Write-Host ("=" * $bannerWidth) -ForegroundColor DarkCyan
Write-Host ("  {0,-30} {1}" -f $ScriptMeta.Name, ("v" + $ScriptMeta.Version)) -ForegroundColor Cyan
Write-Host ("  Author : {0}" -f $ScriptMeta.Author) -ForegroundColor Cyan
Write-Host ("  Blog   : {0}" -f $ScriptMeta.Blog) -ForegroundColor Cyan
Write-Host ("  Date   : {0}" -f $ScriptMeta.Date) -ForegroundColor DarkGray
Write-Host ("=" * $bannerWidth) -ForegroundColor DarkCyan
Write-Host ""

if ($DryRun) {
    Write-Host "  *** DRY RUN MODE - No changes will be made ***" -ForegroundColor Yellow
    Write-Host ("  " + $ScriptMeta.Blog) -ForegroundColor DarkGray
    Write-Host ""
}

if ($WhatIfReport) {
    Write-Host "  *** WHATIF REPORT MODE - Thumbprint collection only ***" -ForegroundColor Cyan
    Write-Host "  Connects to each host, reads certificate thumbprint and expiry," -ForegroundColor DarkGray
    Write-Host "  then generates the HTML report. No changes will be made." -ForegroundColor DarkGray
    Write-Host ("  " + $ScriptMeta.Blog) -ForegroundColor DarkGray
    Write-Host ""
}

# Start transcript for audit logging
Start-Transcript -Path $LogPath -Append
Write-Host "HostPrep started at $(Get-Date)" -ForegroundColor Cyan

# Verify optional modules (Posh-SSH needed for cert regen  --  not relevant in WhatIfReport mode)
$script:PoshSSHAvailable = $false
if (-not $WhatIfReport) {
    if (-not (Get-Module -ListAvailable -Name "Posh-SSH")) {
        Write-Host ""
        Write-Host "  WARNING: The 'Posh-SSH' module is not installed." -ForegroundColor Yellow
        Write-Host "  Certificate regeneration will be skipped for all hosts." -ForegroundColor Yellow
        Write-Host "  To enable it, run: Install-Module -Name Posh-SSH -Scope CurrentUser" -ForegroundColor Yellow
        Write-Host ""
    } else {
        Import-Module Posh-SSH -ErrorAction Stop
        $script:PoshSSHAvailable = $true
    }
}

# Required for HTML entity encoding in the commissioning report
Add-Type -AssemblyName System.Web

#endregion
#region --- Helper Functions ---

function Test-VCF9PasswordCompliance {
    <#
    .SYNOPSIS
        Validates a plaintext password against VCF 9 ESXi root password requirements.

    .DESCRIPTION
        VCF 9 enforces the following rules on ESXi root passwords:
          - Minimum 15 characters, maximum 40 characters
          - At least 1 uppercase letter (not as the very first character)
          - At least 1 lowercase letter
          - At least 1 digit (not as the very last character)
          - At least 1 special character from the set: @ ! # $ % ? ^
          - No characters outside letters, digits, and @ ! # $ % ? ^
          - At least 3 of the 4 character classes must be present
          - Dictionary words should be avoided (cannot be enforced client-side)

    .PARAMETER Password
        The plaintext password string to test.

    .OUTPUTS
        PSCustomObject with:
          .Passed  [bool]   - $true if all rules pass
          .Failures [string[]] - list of failed rule descriptions

    .NOTES
        Source: VCF 9 / ESX 9 password policy documentation and installer validation.
    #>
    param (
        [Parameter(Mandatory)]
        [string]$Password
    )

    $failures = [System.Collections.Generic.List[string]]::new()

    # Rule 1: Length 15-40
    if ($Password.Length -lt 15) {
        $failures.Add("Too short: minimum 15 characters (current: $($Password.Length))")
    }
    if ($Password.Length -gt 40) {
        $failures.Add("Too long: maximum 40 characters (current: $($Password.Length))")
    }

    # Rule 2: Only permitted characters (letters, digits, @ ! # $ % ? ^)
    if ($Password -match '[^a-zA-Z0-9@!#$%\?\^]') {
        $failures.Add("Contains forbidden characters. Only letters, digits, and @ ! # `$ % ? ^ are allowed.")
    }

    # Rule 3: At least 1 lowercase letter
    if ($Password -notmatch '[a-z]') {
        $failures.Add("Must contain at least 1 lowercase letter.")
    }

    # Rule 4: At least 1 uppercase letter, and NOT as the very first character
    if ($Password -notmatch '[A-Z]') {
        $failures.Add("Must contain at least 1 uppercase letter.")
    } elseif ($Password[0] -cmatch '[A-Z]') {
        $failures.Add("Uppercase letter must not be the first character.")
    }

    # Rule 5: At least 1 digit, and NOT as the very last character
    if ($Password -notmatch '[0-9]') {
        $failures.Add("Must contain at least 1 digit.")
    } elseif ($Password[-1] -match '[0-9]') {
        $failures.Add("A digit must not be the last character.")
    }

    # Rule 6: At least 1 special character from the allowed set
    if ($Password -notmatch '[@!#$%\?\^]') {
        $failures.Add("Must contain at least 1 special character from: @ ! # `$ % ? ^")
    }

    # Rule 7: At least 3 of 4 character classes present
    $classCount = 0
    if ($Password -cmatch '[a-z]')       { $classCount++ }
    if ($Password -cmatch '[A-Z]')       { $classCount++ }
    if ($Password -match '[0-9]')        { $classCount++ }
    if ($Password -match '[@!#$%\?\^]') { $classCount++ }

    if ($classCount -lt 3) {
        $failures.Add("Must use at least 3 of 4 character classes: lowercase, uppercase, digits, special characters (currently using $classCount).")
    }

    return [PSCustomObject]@{
        Passed   = ($failures.Count -eq 0)
        Failures = $failures
    }
}

function Test-ESXiCertificateNeedsRegen {
    <#
    .SYNOPSIS
        Checks whether the ESXi host certificate CN matches the host's FQDN
        and captures the SHA-256 thumbprint for use in the HTML report.

    .DESCRIPTION
        Connects to port 443 and reads the TLS certificate. If the CN in the
        Subject does not match the supplied hostname, the certificate needs
        regenerating. No credentials or SSH required.

    .PARAMETER VMHost
        FQDN or hostname of the ESXi host.

    .OUTPUTS
        PSCustomObject with:
          .NeedsRegen  [bool]   - $true if CN does not match hostname
          .Thumbprint  [string] - SHA256:<base64> thumbprint as expected by SDDC Manager
          .CN          [string] - CN extracted from the certificate Subject
          .Expiry      [string] - Certificate expiry date
    #>
    param (
        [Parameter(Mandatory)][string]$VMHost
    )

    try {
        $tcpClient = New-Object System.Net.Sockets.TcpClient($VMHost, 443)
        $sslStream  = New-Object System.Net.Security.SslStream(
            $tcpClient.GetStream(), $false,
            { param($s, $cert, $chain, $errors) $true }   # accept any cert
        )
        $sslStream.AuthenticateAsClient($VMHost)
        $cert = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2(
            $sslStream.RemoteCertificate
        )
        $sslStream.Close()
        $tcpClient.Close()

        # Extract CN from Subject (e.g. "CN=esxi01.vcf.lab, O=VMware...")
        $cnMatch = $cert.Subject -match 'CN=([^,]+)'
        $cn      = if ($cnMatch) { $Matches[1].Trim() } else { "" }

        # Compute SHA-256 thumbprint in the format SDDC Manager expects:
        # "SHA256:" followed by the base64-encoded hash (no padding, URL-safe not required)
        $sha256     = [System.Security.Cryptography.SHA256]::Create()
        $hashBytes  = $sha256.ComputeHash($cert.RawData)
        $thumbprint = "SHA256:" + [System.Convert]::ToBase64String($hashBytes)

        $expiry = $cert.NotAfter.ToString("yyyy-MM-dd HH:mm:ss")

        Write-Host "  Certificate CN  : $cn" -ForegroundColor DarkGray
        Write-Host "  Host FQDN       : $VMHost" -ForegroundColor DarkGray
        Write-Host "  Expires         : $expiry" -ForegroundColor DarkGray
        Write-Host "  SHA256:base64   : $thumbprint" -ForegroundColor DarkGray

        $needsRegen = $cn -ne $VMHost
        if ($needsRegen) {
            Write-Host "  CN does not match hostname. Regeneration needed." -ForegroundColor Yellow
        } else {
            Write-Host "  CN matches hostname. Regeneration not needed." -ForegroundColor Green
        }

        return [PSCustomObject]@{
            NeedsRegen  = $needsRegen
            Thumbprint  = $thumbprint
            CN          = $cn
            Expiry      = $expiry
        }

    } catch {
        Write-Warning "  Could not read certificate from $VMHost port 443: $_"
        Write-Warning "  Proceeding with regeneration to be safe."
        return [PSCustomObject]@{
            NeedsRegen  = $true
            Thumbprint  = "N/A"
            CN          = "N/A"
            Expiry      = "N/A"
        }
    }
}

function Invoke-ESXiCertificateRegen {
    <#
    .SYNOPSIS
        Regenerates the ESXi host certificate via a temporary SSH session.

    .DESCRIPTION
        - Enables SSH on the host via PowerCLI (Set-VMHostServiceConfig)
        - Opens an SSH session using Posh-SSH with the supplied root credentials
        - Runs /sbin/generate-certificates
        - Disables SSH again regardless of outcome (try/finally)
        - Returns $true on success, throws on failure

    .PARAMETER VMHost
        FQDN or hostname of the ESXi host (string - needed for SSH connection).

    .PARAMETER VMHostObj
        VMHost object returned by Get-VMHost, used for PowerCLI service control.

    .PARAMETER Credential
        PSCredential for the root account, used to authenticate the SSH session.
    #>
    param (
        [Parameter(Mandatory)][string]$VMHost,
        [Parameter(Mandatory)]$VMHostObj,
        [Parameter(Mandatory)][System.Management.Automation.PSCredential]$Credential
    )

    # Enable SSH temporarily
    Write-Host "  Enabling SSH temporarily for certificate regeneration..." -ForegroundColor Yellow
    Set-VMHostServiceConfig -VMHost $VMHostObj -ServiceKey "TSM-SSH"

    $sshSession = $null
    try {
        # Connect via SSH
        Write-Host "  Connecting via SSH to run /sbin/generate-certificates..." -ForegroundColor Cyan
        $sshSession = New-SSHSession -ComputerName $VMHost -Credential $Credential `
                        -AcceptKey -ErrorAction Stop

        $sshResult = Invoke-SSHCommand -SessionId $sshSession.SessionId `
                        -Command "/sbin/generate-certificates" -ErrorAction Stop

        if ($sshResult.ExitStatus -ne 0) {
            throw "/sbin/generate-certificates exited with code $($sshResult.ExitStatus). Output: $($sshResult.Output -join ' ')"
        }

        Write-Host "  Certificate regenerated successfully on $VMHost." -ForegroundColor Green
        return $true

    } finally {
        # Always close SSH session and disable the service
        if ($sshSession) {
            Remove-SSHSession -SessionId $sshSession.SessionId -ErrorAction SilentlyContinue | Out-Null
        }
        Write-Host "  Disabling SSH..." -ForegroundColor Yellow
        $svc = Get-VMHostService -VMHost $VMHostObj | Where-Object { $_.Key -eq "TSM-SSH" }
        if ($svc) {
            $svc | Set-VMHostService -Policy "off" -Confirm:$false | Out-Null
            if ($svc.Running) {
                $svc | Stop-VMHostService -Confirm:$false | Out-Null
            }
        }
        Write-Host "  SSH disabled." -ForegroundColor Green
    }
}

function Wait-ESXiHostOnline {
    <#
    .SYNOPSIS
        Waits for an ESXi host to come back online after a reboot by polling
        TCP port 443 until it responds or the timeout is reached.

    .PARAMETER VMHost
        FQDN or name of the ESXi host to poll.

    .PARAMETER TimeoutSeconds
        Maximum number of seconds to wait. Defaults to 600 (10 minutes).

    .PARAMETER PollIntervalSeconds
        Seconds between each poll attempt. Defaults to 15.
    #>
    param (
        [Parameter(Mandatory)][string]$VMHost,
        [int]$TimeoutSeconds    = 600,
        [int]$PollIntervalSeconds = 15
    )

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    Write-Host "  Waiting for $VMHost to come back online (timeout: ${TimeoutSeconds}s)..." -ForegroundColor Cyan

    # Brief initial pause to allow the host to begin its shutdown sequence
    Start-Sleep -Seconds 30

    while ((Get-Date) -lt $deadline) {
        try {
            $tcp = New-Object System.Net.Sockets.TcpClient
            $connect = $tcp.BeginConnect($VMHost, 443, $null, $null)
            $wait    = $connect.AsyncWaitHandle.WaitOne(3000, $false)
            if ($wait -and $tcp.Connected) {
                $tcp.Close()
                Write-Host "  $VMHost is back online." -ForegroundColor Green
                # Brief extra pause to let services fully initialise
                Start-Sleep -Seconds 15
                return $true
            }
            $tcp.Close()
        } catch {
            # Connection refused or timed out  --  host still rebooting
        }
        Write-Host "  Still waiting... ($(
            [int]($deadline - (Get-Date)).TotalSeconds)s remaining)" -ForegroundColor DarkGray
        Start-Sleep -Seconds $PollIntervalSeconds
    }

    throw "Timed out waiting for $VMHost to come back online after ${TimeoutSeconds}s."
}

function Set-VMHostServiceConfig {
    <#
    .SYNOPSIS
        Ensures a VMHost service is set to the given policy and is running.
    #>
    param (
        [Parameter(Mandatory)]$VMHost,
        [string]$ServiceKey,
        [string]$Policy = "on"
    )

    $svc = Get-VMHostService -VMHost $VMHost | Where-Object { $_.Key -eq $ServiceKey }

    if (-not $svc) {
        Write-Warning "  Service '$ServiceKey' not found on host."
        return
    }

    if ($svc.Policy -ne $Policy) {
        Write-Host "  Setting '$ServiceKey' startup policy to '$Policy'..." -ForegroundColor Yellow
        $svc | Set-VMHostService -Policy $Policy -Confirm:$false | Out-Null
    }

    if (-not $svc.Running) {
        Write-Host "  Starting service '$ServiceKey'..." -ForegroundColor Yellow
        $svc | Start-VMHostService -Confirm:$false | Out-Null
    } else {
        Write-Host "  Service '$ServiceKey' is already running with policy '$Policy'." -ForegroundColor Green
    }
}

function Reset-ESXiAccountPassword {
    <#
    .SYNOPSIS
        Resets an ESXi account password via ESXCLI v2 with hardened handling.

    .DESCRIPTION
        - Validates inputs before touching the host
        - Extracts the plaintext password exactly once then immediately clears it
        - Throws a terminating error on any non-true result so the caller's
          catch block always handles failures consistently
        - Warns that the active session credential is now stale after a
          successful reset of the connected account
        - Records the host in the script-scoped processed list for run tracking

    .PARAMETER VMHost
        VMHost object returned by Get-VMHost (not a plain string).

    .PARAMETER NewPassword
        SecureString containing the new password to set for the root account.

    .PARAMETER ConnectedUsername
        The username used for the current VI session. If it matches 'root',
        a stale-session warning is emitted.
    #>
    param (
        [Parameter(Mandatory)]$VMHost,
        [Parameter(Mandatory)][System.Security.SecureString]$NewPassword,
        [string]$ConnectedUsername = ""
    )

    # Guard: password must not be empty
    if ($NewPassword.Length -eq 0) {
        throw "Cannot reset password: new password is empty."
    }

    # Extract plaintext password exactly once into a local variable,
    # use it immediately, then overwrite with empty string to limit
    # the window it exists as cleartext in memory.
    $plainPassword = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto(
                        [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($NewPassword))

    try {
        $esxcli     = Get-EsxCli -VMHost $VMHost -V2
        $esxcliArgs = $esxcli.system.account.set.CreateArgs()

        $esxcliArgs.id                   = "root"
        $esxcliArgs.password             = $plainPassword
        $esxcliArgs.passwordconfirmation = $plainPassword

        $result = $esxcli.system.account.set.Invoke($esxcliArgs)
    }
    finally {
        # Immediately overwrite - limits cleartext lifetime regardless of
        # whether Invoke succeeded or threw
        $plainPassword = [string]::new('*', 16)
        Remove-Variable plainPassword -ErrorAction SilentlyContinue
    }

    # ESXCLI v2 returns $true on success; anything else is a failure
    if ($result -ne $true) {
        throw "ESXCLI returned unexpected result '$result' - password may not have changed."
    }

    Write-Host "  Password reset successfully for 'root' on $($VMHost.Name)." -ForegroundColor Green

    # Warn if root is the same account used for the active session -
    # the current connection credential is now stale for any subsequent reconnects
    if ($ConnectedUsername -eq "root") {
        Write-Warning ("  The reset account 'root' is the same as the active session credential. " +
                       "Any reconnection attempt on this host will fail until credentials are updated.")
    }

    # Record this host so the operator can audit which hosts were processed
    if ($script:PasswordResetCompleted) {
        $script:PasswordResetCompleted.Add($VMHost)
        Write-Host ("  Hosts with password reset completed this run: " +
                    ($script:PasswordResetCompleted -join ', ')) -ForegroundColor DarkGray
    }
}

function Get-CellColor ($value) {
    if ($value -eq $true  -or $value -eq "OK")        { return "Green"    }
    if ($value -eq $false -or $value -like "FAILED*")  { return "Red"      }
    if ($value -eq "Skipped")                          { return "DarkGray" }
    if ($value -eq "Manual")                           { return "Yellow"   }
    if ($value -eq "Partial")                          { return "Yellow"   }
    if ($value -eq "Timeout")                          { return "Red"      }
    if ($value -like "Unexpected*")                    { return "Yellow"   }
    if ($value -like "WARN:*")                         { return "Yellow"   }
    return "White"
}
function Test-DNSResolution {
    <#
    .SYNOPSIS
        Validates forward and reverse DNS resolution for an ESXi host FQDN.

    .DESCRIPTION
        Performs a forward lookup (FQDN to IP) and a reverse lookup (IP back
        to FQDN) and returns a structured result. A mismatch or failure will
        cause SDDC Manager commissioning to fail, so this is checked early
        per host before any configuration changes are made.

    .PARAMETER VMHost
        FQDN of the ESXi host to validate.

    .OUTPUTS
        PSCustomObject with:
          .Status   [string] - "OK", "FAILED", or "WARN:<detail>"
          .Forward  [string] - resolved IP address, or error message
          .Reverse  [string] - PTR name resolved from that IP, or error message
    #>
    param (
        [Parameter(Mandatory)][string]$VMHost
    )

    try {
        # Forward lookup
        $forwardResult = [System.Net.Dns]::GetHostAddresses($VMHost)
        $ip = ($forwardResult | Where-Object { $_.AddressFamily -eq 'InterNetwork' } | Select-Object -First 1).IPAddressToString
        if (-not $ip) {
            $ip = $forwardResult[0].IPAddressToString
        }

        # Reverse lookup
        try {
            $reverseResult = [System.Net.Dns]::GetHostEntry($ip)
            $ptr = $reverseResult.HostName

            # Compare PTR to FQDN (case-insensitive, strip trailing dot)
            $ptrClean = $ptr.TrimEnd('.')
            if ($ptrClean -ieq $VMHost) {
                return [PSCustomObject]@{ Status = "OK";              Forward = $ip; Reverse = $ptr }
            } else {
                return [PSCustomObject]@{ Status = "WARN:PTR mismatch ($ptrClean)"; Forward = $ip; Reverse = $ptr }
            }
        } catch {
            return [PSCustomObject]@{ Status = "WARN:No PTR record"; Forward = $ip; Reverse = "N/A" }
        }

    } catch {
        return [PSCustomObject]@{ Status = "FAILED"; Forward = "N/A"; Reverse = "N/A" }
    }
}


function Get-ESXiStorageType {
    <#
    .SYNOPSIS
        Detects the primary storage type of a standalone ESXi host for use
        in the VCF commissioning CSV.

    .DESCRIPTION
        Checks in order: FC HBAs, NFS datastores, then defaults to VSAN.

        vSAN OSA vs ESA cannot be reliably auto-detected on a freshly prepped
        host because disks are unclaimed at commissioning time -- there are no
        disk groups or storage pools yet. The distinction is a deployment design
        choice, not a readable hardware state. If your hosts are intended for
        vSAN ESA, override the storage type interactively in Commission-VCFHosts.ps1
        when prompted, or edit the CSV directly before running that script.

        Valid SDDC Manager storageType values:
          VSAN       - vSAN Original Storage Architecture (OSA)  [default]
          VSAN_ESA   - vSAN Express Storage Architecture -- set manually
          NFS        - NFS datastore                            -- auto-detected
          VMFS_FC    - VMFS on Fibre Channel                    -- auto-detected
          VVOL       - Virtual Volumes                          -- set manually

    .PARAMETER VMHostObj
        VMHost object returned by Get-VMHost.
    #>
    param (
        [Parameter(Mandatory)]$VMHostObj
    )

    try {
        # FC HBA check -- presence of FibreChannel HBAs indicates VMFS_FC intent
        $fcHbas = Get-VMHostHba -VMHost $VMHostObj -Type FibreChannel -ErrorAction SilentlyContinue
        if ($fcHbas -and @($fcHbas).Count -gt 0) {
            Write-Host "  Storage type detected : VMFS_FC (Fibre Channel HBA present)" -ForegroundColor DarkGray
            return "VMFS_FC"
        }

        # NFS check -- any NFS datastore mounted
        $nfsDs = Get-Datastore -VMHost $VMHostObj -ErrorAction SilentlyContinue |
                    Where-Object { $_.Type -eq "NFS" -or $_.Type -eq "NFS41" }
        if ($nfsDs -and @($nfsDs).Count -gt 0) {
            Write-Host "  Storage type detected : NFS (NFS datastore mounted)" -ForegroundColor DarkGray
            return "NFS"
        }

        # Default -- vSAN hosts have unclaimed disks at commissioning time;
        # OSA vs ESA is a design choice and must be set manually if ESA is intended.
        Write-Host "  Storage type detected : VSAN (default -- override to VSAN_ESA in Commission-VCFHosts.ps1 if needed)" -ForegroundColor DarkGray
        return "VSAN"

    } catch {
        Write-Host "  Storage type detection failed: $_ -- defaulting to VSAN" -ForegroundColor Yellow
        return "VSAN"
    }
}


function Write-ColorSummaryTable {
    param (
        [System.Collections.Generic.List[PSCustomObject]]$Data
    )

    # Column definitions: header label and width
    $columns = [ordered]@{
        Host             = 34
        Connected        = 11
        DNS              = 14
        NTP              = 6
        AdvancedSettings = 17
        OptionalSettings = 17
        CertRegen        = 10
        Rebooted         = 10
        PasswordReset    = 15
        Error            = 28
    }

    $divider = "+" + (($columns.Values | ForEach-Object { "-" * ($_ + 2) }) -join "+") + "+"

    Write-Host ""
    Write-Host $divider -ForegroundColor DarkCyan

    # Header row
    $headerLine = "|"
    foreach ($col in $columns.GetEnumerator()) {
        $headerLine += " {0,-$($col.Value)} |" -f $col.Key
    }
    Write-Host $headerLine -ForegroundColor Cyan
    Write-Host $divider -ForegroundColor DarkCyan

    # Data rows
    foreach ($row in $Data) {
        # Determine row base colour from Connected + Error
        $rowColor = if ($row.Error) { "Red" } elseif ($row.Connected) { "White" } else { "DarkYellow" }

        # Write the row, then rewrite individual cells with colour
        # PowerShell can't inline per-cell colour in a single Write-Host,
        # so we print cell by cell
        Write-Host "|" -ForegroundColor DarkCyan -NoNewline
        foreach ($col in $columns.GetEnumerator()) {
            $val     = $row.($col.Key)
            $display = if ($null -eq $val) { "" } else { "$val" }
            if ($display.Length -gt $col.Value) { $display = $display.Substring(0, $col.Value - 1) + "~" }
            $padded  = " {0,-$($col.Value)} " -f $display
            $color   = Get-CellColor $val
            if ($color -eq "White") { $color = $rowColor }
            Write-Host $padded -ForegroundColor $color -NoNewline
            Write-Host "|" -ForegroundColor DarkCyan -NoNewline
        }
        Write-Host ""  # newline
    }

    Write-Host $divider -ForegroundColor DarkCyan
}

function Write-HtmlReport {
    param (
        [System.Collections.Generic.List[PSCustomObject]]$Data,
        [string]$ReportPath
    )

    $totalCount   = [int]$Data.Count
    $successCount = [int]($Data | Where-Object { (-not $_.Error) -and ($_.Connected -eq $true) } | Measure-Object).Count
    $failCount    = [int]($Data | Where-Object { $_.Error -or ($_.Connected -ne $true) } | Measure-Object).Count

    $generatedAt = Get-Date -Format "yyyy-MM-dd HH:mm:ss"

    # Build table rows
    $rows = foreach ($row in $Data) {
        # WhatIfReport: only connected + no error + cert readable counts as success
        # Normal run: connected + no error + NTP OK + AdvancedSettings OK
        $overallOk = if ($WhatIfReport) {
            (-not $row.Error) -and ($row.Connected -eq $true) -and ($row.Thumbprint -ne "N/A")
        } else {
            (-not $row.Error) -and
            ($row.Connected -eq $true) -and
            ($row.NTP -eq "OK") -and
            ($row.AdvancedSettings -eq "OK")
        }

        $rowClass = if ($row.Error) { "fail" } elseif ($overallOk) { "ok" } else { "warn" }

        $thumbCell = if ($row.Thumbprint -eq "N/A") {
            "<td class='na'>N/A</td>"
        } else {
            $encoded = [System.Web.HttpUtility]::HtmlEncode($row.Thumbprint)
            "<td class='thumbprint'><span class='thumb-text'>$encoded</span><button class='copy-btn' onclick='copyThumb(this)' title='Copy to clipboard'>&#128203;</button></td>"
        }

        $expiryCell = if ($row.Expiry -eq "N/A") {
            "<td class='na'>N/A</td>"
        } else {
            # Highlight expiry if within 90 days
            try {
                $expiryDate = [datetime]::ParseExact($row.Expiry, "yyyy-MM-dd HH:mm:ss", $null)
                $daysLeft = ($expiryDate - (Get-Date)).Days
                $expiryClass = if ($daysLeft -lt 30) { "expiry-critical" } elseif ($daysLeft -lt 90) { "expiry-warn" } else { "" }
                "<td class='$expiryClass'>$([System.Web.HttpUtility]::HtmlEncode($row.Expiry))</td>"
            } catch {
                "<td>$([System.Web.HttpUtility]::HtmlEncode($row.Expiry))</td>"
            }
        }

        $statusIcon = if ($row.Error) { "&#10008;" } elseif ($overallOk) { "&#10004;" } else { "&#9888;" }

        "
        <tr class='$rowClass'>
            <td>$([System.Web.HttpUtility]::HtmlEncode($row.Host))</td>
            <td>$(
                if     ($row.DNS -eq 'OK')       { '<span style="color:#3fb950">OK</span>' }
                elseif ($row.DNS -eq 'FAILED')   { '<span style="color:#f85149">FAILED -- no A record</span>' }
                elseif ($row.DNS -eq 'Skipped')  { '<span style="color:#6e7681">Skipped</span>' }
                elseif ($row.DNS -like 'WARN:*') { '<span style="color:#d29922">' + [System.Web.HttpUtility]::HtmlEncode($row.DNS) + '</span>' }
                else                             { [System.Web.HttpUtility]::HtmlEncode($row.DNS) }
            )</td>
            $thumbCell
            $expiryCell
            <td>$(
                if     ($row.CertRegen -eq 'OK' -and $WhatIfReport) { 'Not needed' }
                elseif ($row.CertRegen -eq 'OK')                    { 'Regenerated' }
                elseif ($row.CertRegen -eq 'Skipped')               { 'Not needed' }
                elseif ($row.CertRegen -eq 'Manual')                { 'Manual required' }
                elseif ($row.CertRegen -eq 'Regen needed')          { '<span class=expiry-warn>Regen needed</span>' }
                else                                                 { [System.Web.HttpUtility]::HtmlEncode($row.CertRegen) }
            )</td>
            <td>$(
                if     ($row.Rebooted -eq 'OK')      { 'Yes' }
                elseif ($row.Rebooted -eq 'Skipped') { 'Not needed' }
                elseif ($row.Rebooted -eq 'Manual')  { 'Manual required' }
                elseif ($row.Rebooted -eq 'Timeout') { '<span class="expiry-critical">Timeout  --  check host console</span>' }
                else                                 { [System.Web.HttpUtility]::HtmlEncode($row.Rebooted) }
            )</td>
            <td>$(if ($row.NTP -eq 'OK') { 'OK' } else { [System.Web.HttpUtility]::HtmlEncode($row.NTP) })</td>
            <td>$(if ($row.AdvancedSettings -eq 'OK') { 'OK' } else { [System.Web.HttpUtility]::HtmlEncode($row.AdvancedSettings) })</td>
            <td>$(if ($row.OptionalSettings -eq 'OK') { 'OK' } elseif ($row.OptionalSettings -eq 'Skipped') { '<span style=color:#6e7681>Skipped</span>' } elseif ($row.OptionalSettings -eq 'Partial') { '<span class=expiry-warn>Partial</span>' } else { [System.Web.HttpUtility]::HtmlEncode($row.OptionalSettings) })</td>
            <td>$(if ($row.PasswordReset -eq 'OK') { 'Reset' } elseif ($row.PasswordReset -eq 'Skipped') { 'Not requested' } else { [System.Web.HttpUtility]::HtmlEncode($row.PasswordReset) })</td>
            <td class='status'>$statusIcon $(if ($row.Error) { [System.Web.HttpUtility]::HtmlEncode($row.Error) } else { '' })</td>
        </tr>"
    }

    $html = @"
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>HostPrep Report</title>
<style>
  * { box-sizing: border-box; margin: 0; padding: 0; }
  body { font-family: 'Segoe UI', Arial, sans-serif; background: #0d1117; color: #c9d1d9; padding: 32px; }
  header { margin-bottom: 28px; border-bottom: 2px solid #1f6feb; padding-bottom: 16px; }
  header h1 { font-size: 1.6rem; color: #58a6ff; letter-spacing: 0.5px; }
  header p  { font-size: 0.85rem; color: #8b949e; margin-top: 4px; }
  .meta { display: flex; gap: 32px; margin-bottom: 24px; flex-wrap: wrap; }
  .meta-item { background: #161b22; border: 1px solid #30363d; border-radius: 6px; padding: 12px 20px; }
  .meta-item .label { font-size: 0.75rem; color: #8b949e; text-transform: uppercase; letter-spacing: 0.5px; }
  .meta-item .value { font-size: 1.1rem; font-weight: 600; color: #c9d1d9; margin-top: 2px; }
  table { width: 100%; border-collapse: collapse; font-size: 0.85rem; background: #161b22; border-radius: 8px; overflow: hidden; border: 1px solid #30363d; }
  thead th { background: #1f2937; color: #58a6ff; padding: 10px 14px; text-align: left; font-weight: 600; letter-spacing: 0.4px; white-space: nowrap; border-bottom: 2px solid #1f6feb; }
  tbody tr { border-bottom: 1px solid #21262d; transition: background 0.15s; }
  tbody tr:hover { background: #1c2128; }
  tbody tr:last-child { border-bottom: none; }
  td { padding: 10px 14px; vertical-align: top; }
  td.thumbprint { font-family: 'Consolas', 'Courier New', monospace; font-size: 0.72rem; color: #79c0ff; word-break: break-all; max-width: 380px; }
  .thumb-text { vertical-align: middle; }
  .copy-btn { margin-left: 8px; background: #21262d; border: 1px solid #30363d; border-radius: 4px; color: #8b949e; cursor: pointer; font-size: 0.75rem; padding: 2px 6px; vertical-align: middle; transition: background 0.15s, color 0.15s; }
  .copy-btn:hover { background: #1f6feb; color: #fff; border-color: #1f6feb; }
  .copy-btn.copied { background: #238636; color: #fff; border-color: #238636; }
  td.na { color: #6e7681; font-style: italic; }
  td.status { white-space: nowrap; }
  .expiry-warn     { color: #d29922; }
  .expiry-critical { color: #f85149; font-weight: 600; }
  tr.ok  td.status { color: #3fb950; }
  tr.fail td.status { color: #f85149; }
  tr.warn td.status { color: #d29922; }
  tr.ok  td:first-child { border-left: 3px solid #3fb950; }
  tr.fail td:first-child { border-left: 3px solid #f85149; }
  tr.warn td:first-child { border-left: 3px solid #d29922; }
  .note { margin-top: 20px; font-size: 0.8rem; color: #8b949e; background: #161b22; border: 1px solid #30363d; border-radius: 6px; padding: 12px 16px; }
  .note strong { color: #c9d1d9; }
  footer { margin-top: 28px; font-size: 0.75rem; color: #6e7681; text-align: center; }
</style>
</head>
<body>

<header>
  <h1>&#128196; HostPrep &mdash; VCF Commissioning Report</h1>
  <p>Generated by HostPrep.ps1 v$($ScriptMeta.Version) &bull; $generatedAt</p>
</header>

<div class="meta">
  <div class="meta-item">
    <div class="label">Hosts processed</div>
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
    <div class="label">Thumbprint format</div>
    <div class="value">SHA256:base64</div>
  </div>
</div>

<table>
  <thead>
    <tr>
      <th>Host FQDN</th>
      <th>DNS</th>
      <th>SSL Thumbprint (SHA256:base64)</th>
      <th>Cert Expiry</th>
      <th>Cert Regen</th>
      <th>Rebooted</th>
      <th>NTP</th>
      <th>Advanced Settings</th>
      <th>Optional Settings</th>
      <th>Password Reset</th>
      <th>Status</th>
    </tr>
  </thead>
  <tbody>
    $($rows -join "`n")
  </tbody>
</table>

<div class="note">
  <strong>Note:</strong> The SSL thumbprint shown is in the <code>SHA256:&lt;base64&gt;</code> format
  as expected by the SDDC Manager commissioning UI. Use these values to verify host identity
  when adding hosts to SDDC Manager during VCF commissioning.
  Thumbprints for hosts where certificate regeneration was performed reflect the <em>new</em> certificate.
  Expiry dates within 90 days are shown in <span class="expiry-warn">amber</span>;
  within 30 days in <span class="expiry-critical">red</span>.
</div>

<footer>HostPrep.ps1 &bull; $($ScriptMeta.Author) &bull; $($ScriptMeta.Blog)</footer>

<script>
function copyThumb(btn) {
    var text = btn.previousElementSibling.textContent.trim();
    navigator.clipboard.writeText(text).then(function() {
        btn.textContent = 'Copied!';
        btn.classList.add('copied');
        setTimeout(function() {
            btn.textContent = '\u{1F4CB}';
            btn.classList.remove('copied');
        }, 2000);
    });
}
</script>

</body>
</html>
"@

    $html | Out-File -FilePath $ReportPath -Encoding UTF8
    Write-Host ("  HTML report written to: {0}" -f $ReportPath) -ForegroundColor Cyan
}

#endregion
#region --- Credential Gathering ---

Write-Host "`nGathering credentials..." -ForegroundColor Cyan

$esxiPassword    = Read-Host "Enter the 'root' password used to connect to the ESXi hosts" -AsSecureString
$esxiCredentials = New-Object System.Management.Automation.PSCredential("root", $esxiPassword)

# Ask interactively whether to reset the root account password
# (not applicable in WhatIfReport mode  --  no changes are made)
Write-Host ""
if ($WhatIfReport) {
    $ResetPassword = $false
    Write-Host "  Password reset: SKIPPED (WhatIfReport mode)" -ForegroundColor DarkGray
} else {
$resetAnswer = $null
while ($resetAnswer -notin @('Y','N')) {
    $resetAnswer = (Read-Host "  Do you want to reset the root account password on all hosts? [Y/N]").Trim().ToUpper()
    if ($resetAnswer -notin @('Y','N')) {
        Write-Host "  Please enter Y or N." -ForegroundColor Yellow
    }
}
$ResetPassword = ($resetAnswer -eq 'Y')

if ($ResetPassword) {
    Write-Host "  Password reset: ENABLED" -ForegroundColor Yellow
    Write-Host ""
    Write-Host "  New password must meet VCF 9 requirements:" -ForegroundColor Cyan
    Write-Host "    - 15 to 40 characters" -ForegroundColor DarkGray
    Write-Host "    - At least 1 lowercase letter" -ForegroundColor DarkGray
    Write-Host "    - At least 1 uppercase letter (not as the first character)" -ForegroundColor DarkGray
    Write-Host "    - At least 1 digit (not as the last character)" -ForegroundColor DarkGray
    Write-Host "    - At least 1 special character from: @ ! # `$ % ? ^" -ForegroundColor DarkGray
    Write-Host "    - Only letters, digits, and @ ! # `$ % ? ^ are permitted" -ForegroundColor DarkGray
    Write-Host "    - At least 3 of the 4 character classes must be present" -ForegroundColor DarkGray
    Write-Host ""

    $NewPassword       = $null
    $passwordCompliant = $false

    while (-not $passwordCompliant) {
        $NewPassword = Read-Host "  Enter NEW root password" -AsSecureString

        if ($NewPassword.Length -eq 0) {
            Write-Host "  Password cannot be empty. Please try again." -ForegroundColor Yellow
            continue
        }

        # Extract plaintext briefly for validation only, then clear immediately
        $plainForValidation = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto(
                                [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($NewPassword))
        $validation = Test-VCF9PasswordCompliance -Password $plainForValidation
        $plainForValidation = [string]::new('*', 16)
        Remove-Variable plainForValidation -ErrorAction SilentlyContinue

        if ($validation.Passed) {
            # Confirm entry to catch typos
            $NewPasswordConfirm = Read-Host "  Confirm NEW root password" -AsSecureString
            $plainConfirm = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto(
                                [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($NewPasswordConfirm))
            $plainOriginal = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto(
                                [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($NewPassword))
            $match = ($plainConfirm -ceq $plainOriginal)
            $plainConfirm  = [string]::new('*', 16)
            $plainOriginal = [string]::new('*', 16)
            Remove-Variable plainConfirm, plainOriginal -ErrorAction SilentlyContinue

            if ($match) {
                $passwordCompliant = $true
                Write-Host "  Password meets all VCF 9 requirements." -ForegroundColor Green
                Write-Host ""
            } else {
                Write-Host "  Passwords do not match. Please try again." -ForegroundColor Yellow
                Write-Host ""
            }
        } else {
            Write-Host ""
            Write-Host "  Password does not meet VCF 9 requirements:" -ForegroundColor Red
            foreach ($failure in $validation.Failures) {
                Write-Host "    x $failure" -ForegroundColor Yellow
            }
            Write-Host "  Please enter a new password." -ForegroundColor Cyan
            Write-Host ""
        }
    }

    # Track which hosts have already had their password reset this run.
    # Useful if the script is interrupted and re-run - the operator can
    # see in the log which hosts were already changed.
    $script:PasswordResetCompleted = [System.Collections.Generic.List[string]]::new()
} else {
    Write-Host "  Password reset: SKIPPED" -ForegroundColor DarkGray
}
} # end else (not WhatIfReport) for password prompt
Write-Host ""

#endregion
#region --- Host List Selection ---

$hostFilePath = $null
while (-not $hostFilePath) {
    $raw = (Read-Host "  Enter full path to the host list .txt file").Trim()

    # Strip surrounding quotes that Windows sometimes adds when copy-pasting paths
    $raw = $raw.Trim('"').Trim("'")

    if ([string]::IsNullOrWhiteSpace($raw)) {
        Write-Host "  Path cannot be empty. Please try again." -ForegroundColor Yellow
        continue
    }

    if (-not (Test-Path -LiteralPath $raw -PathType Leaf)) {
        Write-Host "  File not found: '$raw'" -ForegroundColor Yellow
        Write-Host "  Please check the path and try again." -ForegroundColor Yellow
        continue
    }

    $hostFilePath = $raw
}

$targetEsxiHosts = Get-Content -LiteralPath $hostFilePath |
    Where-Object { $_ -match '\S' -and $_ -notmatch '^\s*#' }

if (-not $targetEsxiHosts) {
    Write-Warning "Host list is empty. Exiting."
    Stop-Transcript
    exit 1
}

Write-Host "  Loaded $($targetEsxiHosts.Count) host(s) from: $hostFilePath" -ForegroundColor Cyan

#endregion
#region --- Per-Host Processing ---

$results = [System.Collections.Generic.List[PSCustomObject]]::new()

foreach ($esxiHost in $targetEsxiHosts) {

    $script:hostTimedOut = $false

    Write-Host ("`n" + ("=" * 60)) -ForegroundColor Cyan
    Write-Host ("  Processing host : $esxiHost") -ForegroundColor Cyan
    Write-Host ("  " + $ScriptMeta.Blog) -ForegroundColor DarkGray
    Write-Host ("=" * 60) -ForegroundColor Cyan

    $hostResult = [PSCustomObject]@{
        Host              = $esxiHost
        Connected         = $false
        DNS               = "Skipped"
        NTP               = "Skipped"
        AdvancedSettings  = "Skipped"
        OptionalSettings  = "Skipped"
        CertRegen         = "Skipped"
        Rebooted          = "Skipped"
        PasswordReset     = "Skipped"
        Thumbprint        = "N/A"
        Expiry            = "N/A"
        StorageType       = "N/A"
        Error             = ""
    }

    try {
        # --- DNS Validation (before connect, so issues are visible even if host is unreachable) ---
        Write-Host "`n  [DNS Validation]" -ForegroundColor Cyan
        if ($DryRun) {
            Write-Host "  [DRY RUN] Would validate forward and reverse DNS for $esxiHost." -ForegroundColor DarkYellow
            $hostResult.DNS = "OK"
        } else {
            $dnsCheck = Test-DNSResolution -VMHost $esxiHost
            $hostResult.DNS = $dnsCheck.Status
            if ($dnsCheck.Status -eq "OK") {
                Write-Host "  Forward : $($dnsCheck.Forward)" -ForegroundColor Green
                Write-Host "  Reverse : $($dnsCheck.Reverse)" -ForegroundColor Green
                Write-Host "  DNS OK -- forward and reverse match." -ForegroundColor Green
            } elseif ($dnsCheck.Status -eq "FAILED") {
                Write-Host "  Forward lookup failed for $esxiHost." -ForegroundColor Red
                Write-Host "  ACTION REQUIRED: Ensure an A record exists for this host." -ForegroundColor Red
            } else {
                Write-Host "  Forward : $($dnsCheck.Forward)" -ForegroundColor Yellow
                Write-Host "  Reverse : $($dnsCheck.Reverse)" -ForegroundColor Yellow
                Write-Host "  WARNING: $($dnsCheck.Status)" -ForegroundColor Yellow
                Write-Host "  ACTION REQUIRED: Fix PTR record before commissioning." -ForegroundColor Yellow
            }
        }

        # --- Connect ---
        Write-Host "`n  [Connect]" -ForegroundColor Cyan
        if ($DryRun) {
            Write-Host "`n  [DRY RUN] Would connect to $esxiHost as 'root'." -ForegroundColor DarkYellow
            $hostResult.Connected = $true
        } else {
            Connect-VIServer -Server $esxiHost -Credential $esxiCredentials -ErrorAction Stop | Out-Null
            $hostResult.Connected = $true
            Write-Host "  Connected to $esxiHost." -ForegroundColor Green
            $vmHostObj = Get-VMHost -Name $esxiHost -ErrorAction Stop

            # Detect storage type immediately after connect while session is live
            Write-Host "`n  [Storage Detection]" -ForegroundColor Cyan
            $hostResult.StorageType = Get-ESXiStorageType -VMHostObj $vmHostObj
        }

        # --- WhatIfReport: cert/thumbprint read only, skip all other steps ---
        if ($WhatIfReport) {
            Write-Host "`n  [WhatIfReport] Reading certificate..." -ForegroundColor Cyan
            $certCheck = Test-ESXiCertificateNeedsRegen -VMHost $esxiHost
            $hostResult.Thumbprint = $certCheck.Thumbprint
            $hostResult.Expiry     = $certCheck.Expiry
            $hostResult.CertRegen  = if ($certCheck.NeedsRegen) { "Regen needed" } else { "OK" }
            Write-Host "  Thumbprint : $($certCheck.Thumbprint)" -ForegroundColor DarkGray
            Write-Host "  CN         : $($certCheck.CN)"         -ForegroundColor DarkGray
            Write-Host "  Expiry     : $($certCheck.Expiry)"     -ForegroundColor DarkGray
            # Skip all remaining steps  --  fall through to finally for clean disconnect
        } else {

        # --- NTP ---
        Write-Host "`n  [NTP]" -ForegroundColor Cyan
        try {
            if ($DryRun) {
                Write-Host "  [DRY RUN] Would verify/add NTP server(s): $($NtpServers -join ', ')." -ForegroundColor DarkYellow
                Write-Host "  [DRY RUN] Would ensure ntpd policy=on and service running." -ForegroundColor DarkYellow
            } else {
                $currentNtp     = @(Get-VMHostNtpServer -VMHost $vmHostObj)
                $missingServers = $NtpServers | Where-Object { $_ -notin $currentNtp }

                if ($missingServers) {
                    Write-Host "  Adding missing NTP server(s): $($missingServers -join ', ')" -ForegroundColor Yellow
                    Add-VMHostNtpServer -VMHost $vmHostObj -NtpServer $missingServers -Confirm:$false -ErrorAction Stop | Out-Null
                } else {
                    Write-Host "  All required NTP server(s) already configured." -ForegroundColor Green
                }

                Set-VMHostServiceConfig -VMHost $vmHostObj -ServiceKey "ntpd"
            }
            $hostResult.NTP = "OK"
        } catch {
            $hostResult.NTP = "FAILED: $_"
            Write-Warning "  NTP configuration failed: $_"
        }

        # --- Advanced Settings (SDDC Manager) ---
        Write-Host "`n  [Advanced Settings]" -ForegroundColor Cyan
        try {
            if ($DryRun) {
                Write-Host "  [DRY RUN] Would set 'Config.HostAgent.ssl.keyStore.allowSelfSigned' = True" -ForegroundColor DarkYellow
            } else {
                Get-AdvancedSetting -Entity $vmHostObj -Name "Config.HostAgent.ssl.keyStore.allowSelfSigned" |
                    Set-AdvancedSetting -Value $true -Confirm:$false | Out-Null
                Write-Host "  Set 'Config.HostAgent.ssl.keyStore.allowSelfSigned' = True" -ForegroundColor Green
            }
            $hostResult.AdvancedSettings = "OK"
        } catch {
            $hostResult.AdvancedSettings = "FAILED: $_"
            Write-Warning "  Advanced settings failed: $_"
        }

        # --- Optional Advanced Settings ---
        $enabledOptional = $OptionalAdvancedSettings | Where-Object { $_.Enabled -eq $true }
        if ($enabledOptional) {
            Write-Host "`n  [Optional Advanced Settings]" -ForegroundColor Cyan
            $optionalFailures = [System.Collections.Generic.List[string]]::new()

            foreach ($setting in $enabledOptional) {
                try {
                    if ($DryRun) {
                        Write-Host "  [DRY RUN] Would set '$($setting.Name)' = $($setting.Value)  ($($setting.Label))" -ForegroundColor DarkYellow
                    } else {
                        Get-AdvancedSetting -Entity $vmHostObj -Name $setting.Name |
                            Set-AdvancedSetting -Value $setting.Value -Confirm:$false | Out-Null
                        Write-Host "  Set '$($setting.Name)' = $($setting.Value)  ($($setting.Label))" -ForegroundColor Green
                    }
                } catch {
                    $msg = "$($setting.Label): $_"
                    $optionalFailures.Add($msg)
                    Write-Warning "  Failed to set '$($setting.Name)': $_"
                }
            }

            $hostResult.OptionalSettings = if ($optionalFailures.Count -eq 0) {
                "OK"
            } elseif ($optionalFailures.Count -lt @($enabledOptional).Count) {
                "Partial"
            } else {
                "FAILED"
            }
        }

        # --- Certificate Regeneration ---
        Write-Host "`n  [Certificate Regeneration]" -ForegroundColor Cyan
        try {
            if ($DryRun) {
                Write-Host "  [DRY RUN] Would check if certificate CN matches hostname." -ForegroundColor DarkYellow
                Write-Host "  [DRY RUN] Would regenerate host certificate if needed." -ForegroundColor DarkYellow
                Write-Host "  [DRY RUN] Would reboot host and wait for it to come back online." -ForegroundColor DarkYellow
                $hostResult.CertRegen = "OK"
                $hostResult.Rebooted  = "OK"
            } elseif (-not $script:PoshSSHAvailable) {
                Write-Host "  Posh-SSH not available. Certificate regeneration skipped." -ForegroundColor Yellow
                Write-Host "  ACTION REQUIRED: Manually run on this host and then reboot:" -ForegroundColor Yellow
                Write-Host "    /sbin/generate-certificates" -ForegroundColor Cyan
                $hostResult.CertRegen = "Manual"
                $hostResult.Rebooted  = "Manual"
            } else {
                $certCheck = Test-ESXiCertificateNeedsRegen -VMHost $esxiHost
                $hostResult.Thumbprint = $certCheck.Thumbprint
                $hostResult.Expiry     = $certCheck.Expiry

                if (-not $certCheck.NeedsRegen) {
                    $hostResult.CertRegen = "Skipped"
                    $hostResult.Rebooted  = "Skipped"
                } else {
                    $certRegenSuccess = Invoke-ESXiCertificateRegen `
                        -VMHost     $esxiHost `
                        -VMHostObj  $vmHostObj `
                        -Credential $esxiCredentials

                    if ($certRegenSuccess) {
                        $hostResult.CertRegen = "OK"

                        # Disconnect cleanly before reboot
                        Disconnect-VIServer -Server $esxiHost -Confirm:$false -ErrorAction SilentlyContinue
                        Write-Host "  Disconnected. Initiating reboot of $esxiHost..." -ForegroundColor Yellow

                        # Reconnect temporarily to issue the reboot command
                        Connect-VIServer -Server $esxiHost -Credential $esxiCredentials -ErrorAction Stop | Out-Null
                        $rebootHostObj = Get-VMHost -Name $esxiHost -ErrorAction Stop
                        Restart-VMHost -VMHost $rebootHostObj -Confirm:$false -Force -ErrorAction Stop | Out-Null
                        Disconnect-VIServer -Server $esxiHost -Confirm:$false -ErrorAction SilentlyContinue
                        Write-Host "  Reboot issued. Waiting for host to come back online..." -ForegroundColor Yellow

                        # Wait for the host to come back (throws on timeout)
                        Wait-ESXiHostOnline -VMHost $esxiHost
                        $hostResult.Rebooted = "OK"

                        # Reconnect for remaining steps (password reset)
                        Write-Host "  Reconnecting to $esxiHost..." -ForegroundColor Cyan
                        Connect-VIServer -Server $esxiHost -Credential $esxiCredentials -ErrorAction Stop | Out-Null
                        $vmHostObj = Get-VMHost -Name $esxiHost -ErrorAction Stop
                        Write-Host "  Reconnected to $esxiHost." -ForegroundColor Green

                        # Re-read thumbprint from the newly regenerated certificate
                        Write-Host "  Reading new certificate thumbprint..." -ForegroundColor Cyan
                        $newCertCheck = Test-ESXiCertificateNeedsRegen -VMHost $esxiHost
                        $hostResult.Thumbprint = $newCertCheck.Thumbprint
                        $hostResult.Expiry     = $newCertCheck.Expiry
                    }
                }
            }
        } catch {
            # Distinguish a reboot timeout from other cert regen failures
            if ($_ -match "Timed out waiting") {
                $hostResult.CertRegen = "OK"       # regen itself succeeded
                $hostResult.Rebooted  = "Timeout"  # host never came back
                $hostResult.Error     = "Host did not come back online after reboot within the timeout period. Check the host console for hardware or boot errors."
                $script:hostTimedOut  = $true
                Write-Host ""
                Write-Host ("  " + ("!" * 58)) -ForegroundColor Red
                Write-Host "  !! REBOOT TIMEOUT: $esxiHost did not come back online !!" -ForegroundColor Red
                Write-Host "  !! Check the host console for hardware or boot errors. !!" -ForegroundColor Red
                Write-Host ("  " + ("!" * 58)) -ForegroundColor Red
                Write-Host ""
            } else {
                $hostResult.CertRegen = "FAILED: $_"
                Write-Warning "  Certificate regeneration/reboot failed: $_"
            }
        }

        # --- Password Reset (always last) ---
        if ($ResetPassword) {
            Write-Host "`n  [Password Reset]" -ForegroundColor Cyan
            try {
                if ($DryRun) {
                    Write-Host "  [DRY RUN] Would reset password for 'root'." -ForegroundColor DarkYellow
                    $hostResult.PasswordReset = "OK"
                } else {
                    Reset-ESXiAccountPassword `
                        -VMHost            $vmHostObj `
                        -NewPassword       $NewPassword `
                        -ConnectedUsername "root"
                    $hostResult.PasswordReset = "OK"
                }
            } catch {
                $hostResult.PasswordReset = "FAILED: $_"
                Write-Warning "  Password reset failed: $_"
            }
        }

        } # end else (not WhatIfReport)

    } catch {
        $hostResult.Error = $_.Exception.Message
        Write-Warning "  Failed to process host '$esxiHost': $_"
    } finally {
        if ($hostResult.Connected -and -not $DryRun) {
            if ($script:hostTimedOut) {
                # Host never came back  --  skip disconnect, it will just throw a noisy error
                Write-Host "`n  Host is unreachable  --  skipping disconnect." -ForegroundColor DarkGray
            } else {
                Disconnect-VIServer -Server $esxiHost -Confirm:$false -ErrorAction SilentlyContinue
                Write-Host "`n  Disconnected from $esxiHost." -ForegroundColor Gray
            }
        } elseif ($DryRun) {
            Write-Host "`n  [DRY RUN] Would disconnect from $esxiHost." -ForegroundColor DarkYellow
        }
    }

    $results.Add($hostResult)
}

#endregion

#region --- Summary ---

# Derive summary banner width from column definitions (matches Write-ColorSummaryTable divider)
$summaryColumnWidths = @(34, 11, 14, 6, 17, 17, 10, 10, 15, 28)
$summaryWidth = ($summaryColumnWidths | Measure-Object -Sum).Sum + ($summaryColumnWidths.Count * 3) + 1


Write-Host ""
Write-Host ("=" * $summaryWidth) -ForegroundColor DarkCyan
Write-Host ("  SUMMARY  -  {0} host(s) processed  --  {1}" -f $results.Count, $ScriptMeta.Blog) -ForegroundColor Cyan
Write-Host ("=" * $summaryWidth) -ForegroundColor DarkCyan

Write-ColorSummaryTable -Data $results

# Legend
Write-Host ""
Write-Host "  Legend: " -NoNewline -ForegroundColor White
Write-Host "OK  "      -NoNewline -ForegroundColor Green
Write-Host "FAILED  "  -NoNewline -ForegroundColor Red
Write-Host "Timeout  " -NoNewline -ForegroundColor Red
Write-Host "Skipped  " -NoNewline -ForegroundColor DarkGray
Write-Host "Manual  "  -NoNewline -ForegroundColor Yellow
Write-Host "Partial  " -NoNewline -ForegroundColor Yellow
Write-Host "Warning"               -ForegroundColor Yellow
Write-Host ""
Write-Host ("  Log written to    : {0}" -f $LogPath) -ForegroundColor DarkGray

Write-HtmlReport -Data $results -ReportPath $ReportPath

# Export commissioning CSV for use by Commission-VCFHosts.ps1
# Only includes hosts that connected successfully and have a valid thumbprint
$csvRows = $results | Where-Object { $_.Connected -eq $true -and $_.Thumbprint -ne "N/A" } |
    Select-Object `
        @{ Name = "FQDN";        Expression = { $_.Host } },
        @{ Name = "Thumbprint";  Expression = { $_.Thumbprint } },
        @{ Name = "StorageType"; Expression = { $_.StorageType } }

if ($csvRows) {
    $csvRows | Export-Csv -Path $CsvPath -NoTypeInformation -Encoding UTF8
    Write-Host ("  Commissioning CSV : {0}" -f $CsvPath) -ForegroundColor Cyan
    Write-Host ("  {0} host(s) exported to CSV." -f @($csvRows).Count) -ForegroundColor DarkGray
} else {
    Write-Host "  No hosts with valid thumbprints  --  CSV not written." -ForegroundColor Yellow
}

Write-Host ("=" * $summaryWidth) -ForegroundColor DarkCyan
Write-Host ""

Stop-Transcript

#endregion
