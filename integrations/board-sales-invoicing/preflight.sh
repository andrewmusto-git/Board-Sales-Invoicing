#!/usr/bin/env bash
# =============================================================================
# preflight.sh — Pre-deployment validation for Board Sales Invoicing → Veza OAA
#
# Usage:
#   bash preflight.sh          # interactive menu
#   bash preflight.sh --all    # run all checks non-interactively, exit 0/1
# =============================================================================
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SLUG="board-sales-invoicing"
MAIN_SCRIPT="${SCRIPT_DIR}/${SLUG}.py"
ENV_FILE="${SCRIPT_DIR}/.env"
VENV_PYTHON="${SCRIPT_DIR}/venv/bin/python3"
SYSTEM_PYTHON="python3"
LOG_FILE="${SCRIPT_DIR}/preflight_$(date +%Y%m%d_%H%M%S).log"

# ---------------------------------------------------------------------------
# Colors & counters
# ---------------------------------------------------------------------------
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; NC='\033[0m'; BOLD='\033[1m'

TESTS_PASSED=0; TESTS_FAILED=0; TESTS_WARNING=0

print_success() { local msg="$1"; echo -e "${GREEN}✓${NC} ${msg}"; echo "[PASS] ${msg}" >> "${LOG_FILE}"; ((TESTS_PASSED++)) || true; }
print_fail()    { local msg="$1"; echo -e "${RED}✗${NC} ${msg}";   echo "[FAIL] ${msg}" >> "${LOG_FILE}"; ((TESTS_FAILED++))  || true; }
print_warning() { local msg="$1"; echo -e "${YELLOW}⚠${NC} ${msg}"; echo "[WARN] ${msg}" >> "${LOG_FILE}"; ((TESTS_WARNING++)) || true; }
print_info()    { local msg="$1"; echo -e "${BLUE}ℹ${NC} ${msg}";  echo "[INFO] ${msg}" >> "${LOG_FILE}"; }
print_header()  { echo -e "\n${BOLD}=== $* ===${NC}"; echo "" >> "${LOG_FILE}"; echo "=== $* ===" >> "${LOG_FILE}"; }

# Resolve which python to use
PYTHON="${SYSTEM_PYTHON}"
[[ -x "${VENV_PYTHON}" ]] && PYTHON="${VENV_PYTHON}"

# Source .env for variable access (masked in output)
_source_env() {
    if [[ -f "${ENV_FILE}" ]]; then
        # shellcheck disable=SC1090
        set -a; source "${ENV_FILE}"; set +a
    fi
}

