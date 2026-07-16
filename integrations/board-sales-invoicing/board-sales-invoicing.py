#!/usr/bin/env python3
"""
Board Sales Invoicing (IBM i / AS400) to Veza OAA Integration Script

Connects to the IBM i system via JDBC (IBM Toolbox for Java / JT400 driver,
com.ibm.as400.access.AS400JDBCDriver) and pushes user, role, and
menu-permission data into Veza's Access Graph using the OAA
CustomApplication template.

Entity model:
  Local User           -> active employees from pdmstrdblb.asem
  Local Role           -> System/Role codes (EM_ROLE / System_ID)
  Application Resource -> Menu/Submenu entries (SUBMENU descriptions)
  Custom Permission    -> view, update
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
# Constants
# ---------------------------------------------------------------------------
log = logging.getLogger(__name__)

PROVIDER_NAME_DEFAULT  = "Board Sales Invoicing"
DATASOURCE_NAME_DEFAULT = "board-sales-invoicing"
JDBC_DRIVER_CLASS      = "com.ibm.as400.access.AS400JDBCDriver"

# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------

def _setup_logging(log_level: str = "INFO") -> None:
    """Configure file-only logging with hourly rotation to the logs/ folder."""
    script_dir = os.path.dirname(os.path.abspath(__file__))
    log_dir    = os.path.join(script_dir, "logs")
    os.makedirs(log_dir, exist_ok=True)

    timestamp   = datetime.now().strftime("%d%m%Y-%H%M")
    script_name = os.path.splitext(os.path.basename(__file__))[0]
    log_file    = os.path.join(log_dir, f"{script_name}_{timestamp}.log")

    handler = TimedRotatingFileHandler(
        log_file, when="h", interval=1, backupCount=24, encoding="utf-8"
    )
    handler.setFormatter(logging.Formatter(
        fmt="%(asctime)s %(levelname)-8s %(message)s",
        datefmt="%Y-%m-%dT%H:%M:%S",
    ))
    root = logging.getLogger()
    root.setLevel(getattr(logging, log_level.upper(), logging.INFO))
    root.addHandler(handler)


# ---------------------------------------------------------------------------
# Milestone reporting
# ---------------------------------------------------------------------------
_RUN_START:      float = 0.0
_MILESTONE_COUNT: int  = 0


def _milestone(label: str, detail: str = "") -> None:
    """Print a numbered, timestamped milestone to stdout and the log."""
    global _MILESTONE_COUNT
    _MILESTONE_COUNT += 1
    elapsed    = time.perf_counter() - _RUN_START if _RUN_START else 0.0
    ts         = datetime.now().strftime("%H:%M:%S")
    detail_str = f"  {detail}" if detail else ""
    line       = f"[{ts}] [{elapsed:6.1f}s] MILESTONE {_MILESTONE_COUNT}: {label}{detail_str}"
    print(line)
    log.info("MILESTONE %d: %s%s", _MILESTONE_COUNT, label, detail_str)


# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------

def load_config(args) -> dict:
    """Load and validate configuration.

    Precedence: CLI arg > environment variable > .env file value.
    """
    env_path = args.env_file if args.env_file else ".env"
    if os.path.exists(env_path):
        load_dotenv(env_path)
        log.info("Loaded environment file: %s", env_path)
    else:
        log.warning("Environment file not found: %s -- relying on environment variables", env_path)

    config = {
        "veza_url":        (args.veza_url       or os.getenv("VEZA_URL",        "")).rstrip("/"),
        "veza_api_key":     args.veza_api_key    or os.getenv("VEZA_API_KEY",    ""),
        "db_url":           args.db_url          or os.getenv("DB_URL",          ""),
        "db_user":          args.db_user         or os.getenv("DB_USER",         ""),
        "db_password":      args.db_password     or os.getenv("DB_PASSWORD",     ""),
        "jdbc_jar":         args.jdbc_jar        or os.getenv("JDBC_JAR",        ""),
        "provider_name":    args.provider_name   or os.getenv("PROVIDER_NAME",   PROVIDER_NAME_DEFAULT),
        "datasource_name":  args.datasource_name or os.getenv("DATASOURCE_NAME", DATASOURCE_NAME_DEFAULT),
    }

    required = ("veza_url", "veza_api_key", "db_url", "db_user", "db_password", "jdbc_jar")
    missing  = [k.upper() for k in required if not config[k]]
    if missing:
        log.error("Missing required configuration: %s", ", ".join(missing))
        sys.exit(1)

    return config


# ---------------------------------------------------------------------------
# Database connection (JDBC via jaydebeapi)
# ---------------------------------------------------------------------------

def get_connection(config: dict):
    """Open and return a JDBC connection to the IBM i system.

    Driver: com.ibm.as400.access.AS400JDBCDriver  (IBM Toolbox for Java)
    JAR:    path provided via JDBC_JAR / --jdbc-jar
    """
    jdbc_jar = config["jdbc_jar"]
    if not os.path.isfile(jdbc_jar):
        log.error("JDBC JAR not found: %s", jdbc_jar)
        sys.exit(1)

    log.info("Connecting via JDBC: %s as %s", config["db_url"], config["db_user"])
    try:
        conn = jaydebeapi.connect(
            JDBC_DRIVER_CLASS,
            config["db_url"],
            [config["db_user"], config["db_password"]],
            jdbc_jar,
        )
        log.info("JDBC connection established")
        _milestone("Database connection established",
                   f"url={config['db_url']}  user={config['db_user']}")
        return conn
    except Exception as exc:
        log.error("JDBC connection failed: %s", exc)
        sys.exit(1)


# ---------------------------------------------------------------------------
# SQL queries (read-only; no user-supplied values are interpolated)
# ---------------------------------------------------------------------------

# Connectivity test
TEST_SQL = "VALUES current date"

# 1. Account query
ACCOUNT_SQL = """\
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
  and sec.SELECTION  = sub.SUBMNU
  and sec.USRID      = emp.USRID
  and emp.em_status  = 'A'
