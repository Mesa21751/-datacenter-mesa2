#!/bin/bash

set -euo pipefail

#============================================#
# Pasarela de red con DHCP y filtrado con DNSMASQ
#  Reglas de firewall
# HA Keepalived
# Autores: Mesa2
#============================================#

ROJO='\e[31m'
VERDE='\e[32m'
AMARILLO='\e[33m'
AZUL='\e[34m'
NEGRITA='\e[1m'
FINAL='\e[0m'

export DEBIAN_FRONTEND=noninteractive

#Autenticación de root
if [ "$(id -u)" -ne 0 ]; then
   echo -e "${ROJO}${NEGRITA}Este script debe ejecutarse como root${FINAL}"
   exit 1
else
  echo -e "${VERDE}${NEGRITA}Puedes continuar...${FINAL}"
  sleep 2
fi

# Actualizamos repositorios
echo -e "${AMARILLO}Actualizando los repositorios...${FINAL}"
apt update 2>/dev/null || true
apt upgrade -y 2>/dev/null || true
apt install yad -y 2>/dev/null || true
echo -e "${VERDE}Repositorios actualizados...${FINAL}"
sleep 1

#Configuramos netpla#
echo -e "${AZUL}${NEGRITA}CONFIGURAMOS NETPLAN 🌐 ${FINAL}"

cd /etc/netplan
cat << 'EOF' > 99-pasarela.yaml 
network:
  version: 2
  renderer: networkd
  ethernets:
    enp0s31f6:
      dhcp4: false
      addresses: [192.168.12.1/24]
EOF

sleep 2

echo -e "${AMARILLO}${NEGRITA}APLICANDO PERMISOS Y CONFIGURACIONES ⚙️ ${FINAL}"
chmod -R 600 /etc/netplan*
netplan apply
sleep 2

echo -e "${AMARILLO}${NEGRITA}REINICIANDO SERVICO DE RED 🛜 ${FINAL}"
systemctl restart systemd-networkd
sleep 2

#Habilitando el reenvio de paquetes
echo -e "${AZUL}${NEGRITA} HABILITANDO EL REENVIO DE PAQUTES (IP FORWARDING) 📦${FINAL}"
sed -i 's/#net.ipv4.ip_forward=1/net.ipv4.ip_forward=1/' /etc/sysctl.conf
sysctl -p
sleep 2

#Habilitando el reenvio de paquetes
echo -e "${AZUL}${NEGRITA} INSTALAMOS ISC-DHCP-SERVER${FINAL}"
apt install isc-dhcp-server -y >& /dev/null
sleep 2

echo -e "${AMARILLO}${NEGRITA}CONFIGURANDO EL SERVIDOR DHCP ${FINAL}"
cat << 'EOF' > /etc/dhcp/dhcpd.conf
ddns-update-style none;
option domain-name-servers 8.8.8.8;
default-lease-time 600;
max-lease-time 7200;
authoritative;
log-facility local7;

subnet 192.168.12.0 netmask 255.255.255.0 {
range 192.168.12.2 192.168.12.254;
option routers 192.168.12.1;
}
EOF

echo -e "${AMARILLO}${NEGRITA}ASIGNANDO LA INTERFAZ DE RED AL SERVIDOR DHCP ${FINAL}"
ARCHIVO="/etc/default/isc-dhcp-server"
if [ -f "$ARCHIVO" ]; then 
     sed -i 's/^INTERFACESv4=.*/INTERFACESv4="enp0s31f6"/' "$ARCHIVO"
else 
     echo 'INTERFACESv4="enp0s31f6" ' > "$ARCHIVO"
fi

echo -e "${AMARILLO}${NEGRITA}REINICIANDO ISC-DHCP-SERVER ${FINAL}"
systemctl daemon-reload
systemctl restart isc-dhcp-server
systemctl enable isc-dhcp-server

echo -e "${AZUL}${NEGRITA} SOLUCIONANDO  PUERTO 53${FINAL}"
# 1. Revertir la inmutailidad a la fuerza
chattr -i /etc/resolv.conf 2>/dev/null || true

#2. Deshabilitar systemd-resolved
systemctl stop systemd-resolved 2>/dev/null || true
systemctl mask systemd-resolved 2>/dev/null || true

#3. Reconfigurar /etc/resolv.conf
rm -f /etc/resolv.conf 2>/dev/null || true
#4. Recrear el archivo con el nuevo contenido

cat << 'EOF' > /etc/resolv.conf 
nameserver 1.1.1.3
nameserver 1.0.0.3
options trust-ad
EOF

#5. Aplicar inmutabilidad de nuevo
chattr +i /etc/resolv.conf 2>/dev/null || true

sleep 5

echo -e "${AZUL}${NEGRITA} INSTALANDO Y DETENIENDO TEMPOTALMENTE DNSMASQ ${FINAL}"
apt install -y dnsmasq 2>/dev/null
systemctl stop dnsmasq 2>/dev/null || true

echo -e "${AMARILLO}${NEGRITA} CONFIGURANDO DNSMASQ Y DOMINIOS DE BLOQUEO ${FINAL}"
cat << 'EOF' > /etc/dnsmasq.conf
# Escuchar en la interfaz de la red local
interface=enp0s31f6
listen-address=127.0.0.1,192.168.12.1
bind-interfaces

# No ofrecer DHCP desde DNSMASQ en la interfaz local
no-dhcp-interface=enp0s31f6