_mask() {
    local val="$1"
    if [[ ${#val} -le 8 ]]; then echo "***"; else echo "${val:0:8}***"; fi
}

# ---------------------------------------------------------------------------
# Section 1 — System Requirements
# ---------------------------------------------------------------------------
check_system_requirements() {
    print_header "1 — System Requirements"

    # Python version ≥ 3.9
    if command -v python3 &>/dev/null; then
        PY_VER=$(python3 -c 'import sys; print(f"{sys.version_info.major}.{sys.version_info.minor}")')
        PY_MAJ=$(echo "${PY_VER}" | cut -d. -f1)
        PY_MIN=$(echo "${PY_VER}" | cut -d. -f2)
        if [[ "${PY_MAJ}" -ge 3 ]] && [[ "${PY_MIN}" -ge 9 ]]; then
            print_success "Python ${PY_VER} (≥ 3.9 required)"
        else
            print_fail "Python ${PY_VER} found — 3.9+ required"
        fi
    else
        print_fail "python3 not found in PATH"
    fi

    # pip3
    if python3 -m pip --version &>/dev/null 2>&1; then
        print_success "pip available"
    else
        print_fail "pip not available — install python3-pip"
    fi

    # Virtual environment detection
    if [[ -x "${VENV_PYTHON}" ]]; then
        print_success "Virtual environment found at ${SCRIPT_DIR}/venv"
    else
        print_warning "No virtual environment at ${SCRIPT_DIR}/venv — run: python3 -m venv venv && venv/bin/pip install -r requirements.txt"
    fi

    # OS info
    if [[ -f /etc/os-release ]]; then
        OS_NAME=$(grep -E '^PRETTY_NAME=' /etc/os-release | cut -d= -f2 | tr -d '"')
        print_info "OS: ${OS_NAME}"
    elif [[ "$(uname)" == "Darwin" ]]; then
        print_info "OS: macOS $(sw_vers -productVersion)"
    fi

    # curl
    if command -v curl &>/dev/null; then
        print_success "curl available ($(curl --version | head -1))"
    else
        print_fail "curl not found — required for API auth tests"
    fi

    # jq (optional)
    if command -v jq &>/dev/null; then
        print_success "jq available"
    else
        print_warning "jq not found (optional) — JSON output will not be pretty-printed"
    fi

    # unixODBC (not required — connector uses JDBC)
    if command -v isql &>/dev/null || command -v odbcinst &>/dev/null; then
        print_info "unixODBC tools found (not required for JDBC connector)"
    else
        print_info "unixODBC not found (not required — this connector uses JDBC)"
    fi

    # Java runtime (≥ 8 required for jaydebeapi / JPype1)
    if command -v java &>/dev/null; then
        JAVA_VER=$(java -version 2>&1 | awk -F '"' '/version/ {print $2}')
        print_success "Java found — version ${JAVA_VER}"
    else
        print_fail "Java not found — JRE 8+ is required for jaydebeapi/JPype1 (install openjdk-11-jre-headless or java-11-openjdk-headless)"
    fi

    # JT400 JAR
    JDBC_JAR_VAL="${JDBC_JAR:-/opt/jt400/jt400.jar}"
    if [[ -f "${JDBC_JAR_VAL}" ]]; then
        print_success "JT400 JAR found: ${JDBC_JAR_VAL}"
    else
        print_fail "JT400 JAR not found at ${JDBC_JAR_VAL} — download from https://repo1.maven.org/maven2/net/sf/jt400/jt400/"
    fi
}

# ---------------------------------------------------------------------------
# Section 2 — Python Dependencies
# ---------------------------------------------------------------------------
check_python_dependencies() {
    print_header "2 — Python Dependencies"
    REQUIREMENTS="${SCRIPT_DIR}/requirements.txt"

    if [[ ! -f "${REQUIREMENTS}" ]]; then
        print_fail "requirements.txt not found at ${REQUIREMENTS}"
        return
    fi

    print_info "Using Python: ${PYTHON}"

    while IFS= read -r line || [[ -n "${line}" ]]; do
        # Skip blank lines and comments
        [[ -z "${line}" || "${line}" =~ ^# ]] && continue
        pkg_name=$(echo "${line}" | sed 's/[>=<!].*//' | tr -d ' ')
        import_name="${pkg_name}"
        # Map package install names to import names
        case "${pkg_name}" in
            python-dotenv) import_name="dotenv" ;;
            oaaclient)     import_name="oaaclient" ;;
            jaydebeapi)    import_name="jaydebeapi" ;;
            JPype1)        import_name="jpype" ;;
        esac

        version=$(${PYTHON} -c "import ${import_name}; v=getattr(${import_name},'__version__','?'); print(v)" 2>/dev/null || echo "NOT FOUND")
        if [[ "${version}" == "NOT FOUND" ]]; then
            print_fail "${pkg_name} — NOT installed (run: ${PYTHON} -m pip install -r requirements.txt)"
        else
            print_success "${pkg_name} — ${version}"
        fi
    done < "${REQUIREMENTS}"
}

# ---------------------------------------------------------------------------
# Section 3 — Configuration File
# ---------------------------------------------------------------------------
check_configuration() {
    print_header "3 — Configuration File"

    if [[ ! -f "${ENV_FILE}" ]]; then
        print_fail ".env file not found at ${ENV_FILE}"
        print_info "Generate template: cp ${SCRIPT_DIR}/.env.example ${ENV_FILE} && chmod 600 ${ENV_FILE}"
        return
    fi
    print_success ".env file found"

    # File permissions
    PERMS=$(stat -c "%a" "${ENV_FILE}" 2>/dev/null || stat -f "%OLp" "${ENV_FILE}" 2>/dev/null || echo "unknown")
    if [[ "${PERMS}" == "600" ]]; then
        print_success ".env permissions: ${PERMS}"
    else
        print_warning ".env permissions: ${PERMS} (should be 600 — run: chmod 600 ${ENV_FILE})"
    fi

    _source_env

    # Required variables
    _check_var() {
        local name="$1" val="${!1:-}" sensitive="${2:-false}"
        if [[ -z "${val}" ]]; then
            print_fail "${name} — NOT SET"
        elif [[ "${val}" == your_* ]] || [[ "${val}" == *your-* ]]; then
            print_fail "${name} — still a placeholder value"
        else
            if [[ "${sensitive}" == "true" ]]; then
                print_success "${name} — set ($(_mask "${val}"))"
            else
                print_success "${name} — ${val}"
            fi
        fi
    }

    _check_var DB_URL
    _check_var DB_USER
    _check_var DB_PASSWORD true
    _check_var JDBC_JAR
    _check_var VEZA_URL
    _check_var VEZA_API_KEY true

    # Optional
    [[ -n "${PROVIDER_NAME:-}" ]] && print_info "PROVIDER_NAME — ${PROVIDER_NAME}" || print_info "PROVIDER_NAME — not set (default: Board Sales Invoicing)"
    [[ -n "${DATASOURCE_NAME:-}" ]] && print_info "DATASOURCE_NAME — ${DATASOURCE_NAME}" || print_info "DATASOURCE_NAME — not set (default: board-sales-invoicing)"
}

# ---------------------------------------------------------------------------
# Section 4 — Network Connectivity
# ---------------------------------------------------------------------------
check_network_connectivity() {
    print_header "4 — Network Connectivity"
    _source_env

    # Extract hostname from JDBC URL (jdbc:as400://hostname/...)
    DB_URL_VAL="${DB_URL:-}"
    DB_HOST_VAL=$(echo "${DB_URL_VAL}" | sed 's|jdbc:as400://||' | cut -d'/' -f1 | cut -d';' -f1)
    DB_PORT=8471  # IBM i DRDA / DDM port; also check 449 (IBM i host server)
    VEZA_HOST=$(echo "${VEZA_URL:-}" | sed 's|https\?://||' | cut -d/ -f1)

    # TCP to IBM i (port 449 = IBM i host server; 8471 = DRDA)
    for port in 449 8471; do
        if nc -zw 5 "${DB_HOST_VAL}" "${port}" &>/dev/null 2>&1; then
            print_success "TCP ${DB_HOST_VAL}:${port} — reachable"
        elif bash -c "exec 3<>/dev/tcp/${DB_HOST_VAL}/${port}" &>/dev/null 2>&1; then
            print_success "TCP ${DB_HOST_VAL}:${port} — reachable (bash fallback)"
        else
            print_warning "TCP ${DB_HOST_VAL}:${port} — not reachable (firewall or port may differ)"
        fi
    done

    # HTTPS to Veza
    if [[ -n "${VEZA_HOST}" ]]; then
        HTTP_RESULT=$(curl -s -o /dev/null -w "%{http_code}|%{time_total}" -m 10 "https://${VEZA_HOST}" 2>/dev/null || echo "000|0")
        HTTP_CODE=$(echo "${HTTP_RESULT}" | cut -d'|' -f1)
        LATENCY=$(echo "${HTTP_RESULT}" | cut -d'|' -f2)
        if [[ "${HTTP_CODE}" =~ ^[23] ]]; then
            print_success "HTTPS ${VEZA_HOST}:443 — HTTP ${HTTP_CODE} (${LATENCY}s)"
        else
            print_fail "HTTPS ${VEZA_HOST}:443 — HTTP ${HTTP_CODE} (check VEZA_URL)"
        fi
    else
        print_warning "VEZA_URL not set — skipping Veza connectivity check"
    fi
}

# ---------------------------------------------------------------------------
# Section 5 — API / Database Authentication
# ---------------------------------------------------------------------------
check_authentication() {
    print_header "5 — API / Database Authentication"
    _source_env

    DB_URL_VAL="${DB_URL:-}"
    DB_USER_VAL="${DB_USER:-}"
    DB_PASSWORD_VAL="${DB_PASSWORD:-}"
    JDBC_JAR_VAL="${JDBC_JAR:-/opt/jt400/jt400.jar}"
    VEZA_URL_VAL="${VEZA_URL:-}"
    VEZA_API_KEY_VAL="${VEZA_API_KEY:-}"

    # JDBC connectivity test via Python / jaydebeapi
    if [[ -z "${DB_URL_VAL}" ]] || [[ -z "${DB_USER_VAL}" ]] || [[ -z "${DB_PASSWORD_VAL}" ]]; then
        print_warning "IBM i credentials not fully set — skipping JDBC auth test"
    elif [[ ! -f "${JDBC_JAR_VAL}" ]]; then
        print_warning "JDBC_JAR not found at ${JDBC_JAR_VAL} — skipping JDBC auth test"
    else
        print_info "Testing JDBC connection to ${DB_URL_VAL} as ${DB_USER_VAL} …"

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
        "${DB_URL_VAL}",
        ["${DB_USER_VAL}", "${DB_PASSWORD_VAL}"],
        "${JDBC_JAR_VAL}",
    )
    cursor = conn.cursor()
    cursor.execute("VALUES current date")
    row = cursor.fetchone()
    conn.close()
    print(f"OK: current date = {row[0]}")
except Exception as e:
    print(f"FAIL: {e}")
    sys.exit(1)
PYEOF
        )

        if echo "${JDBC_RESULT}" | grep -q "^OK:"; then
            print_success "IBM i JDBC auth — ${JDBC_RESULT}"
        else
            print_fail "IBM i JDBC auth failed: ${JDBC_RESULT}"
        fi
    fi

    # Veza API key test
    if [[ -n "${VEZA_URL_VAL}" ]] && [[ -n "${VEZA_API_KEY_VAL}" ]]; then
        print_info "Testing Veza API key against ${VEZA_URL_VAL} …"
        VEZA_RESPONSE=$(curl -s -o /dev/null -w "%{http_code}" -m 15 \
            -H "Authorization: Bearer ${VEZA_API_KEY_VAL}" \
            "${VEZA_URL_VAL}/api/v1/providers" 2>/dev/null || echo "000")
        if [[ "${VEZA_RESPONSE}" == "200" ]]; then
            print_success "Veza API key — HTTP ${VEZA_RESPONSE} (valid)"
        elif [[ "${VEZA_RESPONSE}" == "401" || "${VEZA_RESPONSE}" == "403" ]]; then
            print_fail "Veza API key — HTTP ${VEZA_RESPONSE} (invalid or insufficient permissions)"
        else
            print_warning "Veza API key — HTTP ${VEZA_RESPONSE} (unexpected response)"
        fi
    else
        print_warning "VEZA_URL or VEZA_API_KEY not set — skipping Veza auth test"
    fi
}

