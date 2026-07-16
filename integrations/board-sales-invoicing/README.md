# Board Sales Invoicing IBM i → Veza OAA Connector

Connects to the IBM i system configured via `DB_URL` via JDBC (IBM Toolbox for Java / JT400 driver) and pushes user, role, and menu-permission data into Veza's Access Graph using the OAA CustomApplication template.

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
2. Opens a JDBC connection to the configured IBM i host (`DB_URL`) using the IBM Toolbox for Java driver (`com.ibm.as400.access.AS400JDBCDriver`).
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
| Java JRE 8+ | Required by jaydebeapi/JPype1; `java -version` |
| JT400 JAR (`jt400.jar`) | Download from [Maven Central](https://repo1.maven.org/maven2/net/sf/jt400/jt400/) or [SourceForge](https://sourceforge.net/projects/jt400/files/); place at the path set in `JDBC_JAR` |
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
sudo dnf install -y git python3 python3-pip java-11-openjdk-headless

# Download JT400 JAR
sudo mkdir -p /opt/jt400
sudo curl -fsSL -o /opt/jt400/jt400.jar \
    https://repo1.maven.org/maven2/net/sf/jt400/jt400/20.0.7/jt400-20.0.7.jar

# Clone and set up
git clone https://github.com/<your-github-org>/Board-Sales-Invoicing.git
cd Board-Sales-Invoicing/integrations/board-sales-invoicing
python3 -m venv venv
venv/bin/pip install -r requirements.txt

# Configure
cp .env.example .env
chmod 600 .env
vi .env  # fill in DB_URL, DB_USER, DB_PASSWORD, JDBC_JAR, VEZA_URL, VEZA_API_KEY
```

### Ubuntu / Debian

```bash
sudo apt-get update
sudo apt-get install -y git python3 python3-pip python3-venv openjdk-11-jre-headless

# Download JT400 JAR
sudo mkdir -p /opt/jt400
sudo curl -fsSL -o /opt/jt400/jt400.jar \
    https://repo1.maven.org/maven2/net/sf/jt400/jt400/20.0.7/jt400-20.0.7.jar

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
| `--db-url` | No | JDBC URL | `DB_URL` env var | IBM i JDBC URL |
| `--db-user` | No | String | `DB_USER` | IBM i user profile |
| `--db-password` | No | String | `DB_PASSWORD` | IBM i password |
| `--jdbc-jar` | No | Path | `JDBC_JAR` | Absolute path to jt400.jar |
| `--veza-url` | No* | URL | `VEZA_URL` | Veza tenant URL |
| `--veza-api-key` | No* | String | `VEZA_API_KEY` | Veza API key |
| `--provider-name` | No | String | `Board Sales Invoicing` | Provider label in Veza |
| `--datasource-name` | No | String | `board-sales-invoicing` | Datasource label in Veza |
| `--save-json` | No | Flag | Off | Save OAA payload JSON to disk |
| `--log-level` | No | DEBUG/INFO/WARNING/ERROR | `INFO` | Logging verbosity |

*Required unless `VEZA_URL`/`VEZA_API_KEY` are set in the environment.

### Examples

```bash
# Push to Veza using .env credentials
python3 board-sales-invoicing.py --env-file .env

# Override credentials inline
python3 board-sales-invoicing.py \\
    --db-url "jdbc:as400://your-ibmi-host/PDMSTRDBLB;naming=sql" \\
    --db-user MYUSER \\
    --db-password "S3cr3t!" \\
    --jdbc-jar /opt/jt400/jt400.jar \\
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
| `ClassNotFoundException: com.ibm.as400.access.AS400JDBCDriver` | `JDBC_JAR` points to wrong file or doesn't exist | Verify `JDBC_JAR` path; confirm jt400.jar was downloaded correctly |
| `Connection refused` / `Communication link failure` | Network blocked | Confirm TCP 449 and 8471 to the IBM i host are open |
| `HY000: User not authorized to library PDMSTRDBLB` | Missing IBM i authority | Grant `*USE` on `PDMSTRDBLB` to the connecting user profile |
| `OAAClientError: 401` | Invalid Veza API key | Regenerate key in Veza Settings → API Keys |
| `ModuleNotFoundError: jaydebeapi` | venv not activated / deps not installed | `venv/bin/pip install -r requirements.txt` |
| `JVMNotFoundException` | Java not installed | Install JRE 8+: `sudo dnf install java-11-openjdk-headless` |
| `No account rows returned` | IBM i user has no active employees visible | Check `emp.em_status = 'A'` rows exist and user has authority |
| Empty `SUBMENU` resources | `mnutext` values are NULL or blank | Review `pdmstrdblb.apsubmn` data; contact IBM i administrator |

**Enable debug logging:**
```bash
python3 board-sales-invoicing.py --env-file .env --save-json --log-level DEBUG
```

---

## 12. Changelog

| Version | Date | Notes |
|---|---|---|
| 1.0.0 | 2026-05-11 | Initial release — users, roles, submenu resources, view/update permissions |
