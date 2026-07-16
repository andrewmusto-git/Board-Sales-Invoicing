#!/usr/bin/env python3
"""
Board Sales Invoicing (IBM i / AS400) to Veza OAA Integration Script

Connects to the IBM i system via JDBC (IBM Toolbox for Java / JT400 driver,
com.ibm.as400.access.AS400JDBCDriver) and pushes user, role, and
menu-permission data into Veza's Access Graph using the OAA
CustomApplication template.

Entity model:
  Local User           → active employees from pdmstrdblb.asem (User_ID, User_Name, User_EIN)
  Local Role           → System/Role codes from pdmstrdblb.asem (EM_ROLE / System_ID)
  Application Resource → Menu/Submenu entries (SUBMENU descriptions)
  Custom Permission    → view, update
"""

import argparse
import json
import logging
import os
import sys
import time
from datetime import datetime
from logging.handlers import TimedRotatingFileHandler

import jaydebeapi
from dotenv import load_dotenv
from oaaclient.client import OAAClient, OAAClientError
from oaaclient.templates import CustomApplication, OAAPermission

# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------
log = logging.getLogger(__name__)

PROVIDER_NAME_DEFAULT = "Board Sales Invoicing"
DATASOURCE_NAME_DEFAULT = "board-sales-invoicing"
JDBC_DRIVER_CLASS = "com.ibm.as400.access.AS400JDBCDriver"


def _setup_logging(log_level: str = "INFO") -> None:
    """Configure file-only logging with hourly rotation to the logs/ folder."""
    script_dir = os.path.dirname(os.path.abspath(__file__))
    log_dir = os.path.join(script_dir, "logs")
    os.makedirs(log_dir, exist_ok=True)

    timestamp = datetime.now().strftime("%d%m%Y-%H%M")
    script_name = os.path.splitext(os.path.basename(__file__))[0]
    log_file = os.path.join(log_dir, f"{script_name}_{timestamp}.log")

    handler = TimedRotatingFileHandler(
        log_file,
        when="h",
        interval=1,
        backupCount=24,
        encoding="utf-8",
    )
    handler.setFormatter(
        logging.Formatter(
            fmt="%(asctime)s %(levelname)-8s %(message)s",
            datefmt="%Y-%m-%dT%H:%M:%S",
        )
    )

    root = logging.getLogger()
    root.setLevel(getattr(logging, log_level.upper(), logging.INFO))
    root.addHandler(handler)


# ---------------------------------------------------------------------------
# Milestone reporting
# ---------------------------------------------------------------------------
_RUN_START: float = 0.0
_MILESTONE_COUNT: int = 0


def _milestone(label: str, detail: str = "") -> None:
    """Print a numbered, timestamped milestone banner to stdout and the log."""
    global _MILESTONE_COUNT
    _MILESTONE_COUNT += 1
    elapsed = time.perf_counter() - _RUN_START if _RUN_START else 0.0
    ts = datetime.now().strftime("%H:%M:%S")
    detail_str = f"  {detail}" if detail else ""
    line = f"[{ts}] [{elapsed:6.1f}s] MILESTONE {_MILESTONE_COUNT}: {label}{detail_str}"
    print(line)
    log.info("MILESTONE %d: %s%s", _MILESTONE_COUNT, label, detail_str)


# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------

