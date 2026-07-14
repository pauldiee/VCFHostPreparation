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
         vs ESA cannot be auto-detected on unclaimed hosts -- edit the
         StorageType column in the CSV before running Commission-VCFHosts.ps1
         if VSAN_ESA or VVOL is intended
      6b. vSAN disk wipe (optional, -WipeDisk only)  --  enumerates non-boot
         disks with existing partitions and wipes them via partedUtil over SSH,
         preparing disks for clean vSAN commissioning. Requires the Windows
         OpenSSH client (ssh.exe). Boot disk is always excluded. Skipped for
         VMFS_FC and NFS hosts.
      7. Certificate regeneration  --  check CN vs FQDN; if mismatched, enable
         SSH temporarily, run /sbin/generate-certificates via the built-in
         OpenSSH client, disable SSH, reboot, and wait for the host to return
         online. If the host's own configured hostname disagrees with the host
         list, offer to correct it first (Y/N per host)  --  generate-certificates
         derives the CN from that hostname, so regenerating without fixing it
         would reproduce the same wrong CN
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
    disks are unclaimed at commissioning time. If VSAN_ESA or VVOL is intended,
    edit the StorageType column in the generated CSV before running
    Commission-VCFHosts.ps1. That script reads the CSV value as-is without
    prompting.

    Optional Advanced Settings
    --------------------------
    Near the top of the script, the $DefaultOptionalAdvancedSettings block
    contains extra settings that are disabled by default. Set Enabled = $true
    to apply:

      - Config.HostAgent.plugins.hostsvc.esxAdminsGroup (string)
          AD group whose members receive full ESXi admin access.
          Default: "ESX Admins"  --  change to match your AD group name.

      - LSOM.lsomEnableRebuildOnLSE (integer, 1/0)
          Enables vSAN automatic rebuild when a device is flagged as LSE.

      - DataMover.HardwareAcceleratedMove / HardwareAcceleratedInit (integer, 1/0)
          Enables SSD TRIM so ESXi issues UNMAP commands to compatible SSDs.

    These settings can also be supplied from an external file placed next to
    the script, instead of editing $DefaultOptionalAdvancedSettings in the
    script body:

      - HostPrep.Settings.json  (checked first)
      - HostPrep.Settings.psd1  (checked if the .json file is not found)

    If neither file is present, or a file fails to parse, the script falls
    back to $DefaultOptionalAdvancedSettings. See Get-OptionalAdvancedSettings
    for the loader and the expected file schema for each format.

    Host List File
    --------------
    A plain text file with one ESXi FQDN per line. Lines starting with # are
    treated as comments and ignored. Surrounding quotes on the path are stripped
    automatically when pasted.

    Prerequisites
    -------------
    One-time PowerCLI setup (run once per user account):

        Set-PowerCLIConfiguration -Scope User -ParticipateInCEIP $false -Confirm:$false

    The Windows OpenSSH client (ssh.exe, standard on Windows 10 1809+ and
    Windows 11) is required for automated certificate regeneration and
    -WipeDisk. If it is missing, install the optional feature:

        Add-WindowsCapability -Online -Name OpenSSH.Client~~~~0.0.1.0

    SSH authenticates with the root password through ssh.exe's SSH_ASKPASS
    helper (no external module, no key setup). ESXi 9 removed the HTTPS
    endpoint earlier versions used to install a public key, so password auth
    over the built-in client is used instead. Without the OpenSSH client the
    script will print per-host manual instructions for the certificate and
    disk wipe steps instead of failing.

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
    One or more NTP server addresses. If omitted, the script prompts for the
    server(s) before any host is touched, offering 'pool.ntp.org' as the
    default that Enter accepts. Supply this parameter to run unattended
    without the prompt.

.PARAMETER LogPath
    Path to write the log file. Defaults to the script directory.

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

.PARAMETER WipeDisk
    Enumerates non-boot disks with existing partitions on each VSAN host and
    wipes their partition tables via SSH using partedUtil, preparing them for
    clean vSAN commissioning. Requires the Windows OpenSSH client. Without it
    the script prints manual SSH instructions per host instead of failing.
    Boot disk is always excluded unconditionally.
    Skipped for hosts detected as VMFS_FC or NFS.

.EXAMPLE
    .\HostPrep.ps1

.EXAMPLE
    .\HostPrep.ps1 -NtpServers "ntp1.example.com","ntp2.example.com"

.EXAMPLE
    .\HostPrep.ps1 -DryRun

.EXAMPLE
    .\HostPrep.ps1 -WhatIfReport

.EXAMPLE
    .\HostPrep.ps1 -WipeDisk

.EXAMPLE
    .\HostPrep.ps1 -WipeDisk -DryRun

