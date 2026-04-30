# iDempiere Provisioning Script

Script de provisión para instalar **iDempiere** de forma rápida y guiada en servidores **Debian 13 (Trixie)**, con soporte para **Java 17 (Temurin)**, **PostgreSQL 15** y configuración automática del entorno.

Este repositorio utiliza **ramas** para separar versiones y arquitecturas, por ejemplo:

- `12-x86` → iDempiere 12 para AMD64 / x86_64
- `12-x86Debian` → iDempiere 12 para AMD64 / x86_64 en OS Debian
- `12-arm` → iDempiere 12 para ARM64

- Otras ramas según versión o arquitectura

---

## Instalación rápida

Ejecuta el instalador directamente desde GitHub reemplazando `<RAMA>` por la rama que necesites:

```bash
sudo bash -c 'bash <(curl -fsSL https://raw.githubusercontent.com/josianascanio/idempiere/<RAMA>/provision.sh)'
```

### Ejemplos

#### Rama `12`
```bash
sudo bash -c 'bash <(curl -fsSL https://raw.githubusercontent.com/josianascanio/idempiere/12/provision.sh)'
```

#### Rama `12-arm`
```bash
sudo bash -c 'bash <(curl -fsSL https://raw.githubusercontent.com/josianascanio/idempiere/12-arm/provision.sh)'
```

---

## Qué hace este script

El script automatiza la instalación y preparación de un entorno iDempiere, reduciendo al mínimo la configuración manual.

### Funciones principales

- Solicita los parámetros principales mediante una interfaz interactiva con `whiptail`.
- Permite definir:
  - entorno (`idempiere`, `test`, `prod`, etc.)
  - puerto base
  - carpeta de instalación
  - servidor PostgreSQL
  - contraseña del usuario `adempiere`
- Instala o asegura dependencias opcionales seleccionadas por el usuario.
- Puede agregar el repositorio oficial de PostgreSQL.
- Puede instalar Java 17 usando **Temurin**.
- Puede instalar PostgreSQL 15.
- Puede instalar Nginx.
- Descarga automáticamente el paquete de servidor de iDempiere.
- Extrae y mueve los archivos al directorio final en `/opt`.
- Genera el archivo `idempiereEnv.properties`.
- Detecta `JAVA_HOME` dinámicamente a partir del `java` activo del sistema.
- Ejecuta:
  - `silent-setup-alt.sh`
  - `RUN_ImportIdempiere.sh`
  - `RUN_SyncDB.sh`
  - `sign-database-build-alt.sh`
- Crea el usuario del sistema `idempiere` si no existe.
- Genera llaves SSH para el usuario `idempiere`.
- Crea y habilita un servicio del sistema para iniciar iDempiere automáticamente.

---

## Flujo general

### 1. Captura de parámetros
El script solicita datos básicos del entorno, como nombre del entorno, puerto, carpeta de instalación, host de base de datos y contraseña.

### 2. Selección de dependencias
El usuario puede elegir si desea instalar o asegurar:

- Repositorio oficial de PostgreSQL
- Paquetes base (`git`, `expect`, `fontconfig`, `unzip`, `wget`, `curl`, `ca-certificates`, etc.)
- Java 17
- PostgreSQL 15
- Nginx

### 3. Instalación y configuración
Luego el script:

- actualiza los repositorios
- instala dependencias
- detecta Java
- configura PostgreSQL
- descarga iDempiere
- genera el archivo de entorno
- ejecuta la instalación silenciosa
- importa y sincroniza la base de datos
- crea el servicio de arranque

---

## Requisitos

### Sistema operativo
- **Debian 13 (Trixie)** recomendado

### Acceso
- Usuario con permisos `root` o acceso mediante `sudo`

### Conectividad
- Conexión a internet para descargar paquetes, llaves GPG y el paquete servidor de iDempiere

### Recursos recomendados
- 2 CPU o más
- 4 GB de RAM mínimo
- 20 GB de espacio libre o más

---

## Importante: Java en Debian 13

