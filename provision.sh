#!/usr/bin/env bash
set -Eeuo pipefail

# ============================================================
# iDempiere Provision Script - Debian 13 + Oracle Remoto
# v4.2 - Fix contraseñas con caracteres especiales en sqlplus
# Hecho por Carl0gonzalez + Base de Josian
# ============================================================

INSTALL_CANCELLED="no"
CURRENT_STEP="inicio"
CREATED_SERVICE=""
CREATED_IDEMPIERE_HOME=""
TMP_FILES=()

# ============================================================
# Trap / Limpieza
# ============================================================
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
  echo "Se recibió señal de cancelación. Saliendo de forma controlada..."
  exit 130
}

trap cleanup EXIT
trap cancel_install INT TERM

# ============================================================
# Helpers básicos
# ============================================================
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
  local title="$1" prompt="$2" default="$3"
  local height="${4:-10}" width="${5:-75}"
  local result
  result=$(whiptail --title "$title" --inputbox "$prompt" "$height" "$width" "$default" 3>&1 1>&2 2>&3)
  abort_if_cancel $?
  echo "$result"
}

w_password() {
  local title="$1" prompt="$2"
  local height="${3:-10}" width="${4:-75}"
  local result
  result=$(whiptail --title "$title" --passwordbox "$prompt" "$height" "$width" 3>&1 1>&2 2>&3)
  abort_if_cancel $?
  echo "$result"
}

# FIX v4.1: w_yesno con redirección explícita al TTY
w_yesno() {
  local title="$1" prompt="$2"
  local height="${3:-10}" width="${4:-75}"
  local code=0
  whiptail --title "$title" --yesno "$prompt" "$height" "$width" \
    >/dev/tty 2>/dev/tty </dev/tty || code=$?
  if [[ "$code" -eq 0 ]]; then
    echo "Y"
  elif [[ "$code" -eq 1 ]]; then
    echo "N"
  else
    INSTALL_CANCELLED="yes"
    echo "Cancelado por el usuario."
    exit 0
  fi
}

w_menu() {
  local title="$1" prompt="$2"
  shift 2
  local result
  result=$(whiptail --title "$title" --menu "$prompt" 18 85 8 "$@" 3>&1 1>&2 2>&3)
  abort_if_cancel $?
  echo "$result"
}

w_msg() {
  local title="$1" msg="$2"
  whiptail --title "$title" --msgbox "$msg" 22 90
  abort_if_cancel $?
}

w_checklist() {
  local title="$1" text="$2"
  shift 2
  local result
  result=$(whiptail --title "$title" --checklist "$text" 18 90 8 "$@" 3>&1 1>&2 2>&3)
  abort_if_cancel $?
  echo "$result"
}

# FIX v4.1: confirm_checkpoint con redirección explícita al TTY
confirm_checkpoint() {
  local title="$1" prompt="$2"
  local code=0
  whiptail --title "$title" --yesno "$prompt" 12 80 \
    >/dev/tty 2>/dev/tty </dev/tty || code=$?
  if [[ "$code" -ne 0 ]]; then
    INSTALL_CANCELLED="yes"
    echo "Cancelado por el usuario."
    exit 0
  fi
}

step() {
  CURRENT_STEP="$*"
  echo -e "\n===== $* =====\n"
}

# ============================================================
# Helpers de sistema
# ============================================================

ensure_adoptium_repo() {
  if [[ ! -f /etc/apt/sources.list.d/adoptium.list ]]; then
    step "Agregando repo Adoptium"
    apt install -y wget apt-transport-https gpg
    wget -qO - https://packages.adoptium.net/artifactory/api/gpg/key/public \
      | gpg --dearmor \
      | tee /etc/apt/trusted.gpg.d/adoptium.gpg >/dev/null
    local codename
    codename="$(awk -F= '/^VERSION_CODENAME/{print$2}' /etc/os-release)"
    echo "deb https://packages.adoptium.net/artifactory/deb ${codename} main" \
      > /etc/apt/sources.list.d/adoptium.list
  fi
}

