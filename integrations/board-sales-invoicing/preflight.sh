#!/usr/bin/env bash
# =============================================================================
# preflight.sh -- Pre-deployment validation for Board Sales Invoicing -> Veza OAA
#
# Usage:
#   bash preflight.sh          # interactive menu
#   bash preflight.sh --all    # run all checks non-interactively; exit 0/1
# =============================================================================
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SLUG="board-sales-invoicing"
MAIN_SCRIPT="${SCRIPT_DIR}/${SLUG}.py"
ENV_FILE="${SCRIPT_DIR}/.env"
VENV_PYTHON="${SCRIPT_DIR}/venv/bin/python3"
LOG_FILE="${SCRIPT_DIR}/preflight_$(date +%Y%m%d_%H%M%S).log"

# Resolve Python to venv if available, else system python3
PYTHON="${VENV_PYTHON}"
[[ -x "${PYTHON}" ]] || PYTHON="python3"

# ---------------------------------------------------------------------------
# Colors & counters
# ---------------------------------------------------------------------------
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; NC='\033[0m'; BOLD='\033[1m'
TESTS_PASSED=0; TESTS_FAILED=0; TESTS_WARNING=0

pass()  { echo -e "${GREEN}[PASS]${NC} $*"; echo "[PASS] $*" >> "${LOG_FILE}"; (( TESTS_PASSED++  )) || true; }
fail()  { echo -e "${RED}[FAIL]${NC} $*";   echo "[FAIL] $*" >> "${LOG_FILE}"; (( TESTS_FAILED++  )) || true; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; echo "[WARN] $*" >> "${LOG_FILE}"; (( TESTS_WARNING++ )) || true; }
info()  { echo -e "${BLUE}[INFO]${NC} $*";   echo "[INFO] $*" >> "${LOG_FILE}"; }
hdr()   { echo -e "\n${BOLD}=== $* ===${NC}"; echo "" >> "${LOG_FILE}"; echo "=== $* ===" >> "${LOG_FILE}"; }

_source_env() {
    [[ -f "${ENV_FILE}" ]] && { set -a; source "${ENV_FILE}" 2>/dev/null; set +a; } || true
}