En **Debian 13** este script está preparado para usar **Java 17 con Temurin**, no `openjdk-17-jdk-headless`.

### ¿Por qué?
En Debian 13 puede no estar disponible el paquete tradicional usado en Ubuntu o Debian anteriores:

```bash
openjdk-17-jdk-headless
```

Por esa razón, el script instala:

```bash
temurin-17-jdk
```

### Ventajas de este enfoque
- Mantiene compatibilidad con iDempiere 12
- Evita errores de paquetes inexistentes en Debian 13
- Permite detectar `JAVA_HOME` de forma dinámica
- No depende de una ruta fija como `/usr/lib/jvm/java-17-openjdk-amd64`

### Detección dinámica de Java
El script calcula automáticamente la ruta real del JDK activo usando:

```bash
readlink -f "$(command -v java)"
```

y a partir de eso define `JAVA_HOME` en el archivo `idempiereEnv.properties`.

---

## Estructura esperada de instalación

Por defecto, el script instala iDempiere en una ruta como:

```bash
/opt/<carpeta>/<puerto>_<entorno>
```

Por ejemplo:

```bash
/opt/sas/80_idempiere
```

Y crea un servicio con un nombre como:

```bash
80_idempiere
```

---

## Ejemplo de ejecución

```bash
sudo bash provision.sh
```

Luego el instalador solicitará los parámetros y mostrará un resumen antes de continuar.

---

## Dependencias que puede instalar

Según lo que seleccione el usuario, el script puede instalar o asegurar:

- `whiptail`
- `git`
- `expect`
- `fontconfig`
- `unzip`
- `wget`
- `curl`
- `ca-certificates`
- `lsb-release`
- `temurin-17-jdk`
- `postgresql-15`
- `nginx`

---

## Qué configura en PostgreSQL

Si PostgreSQL 15 está presente, el script:

- reemplaza `pg_hba.conf`
- configura autenticación `md5` para conexiones locales
- intenta asignar contraseña al usuario `postgres`
- habilita y reinicia el servicio

---

## Servicio generado

Al finalizar, el script:

- copia el script base de iDempiere a `/etc/init.d/<servicio>`
- ajusta la ruta de instalación
- ajusta el puerto telnet interno
- habilita el servicio
- reinicia el servicio automáticamente

Puedes verificarlo con:

```bash
systemctl status <servicio>
```

Ejemplo:

```bash
systemctl status 80_idempiere
```

---

## Recomendaciones de uso

- Usar una instalación limpia de Debian 13
- Verificar que los puertos elegidos estén libres
- Confirmar conectividad al servidor PostgreSQL si no se usa `localhost`
- Ejecutar el script como `root` o con `sudo`
- Revisar los logs si algún paso falla

---

## Solución de problemas

### El paquete `openjdk-17-jdk-headless` no existe
Es esperado en Debian 13. El script ya usa `temurin-17-jdk`.

### `JAVA_HOME` no coincide con OpenJDK clásico
También es esperado. En Debian 13 con Temurin la ruta suele ser algo como:

```bash
/usr/lib/jvm/temurin-17-jdk-amd64
```

o su equivalente según arquitectura.

### El servicio no inicia
Revisar:

```bash
systemctl status <servicio>
journalctl -u <servicio> -xe
```

### PostgreSQL no conecta
Verificar:

- host configurado
- `pg_hba.conf`
- contraseña del usuario
- estado del servicio PostgreSQL

---

## Flujo recomendado

1. Entrar a la rama que necesitas (`12`, `12-arm`, `10`, etc.).
2. Copiar el comando de instalación de esa rama.
3. Ejecutarlo en el servidor.
4. Completar los parámetros solicitados.
5. Esperar la instalación automática.
6. Verificar que el servicio haya quedado iniciado.

---

## Notas

- El script de esta rama está orientado principalmente a **Debian 13**.
- Para otras distribuciones o versiones anteriores puede requerir ajustes.
- El comportamiento puede variar según la rama usada.
- Se recomienda mantener una rama por versión y arquitectura para simplificar soporte y mantenimiento.

---

.
