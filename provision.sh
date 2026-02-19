#!/usr/bin/env bash
set -euo pipefail

# ============================================================
# iDempiere Provision Script
# hecho por Josian
# ============================================================

# -----------------------------
# Root check
# -----------------------------
if [[ "${EUID}" -ne 0 ]]; then
  echo "Este script debe ejecutarse como root. Usa: sudo bash $0"
  exit 1
fi

# -----------------------------
# Ensure whiptail exists
# -----------------------------
if ! command -v whiptail >/dev/null 2>&1; then
  echo "Instalando dependencias mínimas..."
  apt update -qq
  apt install -y whiptail
fi

# -----------------------------
# Whiptail helpers
# -----------------------------
abort_if_cancel() {
  local code="$1"
  if [[ "$code" -ne 0 ]]; then
    echo "Cancelado por el usuario."
    exit 0
  fi
}

w_input() {
  local title="$1"
  local prompt="$2"
  local default="$3"
  local height="${4:-10}"
  local width="${5:-75}"

  local result
  result=$(whiptail --title "$title" --inputbox "$prompt" "$height" "$width" "$default" 3>&1 1>&2 2>&3)
  abort_if_cancel $?
  echo "$result"
}

w_msg() {
  local title="$1"
  local msg="$2"
  whiptail --title "$title" --msgbox "$msg" 22 90
  abort_if_cancel $?
}

w_checklist() {
  local title="$1"
  local text="$2"
  shift 2

  local result
  result=$(whiptail --title "$title" --checklist "$text" 18 90 8 "$@" 3>&1 1>&2 2>&3)
  abort_if_cancel $?
  echo "$result"
}

# ============================================================
# 1) Parámetros + resumen + editar
# ============================================================
ENTORNO_DEFAULT="idempiere"
PUERTO_DEFAULT="80"
FOLDER_DEFAULT="sas"
DB_SERVER_DEFAULT="localhost"
DB_PASS_DEFAULT="adempiere"

while true; do
  ENTORNO="$(w_input "Parámetros iDempiere" "ENTORNO (ej: idempiere, test, prod):" "$ENTORNO_DEFAULT")"
  PUERTO="$(w_input "Parámetros iDempiere" "PUERTO base (ej: 80, 81, 82). Se usa para WEB_PORT=80\$PUERTO:" "$PUERTO_DEFAULT")"
  FOLDER="$(w_input "Parámetros iDempiere" "FOLDER (carpeta base en /opt, ej: sas):" "$FOLDER_DEFAULT")"
  DB_SERVER="$(w_input "Parámetros iDempiere" "DB_SERVER (host Postgres, ej: localhost):" "$DB_SERVER_DEFAULT")"
  DB_PASS="$(w_input "Parámetros iDempiere" "DB_PASS (clave del usuario adempiere):" "$DB_PASS_DEFAULT")"

  ENTORNO="${ENTORNO:-$ENTORNO_DEFAULT}"
  PUERTO="${PUERTO:-$PUERTO_DEFAULT}"
  FOLDER="${FOLDER:-$FOLDER_DEFAULT}"
  DB_SERVER="${DB_SERVER:-$DB_SERVER_DEFAULT}"
  DB_PASS="${DB_PASS:-$DB_PASS_DEFAULT}"

  if ! [[ "$PUERTO" =~ ^[0-9]+$ ]]; then
    w_msg "Error" "PUERTO debe ser numérico."
    continue
  fi

  SUMMARY="Se usarán estos valores:

ENTORNO:    $ENTORNO
PUERTO:     $PUERTO
FOLDER:     $FOLDER
DB_SERVER:  $DB_SERVER
DB_PASS:    $DB_PASS
"
  w_msg "Resumen" "$SUMMARY"

  ACTION=$(whiptail --title "Acción" --menu "Selecciona una opción:" 14 60 3 \
    "1" "Continuar" \
    "2" "Editar parámetros" \
    "3" "Cancelar" \
    3>&1 1>&2 2>&3)
  abort_if_cancel $?

  case "$ACTION" in
    1) break ;;
    2) continue ;;
    3) echo "Cancelado por el usuario."; exit 0 ;;
  esac
done

# ============================================================
# 2) Dependencias (UI)
# ============================================================
DEPS="$(w_checklist "Dependencias" "Selecciona qué quieres instalar/asegurar en este servidor:" \
  "repo_pg" "Agregar repo oficial PostgreSQL (apt.postgresql.org)" ON \
  "base"    "git, expect, fontconfig" ON \
  "java17"  "OpenJDK 17 headless" ON \
  "pg15"    "PostgreSQL 15" ON \
  "nginx"   "Nginx" ON \
  "skip"    "NO instalar nada (solo continuar)" OFF
)"