def load_config(args) -> dict:
    """Load configuration from env file, environment variables, and CLI args.

    Precedence: CLI arg > environment variable > .env file value.
    """
    env_path = args.env_file if args.env_file else ".env"
    if os.path.exists(env_path):
        load_dotenv(env_path)
        log.info("Loaded environment file: %s", env_path)
    else:
        log.warning("Environment file not found: %s — relying on environment variables", env_path)

    config = {
        "veza_url": (args.veza_url or os.getenv("VEZA_URL", "")).rstrip("/"),
        "veza_api_key": args.veza_api_key or os.getenv("VEZA_API_KEY", ""),
        "db_url": args.db_url or os.getenv("DB_URL", ""),
        "db_user": args.db_user or os.getenv("DB_USER", ""),
        "db_password": args.db_password or os.getenv("DB_PASSWORD", ""),
        "jdbc_jar": args.jdbc_jar or os.getenv("JDBC_JAR", ""),
        "provider_name": args.provider_name or os.getenv("PROVIDER_NAME", PROVIDER_NAME_DEFAULT),
        "datasource_name": args.datasource_name or os.getenv("DATASOURCE_NAME", DATASOURCE_NAME_DEFAULT),
    }

    # Validate required fields
    missing = []
    if not config["veza_url"]:
        missing.append("VEZA_URL")
    if not config["veza_api_key"]:
        missing.append("VEZA_API_KEY")
    if not config["db_url"]:
        missing.append("DB_URL")
    if not config["db_user"]:
        missing.append("DB_USER")
    if not config["db_password"]:
        missing.append("DB_PASSWORD")
    if not config["jdbc_jar"]:
        missing.append("JDBC_JAR")

    if missing:
        log.error("Missing required configuration: %s", ", ".join(missing))
        sys.exit(1)

    return config


# ---------------------------------------------------------------------------
# Database connection
# ---------------------------------------------------------------------------

def get_connection(config: dict):
    """Return an open JDBC connection to the IBM i system via jaydebeapi.

    Requires:
    - DB_URL:      JDBC URL, e.g. jdbc:as400://hostname/PDMSTRDBLB;naming=sql
    - DB_USER:     IBM i user profile
    - DB_PASSWORD: IBM i user profile password
    - JDBC_JAR:    Absolute path to jt400.jar
    """
    db_url = config["db_url"]
    db_user = config["db_user"]
    db_password = config["db_password"]
    jdbc_jar = config["jdbc_jar"]

    if not os.path.isfile(jdbc_jar):
        log.error("JDBC JAR not found at path: %s", jdbc_jar)
        sys.exit(1)

    log.info("Connecting via JDBC: %s as %s", db_url, db_user)
    try:
        conn = jaydebeapi.connect(
            JDBC_DRIVER_CLASS,
            db_url,
            [db_user, db_password],
            jdbc_jar,
        )
        log.info("JDBC connection established successfully")
        _milestone("Database connection established", f"url={db_url} user={db_user}")
        return conn
    except Exception as exc:
        log.error("JDBC connection failed: %s", exc)
        sys.exit(1)


# ---------------------------------------------------------------------------
# SQL queries (read-only; no user-supplied values are interpolated)
# ---------------------------------------------------------------------------

# Connectivity test query.
TEST_SQL = "VALUES current date"

# Account query — returns all active users with their role and menu permission descriptions.
ACCOUNT_SQL = """
select TRIM(emp.usrid) as User_ID,
       TRIM(emp.em_user_name) as User_Name,
       TRIM(emp.empid) as User_EIN,
       TRIM(EMP.ROLE) as System_ID,
       case
           when sub.mnutext = 'ALL SUBMENUS' and sec.authority = 'Y' and sub.updates = 'Y'
               Then '*UPDATE* ' || TRIM(mnu.MNUTEXT)
           when sub.mnutext = 'ALL SUBMENUS' and (sec.authority <> 'Y' or sub.updates <> 'Y')
               Then TRIM(mnu.MNUTEXT)
           else TRIM(sub.MNUTEXT)
       end Description
FROM pdmstrdblb.asas sec,
     pdmstrdblb.apmenus mnu,
     pdmstrdblb.apsubmn sub,
     pdmstrdblb.asem emp
WHERE sec.MNUPROGRAM = mnu.MNUPGM
  and sec.MNUPROGRAM = sub.MNUPGM
  and sec.SELECTION = sub.SUBMNU
  and sec.USRID = emp.USRID
  and emp.em_status = 'A'
Order by User_id, User_EIN, System_ID, Description
"""