detect_java_home() {
  local java_bin
  java_bin="$(readlink -f "$(command -v javac)")"
  dirname "$(dirname "$java_bin")"
}

require_cmd() {
  local cmd="$1" msg="$2"
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "ERROR: falta el comando '$cmd'. $msg"
    exit 1
  fi
}

check_port_free() {
  local port="$1"
  if ss -tlnp 2>/dev/null | grep -q ":${port} "; then
    echo "ADVERTENCIA: el puerto ${port} ya está en uso. Revisa antes de continuar."
  fi
}

# ============================================================
# Helpers Oracle
# FIX v4.2: heredoc sin comillas simples + connect separado con
#           password entre comillas dobles — soporta caracteres
#           especiales: # $ & / ) @ ! en contraseñas
# ============================================================

oracle_sql_admin() {
  local sql="$1"
  sqlplus -s /nolog <<SQLEOF
connect ${ORACLE_ADMIN_USER}/"${ORACLE_ADMIN_PASSWORD}"@//${DB_SERVER}:${DB_PORT}/${DB_SERVICE}
set heading off
set feedback off
set verify off
set pagesize 0
set linesize 300
set trimspool on
whenever sqlerror exit failure
${sql}
exit
SQLEOF
}

oracle_sql_app() {
  local sql="$1"
  sqlplus -s /nolog <<SQLEOF
connect ${ORACLE_APP_USER}/"${ORACLE_APP_PASSWORD}"@//${DB_SERVER}:${DB_PORT}/${DB_SERVICE}
set heading off
set feedback off
set verify off
set pagesize 0
set linesize 300
set trimspool on
whenever sqlerror exit failure
${sql}
exit
SQLEOF
}

oracle_test_connection() {
  local out rc=0
  out="$(oracle_sql_admin "select 'CONN_OK' from dual;" 2>&1)" || rc=$?
  if [[ "$rc" -ne 0 ]] || ! echo "$out" | grep -q "CONN_OK"; then
    echo "Detalle del error de conexión:"
    echo "$out"
    return 1
  fi
  return 0
}

oracle_verify_tablespace() {
  local count_data rc_data=0
  count_data="$(oracle_sql_admin \
    "select count(*) from dba_tablespaces where tablespace_name = upper('${ORACLE_TABLESPACE}');" \
    2>&1)" || rc_data=$?
  count_data="$(echo "$count_data" | tr -d '[:space:]')"
  if [[ "$rc_data" -ne 0 || "$count_data" != "1" ]]; then
    echo "ERROR: el tablespace de datos '${ORACLE_TABLESPACE}' no existe o no es accesible."
    echo "Resultado raw: $count_data"
    exit 1
  fi

  local count_temp rc_temp=0
  count_temp="$(oracle_sql_admin \
    "select count(*) from dba_tablespaces where tablespace_name = upper('${ORACLE_TEMP_TABLESPACE}');" \
    2>&1)" || rc_temp=$?
  count_temp="$(echo "$count_temp" | tr -d '[:space:]')"
  if [[ "$rc_temp" -ne 0 || "$count_temp" != "1" ]]; then
    echo "ERROR: el temporary tablespace '${ORACLE_TEMP_TABLESPACE}' no existe o no es accesible."
    exit 1
  fi
}