_mask() {
    local v="$1"
    [[ ${#v} -le 8 ]] && echo "***" || echo "${v:0:8}***"
}

# ---------------------------------------------------------------------------
# 1 -- System Requirements
# ---------------------------------------------------------------------------
check_system_requirements() {
    hdr "1 -- System Requirements"

    # Python >= 3.9
    if command -v python3 &>/dev/null; then
        PV=$(python3 -c 'import sys; print(f"{sys.version_info.major}.{sys.version_info.minor}")')
        PM=$(echo "${PV}" | cut -d. -f1)
        Pm=$(echo "${PV}" | cut -d. -f2)
        if [[ "${PM}" -ge 3 ]] && [[ "${Pm}" -ge 9 ]]; then
            pass "Python ${PV} (>= 3.9 required)"
        else
            fail "Python ${PV} -- 3.9+ required"
        fi
    else
        fail "python3 not found in PATH"
    fi

    # pip
    python3 -m pip --version &>/dev/null 2>&1 && pass "pip available" || fail "pip not available"

    # venv
    if [[ -x "${VENV_PYTHON}" ]]; then
        pass "venv found: ${SCRIPT_DIR}/venv"
    else
        warn "No venv at ${SCRIPT_DIR}/venv -- run: python3 -m venv venv && venv/bin/pip install -r requirements.txt"
    fi

    # OS info
    if [[ -f /etc/os-release ]]; then
        OS_NAME=$(grep -E '^PRETTY_NAME=' /etc/os-release | cut -d= -f2 | tr -d '"')
        info "OS: ${OS_NAME}"
    fi

    # curl
    command -v curl &>/dev/null && pass "curl available" || fail "curl not found"

    # Java (required for jaydebeapi/JPype1)
    if command -v java &>/dev/null; then
        JV=$(java -version 2>&1 | awk -F '"' '/version/ {print $2}')
        pass "Java ${JV} (required for JDBC)"
    else
        fail "Java not found -- JRE 8+ required (install openjdk-11-jre-headless)"
    fi

    # JT400 JAR
    _source_env
    JDBC_JAR_VAL="${JDBC_JAR:-/opt/jt400/jt400.jar}"
    if [[ -f "${JDBC_JAR_VAL}" ]]; then
        pass "JT400 JAR found: ${JDBC_JAR_VAL}"
    else
        fail "JT400 JAR not found at ${JDBC_JAR_VAL} -- download from https://repo1.maven.org/maven2/net/sf/jt400/jt400/"
    fi

    # jq (optional)
    command -v jq &>/dev/null && pass "jq available (optional)" \
        || warn "jq not found (optional)"
}

# ---------------------------------------------------------------------------
# 2 -- Python Dependencies
# ---------------------------------------------------------------------------
check_python_dependencies() {
    hdr "2 -- Python Dependencies"
    REQS="${SCRIPT_DIR}/requirements.txt"
    [[ -f "${REQS}" ]] || { fail "requirements.txt not found at ${REQS}"; return; }
    info "Using Python: ${PYTHON}"

    while IFS= read -r line || [[ -n "${line}" ]]; do
        [[ -z "${line}" || "${line}" =~ ^# ]] && continue
        pkg=$(echo "${line}" | sed 's/[>=<!].*//' | tr -d ' ')
        imp="${pkg}"
        case "${pkg}" in
            python-dotenv) imp="dotenv"     ;;
            oaaclient)     imp="oaaclient"  ;;
            jaydebeapi)    imp="jaydebeapi" ;;
            JPype1)        imp="jpype"      ;;
        esac
        ver=$(${PYTHON} -c "import ${imp}; v=getattr(${imp},'__version__','?'); print(v)" 2>/dev/null || echo "NOT FOUND")
        if [[ "${ver}" == "NOT FOUND" ]]; then
            fail "${pkg} -- NOT installed"
        else
            pass "${pkg} -- ${ver}"
        fi
    done < "${REQS}"
}

# ---------------------------------------------------------------------------
# 3 -- Configuration File
# ---------------------------------------------------------------------------
check_configuration() {
    hdr "3 -- Configuration File"

    if [[ ! -f "${ENV_FILE}" ]]; then
        fail ".env not found at ${ENV_FILE}"
        info "Generate: cp ${SCRIPT_DIR}/.env.example ${ENV_FILE} && chmod 600 ${ENV_FILE}"
        return
    fi
    pass ".env found"

    PERMS=$(stat -c "%a" "${ENV_FILE}" 2>/dev/null || stat -f "%OLp" "${ENV_FILE}" 2>/dev/null || echo "?")
    [[ "${PERMS}" == "600" ]] && pass ".env permissions: 600" \
        || warn ".env permissions: ${PERMS} (should be 600 -- run: chmod 600 ${ENV_FILE})"

    _source_env

    _chk() {
        local name="$1" val="${!1:-}" sensitive="${2:-false}"
        if [[ -z "${val}" ]]; then
            fail "${name} -- NOT SET"
        elif [[ "${val}" == your_* || "${val}" == *your-* ]]; then
            fail "${name} -- still a placeholder value"
        else
            if [[ "${sensitive}" == "true" ]]; then
                pass "${name} -- set ($(_mask "${val}"))"
            else
                pass "${name} -- ${val}"
            fi
        fi
    }

    _chk DB_URL
    _chk DB_USER
    _chk DB_PASSWORD  true
    _chk JDBC_JAR
    _chk VEZA_URL
    _chk VEZA_API_KEY true

    [[ -n "${PROVIDER_NAME:-}" ]]   && info "PROVIDER_NAME   -- ${PROVIDER_NAME}"   || info "PROVIDER_NAME   -- not set (default: Board Sales Invoicing)"
    [[ -n "${DATASOURCE_NAME:-}" ]] && info "DATASOURCE_NAME -- ${DATASOURCE_NAME}" || info "DATASOURCE_NAME -- not set (default: board-sales-invoicing)"
}

# ---------------------------------------------------------------------------
# 4 -- Network Connectivity
# ---------------------------------------------------------------------------
check_network_connectivity() {
    hdr "4 -- Network Connectivity"
    _source_env

    # Extract hostname from JDBC URL  jdbc:as400://hostname/library...
    DB_HOST=$(echo "${DB_URL:-}" | sed 's|jdbc:as400://||' | cut -d'/' -f1 | cut -d';' -f1)
    VEZA_HOST=$(echo "${VEZA_URL:-}" | sed 's|https\?://||' | cut -d/ -f1)

    if [[ -n "${DB_HOST}" ]]; then
        for port in 449 8471; do
            if nc -zw 5 "${DB_HOST}" "${port}" &>/dev/null 2>&1 || \
               bash -c "exec 3<>/dev/tcp/${DB_HOST}/${port}" &>/dev/null 2>&1; then
                pass "TCP ${DB_HOST}:${port} -- reachable"
            else
                warn "TCP ${DB_HOST}:${port} -- not reachable (firewall or port may differ)"
            fi
        done
    else
        warn "DB_URL not set -- skipping IBM i network check"
    fi

    if [[ -n "${VEZA_HOST}" ]]; then
        RESULT=$(curl -s -o /dev/null -w "%{http_code}|%{time_total}" -m 10 "https://${VEZA_HOST}" 2>/dev/null || echo "000|0")
        CODE=$(echo "${RESULT}" | cut -d'|' -f1)
        LAT=$(echo "${RESULT}"  | cut -d'|' -f2)
        [[ "${CODE}" =~ ^[23] ]] && pass "HTTPS ${VEZA_HOST}:443 -- HTTP ${CODE} (${LAT}s)" \
                                  || fail "HTTPS ${VEZA_HOST}:443 -- HTTP ${CODE}"
    else
        warn "VEZA_URL not set -- skipping Veza connectivity check"
    fi
}

# ---------------------------------------------------------------------------
# 5 -- Authentication
# ---------------------------------------------------------------------------
check_authentication() {
    hdr "5 -- Authentication"
    _source_env

    JDBC_JAR_VAL="${JDBC_JAR:-/opt/jt400/jt400.jar}"

    # JDBC connectivity test
    if [[ -z "${DB_URL:-}" || -z "${DB_USER:-}" || -z "${DB_PASSWORD:-}" ]]; then
        warn "IBM i credentials not fully set -- skipping JDBC auth test"
    elif [[ ! -f "${JDBC_JAR_VAL}" ]]; then
        warn "JDBC_JAR not found at ${JDBC_JAR_VAL} -- skipping JDBC auth test"
    else
        info "Testing JDBC connection to ${DB_URL} as ${DB_USER} ..."
        JDBC_RESULT=$(${PYTHON} - <<PYEOF 2>&1
import sys
try:
    import jaydebeapi
except ImportError:
    print("IMPORT_ERROR: jaydebeapi not installed")
    sys.exit(1)
try:
    conn = jaydebeapi.connect(
        "com.ibm.as400.access.AS400JDBCDriver",
        "${DB_URL}",
        ["${DB_USER}", "${DB_PASSWORD}"],
        "${JDBC_JAR_VAL}",
    )
    cur = conn.cursor()
    cur.execute("VALUES current date")
    row = cur.fetchone()
    conn.close()
    print(f"OK: current date = {row[0]}")
except Exception as e:
    print(f"FAIL: {e}")
    sys.exit(1)
PYEOF
        )
        echo "${JDBC_RESULT}" | grep -q "^OK:" \
            && pass "JDBC auth -- ${JDBC_RESULT}" \
            || fail "JDBC auth failed: ${JDBC_RESULT}"
    fi

    # Veza API key test
    if [[ -n "${VEZA_URL:-}" && -n "${VEZA_API_KEY:-}" ]]; then
        info "Testing Veza API key ..."
        CODE=$(curl -s -o /dev/null -w "%{http_code}" -m 15 \
            -H "Authorization: Bearer ${VEZA_API_KEY}" \
            "${VEZA_URL}/api/v1/providers" 2>/dev/null || echo "000")
        case "${CODE}" in
            200)     pass "Veza API key -- HTTP ${CODE} (valid)" ;;
            401|403) fail "Veza API key -- HTTP ${CODE} (invalid or insufficient permissions)" ;;
            *)       warn "Veza API key -- HTTP ${CODE} (unexpected response)" ;;
        esac
    else
        warn "VEZA_URL or VEZA_API_KEY not set -- skipping Veza auth test"
    fi
}