Order by User_id, User_EIN, System_ID, Description"""

# 3. Access (submenu resource) query
GROUP_SQL = """\
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
  and sec.SELECTION  = sub.SUBMNU
  and sec.USRID      = emp.USRID
  and emp.em_status  = 'A'"""

# 4. System_ID (role) query
ROLE_SQL = """\
select distinct TRIM(asem.EM_ROLE) as EM_ROLE
from PDMSTRDBLB.asem AS asem"""


# ---------------------------------------------------------------------------
# Data extraction
# ---------------------------------------------------------------------------

def fetch_accounts(conn) -> list:
    """Run the Account query and return all rows as dicts (columns uppercased)."""
    print("  -> Querying accounts / permissions ...")
    log.info("Running Account SQL ...")
    cur  = conn.cursor()
    cur.execute(ACCOUNT_SQL)
    cols = [c[0].upper() for c in cur.description]
    rows = [dict(zip(cols, row)) for row in cur.fetchall()]
    cur.close()
    log.info("Account query returned %d rows", len(rows))
    _milestone("Account query complete", f"{len(rows):,} rows")
    return rows


def fetch_submenus(conn) -> list:
    """Run the Access query and return distinct SUBMENU values."""
    print("  -> Querying submenu resources ...")
    log.info("Running Access SQL ...")
    cur    = conn.cursor()
    cur.execute(GROUP_SQL)
    values = [row[0] for row in cur.fetchall() if row[0]]
    cur.close()
    log.info("Access query returned %d distinct submenus", len(values))
    _milestone("Access query complete", f"{len(values):,} distinct resources")
    return values


def fetch_roles(conn) -> list:
    """Run the System_ID query and return distinct EM_ROLE values."""
    print("  -> Querying System_ID / EM_ROLE codes ...")
    log.info("Running System_ID SQL ...")
    cur    = conn.cursor()
    cur.execute(ROLE_SQL)
    values = [row[0] for row in cur.fetchall() if row[0]]
    cur.close()
    log.info("System_ID query returned %d distinct roles", len(values))
    _milestone("System_ID query complete", f"{len(values):,} distinct roles")
    return values


# ---------------------------------------------------------------------------
# OAA payload assembly
# ---------------------------------------------------------------------------

def build_payload(accounts: list, submenus: list, roles: list,
                  config: dict) -> CustomApplication:
    """Map IBM i data to an OAA CustomApplication payload.

    Mapping:
      asem active rows             -> Local User  (User_ID, full_name, employee_id)
      EM_ROLE / System_ID          -> Local Role
      SUBMENU descriptions         -> Application Resource  (type: Submenu)
      Description starts *UPDATE*  -> 'update' permission  (DataRead + DataWrite)
      All other descriptions       -> 'view'   permission  (DataRead only)
    """
    app = CustomApplication(
        name=config["datasource_name"],
        application_type=config["provider_name"],
        description="Board Sales Invoicing IBM i menu security and user access",
    )

    app.add_custom_permission("view",   [OAAPermission.DataRead])
    app.add_custom_permission("update", [OAAPermission.DataRead, OAAPermission.DataWrite])

    # Application Resources (submenus)
    log.info("Adding %d Application Resources ...", len(submenus))
    for name in submenus:
        app.add_resource(name=name, resource_type="Submenu")

    # Local Roles (System IDs / EM_ROLE)
    log.info("Adding %d Local Roles ...", len(roles))
    role_set = set(roles)
    for name in roles:
        app.add_local_role(name=name)

    # Local Users — de-duplicate multi-row account results first
    user_index: dict = {}
    for row in accounts:
        uid = (row.get("USER_ID") or "").strip()
        if not uid:
            continue
        if uid not in user_index:
            user_index[uid] = {
                "name":      (row.get("USER_NAME") or uid).strip(),
                "ein":       (row.get("USER_EIN")  or "").strip(),
                "system_id": (row.get("SYSTEM_ID") or "").strip(),
                "perms":     [],
            }
        desc = (row.get("DESCRIPTION") or "").strip()
        if desc:
            perm = "update" if desc.startswith("*UPDATE*") else "view"
            user_index[uid]["perms"].append((desc, perm))

    log.info("Adding %d Local Users ...", len(user_index))
    for uid, info in user_index.items():
        lu = app.add_local_user(name=uid)
        lu.full_name = info["name"]
        lu.add_attribute("employee_id", info["ein"])
        lu.add_attribute("system_id",   info["system_id"])

        if info["system_id"] in role_set:
            lu.add_role(info["system_id"])
            log.debug("User %s -> Role %s", uid, info["system_id"])

        for desc, perm in info["perms"]:
            lu.add_permission(permission=perm, resource_name=desc, apply_to_application=False)
            log.debug("User %s -> %s on %s", uid, perm, desc)

    log.info("Payload: %d users  %d roles  %d resources",
             len(user_index), len(roles), len(submenus))
    _milestone("OAA payload built",
               f"{len(user_index):,} users  {len(roles):,} roles  {len(submenus):,} resources")
    return app


# ---------------------------------------------------------------------------
# Veza push
# ---------------------------------------------------------------------------

def push_to_veza(config: dict, app: CustomApplication,
                 save_json: bool = False, output_dir: str = ".") -> None:
    """Push the OAA payload to Veza."""
    if save_json:
        path = os.path.join(output_dir,
                            f"{app.name.replace(' ', '_')}_oaa_payload.json")
        with open(path, "w", encoding="utf-8") as fh:
            json.dump(app.get_payload(), fh, indent=2, default=str)
        log.info("Payload saved: %s", path)
        _milestone("Payload JSON saved", path)

    veza_client = OAAClient(url=config["veza_url"], token=config["veza_api_key"])
    try:
        resp = veza_client.push_application(
            provider_name=config["provider_name"],
            data_source_name=config["datasource_name"],
            application_object=app,
            create_provider=True,
        )
        if resp and resp.get("warnings"):
            for w in resp["warnings"]:
                log.warning("Veza warning: %s", w)
        log.info("Push complete: provider=%s  datasource=%s",
                 config["provider_name"], config["datasource_name"])
        _milestone("Veza push complete",
                   f"provider={config['provider_name']}  datasource={config['datasource_name']}")
    except OAAClientError as exc:
        log.error("Veza push failed: %s -- %s (HTTP %s)",
                  exc.error, exc.message, exc.status_code)
        if hasattr(exc, "details"):
            for d in exc.details:
                log.error("  Detail: %s", d)
        sys.exit(1)


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------

def parse_args() -> argparse.Namespace:
    p = argparse.ArgumentParser(
        description="Board Sales Invoicing IBM i -> Veza OAA connector (JDBC)",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
Examples:
  python3 board-sales-invoicing.py --env-file .env

  python3 board-sales-invoicing.py \\
      --db-url "jdbc:as400://hostname/PDMSTRDBLB;naming=sql" \\
      --db-user MYUSER --db-password SECRET \\
      --jdbc-jar /opt/jt400/jt400.jar \\
      --veza-url https://your-veza-host \\
      --veza-api-key TOKEN
""",
    )

    db = p.add_argument_group("IBM i / AS400 JDBC source")
    db.add_argument("--db-url",      default=None,
                    help='JDBC URL (env: DB_URL), e.g. "jdbc:as400://hostname/PDMSTRDBLB;naming=sql"')
    db.add_argument("--db-user",     default=None, help="IBM i user profile (env: DB_USER)")
    db.add_argument("--db-password", default=None, help="IBM i password (env: DB_PASSWORD)")
    db.add_argument("--jdbc-jar",    default=None, help="Path to jt400.jar (env: JDBC_JAR)")

    vz = p.add_argument_group("Veza")
    vz.add_argument("--veza-url",     default=None, help="Veza tenant URL (env: VEZA_URL)")
    vz.add_argument("--veza-api-key", default=None, help="Veza API key (env: VEZA_API_KEY)")

    meta = p.add_argument_group("OAA metadata")
    meta.add_argument("--provider-name",   default=None,
                      help=f"Provider name in Veza (default: {PROVIDER_NAME_DEFAULT!r})")
    meta.add_argument("--datasource-name", default=None,
                      help=f"Datasource name in Veza (default: {DATASOURCE_NAME_DEFAULT!r})")

    p.add_argument("--env-file",  default=".env",
                   help="Path to .env file (default: .env)")
    p.add_argument("--save-json", action="store_true",
                   help="Save OAA payload JSON to disk for inspection")
    p.add_argument("--log-level", default="INFO",
                   choices=["DEBUG", "INFO", "WARNING", "ERROR"],
                   help="Logging verbosity (default: INFO)")
    return p.parse_args()


# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------

def main() -> None:
    global _RUN_START, _MILESTONE_COUNT
    _RUN_START       = time.perf_counter()
    _MILESTONE_COUNT = 0

    args = parse_args()
    _setup_logging(args.log_level)

    ts = datetime.now().strftime("%Y-%m-%d %H:%M:%S")
    print("=" * 60)
    print(" Board Sales Invoicing -> Veza OAA Connector")
    print(f" {ts}")
    print(f" save_json={args.save_json}  log_level={args.log_level}")
    print("=" * 60)
    log.info("Starting connector  save_json=%s  log_level=%s",
             args.save_json, args.log_level)

    # MILESTONE 1 -- Configuration
    config = load_config(args)
    _milestone("Configuration loaded",
               f"provider={config['provider_name']}  "
               f"datasource={config['datasource_name']}")

    # MILESTONE 2 -- Database connection (emitted inside get_connection)
    conn = get_connection(config)

    # MILESTONES 3-5 -- Data extraction
    print("\nExtracting data from IBM i ...")
    accounts = fetch_accounts(conn)
    submenus = fetch_submenus(conn)
    roles    = fetch_roles(conn)
    conn.close()
    log.info("Database connection closed")

    if not accounts:
        log.warning("No account rows returned -- check query and credentials")
        print("[WARN] No account rows returned")

    # MILESTONE 6 -- Payload assembly
    print("\nBuilding OAA payload ...")
    app = build_payload(accounts, submenus, roles, config)

    # MILESTONE 7+ -- Veza push
    print("\nPushing to Veza ...")
    push_to_veza(
        config=config,
        app=app,
        save_json=args.save_json,
        output_dir=os.path.dirname(os.path.abspath(__file__)),
    )

    elapsed      = time.perf_counter() - _RUN_START
    unique_users = len({(r.get("USER_ID") or "").strip() for r in accounts
                        if (r.get("USER_ID") or "").strip()})
    print("\n" + "=" * 60)
    print(" Run Summary")
    print(f"  Users:     {unique_users:,}")
    print(f"  Roles:     {len(roles):,}")
    print(f"  Resources: {len(submenus):,}")
    print(f"  Elapsed:   {elapsed:.1f}s")
    print("=" * 60)
    log.info("Connector run complete  elapsed=%.1fs", elapsed)


if __name__ == "__main__":
    main()
