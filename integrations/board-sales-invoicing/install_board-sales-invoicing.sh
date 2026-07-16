#!/usr/bin/env bash
# =============================================================================
# install_board-sales-invoicing.sh
# One-command installer for Board Sales Invoicing IBM i -> Veza OAA connector
#
# Usage:
#   bash install_board-sales-invoicing.sh
#   bash install_board-sales-invoicing.sh --non-interactive
#
#   REPO_URL=https://github.com/<org>/Board-Sales-Invoicing.git \
#   DB_URL=jdbc:as400://host/PDMSTRDBLB VEZA_URL=https://host \
#   VEZA_API_KEY=tok DB_USER=u DB_PASSWORD=p JDBC_JAR=/opt/jt400/jt400.jar \
#       bash install_board-sales-invoicing.sh --non-interactive
#
# Flags:
#   --non-interactive   Use environment variables instead of interactive prompts
#   --overwrite-env     Overwrite an existing .env file
#   --install-dir PATH  Custom install root (default: /opt/VEZA/board-sales-invoicing-veza)
#   --repo-url URL      Git repository URL (skips interactive prompt)
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
JDBC_JAR_VAL=""   # resolved during credential collection or to JT400_DIR default

# ---------------------------------------------------------------------------
# Colors & helpers
# ---------------------------------------------------------------------------
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; NC='\033[0m'; BOLD='\033[1m'

info()  { echo -e "${BLUE}[INFO]${NC}  $*"; }
ok()    { echo -e "${GREEN}[OK]${NC}    $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
die()   { echo -e "${RED}[ERROR]${NC} $*" >&2; exit 1; }

# Milestone: numbered, timestamped progress steps printed to stdout
_MS=0
milestone() {
    (( _MS++ )) || true
    local ts; ts=$(date +%H:%M:%S)
    echo -e "\n${BOLD}[${ts}] * STEP ${_MS}: $*${NC}"
}

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------
while [[ $# -gt 0 ]]; do
    case "$1" in
        --non-interactive) NON_INTERACTIVE=true ;;
        --overwrite-env)   OVERWRITE_ENV=true ;;
        --install-dir)     INSTALL_DIR="$2"
                           SCRIPTS_DIR="${INSTALL_DIR}/scripts"
                           LOGS_DIR="${INSTALL_DIR}/logs"
                           shift ;;
        --repo-url)        REPO_URL="$2"; shift ;;
        --branch)          BRANCH="$2";   shift ;;
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
if   command -v dnf    &>/dev/null; then PKG_MGR="dnf"
elif command -v yum    &>/dev/null; then PKG_MGR="yum"
elif command -v apt-get &>/dev/null; then PKG_MGR="apt-get"
fi
[[ -z "${PKG_MGR}" ]] && warn "Could not detect package manager -- manual dependency install may be required"

# ---------------------------------------------------------------------------
# Package installer helper (one package at a time to avoid conflict failures)
# ---------------------------------------------------------------------------
_install_pkg() {
    local pkg="$1"
    info "Installing ${pkg} ..."
    case "${PKG_MGR}" in
        dnf|yum) "${PKG_MGR}" install -y "${pkg}" >/dev/null || warn "Failed to install ${pkg}" ;;
        apt-get) apt-get install -y "${pkg}"       >/dev/null || warn "Failed to install ${pkg}" ;;
        *) warn "Unknown package manager -- install ${pkg} manually" ;;
    esac
}

# ---------------------------------------------------------------------------
# STEP 1 -- System prerequisites
# ---------------------------------------------------------------------------
milestone "Checking system prerequisites"
info "Checking git, python3, pip, curl ..."

command -v git     &>/dev/null || _install_pkg git
command -v python3 &>/dev/null || _install_pkg python3
python3 -m pip --version &>/dev/null || _install_pkg python3-pip

# curl -- skip on Amazon Linux if curl-minimal already present
if ! command -v curl &>/dev/null; then
    if [[ "${OS_ID}" == "amzn" ]]; then
        warn "Skipping curl install on Amazon Linux (curl-minimal conflict)"
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
ok "System prerequisites satisfied"

# ---------------------------------------------------------------------------
# STEP 2 -- Java runtime check
# ---------------------------------------------------------------------------
milestone "Checking Java runtime (required for jaydebeapi/JPype1)"
if ! command -v java &>/dev/null; then
    warn "Java not found -- attempting to install OpenJDK 11 ..."
    case "${PKG_MGR}" in
        dnf|yum) _install_pkg java-11-openjdk-headless ;;
        apt-get) _install_pkg openjdk-11-jre-headless  ;;
        *) die "Java JRE 8+ is required. Install it manually and re-run." ;;
    esac
fi
JAVA_VER=$(java -version 2>&1 | awk -F '"' '/version/ {print $2}')
ok "Java ${JAVA_VER}"