# Access query — returns distinct menu/submenu resources.
GROUP_SQL = """
SELECT distinct
       case
           when sub.mnutext = 'ALL SUBMENUS' and sec.authority = 'Y' and sub.updates = 'Y'
               Then '*UPDATE* ' || TRIM(mnu.MNUTEXT)
           when sub.mnutext = 'ALL SUBMENUS' and (sec.authority <> 'Y' or sub.updates <> 'Y')
               Then TRIM(mnu.MNUTEXT)
           else TRIM(sub.MNUTEXT)
       end SUBMENU
FROM pdmstrdblb.asas sec,
     pdmstrdblb.apmenus mnu,
     pdmstrdblb.apsubmn sub,
     pdmstrdblb.asem emp
WHERE sec.MNUPROGRAM = mnu.MNUPGM
  and sec.MNUPROGRAM = sub.MNUPGM
  and sec.SELECTION = sub.SUBMNU
  and sec.USRID = emp.USRID
  and emp.em_status = 'A'
"""

# System_ID query — returns distinct EM_ROLE / System_ID codes.
ROLE_SQL = """
select distinct TRIM(asem.EM_ROLE) as EM_ROLE
from PDMSTRDBLB.asem AS asem
"""


# ---------------------------------------------------------------------------
# Data extraction
# ---------------------------------------------------------------------------

def fetch_accounts(conn) -> list:
    """Fetch all active user-permission rows."""
    print("  → Querying account / permission data …")
    log.info("Fetching account (user/permission) data …")
    cursor = conn.cursor()
    cursor.execute(ACCOUNT_SQL)
    columns = [col[0].upper() for col in cursor.description]
    rows = [dict(zip(columns, row)) for row in cursor.fetchall()]
    cursor.close()
    log.info("Fetched %d account rows", len(rows))
    _milestone("Account query complete", f"{len(rows):,} rows returned")
    return rows


def fetch_submenus(conn) -> list:
    """Fetch all distinct submenu resource names."""
    print("  → Querying submenu resources …")
    log.info("Fetching submenu (resource) data …")
    cursor = conn.cursor()
    cursor.execute(GROUP_SQL)
    submenus = [row[0] for row in cursor.fetchall() if row[0]]
    cursor.close()
    log.info("Fetched %d submenu resources", len(submenus))
    _milestone("Access query complete", f"{len(submenus):,} distinct resources")
    return submenus


def fetch_roles(conn) -> list:
    """Fetch all distinct System_ID / EM_ROLE values."""
    print("  → Querying System_ID / EM_ROLE codes …")
    log.info("Fetching role (System_ID) data …")
    cursor = conn.cursor()
    cursor.execute(ROLE_SQL)
    roles = [row[0] for row in cursor.fetchall() if row[0]]
    cursor.close()
    log.info("Fetched %d roles", len(roles))
    _milestone("System_ID query complete", f"{len(roles):,} distinct roles")
    return roles


# ---------------------------------------------------------------------------
# OAA payload assembly
# ---------------------------------------------------------------------------