oracle_prepare_app_user() {
  if [[ "${CREATE_APP_USER}" != "Y" ]]; then
    step "Saltando creación/ajuste del usuario Oracle de aplicación"
    return
  fi

  step "Creando o ajustando usuario Oracle ${ORACLE_APP_USER}"
  local rc=0
  sqlplus -s /nolog <<SQLEOF || rc=$?
connect ${ORACLE_ADMIN_USER}/"${ORACLE_ADMIN_PASSWORD}"@//${DB_SERVER}:${DB_PORT}/${DB_SERVICE}
set heading off
set feedback off
set verify off
set pagesize 0
set linesize 300
whenever sqlerror exit failure

declare
  v_count number := 0;
  v_user  varchar2(128) := upper('${ORACLE_APP_USER}');
  v_pass  varchar2(512) := '${ORACLE_APP_PASSWORD}';
  v_ts    varchar2(128) := upper('${ORACLE_TABLESPACE}');
  v_tts   varchar2(128) := upper('${ORACLE_TEMP_TABLESPACE}');
begin
  select count(*) into v_count from dba_users where username = v_user;
  if v_count = 0 then
    execute immediate 'create user ' || v_user ||
      ' identified by "' || v_pass || '"' ||
      ' default tablespace ' || v_ts ||
      ' temporary tablespace ' || v_tts ||
      ' quota unlimited on ' || v_ts;
    execute immediate 'grant connect, resource, create view, create sequence, create materialized view to ' || v_user;
  else
    execute immediate 'alter user ' || v_user || ' identified by "' || v_pass || '"';
    execute immediate 'alter user ' || v_user ||
      ' default tablespace ' || v_ts ||
      ' temporary tablespace ' || v_tts ||
      ' quota unlimited on ' || v_ts;
    execute immediate 'grant connect, resource, create view, create sequence, create materialized view to ' || v_user;
  end if;
end;
/
exit
SQLEOF

  if [[ "$rc" -ne 0 ]]; then
    echo "ERROR: falló la creación/ajuste del usuario Oracle ${ORACLE_APP_USER} (rc=$rc)."
    exit 1
  fi
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

ENTORNO=""
PUERTO=""
FOLDER=""
ORACLE_DB_TYPE=""
DB_SERVER=""
DB_PORT=""
DB_SERVICE=""
ORACLE_ADMIN_USER=""
ORACLE_ADMIN_PASSWORD=""
ORACLE_APP_USER=""
ORACLE_APP_PASSWORD=""
ORACLE_TABLESPACE=""
ORACLE_TEMP_TABLESPACE=""
CREATE_APP_USER=""
DB_EXISTS=""

while true; do
  ENTORNO="$(w_input "Parámetros iDempiere" "ENTORNO (ej: idempiere, test, prod):" "${ENTORNO:-$ENTORNO_DEFAULT}")"
  PUERTO="$(w_input "Parámetros iDempiere" "PUERTO base (ej: 80, 81, 82). WEB_PORT=80\$PUERTO, SSL=84\$PUERTO:" "${PUERTO:-$PUERTO_DEFAULT}")"
  FOLDER="$(w_input "Parámetros iDempiere" "FOLDER (carpeta base en /opt, ej: sas):" "${FOLDER:-$FOLDER_DEFAULT}")"

  ORACLE_DB_TYPE="$(w_menu "Tipo de base de datos" "Selecciona el tipo de Oracle REMOTO:" \
    "oracle"   "Oracle estándar / Enterprise / Standard / PDB" \
    "oracleXE" "Oracle Express Edition (XE)"
  )"

  DB_SERVER="$(w_input "Oracle remoto" "DB_SERVER (host o IP del servidor Oracle remoto):" "${DB_SERVER:-$DB_SERVER_DEFAULT}")"
  DB_PORT="$(w_input "Oracle remoto" "DB_PORT del listener Oracle remoto:" "${DB_PORT:-$DB_PORT_DEFAULT}")"
  DB_SERVICE="$(w_input "Oracle remoto" "DB_SERVICE / Service Name / PDB (ej: xepdb1, ORCL):" "${DB_SERVICE:-$DB_SERVICE_DEFAULT}")"

  ORACLE_ADMIN_USER="$(w_input "Oracle remoto" "Usuario administrador Oracle remoto (ej: system):" "${ORACLE_ADMIN_USER:-$ORACLE_ADMIN_USER_DEFAULT}")"
  ORACLE_ADMIN_PASSWORD="$(w_password "Oracle remoto" "Password del usuario administrador Oracle (vuelve a ingresar si editas):")"

  ORACLE_APP_USER="$(w_input "Oracle remoto" "Usuario de aplicación iDempiere en Oracle remoto:" "${ORACLE_APP_USER:-$ORACLE_APP_USER_DEFAULT}")"
  ORACLE_APP_PASSWORD="$(w_password "Oracle remoto" "Password del usuario de aplicación ${ORACLE_APP_USER} (vuelve a ingresar si editas):")"

  ORACLE_TABLESPACE="$(w_input "Oracle remoto" "Tablespace de datos para iDempiere:" "${ORACLE_TABLESPACE:-$ORACLE_TABLESPACE_DEFAULT}")"
  ORACLE_TEMP_TABLESPACE="$(w_input "Oracle remoto" "Temporary tablespace para iDempiere:" "${ORACLE_TEMP_TABLESPACE:-$ORACLE_TEMP_TABLESPACE_DEFAULT}")"

  CREATE_APP_USER="$(w_yesno "Oracle remoto" "¿Crear o ajustar el usuario Oracle de aplicación (${ORACLE_APP_USER})?\n\nSí = crear/actualizar usuario\nNo = usar usuario existente sin cambios" 12 70)"
  DB_EXISTS="$(w_yesno "Base de datos" "¿El esquema de iDempiere ya existe en Oracle?\n\nSí = NO importar seed (ya está cargado)\nNo = importar seed desde cero" 12 70)"

  # Validaciones
  if ! [[ "$PUERTO" =~ ^[0-9]+$ ]]; then
    w_msg "Error" "PUERTO debe ser numérico."
    continue
  fi

  if ! [[ "$DB_PORT" =~ ^[0-9]+$ ]]; then
    w_msg "Error" "DB_PORT debe ser numérico."
    continue
  fi

  if [[ -z "${ORACLE_ADMIN_PASSWORD:-}" || -z "${ORACLE_APP_PASSWORD:-}" ]]; then
    w_msg "Error" "Las contraseñas de Oracle no pueden estar vacías."
    continue
  fi

  if [[ -z "$DB_SERVER" || -z "$DB_SERVICE" || -z "$ORACLE_ADMIN_USER" || \
        -z "$ORACLE_APP_USER" || -z "$ORACLE_TABLESPACE" ]]; then
    w_msg "Error" "DB_SERVER, DB_SERVICE, ORACLE_ADMIN_USER, ORACLE_APP_USER y ORACLE_TABLESPACE son obligatorios."
    continue
  fi

  WEB_PORT_COMPOSED="80${PUERTO}"
  SSL_PORT_COMPOSED="84${PUERTO}"
  TELNET_PORT_COMPOSED="126${PUERTO}"

  if ! [[ "$WEB_PORT_COMPOSED" =~ ^[0-9]+$ ]] || [[ "$WEB_PORT_COMPOSED" -gt 65535 ]] || \
     ! [[ "$SSL_PORT_COMPOSED"  =~ ^[0-9]+$ ]] || [[ "$SSL_PORT_COMPOSED"  -gt 65535 ]] || \
     ! [[ "$TELNET_PORT_COMPOSED" =~ ^[0-9]+$ ]] || [[ "$TELNET_PORT_COMPOSED" -gt 65535 ]]; then
    w_msg "Error" "El PUERTO '${PUERTO}' genera puertos inválidos:\nWEB=${WEB_PORT_COMPOSED}\nSSL=${SSL_PORT_COMPOSED}\nTELNET=${TELNET_PORT_COMPOSED}\n\nUsa un valor más corto (ej: 80, 81, 82)."
    continue
  fi

  SUMMARY="Se usarán estos valores:

