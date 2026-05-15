# iDempiere 12 Provisioning Script

Script de provision para instalar **iDempiere 12** de forma rapida y guiada en servidores **AMD64 / x86_64**, usando **OpenJDK 17**, **PostgreSQL 15** y configuracion automatica del entorno.

Este repositorio utiliza ramas para separar versiones, arquitecturas y variantes de sistema operativo, por ejemplo:

- `12-x86`: iDempiere 12 para AMD64 / x86_64 usando OpenJDK 17.
- `12-x86Debian`: iDempiere 12 para Debian 13 usando Java 17 Temurin.
- `12-arm`: variante de iDempiere 12 mantenida en una rama separada.
- Otras ramas segun version o arquitectura.

---

## Instalacion rapida

Ejecuta el instalador directamente desde GitHub:

```bash
sudo bash -c 'bash <(curl -fsSL https://raw.githubusercontent.com/josianascanio/idempiere/12-x86/provision.sh)'
```

Si necesitas otra rama, reemplaza `12-x86` por la rama correspondiente:

```bash
sudo bash -c 'bash <(curl -fsSL https://raw.githubusercontent.com/josianascanio/idempiere/<RAMA>/provision.sh)'
```

---

## Que hace este script

El script automatiza la instalacion y preparacion de un entorno iDempiere, reduciendo la configuracion manual necesaria.

### Funciones principales

- Solicita los parametros principales mediante una interfaz interactiva con `whiptail`.
- Permite definir el entorno, puerto base, carpeta de instalacion, servidor PostgreSQL y clave del usuario `adempiere`.
- Instala o asegura dependencias opcionales seleccionadas por el usuario.
- Puede agregar el repositorio oficial de PostgreSQL.
- Puede instalar Java 17 usando `openjdk-17-jdk-headless`.
- Puede instalar PostgreSQL 15.
- Puede instalar Nginx.
- Descarga automaticamente el paquete servidor de iDempiere 12 para x86_64.
- Extrae y mueve los archivos al directorio final bajo `/opt`.
- Genera el archivo `idempiereEnv.properties`.
- Ejecuta `silent-setup-alt.sh`, `RUN_ImportIdempiere.sh`, `RUN_SyncDB.sh` y `sign-database-build-alt.sh`.
- Crea el usuario del sistema `idempiere` si no existe.
- Genera llaves SSH para el usuario `idempiere`.
- Crea, habilita y reinicia un servicio del sistema para iDempiere.

---

## Flujo general

### 1. Captura de parametros

El instalador solicita los datos basicos del entorno:

- `ENTORNO`: nombre del entorno, por ejemplo `idempiere`, `test` o `prod`.
- `PUERTO`: puerto base usado para construir los puertos web y SSL.
- `FOLDER`: carpeta base dentro de `/opt`.
- `DB_SERVER`: host del servidor PostgreSQL.
- `DB_PASS`: clave del usuario de base de datos `adempiere`.

### 2. Seleccion de dependencias

El usuario puede elegir si desea instalar o asegurar:

- Repositorio oficial de PostgreSQL.
- Paquetes base: `git`, `expect` y `fontconfig`.
- OpenJDK 17 headless.
- PostgreSQL 15.
- Nginx.

### 3. Instalacion y configuracion

Luego el script actualiza repositorios, instala dependencias, configura PostgreSQL si esta presente, descarga iDempiere, genera el archivo de entorno, importa la base de datos, sincroniza la base y crea el servicio de arranque.

---

## Requisitos

### Sistema operativo

- Debian o Ubuntu compatible con `apt`.

### Acceso

- Usuario con permisos `root` o acceso mediante `sudo`.

### Conectividad

- Conexion a internet para descargar paquetes, llaves GPG y el paquete servidor de iDempiere.

### Recursos recomendados

- 2 CPU o mas.
- 4 GB de RAM minimo.
- 20 GB de espacio libre o mas.

---

## Java en esta rama

Esta rama usa **OpenJDK 17**, no Temurin.

Cuando el usuario selecciona instalar Java, el script instala:

```bash
openjdk-17-jdk-headless
```

El archivo `idempiereEnv.properties` se genera con esta ruta fija:

```properties
JAVA_HOME=/usr/lib/jvm/java-17-openjdk-amd64
```

Si el sistema utiliza una ruta diferente para Java, revisa y ajusta `JAVA_HOME` antes de ejecutar iDempiere en produccion.

---

## Estructura esperada de instalacion

Por defecto, el script instala iDempiere en una ruta como:

```bash
/opt/<carpeta>/<puerto>_<entorno>
```

Ejemplo:

```bash
/opt/sas/80_idempiere
```

Tambien crea un servicio con un nombre como:

```bash
80_idempiere
```

---

## Ejemplo de ejecucion local

Si ya tienes el repositorio clonado y estas en esta rama:

```bash
sudo bash provision.sh
```

El instalador solicitara los parametros, mostrara un resumen y luego continuara con la instalacion.

---

## Que configura en PostgreSQL

Si PostgreSQL 15 esta presente, el script:

- Reemplaza `pg_hba.conf`.
- Configura autenticacion `md5` para conexiones locales.
- Intenta asignar la clave `postgres` al usuario `postgres`.
- Habilita y reinicia el servicio PostgreSQL.

---

## Servicio generado

Al finalizar, el script:

- Copia el script base de iDempiere a `/etc/init.d/<servicio>`.
- Ajusta la ruta de instalacion.
- Ajusta el puerto telnet interno.
- Habilita el servicio.
- Reinicia el servicio automaticamente.

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

- Usar una instalacion limpia del sistema operativo.
- Verificar que los puertos elegidos esten libres.
- Confirmar conectividad al servidor PostgreSQL si no se usa `localhost`.
- Ejecutar el script como `root` o con `sudo`.
- Revisar los logs si algun paso falla.

---

## Solucion de problemas

### Java no esta instalado o no se encuentra

Verifica que `openjdk-17-jdk-headless` este instalado y que `java` este disponible en el `PATH`:

```bash
java -version
```

### El servicio no inicia

Revisa el estado del servicio y los logs:

```bash
systemctl status <servicio>
journalctl -u <servicio> -xe
```

### PostgreSQL no conecta

Verifica el host configurado, `pg_hba.conf`, la clave del usuario y el estado del servicio PostgreSQL.

---

## Flujo recomendado

1. Entra a la rama que necesitas.
2. Copia el comando de instalacion de esa rama.
3. Ejecutalo en el servidor.
4. Completa los parametros solicitados.
5. Espera la instalacion automatica.
6. Verifica que el servicio haya quedado iniciado.

---

## Notas

- El comportamiento puede variar segun la rama usada.
- Se recomienda mantener una rama por version, arquitectura o variante de sistema operativo para simplificar soporte y mantenimiento.
- La rama `12-x86Debian` usa Temurin 17; esta rama usa OpenJDK 17.

---

## Contribuidores

- [Josian Ascanio](https://github.com/josianascanio)
- [Carlo Gonzalez](https://github.com/Carl0gonzalez)