.NOTES
    Script  : HostPrep.ps1
    Version : 4.4.0
    Author  : Paul van Dieen
    Blog    : https://www.hollebollevsan.nl
    Date    : 2026-07-14

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
                on unclaimed hosts -- edit StorageType in the CSV to
                VSAN_ESA or VVOL if needed before running
                Commission-VCFHosts.ps1; detected type written per-host
                to the commissioning CSV
        3.7.0 - Replaced Start/Stop-Transcript with Write-Log: timestamped
                INFO/WARN/ERROR entries written to the log file; all
                Write-Host and Write-Warning calls converted to Write-Log;
                log file defaults to script directory (same as report and
                CSV); -NoNewline console-only calls produce no log entry
        3.7.1 - After cert regen and reboot, re-check CN vs FQDN; if still
                mismatched set CertRegen to "CN mismatch" with a WARN log
                entry and highlight it in red in the HTML report
        3.7.2 - CN mismatch after cert regen now marks the host as not ready:
                red in the console summary table, red in the HTML report,
                and overall row status set to warn so the host is not shown
                as successful (VCF will not accept a mismatched CN)
        3.7.3 - Before cert regen, compare ESXi configured hostname (via
                Get-VMHostNetwork) to the FQDN from the hosts file; if they
                differ, skip regen and flag as CN mismatch immediately --
                generate-certificates uses the host's own hostname so regen
                would produce the same wrong CN and the reboot is wasted
        3.7.4 - CN mismatch (both pre-regen hostname check and post-regen
                verify) now sets $hostResult.Error so the host shows as
                failed (red) in the console and HTML report
        4.0.0 - Added -WipeDisk switch and Invoke-VSANDiskWipe helper:
                enumerates non-boot disks with existing partitions via
                esxcli, prompts Y/N per host, wipes partition tables via
                partedUtil over SSH; boot disk excluded unconditionally
                via IsBootDrive flag with size-heuristic fallback; VMFS
                datastores on target disks are unmounted before wipe;
                falls back to manual SSH instructions when Posh-SSH is
                unavailable; DiskWipe column added to summary table and
                HTML report; Get-CellColor updated to match Skipped*
        4.0.1 - VMFS unmount in Invoke-VSANDiskWipe switched from PowerCLI
                (Get-Datastore/Remove-Datastore) to SSH via esxcli storage
                filesystem unmount; no vCenter connection required; SSH
                session opened before unmount and reused for the wipe
        4.0.2 - All Write-Host/Write-Warning calls in Invoke-VSANDiskWipe
                converted to Write-Log; per-device partition count logged
                during enumeration; VMFS extent matches logged per disk;
                full wipe flow now captured in the log file
        4.0.3 - Fixed boot disk size heuristic: esxcli returns Size as a
                string; cast to [long] before -le comparison to prevent
                lexicographic false-positives (e.g. "512000" -le "8192"
                evaluated true)
        4.0.4 - Replaced size heuristic with layered boot detection: Layer 2
                (system.boot.device.get), Layer 3 (IsRemovable fallback);
                warning logged if boot device cannot be identified
        4.0.5 - Added Layer 2b (system.coredump.partition.get) and Layer 2c
                (OSDATA-* VMFS volume -- always present on ESXi boot disk,
                no SSH required); added Layer 4 SSH /proc/mounts probe
                inside the wipe session as a final safety net
        4.0.6 - Layer 4 /proc/mounts retroactively removes boot disk from
                wipe candidate list if missed by Layers 1-3; aborts cleanly
                if no candidates remain after removal
        4.0.7 - Fixed Layer 4 SSH command: replaced awk (broken PowerShell
                string escaping) with grep ' /bootbank ' /proc/mounts
        4.0.8 - Fixed VMFS unmount command: corrected namespace from
                esxcli storage vmfs unmount to esxcli storage filesystem
                unmount -l <label>
        4.0.9 - Removed diagnostic/debug logging from Invoke-VSANDiskWipe;
                boot detection layers log only on success or actionable
                warning; VMFS unmount list logged once at collection time
        4.1.0 - Replaced Posh-SSH with the built-in Windows OpenSSH client
                (ssh.exe): a throwaway ed25519 keypair is generated once per
                run, the public key is installed per host via HTTPS PUT to
                /host/ssh_root_authorized_keys and removed again after the
                host's SSH steps, commands run via ssh.exe with a temp
                known_hosts file, and the keypair is deleted at end of run.
                No external module dependencies remain. (GitHub issue #3)
        4.1.1 - ESXi 9 removed the /host/ssh_root_authorized_keys endpoint, so
                the HTTPS key-install (used by cert regen and -WipeDisk) failed
                with 404. Replaced key auth with root-password auth over the
                same built-in ssh.exe via SSH_ASKPASS (keyboard-interactive);
                ssh-keygen and the HTTPS PUT are gone. Still no external
                module dependencies. (GitHub issue #3)
        4.2.0 - Optional advanced settings can now be supplied externally:
                added Get-OptionalAdvancedSettings, which loads
                HostPrep.Settings.json (preferred) or HostPrep.Settings.psd1
                (fallback) from the script directory, falling back to the
                built-in $DefaultOptionalAdvancedSettings if neither file is
                present or parsing fails; added matching .example template
                files
        4.3.0 - NTP servers are now confirmed interactively when -NtpServers is
                not supplied, instead of silently applying the pool.ntp.org
                parameter default to every host. Passing -NtpServers still runs
                unattended. (GitHub issue #6)
              - Added a PowerCLI preflight check: if VMware.VimAutomation.Core
                is not installed the script now exits immediately with the
                install command, instead of erroring on every PowerCLI cmdlet
                and still prompting for the host list, NTP servers and root
                password before failing at Connect-VIServer.
        4.4.0 - Certificate regeneration no longer just skips a host whose
                configured hostname disagrees with the host list: added
                Repair-ESXiHostname, which prompts Y/N and sets the ESXi
                hostname/domain from the host list via Set-VMHostNetwork,
                verifies the change, then continues into regeneration. The regen
                reboot covers the rename too. Declining keeps the old behaviour
                (skip, flag CN mismatch). Hosts taking DNS from DHCP are
                detected up front: ESXi ignores a hostname set while DHCP is in
                charge, so the script explains that and points at the static-DNS
                setting instead of silently failing. (GitHub issue #8)
#>

[CmdletBinding()]
param (
    [string[]]$NtpServers = @("pool.ntp.org"),

    [switch]$DryRun,

    [switch]$WhatIfReport,

    [string]$LogPath = [System.IO.Path]::Combine(
        $PSScriptRoot,
        "HostPrep_$(Get-Date -Format 'yyyyMMdd_HHmmss').log"
    ),

    [string]$ReportPath = [System.IO.Path]::Combine(
        $PSScriptRoot,
        "HostPrep_$(Get-Date -Format 'yyyyMMdd_HHmmss')_Report.html"
    ),

    [string]$CsvPath = [System.IO.Path]::Combine(
        $PSScriptRoot,
        "HostPrep_$(Get-Date -Format 'yyyyMMdd_HHmmss')_Commissioning.csv"
    ),

    # Enumerate non-boot disks with existing partitions on each VSAN host and
    # wipe them via partedUtil over SSH. Requires the Windows OpenSSH client.
    # Boot disk is always excluded. Skipped for VMFS_FC and NFS hosts.
    [switch]$WipeDisk
)

#region --- Script Metadata ---

$ScriptMeta = @{
    Name    = "HostPrep.ps1"
    Version = "4.4.0"
    Author  = "Paul van Dieen"
    Blog    = "https://www.hollebollevsan.nl"
    Date    = "2026-07-14"
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
# These are the built-in defaults, used only when neither HostPrep.Settings.json
# nor HostPrep.Settings.psd1 is found next to the script (see
# Get-OptionalAdvancedSettings in the Helper Functions region).
#
$DefaultOptionalAdvancedSettings = @(

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

#region --- Logging ---

function Write-Log {
    <#
    .SYNOPSIS
        Writes a timestamped, levelled log entry to both the log file and the console.
    .PARAMETER Message
        The message to log. Empty strings produce a blank console line only (no file entry).
    .PARAMETER Level
        INFO (default), WARN, or ERROR.
    .PARAMETER Color
        Explicit console colour override. If omitted, defaults to Cyan (INFO), Yellow (WARN), Red (ERROR).
    .PARAMETER NoNewline
        Passes -NoNewline to Write-Host. No log file entry is written for partial lines.
    #>
    param(
        [string]$Message = "",
        [ValidateSet('INFO','WARN','ERROR')]
        [string]$Level = 'INFO',
        [System.ConsoleColor]$Color,
        [switch]$NoNewline
    )

    # Only write complete, non-empty lines to the log file
    if (-not $NoNewline -and $Message -ne "") {
        $ts = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
        "[{0}] {1,-5}  {2}" -f $ts, $Level, $Message.TrimStart() |
            Add-Content -Path $script:LogPath -Encoding UTF8
    }

    # Console colour: explicit -Color > level default
    $consoleColor = if ($PSBoundParameters.ContainsKey('Color')) {
        $Color
    } else {
        switch ($Level) {
            'ERROR' { [System.ConsoleColor]::Red    }
            'WARN'  { [System.ConsoleColor]::Yellow }
            default { [System.ConsoleColor]::Cyan   }
        }
    }

    Write-Host $Message -ForegroundColor $consoleColor -NoNewline:$NoNewline
}

#endregion

#region --- Initialisation ---

# PowerCLI is a hard dependency  --  every host operation runs through it. Check
# for it before anything else: without this the missing cmdlets surface as a wall
# of "not recognized" errors and the script carries on to prompt for the host
# list, NTP servers and the root password before finally dying at Connect-VIServer.
#
# Deliberately uses Write-Host rather than Write-Log: the log file is created
# further down, and this check must run before the Get-PowerCLIConfiguration
# calls immediately below.
if (-not (Get-Module -ListAvailable -Name VMware.VimAutomation.Core)) {
    Write-Host ""
    Write-Host "  ERROR: VMware PowerCLI was not found." -ForegroundColor Red
    Write-Host "  HostPrep needs it to connect to the ESXi hosts and cannot continue." -ForegroundColor Red
    Write-Host ""
    Write-Host "  Install it for the current user (no admin rights required):" -ForegroundColor Yellow
    Write-Host "    Install-Module -Name VMware.PowerCLI -Scope CurrentUser" -ForegroundColor Yellow
    Write-Host ""
    Write-Host ("  This session is PowerShell {0} ({1}). PowerCLI must be installed for the" -f $PSVersionTable.PSVersion, $PSVersionTable.PSEdition) -ForegroundColor DarkGray
    Write-Host "  same edition you run HostPrep with  --  a copy installed under Windows" -ForegroundColor DarkGray
    Write-Host "  PowerShell 5.1 is not visible to PowerShell 7, and vice versa." -ForegroundColor DarkGray
    Write-Host ""
    exit 1
}

# Suppress PowerCLI CEIP nag. The warning fires on first module load in any
# new session, so we persist the opt-out to the User scope once and silently
# apply it to the current session. After the first run it will never appear.
$ceipConfig = Get-PowerCLIConfiguration -Scope User -WarningAction SilentlyContinue
if ($null -eq $ceipConfig.ParticipateInCEIP) {
    Set-PowerCLIConfiguration -Scope User -ParticipateInCEIP $false -Confirm:$false -WarningAction SilentlyContinue | Out-Null
}
Set-PowerCLIConfiguration -Scope Session -ParticipateInCEIP $false -InvalidCertificateAction Ignore -Confirm:$false -WarningAction SilentlyContinue | Out-Null

$bannerWidth = 62

# Initialise log file with a session header
"[{0}] {1,-5}  {2} v{3} -- Session started" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), "INFO", $ScriptMeta.Name, $ScriptMeta.Version |
    Out-File -FilePath $LogPath -Encoding UTF8

Write-Log ""
Write-Log ("=" * $bannerWidth) -Color DarkCyan
Write-Log ("  {0,-30} {1}" -f $ScriptMeta.Name, ("v" + $ScriptMeta.Version))
Write-Log ("  Author : {0}" -f $ScriptMeta.Author)
Write-Log ("  Blog   : {0}" -f $ScriptMeta.Blog)
Write-Log ("  Date   : {0}" -f $ScriptMeta.Date) -Color DarkGray
Write-Log ("=" * $bannerWidth) -Color DarkCyan
Write-Log ""

if ($DryRun) {
    Write-Log "  *** DRY RUN MODE - No changes will be made ***" -Level WARN
    Write-Log ("  " + $ScriptMeta.Blog) -Color DarkGray
    Write-Log ""
}

if ($WipeDisk) {
    Write-Host "  *** DISK WIPE MODE ENABLED -- non-boot partitioned disks will be wiped ***" -ForegroundColor Red
    Write-Host "  Only applies to hosts detected as VSAN storage type." -ForegroundColor Yellow
    Write-Host "  Boot disk is always excluded." -ForegroundColor Yellow
    if ($DryRun) {
        Write-Host "  (DryRun is active -- no actual wipes will occur)" -ForegroundColor DarkYellow
    }
    Write-Host ""
}

if ($WhatIfReport) {
    Write-Log "  *** WHATIF REPORT MODE - Thumbprint collection only ***"
    Write-Log "  Connects to each host, reads certificate thumbprint and expiry," -Color DarkGray
    Write-Log "  then generates the HTML report. No changes will be made." -Color DarkGray
    Write-Log ("  " + $ScriptMeta.Blog) -Color DarkGray
    Write-Log ""
}

# Mutual exclusion guard -- only one mode at a time
if ($DryRun -and $WhatIfReport) {
    Write-Log "  ERROR: -DryRun and -WhatIfReport are mutually exclusive. Specify one at a time." -Level ERROR
    exit 1
}

Write-Log "HostPrep started at $(Get-Date)"

# Verify the Windows OpenSSH client is available (needed for cert regen and
# -WipeDisk  --  not relevant in WhatIfReport mode)
$script:SSHClientAvailable = $false
$script:HostPrepSSHAuth    = $null
if (-not $WhatIfReport) {
    if (-not (Get-Command ssh.exe -ErrorAction SilentlyContinue)) {
        Write-Log ""
        Write-Log "  WARNING: The Windows OpenSSH client (ssh.exe) was not found." -Level WARN
        Write-Log "  Certificate regeneration and disk wipe will be skipped for all hosts." -Level WARN
        Write-Log "  To enable it, install the 'OpenSSH Client' optional Windows feature:" -Level WARN
        Write-Log "    Add-WindowsCapability -Online -Name OpenSSH.Client~~~~0.0.1.0" -Level WARN
        Write-Log ""
    } else {
        $script:SSHClientAvailable = $true
    }
}

# Required for HTML entity encoding in the commissioning report
Add-Type -AssemblyName System.Web

# Trust-all certificate callback for direct HTTPS calls to ESXi hosts (their
# certs are self-signed at prep time). Compiled once per session; scriptblock
# delegates are not reliable as TLS callbacks in Windows PowerShell.
if (-not ("HostPrepTls" -as [type])) {
    Add-Type -TypeDefinition @"
using System.Net.Security;
public static class HostPrepTls
{
    public static readonly RemoteCertificateValidationCallback TrustAll =
        (sender, certificate, chain, sslPolicyErrors) => true;
}
"@
}

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

        Write-Log "  Certificate CN  : $cn" -Color DarkGray
        Write-Log "  Host FQDN       : $VMHost" -Color DarkGray
        Write-Log "  Expires         : $expiry" -Color DarkGray
        Write-Log "  SHA256:base64   : $thumbprint" -Color DarkGray

        $needsRegen = $cn -ne $VMHost
        if ($needsRegen) {
            Write-Log "  CN does not match hostname. Regeneration needed." -Level WARN
        } else {
            Write-Log "  CN matches hostname. Regeneration not needed." -Color Green
        }

        return [PSCustomObject]@{
            NeedsRegen  = $needsRegen
            Thumbprint  = $thumbprint
            CN          = $cn
            Expiry      = $expiry
        }

    } catch {
        Write-Log "  Could not read certificate from $VMHost port 443: $_" -Level WARN
        Write-Log "  Proceeding with regeneration to be safe." -Level WARN
        return [PSCustomObject]@{
            NeedsRegen  = $true
            Thumbprint  = "N/A"
            CN          = "N/A"
            Expiry      = "N/A"
        }
    }
}

function Get-HostPrepSSHAuth {
    <#
    .SYNOPSIS
        Returns this run's SSH askpass helper, creating it on first use.

    .DESCRIPTION
        ESXi 9 removed the /host/ssh_root_authorized_keys HTTPS endpoint that
        earlier versions used to install a public key, so SSH authenticates
        with the root password instead. The built-in OpenSSH client (ssh.exe)
        reads the password from an SSH_ASKPASS helper: a small .cmd that prints
        a password file. Both live in a run-specific temp folder alongside a
        temp known_hosts file so host keys never pollute the user's
        ~/.ssh/known_hosts. The folder is deleted at the end of the run.

        The password never appears on the command line or in the process list;
        it sits only in the temp password file for the duration of the run.
        The same helper is reused for every host in the run.

    .PARAMETER Credential
        PSCredential for the root account whose password drives the SSH login.

    .OUTPUTS
        PSCustomObject with:
          .KeyDir         [string] - temp folder holding all SSH material
          .AskPassPath    [string] - SSH_ASKPASS helper (.cmd) path
          .KnownHostsPath [string] - temp known_hosts file for this run
    #>
    param (
        [Parameter(Mandatory)][System.Management.Automation.PSCredential]$Credential
    )

    if ($script:HostPrepSSHAuth) { return $script:HostPrepSSHAuth }

    $keyDir = Join-Path ([System.IO.Path]::GetTempPath()) ("HostPrep_ssh_" + [guid]::NewGuid().ToString("N"))
    New-Item -ItemType Directory -Path $keyDir -Force | Out-Null
    $pwFile      = Join-Path $keyDir "pw"
    $askPassPath = Join-Path $keyDir "askpass.cmd"

    # Password file: raw bytes, no BOM, single trailing newline. The askpass
    # .cmd simply 'type's it, so special characters in the password are emitted
    # verbatim (cmd never parses the password itself).
    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($pwFile, ($Credential.GetNetworkCredential().Password + "`n"), $utf8NoBom)
    [System.IO.File]::WriteAllText($askPassPath, ("@type `"{0}`"`r`n" -f $pwFile), $utf8NoBom)

    $script:HostPrepSSHAuth = [PSCustomObject]@{
        KeyDir         = $keyDir
        AskPassPath    = $askPassPath
        KnownHostsPath = (Join-Path $keyDir "known_hosts")
    }
    Write-Log "  Prepared temporary SSH credential helper for this run." -Color DarkGray
    return $script:HostPrepSSHAuth
}

function Invoke-ESXiSSHCommand {
    <#
    .SYNOPSIS
        Runs a single command on an ESXi host using the built-in OpenSSH
        client (ssh.exe), authenticating with the root password via SSH_ASKPASS.

    .DESCRIPTION
        ESXi's sshd offers keyboard-interactive (not password) authentication,
        so ssh.exe is told to prefer it and to read the password from the run's
        SSH_ASKPASS helper. SSH_ASKPASS_REQUIRE=force makes ssh use the helper
        even though a console is attached; pubkey auth is disabled so the login
        does not stall trying the user's default keys first.

    .PARAMETER VMHost
        FQDN or hostname of the ESXi host.

    .PARAMETER Command
        The command to run on the host.

    .PARAMETER Credential
        PSCredential for the root account.

    .OUTPUTS
        PSCustomObject with:
          .ExitStatus [int]      - remote command exit code (255 = connection
                                   or authentication failure)
          .Output     [string[]] - stdout and stderr merged
    #>
    param (
        [Parameter(Mandatory)][string]$VMHost,
        [Parameter(Mandatory)][string]$Command,
        [Parameter(Mandatory)][System.Management.Automation.PSCredential]$Credential
    )

    $sshAuth = Get-HostPrepSSHAuth -Credential $Credential
    $sshArgs = @(
        "-o", "PreferredAuthentications=keyboard-interactive,password"
        "-o", "KbdInteractiveAuthentication=yes"    # ESXi sshd offers keyboard-interactive, not password
        "-o", "PubkeyAuthentication=no"             # skip the user's default keys
        "-o", "StrictHostKeyChecking=accept-new"    # auto-accept unknown host keys
        "-o", ("UserKnownHostsFile=`"{0}`"" -f $sshAuth.KnownHostsPath)
        "-o", "ConnectTimeout=20"
        "-o", "NumberOfPasswordPrompts=1"
        "root@$VMHost"
        $Command
    )

    # ssh.exe reads the password from the SSH_ASKPASS helper. Save and restore
    # any pre-existing values so the run does not clobber the user's environment.
    $savedAskPass = $env:SSH_ASKPASS
    $savedRequire = $env:SSH_ASKPASS_REQUIRE
    try {
        $env:SSH_ASKPASS         = $sshAuth.AskPassPath
        $env:SSH_ASKPASS_REQUIRE = "force"
        $output   = & ssh.exe @sshArgs 2>&1 | ForEach-Object { "$_" }
        $exitCode = $LASTEXITCODE
    } finally {
        if ($null -eq $savedAskPass) { Remove-Item Env:\SSH_ASKPASS -ErrorAction SilentlyContinue }         else { $env:SSH_ASKPASS = $savedAskPass }
        if ($null -eq $savedRequire) { Remove-Item Env:\SSH_ASKPASS_REQUIRE -ErrorAction SilentlyContinue } else { $env:SSH_ASKPASS_REQUIRE = $savedRequire }
    }

    return [PSCustomObject]@{
        ExitStatus = $exitCode
        Output     = @($output)
    }
}

function Invoke-ESXiCertificateRegen {
    <#
    .SYNOPSIS
        Regenerates the ESXi host certificate via a temporary SSH session.

    .DESCRIPTION
        - Enables SSH on the host via PowerCLI (Set-VMHostServiceConfig)
        - Authenticates over SSH with the root password (SSH_ASKPASS)
        - Runs /sbin/generate-certificates using the built-in OpenSSH client
        - Removes the key and disables SSH again regardless of outcome
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
    Write-Log "  Enabling SSH temporarily for certificate regeneration..." -Level WARN
    Set-VMHostServiceConfig -VMHost $VMHostObj -ServiceKey "TSM-SSH"

    try {
        Write-Log "  Connecting via SSH to run /sbin/generate-certificates..."
        $sshResult = Invoke-ESXiSSHCommand -VMHost $VMHost -Command "/sbin/generate-certificates" -Credential $Credential

        if ($sshResult.ExitStatus -ne 0) {
            throw "/sbin/generate-certificates exited with code $($sshResult.ExitStatus). Output: $($sshResult.Output -join ' ')"
        }

        Write-Log "  Certificate regenerated successfully on $VMHost." -Color Green
        return $true

    } finally {
        # Always disable the service again regardless of outcome
        Write-Log "  Disabling SSH..." -Level WARN
        $svc = Get-VMHostService -VMHost $VMHostObj | Where-Object { $_.Key -eq "TSM-SSH" }
        if ($svc) {
            $svc | Set-VMHostService -Policy "off" -Confirm:$false | Out-Null
            if ($svc.Running) {
                $svc | Stop-VMHostService -Confirm:$false | Out-Null
            }
        }
        Write-Log "  SSH disabled." -Color Green
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
    Write-Log "  Waiting for $VMHost to come back online (timeout: ${TimeoutSeconds}s)..."

    # Brief initial pause to allow the host to begin its shutdown sequence
    Start-Sleep -Seconds 30

    while ((Get-Date) -lt $deadline) {
        try {
            $tcp = New-Object System.Net.Sockets.TcpClient
            $connect = $tcp.BeginConnect($VMHost, 443, $null, $null)
            $wait    = $connect.AsyncWaitHandle.WaitOne(3000, $false)
            if ($wait -and $tcp.Connected) {
                $tcp.Close()
                Write-Log "  $VMHost is back online." -Color Green
                # Brief extra pause to let services fully initialise
                Start-Sleep -Seconds 15
                return $true
            }
            $tcp.Close()
        } catch {
            # Connection refused or timed out  --  host still rebooting
        }
        Write-Log "  Still waiting... ($([int]($deadline - (Get-Date)).TotalSeconds)s remaining)" -Color DarkGray
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
        Write-Log "  Service '$ServiceKey' not found on host." -Level WARN
        return
    }

    if ($svc.Policy -ne $Policy) {
        Write-Log "  Setting '$ServiceKey' startup policy to '$Policy'..." -Level WARN
        $svc | Set-VMHostService -Policy $Policy -Confirm:$false | Out-Null
    }

    if (-not $svc.Running) {
        Write-Log "  Starting service '$ServiceKey'..." -Level WARN
        $svc | Start-VMHostService -Confirm:$false | Out-Null
    } else {
        Write-Log "  Service '$ServiceKey' is already running with policy '$Policy'." -Color Green
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

    Write-Log "  Password reset successfully for 'root' on $($VMHost.Name)." -Color Green

    # Warn if root is the same account used for the active session -
    # the current connection credential is now stale for any subsequent reconnects
    if ($ConnectedUsername -eq "root") {
        Write-Log ("  The reset account 'root' is the same as the active session credential. " +
                   "Any reconnection attempt on this host will fail until credentials are updated.") -Level WARN
    }

    # Record this host so the operator can audit which hosts were processed
    if ($script:PasswordResetCompleted) {
        $script:PasswordResetCompleted.Add($VMHost)
        Write-Log ("  Hosts with password reset completed this run: " +
                   ($script:PasswordResetCompleted -join ', ')) -Color DarkGray
    }
}

function Get-CellColor ($value) {
    if ($value -eq $true  -or $value -eq "OK")        { return "Green"    }
    if ($value -eq $false -or $value -like "FAILED*")  { return "Red"      }
    if ($value -like "Skipped*")                       { return "DarkGray" }
    if ($value -eq "Manual")                           { return "Yellow"   }
    if ($value -eq "Partial")                          { return "Yellow"   }
    if ($value -eq "Timeout")                          { return "Red"      }
    if ($value -like "Unexpected*")                    { return "Yellow"   }
    if ($value -like "WARN:*")                         { return "Yellow"   }
    if ($value -eq "CN mismatch")                      { return "Red"      }
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
          VSAN_ESA   - vSAN Express Storage Architecture -- edit CSV manually
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
            Write-Log "  Storage type detected : VMFS_FC (Fibre Channel HBA present)" -Color DarkGray
            return "VMFS_FC"
        }

        # NFS check -- any NFS datastore mounted
        $nfsDs = Get-Datastore -VMHost $VMHostObj -ErrorAction SilentlyContinue |
                    Where-Object { $_.Type -eq "NFS" -or $_.Type -eq "NFS41" }
        if ($nfsDs -and @($nfsDs).Count -gt 0) {
            Write-Log "  Storage type detected : NFS (NFS datastore mounted)" -Color DarkGray
            return "NFS"
        }

        # Default -- vSAN hosts have unclaimed disks at commissioning time;
        # OSA vs ESA is a design choice and must be set manually if ESA is intended.
        Write-Log "  Storage type detected : VSAN (default -- edit StorageType in the CSV to VSAN_ESA or VVOL if needed)" -Color DarkGray
        return "VSAN"

    } catch {
        Write-Log "  Storage type detection failed: $_ -- defaulting to VSAN" -Level WARN
        return "VSAN"
    }
}

function Repair-ESXiHostname {
    <#
    .SYNOPSIS
        Offers to correct the ESXi host's configured hostname and domain so a
        regenerated certificate will carry the right CN.

    .DESCRIPTION
        /sbin/generate-certificates builds the certificate CN from the host's own
        configured FQDN. Regenerating while that hostname is wrong just reproduces
        the wrong CN and wastes a reboot, so the caller checks first and calls this
        when the host disagrees with the host list.

        Prompts Y/N, then sets the hostname and domain from the FQDN in the host
        list via Set-VMHostNetwork and re-reads them from the host to confirm the
        change took. Renaming a host is never silent.

        The caller regenerates the certificate and reboots immediately after, so
        the rename needs no reboot of its own.

    .PARAMETER VMHost
        Expected FQDN of the ESXi host, as listed in the host list file.

    .PARAMETER VMHostObj
        Connected VMHost object, used to re-read the network config afterwards.

    .PARAMETER HostNetwork
        VMHostNetworkInfo for the host (from Get-VMHostNetwork). Set-VMHostNetwork
        takes this object rather than a VMHost.

    .OUTPUTS
        [bool] $true if the host's FQDN now matches $VMHost and regeneration
        should proceed; $false if declined, not applicable, or the change failed.
    #>
    param(
        [Parameter(Mandatory)][string]$VMHost,
        [Parameter(Mandatory)]$VMHostObj,
        [Parameter(Mandatory)]$HostNetwork
    )

    # A short name in the host list gives no domain to configure, so there is
    # nothing sensible to set here.
    if ($VMHost -notmatch '\.') {
        Write-Log "  '$VMHost' is not an FQDN, so no domain can be derived. Hostname fix skipped." -Level WARN
        return $false
    }

    # When the host takes its DNS settings from DHCP, it also takes its hostname and
    # domain from there. Set-VMHostNetwork then accepts -HostName/-DomainName without
    # error and silently changes nothing, so catch it here rather than letting the
    # read-back below report a baffling "hostname unchanged".
    if ($HostNetwork.DnsFromDhcp) {
        Write-Log "  This host obtains its DNS settings (and therefore its hostname and domain) from DHCP." -Level WARN
        Write-Log "  ESXi ignores a hostname set while DHCP is in charge, so the fix cannot be applied." -Level WARN
        Write-Log "  Set DNS to static on the host, then re-run  --  in the ESXi UI:" -Level WARN
        Write-Log "    Networking > TCP/IP stacks > Default > Edit settings > 'Enter settings manually'" -Level WARN
        Write-Log "  A VCF host should not depend on DHCP for its identity in any case." -Level WARN
        return $false
    }

    $desiredShort  = $VMHost.Split('.')[0]
    $desiredDomain = ($VMHost -split '\.', 2)[1]

    $answer = (Read-Host "  Fix the hostname on $VMHost so the certificate CN will match? [Y/N]").Trim().ToUpper()
    if ($answer -ne 'Y') {
        Write-Log "  Hostname fix declined." -Level WARN
        return $false
    }

    try {
        Write-Log "    Setting hostname : $desiredShort" -Color DarkGray
        Write-Log "    Setting domain   : $desiredDomain" -Color DarkGray

        Set-VMHostNetwork -Network $HostNetwork -HostName $desiredShort -DomainName $desiredDomain `
            -Confirm:$false -ErrorAction Stop | Out-Null

        # Read it back from the host rather than trusting the call to have stuck:
        # a wrong CN is exactly the failure this is meant to prevent.
        $updated     = Get-VMHostNetwork -VMHost $VMHostObj
        $updatedFqdn = "$($updated.HostName).$($updated.DomainName)".ToLower().TrimEnd('.')

        if ($updatedFqdn -eq $VMHost.ToLower()) {
            Write-Log "  Hostname updated to '$updatedFqdn'. Proceeding with certificate regeneration." -Color Green
            return $true
        }

        Write-Log "  Hostname still reads '$updatedFqdn' after the change. Regeneration skipped." -Level WARN
        return $false

    } catch {
        Write-Log "  Failed to set the hostname: $_" -Level WARN
        return $false
    }
}

function Get-OptionalAdvancedSettings {
    <#
    .SYNOPSIS
        Loads the optional advanced settings list, preferring an external
        file next to the script over the built-in defaults.

    .DESCRIPTION
        Looks in the script directory for, in order:
          1. HostPrep.Settings.json
          2. HostPrep.Settings.psd1
        The first one found is used. If neither exists, or the one found
        fails to parse, $DefaultOptionalAdvancedSettings (defined at the top
        of the script) is used instead.

        JSON schema -- a top-level array of objects:
          [
            {
              "Name":    "Config.HostAgent.plugins.hostsvc.esxAdminsGroup",
              "Value":   "ESX Admins",
              "Enabled": false,
              "Label":   "ESX Admins group"
            }
          ]

        PSD1 schema -- Import-PowerShellDataFile requires a top-level
        hashtable, so the array is nested under a Settings key:
          @{
              Settings = @(
                  @{
                      Name    = "Config.HostAgent.plugins.hostsvc.esxAdminsGroup"
                      Value   = "ESX Admins"
                      Enabled = $false
                      Label   = "ESX Admins group"
                  }
              )
          }

        Each entry needs Name, Value, Enabled and Label. Value types follow
        the same rules as the built-in defaults: strings quoted, integers
        unquoted, booleans as true/false ($true/$false in .psd1).

    .OUTPUTS
        Array of settings objects (PSCustomObject for JSON, Hashtable for
        .psd1), each with Name, Value, Enabled and Label properties.
    #>
    param ()

    $jsonPath = Join-Path $PSScriptRoot "HostPrep.Settings.json"
    $psd1Path = Join-Path $PSScriptRoot "HostPrep.Settings.psd1"

    if (Test-Path -LiteralPath $jsonPath -PathType Leaf) {
        try {
            $loaded = Get-Content -LiteralPath $jsonPath -Raw | ConvertFrom-Json -ErrorAction Stop
            Write-Log "  Loaded optional advanced settings from: $jsonPath" -Color DarkGray
            return @($loaded)
        } catch {
            Write-Log "  Failed to parse $jsonPath ($_)" -Level WARN
            Write-Log "  Falling back to $psd1Path or built-in defaults." -Level WARN
        }
    }

    if (Test-Path -LiteralPath $psd1Path -PathType Leaf) {
        try {
            $data = Import-PowerShellDataFile -LiteralPath $psd1Path -ErrorAction Stop
            if (-not $data.ContainsKey('Settings')) {
                throw "top-level hashtable is missing a 'Settings' key."
            }
            Write-Log "  Loaded optional advanced settings from: $psd1Path" -Color DarkGray
            return @($data.Settings)
        } catch {
            Write-Log "  Failed to parse $psd1Path ($_)" -Level WARN
            Write-Log "  Falling back to built-in defaults." -Level WARN
        }
    }

    Write-Log "  No HostPrep.Settings.json or HostPrep.Settings.psd1 found -- using built-in default optional advanced settings." -Color DarkGray
    return $DefaultOptionalAdvancedSettings
}

function Invoke-VSANDiskWipe {
    <#
    .SYNOPSIS
        Identifies and wipes non-boot disks with existing partitions on an
        ESXi host, preparing them for clean vSAN commissioning.

    .DESCRIPTION
        - Enumerates all storage devices via esxcli v2
        - Identifies the boot device (IsBootDrive flag; size heuristic fallback)
          and excludes it unconditionally
        - Lists non-boot disks that have existing partition tables
        - Prompts Y/N before wiping
        - Unmounts any VMFS datastores on target disks via SSH (esxcli storage vmfs unmount)
          before wiping -- no vCenter connection required
        - Wipes partition tables via SSH using: partedUtil mklabel <device> gpt
        - Falls back to printing manual SSH instructions if the OpenSSH client is unavailable

    .PARAMETER VMHost
        FQDN of the ESXi host (string, used for SSH connection).

    .PARAMETER VMHostObj
        VMHost object returned by Get-VMHost, used for PowerCLI operations.

    .PARAMETER Credential
        PSCredential for the root account, used to authenticate the SSH session.

    .PARAMETER DryRun
        Simulates the wipe without making any changes.

    .OUTPUTS
        PSCustomObject with:
          .Status      [string] - "OK", "Partial", "FAILED: <msg>", "Manual",
                                  "Skipped (clean)", or "Skipped (operator)"
          .WipedCount  [int]    - number of disks successfully wiped
          .FailedDisks [string[]] - device names that failed
    #>
    param (
        [Parameter(Mandatory)][string]$VMHost,
        [Parameter(Mandatory)]$VMHostObj,
        [Parameter(Mandatory)][System.Management.Automation.PSCredential]$Credential,
        [switch]$DryRun
    )

    $esxCli = Get-EsxCli -VMHost $VMHostObj -V2

    # --- Enumerate all storage devices ---
    try {
        $allDevices = $esxCli.storage.core.device.list.Invoke()
    } catch {
        Write-Log ("  Could not enumerate storage devices: {0}" -f $_) -Level WARN
        return [PSCustomObject]@{ Status = "FAILED: $_"; WipedCount = 0; FailedDisks = @() }
    }
    # --- Identify boot device(s) ---
    $bootDevices = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)

    # Layer 1: IsBootDrive flag (reliable on ESXi 7+/8+)
    foreach ($dev in $allDevices) {
        if ($dev.IsBootDrive -eq $true) {
            $bootDevices.Add($dev.Device) | Out-Null
        }
    }

    # Layer 2a: esxcli system boot device get
    if ($bootDevices.Count -eq 0) {
        try {
            $bootDevInfo = $esxCli.system.boot.device.get.Invoke()
            $rawPath = $bootDevInfo.PSObject.Properties |
                Where-Object { $_.Value -match '/dev/disks/|vmhba|eui\.' } |
                Select-Object -First 1 -ExpandProperty Value
            if ($rawPath) {
                $devName = ($rawPath -replace '^/dev/disks/', '') -replace ':\d+$', ''
                if ($devName) {
                    $bootDevices.Add($devName) | Out-Null
                    Write-Log ("  Boot device identified (system.boot.device.get): {0}" -f $devName) -Color DarkGray
                }
            }
        } catch { }
    }

    # Layer 2b: esxcli system coredump partition get
    if ($bootDevices.Count -eq 0) {
        try {
            $cdump = $esxCli.system.coredump.partition.get.Invoke()
            $cdumpRaw = $cdump.PSObject.Properties |
                Where-Object { $_.Value -match 'vmhba|eui\.' } |
                Select-Object -First 1 -ExpandProperty Value
            if ($cdumpRaw) {
                $devName = $cdumpRaw -replace ':\d+$', ''
                if ($devName) {
                    $bootDevices.Add($devName) | Out-Null
                    Write-Log ("  Boot device identified (coredump partition): {0}" -f $devName) -Color DarkGray
                }
            }
        } catch { }
    }

    # Layer 2c: OSDATA volume detection -- ESXi boot disks always host an OSDATA-* VMFS volume.
    if ($bootDevices.Count -eq 0) {
        try {
            $allExtents = $esxCli.storage.vmfs.extent.list.Invoke()
            foreach ($extent in ($allExtents | Where-Object { $_.VolumeName -like 'OSDATA-*' })) {
                $bootDevices.Add($extent.DeviceName) | Out-Null
                Write-Log ("  Boot device identified (OSDATA volume): {0}" -f $extent.DeviceName) -Color DarkGray
            }
        } catch { }
    }

    # Layer 3: Removable device fallback -- catches USB/SD/CD-ROM boot media.
    if ($bootDevices.Count -eq 0) {
        Write-Log "  Boot device not identified via esxcli -- falling back to IsRemovable flag." -Level WARN
        foreach ($dev in $allDevices) {
            if ($dev.IsRemovable -eq $true) {
                $bootDevices.Add($dev.Device) | Out-Null
            }
        }
    }

    if ($bootDevices.Count -eq 0) {
        Write-Log "  WARNING: Could not identify boot device -- all non-boot disks will be candidates. Review carefully." -Level WARN
    }

    $bootDeviceList = if ($bootDevices.Count -gt 0) { ($bootDevices | Sort-Object) -join ', ' } else { 'none detected' }
    Write-Log ("  Boot device(s) excluded from wipe: {0}" -f $bootDeviceList) -Color DarkGray

    # --- Find non-boot disks with existing partition tables ---
    $disksToWipe = [System.Collections.Generic.List[PSCustomObject]]::new()

    foreach ($dev in $allDevices) {
        if ($bootDevices.Contains($dev.Device)) { continue }

        try {
            $partArgs = $esxCli.storage.core.device.partition.list.CreateArgs()
            $partArgs.device = $dev.Device
            $partitions = $esxCli.storage.core.device.partition.list.Invoke($partArgs)
            $partCount  = @($partitions).Count

            if ($partitions -and $partCount -gt 0) {
                $sizeGb = [math]::Round($dev.Size / 1024, 1)
                $disksToWipe.Add([PSCustomObject]@{
                    Device  = $dev.Device
                    Display = $dev.DisplayName
                    SizeGB  = $sizeGb
                    IsSSD   = $dev.IsSSD
                })
            }
        } catch {
            Write-Log ("  Device {0} -- partition query failed (skipped): {1}" -f $dev.Device, $_) -Color DarkGray
        }
    }

    if ($disksToWipe.Count -eq 0) {
        Write-Log "  All non-boot disks are clean. No wipe needed." -Color Green
        return [PSCustomObject]@{ Status = "Skipped (clean)"; WipedCount = 0; FailedDisks = @() }
    }

    # --- Display disks and prompt ---
    Write-Log ""
    Write-Log ("  Disks with existing partitions on {0}:" -f $VMHost) -Level WARN
    foreach ($disk in $disksToWipe) {
        Write-Log ("    {0}  ({1} GB, SSD: {2})" -f $disk.Device, $disk.SizeGB, $disk.IsSSD) -Level WARN
        Write-Log ("      {0}" -f $disk.Display) -Color DarkGray
    }
    Write-Log ""

    if ($DryRun) {
        Write-Log ("  [DRY RUN] Would wipe {0} disk(s) on {1}." -f $disksToWipe.Count, $VMHost) -Color DarkYellow
        return [PSCustomObject]@{ Status = "OK"; WipedCount = $disksToWipe.Count; FailedDisks = @() }
    }

    $answer = $null
    while ($answer -notin @('Y', 'N')) {
        $answer = (Read-Host ("  Wipe {0} disk(s) on {1}? [Y/N]" -f $disksToWipe.Count, $VMHost)).Trim().ToUpper()
        if ($answer -notin @('Y', 'N')) {
            Write-Log "  Please enter Y or N." -Level WARN
        }
    }

    if ($answer -eq 'N') {
        Write-Log "  Disk wipe skipped by operator." -Color DarkGray
        return [PSCustomObject]@{ Status = "Skipped (operator)"; WipedCount = 0; FailedDisks = @() }
    }

    # --- OpenSSH client availability check (soft fail) ---
    if (-not $script:SSHClientAvailable) {
        Write-Log ""
        Write-Log "  OpenSSH client not available. Cannot run partedUtil via SSH." -Level WARN
        Write-Log ("  ACTION REQUIRED: Manually wipe the following disks on {0} via SSH:" -f $VMHost) -Level WARN
        foreach ($disk in $disksToWipe) {
            Write-Log ("    partedUtil mklabel /vmfs/devices/disks/{0} gpt" -f $disk.Device) -Color Cyan
        }
        return [PSCustomObject]@{
            Status      = "Manual"
            WipedCount  = 0
            FailedDisks = @($disksToWipe | Select-Object -ExpandProperty Device)
        }
    }

    # --- Collect VMFS volumes mounted on target disks (via esxcli -- no vCenter needed) ---
    $vmfsToUnmount = [System.Collections.Generic.List[string]]::new()
    try {
        $vmfsExtents = $esxCli.storage.vmfs.extent.list.Invoke()
        foreach ($disk in $disksToWipe) {
            foreach ($extent in ($vmfsExtents | Where-Object { $_.DeviceName -eq $disk.Device })) {
                if (-not $vmfsToUnmount.Contains($extent.VolumeName)) {
                    $vmfsToUnmount.Add($extent.VolumeName)
                    Write-Log ("  VMFS datastore to unmount: '{0}' on {1}" -f $extent.VolumeName, $disk.Device) -Color DarkGray
                }
            }
        }
    } catch {
        Write-Log ("  VMFS extent check failed (non-fatal): {0}" -f $_) -Level WARN
    }

    # --- Enable SSH temporarily, then unmount VMFS and wipe ---
    Write-Log "  Enabling SSH temporarily for disk wipe..." -Level WARN
    Set-VMHostServiceConfig -VMHost $VMHostObj -ServiceKey "TSM-SSH"

    $wipedCount = 0
    $failedDisks = [System.Collections.Generic.List[string]]::new()

    try {
        Write-Log "  Connecting via SSH to run partedUtil..." -Color Cyan
        $probe = Invoke-ESXiSSHCommand -VMHost $VMHost -Command "echo connected" -Credential $Credential
        if ($probe.ExitStatus -ne 0) {
            throw ("SSH connection failed: {0}" -f (($probe.Output -join ' ').Trim()))
        }

        # Layer 4: /proc/mounts bootbank check -- definitive boot device identification via SSH.
        # Runs after connectivity is verified; retroactively removes boot disk from wipe list if
        # it was missed by Layers 1-3 (e.g. nested ESXi where IsBootDrive flag is not set).
        $mountResult = Invoke-ESXiSSHCommand -VMHost $VMHost -Credential $Credential `
            -Command "grep ' /bootbank ' /proc/mounts"
        $bootMountRaw = ($mountResult.Output | Where-Object { $_ -match '/dev/disks/' } | Select-Object -First 1)
        if ($bootMountRaw) {
            $bootMountRaw = ($bootMountRaw.Trim() -split '\s+')[0]   # first field = device path
            $bootDevFromMount = ($bootMountRaw -replace '^/dev/disks/', '') -replace ':\d+$', ''
            if ($bootDevFromMount -and -not $bootDevices.Contains($bootDevFromMount)) {
                Write-Log ("  Boot device '{0}' was not excluded by earlier layers -- removing from wipe list." -f $bootDevFromMount) -Level WARN
                $bootDevices.Add($bootDevFromMount) | Out-Null
                $disksToWipe = [System.Collections.Generic.List[PSCustomObject]]($disksToWipe | Where-Object { $_.Device -ne $bootDevFromMount })
                if ($disksToWipe.Count -eq 0) {
                    Write-Log "  No wipe candidates remain after boot device removal. Skipping wipe." -Color Green
                    return [PSCustomObject]@{ Status = "Skipped (clean)"; WipedCount = 0; FailedDisks = @() }
                }
                Write-Log ("  Remaining wipe candidates: {0}" -f ($disksToWipe | ForEach-Object { $_.Device }) -join ', ') -Color DarkGray
            }
        }

        # Unmount VMFS volumes via SSH before wiping
        foreach ($volName in $vmfsToUnmount) {
            Write-Log ("  Unmounting VMFS datastore '{0}'..." -f $volName) -Level WARN
            $umResult = Invoke-ESXiSSHCommand -VMHost $VMHost -Credential $Credential `
                -Command ("esxcli storage filesystem unmount -l '{0}'" -f $volName)
            if ($umResult.ExitStatus -eq 0) {
                Write-Log ("  Datastore '{0}' unmounted." -f $volName) -Color Green
            } else {
                $umErr = ($umResult.Output -join ' ').Trim()
                Write-Log ("  Could not unmount '{0}' (wipe may fail): {1}" -f $volName, $umErr) -Level WARN
            }
        }

        foreach ($disk in $disksToWipe) {
            try {
                Write-Log ("  Wiping {0} ({1} GB)..." -f $disk.Device, $disk.SizeGB) -Level WARN
                $cmd    = "partedUtil mklabel /vmfs/devices/disks/{0} gpt" -f $disk.Device
                $result = Invoke-ESXiSSHCommand -VMHost $VMHost -Command $cmd -Credential $Credential

                if ($result.ExitStatus -eq 0) {
                    Write-Log ("  Wiped {0} successfully." -f $disk.Device) -Color Green
                    $wipedCount++
                } else {
                    $errMsg = ($result.Output -join ' ').Trim()
                    Write-Log ("  partedUtil failed on {0}: {1}" -f $disk.Device, $errMsg) -Level WARN
                    $failedDisks.Add($disk.Device)
                }
            } catch {
                Write-Log ("  Failed to wipe {0}: {1}" -f $disk.Device, $_) -Level WARN
                $failedDisks.Add($disk.Device)
            }
        }

    } catch {
        Write-Log ("  SSH setup failed: {0}" -f $_) -Level WARN
        return [PSCustomObject]@{
            Status      = "FAILED: SSH - $_"
            WipedCount  = 0
            FailedDisks = @($disksToWipe | Select-Object -ExpandProperty Device)
        }
    } finally {
        Write-Log "  Disabling SSH..." -Level WARN
        $svc = Get-VMHostService -VMHost $VMHostObj | Where-Object { $_.Key -eq "TSM-SSH" }
        if ($svc) {
            $svc | Set-VMHostService -Policy "off" -Confirm:$false | Out-Null
            if ($svc.Running) { $svc | Stop-VMHostService -Confirm:$false | Out-Null }
        }
        Write-Log "  SSH disabled." -Color Green
    }

    $status = if ($failedDisks.Count -eq 0) {
        "OK"
    } elseif ($wipedCount -gt 0) {
        "Partial"
    } else {
        "FAILED"
    }

    $statusColor = if ($status -eq 'OK') { 'Green' } elseif ($status -eq 'Partial') { 'Yellow' } else { 'Red' }
    Write-Log ("  Disk wipe complete: {0} wiped, {1} failed." -f $wipedCount, $failedDisks.Count) -Color $statusColor

    return [PSCustomObject]@{
        Status      = $status
        WipedCount  = $wipedCount
        FailedDisks = $failedDisks
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
        DiskWipe         = 14
        CertRegen        = 10
        Rebooted         = 10
        PasswordReset    = 15
        Error            = 28
    }

    $divider = "+" + (($columns.Values | ForEach-Object { "-" * ($_ + 2) }) -join "+") + "+"

    Write-Log ""
    Write-Log $divider -Color DarkCyan

    # Header row
    $headerLine = "|"
    foreach ($col in $columns.GetEnumerator()) {
        $headerLine += " {0,-$($col.Value)} |" -f $col.Key
    }
    Write-Log $headerLine
    Write-Log $divider -Color DarkCyan

    # Data rows
    foreach ($row in $Data) {
        # Determine row base colour from Connected + Error
        $rowColor = if ($row.Error) { "Red" } elseif ($row.Connected) { "White" } else { "DarkYellow" }

        # Write the row cell by cell so each cell can have its own colour.
        # -NoNewline calls go to console only (no log file entry).
        Write-Log "|" -Color DarkCyan -NoNewline
        foreach ($col in $columns.GetEnumerator()) {
            $val     = $row.($col.Key)
            $display = if ($null -eq $val) { "" } else { "$val" }
            if ($display.Length -gt $col.Value) { $display = $display.Substring(0, $col.Value - 1) + "~" }
            $padded  = " {0,-$($col.Value)} " -f $display
            $color   = Get-CellColor $val
            if ($color -eq "White") { $color = $rowColor }
            Write-Log $padded -Color $color -NoNewline
            Write-Log "|" -Color DarkCyan -NoNewline
        }
        Write-Log ""  # newline
    }

    Write-Log $divider -Color DarkCyan
}

function Write-HtmlReport {
    param (
        [System.Collections.Generic.List[PSCustomObject]]$Data,
        [string]$ReportPath,
        [switch]$WhatIfReport
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
            ($row.AdvancedSettings -eq "OK") -and
            ($row.CertRegen -ne "CN mismatch")
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
                elseif ($row.CertRegen -eq 'CN mismatch')           { '<span class=expiry-critical>CN mismatch after regen</span>' }
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
            <td>$(
                if     ($row.DiskWipe -eq 'OK')                { '<span style="color:#3fb950">Wiped</span>' }
                elseif ($row.DiskWipe -like 'Skipped*')        { '<span style="color:#6e7681">' + [System.Web.HttpUtility]::HtmlEncode($row.DiskWipe) + '</span>' }
                elseif ($row.DiskWipe -eq 'Manual')            { '<span class="expiry-warn">Manual required</span>' }
                elseif ($row.DiskWipe -eq 'Partial')           { '<span class="expiry-warn">Partial</span>' }
                elseif ($row.DiskWipe -like 'FAILED*')         { '<span style="color:#f85149">' + [System.Web.HttpUtility]::HtmlEncode($row.DiskWipe) + '</span>' }
                else                                           { [System.Web.HttpUtility]::HtmlEncode($row.DiskWipe) }
            )</td>
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
      <th>Disk Wipe</th>
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
    Write-Log ("  HTML report written to: {0}" -f $ReportPath)
}

#endregion
#region --- Optional Advanced Settings (Load) ---

$OptionalAdvancedSettings = Get-OptionalAdvancedSettings

$enabledOptionalPreview = @($OptionalAdvancedSettings | Where-Object { $_.Enabled -eq $true })
if ($enabledOptionalPreview.Count -gt 0) {
    Write-Log ("  Optional advanced settings enabled: " + (($enabledOptionalPreview | ForEach-Object { $_.Label }) -join ', ')) -Color DarkGray
} else {
    Write-Log "  No optional advanced settings enabled." -Color DarkGray
}

#endregion
#region --- Host List Selection ---

$hostFilePath = $null
while (-not $hostFilePath) {
    $raw = (Read-Host "  Enter full path to the host list .txt file").Trim()

    # Strip surrounding quotes that Windows sometimes adds when copy-pasting paths
    $raw = $raw.Trim('"').Trim("'")

    if ([string]::IsNullOrWhiteSpace($raw)) {
        Write-Log "  Path cannot be empty. Please try again." -Level WARN
        continue
    }

    if (-not (Test-Path -LiteralPath $raw -PathType Leaf)) {
        Write-Log "  File not found: '$raw'" -Level WARN
        Write-Log "  Please check the path and try again." -Level WARN
        continue
    }

    $hostFilePath = $raw
}

$targetEsxiHosts = Get-Content -LiteralPath $hostFilePath |
    Where-Object { $_ -match '\S' -and $_ -notmatch '^\s*#' }

if (-not $targetEsxiHosts) {
    Write-Log "Host list is empty. Exiting." -Level ERROR
    exit 1
}

Write-Log "  Loaded $($targetEsxiHosts.Count) host(s) from: $hostFilePath"

#endregion
#region --- NTP Server Selection ---

# When -NtpServers is supplied on the command line the script stays unattended.
# When it is not, confirm the servers interactively instead of silently applying
# the public pool: on an isolated management network pool.ntp.org is unreachable,
# which leaves every host with a dead time source and breaks commissioning later.
if (-not $PSBoundParameters.ContainsKey('NtpServers')) {

    Write-Log "`nNTP servers..."
    Write-Log "  Default if you press Enter: $($NtpServers -join ', ')" -Color DarkGray

    $ntpRaw = (Read-Host "  Enter NTP server(s), comma separated [Enter = default]").Trim()

    if (-not [string]::IsNullOrWhiteSpace($ntpRaw)) {
        $entered = @(
            $ntpRaw -split ',' |
                ForEach-Object { $_.Trim().Trim('"').Trim("'") } |
                Where-Object   { $_ -match '\S' }
        )

        if ($entered.Count -gt 0) {
            $NtpServers = $entered
        }
    }
}

Write-Log "  NTP server(s) to configure: $($NtpServers -join ', ')" -Color Green

#endregion
#region --- Credential Gathering ---

Write-Log "`nGathering credentials..."

$esxiPassword    = Read-Host "Enter the 'root' password used to connect to the ESXi hosts" -AsSecureString
$esxiCredentials = New-Object System.Management.Automation.PSCredential("root", $esxiPassword)

# Ask interactively whether to reset the root account password
# (not applicable in WhatIfReport mode  --  no changes are made)
Write-Log ""
if ($WhatIfReport) {
    $ResetPassword = $false
    Write-Log "  Password reset: SKIPPED (WhatIfReport mode)" -Color DarkGray
} else {
$resetAnswer = $null
while ($resetAnswer -notin @('Y','N')) {
    $resetAnswer = (Read-Host "  Do you want to reset the root account password on all hosts? [Y/N]").Trim().ToUpper()
    if ($resetAnswer -notin @('Y','N')) {
        Write-Log "  Please enter Y or N." -Level WARN
    }
}
$ResetPassword = ($resetAnswer -eq 'Y')

if ($ResetPassword) {
    Write-Log "  Password reset: ENABLED" -Level WARN
    Write-Log ""
    Write-Log "  New password must meet VCF 9 requirements:"
    Write-Log "    - 15 to 40 characters" -Color DarkGray
    Write-Log "    - At least 1 lowercase letter" -Color DarkGray
    Write-Log "    - At least 1 uppercase letter (not as the first character)" -Color DarkGray
    Write-Log "    - At least 1 digit (not as the last character)" -Color DarkGray
    Write-Log "    - At least 1 special character from: @ ! # `$ % ? ^" -Color DarkGray
    Write-Log "    - Only letters, digits, and @ ! # `$ % ? ^ are permitted" -Color DarkGray
    Write-Log "    - At least 3 of the 4 character classes must be present" -Color DarkGray
    Write-Log ""

    $NewPassword       = $null
    $passwordCompliant = $false

    while (-not $passwordCompliant) {
        $NewPassword = Read-Host "  Enter NEW root password" -AsSecureString

        if ($NewPassword.Length -eq 0) {
            Write-Log "  Password cannot be empty. Please try again." -Level WARN
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
                Write-Log "  Password meets all VCF 9 requirements." -Color Green
                Write-Log ""
            } else {
                Write-Log "  Passwords do not match. Please try again." -Level WARN
                Write-Log ""
            }
        } else {
            Write-Log ""
            Write-Log "  Password does not meet VCF 9 requirements:" -Level ERROR
            foreach ($failure in $validation.Failures) {
                Write-Log "    x $failure" -Level WARN
            }
            Write-Log "  Please enter a new password."
            Write-Log ""
        }
    }

    # Track which hosts have already had their password reset this run.
    # Useful if the script is interrupted and re-run - the operator can
    # see in the log which hosts were already changed.
    $script:PasswordResetCompleted = [System.Collections.Generic.List[string]]::new()
} else {
    Write-Log "  Password reset: SKIPPED" -Color DarkGray
}
} # end else (not WhatIfReport) for password prompt
Write-Log ""

#endregion
#region --- Per-Host Processing ---

$results = [System.Collections.Generic.List[PSCustomObject]]::new()

foreach ($esxiHost in $targetEsxiHosts) {

    $script:hostTimedOut = $false

    Write-Log ("`n" + ("=" * 60)) -Color DarkCyan
    Write-Log ("  Processing host : $esxiHost")
    Write-Log ("  " + $ScriptMeta.Blog) -Color DarkGray
    Write-Log ("=" * 60) -Color DarkCyan

    $hostResult = [PSCustomObject]@{
        Host              = $esxiHost
        Connected         = $false
        DNS               = "Skipped"
        NTP               = "Skipped"
        AdvancedSettings  = "Skipped"
        OptionalSettings  = "Skipped"
        DiskWipe          = "Skipped"
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
        Write-Log "`n  [DNS Validation]"
        if ($DryRun) {
            Write-Log "  [DRY RUN] Would validate forward and reverse DNS for $esxiHost." -Color DarkYellow
            $hostResult.DNS = "OK"
        } else {
            $dnsCheck = Test-DNSResolution -VMHost $esxiHost
            $hostResult.DNS = $dnsCheck.Status
            if ($dnsCheck.Status -eq "OK") {
                Write-Log "  Forward : $($dnsCheck.Forward)" -Color Green
                Write-Log "  Reverse : $($dnsCheck.Reverse)" -Color Green
                Write-Log "  DNS OK -- forward and reverse match." -Color Green
            } elseif ($dnsCheck.Status -eq "FAILED") {
                Write-Log "  Forward lookup failed for $esxiHost." -Level ERROR
                Write-Log "  ACTION REQUIRED: Ensure an A record exists for this host." -Level ERROR
                throw "DNS A record lookup failed for $esxiHost. Fix DNS before commissioning."
            } else {
                Write-Log "  Forward : $($dnsCheck.Forward)" -Level WARN
                Write-Log "  Reverse : $($dnsCheck.Reverse)" -Level WARN
                Write-Log "  WARNING: $($dnsCheck.Status)" -Level WARN
                Write-Log "  ACTION REQUIRED: Fix PTR record before commissioning." -Level WARN
            }
        }

        # --- Connect ---
        Write-Log "`n  [Connect]"
        if ($DryRun) {
            Write-Log "`n  [DRY RUN] Would connect to $esxiHost as 'root'." -Color DarkYellow
            $hostResult.Connected   = $true
            $hostResult.StorageType = "Skipped"
        } else {
            Connect-VIServer -Server $esxiHost -Credential $esxiCredentials -ErrorAction Stop | Out-Null
            $hostResult.Connected = $true
            Write-Log "  Connected to $esxiHost." -Color Green
            $vmHostObj = Get-VMHost -Name $esxiHost -ErrorAction Stop

            # Detect storage type immediately after connect while session is live
            Write-Log "`n  [Storage Detection]"
            $hostResult.StorageType = Get-ESXiStorageType -VMHostObj $vmHostObj
        }

        # --- WhatIfReport: cert/thumbprint read only, skip all other steps ---
        if ($WhatIfReport) {
            Write-Log "`n  [WhatIfReport] Reading certificate..."
            $certCheck = Test-ESXiCertificateNeedsRegen -VMHost $esxiHost
            $hostResult.Thumbprint = $certCheck.Thumbprint
            $hostResult.Expiry     = $certCheck.Expiry
            $hostResult.CertRegen  = if ($certCheck.NeedsRegen) { "Regen needed" } else { "OK" }
            Write-Log "  Thumbprint   : $($certCheck.Thumbprint)" -Color DarkGray
            Write-Log "  CN           : $($certCheck.CN)"         -Color DarkGray
            Write-Log "  Expiry       : $($certCheck.Expiry)"     -Color DarkGray
            Write-Log "  Storage type : $($hostResult.StorageType)  (edit CSV to VSAN_ESA or VVOL if needed)" -Color DarkGray
            # Skip all remaining steps  --  fall through to finally for clean disconnect
        } else {

        # --- NTP ---
        Write-Log "`n  [NTP]"
        try {
            if ($DryRun) {
                Write-Log "  [DRY RUN] Would verify/add NTP server(s): $($NtpServers -join ', ')." -Color DarkYellow
                Write-Log "  [DRY RUN] Would ensure ntpd policy=on and service running." -Color DarkYellow
            } else {
                $currentNtp     = @(Get-VMHostNtpServer -VMHost $vmHostObj)
                $missingServers = $NtpServers | Where-Object { $_ -notin $currentNtp }

                if ($missingServers) {
                    Write-Log "  Adding missing NTP server(s): $($missingServers -join ', ')" -Level WARN
                    Add-VMHostNtpServer -VMHost $vmHostObj -NtpServer $missingServers -Confirm:$false -ErrorAction Stop | Out-Null
                } else {
                    Write-Log "  All required NTP server(s) already configured." -Color Green
                }

                Set-VMHostServiceConfig -VMHost $vmHostObj -ServiceKey "ntpd"
            }
            $hostResult.NTP = "OK"
        } catch {
            $hostResult.NTP = "FAILED: $_"
            Write-Log "  NTP configuration failed: $_" -Level WARN
        }

        # --- Advanced Settings (SDDC Manager) ---
        Write-Log "`n  [Advanced Settings]"
        try {
            if ($DryRun) {
                Write-Log "  [DRY RUN] Would set 'Config.HostAgent.ssl.keyStore.allowSelfSigned' = True" -Color DarkYellow
            } else {
                Get-AdvancedSetting -Entity $vmHostObj -Name "Config.HostAgent.ssl.keyStore.allowSelfSigned" |
                    Set-AdvancedSetting -Value $true -Confirm:$false | Out-Null
                Write-Log "  Set 'Config.HostAgent.ssl.keyStore.allowSelfSigned' = True" -Color Green
            }
            $hostResult.AdvancedSettings = "OK"
        } catch {
            $hostResult.AdvancedSettings = "FAILED: $_"
            Write-Log "  Advanced settings failed: $_" -Level WARN
        }

        # --- Optional Advanced Settings ---
        $enabledOptional = $OptionalAdvancedSettings | Where-Object { $_.Enabled -eq $true }
        if ($enabledOptional) {
            Write-Log "`n  [Optional Advanced Settings]"
            $optionalFailures = [System.Collections.Generic.List[string]]::new()

            foreach ($setting in $enabledOptional) {
                try {
                    if ($DryRun) {
                        Write-Log "  [DRY RUN] Would set '$($setting.Name)' = $($setting.Value)  ($($setting.Label))" -Color DarkYellow
                    } else {
                        Get-AdvancedSetting -Entity $vmHostObj -Name $setting.Name |
                            Set-AdvancedSetting -Value $setting.Value -Confirm:$false | Out-Null
                        Write-Log "  Set '$($setting.Name)' = $($setting.Value)  ($($setting.Label))" -Color Green
                    }
                } catch {
                    $msg = "$($setting.Label): $_"
                    $optionalFailures.Add($msg)
                    Write-Log "  Failed to set '$($setting.Name)': $_" -Level WARN
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

        # --- vSAN Disk Wipe ---
        if ($WipeDisk) {
            Write-Host "`n  [vSAN Disk Wipe]" -ForegroundColor Cyan
            if ($DryRun) {
                Write-Host "  [DRY RUN] Would check and wipe non-boot partitioned disks on $esxiHost." -ForegroundColor DarkYellow
                $hostResult.DiskWipe = "OK"
            } elseif ($hostResult.StorageType -ne 'VSAN') {
                Write-Host ("  Skipped -- storage type is {0}, not VSAN." -f $hostResult.StorageType) -ForegroundColor DarkGray
                $hostResult.DiskWipe = "Skipped"
            } else {
                try {
                    $wipeResult = Invoke-VSANDiskWipe `
                        -VMHost     $esxiHost `
                        -VMHostObj  $vmHostObj `
                        -Credential $esxiCredentials
                    $hostResult.DiskWipe = $wipeResult.Status
                } catch {
                    $hostResult.DiskWipe = "FAILED: $_"
                    Write-Warning "  Disk wipe failed: $_"
                }
            }
        }

        # --- Certificate Regeneration ---
        Write-Log "`n  [Certificate Regeneration]"
        try {
            if ($DryRun) {
                Write-Log "  [DRY RUN] Would check if certificate CN matches hostname." -Color DarkYellow
                Write-Log "  [DRY RUN] On a hostname mismatch, would offer to set the ESXi hostname/domain to '$esxiHost'." -Color DarkYellow
                Write-Log "  [DRY RUN] Would regenerate host certificate if needed." -Color DarkYellow
                Write-Log "  [DRY RUN] Would reboot host and wait for it to come back online." -Color DarkYellow
                $hostResult.CertRegen = "OK"
                $hostResult.Rebooted  = "OK"
            } else {
                # Always read cert thumbprint and expiry -- no SSH required
                $certCheck = Test-ESXiCertificateNeedsRegen -VMHost $esxiHost
                $hostResult.Thumbprint = $certCheck.Thumbprint
                $hostResult.Expiry     = $certCheck.Expiry

                if (-not $certCheck.NeedsRegen) {
                    $hostResult.CertRegen = "Skipped"
                    $hostResult.Rebooted  = "Skipped"
                } elseif (-not $script:SSHClientAvailable) {
                    Write-Log "  OpenSSH client not available. Certificate regeneration skipped." -Level WARN
                    Write-Log "  ACTION REQUIRED: Manually run on this host and then reboot:" -Level WARN
                    Write-Log "    /sbin/generate-certificates"
                    $hostResult.CertRegen = "Manual"
                    $hostResult.Rebooted  = "Manual"
                } else {
                    # Verify the ESXi configured hostname matches the FQDN from the
                    # hosts file before attempting regen -- generate-certificates uses
                    # the host's own configured FQDN, so a hostname mismatch means
                    # regen would produce the same wrong CN and the reboot is wasted.
                    $hostNet    = Get-VMHostNetwork -VMHost $vmHostObj
                    $esxiFqdn   = "$($hostNet.HostName).$($hostNet.DomainName)".ToLower().TrimEnd('.')
                    $hostnameOk = ($esxiFqdn -eq $esxiHost.ToLower())

                    # Mismatch is fixable from here: offer to set the hostname from the
                    # host list, then regenerate. The regen reboots the host anyway, so
                    # the rename costs nothing extra.
                    if (-not $hostnameOk) {
                        Write-Log "  ESXi hostname '$esxiFqdn' does not match expected FQDN '$esxiHost'." -Level WARN
                        $hostnameOk = Repair-ESXiHostname `
                            -VMHost      $esxiHost `
                            -VMHostObj   $vmHostObj `
                            -HostNetwork $hostNet
                    }

                    if (-not $hostnameOk) {
                        Write-Log "  Certificate regeneration skipped: fix the ESXi hostname first or" -Level WARN
                        Write-Log "  the regenerated certificate will still have the wrong CN." -Level WARN
                        $hostResult.CertRegen = "CN mismatch"
                        $hostResult.Rebooted  = "Skipped"
                        $hostResult.Error     = "ESXi hostname '$esxiFqdn' does not match '$esxiHost' -- correct the hostname before commissioning."
                    } else {

                    $certRegenSuccess = Invoke-ESXiCertificateRegen `
                        -VMHost     $esxiHost `
                        -VMHostObj  $vmHostObj `
                        -Credential $esxiCredentials

                    if ($certRegenSuccess) {
                        $hostResult.CertRegen = "OK"

                        # Disconnect cleanly before reboot
                        Disconnect-VIServer -Server $esxiHost -Confirm:$false -ErrorAction SilentlyContinue
                        Write-Log "  Disconnected. Initiating reboot of $esxiHost..." -Level WARN

                        # Reconnect temporarily to issue the reboot command
                        Connect-VIServer -Server $esxiHost -Credential $esxiCredentials -ErrorAction Stop | Out-Null
                        $rebootHostObj = Get-VMHost -Name $esxiHost -ErrorAction Stop
                        Restart-VMHost -VMHost $rebootHostObj -Confirm:$false -Force -ErrorAction Stop | Out-Null
                        Disconnect-VIServer -Server $esxiHost -Confirm:$false -ErrorAction SilentlyContinue
                        Write-Log "  Reboot issued. Waiting for host to come back online..." -Level WARN

                        # Wait for the host to come back (throws on timeout)
                        Wait-ESXiHostOnline -VMHost $esxiHost
                        $hostResult.Rebooted = "OK"

                        # Reconnect for remaining steps (password reset)
                        Write-Log "  Reconnecting to $esxiHost..."
                        Connect-VIServer -Server $esxiHost -Credential $esxiCredentials -ErrorAction Stop | Out-Null
                        $vmHostObj = Get-VMHost -Name $esxiHost -ErrorAction Stop
                        Write-Log "  Reconnected to $esxiHost." -Color Green

                        # Re-read cert -- verify CN now matches and capture new thumbprint
                        Write-Log "  Reading new certificate thumbprint..."
                        $newCertCheck = Test-ESXiCertificateNeedsRegen -VMHost $esxiHost
                        $hostResult.Thumbprint = $newCertCheck.Thumbprint
                        $hostResult.Expiry     = $newCertCheck.Expiry
                        if ($newCertCheck.NeedsRegen) {
                            $hostResult.CertRegen = "CN mismatch"
                            $hostResult.Error     = "Certificate CN '$($newCertCheck.CN)' still does not match '$esxiHost' after regeneration -- correct the ESXi hostname before commissioning."
                            Write-Log "  WARNING: Certificate CN still does not match hostname after regeneration." -Level WARN
                            Write-Log "  CN: $($newCertCheck.CN)  --  Expected: $esxiHost" -Level WARN
                        }
                    }
                    } # end hostname-matches-fqdn check
                }
            }
        } catch {
            # Distinguish a reboot timeout from other cert regen failures
            if ($_ -match "Timed out waiting") {
                $hostResult.CertRegen = "OK"       # regen itself succeeded
                $hostResult.Rebooted  = "Timeout"  # host never came back
                $hostResult.Error     = "Host did not come back online after reboot within the timeout period. Check the host console for hardware or boot errors."
                $script:hostTimedOut  = $true
                Write-Log ""
                Write-Log ("  " + ("!" * 58)) -Level ERROR
                Write-Log "  !! REBOOT TIMEOUT: $esxiHost did not come back online !!" -Level ERROR
                Write-Log "  !! Check the host console for hardware or boot errors. !!" -Level ERROR
                Write-Log ("  " + ("!" * 58)) -Level ERROR
                Write-Log ""
            } else {
                $hostResult.CertRegen = "FAILED: $_"
                Write-Log "  Certificate regeneration/reboot failed: $_" -Level WARN
            }
        }

        # --- Password Reset (always last) ---
        if ($ResetPassword) {
            Write-Log "`n  [Password Reset]"
            try {
                if ($DryRun) {
                    Write-Log "  [DRY RUN] Would reset password for 'root'." -Color DarkYellow
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
                Write-Log "  Password reset failed: $_" -Level WARN
            }
        }

        } # end else (not WhatIfReport)

    } catch {
        $hostResult.Error = $_.Exception.Message
        Write-Log "  Failed to process host '$esxiHost': $_" -Level WARN
    } finally {
        if ($hostResult.Connected -and -not $DryRun) {
            if ($script:hostTimedOut) {
                # Host never came back  --  skip disconnect, it will just throw a noisy error
                Write-Log "`n  Host is unreachable  --  skipping disconnect." -Color DarkGray
            } else {
                Disconnect-VIServer -Server $esxiHost -Confirm:$false -ErrorAction SilentlyContinue
                Write-Log "`n  Disconnected from $esxiHost." -Color Gray
            }
        } elseif ($DryRun) {
            Write-Log "`n  [DRY RUN] Would disconnect from $esxiHost." -Color DarkYellow
        }
    }

    $results.Add($hostResult)
}

#endregion

#region --- Summary ---

# Derive summary banner width from column definitions (matches Write-ColorSummaryTable divider)
$summaryColumnWidths = @(34, 11, 14, 6, 17, 17, 14, 10, 10, 15, 28)
$summaryWidth = ($summaryColumnWidths | Measure-Object -Sum).Sum + ($summaryColumnWidths.Count * 3) + 1


Write-Log ""
Write-Log ("=" * $summaryWidth) -Color DarkCyan
Write-Log ("  SUMMARY  -  {0} host(s) processed  --  {1}" -f $results.Count, $ScriptMeta.Blog)
Write-Log ("=" * $summaryWidth) -Color DarkCyan

Write-ColorSummaryTable -Data $results

# Legend
Write-Log ""
Write-Log "  Legend: " -Color White -NoNewline
Write-Log "OK  "      -Color Green   -NoNewline
Write-Log "FAILED  "  -Level ERROR   -NoNewline
Write-Log "Timeout  " -Level ERROR   -NoNewline
Write-Log "Skipped  " -Color DarkGray -NoNewline
Write-Log "Manual  "  -Level WARN    -NoNewline
Write-Log "Partial  " -Level WARN    -NoNewline
Write-Log "Warning"   -Level WARN
Write-Log ""
Write-Log ("  Log written to    : {0}" -f $LogPath) -Color DarkGray

Write-HtmlReport -Data $results -ReportPath $ReportPath -WhatIfReport:$WhatIfReport

# Export commissioning CSV for use by Commission-VCFHosts.ps1
# Only includes hosts that connected successfully and have a valid thumbprint
$csvRows = $results | Where-Object { $_.Connected -eq $true -and $_.Thumbprint -ne "N/A" } |
    Select-Object `
        @{ Name = "FQDN";        Expression = { $_.Host } },
        @{ Name = "Thumbprint";  Expression = { $_.Thumbprint } },
        @{ Name = "StorageType"; Expression = { $_.StorageType } }

if ($csvRows) {
    $csvRows | Export-Csv -Path $CsvPath -NoTypeInformation -Encoding UTF8
    Write-Log ("  Commissioning CSV : {0}" -f $CsvPath)
    Write-Log ("  {0} host(s) exported to CSV." -f @($csvRows).Count) -Color DarkGray
} else {
    Write-Log "  No hosts with valid thumbprints  --  CSV not written." -Level WARN
}

# Remove the throwaway SSH credential helper created for this run (if any)
if ($script:HostPrepSSHAuth) {
    Remove-Item -Path $script:HostPrepSSHAuth.KeyDir -Recurse -Force -ErrorAction SilentlyContinue
    $script:HostPrepSSHAuth = $null
    Write-Log "  Temporary SSH credential helper removed." -Color DarkGray
}

Write-Log ("=" * $summaryWidth) -Color DarkCyan
Write-Log ""

#endregion
