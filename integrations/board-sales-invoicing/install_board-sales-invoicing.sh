#!/usr/bin/env bash
# =============================================================================
# install_board-sales-invoicing.sh
# One-command installer for Board Sales Invoicing IBM i → Veza OAA connector
#
# Usage:
#   bash install_board-sales-invoicing.sh
#   bash install_board-sales-invoicing.sh --non-interactive
#   VEZA_URL=https://your-company.veza.com VEZA_API_KEY=tok DB_USER=u DB_PASSWORD=p \
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
REPO_URL="${REPO_URL:-https://github.com/your-org/Board-Sales-Invoicing.git}"
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
# IBM i Access ODBC driver notice
# ---------------------------------------------------------------------------
info "Checking for IBM i Access ODBC driver …"
if command -v odbcinst &>/dev/null; then
    if odbcinst -q -d 2>/dev/null | grep -qi "ibm i access"; then
        ok "IBM i Access ODBC driver detected"
    else
        warn "IBM i Access ODBC driver NOT found in odbcinst — install IBM i Access Client Solutions before running the connector"
        warn "Download: https://www.ibm.com/support/pages/ibm-i-access-client-solutions"
    fi
else
    warn "odbcinst not available — cannot verify IBM i ODBC driver; install unixODBC and IBM i Access Client Solutions"
fi
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
if [[ "${NON_INTERACTIVE}" == "false" ]] && [[ "${REPO_URL}" == *"your-org"* ]]; then
    IFS= read -r -p "Git repository URL [${REPO_URL}]: " _repo_input </dev/tty
    [[ -n "${_repo_input}" ]] && REPO_URL="${_repo_input}"
fi

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

    DB_HOST_VAL=$(_prompt "DB_HOST" "IBM i hostname (e.g. ibmi.example.com)")
    [[ -z "${DB_HOST_VAL}" ]] && die "IBM i hostname is required"

    DB_USER_VAL=$(_prompt "DB_USER" "IBM i username")
    DB_PASSWORD_VAL=$(_prompt "DB_PASSWORD" "IBM i password" true)

    VEZA_URL_VAL=$(_prompt "VEZA_URL" "Veza tenant URL (e.g. https://your-company.veza.com)")
    VEZA_API_KEY_VAL=$(_prompt "VEZA_API_KEY" "Veza API key" true)

    cat > "${ENV_FILE}" <<EOF
# Board Sales Invoicing IBM i → Veza OAA Connector — generated by installer
# Generated: $(date -u +"%Y-%m-%dT%H:%M:%SZ")
# Permissions: chmod 600 .env

# IBM i source
DB_HOST=${DB_HOST_VAL}
DB_USER=${DB_USER_VAL}
DB_PASSWORD=${DB_PASSWORD_VAL}

# Veza
VEZA_URL=${VEZA_URL_VAL}
VEZA_API_KEY=${VEZA_API_KEY_VAL}

# OAA labels (optional)
# PROVIDER_NAME=Board Sales Invoicing
# DATASOURCE_NAME=${DB_HOST_VAL}
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