#Bloquear dominios
address=/facebook.com/0.0.0.0
address=/tiktok.com/0.0.0.0
address=/instagram.com/0.0.0.0
address=/messenger.com/0.0.0.0
address=/pornhub.com/0.0.0.0
address=/xvideos.com/0.0.0.0
address=/xnxx.com/0.0.0.0
address=/redtube.com/0.0.0.0
address=/youporn.com/0.0.0.0
EOF

echo -e "${AMARILLO}${NEGRITA} HABILITAMOS E INICIAMOS SERVICIO ${FINAL}"
systemctl enable dnsmasq
systemctl start dnsmasq

echo -e "${AZUL}${NEGRITA} INSTALANDO IPTABLES-PERSISTENT ${FINAL}"
#Para evitar promts interactivos durante la instalación
echo "iptables-persistent iptables-persistent/autosave_v4 boolean true" | debconf-set-selections
echo "iptables-persistent iptables-persistent/autosave_v6 boolean true" | debconf-set-selections
apt install iptables-persistent -y 

echo -e "${AMARILLO}${NEGRITA} CONFIGURANDO LAS REGLAS IPTABLES ${FINAL}"

#1. Redirigir el tráfico DNS UDP (puerto 53) hacia el dnsmasq local
iptables -t nat -A PREROUTING -s 192.168.12.0/24 -p udp --dport 53 ! -d 192.168.12.1 -j REDIRECT --to-ports 53

#2. Redirigir el tráfico DNS TCP (puerto 53) hacia el dnsmasq local
iptables -t nat -A PREROUTING -s 192.168.12.0/24 -p tcp --dport 53 ! -d 192.168.12.1 -j REDIRECT --to-ports 53

#3. Enmascaramiento (NAT) para dar salida a internet a la red interna
iptables -t  nat -A POSTROUTING -o wlp2s0 -j MASQUERADE

echo -e "${AMARILLO}${NEGRITA} GUARDANDO REGLAS ${FINAL}"
netfilter-persistent save

echo -e "${AZUL}${NEGRITA} DESPLEGANDO INTERFAZ ${FINAL}"
FORM_DATA=$(yad --form --title="TIPO DE NODO" \
--text="Selecciona la opción que desees: " \
--field="Selecciona rol para este nodo:CB" "MASTER!BACKUP" \
--button="Aceptar:0"     --button="Cancelar:1" )

#Verificar cancelación por el usuario
if [[ -z "$FORM_DATA" ]]; then
     echo -e "${ROJO}${NEGRITA} CANCELACIÓN POR EL USUARIO ${FINAL}"
    exit 1
fi

#Extrayendo rol
ROL=$(echo "$FORM_DATA" | cut -d '|' -f1)

echo -e "${VERDE}HAS SELECCIONADO EL ROL: ${NEGRITA}$ROL ${FINAL}"


echo -e "${AZUL}${NEGRITA} INSTALANDO KEEPALIVED ${FINAL}"
apt install keepalived -y >& /dev/null

echo -e "${AMARILLO}${NEGRITA} CONFIGURANDO KEEPALIVED ${FINAL}"

mkdir -p /etc/keepalived

#Evaluar el rol para asiganar la prioridad correspondiente
case  "$ROL" in
   "MASTER" )
          PRIORIDAD=150
          ;;
    "BACKUP" )
          PRIORIDAD=100
          ;;
       *)
             echo -e "${ROJO}${NEGRITA} ROL NO RECONOCIDO. ${FINAL}"
    exit 1
    ;;
esac

#SCRIPT REVISIÓN DE INTERNET POR LA INTERFAZ WAN#
cat << 'EOF' > /etc/keepalived/internet.sh
#!/bin/bash
ping -c 1 -W 2 -I wlp2s0 8.8.8.8 >/dev/null>&1
EOF
chmod +x /etc/keepalived/internet.sh

#SCRIPT NOTIFICACIONES
cat << 'EOF' > /etc/keepalived/cambiar_estado.sh
#!/bin/bash
      activar_servicios() {
          systctl -w net.ipv4.ip_forward=1 > /dev/null
          systemctl start dnsmasq 2>/dev/null || true
      }
      
      desactivar_servicios() {
         systectl -w net.ipv4.ip_forward=0 > /dev/null
         systemctl stop dnsmasq 2>/dev/null || true
      }
      
      detener_dns() {
         systemctl stop dnsmasq 2>/dev/null || true
      }

ESTADO="$1"
 
case "$ESTADO" in
master) activar_servicios ;;
backup) desactivar_servicios ;;
cliente) detener_dns ;;
esac
EOF
chmod +x /etc/keepalived/cambiar_estado.sh

#Creamos el archivo de configuración#
cat << EOF > /etc/keepalived/keepalived.conf
global_defs {
virtual_router_id PASARELA_$(echo $ROL)
}

vrrp_script internet {
script "/etc/keepalived/internet.sh"
interval 3
timeout 2
fall 2
rise 2
weight -60
}

vrrp_instance VI_PASARELA {
state $ROL
interface enp0s31f6
virtual_router_id 51
priority  $PRIORIDAD
advert_int 1
use_vmac

authentication {
auth_type PASS
auth_pass 5117
}
virtual_ipaddress {
    192.168.50.1 dev vrrp.51
   }    

track_script {
    internet
    }   
 
 notify_master "/etc/keepalived/cambiar_estado.sh master"
 notify_backup "/etc/keepalived/cambiar_estado.sh backup"
}
EOF

echo -e "${AMARILLO}${NEGRITA} INICIAMOS Y ARRANCAMOS EL SERVICIO ${FINAL}"
systemctl daemon-reload
systemctl enable keepalived
systemctl start keepalived 

echo -e "${VERDE}${NEGRITA} FIN DEL SCRIPT... ${FINAL}"