# ---------------------------------------------------------------------------
# STEP 3 -- JT400 JAR (IBM Toolbox for Java)
# ---------------------------------------------------------------------------
milestone "Checking JT400 JAR"
JT400_JAR="${JT400_DIR}/jt400.jar"
if [[ ! -f "${JT400_JAR}" ]]; then
    info "jt400.jar not found at ${JT400_JAR} -- downloading from Maven Central ..."
    mkdir -p "${JT400_DIR}"
    JT400_VERSION="20.0.7"
    JT400_URL="https://repo1.maven.org/maven2/net/sf/jt400/jt400/${JT400_VERSION}/jt400-${JT400_VERSION}.jar"
    if curl -fsSL -o "${JT400_JAR}" "${JT400_URL}"; then
        ok "jt400.jar downloaded to ${JT400_JAR}"
    else
        warn "Automatic download failed. Download jt400.jar manually:"
        warn "  https://repo1.maven.org/maven2/net/sf/jt400/jt400/"
        warn "  or  https://sourceforge.net/projects/jt400/files/"
        warn "Place it at ${JT400_JAR} and re-run, or provide a different path below."
    fi
else
    ok "jt400.jar already present: ${JT400_JAR}"
fi

# ---------------------------------------------------------------------------
# STEP 4 -- Python version check (>= 3.9)
# ---------------------------------------------------------------------------
milestone "Checking Python version"
PYTHON_VERSION=$(python3 -c 'import sys; print(f"{sys.version_info.major}.{sys.version_info.minor}")')
PYTHON_MAJOR=$(echo "${PYTHON_VERSION}" | cut -d. -f1)
PYTHON_MINOR=$(echo "${PYTHON_VERSION}" | cut -d. -f2)
if [[ "${PYTHON_MAJOR}" -lt 3 ]] || { [[ "${PYTHON_MAJOR}" -eq 3 ]] && [[ "${PYTHON_MINOR}" -lt 9 ]]; }; then
    die "Python 3.9+ required (found ${PYTHON_VERSION})"
fi
ok "Python ${PYTHON_VERSION}"

# ---------------------------------------------------------------------------
# STEP 5 -- Repository URL
# ---------------------------------------------------------------------------
milestone "Collecting repository URL"
if [[ -z "${REPO_URL}" ]]; then
    if [[ "${NON_INTERACTIVE}" == "true" ]]; then
        die "REPO_URL must be set in non-interactive mode (--repo-url or REPO_URL env var)"
    fi
    IFS= read -r -p "Git repository URL: " REPO_URL </dev/tty
    [[ -z "${REPO_URL}" ]] && die "Repository URL is required"
fi
ok "Repository: ${REPO_URL}"

# ---------------------------------------------------------------------------
# STEP 6 -- Create directory layout
# ---------------------------------------------------------------------------
milestone "Creating install directories"
info "Install root: ${INSTALL_DIR}"
mkdir -p "${SCRIPTS_DIR}" "${LOGS_DIR}"
ok "Directories created: ${SCRIPTS_DIR}  ${LOGS_DIR}"

# ---------------------------------------------------------------------------
# STEP 7 -- Clone repository and copy integration files
# ---------------------------------------------------------------------------
milestone "Cloning repository and installing files"
info "Cloning branch '${BRANCH}' from ${REPO_URL} ..."
tmp_dir=$(mktemp -d)
trap 'rm -rf "${tmp_dir}"' EXIT

GIT_TERMINAL_PROMPT=0 git clone --branch "${BRANCH}" --depth 1 --single-branch \
    "${REPO_URL}" "${tmp_dir}" 2>&1 \
    || die "git clone failed -- check REPO_URL and network access"

[[ -d "${tmp_dir}/${INTEGRATION_SUBDIR}" ]] \
    || die "Integration directory not found in repo: ${INTEGRATION_SUBDIR}"