ENTORNO:            $ENTORNO
PUERTO:             $PUERTO
  WEB_PORT:         $WEB_PORT_COMPOSED
  SSL_PORT:         $SSL_PORT_COMPOSED
  TELNET_PORT:      $TELNET_PORT_COMPOSED
FOLDER:             $FOLDER
DB_TYPE:            $ORACLE_DB_TYPE

ORACLE REMOTO:
DB_SERVER:          $DB_SERVER
DB_PORT:            $DB_PORT
DB_SERVICE:         $DB_SERVICE
ADMIN USER:         $ORACLE_ADMIN_USER
APP USER:           $ORACLE_APP_USER
TABLESPACE:         $ORACLE_TABLESPACE
TEMP TABLESPACE:    $ORACLE_TEMP_TABLESPACE
CREATE_APP_USER:    $CREATE_APP_USER
DB_EXISTS:          $DB_EXISTS
"
  w_msg "Resumen de configuración" "$SUMMARY"

  ACTION=$(whiptail --title "Acción" --menu "¿Todo correcto?" 14 65 3 \
    "1" "Continuar con la instalación" \
    "2" "Editar parámetros (mantiene valores)" \
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
DEPS="$(w_checklist "Dependencias" "Selecciona qué instalar/asegurar en este servidor Debian:" \
  "base"   "git, expect, fontconfig, unzip, wget, curl, ca-certificates, lsb-release" ON \
  "java17" "Temurin/OpenJDK 17" ON \
  "nginx"  "Nginx" OFF \
  "skip"   "NO instalar nada (solo continuar)" OFF
)"