def build_oaa_payload(
    accounts: list,
    submenus: list,
    roles: list,
    config: dict,
) -> CustomApplication:
    """Build the OAA CustomApplication payload from extracted IBM i data.

    Entity mapping:
      pdmstrdblb.asem (active employees)  → Local User
      pdmstrdblb.asem EM_ROLE / ROLE      → Local Role
      SUBMENU descriptions                → Application Resource
      *UPDATE* prefix                     → 'update' Custom Permission
      All other entries                   → 'view'   Custom Permission
    """
    provider_name = config["provider_name"]
    datasource_name = config["datasource_name"]

    app = CustomApplication(
        name=datasource_name,
        application_type=provider_name,
        description="Board Sales Invoicing IBM i menu security and user access",
    )

    # Custom permissions
    app.add_custom_permission("view", [OAAPermission.DataRead])
    app.add_custom_permission("update", [OAAPermission.DataRead, OAAPermission.DataWrite])

    # Add all submenu resources
    log.info("Adding %d Application Resources (submenus) …", len(submenus))
    for submenu in submenus:
        resource = app.add_resource(name=submenu, resource_type="Submenu")
        log.debug("Resource: %s", submenu)

    # Add all roles
    log.info("Adding %d Local Roles (System IDs) …", len(roles))
    for role_name in roles:
        role = app.add_local_role(name=role_name)
        log.debug("Role: %s", role_name)

    # Build user index: user_id → {name, ein, system_id, permissions[]}
    role_set = set(roles)
    user_index: dict = {}
    for row in accounts:
        uid = (row.get("USER_ID") or "").strip()
        if not uid:
            continue
        if uid not in user_index:
            user_index[uid] = {
                "name": (row.get("USER_NAME") or uid).strip(),
                "ein": (row.get("USER_EIN") or "").strip(),
                "system_id": (row.get("SYSTEM_ID") or "").strip(),
                "permissions": [],
            }
        desc = (row.get("DESCRIPTION") or "").strip()
        if desc:
            perm = "update" if desc.startswith("*UPDATE*") else "view"
            user_index[uid]["permissions"].append((desc, perm))

    log.info("Adding %d Local Users …", len(user_index))
    for uid, info in user_index.items():
        local_user = app.add_local_user(name=uid)
        local_user.full_name = info["name"]
        local_user.add_attribute("employee_id", info["ein"])
        local_user.add_attribute("system_id", info["system_id"])

        # Associate user → role
        system_id = info["system_id"]
        if system_id and system_id in role_set:
            local_user.add_role(system_id)
            log.debug("User %s → Role %s", uid, system_id)

        # Associate user → resource permissions
        for desc, perm in info["permissions"]:
            if desc:
                local_user.add_permission(
                    permission=perm,
                    resource_name=desc,
                    apply_to_application=False,
                )
                log.debug("User %s → %s on %s", uid, perm, desc)

    log.info(
        "Payload built: %d users, %d roles, %d resources",
        len(user_index),
        len(roles),
        len(submenus),
    )
    _milestone(
        "OAA payload built",
        f"{len(user_index):,} users  {len(roles):,} roles  {len(submenus):,} resources",
    )
    return app


# ---------------------------------------------------------------------------
# Veza push
# ---------------------------------------------------------------------------

def push_to_veza(
    config: dict,
    app: CustomApplication,
    save_json: bool = False,
    output_dir: str = ".",
) -> None:
    """Push the OAA payload to Veza, optionally saving the JSON for inspection."""
    if save_json:
        payload_path = os.path.join(
            output_dir,
            f"{app.name.replace(' ', '_')}_oaa_payload.json",
        )
        with open(payload_path, "w", encoding="utf-8") as fh:
            json.dump(app.get_payload(), fh, indent=2, default=str)
        log.info("Payload saved to: %s", payload_path)
        _milestone("Payload JSON saved", payload_path)

    veza_con = OAAClient(url=config["veza_url"], token=config["veza_api_key"])
    try:
        response = veza_con.push_application(
            provider_name=config["provider_name"],
            data_source_name=config["datasource_name"],
            application_object=app,
            create_provider=True,
        )
        if response and response.get("warnings"):
            for w in response["warnings"]:
                log.warning("Veza warning: %s", w)
        log.info("Successfully pushed to Veza: provider=%s datasource=%s",
                 config["provider_name"], config["datasource_name"])
        _milestone(
            "Veza push complete",
            f"provider={config['provider_name']}  datasource={config['datasource_name']}",
        )
    except OAAClientError as exc:
        log.error(
            "Veza push failed: %s — %s (HTTP %s)",
            exc.error,
            exc.message,
            exc.status_code,
        )
        if hasattr(exc, "details"):
            for detail in exc.details:
                log.error("  Detail: %s", detail)
        sys.exit(1)


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------

def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Board Sales Invoicing IBM i → Veza OAA connector (JDBC)",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
Examples:
  # Push to Veza using .env credentials:
  python3 board-sales-invoicing.py --env-file .env

  # Override credentials on the fly:
  python3 board-sales-invoicing.py \\
      --db-url "jdbc:as400://your-ibmi-host/PDMSTRDBLB" \\
      --db-user MYUSER --db-password SECRET \\
      --jdbc-jar /opt/jt400/jt400.jar \\
      --veza-url https://your-company.veza.com \\
      --veza-api-key TOKEN