# ---------------------------------------------------------------------------
# 6 -- Veza Endpoint Accessibility
# ---------------------------------------------------------------------------
check_veza_endpoint() {
    hdr "6 -- Veza Endpoint Accessibility"
    _source_env
    if [[ -z "${VEZA_URL:-}" || -z "${VEZA_API_KEY:-}" ]]; then
        warn "VEZA_URL or VEZA_API_KEY not set -- skipping"
        return
    fi

    BODY='{"query":"nodes{InstanceId first:1}"}'
    RESP=$(curl -s -w "\n%{http_code}" -m 15 \
        -X POST \
        -H "Authorization: Bearer ${VEZA_API_KEY}" \
        -H "Content-Type: application/json" \
        -d "${BODY}" \
        "${VEZA_URL}/api/v1/assessments/query_spec:nodes" 2>/dev/null || echo -e "\n000")
    CODE=$(echo "${RESP}" | tail -1)
    [[ "${CODE}" == "200" ]] \
        && pass "Veza query endpoint -- HTTP ${CODE}" \
        || fail "Veza query endpoint -- HTTP ${CODE}"
}

# ---------------------------------------------------------------------------
# 7 -- Deployment Structure
# ---------------------------------------------------------------------------
check_deployment() {
    hdr "7 -- Deployment Structure"

    if [[ -f "${MAIN_SCRIPT}" ]]; then
        pass "Main script: ${MAIN_SCRIPT}"
        [[ -r "${MAIN_SCRIPT}" ]] && pass "Main script readable" || fail "Main script not readable"
    else
        fail "Main script NOT found: ${MAIN_SCRIPT}"
    fi

    [[ -f "${SCRIPT_DIR}/requirements.txt" ]] \
        && pass "requirements.txt found" || fail "requirements.txt NOT found"

    if [[ -d "${SCRIPT_DIR}/logs" ]]; then
        [[ -w "${SCRIPT_DIR}/logs" ]] && pass "logs/ writable" || warn "logs/ not writable"
    else
        info "logs/ does not exist -- will be created on first run"
    fi

    info "Running as: $(whoami)"
    [[ "${SCRIPT_DIR}" == /opt/VEZA/* ]] \
        && pass "Installed at recommended path: ${SCRIPT_DIR}" \
        || info "Install path: ${SCRIPT_DIR}"

    if [[ -f "${MAIN_SCRIPT}" && -x "${PYTHON}" ]]; then
        HOUT=$(${PYTHON} "${MAIN_SCRIPT}" --help 2>&1)
        echo "${HOUT}" | grep -q "db-url" \
            && pass "--help runs cleanly (--db-url present)" \
            || fail "--help did not return expected output"
    fi
}

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
print_summary() {
    hdr "Validation Summary"
    echo -e "${GREEN}Passed:${NC}   ${TESTS_PASSED}"
    echo -e "${RED}Failed:${NC}   ${TESTS_FAILED}"
    echo -e "${YELLOW}Warnings:${NC} ${TESTS_WARNING}"
    echo ""
    echo "Full log: ${LOG_FILE}"
    echo ""
    if [[ "${TESTS_FAILED}" -eq 0 ]]; then
        echo -e "${GREEN}All checks passed!${NC}"
        echo ""
        echo "Run the connector:"
        echo "  cd ${SCRIPT_DIR}"
        echo "  ${PYTHON} board-sales-invoicing.py --env-file .env"
        return 0
    else
        echo -e "${RED}[FAIL] Some checks failed -- address issues above before deployment.${NC}"
        return 1
    fi
}

# ---------------------------------------------------------------------------
# Utilities
# ---------------------------------------------------------------------------
display_config() {
    hdr "Current Configuration"
    _source_env
    echo "  DB_URL        : ${DB_URL:-NOT SET}"
    echo "  DB_USER       : ${DB_USER:-NOT SET}"
    echo "  DB_PASSWORD   : $(_mask "${DB_PASSWORD:-}")"
    echo "  JDBC_JAR      : ${JDBC_JAR:-NOT SET}"
    echo "  VEZA_URL      : ${VEZA_URL:-NOT SET}"
    echo "  VEZA_API_KEY  : $(_mask "${VEZA_API_KEY:-}")"
    echo "  PROVIDER_NAME : ${PROVIDER_NAME:-Board Sales Invoicing (default)}"
    echo "  DATASOURCE    : ${DATASOURCE_NAME:-board-sales-invoicing (default)}"
}

generate_env_template() {
    if [[ -f "${ENV_FILE}" ]]; then
        echo "  .env already exists at ${ENV_FILE}"
        echo "  Use --overwrite-env flag in the installer to replace it."
    else
        cp "${SCRIPT_DIR}/.env.example" "${ENV_FILE}" 2>/dev/null || \
            cat > "${ENV_FILE}" <<'ENVEOF'
DB_URL=jdbc:as400://your-ibmi-host/PDMSTRDBLB;naming=sql;date format=iso
DB_USER=your_ibmi_user
DB_PASSWORD=your_ibmi_password
JDBC_JAR=/opt/jt400/jt400.jar
VEZA_URL=https://your-veza-host
VEZA_API_KEY=your_veza_api_key_here
ENVEOF
        chmod 600 "${ENV_FILE}"
        echo "  .env template created at ${ENV_FILE}"
    fi
}

install_deps() {
    if [[ -x "${VENV_PYTHON}" ]]; then
        "${SCRIPT_DIR}/venv/bin/pip" install -r "${SCRIPT_DIR}/requirements.txt"
    else
        python3 -m venv "${SCRIPT_DIR}/venv"
        "${SCRIPT_DIR}/venv/bin/pip" install -r "${SCRIPT_DIR}/requirements.txt"
    fi
    echo "Dependencies installed."
}

# ---------------------------------------------------------------------------
# Run all checks
# ---------------------------------------------------------------------------
run_all_checks() {
    : > "${LOG_FILE}"
    echo "Board Sales Invoicing Preflight -- $(date)" >> "${LOG_FILE}"
    check_system_requirements
    check_python_dependencies
    check_configuration
    check_network_connectivity
    check_authentication
    check_veza_endpoint
    check_deployment
    print_summary
}

# ---------------------------------------------------------------------------
# Interactive menu
# ---------------------------------------------------------------------------
show_menu() {
    echo ""
    echo -e "${BOLD}Board Sales Invoicing -> Veza OAA -- Preflight${NC}"
    echo "==============================================="
    echo "  1)  System Requirements"
    echo "  2)  Python Dependencies"
    echo "  3)  Configuration File"
    echo "  4)  Network Connectivity"
    echo "  5)  Authentication"
    echo "  6)  Veza Endpoint"
    echo "  7)  Deployment Structure"
    echo "  8)  Run All Checks"
    echo "  ---"
    echo "  9)  Display current config"
    echo "  10) Generate .env template"
    echo "  11) Install Python dependencies"
    echo "  q)  Quit"
    echo ""
    IFS= read -r -p "Select: " choice </dev/tty
    case "${choice}" in
        1)  check_system_requirements ;;
        2)  check_python_dependencies ;;
        3)  check_configuration ;;
        4)  check_network_connectivity ;;
        5)  check_authentication ;;
        6)  check_veza_endpoint ;;
        7)  check_deployment ;;
        8)  run_all_checks ;;
        9)  display_config ;;
        10) generate_env_template ;;
        11) install_deps ;;
        q|Q) echo "Exiting."; exit 0 ;;
        *) echo "Invalid option." ;;
    esac
    show_menu
}

# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------
echo -e "${BOLD}Board Sales Invoicing -> Veza OAA -- Preflight${NC}"
echo "Log: ${LOG_FILE}"

if [[ "${1:-}" == "--all" ]]; then
    run_all_checks
    [[ "${TESTS_FAILED}" -eq 0 ]] && exit 0 || exit 1
else
    show_menu
fi