INSTALL_ANY="yes"
[[ "$DEPS" == *"skip"* ]] && INSTALL_ANY="no"

confirm_checkpoint "Confirmación final" "Se iniciará la instalación de iDempiere con Oracle remoto.\n\nPodrás cancelar con Ctrl+C en cualquier momento.\n\n¿Deseas continuar?"

# ============================================================
# 3) Instalación en consola
# ============================================================
clear
export IDEMPIERE_HOME="/opt/${FOLDER}/${PUERTO}_${ENTORNO}"
export ENTORNO PUERTO FOLDER
CREATED_IDEMPIERE_HOME="$IDEMPIERE_HOME"

echo "======================================================"
echo " Iniciando instalación iDempiere v12"
echo " Oracle remoto:  ${DB_SERVER}:${DB_PORT}/${DB_SERVICE}"
echo " Tipo de base:   ${ORACLE_DB_TYPE}"
echo " iDempiere home: ${IDEMPIERE_HOME}"
echo " WEB_PORT:       ${WEB_PORT_COMPOSED}"
echo " SSL_PORT:       ${SSL_PORT_COMPOSED}"
echo " TELNET_PORT:    ${TELNET_PORT_COMPOSED}"
echo " Ctrl+C cancela en cualquier momento"
echo "======================================================"

if [[ "$INSTALL_ANY" == "yes" ]]; then
  confirm_checkpoint "Checkpoint 1/6" "Se instalarán/asegurarán dependencias del sistema.\n\n¿Continuar?"

  if [[ "$DEPS" == *"java17"* ]]; then
    ensure_adoptium_repo
  fi

  step "APT update"
  apt update -y

  if [[ "$DEPS" == *"base"* ]]; then
    step "Instalando paquetes base"
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

# Verificar comandos siempre requeridos
require_cmd java   "Instala Java 17 (Temurin) antes de continuar."
require_cmd javac  "Se requiere JDK completo, no solo JRE."
require_cmd sqlplus "Instala Oracle Instant Client Basic + SQL*Plus y agrega al PATH."

# FIX v4.2: impdp solo se requiere si se va a importar el seed
if [[ "$DB_EXISTS" != "Y" ]]; then
  require_cmd impdp "Instala Oracle Instant Client Tools y agrega al PATH.\nSymlink: sudo ln -s /opt/oracle/instantclient_*/impdp /usr/local/bin/impdp"
fi

JAVA_HOME_DYNAMIC="$(detect_java_home)"
export JAVA_HOME="$JAVA_HOME_DYNAMIC"

step "Java detectado"
echo "JAVA_HOME=$JAVA_HOME"
java -version
javac -version

check_port_free "$WEB_PORT_COMPOSED"
check_port_free "$SSL_PORT_COMPOSED"
check_port_free "$TELNET_PORT_COMPOSED"

confirm_checkpoint "Checkpoint 2/6" "Se validará la conexión con Oracle remoto y los tablespaces.\n\n¿Continuar?"

step "Validando conexión Oracle remoto"
if ! oracle_test_connection; then
  echo "ERROR: no se pudo conectar a Oracle remoto."
  echo "Verifica: host, puerto, service name y credenciales."
  exit 1
fi
echo "Conexión Oracle: OK"

step "Validando tablespaces en Oracle remoto"
oracle_verify_tablespace
echo "Tablespaces: OK"

