# iDempiere Provisioning Script

Script de provisión para instalar **iDempiere** de forma rápida usando un único comando.

Este repositorio utiliza **ramas** para separar versiones y arquitecturas (por ejemplo: `12`, `12-arm`, `10`, etc.).

---

## 🚀 Instalación rápida (una sola línea)

Ejecuta el instalador directamente desde GitHub reemplazando el nombre de la rama en <NOMBRE-DE-LA-RAMA>:

```bash
sudo bash -c 'bash <(curl -fsSL https://raw.githubusercontent.com/josianascanio/idempiere/<NOMBRE-DE-LA-RAMA>/provision.sh)'
```

### Ejemplo (rama 12-arm)

```bash
sudo bash -c 'bash <(curl -fsSL https://raw.githubusercontent.com/josianascanio/idempiere/12-arm/provision.sh)'
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
