#!/usr/bin/env bash
# =============================================================================
# install_board-sales-invoicing.sh
# One-command installer for Board Sales Invoicing IBM i → Veza OAA connector
#
# Usage:
#   bash install_board-sales-invoicing.sh
#   bash install_board-sales-invoicing.sh --non-interactive
#   VEZA_URL=https://your-company.veza.com VEZA_API_KEY=tok \
#       DB_URL=jdbc:as400://host/PDMSTRDBLB DB_USER=u DB_PASSWORD=p \
#       JDBC_JAR=/opt/jt400/jt400.jar \
#       bash install_board-sales-invoicing.sh --non-interactive
#
# Flags:
#   --non-interactive   Use env vars instead of prompting
#   --overwrite-env     Overwrite an existing .env file
#   --install-dir PATH  Custom install root (default: /opt/VEZA/board-sales-invoicing-veza)
#   --repo-url URL      Git repository URL
#   --branch NAME       Git branch to clone (default: main)
# =============================================================================
set -uo pipefail

# ---------------------------------------------------------------------------
# Defaults
# ---------------------------------------------------------------------------
INSTALL_DIR="/opt/VEZA/board-sales-invoicing-veza"
SCRIPTS_DIR="${INSTALL_DIR}/scripts"
LOGS_DIR="${INSTALL_DIR}/logs"
JT400_DIR="/opt/jt400"
REPO_URL="${REPO_URL:-}"
BRANCH="${BRANCH:-main}"
INTEGRATION_SUBDIR="integrations/board-sales-invoicing"
NON_INTERACTIVE=false
OVERWRITE_ENV=false

# ---------------------------------------------------------------------------
# Colors
# ---------------------------------------------------------------------------
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; NC='\033[0m'; BOLD='\033[1m'

info()  { echo -e "${BLUE}[INFO]${NC}  $*"; }
ok()    { echo -e "${GREEN}[OK]${NC}    $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
die()   { echo -e "${RED}[ERROR]${NC} $*" >&2; exit 1; }

# Milestone counter — numbered progress steps printed to stdout
_MS=0
milestone() {
    (( _MS++ )) || true
    local ts; ts=$(date +%H:%M:%S)
    echo -e "\n${BOLD}[${ts}] ● STEP ${_MS}: $*${NC}"
}

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------
while [[ $# -gt 0 ]]; do
    case "$1" in
        --non-interactive) NON_INTERACTIVE=true ;;
        --overwrite-env)   OVERWRITE_ENV=true ;;
        --install-dir)     INSTALL_DIR="$2"; SCRIPTS_DIR="${INSTALL_DIR}/scripts"; LOGS_DIR="${INSTALL_DIR}/logs"; shift ;;
        --repo-url)        REPO_URL="$2"; shift ;;
        --branch)          BRANCH="$2"; shift ;;
        *) warn "Unknown flag: $1" ;;
    esac
    shift
done

# ---------------------------------------------------------------------------
# OS detection
# ---------------------------------------------------------------------------
OS_ID=""
PKG_MGR=""
if [[ -f /etc/os-release ]]; then
    OS_ID=$(grep -E '^ID=' /etc/os-release | cut -d= -f2 | tr -d '"')
fi

if command -v dnf &>/dev/null; then
    PKG_MGR="dnf"
elif command -v yum &>/dev/null; then
    PKG_MGR="yum"
elif command -v apt-get &>/dev/null; then
    PKG_MGR="apt-get"
fi

[[ -z "${PKG_MGR}" ]] && warn "Could not detect package manager — manual dependency install may be required"

# ---------------------------------------------------------------------------
# Package installer helper
# ---------------------------------------------------------------------------
_install_pkg() {
    local pkg="$1"
    info "Installing ${pkg} …"
    case "${PKG_MGR}" in
        dnf|yum) "${PKG_MGR}" install -y "${pkg}" >/dev/null || warn "Failed to install ${pkg}" ;;
        apt-get) apt-get install -y "${pkg}" >/dev/null || warn "Failed to install ${pkg}" ;;
        *) warn "Unknown package manager — please install ${pkg} manually" ;;
    esac
}