confirm_checkpoint "Checkpoint 3/6" "Se procederá con la creación/ajuste del usuario Oracle de aplicación.\n\n¿Continuar?"
step "Preparando usuario de aplicación Oracle"
oracle_prepare_app_user

# ============================================================
# 4) Usuario OS y estructura de directorios
# ============================================================
confirm_checkpoint "Checkpoint 4/6" "Se crearán directorios locales y el usuario del sistema para iDempiere.\n\n¿Continuar?"

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
  echo "ADVERTENCIA: no existe el grupo 'dba' en este host. Continuando."
fi

# ============================================================
# 5) Descargar e instalar iDempiere
# ============================================================
confirm_checkpoint "Checkpoint 5/6" "Se descargará y desplegará iDempiere en este servidor.\n\n¿Continuar?"

step "Descargando build.zip (si no existe)"
if [[ ! -f "build.zip" ]]; then
  wget --progress=bar:force:noscroll -O build.zip \
    "https://sourceforge.net/projects/idempiere/files/v12/daily-server/idempiereServer12Daily.gtk.linux.x86_64.zip/download"
fi

step "Extrayendo build.zip"
rm -rf idempiere.gtk.linux.x86_64
unzip -o build.zip

EXTRACTED_DIR=""
if [[ -d "idempiere.gtk.linux.x86_64/idempiere-server" ]]; then
  EXTRACTED_DIR="idempiere.gtk.linux.x86_64/idempiere-server"
else
  EXTRACTED_DIR="$(find . -maxdepth 2 -type d -name "idempiere-server" 2>/dev/null | head -1)"
  if [[ -z "$EXTRACTED_DIR" ]]; then
    echo "ERROR: no se encontró carpeta 'idempiere-server' después de extraer el ZIP."
    echo "Contenido actual:"; ls -la
    exit 1
  fi
fi