INSTALL_ANY="yes"
if [[ "$DEPS" == *"skip"* ]]; then
  INSTALL_ANY="no"
fi

# ============================================================
# 3) Instalación en consola (para no romper ENTER en Import)
# ============================================================
clear

export IDEMPIERE_HOME="/opt/${FOLDER}/${PUERTO}_${ENTORNO}"
export ENTORNO PUERTO FOLDER DB_SERVER DB_PASS

echo "Iniciando instalación..."

step() { echo -e "\n===== $* =====\n"; }

if [[ "$INSTALL_ANY" == "yes" ]]; then
  if [[ "$DEPS" == *"repo_pg"* ]]; then
    step "Agregando repo PostgreSQL"
    wget -q -O /usr/share/keyrings/postgresql-keyring.asc https://www.postgresql.org/media/keys/ACCC4CF8.asc
    echo "deb [signed-by=/usr/share/keyrings/postgresql-keyring.asc] https://apt.postgresql.org/pub/repos/apt $(lsb_release -cs)-pgdg main" \
      > /etc/apt/sources.list.d/postgresql.list
  fi

  step "APT update"
  apt update -y

  if [[ "$DEPS" == *"base"* ]]; then
    step "Instalando base (git/expect/fontconfig)"
    apt install -y git expect fontconfig
  fi

  if [[ "$DEPS" == *"java17"* ]]; then
    step "Instalando Java 17"
    apt install -y openjdk-17-jdk-headless
  fi

  if [[ "$DEPS" == *"pg15"* ]]; then
    step "Instalando PostgreSQL 15"
    apt install -y postgresql-15
  fi

  if [[ "$DEPS" == *"nginx"* ]]; then
    step "Instalando Nginx"
    apt install -y nginx
  fi
else
  step "Saltando instalación de dependencias"
fi

# Config Postgres si existe
if [[ -d "/etc/postgresql/15/main" ]]; then
  step "Configurando PostgreSQL (pg_hba.conf)"
  cat << 'EOF' > /etc/postgresql/15/main/pg_hba.conf
local   all             postgres                                peer
local   all             all                                     md5
host    all             all             127.0.0.1/32            md5
host    all             all             ::1/128                 md5
EOF

  step "Asignando clave a postgres"
  sudo -u postgres psql -U postgres -c "alter user postgres password 'postgres';" || true

  step "Reiniciando PostgreSQL"
  systemctl enable postgresql || true
  systemctl restart postgresql || true
fi

# Install iDempiere
step "Creando directorio $IDEMPIERE_HOME"
mkdir -p "$IDEMPIERE_HOME"

step "Descargando build.zip (si no existe)"
if [[ ! -f "build.zip" ]]; then
  wget --progress=bar:force:noscroll -O build.zip \
    "https://sourceforge.net/projects/idempiere/files/v12/daily-server/idempiereServer12Daily.gtk.linux.x86_64.zip"
fi

step "Extrayendo build.zip"
jar xvf build.zip

step "Moviendo iDempiere a $IDEMPIERE_HOME"
mkdir -p "/opt/$FOLDER"
mv idempiere.gtk.linux.x86_64/idempiere-server "/opt/$FOLDER" || true
mv "/opt/$FOLDER/idempiere-server/"* "$IDEMPIERE_HOME"
rm -rf idempiere.gtk.linux.x86_64

step "Creando idempiereEnv.properties"
cat << EOF > "$IDEMPIERE_HOME/idempiereEnv.properties"
#idempiereEnv.properties Template

#idempiere home
IDEMPIERE_HOME=$IDEMPIERE_HOME
#Java home
JAVA_HOME=/usr/lib/jvm/java-17-openjdk-amd64

#Java runtime options
IDEMPIERE_JAVA_OPTIONS=-Xms1G -Xmx1G

#Type of database, postgresql|oracle|oracleXE
ADEMPIERE_DB_TYPE=PostgreSQL
ADEMPIERE_DB_EXISTS=N
#Path to database specific sql scripts: postgresql|oracle|oracleXE
ADEMPIERE_DB_PATH=postgresql
#Database server host name
ADEMPIERE_DB_SERVER=$DB_SERVER
#Database port, oracle[1512], postgresql[5432]
ADEMPIERE_DB_PORT=5432
#Database name
ADEMPIERE_DB_NAME=${PUERTO}_${ENTORNO}
#Database system user password
ADEMPIERE_DB_SYSTEM=postgres
#Database user name
ADEMPIERE_DB_USER=adempiere
#Database user password
ADEMPIERE_DB_PASSWORD=$DB_PASS

