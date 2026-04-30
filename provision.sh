#!/usr/bin/env bash
set -Eeuo pipefail

# ============================================================
# iDempiere Provision Script - Debian 13 + Oracle Remoto
#  cancelación controlada + selección manual oracle/oracleXE
#  Hecho por Carl0gonzalez
# ============================================================

INSTALL_CANCELLED="no"
CURRENT_STEP="inicio"
CREATED_SERVICE=""
CREATED_IDEMPIERE_HOME=""
TMP_FILES=()

cleanup() {
  local exit_code=$?

  for f in "${TMP_FILES[@]:-}"; do
    [[ -n "${f:-}" && -e "$f" ]] && rm -f "$f" || true
  done

  if [[ "$INSTALL_CANCELLED" == "yes" ]]; then
    echo
    echo "============================================================"
    echo " Instalación cancelada por el usuario."
    echo " Último paso: ${CURRENT_STEP}"
    echo " NOTA: no se hace rollback automático de cambios ya aplicados."
    echo "============================================================"
    echo
  fi

  exit "$exit_code"
}

cancel_install() {
  INSTALL_CANCELLED="yes"
  echo
  echo "Se recibió una señal de cancelación. Saliendo de forma controlada..."
  exit 130
}

trap cleanup EXIT
trap cancel_install INT TERM

if [[ "${EUID}" -ne 0 ]]; then
  echo "Este script debe ejecutarse como root. Usa: sudo bash $0"
  exit 1
fi

if ! command -v whiptail >/dev/null 2>&1; then
  echo "Instalando dependencias mínimas..."
  apt update -qq
  apt install -y whiptail
fi

