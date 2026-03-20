# VCF Host Preparation and Commissioning

A pair of PowerShell scripts that automate ESXi host preparation and commissioning for **VMware Cloud Foundation 9 / SDDC Manager**.

| Script | Purpose |
|---|---|
| `HostPrep.ps1` | Prepares ESXi hosts — DNS, NTP, certificates, advanced settings, password reset |
| `Commission-VCFHosts.ps1` | Commissions prepared hosts into SDDC Manager via the REST API |

The typical workflow is: run `HostPrep.ps1` first, then hand off the generated CSV to `Commission-VCFHosts.ps1`.

![HostPrep console output](https://www.hollebollevsan.nl/wp-content/uploads/2026/03/HostPrep-Console-Screenshot.jpg)

---

## HostPrep.ps1

### What it does

For each host in your list, the script runs through the following steps in order:

1. **DNS validation** — forward (A record) and reverse (PTR) lookup, flags mismatches before anything else runs
2. **Connect** — connects directly to the ESXi host using the root account via PowerCLI
3. **NTP** — verifies the required NTP servers are configured and that `ntpd` is running and set to start automatically
4. **Advanced Settings** — sets `Config.HostAgent.ssl.keyStore.allowSelfSigned = true`, required by SDDC Manager
5. **Optional Advanced Settings** — applies any extra settings you have enabled in the `$OptionalAdvancedSettings` block at the top of the script
6. **Certificate regeneration** — reads the TLS certificate from port 443 and checks whether the CN matches the host FQDN. If not, it temporarily enables SSH, runs `/sbin/generate-certificates` via Posh-SSH, disables SSH again, then reboots the host and waits for it to come back online before continuing
7. **Password reset** *(optional)* — resets the root account password to a new VCF 9 compliant value. Always runs last so the existing credential remains valid throughout

After all hosts are processed, a colourised summary table is printed, a self-contained HTML report is saved next to the script, and a commissioning CSV is written for use by `Commission-VCFHosts.ps1`.

![HostPrep HTML commissioning report](https://www.hollebollevsan.nl/wp-content/uploads/2026/03/HostPrep-Report-Screenshot.jpg)

### Requirements

| Requirement | Notes |
|---|---|
| PowerShell 5.1+ | Included with Windows 10 / Server 2016 and later |
| VMware PowerCLI | `Install-Module -Name VMware.PowerCLI -Scope CurrentUser` |
| Posh-SSH | Optional — needed for automated cert regeneration. `Install-Module -Name Posh-SSH -Scope CurrentUser` |

**One-time PowerCLI setup** (run once per user account, then never again):

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
| `-WhatIfReport` | `switch` | — | Connect and collect thumbprints only, generate report and CSV |
| `-LogPath` | `string` | Desktop | Path for the transcript log file |
| `-ReportPath` | `string` | Next to script | Path for the HTML report file |
| `-CsvPath` | `string` | Next to script | Path for the commissioning CSV file |

### Host list file

The script prompts for the path to a plain text file with one FQDN per line. Lines starting with `#` are treated as comments and ignored.

```
esxi01.vcf.lab
esxi02.vcf.lab
# esxi03.vcf.lab  (skipped)
esxi04.vcf.lab
```

### HTML commissioning report

The report is saved as `HostPrep_<timestamp>_Report.html` next to the script. For each host it shows:

- **SSL thumbprint** in `SHA256:<base64>` format (exactly as SDDC Manager expects) with a one-click copy button
- **Certificate expiry** — highlighted amber within 90 days, red within 30
- **DNS status** — forward and reverse lookup result
- **Per-step status** — cert regen, reboot, NTP, advanced settings, optional settings, password reset
- **Overall pass/fail indicator**

### Commissioning CSV

After each run a CSV file is saved as `HostPrep_<timestamp>_Commissioning.csv` next to the script. It contains one row per host that connected successfully and has a valid thumbprint:

```
FQDN,Thumbprint,StorageType
esxi01.vcf.lab,SHA256:abc123...,VSAN
esxi02.vcf.lab,SHA256:def456...,VSAN
```

This file is the input for `Commission-VCFHosts.ps1`.

### Optional Advanced Settings

Near the top of the script there is an `$OptionalAdvancedSettings` block. Each entry is disabled by default — set `Enabled = $true` to apply it on every host.

| Setting | Description | Value type |
|---|---|---|
| `Config.HostAgent.plugins.hostsvc.esxAdminsGroup` | AD group whose members get full ESXi admin access | string |
| `LSOM.lsomEnableRebuildOnLSE` | Enables automatic vSAN rebuild when a device is flagged as LSE | integer (1/0) |
| `DataMover.HardwareAcceleratedMove` | Enables SSD TRIM — ESXi issues UNMAP commands to compatible SSDs | integer (1/0) |
| `DataMover.HardwareAcceleratedInit` | Enables SSD TRIM — ESXi issues UNMAP commands to compatible SSDs | integer (1/0) |

> **Note:** Re-running the script with a different `esxAdminsGroup` value will overwrite the setting on all hosts. Verify the group name before enabling.

### DNS validation

| Result | Meaning |
|---|---|
| `OK` | A record resolves and PTR matches the FQDN |
| `WARN: PTR mismatch` | A record resolves but PTR points to a different name |
| `WARN: No PTR record` | A record resolves but no PTR exists |
| `FAILED` | Forward lookup failed entirely |

DNS issues are flagged but do not block the remaining preparation steps. Fix any warnings before commissioning.

### Summary table colours

| Colour | Meaning |
|---|---|
| 🟢 Green | OK |
| 🔴 Red | FAILED or Timeout |
| ⬜ Dark gray | Skipped |
| 🟡 Yellow | Manual action required, Partial, or Warning |

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

1. Reads the commissioning CSV (FQDN, thumbprint, storage type)
2. Prompts for SDDC Manager FQDN, username and password
3. Authenticates and retrieves a Bearer token
4. Detects the SDDC Manager version
5. Retrieves available network pools and prompts for selection
6. Confirms or overrides the storage type from the CSV
7. Prompts for the ESXi root password (required by SDDC Manager)
8. Validates hosts via `POST /v1/hosts/validations` — aborts with a per-check error breakdown if validation fails
9. Commissions hosts via `POST /v1/hosts`
10. Polls the task every 15 seconds until `SUCCESSFUL`, `FAILED`, or timeout
11. Prints a colourised per-host result summary with task ID and SDDC Manager link

### Usage

Run interactively — all prompts are handled at runtime:

```powershell
.\Commission-VCFHosts.ps1
```

Pass the CSV path and SDDC Manager FQDN directly:

```powershell
.\Commission-VCFHosts.ps1 -CsvPath "C:\VCF\HostPrep_20260320_Commissioning.csv" -SddcManager sddc-manager.vcf.lab
```

In lab environments with self-signed certificates on SDDC Manager:

```powershell
.\Commission-VCFHosts.ps1 -SkipCertificateCheck
```

### Parameters

| Parameter | Type | Default | Description |
|---|---|---|---|
| `-CsvPath` | `string` | Prompted | Path to the HostPrep commissioning CSV |
| `-SddcManager` | `string` | Prompted | FQDN of the SDDC Manager appliance |
| `-TimeoutMinutes` | `int` | `30` | Maximum minutes to wait for the task to complete |
| `-SkipCertificateCheck` | `switch` | — | Ignore TLS errors — useful for lab environments |

### Requirements

No additional modules required beyond standard PowerShell 5.1. All API calls use `Invoke-RestMethod`.

---

## Blog post

Full write-up with background and screenshots:  
[Automating ESXi Host Preparation for VCF 9 with PowerShell – HolleBollevSAN](https://www.hollebollevsan.nl/automating-esxi-host-preparation-for-vcf-9-with-powershell/)

---

## Author

Paul van Dieen — [hollebollevsan.nl](https://www.hollebollevsan.nl)
