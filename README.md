# iDempiere Provisioning Script

Script de provisión para instalar **iDempiere** de forma rápida usando un único comando.

Este repositorio utiliza **ramas** para separar versiones y arquitecturas (por ejemplo: `12`, `12-arm`, `10`, etc.).

---

## 🚀 Instalación rápida (una sola línea)

Ejecuta el instalador directamente desde GitHub:

```bash
curl -s https://raw.githubusercontent.com/josianascanio/idempiere/HEAD/provision.sh | bash
```

### ¿Qué significa `HEAD`?
`HEAD` se adapta automáticamente a la **rama actual** desde donde estés viendo el README.

- Si estás en la rama `12`, descargará el script de `12`.
- Si estás en la rama `12-arm`, descargará el script de `12-arm`.

---

## 🌿 Elegir una rama específica

Si quieres usar una versión concreta, solo cambia la rama en la URL.

### Ejemplo (rama 12-arm)

```bash
curl -s https://raw.githubusercontent.com/josianascanio/idempiere/12-arm/provision.sh | bash
```

---

## 🧭 Flujo recomendado

1. Entra a la rama que necesitas (`12`, `12-arm`, `10`, etc.).
2. Copia el comando de instalación.
3. Ejecútalo en tu servidor.
4. Sigue los pasos del instalador.

---

## ⚠️ Requisitos

- Ubuntu Server / Debian
- Acceso sudo o root
- Conexión a internet

---

## 📝 Nota

El instalador descarga y ejecuta el script más reciente disponible en la rama seleccionada.
