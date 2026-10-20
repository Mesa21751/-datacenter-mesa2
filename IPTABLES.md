Mesa 2: Guía de Configuración de iptables-nft

Nos conviene iptables-nft, la versión que Ubuntu Server 24.04 ya trae por defecto: usa nftables por debajo, funciona bien en servidores normales (físicos) y no hay que instalar nada raro. Esta guía explica cada paso con su comando, para las 5 máquinas de la red 192.168.50.0/24.

Cuál iptables nos conviene

En Ubuntu 24.04 existen tres opciones. Elegimos la primera.

Opción | Qué es | ¿Nos conviene?
iptables-nft | Los mismos comandos iptables, pero guarda las reglas en nftables. Es el predeterminado de Ubuntu 24.04. | Sí. Es lo que usa el sistema y funciona bien en servidores normales (físicos).
iptables-legacy | La versión antigua, con su propio sistema de reglas. | No. Si se mezcla con la anterior, las reglas quedan separadas y se confunden.
nftables (nft) | El sistema nuevo, con otra forma de escribir las reglas. | No para este proyecto. Hay que aprender otra sintaxis y no ganamos nada.

Regla de oro: usar solo una versión en todas las máquinas y no usar ufw al mismo tiempo.

Paso 1 y 2: Verificar la versión e instalar

Ver qué versión de iptables está activa (debe decir nf_tables):
iptables --version
Salida esperada: iptables v1.8.10 (nf_tables)


Si dijera (legacy), cambiarla a nft:
sudo update-alternatives --set iptables /usr/sbin/iptables-nft
sudo update-alternatives --set ip6tables /usr/sbin/ip6tables-nft


Instalar iptables y el paquete que guarda las reglas al reiniciar (responder sí si pregunta guardar las reglas actuales):
sudo apt update
sudo apt install -y iptables iptables-persistent


Comprobar que ufw no esté activo (debe decir inactive):
sudo ufw status
Si estuviera activo, desactivar con: sudo ufw disable


Paso 3: Reglas base (en las 5 máquinas)

Estas reglas bloquean todo lo que entra, menos lo necesario. El orden importa: primero se permite, y la regla DROP va al final para no quedarnos sin acceso por SSH.

Permitir el tráfico interno de la propia máquina:
sudo iptables -A INPUT -i lo -j ACCEPT


Permitir las respuestas a conexiones que la máquina ya abrió:
sudo iptables -A INPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT


Permitir SSH solo desde la red del proyecto:
sudo iptables -A INPUT -p tcp --dport 22 -s 192.168.50.0/24 -j ACCEPT


Permitir ping para probar la red:
sudo iptables -A INPUT -p icmp -j ACCEPT


Bloquear todo lo demás que entre:
sudo iptables -P INPUT DROP


Paso 4: Reglas específicas de cada máquina

Después de las reglas base, cada máquina abre solo los puertos de su servicio. La base de datos usa MariaDB en el puerto 3306.

Máquina: Nodo-cerebro y Nodo-backup

Puerto: 4505 y 4506 TCP

Para qué: Salt (las demás máquinas se conectan aquí)

Comando: sudo iptables -A INPUT -p tcp -m multiport --dports 4505,4506 -s 192.168.50.0/24 -j ACCEPT

Máquina: Nodo-cerebro y Nodo-backup

Puerto: 9000 TCP

Para qué: Página web de Graylog

Comando: sudo iptables -A INPUT -p tcp --dport 9000 -s 192.168.50.0/24 -j ACCEPT

Máquina: Nodo-cerebro y Nodo-backup

Puerto: 12201 TCP y 1514 UDP

Para qué: Graylog recibe los registros (logs)

Comando: sudo iptables -A INPUT -p tcp --dport 12201 -s 192.168.50.0/24 -j ACCEPT y sudo iptables -A INPUT -p udp --dport 1514 -s 192.168.50.0/24 -j ACCEPT

Máquina: Nodo-cerebro (dnsmasq)

Puerto: 67 UDP y 53 UDP/TCP

Para qué: dnsmasq: DHCP y DNS

Comando: sudo iptables -A INPUT -p udp --dport 67 -j ACCEPT, sudo iptables -A INPUT -p udp --dport 53 -s 192.168.50.0/24 -j ACCEPT y sudo iptables -A INPUT -p tcp --dport 53 -s 192.168.50.0/24 -j ACCEPT

Máquina: Nodo-datos

Puerto: 3306 TCP

Para qué: Base de datos (solo cerebro y backup)

Comando: sudo iptables -A INPUT -p tcp --dport 3306 -s 192.168.50.10 -j ACCEPT y sudo iptables -A INPUT -p tcp --dport 3306 -s 192.168.50.11 -j ACCEPT

Máquina: Nodo-voip

Puerto: 5060 UDP

Para qué: Asterisk: llamadas ext. 201 y 202

Comando: sudo iptables -A INPUT -p udp --dport 5060 -s 192.168.50.0/24 -j ACCEPT

Máquina: Nodo-voip

Puerto: 10000:20000 UDP

Para qué: Audio de las llamadas (RTP)

Comando: sudo iptables -A INPUT -p udp --dport 10000:20000 -s 192.168.50.0/24 -j ACCEPT

Máquina: Nodo-respaldos

Puerto: 55414 TCP

Para qué: Web UI de UrBackup

Comando: sudo iptables -A INPUT -p tcp --dport 55414 -s 192.168.50.0/24 -j ACCEPT

Máquina: Nodo-respaldos

Puerto: 35621:35623 TCP/UDP

Para qué: UrBackup comunicación general

Comando: sudo iptables -A INPUT -p tcp -m multiport --dports 35621,35623 -s 192.168.50.0/24 -j ACCEPT y sudo iptables -A INPUT -p udp -m multiport --dports 35622,35623 -s 192.168.50.0/24 -j ACCEPT

Nota para clientes UrBackup: En las demás máquinas que actúan como cliente, abrir los puertos 35621 TCP y 35622 UDP con los mismos comandos.

Filtrado con dnsmasq
El servicio DHCP no usa filtro por IP de origen porque los clientes no tienen una IP asignada aún. El filtrado se configura directamente en /etc/dnsmasq.conf agregando una línea por nodo:
dhcp-host=MAC,IP,nombre
dhcp-ignore=tag:!known
Esto asegura que solo las 5 máquinas conocidas reciban dirección IP fija.

Paso 5 y 6: Guardar, probar y revertir

Guardar reglas para persistencia tras reinicio:
sudo netfilter-persistent save


Listar reglas activas con numeración de línea:
sudo iptables -L -n -v --line-numbers


Probar conectividad hacia un puerto desde otro nodo:
nc -zv 192.168.50.10 4505


Confirmar persistencia tras un reinicio:
sudo reboot
sudo iptables -L -n


En caso de emergencia (Restablecer)
Si te quedas sin acceso o necesitas reiniciar la tabla de reglas a cero:
sudo iptables -P INPUT ACCEPT
sudo iptables -F

Para borrar una sola regla por número (ejemplo: regla #3 en INPUT):
sudo iptables -D INPUT 3