cp -f "${tmp_dir}/${INTEGRATION_SUBDIR}"/*.py       "${SCRIPTS_DIR}/" 2>/dev/null || true
cp -f "${tmp_dir}/${INTEGRATION_SUBDIR}/requirements.txt" "${SCRIPTS_DIR}/"
cp -f "${tmp_dir}/${INTEGRATION_SUBDIR}/.env.example"     "${SCRIPTS_DIR}/" 2>/dev/null || true
ok "Files installed to ${SCRIPTS_DIR}"

# Strip Windows CRLF line endings -- ensures shebangs resolve correctly on Linux
# regardless of how the repository was cloned or on what OS it was edited.
info "Normalising line endings (CRLF -> LF) ..."
for f in "${SCRIPTS_DIR}"/*.py "${SCRIPTS_DIR}"/*.sh; do
    [[ -f "${f}" ]] && sed -i 's/\r$//' "${f}"
done
ok "Line endings normalised"

# ---------------------------------------------------------------------------
# STEP 8 -- Python virtual environment
# ---------------------------------------------------------------------------
milestone "Creating Python virtual environment and installing dependencies"
info "Creating venv at ${SCRIPTS_DIR}/venv ..."
python3 -m venv "${SCRIPTS_DIR}/venv"
"${SCRIPTS_DIR}/venv/bin/pip" install --quiet --upgrade pip
"${SCRIPTS_DIR}/venv/bin/pip" install --quiet -r "${SCRIPTS_DIR}/requirements.txt"
ok "Python virtual environment ready"

# ---------------------------------------------------------------------------
# STEP 9 -- Collect credentials and write .env
# ---------------------------------------------------------------------------
milestone "Collecting credentials"

_prompt() {
    local var="$1" prompt="$2" silent="${3:-false}"
    if [[ "${NON_INTERACTIVE}" == "true" ]]; then
        echo "${!var:-}"
        return
    fi
    local value
    if [[ "${silent}" == "true" ]]; then
        IFS= read -r -s -p "${prompt}: " value </dev/tty; echo >/dev/tty
    else
        IFS= read -r -p "${prompt}: " value </dev/tty
    fi
    echo "${value}"
}

ENV_FILE="${SCRIPTS_DIR}/.env"
if [[ -f "${ENV_FILE}" ]] && [[ "${OVERWRITE_ENV}" == "false" ]]; then
    warn ".env already exists at ${ENV_FILE} -- skipping (use --overwrite-env to replace)"
    JDBC_JAR_VAL="${JDBC_JAR:-${JT400_JAR}}"
else
    info "Collecting configuration ..."

    DB_URL_VAL=$(_prompt "DB_URL" 'IBM i JDBC URL (e.g. jdbc:as400://hostname/PDMSTRDBLB;naming=sql)')
    [[ -z "${DB_URL_VAL}" ]] && die "DB_URL is required"

    DB_USER_VAL=$(_prompt "DB_USER" "IBM i username")
    [[ -z "${DB_USER_VAL}" ]] && die "DB_USER is required"

    DB_PASSWORD_VAL=$(_prompt "DB_PASSWORD" "IBM i password" true)
    [[ -z "${DB_PASSWORD_VAL}" ]] && die "DB_PASSWORD is required"

    VEZA_URL_VAL=$(_prompt "VEZA_URL" "Veza tenant URL (e.g. https://your-veza-host)")
    [[ -z "${VEZA_URL_VAL}" ]] && die "VEZA_URL is required"

    VEZA_API_KEY_VAL=$(_prompt "VEZA_API_KEY" "Veza API key" true)
    [[ -z "${VEZA_API_KEY_VAL}" ]] && die "VEZA_API_KEY is required"

    # JT400 JAR path -- default to what was downloaded (or already present)
    JT400_JAR_DEFAULT="${JT400_JAR}"
    if [[ "${NON_INTERACTIVE}" == "false" ]]; then
        IFS= read -r -p "Path to jt400.jar [${JT400_JAR_DEFAULT}]: " _jar </dev/tty
        JDBC_JAR_VAL="${_jar:-${JT400_JAR_DEFAULT}}"
    else
        JDBC_JAR_VAL="${JDBC_JAR:-${JT400_JAR_DEFAULT}}"
    fi

    cat > "${ENV_FILE}" <<EOF
# Board Sales Invoicing IBM i -> Veza OAA Connector
# Generated: $(date -u +"%Y-%m-%dT%H:%M:%SZ")
# chmod 600 .env

# IBM i JDBC source
DB_URL=${DB_URL_VAL}
DB_USER=${DB_USER_VAL}
DB_PASSWORD=${DB_PASSWORD_VAL}
JDBC_JAR=${JDBC_JAR_VAL}

# Veza
VEZA_URL=${VEZA_URL_VAL}
VEZA_API_KEY=${VEZA_API_KEY_VAL}

# OAA labels (optional overrides)
# PROVIDER_NAME=Board Sales Invoicing
# DATASOURCE_NAME=board-sales-invoicing
EOF
    chmod 600 "${ENV_FILE}"
    ok ".env written to ${ENV_FILE} (permissions: 600)"
fi

# ---------------------------------------------------------------------------
# STEP 10 -- Finalise permissions
# ---------------------------------------------------------------------------
milestone "Finalising directory permissions"
chmod 700 "${SCRIPTS_DIR}"
chmod 700 "${LOGS_DIR}" 2>/dev/null || true
ok "Permissions set"

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
milestone "Installation complete"
echo ""
echo -e "${BOLD}======================================${NC}"
echo -e "${GREEN}Installation complete!${NC}"
echo -e "${BOLD}======================================${NC}"
echo ""
echo -e "  Install path : ${SCRIPTS_DIR}"
echo -e "  Logs         : ${LOGS_DIR}"
echo -e "  .env         : ${ENV_FILE}"
echo -e "  JT400 JAR    : ${JDBC_JAR_VAL:-${JT400_JAR}}"
echo ""
echo -e "${BOLD}Next steps:${NC}"
echo -e "  1. Verify .env credentials:"
echo -e "     cat ${ENV_FILE}"
echo ""
echo -e "  2. Run the connector:"
echo -e "     cd ${SCRIPTS_DIR}"
echo -e "     ./venv/bin/python3 board-sales-invoicing.py --env-file .env"
echo ""
echo -e "  3. Schedule via cron (daily at 2 AM):"
echo -e "     echo '0 2 * * * $(whoami) cd ${SCRIPTS_DIR} && ./venv/bin/python3 board-sales-invoicing.py --env-file .env >> ${LOGS_DIR}/cron.log 2>&1' | sudo tee /etc/cron.d/board-sales-invoicing"
echo ""