abort_if_cancel() {
  local code="$1"
  if [[ "$code" -ne 0 ]]; then
    INSTALL_CANCELLED="yes"
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

w_password() {
  local title="$1"
  local prompt="$2"
  local height="${3:-10}"
  local width="${4:-75}"
  local result
  result=$(whiptail --title "$title" --passwordbox "$prompt" "$height" "$width" 3>&1 1>&2 2>&3)
  abort_if_cancel $?
  echo "$result"
}

w_yesno() {
  local title="$1"
  local prompt="$2"
  local height="${3:-10}"
  local width="${4:-75}"
  if whiptail --title "$title" --yesno "$prompt" "$height" "$width"; then
    echo "Y"
  else
    echo "N"
  fi
}

w_menu() {
  local title="$1"
  local prompt="$2"
  shift 2
  local result
  result=$(whiptail --title "$title" --menu "$prompt" 18 85 8 "$@" 3>&1 1>&2 2>&3)
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

confirm_checkpoint() {
  local title="$1"
  local prompt="$2"
  if ! whiptail --title "$title" --yesno "$prompt" 12 80; then
    INSTALL_CANCELLED="yes"
    echo "Cancelado por el usuario."
    exit 0
  fi
}

step() {
  CURRENT_STEP="$*"
  echo -e "\n===== $* =====\n"
}

ensure_adoptium_repo() {
  if [[ ! -f /etc/apt/sources.list.d/adoptium.list ]]; then
    step "Agregando repo Adoptium"
    apt install -y wget apt-transport-https gpg
    wget -qO - https://packages.adoptium.net/artifactory/api/gpg/key/public \
      | gpg --dearmor \
      | tee /etc/apt/trusted.gpg.d/adoptium.gpg >/dev/null
    echo "deb https://packages.adoptium.net/artifactory/deb $(awk -F= '/^VERSION_CODENAME/{print$2}' /etc/os-release) main" \
      > /etc/apt/sources.list.d/adoptium.list
  fi
}

detect_java_home() {
  local java_bin
  java_bin="$(readlink -f "$(command -v java)")"
  dirname "$(dirname "$java_bin")"
}

require_cmd() {
  local cmd="$1"
  local msg="$2"
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "ERROR: falta el comando '$cmd'. $msg"
    exit 1
  fi
}

oracle_connect_string() {
  local user="$1"
  local pass="$2"
  echo "${user}/${pass}@//${DB_SERVER}:${DB_PORT}/${DB_SERVICE}"
}

oracle_sql() {
  local conn="$1"
  local sql="$2"
  sqlplus -s "$conn" <<SQL
set heading off
set feedback off
set verify off
set pagesize 0
set linesize 300
set trimspool on
whenever sqlerror exit failure
${sql}
exit
SQL
}

oracle_test_connection() {
  local conn
  conn="$(oracle_connect_string "$ORACLE_ADMIN_USER" "$ORACLE_ADMIN_PASSWORD")"
  local out
  out="$(oracle_sql "$conn" "select 'OK' from dual;")"
  echo "$out" | grep -q "OK"
}

oracle_verify_tablespace() {
  local conn
  conn="$(oracle_connect_string "$ORACLE_ADMIN_USER" "$ORACLE_ADMIN_PASSWORD")"

  local count_data
  count_data="$(oracle_sql "$conn" "select count(*) from dba_tablespaces where tablespace_name = upper('${ORACLE_TABLESPACE}');" | tr -d '[:space:]')"
  if [[ "$count_data" != "1" ]]; then
    echo "ERROR: el tablespace de datos '${ORACLE_TABLESPACE}' no existe en el Oracle remoto."
    exit 1
  fi

  local count_temp
  count_temp="$(oracle_sql "$conn" "select count(*) from dba_tablespaces where tablespace_name = upper('${ORACLE_TEMP_TABLESPACE}');" | tr -d '[:space:]')"
  if [[ "$count_temp" != "1" ]]; then
    echo "ERROR: el temporary tablespace '${ORACLE_TEMP_TABLESPACE}' no existe en el Oracle remoto."
    exit 1
  fi
}

oracle_prepare_app_user() {
  local conn
  conn="$(oracle_connect_string "$ORACLE_ADMIN_USER" "$ORACLE_ADMIN_PASSWORD")"

  if [[ "${CREATE_APP_USER}" != "Y" ]]; then
    step "Saltando creación/ajuste del usuario Oracle de aplicación"
    return
  fi

  step "Creando o ajustando usuario Oracle ${ORACLE_APP_USER}"
  sqlplus -s "$conn" <<SQL
set heading off
set feedback off
set verify off
set pagesize 0
set linesize 300
whenever sqlerror exit failure

declare
  v_count number := 0;
begin
  select count(*) into v_count
  from dba_users
  where username = upper('${ORACLE_APP_USER}');

  if v_count = 0 then
    execute immediate 'create user ${ORACLE_APP_USER} identified by "${ORACLE_APP_PASSWORD}" default tablespace ${ORACLE_TABLESPACE} temporary tablespace ${ORACLE_TEMP_TABLESPACE} quota unlimited on ${ORACLE_TABLESPACE}';
    execute immediate 'grant connect, resource, create view, create sequence, create materialized view to ${ORACLE_APP_USER}';
  else
    execute immediate 'alter user ${ORACLE_APP_USER} identified by "${ORACLE_APP_PASSWORD}"';
    execute immediate 'alter user ${ORACLE_APP_USER} default tablespace ${ORACLE_TABLESPACE} temporary tablespace ${ORACLE_TEMP_TABLESPACE}';
    execute immediate 'alter user ${ORACLE_APP_USER} quota unlimited on ${ORACLE_TABLESPACE}';
    execute immediate 'grant connect, resource, create view, create sequence, create materialized view to ${ORACLE_APP_USER}';
  end if;
end;
/
exit
SQL
}

# ============================================================
# 1) Parámetros
# ============================================================
ENTORNO_DEFAULT="idempiere"
PUERTO_DEFAULT="80"
FOLDER_DEFAULT="sas"

DB_SERVER_DEFAULT=""
DB_PORT_DEFAULT="1521"
DB_SERVICE_DEFAULT=""
ORACLE_ADMIN_USER_DEFAULT="system"
ORACLE_APP_USER_DEFAULT="adempiere"
ORACLE_TABLESPACE_DEFAULT=""
ORACLE_TEMP_TABLESPACE_DEFAULT="TEMP"

while true; do
  ENTORNO="$(w_input "Parámetros iDempiere" "ENTORNO (ej: idempiere, test, prod):" "$ENTORNO_DEFAULT")"
  PUERTO="$(w_input "Parámetros iDempiere" "PUERTO base (ej: 80, 81, 82). Se usa para WEB_PORT=80\$PUERTO:" "$PUERTO_DEFAULT")"
  FOLDER="$(w_input "Parámetros iDempiere" "FOLDER (carpeta base en /opt, ej: sas):" "$FOLDER_DEFAULT")"

  ORACLE_DB_TYPE="$(w_menu "Tipo de base de datos" "Selecciona el tipo de Oracle REMOTO para iDempiere:" \
    "oracle"   "Oracle estándar / Enterprise / Standard / PDB" \
    "oracleXE" "Oracle Express Edition (XE)"
  )"

  DB_SERVER="$(w_input "Oracle remoto" "DB_SERVER (host o IP del servidor Oracle remoto):" "$DB_SERVER_DEFAULT")"
  DB_PORT="$(w_input "Oracle remoto" "DB_PORT del listener Oracle remoto:" "$DB_PORT_DEFAULT")"
  DB_SERVICE="$(w_input "Oracle remoto" "DB_SERVICE / Service Name / PDB del Oracle remoto (ej: xepdb1):" "$DB_SERVICE_DEFAULT")"

  ORACLE_ADMIN_USER="$(w_input "Oracle remoto" "Usuario administrador Oracle remoto (ej: system):" "$ORACLE_ADMIN_USER_DEFAULT")"
  ORACLE_ADMIN_PASSWORD="$(w_password "Oracle remoto" "Password del usuario administrador Oracle remoto:")"

  ORACLE_APP_USER="$(w_input "Oracle remoto" "Usuario de aplicación iDempiere a crear/usar en Oracle remoto:" "$ORACLE_APP_USER_DEFAULT")"
  ORACLE_APP_PASSWORD="$(w_password "Oracle remoto" "Password del usuario de aplicación ${ORACLE_APP_USER}:")"

  ORACLE_TABLESPACE="$(w_input "Oracle remoto" "Tablespace de datos para iDempiere en Oracle remoto:" "$ORACLE_TABLESPACE_DEFAULT")"
  ORACLE_TEMP_TABLESPACE="$(w_input "Oracle remoto" "Temporary tablespace para iDempiere en Oracle remoto:" "$ORACLE_TEMP_TABLESPACE_DEFAULT")"

  CREATE_APP_USER="$(w_yesno "Oracle remoto" "¿Crear o ajustar el usuario Oracle de aplicación (${ORACLE_APP_USER}) en el Oracle remoto con el admin indicado?")"
  DB_EXISTS="$(w_yesno "Base de datos" "¿El esquema/base de iDempiere ya existe en Oracle remoto? Responde NO si se va a importar seed nueva.")"

  ENTORNO="${ENTORNO:-$ENTORNO_DEFAULT}"
  PUERTO="${PUERTO:-$PUERTO_DEFAULT}"
  FOLDER="${FOLDER:-$FOLDER_DEFAULT}"

  if ! [[ "$PUERTO" =~ ^[0-9]+$ ]]; then
    w_msg "Error" "PUERTO debe ser numérico."
    continue
  fi

  if ! [[ "$DB_PORT" =~ ^[0-9]+$ ]]; then
    w_msg "Error" "DB_PORT debe ser numérico."
    continue
  fi

  if [[ -z "$DB_SERVER" || -z "$DB_SERVICE" || -z "$ORACLE_ADMIN_USER" || -z "$ORACLE_APP_USER" || -z "$ORACLE_TABLESPACE" ]]; then
    w_msg "Error" "DB_SERVER, DB_SERVICE, ORACLE_ADMIN_USER, ORACLE_APP_USER y ORACLE_TABLESPACE son obligatorios."
    continue
  fi

  SUMMARY="Se usarán estos valores:

ENTORNO:              $ENTORNO
PUERTO:               $PUERTO
FOLDER:               $FOLDER
DB_TYPE:              $ORACLE_DB_TYPE

ORACLE REMOTO:
DB_SERVER:            $DB_SERVER
DB_PORT:              $DB_PORT
DB_SERVICE:           $DB_SERVICE
ADMIN USER:           $ORACLE_ADMIN_USER
APP USER:             $ORACLE_APP_USER
TABLESPACE:           $ORACLE_TABLESPACE
TEMP TABLESPACE:      $ORACLE_TEMP_TABLESPACE
CREATE_APP_USER:      $CREATE_APP_USER
DB_EXISTS:            $DB_EXISTS
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
    3) INSTALL_CANCELLED="yes"; echo "Cancelado por el usuario."; exit 0 ;;
  esac