""",
    )

    # Source connection
    src = parser.add_argument_group("IBM i / AS400 JDBC source")
    src.add_argument("--db-url", default=None,
                     help='JDBC URL for IBM i (env: DB_URL), e.g. "jdbc:as400://hostname/PDMSTRDBLB"')
    src.add_argument("--db-user", default=None,
                     help="IBM i user profile (env: DB_USER)")
    src.add_argument("--db-password", default=None,
                     help="IBM i user profile password (env: DB_PASSWORD)")
    src.add_argument("--jdbc-jar", default=None,
                     help="Absolute path to jt400.jar (env: JDBC_JAR)")

    # Veza
    veza = parser.add_argument_group("Veza")
    veza.add_argument("--veza-url", default=None,
                      help="Veza tenant URL (env: VEZA_URL)")
    veza.add_argument("--veza-api-key", default=None,
                      help="Veza API key (env: VEZA_API_KEY)")

    # OAA metadata
    meta = parser.add_argument_group("OAA metadata")
    meta.add_argument("--provider-name", default=None,
                      help=f"Provider name in Veza (default: {PROVIDER_NAME_DEFAULT!r})")
    meta.add_argument("--datasource-name", default=None,
                      help=f"Datasource name in Veza (default: {DATASOURCE_NAME_DEFAULT!r})")

    # Behavior
    parser.add_argument("--env-file", default=".env",
                        help="Path to .env file (default: .env)")
    parser.add_argument("--save-json", action="store_true",
                        help="Save OAA payload as JSON for inspection")
    parser.add_argument("--log-level", default="INFO",
                        choices=["DEBUG", "INFO", "WARNING", "ERROR"],
                        help="Logging verbosity (default: INFO)")

    return parser.parse_args()


# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------

def main() -> None:
    global _RUN_START, _MILESTONE_COUNT
    _RUN_START = time.perf_counter()
    _MILESTONE_COUNT = 0

    args = parse_args()
    _setup_logging(args.log_level)

    run_ts = datetime.now().strftime("%Y-%m-%d %H:%M:%S")
    print("=" * 60)
    print(" Board Sales Invoicing → Veza OAA Connector")
    print(f" {run_ts}")
    print(f" save_json={args.save_json}  log_level={args.log_level}")
    print("=" * 60)

    log.info("Starting Board Sales Invoicing → Veza OAA connector")
    log.info("save_json=%s log_level=%s", args.save_json, args.log_level)

    # MILESTONE 1 — configuration
    config = load_config(args)
    _milestone(
        "Configuration loaded",
        f"db_url={config['db_url']}  "
        f"provider={config['provider_name']}  datasource={config['datasource_name']}",
    )

    # MILESTONE 2 — database connection (emitted inside get_connection)
    conn = get_connection(config)

    # MILESTONES 3-5 — data extraction (emitted inside each fetch function)
    print("\nExtracting data from IBM i …")
    accounts = fetch_accounts(conn)
    submenus = fetch_submenus(conn)
    roles = fetch_roles(conn)
    conn.close()
    log.info("Database connection closed")

    if not accounts:
        log.warning("No account rows returned — check query and credentials")
        print("[WARN] No account rows returned — check query and credentials")

    # MILESTONE 6 — payload build (emitted inside build_oaa_payload)
    print("\nBuilding OAA payload …")
    app = build_oaa_payload(accounts, submenus, roles, config)

    # MILESTONE 7+ — push / save (emitted inside push_to_veza)
    print("\nPushing to Veza …")
    script_dir = os.path.dirname(os.path.abspath(__file__))
    push_to_veza(
        config=config,
        app=app,
        save_json=args.save_json,
        output_dir=script_dir,
    )

    elapsed = time.perf_counter() - _RUN_START
    unique_users = len({(r.get("USER_ID") or "").strip() for r in accounts if (r.get("USER_ID") or "").strip()})
    summary = (
        f"  Users:     {unique_users:,}\n"
        f"  Roles:     {len(roles):,}\n"
        f"  Resources: {len(submenus):,}\n"
        f"  Elapsed:   {elapsed:.1f}s"
    )
    print("\n" + "=" * 60)
    print(" Run Summary")
    print(summary)
    print("=" * 60)
    log.info("Connector run complete — elapsed=%.1fs", elapsed)


if __name__ == "__main__":
    main()
