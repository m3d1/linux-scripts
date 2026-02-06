
#!/usr/bin/env bash
# Canonical MAAS (3.6) + PostgreSQL (same host) automated install
# - Installs snapd if missing
# - Installs PostgreSQL 16 (MAAS 3.6 requirement) or fallback meta 'postgresql'
# - Creates local DB/user with strong random password
# - Initializes MAAS region+rack with --database-uri
# - Creates MAAS admin (either user-provided or strong random)
# - Writes credentials to /home/<currentuser>/maas/maas.creds (chmod 600)
#
# - Autor : Mehdi BASRI (m3d1)
# - Email : basri.mehdi@thinkit-maroc.com
# - bash -c "$(curl -fsSL # bash -c "$(curl -fsSL https://github.com/m3d1/linux-scripts/blob/main/Maas/install/maas-install.sh)")"


set -euo pipefail

########################
# Helper: print header #
########################
header() { echo -e "\n==== $* ====\n"; }

#####################################
# Require root/sudo to run this file #
#####################################
if [[ $EUID -ne 0 ]]; then
  echo "Please run as root (sudo)."
  exit 1
fi

##############################
# Determine current SUDO user #
##############################
CURRENT_USER="${SUDO_USER:-$(id -un)}"
TARGET_HOME=$(eval echo "~${CURRENT_USER}")
CREDS_DIR="${TARGET_HOME}/maas"
CREDS_FILE="${CREDS_DIR}/maas.creds"
MAAS_VERSION="3.6"
MAAS_CHANNEL="${MAAS_VERSION}/stable"

#####################################
# Prompt: DB/MAAS admin information #
#####################################
read -r -p "Database username [maasuser]: " DB_USER_INPUT
DB_USER="${DB_USER_INPUT:-maasuser}"

read -r -p "Database name [maasdb]: " DB_NAME_INPUT
DB_NAME="${DB_NAME_INPUT:-maasdb}"

# Strong random DB password (base64 32 chars)
DB_PASS="$(openssl rand -base64 32)"

read -r -p "MAAS admin username [admin]: " MAAS_ADMIN_INPUT
MAAS_ADMIN="${MAAS_ADMIN_INPUT:-admin}"

# Ask if user wants to set admin password manually
read -r -p "Do you want to set a custom MAAS admin password? [y/N]: " SET_ADMIN_PASS_CHOICE
if [[ "${SET_ADMIN_PASS_CHOICE,,}" == "y" ]]; then
  # Read password twice (silent) and match
  while true; do
    read -rs -p "Enter MAAS admin password: " MAAS_ADMIN_PASS_1; echo
    read -rs -p "Confirm MAAS admin password: " MAAS_ADMIN_PASS_2; echo
    if [[ "$MAAS_ADMIN_PASS_1" == "$MAAS_ADMIN_PASS_2" && -n "$MAAS_ADMIN_PASS_1" ]]; then
      MAAS_ADMIN_PASS="$MAAS_ADMIN_PASS_1"
      break
    else
      echo "Passwords do not match or empty. Try again."
    fi
  done
else
  MAAS_ADMIN_PASS="$(openssl rand -base64 32)"
fi

# Email for admin account (required by createadmin)
read -r -p "MAAS admin email address: " MAAS_ADMIN_EMAIL
if [[ -z "${MAAS_ADMIN_EMAIL}" ]]; then
  echo "Email address is required for the MAAS admin."
  exit 1
fi

############################################
# Ensure snapd is installed and available  #
############################################
if ! command -v snap >/dev/null 2>&1; then
  header "Installing snapd"
  apt-get update
  apt-get install -y snapd
  systemctl enable --now snapd.socket
fi

#############################################
# Install PostgreSQL (version tied to MAAS) #
#############################################
header "Installing PostgreSQL for MAAS ${MAAS_VERSION}"

apt-get update

# For MAAS 3.6 we target PostgreSQL 16 (Jammy/Noble defaults to 16)
# Try explicit package, fallback to meta 'postgresql'
if apt-cache show postgresql-16 >/dev/null 2>&1; then
  apt-get install -y postgresql-16
else
  apt-get install -y postgresql
fi

