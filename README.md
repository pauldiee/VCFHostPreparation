# VCF Host Preparation and Commissioning

A pair of PowerShell scripts that automate ESXi host preparation and commissioning for **VMware Cloud Foundation 9 / SDDC Manager**.

| Script | Purpose |
|---|---|
| `HostPrep.ps1` | Prepares ESXi hosts — DNS, NTP, certificates, storage type detection, advanced settings, password reset |
| `Commission-VCFHosts.ps1` | Commissions prepared hosts into SDDC Manager via the REST API |

The typical workflow is: run `HostPrep.ps1` first, then hand the generated CSV to `Commission-VCFHosts.ps1`.

![HostPrep console output](https://www.hollebollevsan.nl/wp-content/uploads/2026/03/HostPrep-Console-Screenshot.jpg)

---

## HostPrep.ps1

### What it does

For each host in your list, the script runs through the following steps in order:

1. **DNS validation** — forward (A record) and reverse (PTR) lookup, flags mismatches before anything else runs
2. **Connect** — connects directly to the host using the root account via PowerCLI
3. **NTP** — verifies the required NTP servers are configured and that `ntpd` is running and set to start automatically
4. **Advanced Settings** — sets `Config.HostAgent.ssl.keyStore.allowSelfSigned = true`, required by SDDC Manager
5. **Optional Advanced Settings** — applies any extra settings enabled in the `$OptionalAdvancedSettings` block at the top of the script
6. **Storage type detection** — detects the primary storage type for the commissioning CSV (see below)
7. **Certificate regeneration** — reads the TLS certificate from port 443 and checks whether the CN matches the host FQDN. If not, temporarily enables SSH, runs `/sbin/generate-certificates` via Posh-SSH, disables SSH again, reboots, and waits for the host to come back online
8. **Password reset** *(optional)* — resets the root password to a VCF 9 compliant value. Always runs last so the existing credential stays valid throughout

After all hosts are processed:
- A colourised summary table is printed to the console
- A self-contained **HTML commissioning report** is saved next to the script
- A **commissioning CSV** is saved for use by `Commission-VCFHosts.ps1`

![HostPrep HTML commissioning report](https://www.hollebollevsan.nl/wp-content/uploads/2026/03/HostPrep-Report-Screenshot.jpg)

### Storage type detection

After connecting to each host, `HostPrep.ps1` detects the storage type and writes it to the commissioning CSV:

| Result | Condition |
|---|---|
| `VMFS_FC` | Fibre Channel HBA detected |
| `NFS` | NFS datastore mounted |
| `VSAN` | Default for all other hosts |

> **vSAN OSA vs ESA cannot be auto-detected.** On a freshly prepped host about to be commissioned, disks are unclaimed — no disk groups or storage pools exist yet. The choice between OSA and ESA is a deployment design decision. If your hosts are intended for vSAN ESA, override the storage type to `VSAN_ESA` interactively in `Commission-VCFHosts.ps1` when prompted, or edit the CSV directly before running that script.

### Requirements

| Requirement | Notes |
|---|---|
| PowerShell 5.1+ | Included with Windows 10 / Server 2016 and later |
| VMware PowerCLI | `Install-Module -Name VMware.PowerCLI -Scope CurrentUser` |
| Posh-SSH | Optional — needed for automated cert regeneration. `Install-Module -Name Posh-SSH -Scope CurrentUser` |

**One-time PowerCLI setup** (run once per user account):

```powershell
Set-PowerCLIConfiguration -Scope User -ParticipateInCEIP $false -Confirm:$false
```

### Usage

Basic run — all prompts are interactive:

```powershell
.\HostPrep.ps1
```

With custom NTP servers:

```powershell
.\HostPrep.ps1 -NtpServers "ntp1.example.com","ntp2.example.com"
```

Simulate all steps without making any changes:

```powershell
.\HostPrep.ps1 -DryRun
```

Collect thumbprints and generate the HTML report and CSV without making any changes:

```powershell
.\HostPrep.ps1 -WhatIfReport
```

### Parameters

| Parameter | Type | Default | Description |
|---|---|---|---|
| `-NtpServers` | `string[]` | `pool.ntp.org` | One or more NTP server addresses |
| `-DryRun` | `switch` | — | Simulate all steps, no changes made |
| `-WhatIfReport` | `switch` | — | Read thumbprints and generate report/CSV, no changes |
| `-LogPath` | `string` | Desktop | Path for the transcript log file |
| `-ReportPath` | `string` | Next to script | Path for the HTML commissioning report |
| `-CsvPath` | `string` | Next to script | Path for the commissioning CSV |

### Host list file

A plain text file with one FQDN per line. Lines starting with `#` are treated as comments and ignored.

```
esxi01.vcf.lab
esxi02.vcf.lab
# esxi03.vcf.lab  (skipped)
esxi04.vcf.lab
```

### HTML commissioning report

Saved as `HostPrep_<timestamp>_Report.html` next to the script. For each host it shows:

- **SSL thumbprint** in `SHA256:<base64>` format (exactly as SDDC Manager expects) with a one-click copy button
- **Certificate expiry** — highlighted amber within 90 days, red within 30
- **DNS status** — forward and reverse lookup result
- **Per-step status** — cert regen, reboot, NTP, advanced settings, optional settings, password reset
- **Overall pass/fail indicator**

### Commissioning CSV

Saved as `HostPrep_<timestamp>_Commissioning.csv`. One row per host that connected successfully:

```
FQDN,Thumbprint,StorageType
esxi01.vcf.lab,SHA256:abc123...,VSAN
esxi02.vcf.lab,SHA256:def456...,VMFS_FC
```

This file is the input for `Commission-VCFHosts.ps1`.

### Optional Advanced Settings

The `$OptionalAdvancedSettings` block near the top of the script contains extra settings, all disabled by default. Set `Enabled = $true` to apply on every host.

| Setting | Description | Value type |
|---|---|---|
| `Config.HostAgent.plugins.hostsvc.esxAdminsGroup` | AD group whose members get full ESXi admin access | string |
| `LSOM.lsomEnableRebuildOnLSE` | Enables automatic vSAN rebuild when a device is flagged as LSE | integer (1/0) |
| `DataMover.HardwareAcceleratedMove` | Enables SSD TRIM — ESXi issues UNMAP to compatible SSDs | integer (1/0) |
| `DataMover.HardwareAcceleratedInit` | Enables SSD TRIM — ESXi issues UNMAP to compatible SSDs | integer (1/0) |

> Re-running with a different `esxAdminsGroup` value will overwrite the setting. Verify the group name before enabling across a full deployment.

### DNS validation

| Result | Meaning |
|---|---|
| `OK` | A record resolves and PTR matches the FQDN |
| `WARN: PTR mismatch` | A record resolves but PTR points to a different name |
| `WARN: No PTR record` | A record resolves but no PTR exists |
| `FAILED` | Forward lookup failed entirely |

DNS issues are flagged but do not block the remaining preparation steps. Fix any warnings before commissioning — SDDC Manager requires correct forward and reverse DNS.

### VCF 9 password requirements

If a password reset is requested, the new password is validated against VCF 9 rules before any host is touched:

- 15 to 40 characters
- At least 1 lowercase letter
- At least 1 uppercase letter — not as the first character
- At least 1 digit — not as the last character
- At least 1 special character from: `@ ! # $ % ? ^`
- Only letters, digits, and `@ ! # $ % ? ^` permitted
- At least 3 of the 4 character classes must be present

### Reboot timeout handling

If a host does not come back online after a certificate-triggered reboot, the script sets `Rebooted = Timeout`, prints a prominent red banner, skips the disconnect to avoid noisy errors, and continues with the next host.

---

## Commission-VCFHosts.ps1

Reads the CSV produced by `HostPrep.ps1` and commissions all hosts into SDDC Manager in a single batch via the REST API.

### What it does

1. Reads the commissioning CSV — FQDN, thumbprint, and detected storage type per host
2. Prompts for SDDC Manager FQDN, username and password
3. Authenticates and retrieves a Bearer token, detects SDDC Manager version
4. Retrieves available network pools and prompts for selection
5. Shows the detected storage type per host with an interactive override prompt — confirm or change per host before commissioning. Override `VSAN` to `VSAN_ESA` here if ESA is intended
6. Prompts for the ESXi root password (required by SDDC Manager)
7. Validates hosts via `POST /v1/hosts/validations` — prints every check with PASS/FAIL/WARN icons, aborts on failure
8. Commissions hosts via `POST /v1/hosts`
9. Polls the task every 15 seconds until `SUCCESSFUL`, `FAILED`, or timeout
10. Queries `GET /v1/hosts` to retrieve the SDDC Manager host UUID for each commissioned host
11. Prints a colourised per-host summary table with host UUIDs
12. Writes a **results CSV** and a **dark-mode HTML report** next to the script

### Storage type override

At step 5 you are shown the storage type that `HostPrep.ps1` detected for each host, and given the opportunity to override it:

```
  esxi01.vcf.lab                           Detected: VSAN
    Press Enter to accept 'VSAN', or type a different storage type: VSAN_ESA
    Using: VSAN_ESA

  esxi02.vcf.lab                           Detected: VMFS_FC
    Press Enter to accept 'VMFS_FC', or type a different storage type:
    Using: VMFS_FC
```

Valid values: `VSAN`, `VSAN_ESA`, `NFS`, `VMFS_FC`, `VVOL`

### Output files

After commissioning completes, two files are written next to the script:

- `Commission_<timestamp>_Results.csv` — per-host results including SDDC Manager host UUID, storage type, network pool, task ID, and timestamp
- `Commission_<timestamp>_Report.html` — dark-mode HTML report with host UUIDs, storage types, network pool, task ID, and per-host status

### -ValidateOnly mode

Run validation without commissioning anything:

```powershell
.\Commission-VCFHosts.ps1 -ValidateOnly
```

Goes through all setup steps then calls `POST /v1/hosts/validations`, prints every check with icons, and exits cleanly:

```
  Validation results:
    [PASS] Certificate thumbprint check
    [PASS] DNS forward lookup
    [WARN] NTP configuration
    [FAIL] Network connectivity check

  VALIDATION SUMMARY
  Hosts checked  : 4
  Checks passed  : 11
  Checks warned  : 1
  Checks failed  : 1

  No hosts were commissioned. Run without -ValidateOnly to proceed.
```

### Usage

Interactive run — all prompts at runtime:

```powershell
.\Commission-VCFHosts.ps1
```

Pass CSV path and SDDC Manager FQDN directly:

```powershell
.\Commission-VCFHosts.ps1 -CsvPath "C:\VCF\HostPrep_20260320_Commissioning.csv" -SddcManager sddc-manager.vcf.lab
```

Validate only, no commissioning:

```powershell
.\Commission-VCFHosts.ps1 -ValidateOnly
```

Lab environment with self-signed certificate on SDDC Manager:

```powershell
.\Commission-VCFHosts.ps1 -SkipCertificateCheck
```

### Parameters

| Parameter | Type | Default | Description |
|---|---|---|---|
| `-CsvPath` | `string` | Prompted | Path to the HostPrep commissioning CSV |
| `-SddcManager` | `string` | Prompted | FQDN of the SDDC Manager appliance |
| `-TimeoutMinutes` | `int` | `30` | Maximum minutes to wait for the task |
| `-ValidateOnly` | `switch` | — | Run validation only, do not commission |
| `-SkipCertificateCheck` | `switch` | — | Ignore TLS errors — for lab use |
| `-ReportPath` | `string` | Next to script | Path for the HTML report |
| `-OutputCsvPath` | `string` | Next to script | Path for the results CSV |

### Requirements

No additional modules required beyond PowerShell 5.1. All API calls use `Invoke-RestMethod`.

---

## Blog post

Full write-up with background and screenshots:  
[Automating ESXi Host Preparation for VCF 9 with PowerShell – HolleBollevSAN](https://www.hollebollevsan.nl/automating-esxi-host-preparation-for-vcf-9-with-powershell/)

---

## Author

Paul van Dieen — [hollebollevsan.nl](https://www.hollebollevsan.nl)
