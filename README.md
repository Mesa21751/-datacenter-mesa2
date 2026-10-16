# Data Center - Mesa 2
Proyecto de 5 nodos con automatización y monitoreo - Complejo Educativo Residencial Altavista

## 📃 Descripción
Somos estudiantes de 3er año de bachillerato técnico vocacional en Infraestructura Tecnológica y Servicios Informáticos (ITSI). Este proyecto implementa un mini Data Center con 5 máquinas virtuales con redundancia, automatización y monitoreo.

## 🌐 Arquitectura de 5 Nodos

- **Nodo Master:** Salt Master + Zabbix Server  (Control y monitoreo)
- **Nodo Backup:** Respaldo de la Master para redundancia
- **Pasarela:** Pasarela de red con DHCP (Haciendo filtración)
- **Nodo Datos:** Bases de datos y servicios pesados 
- **Nodo Telefonía:** Asterisk (extensiones 201 y 202)
- **Nodo Respaldos:** UrBackup

## 🛠️ Stack Tecnológico
* OS: Ubuntu Server (24.04)
* Automatización: SaltStack
* Monitoreo: Zabbix
* Telefonía: Asterisk

## 🧪 Pruebas de Rendimiento y Estrés
Se realizará una breve mención de cómo validan la estabilidad con `stress` y el monitoreo en Zabbix.

## 👥​ Integrantes - Mesa 2

|Nombre                             | Roles de equipo |
| :--- | :---|
|Jordy Alexander Martínez Arevalo   | Soporte Técnico|
|Josué Abraham Reyes Salazar        | Especialista   |
|Maybelline Nohemy Méndez López     | Documentador   |
|Debora Raquel Uribe Elias          | Investigador   |
|Jenniffer Lissette Orellana Linares| Líder Técnico  |