# ---------------------------------------------------------------------------
# Section 6 — API Endpoint Accessibility
# ---------------------------------------------------------------------------
check_api_endpoints() {
    print_header "6 — API Endpoint Accessibility"
    _source_env

    VEZA_URL_VAL="${VEZA_URL:-}"
    VEZA_API_KEY_VAL="${VEZA_API_KEY:-}"

    if [[ -z "${VEZA_URL_VAL}" ]] || [[ -z "${VEZA_API_KEY_VAL}" ]]; then
        print_warning "VEZA_URL or VEZA_API_KEY not set — skipping endpoint check"
        return
    fi

    # Veza query endpoint
    QUERY_BODY='{"query":"nodes{InstanceId first:1}"}'
    QUERY_RESPONSE=$(curl -s -w "\n%{http_code}" -m 15 \
        -X POST \
        -H "Authorization: Bearer ${VEZA_API_KEY_VAL}" \
        -H "Content-Type: application/json" \
        -d "${QUERY_BODY}" \
        "${VEZA_URL_VAL}/api/v1/assessments/query_spec:nodes" 2>/dev/null || echo -e "\n000")
    QUERY_CODE=$(echo "${QUERY_RESPONSE}" | tail -1)
    QUERY_BODY_RESP=$(echo "${QUERY_RESPONSE}" | head -n -1)

    if [[ "${QUERY_CODE}" == "200" ]]; then
        print_success "Veza query endpoint — HTTP ${QUERY_CODE}"
    else
        print_fail "Veza query endpoint — HTTP ${QUERY_CODE}"
        print_info "Response: $(echo "${QUERY_BODY_RESP}" | ${PYTHON} -c 'import sys,json; d=sys.stdin.read(); print(json.dumps(json.loads(d),indent=2))' 2>/dev/null || echo "${QUERY_BODY_RESP}")"
    fi
}