done

# ============================================================
# 2) Dependencias
# ============================================================
DEPS="$(w_checklist "Dependencias" "Selecciona qué quieres instalar/asegurar en este servidor Debian:" \
  "base"           "git, expect, fontconfig, unzip, wget, curl, ca-certificates, lsb-release" ON \
  "java17"         "Temurin/OpenJDK 17" ON \
  "nginx"          "Nginx" OFF \
  "skip"           "NO instalar nada (solo continuar)" OFF
)"

INSTALL_ANY="yes"
if [[ "$DEPS" == *"skip"* ]]; then
  INSTALL_ANY="no"
fi

confirm_checkpoint "Confirmación final" "Se iniciará la instalación de iDempiere usando Oracle remoto.\n\nPodrás cancelar en cualquier momento con Ctrl+C.\n\n¿Deseas continuar?"

# ============================================================
# 3) Instalación en consola
# ============================================================
clear
export IDEMPIERE_HOME="/opt/${FOLDER}/${PUERTO}_${ENTORNO}"
export ENTORNO PUERTO FOLDER
CREATED_IDEMPIERE_HOME="$IDEMPIERE_HOME"

echo "Iniciando instalación..."
echo "Oracle remoto: ${DB_SERVER}:${DB_PORT}/${DB_SERVICE}"
echo "Tipo de base: ${ORACLE_DB_TYPE}"
echo "Puedes cancelar en cualquier momento con Ctrl+C"