#Application server host name
ADEMPIERE_APPS_SERVER=0.0.0.0
ADEMPIERE_WEB_ALIAS=localhost
#Application server port
ADEMPIERE_WEB_PORT=80$PUERTO
ADEMPIERE_SSL_PORT=84$PUERTO

#Keystore setting
ADEMPIERE_KEYSTORE=$IDEMPIERE_HOME/keystore/myKeystore
ADEMPIERE_KEYSTOREWEBALIAS=adempiere
ADEMPIERE_KEYSTORECODEALIAS=adempiere
ADEMPIERE_KEYSTOREPASS=myPassword

#Certificate details
#Common name, default to host name
ADEMPIERE_CERT_CN=localhost
#Organization, default to the user name
ADEMPIERE_CERT_ORG=iDempiere Bazaar
#Organization Unit, default to 'AdempiereUser'
ADEMPIERE_CERT_ORG_UNIT=iDempiereUser
#town
ADEMPIERE_CERT_LOCATION=myTown
#state
ADEMPIERE_CERT_STATE=CA
#2 character country code
ADEMPIERE_CERT_COUNTRY=US

#Mail server setting
ADEMPIERE_MAIL_SERVER=localhost
ADEMPIERE_ADMIN_EMAIL=
ADEMPIERE_MAIL_USER=
ADEMPIERE_MAIL_PASSWORD=

#ftp server setting
ADEMPIERE_FTP_SERVER=localhost
ADEMPIERE_FTP_PREFIX=my
ADEMPIERE_FTP_USER=anonymous
ADEMPIERE_FTP_PASSWORD=user@host.com
EOF


step "Ejecutando silent-setup-alt.sh"
cd "$IDEMPIERE_HOME"
sh silent-setup-alt.sh

step "Importando base (RUN_ImportIdempiere.sh)"
cd "$IDEMPIERE_HOME"
bash utils/RUN_ImportIdempiere.sh

step "Sync DB (RUN_SyncDB.sh)"
cd "$IDEMPIERE_HOME/utils"
sh RUN_SyncDB.sh

step "Firmando base (sign-database-build-alt.sh)"
cd "$IDEMPIERE_HOME"
sh sign-database-build-alt.sh

# Usuario + servicio
step "Creando usuario idempiere (si no existe)"
if ! id idempiere >/dev/null 2>&1; then
  useradd -d "$IDEMPIERE_HOME" -s /bin/bash idempiere
fi

step "Creando SSH key (si no existe)"
if [[ ! -f "$IDEMPIERE_HOME/.ssh/idempiere" ]]; then
  mkdir -p "$IDEMPIERE_HOME/.ssh"
  ssh-keygen -t ed25519 -f "$IDEMPIERE_HOME/.ssh/idempiere" -N ''
  cp "$IDEMPIERE_HOME/.ssh/idempiere.pub" "$IDEMPIERE_HOME/.ssh/authorized_keys"
  chmod 700 "$IDEMPIERE_HOME/.ssh"
  chmod 600 "$IDEMPIERE_HOME/.ssh/idempiere"
  chmod 644 "$IDEMPIERE_HOME/.ssh/idempiere.pub"
  chmod 644 "$IDEMPIERE_HOME/.ssh/authorized_keys"
fi

chown -R idempiere:idempiere "$IDEMPIERE_HOME"

SERVICIO="${PUERTO}_${ENTORNO}"
step "Creando servicio: $SERVICIO"
cp "$IDEMPIERE_HOME/utils/unix/idempiere_Debian.sh" "/etc/init.d/$SERVICIO"

archivo="/etc/init.d/$SERVICIO"
sed "s|/opt/idempiere-server|$IDEMPIERE_HOME|g; s|TELNET_PORT=12612|TELNET_PORT=126$PUERTO|g" \
  "$archivo" > "$archivo.tmp"
mv "$archivo.tmp" "$archivo"
chmod 755 "$archivo"

systemctl daemon-reload
systemctl enable "$SERVICIO"
systemctl restart "$SERVICIO"

w_msg "Finalizado" "Servicio: $SERVICIO\nHome: $IDEMPIERE_HOME"