# ---------------------------------------------------------------------------
# System prerequisites
# ---------------------------------------------------------------------------
info "Checking system prerequisites …"

command -v git &>/dev/null     || _install_pkg git
command -v python3 &>/dev/null || _install_pkg python3
python3 -m pip --version &>/dev/null || _install_pkg python3-pip

# curl — skip on Amazon Linux if curl-minimal is already present
if ! command -v curl &>/dev/null; then
    if [[ "${OS_ID}" == "amzn" ]]; then
        warn "Skipping curl install on Amazon Linux (curl-minimal conflict) — curl must be present"
    else
        _install_pkg curl
    fi
fi

# python3-venv
if ! python3 -m venv --help &>/dev/null 2>&1; then
    case "${PKG_MGR}" in
        dnf|yum) _install_pkg python3-virtualenv ;;
        apt-get) _install_pkg python3-venv ;;
    esac
fi
milestone "System prerequisites verified"

# ---------------------------------------------------------------------------
# Java runtime check (≥ 8)
# ---------------------------------------------------------------------------
milestone "Checking Java runtime …"
if ! command -v java &>/dev/null; then
    warn "Java not found — attempting to install OpenJDK 11 …"
    case "${PKG_MGR}" in
        dnf|yum) _install_pkg java-11-openjdk-headless ;;
        apt-get) _install_pkg openjdk-11-jre-headless ;;
        *) die "Java is required but could not be installed automatically. Install JRE 8+ and re-run." ;;
    esac
fi
JAVA_VER=$(java -version 2>&1 | awk -F '"' '/version/ {print $2}')
info "Java version: ${JAVA_VER}"
milestone "Java runtime verified — ${JAVA_VER}"

# ---------------------------------------------------------------------------
# JT400 JAR (IBM Toolbox for Java)
# ---------------------------------------------------------------------------
milestone "Checking for JT400 JAR …"
JT400_JAR="${JT400_DIR}/jt400.jar"
if [[ ! -f "${JT400_JAR}" ]]; then
    info "JT400 JAR not found at ${JT400_JAR} — downloading from Maven Central …"
    mkdir -p "${JT400_DIR}"
    JT400_VERSION="20.0.7"
    JT400_URL="https://repo1.maven.org/maven2/net/sf/jt400/jt400/${JT400_VERSION}/jt400-${JT400_VERSION}.jar"
    if curl -fsSL -o "${JT400_JAR}" "${JT400_URL}"; then
        ok "JT400 JAR downloaded to ${JT400_JAR}"
    else
        warn "Automatic download failed. Download jt400.jar manually from:"
        warn "  https://repo1.maven.org/maven2/net/sf/jt400/jt400/"
        warn "  or https://sourceforge.net/projects/jt400/files/"
        warn "Then copy it to ${JT400_JAR} before running the connector."
    fi
else
    ok "JT400 JAR already present: ${JT400_JAR}"
fi
milestone "JT400 JAR check complete"

# ---------------------------------------------------------------------------
# IBM i Access ODBC driver notice (informational only — JDBC is used instead)
# ---------------------------------------------------------------------------
info "Note: this connector uses JDBC (jaydebeapi + jt400.jar) — ODBC drivers are NOT required."
milestone "IBM i ODBC driver check complete"

# ---------------------------------------------------------------------------
# Python version check (≥ 3.9)
# ---------------------------------------------------------------------------
PYTHON_VERSION=$(python3 -c 'import sys; print(f"{sys.version_info.major}.{sys.version_info.minor}")')
PYTHON_MAJOR=$(echo "${PYTHON_VERSION}" | cut -d. -f1)
PYTHON_MINOR=$(echo "${PYTHON_VERSION}" | cut -d. -f2)