if [[ "$INSTALL_ANY" == "yes" ]]; then
  confirm_checkpoint "Checkpoint" "Se instalarán/asegurarán dependencias del sistema.\n\n¿Continuar?"
  if [[ "$DEPS" == *"java17"* ]]; then
    ensure_adoptium_repo
  fi

  step "APT update"
  apt update -y

  if [[ "$DEPS" == *"base"* ]]; then
    step "Instalando base"
    apt install -y git expect fontconfig unzip wget curl ca-certificates lsb-release
  fi

  if [[ "$DEPS" == *"java17"* ]]; then
    step "Instalando Java 17 (Temurin)"
    apt install -y temurin-17-jdk
  fi

  if [[ "$DEPS" == *"nginx"* ]]; then
    step "Instalando Nginx"
    apt install -y nginx
  fi
else
  step "Saltando instalación de dependencias"
fi

require_cmd java "Instala Java 17 antes de continuar."
require_cmd javac "Se requiere JDK, no solo JRE."
require_cmd sqlplus "Instala Oracle Instant Client y deja sqlplus en PATH."
require_cmd impdp "El import Oracle de iDempiere requiere impdp en PATH."

JAVA_HOME_DYNAMIC="$(detect_java_home)"
export JAVA_HOME="$JAVA_HOME_DYNAMIC"

step "Java detectado"
echo "JAVA_HOME=$JAVA_HOME"
java -version
javac -version

confirm_checkpoint "Checkpoint" "Se validará la conexión con el Oracle remoto y los tablespaces.\n\n¿Continuar?"
step "Validando conexión Oracle remoto"
if ! oracle_test_connection; then
  echo "ERROR: no se pudo conectar a Oracle remoto con las credenciales suministradas."
  exit 1
fi

step "Validando tablespaces en Oracle remoto"
oracle_verify_tablespace

confirm_checkpoint "Checkpoint" "Se procederá con creación/ajuste del usuario de aplicación en Oracle remoto si corresponde.\n\n¿Continuar?"
step "Preparando usuario de aplicación Oracle"
oracle_prepare_app_user

# ============================================================
# 4) Usuario OS y prerrequisitos Oracle
# ============================================================
confirm_checkpoint "Checkpoint" "Se crearán directorios locales y usuario del sistema para iDempiere.\n\n¿Continuar?"
step "Creando directorio $IDEMPIERE_HOME"
mkdir -p "$IDEMPIERE_HOME"
mkdir -p "/opt/$FOLDER"

step "Creando usuario idempiere (si no existe)"
if ! id idempiere >/dev/null 2>&1; then
  useradd -d "$IDEMPIERE_HOME" -s /bin/bash idempiere
fi

if getent group dba >/dev/null 2>&1; then
  step "Agregando usuario idempiere al grupo dba"
  usermod -aG dba idempiere || true
else
  echo "ADVERTENCIA: no existe el grupo 'dba' en este host. Revisa este punto antes del import Oracle."
fi

# ============================================================
# 5) Descargar e instalar iDempiere
# ============================================================
confirm_checkpoint "Checkpoint" "Se descargará y desplegará iDempiere en el servidor Debian.\n\n¿Continuar?"
step "Descargando build.zip (si no existe)"
if [[ ! -f "build.zip" ]]; then
  wget --progress=bar:force:noscroll -O build.zip \
    "https://sourceforge.net/projects/idempiere/files/v12/daily-server/idempiereServer12Daily.gtk.linux.x86_64.zip/download"
fi

step "Extrayendo build.zip"
rm -rf idempiere.gtk.linux.x86_64
unzip -o build.zip