# Figure out PG major (e.g., 16, 14) to edit correct path
PG_MAJOR="$(psql -V | awk '{print $3}' | cut -d. -f1)"
PG_CONF_DIR="/etc/postgresql/${PG_MAJOR}/main"
PG_HBA="${PG_CONF_DIR}/pg_hba.conf"
PG_CONF="${PG_CONF_DIR}/postgresql.conf"

##########################################
# Create DB/user with strong random pass #
##########################################
header "Creating database '${DB_NAME}' and user '${DB_USER}'"
# Escape single quotes in password for psql
DB_PASS_SQL="${DB_PASS//\'/\'\'}"

sudo service postgresql restart

sudo -E -u postgres bash -c "psql -X -p 5432 -c \"CREATE ROLE ${DB_USER} LOGIN PASSWORD '$DB_PASS';\""

sudo -E -u postgres bash -c "psql -X -p 5432 -c \"CREATE DATABASE ${DB_NAME} OWNER ${DB_USER};\""


###########################################################
# Harden local DB access (localhost only, md5) + restart  #
###########################################################
header "Hardening PostgreSQL local access"
# Ensure listen_addresses='localhost'
sed -i "s/^[#]*\s*listen_addresses\s*=\s*.*/listen_addresses = 'localhost'/g" "${PG_CONF}"

# Add/ensure pg_hba line for local IPv4
if ! grep -qE "^host\s+${DB_NAME}\s+${DB_USER}\s+127\.0\.0\.1/32\s+md5" "${PG_HBA}"; then
  echo "host    ${DB_NAME}    ${DB_USER}    127.0.0.1/32    md5" >> "${PG_HBA}"
fi

systemctl restart postgresql

#####################################
# URL-encode DB password for URI    #
#####################################
urlencode() {
  # Requires python3 (default on Ubuntu 24.04)
  python3 - <<'PY' "$1"
import sys, urllib.parse
print(urllib.parse.quote(sys.argv[1], safe=''))
PY
}
DB_PASS_ENC="$(urlencode "${DB_PASS}")"

###########################################
# Install MAAS snap and initialize (DB URI)
###########################################
header "Installing MAAS ${MAAS_VERSION} (snap channel: ${MAAS_CHANNEL})"
snap install --channel="${MAAS_CHANNEL}" maas

FQDN="$(hostname -f 2>/dev/null || hostname)"
MAAS_URL="http://${FQDN}:5240/MAAS"

header "Initializing MAAS region+rack with PostgreSQL (local)"
# Per Canonical docs, use --database-uri to wire Postgres during init.
maas init region+rack \
  --database-uri "postgres://${DB_USER}:${DB_PASS_ENC}@localhost/${DB_NAME}" \
  --maas-url "${MAAS_URL}"

##########################################
# Create MAAS admin non-interactively    #
##########################################
header "Creating MAAS admin account"
maas createadmin \
  --username "${MAAS_ADMIN}" \
  --password "${MAAS_ADMIN_PASS}" \
  --email    "${MAAS_ADMIN_EMAIL}"

##########################################
# Persist credentials (chmod 600)        #
##########################################
header "Saving credentials to ${CREDS_FILE}"
mkdir -p "${CREDS_DIR}"
cat > "${CREDS_FILE}" <<EOF
# MAAS install credentials (generated by install_maas.sh)
MAAS_VERSION=${MAAS_VERSION}
MAAS_CHANNEL=${MAAS_CHANNEL}
MAAS_URL=${MAAS_URL}

DB_USER=${DB_USER}
DB_NAME=${DB_NAME}
DB_PASS=${DB_PASS}

MAAS_ADMIN=${MAAS_ADMIN}
MAAS_ADMIN_PASS=${MAAS_ADMIN_PASS}
MAAS_ADMIN_EMAIL=${MAAS_ADMIN_EMAIL}
EOF
chown "${CURRENT_USER}:${CURRENT_USER}" "${CREDS_FILE}"
chmod 600 "${CREDS_FILE}"

##########################################
# Final checks and hints                 #
##########################################
header "MAAS installation complete"
echo "Web UI: ${MAAS_URL}"
echo "Admin:  ${MAAS_ADMIN}"
echo "Creds:  ${CREDS_FILE}"
echo
echo "Next steps:"
echo "  - Log in to the Web UI and importecho  - Log in to the Web UI and import at least one Ubuntu image."
echo "  - Configure upstream DNS, DHCP (if MAAS is authoritative), and fabrics."