if [[ "${PYTHON_MAJOR}" -lt 3 ]] || { [[ "${PYTHON_MAJOR}" -eq 3 ]] && [[ "${PYTHON_MINOR}" -lt 9 ]]; }; then
    die "Python 3.9+ required (found ${PYTHON_VERSION})"
fi
ok "Python ${PYTHON_VERSION} detected"
milestone "Python ${PYTHON_VERSION} — version requirement satisfied"

# ---------------------------------------------------------------------------
# Directory layout
# ---------------------------------------------------------------------------
info "Creating install directory: ${INSTALL_DIR}"
mkdir -p "${SCRIPTS_DIR}" "${LOGS_DIR}"
milestone "Install directories created: ${SCRIPTS_DIR}"

# ---------------------------------------------------------------------------
# Repository URL (prompt in interactive mode if not supplied via --repo-url)
# ---------------------------------------------------------------------------
if [[ "${NON_INTERACTIVE}" == "false" ]] && [[ -z "${REPO_URL}" ]]; then
    IFS= read -r -p "Git repository URL: " REPO_URL </dev/tty
    [[ -z "${REPO_URL}" ]] && die "Repository URL is required"
fi
[[ -z "${REPO_URL}" ]] && die "REPO_URL must be set (use --repo-url or the interactive prompt)"

# ---------------------------------------------------------------------------
# Clone and copy integration files
# ---------------------------------------------------------------------------
info "Cloning repository (branch: ${BRANCH}) …"
tmp_dir=$(mktemp -d)
trap 'rm -rf "${tmp_dir}"' EXIT

GIT_TERMINAL_PROMPT=0 git clone --branch "${BRANCH}" --depth 1 --single-branch \
    "${REPO_URL}" "${tmp_dir}" 2>&1 || die "git clone failed — check REPO_URL and network access"

if [[ ! -d "${tmp_dir}/${INTEGRATION_SUBDIR}" ]]; then
    die "Integration directory not found in repo: ${INTEGRATION_SUBDIR}"
fi

