# Board Sales Invoicing IBM i → Veza OAA Connector

Connects to the IBM i system configured via `DB_HOST` via pyodbc (IBM i Access Client Solutions ODBC driver) and pushes user, role, and menu-permission data into Veza's Access Graph using the OAA CustomApplication template.

---

## 1. Overview

This connector queries three views of the `pdmstrdblb` schema on the IBM i host and maps them to Veza's Open Authorization API (OAA) `CustomApplication` template:

| IBM i Source | OAA Entity | Description |
|---|---|---|
| `pdmstrdblb.asem` (active employees) | **Local User** | User ID, full name, employee ID |
| `pdmstrdblb.asem.EM_ROLE` | **Local Role** | System/Role code assigned to each employee |
| `pdmstrdblb.apmenus` + `pdmstrdblb.apsubmn` (submenu descriptions) | **Application Resource** | Menu/submenu entries the user can access |
| `sec.authority = 'Y' AND sub.updates = 'Y'` → `*UPDATE*` prefix | **Custom Permission: `update`** | Read + Write OAA permissions |
| All other menu entries | **Custom Permission: `view`** | Read-only OAA permission |

**Permission mapping:**

| OAA Custom Permission | OAA Standard Permissions | When Applied |
|---|---|---|
| `view` | `DataRead` | User has access to a submenu without update rights |
| `update` | `DataRead`, `DataWrite` | Submenu description starts with `*UPDATE*` |

---

## 2. Entity Relationship Map

```mermaid
graph LR
    subgraph IBMi["📊 IBM i <your-ibmi-host> — pdmstrdblb"]
        ASEM["pdmstrdblb.asem\nEmployee Master\n(User_ID, User_Name, EIN, ROLE)"]
        ASAS["pdmstrdblb.asas\nSecurity Matrix\n(USRID, MNUPROGRAM, SELECTION, authority)"]
        APMENUS["pdmstrdblb.apmenus\nMenu Definitions\n(MNUPGM, MNUTEXT)"]
        APSUBMN["pdmstrdblb.apsubmn\nSubmenu Definitions\n(MNUPGM, SUBMNU, MNUTEXT, updates)"]
    end

    subgraph Veza["🔷 Veza Access Graph — OAA CustomApplication"]
        LU["Local User\n(User_ID / full_name / employee_id)"]
        LR["Local Role\n(EM_ROLE / System_ID)"]
        AR["Application Resource\n(Submenu description)"]
        CP["Custom Permission\nview · update"]
    end

    ASEM  -->|"extract users"| LU
    ASEM  -->|"extract roles"| LR
    ASAS  -->|"user-role membership"| LU
    APMENUS -->|"extract submenus"| AR
    APSUBMN -->|"map flags → permissions"| CP

    LU -->|"member of"| LR
    LU -->|"has permission"| CP
    CP -->|"on resource"| AR
```

---

## 3. How It Works

1. Reads credentials from `.env` (or CLI args / environment variables).
2. Opens a pyodbc connection to the configured IBM i host (`DB_HOST`) using the IBM i Access ODBC driver.
3. Runs the **Account Query** — returns all active employees with their role assignments and the menu/submenu entries they can access.
4. Runs the **Group Query** — returns the distinct set of menu/submenu resource names.
5. Runs the **Role Query** — returns the distinct set of `EM_ROLE` / System_ID codes.
6. Builds a `CustomApplication` OAA payload:
   - Each unique `User_ID` → Local User
   - Each unique `EM_ROLE` → Local Role
   - Each unique `SUBMENU` description → Application Resource
   - `*UPDATE*`-prefixed descriptions → `update` permission; others → `view` permission
7. Associates each user to their role and to each resource/permission pair.
8. Pushes the payload to Veza via `OAAClient.push_application()`, creating the provider automatically if it does not exist.

---

## 4. Prerequisites

