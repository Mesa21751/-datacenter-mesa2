#!/bin/bash

set -euo pipefail

# ==========================================
# Script de automatización para UrBackup 
# Para clientes o servidor
# ==========================================

if [ "$EUID" -ne 0 ]; then
    echo "Debes ejecutar este script como root"
    exit 1
fi

clear
echo "=========================================="
echo "    Instalación automática de UrBackup"
echo "=========================================="
echo "Selecciona una opción:"
echo "  1) Servidor UrBackup"
echo "  2) Cliente UrBackup"
read -p "Seleccione una opción (1 o 2): " opcion

if [ "$opcion" -eq 1 ]; then
    echo "Iniciando configuración del servidor"
    
    #Configurar repositorio solo si no existe
    if [ ! -f /etc/apt/sources.list.d/home_uroni.list ]; then
        echo "Añadiendo repositorio de UrBackup"
        apt update -y
        mkdir -p /etc/apt/keyrings
        wget -nv https://download.opensuse.org/repositories/home:/uroni/xUbuntu_24.04/Release.key -O /etc/apt/keyrings/home_uroni.asc
        echo 'deb [signed-by=/etc/apt/keyrings/home_uroni.asc] http://download.opensuse.org/repositories/home:/uroni/xUbuntu_24.04/ /' | tee /etc/apt/sources.list.d/home_uroni.list > /dev/null
        apt update -y
    else
        echo "El repositorio del servidor ya está configurado :D"
    fi

    if ! dpkg -l | grep -q "^ii\s\+urbackup-server"; then
        echo "Instalando UrBackup Server..."
        apt install -y urbackup-server
    else
        echo "El paquete de 'urbackup-server' ya se encuentra instalado."
    fi

    systemctl start urbackupsrv
    systemctl enable urbackupsrv > /dev/null 2>&1

    echo "==================================================================="
    echo "Se instalo correctamente"
    echo "Puedes accede a la interfaz web en: http://tu_ip:55414"
    echo "==================================================================="

elif [ "$opcion" -eq 2 ]; then
    echo "Iniciando configuración del cliente"
   
    if ! command -v urbackupclientctl &> /dev/null; then
        echo "Descargando e instalando el cliente de UrBackup"
        apt update -y
        TF=$(mktemp) && wget "https://hndl.urbackup.org/Client/2.5.25/UrBackup%20Client%20Linux%202.5.25.sh" -O "$TF" && sh "$TF"
        rm -f "$TF"
    else
        echo "El cliente de UrBackup ya se encuentra instalado"
    fi

    systemctl start urbackupclientbackend
    systemctl enable urbackupclientbackend > /dev/null 2>&1

    echo "Verificando directorio de respaldo (/var/log)"
    if ! urbackupclientctl list-backupdirs | grep -q "/var/log"; then
        urbackupclientctl add-backupdir --path /var/log
        echo "Directorio /var/log añadido exitosamente"
    else
        echo "El directorio /var/log ya estaba agregado"
    fi

    echo "Verificando configuración del Modo Interne"
    
    IP_SERVIDOR="192.168.12.5"
    PUERTO_SERVIDOR="55415"
    PASS_SERVIDOR="1751"

    check_and_set() {
        local key=$1
        local expected=$2
        local current
        current=$(urbackupclientctl get-settings -k "$key" 2>/dev/null)
        if [ "$current" != "$expected" ]; then
            urbackupclientctl set-settings -k "$key" -v "$expected"
            echo "Parámetro '$key' actualizado a: $expected"
        fi
    }

    check_and_set "internet_mode_enabled" "true"
    check_and_set "internet_server" "$IP_SERVIDOR"
    check_and_set "internet_server_port" "$PUERTO_SERVIDOR"
    check_and_set "internet_server_password" "$PASS_SERVIDOR"

    systemctl restart urbackupclientbackend

    echo "================================================="
    echo "             Cliente configurado                 "
    echo "================================================="

else
    echo "Opción no válida, ejecuta el script nuevamente y selecciona opción"
    exit 1
fi