cp -f "${tmp_dir}/${INTEGRATION_SUBDIR}"/*.py          "${SCRIPTS_DIR}/" 2>/dev/null || true
cp -f "${tmp_dir}/${INTEGRATION_SUBDIR}/requirements.txt" "${SCRIPTS_DIR}/"
cp -f "${tmp_dir}/${INTEGRATION_SUBDIR}/.env.example"   "${SCRIPTS_DIR}/" 2>/dev/null || true
ok "Integration files installed to ${SCRIPTS_DIR}"
milestone "Repository cloned — integration files installed to ${SCRIPTS_DIR}"

# ---------------------------------------------------------------------------
# Python virtual environment
# ---------------------------------------------------------------------------
info "Creating Python virtual environment …"
python3 -m venv "${SCRIPTS_DIR}/venv"
"${SCRIPTS_DIR}/venv/bin/pip" install --quiet --upgrade pip
"${SCRIPTS_DIR}/venv/bin/pip" install --quiet -r "${SCRIPTS_DIR}/requirements.txt"
ok "Python dependencies installed"
milestone "Python virtual environment ready — all dependencies installed"

# ---------------------------------------------------------------------------
# Gather credentials
# ---------------------------------------------------------------------------
_prompt() {
    local var="$1" prompt="$2" silent="${3:-false}"
    if [[ "${NON_INTERACTIVE}" == "true" ]]; then
        echo "${!var:-}"
        return
    fi
    if [[ "${silent}" == "true" ]]; then
        IFS= read -r -s -p "${prompt}: " value </dev/tty; echo >/dev/tty
    else
        IFS= read -r -p "${prompt}: " value </dev/tty
    fi
    echo "${value}"
}

ENV_FILE="${SCRIPTS_DIR}/.env"
if [[ -f "${ENV_FILE}" ]] && [[ "${OVERWRITE_ENV}" == "false" ]]; then
    warn ".env file already exists at ${ENV_FILE} — skipping credential setup (use --overwrite-env to replace)"
else
    info "Collecting configuration …"

    DB_URL_VAL=$(_prompt "DB_URL" 'IBM i JDBC URL (e.g. jdbc:as400://hostname/PDMSTRDBLB;naming=sql)')
    [[ -z "${DB_URL_VAL}" ]] && die "DB_URL is required"

    DB_USER_VAL=$(_prompt "DB_USER" "IBM i username")
    DB_PASSWORD_VAL=$(_prompt "DB_PASSWORD" "IBM i password" true)

    VEZA_URL_VAL=$(_prompt "VEZA_URL" "Veza tenant URL (e.g. https://your-company.veza.com)")
    VEZA_API_KEY_VAL=$(_prompt "VEZA_API_KEY" "Veza API key" true)

    # Confirm JT400 JAR path
    JT400_JAR_DEFAULT="${JT400_JAR:-/opt/jt400/jt400.jar}"
    if [[ "${NON_INTERACTIVE}" == "false" ]]; then
        IFS= read -r -p "Path to jt400.jar [${JT400_JAR_DEFAULT}]: " _jar_input </dev/tty
        JDBC_JAR_VAL="${_jar_input:-${JT400_JAR_DEFAULT}}"
    else
        JDBC_JAR_VAL="${JDBC_JAR:-${JT400_JAR_DEFAULT}}"
    fi

    cat > "${ENV_FILE}" <<EOF
# Board Sales Invoicing IBM i → Veza OAA Connector — generated by installer
# Generated: $(date -u +"%Y-%m-%dT%H:%M:%SZ")
# Permissions: chmod 600 .env

# IBM i JDBC source
DB_URL=${DB_URL_VAL}
DB_USER=${DB_USER_VAL}
DB_PASSWORD=${DB_PASSWORD_VAL}
JDBC_JAR=${JDBC_JAR_VAL}

# Veza
VEZA_URL=${VEZA_URL_VAL}
VEZA_API_KEY=${VEZA_API_KEY_VAL}

# OAA labels (optional)
# PROVIDER_NAME=Board Sales Invoicing
# DATASOURCE_NAME=${DB_URL_VAL}
EOF
    chmod 600 "${ENV_FILE}"
    ok ".env created at ${ENV_FILE} (permissions: 600)"
    milestone "Credentials saved — .env written to ${ENV_FILE}"
fi

# ---------------------------------------------------------------------------
# Log directory permissions
# ---------------------------------------------------------------------------
chmod 700 "${SCRIPTS_DIR}"
chmod 700 "${LOGS_DIR}" 2>/dev/null || true

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo ""
echo -e "${BOLD}========================================${NC}"
echo -e "${GREEN}Installation complete!${NC}"
echo -e "${BOLD}========================================${NC}"
echo ""
echo -e "  Install path : ${SCRIPTS_DIR}"
echo -e "  Logs         : ${LOGS_DIR}"
echo -e "  .env         : ${ENV_FILE}"
echo -e "  JT400 JAR    : ${JT400_JAR:-/opt/jt400/jt400.jar}"
echo ""
echo -e "${BOLD}Next steps:${NC}"
echo -e "  1. Verify .env credentials:"
echo -e "     cat ${ENV_FILE}"
echo ""
echo -e "  2. Push to Veza:"
echo -e "     cd ${SCRIPTS_DIR}"
echo -e "     ./venv/bin/python3 board-sales-invoicing.py --env-file .env"
echo ""
echo -e "  3. Schedule via cron (run daily at 2 AM):"
echo -e "     echo '0 2 * * * $(whoami) cd ${SCRIPTS_DIR} && ./venv/bin/python3 board-sales-invoicing.py --env-file .env >> ${LOGS_DIR}/cron.log 2>&1' | sudo tee /etc/cron.d/board-sales-invoicing"
echo ""