| Requirement | Notes |
|---|---|
| Python 3.9+ | `python3 --version` |
| unixODBC | `sudo dnf install unixODBC unixODBC-devel` |
| IBM i Access Client Solutions ODBC driver | Download from [IBM Support](https://www.ibm.com/support/pages/ibm-i-access-client-solutions); install and register in `/etc/odbc.ini` |
| Network access to your IBM i host | TCP ports 449 and 8471 must be reachable |
| IBM i user profile | Must have `*USE` authority to `pdmstrdblb` library |
| Veza tenant + API key | Generated in Veza Settings → API Keys |

---

## 5. Quick Start

Once the repository is available, run the one-command installer:

```bash
curl -fsSL https://raw.githubusercontent.com/<your-github-org>/Board-Sales-Invoicing/main/integrations/board-sales-invoicing/install_board-sales-invoicing.sh | bash
```

The installer will:
- Install system prerequisites (git, python3, unixODBC)
- Clone the integration files to `/opt/VEZA/board-sales-invoicing-veza/scripts/`
- Create a Python virtual environment and install dependencies
- Prompt for IBM i and Veza credentials and write a `chmod 600` `.env` file

---

## 6. Manual Installation

### RHEL / CentOS / Amazon Linux

```bash
# Install prerequisites
sudo dnf install -y git python3 python3-pip unixODBC unixODBC-devel

# Install IBM i Access Client Solutions ODBC driver
# (download RPM from https://www.ibm.com/support/pages/ibm-i-access-client-solutions)
sudo rpm -ivh ibm-iaccess-*.rpm

# Clone and set up
git clone https://github.com/<your-github-org>/Board-Sales-Invoicing.git
cd Board-Sales-Invoicing/integrations/board-sales-invoicing
python3 -m venv venv
venv/bin/pip install -r requirements.txt

# Configure
cp .env.example .env
chmod 600 .env
vi .env  # fill in DB_HOST, DB_USER, DB_PASSWORD, VEZA_URL, VEZA_API_KEY
```

### Ubuntu / Debian

```bash
sudo apt-get update
sudo apt-get install -y git python3 python3-pip python3-venv unixodbc unixodbc-dev

# Install IBM i Access Client Solutions ODBC driver
# (download .deb from https://www.ibm.com/support/pages/ibm-i-access-client-solutions)
sudo dpkg -i ibm-iaccess-*.deb

git clone https://github.com/<your-github-org>/Board-Sales-Invoicing.git
cd Board-Sales-Invoicing/integrations/board-sales-invoicing
python3 -m venv venv
venv/bin/pip install -r requirements.txt

cp .env.example .env
chmod 600 .env
nano .env
```

---

## 7. Usage

### CLI Arguments

| Argument | Required | Values | Default | Description |
|---|---|---|---|---|
| `--env-file` | No | Path | `.env` | Path to credentials file |
| `--db-host` | No | Hostname | `DB_HOST` env var | IBM i hostname |
| `--db-user` | No | String | `DB_USER` | IBM i user profile |
| `--db-password` | No | String | `DB_PASSWORD` | IBM i password |
| `--db-dsn` | No | DSN name | `DB_DSN` | ODBC DSN (overrides host) |
| `--veza-url` | No* | URL | `VEZA_URL` | Veza tenant URL |
| `--veza-api-key` | No* | String | `VEZA_API_KEY` | Veza API key |
| `--provider-name` | No | String | `Board Sales Invoicing` | Provider label in Veza |
| `--datasource-name` | No | String | `board-sales-invoicing` | Datasource label in Veza |
| `--dry-run` | No | Flag | Off | Build payload without pushing |
| `--save-json` | No | Flag | Off | Save OAA payload JSON to disk |
| `--log-level` | No | DEBUG/INFO/WARNING/ERROR | `INFO` | Logging verbosity |

*Required unless `--dry-run` is used.

### Examples

```bash
# Dry-run — build and save payload, no Veza push
python3 board-sales-invoicing.py --env-file .env --dry-run --save-json

# Full push to Veza
python3 board-sales-invoicing.py --env-file .env

# Override host and credentials inline
python3 board-sales-invoicing.py \
    --db-host your-ibmi-host \\
    --db-user MYUSER \\
    --db-password "S3cr3t!" \\
    --veza-url https://your-company.veza.com \\
    --veza-api-key "vza_..." \
    --save-json

# Debug logging
python3 board-sales-invoicing.py --env-file .env --log-level DEBUG
```

---

## 8. Deployment on Linux

### Service account

```bash
sudo useradd -r -s /bin/bash -m -d /opt/board-sales-invoicing-veza board-sales-veza
sudo chown -R board-sales-veza:board-sales-veza /opt/VEZA/board-sales-invoicing-veza
sudo chmod 700 /opt/VEZA/board-sales-invoicing-veza/scripts
sudo chmod 600 /opt/VEZA/board-sales-invoicing-veza/scripts/.env
```

### SELinux (RHEL)

```bash
getenforce  # check SELinux mode
sudo restorecon -Rv /opt/VEZA/board-sales-invoicing-veza/
```

### Cron scheduling (daily at 2 AM)

Create `/etc/cron.d/board-sales-invoicing`:

```cron
SHELL=/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/sbin:/bin:/usr/sbin:/usr/bin

# Board Sales Invoicing → Veza OAA — daily sync at 2 AM
0 2 * * * board-sales-veza cd /opt/VEZA/board-sales-invoicing-veza/scripts && \
    ./venv/bin/python3 board-sales-invoicing.py --env-file .env >> \
    /opt/VEZA/board-sales-invoicing-veza/logs/cron.log 2>&1
```

### Log rotation (`/etc/logrotate.d/board-sales-invoicing`)

```
/opt/VEZA/board-sales-invoicing-veza/logs/*.log {
    daily
    rotate 30
    compress
    missingok
    notifempty
    create 640 board-sales-veza board-sales-veza
}
```

---

## 9. Multiple Instances

To run against multiple IBM i environments, use separate `.env` files and the `--env-file` flag:

```bash
# Production
python3 board-sales-invoicing.py --env-file .env.prod --datasource-name ibmi-prod

# QA / staging
python3 board-sales-invoicing.py --env-file .env.qa --datasource-name ibmi-qa
```

Stagger cron entries by 30 minutes to avoid simultaneous Veza pushes.

---

## 10. Security Considerations

- **`.env` file**: always `chmod 600` — contains plaintext credentials.
- **Service account**: run as a dedicated non-root user with no login shell.
- **IBM i user profile**: grant only `*USE` authority to `pdmstrdblb` — no DDL or DML rights needed beyond `SELECT`.
- **Veza API key**: rotate periodically in Veza Settings → API Keys; update `.env` after rotation.
- **SELinux / AppArmor**: run `restorecon` after installing on RHEL; review AppArmor policy on Ubuntu if the connector cannot read `/etc/odbc.ini`.
- **Network**: restrict outbound access to `<your-ibmi-host>:449,8471` and `<your-veza-url>:443`.

---

## 11. Troubleshooting

| Symptom | Likely Cause | Fix |
|---|---|---|
| `pyodbc.Error: Data source name not found` | ODBC driver not registered | Verify IBM i Access Client Solutions is installed; check `/etc/odbcinst.ini` |
| `Communication link failure` | Network blocked | Confirm TCP 449 and 8471 to the IBM i host are open |
| `HY000: User not authorized to library PDMSTRDBLB` | Missing IBM i authority | Grant `*USE` on `PDMSTRDBLB` to the connecting user profile |
| `OAAClientError: 401` | Invalid Veza API key | Regenerate key in Veza Settings → API Keys |
| `ModuleNotFoundError: pyodbc` | venv not activated / deps not installed | `venv/bin/pip install -r requirements.txt` |
| `No account rows returned` | IBM i user has no active employees visible | Check `emp.em_status = 'A'` rows exist and user has authority |
| Empty `SUBMENU` resources | `mnutext` values are NULL or blank | Review `pdmstrdblb.apsubmn` data; contact IBM i administrator |

**Enable debug logging:**
```bash
python3 board-sales-invoicing.py --env-file .env --dry-run --save-json --log-level DEBUG
```

---

## 12. Changelog

| Version | Date | Notes |
|---|---|---|
| 1.0.0 | 2026-05-11 | Initial release — users, roles, submenu resources, view/update permissions |
