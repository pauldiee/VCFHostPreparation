# VCF Host Preparation and Commissioning

Two PowerShell scripts that automate ESXi host preparation and commissioning for **VMware Cloud Foundation 9 / SDDC Manager**.

| Script | Version | Purpose |
|---|---|---|
| `HostPrep.ps1` | 4.0.0 | Prepares ESXi hosts — DNS, NTP, certificates, storage detection, disk wipe, advanced settings, password reset |
| `Commission-VCFHosts.ps1` | 3.1.0 | Commissions prepared hosts into SDDC Manager via the REST API |

Run `HostPrep.ps1` first, then hand the generated CSV to `Commission-VCFHosts.ps1`.

![HostPrep console output](https://www.hollebollevsan.nl/wp-content/uploads/2026/03/HostPrep-Console-Screenshot.jpg)

---

## HostPrep.ps1

### What it does

Reads a plain text file with one ESXi FQDN per line and runs the following steps on each host in order:

1. **DNS validation** — forward A record and reverse PTR lookup; flags mismatches before anything else runs
2. **Connect** — connects directly to the host using the root account via PowerCLI
3. **NTP** — verifies required NTP servers are configured and `ntpd` is running and set to start automatically
4. **Advanced Settings** — sets `Config.HostAgent.ssl.keyStore.allowSelfSigned = true`, required by SDDC Manager
5. **Optional Advanced Settings** — applies any extra settings enabled in the `$OptionalAdvancedSettings` block
6. **Storage type detection** — detects the primary storage type for the commissioning CSV (see below)
6b. **vSAN disk wipe** *(optional, `-WipeDisk` only)* — enumerates non-boot disks with existing partitions and wipes them via `partedUtil` over SSH, preparing disks for clean vSAN commissioning (see below)
7. **Certificate regeneration** — reads the TLS certificate from port 443 and checks whether the CN matches the host FQDN. If not: temporarily enables SSH, runs `/sbin/generate-certificates` via Posh-SSH, disables SSH, reboots, waits for the host to return online
8. **Password reset** *(optional)* — resets the root password to a VCF 9 compliant value; always runs last so the existing credential stays valid throughout

After all hosts are processed:
- A colourised summary table is printed to the console
- A self-contained **HTML commissioning report** is saved next to the script with SHA256 thumbprints, cert expiry, DNS status, and per-step results
- A **commissioning CSV** is saved for use by `Commission-VCFHosts.ps1`

![HostPrep HTML commissioning report](https://www.hollebollevsan.nl/wp-content/uploads/2026/03/HostPrep-Report-Screenshot.jpg)

### vSAN disk wipe

Use `-WipeDisk` to clean disks on hosts that were previously part of a vSAN cluster before recommissioning them into VCF. The script:

1. Enumerates all storage devices via `esxcli`
2. Identifies and **unconditionally excludes** the boot disk (`IsBootDrive` flag; falls back to ≤ 8 GB size heuristic if the flag is not set)
3. Lists all non-boot disks with existing partition tables
4. Prompts **Y/N** per host before wiping anything
5. Unmounts any VMFS datastores on target disks, then wipes partition tables via SSH: `partedUtil mklabel <device> gpt`
6. Disables SSH again when done

**Only runs for hosts detected as `VSAN`.** Skipped automatically for `VMFS_FC` and `NFS` hosts.

Requires Posh-SSH. Without it the script prints per-host manual SSH instructions instead of failing.

```powershell
# Wipe vSAN disks during host prep
.\HostPrep.ps1 -WipeDisk

# Dry run -- shows which disks would be wiped, no changes made
.\HostPrep.ps1 -WipeDisk -DryRun
```

> **Boot disk is always protected.** It is excluded at enumeration time and never reaches `partedUtil` regardless of the Y/N answer.

### Storage type detection

After connecting to each host, `HostPrep.ps1` detects the storage type and writes it to the commissioning CSV:

| Detected value | Condition |
|---|---|
| `VMFS_FC` | Fibre Channel HBA present |
| `NFS` | NFS datastore mounted |
| `VSAN` | Default — all other hosts (unclaimed disks) |

> **vSAN OSA vs ESA cannot be auto-detected.** On a freshly prepped host disks are unclaimed — no disk groups or storage pools exist yet. If `VSAN_ESA` or `VVOL` is intended, edit the `StorageType` column in the generated CSV before running `Commission-VCFHosts.ps1`. That script reads the value as-is without prompting.

### Requirements

| Requirement | Notes |
|---|---|
| PowerShell 5.1 | Included with Windows 10 / Server 2016 and later |
| VMware PowerCLI | `Install-Module -Name VMware.PowerCLI -Scope CurrentUser` |
| Posh-SSH | Optional — required for automated cert regen and `-WipeDisk`. `Install-Module -Name Posh-SSH -Scope CurrentUser` |

One-time PowerCLI setup (run once per user account):

```powershell
Set-PowerCLIConfiguration -Scope User -ParticipateInCEIP $false -Confirm:$false
```

Without Posh-SSH the script prints per-host manual instructions for the certificate and disk wipe steps.

### Usage

```powershell
# Interactive -- all prompts at runtime
.\HostPrep.ps1

# Custom NTP servers
.\HostPrep.ps1 -NtpServers "ntp1.example.com","ntp2.example.com"

# Simulate all steps without making any changes
.\HostPrep.ps1 -DryRun

# Collect thumbprints and generate report/CSV without making any changes
.\HostPrep.ps1 -WhatIfReport

# Wipe vSAN disks during prep (prompts Y/N per host)
.\HostPrep.ps1 -WipeDisk

# Dry run with disk wipe simulation
.\HostPrep.ps1 -WipeDisk -DryRun
```

### Parameters

| Parameter | Type | Default | Description |
|---|---|---|---|
| `-NtpServers` | `string[]` | `pool.ntp.org` | One or more NTP server addresses |
| `-DryRun` | `switch` | — | Simulate all steps, no changes made |
| `-WhatIfReport` | `switch` | — | Read thumbprints and generate report/CSV without changes |
| `-LogPath` | `string` | Next to script | Path for the transcript log |
| `-ReportPath` | `string` | Next to script | Path for the HTML commissioning report |
| `-WipeDisk` | `switch` | — | Wipe non-boot partitioned disks on VSAN hosts via SSH before cert regen |
| `-CsvPath` | `string` | Next to script | Path for the commissioning CSV |

### Host list file

A plain text file with one FQDN per line. Lines starting with `#` are treated as comments.

```
esxi01.vcf.lab
esxi02.vcf.lab
# esxi03.vcf.lab  -- skipped
esxi04.vcf.lab
```

### Optional Advanced Settings

The `$OptionalAdvancedSettings` block near the top of the script contains extra settings, all disabled by default. Set `Enabled = $true` to apply on every host:

| Setting | Description |
|---|---|
| `Config.HostAgent.plugins.hostsvc.esxAdminsGroup` | AD group whose members get full ESXi admin access. Change the value to match your AD group name. |
| `LSOM.lsomEnableRebuildOnLSE` | Enables automatic vSAN rebuild when a device is flagged as LSE |
| `DataMover.HardwareAcceleratedMove` | Enables SSD TRIM — ESXi issues UNMAP to compatible SSDs |
| `DataMover.HardwareAcceleratedInit` | Enables SSD TRIM — ESXi issues UNMAP to compatible SSDs |

### VCF 9 password requirements

If a password reset is requested, the new value is validated before any host is touched:

- 15 to 40 characters
- At least 1 lowercase letter
- At least 1 uppercase letter — not as the first character
- At least 1 digit — not as the last character
- At least 1 special character from: `@ ! # $ % ? ^`
- Only letters, digits, and `@ ! # $ % ? ^` permitted
- At least 3 of the 4 character classes must be present

---

## Commission-VCFHosts.ps1

Reads the CSV produced by `HostPrep.ps1` and commissions all hosts into SDDC Manager in a single batch via the REST API.

### What it does

1. Reads the CSV — FQDN, thumbprint, detected storage type per host
2. Prompts for SDDC Manager FQDN, username and password
3. Authenticates and retrieves a Bearer token; detects SDDC Manager version via `GET /v1/sddc-managers`
4. Retrieves available network pools and prompts for selection
5. Displays the detected storage type per host — no prompting; edit the CSV `StorageType` column before running if any value needs changing (`VSAN_ESA` and `VVOL` must be set manually)
6. Prompts for the ESXi root password (required by SDDC Manager for both validation and commissioning)
7. Saves a sanitised JSON payload to disk (password masked as `********`) before sending anything
8. Validates hosts via `POST /v1/hosts/validations`:
   - Flattens the VCF 9 nested check structure to get per-host leaf results
   - Prints every check with PASS/FAIL/WARN icons and full error detail including `errorResponse.message`
   - Saves the full validation response JSON to disk
   - Writes a dark-mode HTML validation report and opens it in the browser
   - Aborts on failure
9. Commissions hosts via `POST /v1/hosts`
10. Polls the task every 15 seconds until `SUCCESSFUL`, `FAILED`, or timeout
11. Queries `GET /v1/hosts` to retrieve the SDDC Manager host UUID per commissioned host
12. Prints a colourised per-host summary table with host UUIDs
13. Writes a dark-mode HTML commissioning report and results CSV; opens the report in the browser

### Storage type

The `StorageType` column is read directly from the CSV — no prompting at runtime. `HostPrep.ps1` detects `VMFS_FC` and `NFS` automatically; everything else defaults to `VSAN`. To use `VSAN_ESA` or `VVOL`, edit the column in the CSV and re-run.

```
  Storage types from CSV:
  (To change a value, edit the StorageType column in the CSV and re-run)
  Valid values: VSAN, VSAN_ESA, NFS, VMFS_FC, VVOL

    esxi01.vcf.lab                             VSAN_ESA
    esxi02.vcf.lab                             VSAN_ESA
    esxi03.vcf.lab                             VMFS_FC
```

### Validation report

The HTML validation report (`Commission_<timestamp>_ValidationReport.html`) is written after every validation run — pass, fail, or `-ValidateOnly`. It shows:

- **Stat cards** — overall status (from `resultStatus` field), plus pass/warn/fail counts for host-level checks only (the "Validating input specification" wrapper is excluded from counts)
- **Per-host summary table** — actual `resultStatus` per host matched from the flattened check list, with the error message (`errorResponse.message`) displayed underneath in the appropriate colour
- **Validation checks table** — all leaf checks from the flattened structure with nested detail expanded inline

### Output files

All files are written next to the script with a timestamp prefix:

| File | Written when |
|---|---|
| `Commission_<ts>_Payload.json` | Always — sanitised payload, password masked |
| `Commission_<ts>_ValidationResponse.json` | Always — raw SDDC Manager validation response |
| `Commission_<ts>_ValidationReport.html` | Always after validation (pass or fail) |
| `Commission_<ts>_Report.html` | After successful commissioning |
| `Commission_<ts>_Results.csv` | After successful commissioning |

### `-ValidateOnly` mode

Runs validation without commissioning anything. All output files above except the commissioning report and results CSV are written:

```powershell
.\Commission-VCFHosts.ps1 -ValidateOnly
```

### Usage

```powershell
# Interactive -- all prompts at runtime
.\Commission-VCFHosts.ps1

# Pass CSV and SDDC Manager directly
.\Commission-VCFHosts.ps1 -CsvPath "C:\VCF\HostPrep_20260320_Commissioning.csv" -SddcManager sddc-manager.vcf.lab

# Validate only -- no commissioning
.\Commission-VCFHosts.ps1 -ValidateOnly

# Lab environment with self-signed certificate on SDDC Manager
.\Commission-VCFHosts.ps1 -SkipCertificateCheck

# Validate only, pass all args
.\Commission-VCFHosts.ps1 -ValidateOnly -SddcManager sddc-manager.vcf.lab -CsvPath "C:\VCF\hosts.csv"
```

### Parameters

| Parameter | Type | Default | Description |
|---|---|---|---|
| `-CsvPath` | `string` | Prompted | Path to the HostPrep commissioning CSV |
| `-SddcManager` | `string` | Prompted | FQDN of the SDDC Manager appliance |
| `-TimeoutMinutes` | `int` | `30` | Maximum minutes to wait for the commission task |
| `-ValidateOnly` | `switch` | — | Run validation only, do not commission |
| `-SkipCertificateCheck` | `switch` | — | Ignore TLS errors — for lab use |
| `-SavePayload` | `switch` | — | Retained for compatibility; payload is always saved |
| `-ReportPath` | `string` | Next to script | Path for the commissioning HTML report |
| `-OutputCsvPath` | `string` | Next to script | Path for the commissioning results CSV |
| `-PayloadPath` | `string` | Next to script | Path for the sanitised JSON payload |
| `-ValidateReportPath` | `string` | Next to script | Path for the validation HTML report |

### Requirements

No additional modules required beyond PowerShell 5.1. All API calls use `Invoke-RestMethod`.

---

## Blog post

Full write-up with background and screenshots:  
[Automating ESXi Host Preparation for VCF 9 with PowerShell – HolleBollevSAN](https://www.hollebollevsan.nl/automating-esxi-host-preparation-for-vcf-9-with-powershell/)

---

## Next step

Once your hosts are commissioned into SDDC Manager, use the scripts in [VCFJsonSpecCreators](https://github.com/pauldiee/VCFJsonSpecCreators) to build the JSON payloads for creating network pools, workload domains, and clusters.

---

## Author

Paul van Dieen — [hollebollevsan.nl](https://www.hollebollevsan.nl)