step "Moviendo iDempiere a $IDEMPIERE_HOME"
rm -rf "${IDEMPIERE_HOME:?}"/*
mv "$EXTRACTED_DIR"/* "$IDEMPIERE_HOME"/
rm -rf idempiere.gtk.linux.x86_64

if getent group dba >/dev/null 2>&1; then
  step "Ajustando permisos Oracle sobre IDEMPIERE_HOME"
  chgrp -R dba "$IDEMPIERE_HOME" || true
  chmod -R g+rwX "$IDEMPIERE_HOME" || true
fi

# Detectar scripts de setup
SETUP_SCRIPT=""
if [[ -f "$IDEMPIERE_HOME/silent-setup-alt.sh" ]]; then
  SETUP_SCRIPT="$IDEMPIERE_HOME/silent-setup-alt.sh"
elif [[ -f "$IDEMPIERE_HOME/utils/RUN_SilentSetup.sh" ]]; then
  SETUP_SCRIPT="$IDEMPIERE_HOME/utils/RUN_SilentSetup.sh"
else
  echo "ERROR: no se encontró script de setup silencioso."
  find "$IDEMPIERE_HOME" -maxdepth 2 -name "*.sh" | sort
  exit 1
fi

SIGN_SCRIPT=""
if [[ -f "$IDEMPIERE_HOME/sign-database-build-alt.sh" ]]; then
  SIGN_SCRIPT="$IDEMPIERE_HOME/sign-database-build-alt.sh"
elif [[ -f "$IDEMPIERE_HOME/utils/sign-database-build.sh" ]]; then
  SIGN_SCRIPT="$IDEMPIERE_HOME/utils/sign-database-build.sh"
else
  echo "ADVERTENCIA: no se encontró script de firma de base. Se omitirá."
fi

step "Creando idempiereEnv.properties"
KEYSTORE_PASS="$(openssl rand -base64 18 | tr -dc 'A-Za-z0-9' | head -c 20)"

cat <<EOF > "$IDEMPIERE_HOME/idempiereEnv.properties"
# idempiereEnv.properties - generado automáticamente por provision.sh v4.2

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

ADEMPIERE_APPS_SERVER=localhost
ADEMPIERE_WEB_ALIAS=localhost
ADEMPIERE_WEB_PORT=$WEB_PORT_COMPOSED
ADEMPIERE_SSL_PORT=$SSL_PORT_COMPOSED

ADEMPIERE_KEYSTORE=$IDEMPIERE_HOME/keystore/myKeystore
ADEMPIERE_KEYSTOREWEBALIAS=adempiere
ADEMPIERE_KEYSTORECODEALIAS=adempiere
ADEMPIERE_KEYSTOREPASS=$KEYSTORE_PASS

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

echo ""
echo ">>> KEYSTORE_PASS generado: $KEYSTORE_PASS"
echo ">>> Guarda este valor en un lugar seguro."
echo ""

confirm_checkpoint "Checkpoint 6/6" "Se ejecutará el setup silencioso, el import de base (si aplica) y la sincronización.\n\n¿Continuar?"

step "Ejecutando setup silencioso: $(basename $SETUP_SCRIPT)"
cd "$IDEMPIERE_HOME"
sh "$SETUP_SCRIPT"

if [[ "$DB_EXISTS" != "Y" ]]; then
  step "Importando base de datos seed (RUN_ImportIdempiere.sh)"
  if [[ -f "$IDEMPIERE_HOME/utils/RUN_ImportIdempiere.sh" ]]; then
    cd "$IDEMPIERE_HOME/utils"
    bash RUN_ImportIdempiere.sh
  else
    echo "ERROR: no se encontró utils/RUN_ImportIdempiere.sh"
    exit 1
  fi
else
  step "Saltando import (DB_EXISTS=Y — esquema ya existe en Oracle)"
fi

step "Sync DB (RUN_SyncDB.sh)"
if [[ -f "$IDEMPIERE_HOME/utils/RUN_SyncDB.sh" ]]; then
  cd "$IDEMPIERE_HOME/utils"
  sh RUN_SyncDB.sh
else
  echo "ADVERTENCIA: no se encontró utils/RUN_SyncDB.sh — omitiendo sync."
fi

if [[ -n "$SIGN_SCRIPT" ]]; then
  step "Firmando base: $(basename $SIGN_SCRIPT)"
  cd "$IDEMPIERE_HOME"
  sh "$SIGN_SCRIPT"
else
  step "Omitiendo firma de base (script no disponible)"
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

# ============================================================
# 6) Servicio systemd
# ============================================================
SERVICIO="${PUERTO}_${ENTORNO}"
CREATED_SERVICE="$SERVICIO"

step "Creando servicio: $SERVICIO"

INIT_SCRIPT_SRC="$IDEMPIERE_HOME/utils/unix/idempiere_Debian.sh"
if [[ ! -f "$INIT_SCRIPT_SRC" ]]; then
  echo "ERROR: no se encontró el script init $INIT_SCRIPT_SRC"
  exit 1
fi

cp "$INIT_SCRIPT_SRC" "/etc/init.d/$SERVICIO"
archivo="/etc/init.d/$SERVICIO"
tmp_sed="${archivo}.tmp"
TMP_FILES+=("$tmp_sed")

sed "s|/opt/idempiere-server|$IDEMPIERE_HOME|g; s|TELNET_PORT=12612|TELNET_PORT=${TELNET_PORT_COMPOSED}|g" \
  "$archivo" > "$tmp_sed"
mv "$tmp_sed" "$archivo"
chmod 755 "$archivo"

systemctl daemon-reload
systemctl enable "$SERVICIO"
systemctl restart "$SERVICIO"

w_msg "Instalación completada ✓" "Servicio:      $SERVICIO
Home:          $IDEMPIERE_HOME
JAVA_HOME:     $JAVA_HOME
DB_TYPE:       $ORACLE_DB_TYPE
DB_SERVER:     $DB_SERVER:$DB_PORT/$DB_SERVICE
APP_USER:      $ORACLE_APP_USER
WEB_PORT:      $WEB_PORT_COMPOSED
SSL_PORT:      $SSL_PORT_COMPOSED
TELNET_PORT:   $TELNET_PORT_COMPOSED

KEYSTORE_PASS fue mostrado en consola.
Guárdalo en un lugar seguro."