step "Moviendo iDempiere a $IDEMPIERE_HOME"
if [[ -d "idempiere.gtk.linux.x86_64/idempiere-server" ]]; then
  rm -rf "$IDEMPIERE_HOME"/*
  mv idempiere.gtk.linux.x86_64/idempiere-server/* "$IDEMPIERE_HOME"/
  rm -rf idempiere.gtk.linux.x86_64
else
  echo "ERROR: no se encontró la carpeta idempiere.gtk.linux.x86_64/idempiere-server"
  exit 1
fi

if getent group dba >/dev/null 2>&1; then
  step "Ajustando permisos Oracle sobre IDEMPIERE_HOME"
  chgrp -R dba "$IDEMPIERE_HOME" || true
  chmod -R g+rwX "$IDEMPIERE_HOME" || true
fi

step "Creando idempiereEnv.properties"
cat <<EOF > "$IDEMPIERE_HOME/idempiereEnv.properties"
# idempiereEnv.properties

IDEMPIERE_HOME=$IDEMPIERE_HOME
JAVA_HOME=$JAVA_HOME
IDEMPIERE_JAVA_OPTIONS=-Xms1G -Xmx1G

ADEMPIERE_DB_TYPE=$ORACLE_DB_TYPE
ADEMPIERE_DB_EXISTS=$DB_EXISTS
ADEMPIERE_DB_PATH=$ORACLE_DB_TYPE
ADEMPIERE_DB_SERVER=$DB_SERVER
ADEMPIERE_DB_PORT=$DB_PORT
ADEMPIERE_DB_NAME=$DB_SERVICE
ADEMPIERE_DB_SYSTEM=$ORACLE_ADMIN_PASSWORD
ADEMPIERE_DB_USER=$ORACLE_APP_USER
ADEMPIERE_DB_PASSWORD=$ORACLE_APP_PASSWORD

ADEMPIERE_APPS_SERVER=0.0.0.0
ADEMPIERE_WEB_ALIAS=localhost
ADEMPIERE_WEB_PORT=80$PUERTO
ADEMPIERE_SSL_PORT=84$PUERTO

ADEMPIERE_KEYSTORE=$IDEMPIERE_HOME/keystore/myKeystore
ADEMPIERE_KEYSTOREWEBALIAS=adempiere
ADEMPIERE_KEYSTORECODEALIAS=adempiere
ADEMPIERE_KEYSTOREPASS=myPassword

ADEMPIERE_CERT_CN=localhost
ADEMPIERE_CERT_ORG=iDempiere Bazaar
ADEMPIERE_CERT_ORG_UNIT=iDempiereUser
ADEMPIERE_CERT_LOCATION=myTown
ADEMPIERE_CERT_STATE=CA
ADEMPIERE_CERT_COUNTRY=US

ADEMPIERE_MAIL_SERVER=localhost
ADEMPIERE_ADMIN_EMAIL=
ADEMPIERE_MAIL_USER=
ADEMPIERE_MAIL_PASSWORD=

ADEMPIERE_FTP_SERVER=localhost
ADEMPIERE_FTP_PREFIX=my
ADEMPIERE_FTP_USER=anonymous
ADEMPIERE_FTP_PASSWORD=user@host.com
EOF

confirm_checkpoint "Checkpoint" "Se ejecutará el setup silencioso, el import de base y la sincronización.\n\n¿Continuar?"
step "Ejecutando silent-setup-alt.sh"
cd "$IDEMPIERE_HOME"
sh silent-setup-alt.sh

step "Importando base (RUN_ImportIdempiere.sh)"
cd "$IDEMPIERE_HOME/utils"
bash RUN_ImportIdempiere.sh

step "Sync DB (RUN_SyncDB.sh)"
cd "$IDEMPIERE_HOME/utils"
sh RUN_SyncDB.sh

step "Firmando base (sign-database-build-alt.sh)"
cd "$IDEMPIERE_HOME"
sh sign-database-build-alt.sh

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

confirm_checkpoint "Checkpoint" "Se creará y habilitará el servicio del sistema para iDempiere.\n\n¿Continuar?"
SERVICIO="${PUERTO}_${ENTORNO}"
CREATED_SERVICE="$SERVICIO"

step "Creando servicio: $SERVICIO"
cp "$IDEMPIERE_HOME/utils/unix/idempiere_Debian.sh" "/etc/init.d/$SERVICIO"

archivo="/etc/init.d/$SERVICIO"
tmp_sed="${archivo}.tmp"
TMP_FILES+=("$tmp_sed")

sed "s|/opt/idempiere-server|$IDEMPIERE_HOME|g; s|TELNET_PORT=12612|TELNET_PORT=126$PUERTO|g" \
  "$archivo" > "$tmp_sed"
mv "$tmp_sed" "$archivo"
chmod 755 "$archivo"

systemctl daemon-reload
systemctl enable "$SERVICIO"
systemctl restart "$SERVICIO"

w_msg "Finalizado" "Servicio: $SERVICIO\nHome: $IDEMPIERE_HOME\nJAVA_HOME: $JAVA_HOME\nDB_TYPE: $ORACLE_DB_TYPE"