# ---------------------------------------------------------------------------
# Section 7 — Deployment Structure
# ---------------------------------------------------------------------------
check_deployment_structure() {
    print_header "7 — Deployment Structure"

    if [[ -f "${MAIN_SCRIPT}" ]]; then
        print_success "Main script found: ${MAIN_SCRIPT}"
        if [[ -r "${MAIN_SCRIPT}" ]]; then
            print_success "Main script is readable"
        else
            print_fail "Main script is not readable"
        fi
    else
        print_fail "Main script NOT found: ${MAIN_SCRIPT}"
    fi

    REQS="${SCRIPT_DIR}/requirements.txt"
    if [[ -f "${REQS}" ]]; then
        print_success "requirements.txt found"
    else
        print_fail "requirements.txt NOT found at ${REQS}"
    fi

    LOG_DIR="${SCRIPT_DIR}/logs"
    if [[ -d "${LOG_DIR}" ]]; then
        if [[ -w "${LOG_DIR}" ]]; then
            print_success "logs/ directory exists and is writable"
        else
            print_warning "logs/ directory exists but is not writable — fix permissions"
        fi
    else
        print_info "logs/ directory does not exist — it will be auto-created on first run"
    fi

    CURRENT_USER=$(whoami)
    print_info "Running as user: ${CURRENT_USER}"
    if [[ "${SCRIPT_DIR}" == /opt/VEZA/* ]]; then
        print_success "Installed at recommended path: ${SCRIPT_DIR}"
    else
        print_info "Install path (${SCRIPT_DIR}) differs from recommended /opt/VEZA/board-sales-invoicing-veza/scripts/"
    fi

    # Validate --help runs cleanly
    if [[ -f "${MAIN_SCRIPT}" ]] && [[ -x "${PYTHON}" ]]; then
        HELP_OUT=$(${PYTHON} "${MAIN_SCRIPT}" --help 2>&1)
        if echo "${HELP_OUT}" | grep -q "db-url"; then
            print_success "python3 board-sales-invoicing.py --help runs cleanly"
        else
            print_fail "python3 board-sales-invoicing.py --help did not return expected output"
            print_info "${HELP_OUT}"
        fi
    fi
}

# ---------------------------------------------------------------------------
# Section 8 — Summary
# ---------------------------------------------------------------------------
print_summary() {
    print_header "Validation Summary"
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
        echo -e "${RED}✗ Some checks failed. Please address the issues above before deployment.${NC}"
        return 1
    fi
}

# ---------------------------------------------------------------------------
# Utility functions
# ---------------------------------------------------------------------------
display_config() {
    print_header "Current Configuration"
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
VEZA_URL=https://your-company.veza.com
VEZA_API_KEY=your_veza_api_key_here
ENVEOF
        chmod 600 "${ENV_FILE}"
        echo "  .env template created at ${ENV_FILE}"
    fi
}

install_dependencies() {
    if [[ -x "${VENV_PYTHON}" ]]; then
        "${SCRIPT_DIR}/venv/bin/pip" install -r "${SCRIPT_DIR}/requirements.txt"
    else
        python3 -m venv "${SCRIPT_DIR}/venv"
        "${SCRIPT_DIR}/venv/bin/pip" install -r "${SCRIPT_DIR}/requirements.txt"
    fi
    echo "Dependencies installed."
}

# ---------------------------------------------------------------------------
# Interactive menu
# ---------------------------------------------------------------------------
show_menu() {
    echo ""
    echo -e "${BOLD}Board Sales Invoicing → Veza OAA — Preflight Validation${NC}"
    echo "========================================================"
    echo "  1) System Requirements"
    echo "  2) Python Dependencies"
    echo "  3) Configuration File"
    echo "  4) Network Connectivity"
    echo "  5) API / Database Authentication"
    echo "  6) Veza Endpoint Accessibility"
    echo "  7) Deployment Structure"
    echo "  8) Run All Checks"
    echo "  --------"
    echo "  9)  Display current configuration"
    echo "  10) Generate .env template"
    echo "  11) Install Python dependencies"
    echo "  q)  Quit"
    echo ""
    IFS= read -r -p "Select an option: " choice </dev/tty

    case "${choice}" in
        1)  check_system_requirements ;;
        2)  check_python_dependencies ;;
        3)  check_configuration ;;
        4)  check_network_connectivity ;;
        5)  check_authentication ;;
        6)  check_api_endpoints ;;
        7)  check_deployment_structure ;;
        8)  run_all_checks ;;
        9)  display_config ;;
        10) generate_env_template ;;
        11) install_dependencies ;;
        q|Q) echo "Exiting."; exit 0 ;;
        *) echo "Invalid option." ;;
    esac

    show_menu
}

run_all_checks() {
    echo "" > "${LOG_FILE}"
    echo "Board Sales Invoicing Preflight — $(date)" >> "${LOG_FILE}"
    check_system_requirements
    check_python_dependencies
    check_configuration
    check_network_connectivity
    check_authentication
    check_api_endpoints
    check_deployment_structure
    print_summary
}

# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------
echo -e "${BOLD}Board Sales Invoicing → Veza OAA — Preflight${NC}"
echo "Log file: ${LOG_FILE}"

if [[ "${1:-}" == "--all" ]]; then
    run_all_checks
    [[ "${TESTS_FAILED}" -eq 0 ]] && exit 0 || exit 1
else
    show_menu
fi
