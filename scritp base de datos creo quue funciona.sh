#!/bin/bash
######################################
#  Script que instala el centro de bases de datos
#  (MariaDB + la API que conecta con SaltStack y UrBackup)
#  Es DESATENDIDO: no pregunta nada, se ejecuta de una vez
###########  IDEMPOTENTE (se puede repetir sin problema) ##########
######################################
##==================================##



# no interactivo 🤫
export DEBIAN_FRONTEND=noninteractive


######## VARIABLES  #############
DB_NAME="${DB_NAME:-datacenter}"          # nombre de la base de datos
DB_USER="${DB_USER:-dcapi}"               # usuario que usara la API
API_DIR="${API_DIR:-/opt/dcapi}"          # carpeta donde queda la API
API_PORT="${API_PORT:-8000}"              # puerto de la API
RED_PERMITIDA="${RED_PERMITIDA:-192.168.12.0/24}"   # red que puede entrar a la API

# datos de Salt y UrBackup (si no se ponen quedan en "cambiar" y se editan despues)
SALT_URL="${SALT_URL:-https://127.0.0.1:8080}"
SALT_USER="${SALT_USER:-saltapi}"
SALT_PASS="${SALT_PASS:-cambiar}"
URBACKUP_URL="${URBACKUP_URL:-http://127.0.0.1:55414/x}"
URBACKUP_USER="${URBACKUP_USER:-admin}"
URBACKUP_PASS="${URBACKUP_PASS:-cambiar}"

# carpeta donde esta este script (para encontrar api_datacenter.py)
CARPETA_SCRIPT="$(cd "$(dirname "$0")" && pwd)"
LOG="/var/log/setup_datacenter_db.log"                  # aqui se guarda todo lo que pasa
CREDENCIALES="/root/datacenter_credenciales.txt"        # aqui quedan las claves


# REVISAR QUE TODO ESTE BIEN ANTES DE EMPEZAR 
# Tiene que ser root porque instala cosas
if [ "$EUID" -ne 0 ]; then
    echo "Ejecute este script como root: sudo bash $0"
    exit 1
fi

# Tiene que estar el archivo de la API junto al script
if [ ! -f "$CARPETA_SCRIPT/api_datacenter.py" ]; then
    echo "ERROR: falta api_datacenter.py en la misma carpeta que este script ($CARPETA_SCRIPT)"
    exit 1
fi

# Todo lo que salga en pantalla tambien se guarda en un archivo (log) 📝
exec > >(tee -a "$LOG") 2>&1
echo "===== Inicio: $(date '+%F %T') ====="

# Funcion chiquita para leer un valor del archivo .env
# (sirve para no cambiar las claves si el script se corre otra vez)
leer_env() { grep -s "^$1=" "$API_DIR/.env" | head -n1 | cut -d= -f2- || true; }


# INSTALAR LOS PAQUETES 
echo "[1/6] Instalando paquetes..."
apt-get update -y
# mariadb = la base de datos, python = para la API, curl = para probar, openssl = para claves
apt-get install -y mariadb-server python3 python3-venv python3-pip curl openssl
# que MariaDB arranque sola con el sistema y la prendemos ya
systemctl enable --now mariadb

# CREAR LAS CLAVES 
echo "Preparando crontraseñas"
mkdir -p "$API_DIR"

# si ya habia una clave se queda la misma, si no se crea una al azar
DB_PASS="$(leer_env DB_PASS)"
[ -z "$DB_PASS" ] && DB_PASS="$(openssl rand -hex 12)"
API_KEY="$(leer_env API_KEY)"
[ -z "$API_KEY" ] && API_KEY="$(openssl rand -hex 24)"


#4 CREAR LA BASE DE DATOS Y LAS TABLAS 
echo "Creando base de datos y tablas"
mysql <<SQL
CREATE DATABASE IF NOT EXISTS ${DB_NAME} CHARACTER SET utf8mb4;
USE ${DB_NAME};

-- tabla 1: los servidores del centro de datos
CREATE TABLE IF NOT EXISTS nodos (
  id INT AUTO_INCREMENT PRIMARY KEY,
  nombre VARCHAR(64) NOT NULL UNIQUE,
  ip VARCHAR(45) NOT NULL,
  rol VARCHAR(32) NOT NULL,
  salt_minion_id VARCHAR(64),
  urbackup_client VARCHAR(64),
  creado TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

-- tabla 2: RESPALDOS DE SEGURIDAD (los de UrBackup)
CREATE TABLE IF NOT EXISTS respaldos (
  id INT AUTO_INCREMENT PRIMARY KEY,
  cliente VARCHAR(64) NOT NULL,
  tipo VARCHAR(16) NOT NULL,
  estado VARCHAR(16) NOT NULL,
  ruta_destino VARCHAR(255) NULL,
  tamano_mb BIGINT NULL,
  solicitado TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
  finalizado TIMESTAMP NULL,
  INDEX idx_respaldos_cliente (cliente)
);

-- tabla 3: ALERTAS Y MONITOREO (las que manda Graylog o Salt)
CREATE TABLE IF NOT EXISTS alertas (
  id INT AUTO_INCREMENT PRIMARY KEY,
  fuente VARCHAR(16) NOT NULL DEFAULT 'graylog',
  nivel VARCHAR(16) NOT NULL DEFAULT 'info',
  nodo VARCHAR(64) NULL,
  mensaje TEXT NOT NULL,
  recibido TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
  INDEX idx_alertas_nodo (nodo)
);

-- tabla 4: 
CREATE TABLE IF NOT EXISTS eventos (
  id INT AUTO_INCREMENT PRIMARY KEY,
  origen VARCHAR(16) NOT NULL,
  accion VARCHAR(64) NOT NULL,
  detalle TEXT,
  ok BOOLEAN DEFAULT TRUE,
  fecha TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

-- usuario para la API (solo puede leer y escribir datos, nada mas)
CREATE USER IF NOT EXISTS '${DB_USER}'@'localhost' IDENTIFIED BY '${DB_PASS}';
ALTER USER '${DB_USER}'@'localhost' IDENTIFIED BY '${DB_PASS}';
GRANT SELECT, INSERT, UPDATE, DELETE ON ${DB_NAME}.* TO '${DB_USER}'@'localhost';
FLUSH PRIVILEGES;
SQL


# INSTALAR LA API 
echo " Instalando la API..."
# copiamos la API a su carpeta
cp "$CARPETA_SCRIPT/api_datacenter.py" "$API_DIR/api_datacenter.py"

# entorno virtual de python (para no mezclar con el del sistema)
[ -d "$API_DIR/venv" ] || python3 -m venv "$API_DIR/venv"
"$API_DIR/venv/bin/pip" install --quiet fastapi uvicorn pymysql requests \
    urbackup-server-web-api-wrapper

# archivo .env con la configuracion (solo se crea la primera vez)
if [ ! -f "$API_DIR/.env" ]; then
    umask 077     # para que solo root pueda leerlo
    cat > "$API_DIR/.env" <<ENV
DB_HOST=127.0.0.1
DB_USER=${DB_USER}
DB_PASS=${DB_PASS}
DB_NAME=${DB_NAME}
SALT_URL=${SALT_URL}
SALT_USER=${SALT_USER}
SALT_PASS=${SALT_PASS}
SALT_EAUTH=pam
URBACKUP_URL=${URBACKUP_URL}
URBACKUP_USER=${URBACKUP_USER}
URBACKUP_PASS=${URBACKUP_PASS}
API_KEY=${API_KEY}
ENV
    echo "Archivo $API_DIR/.env creado."
else
    echo "Ya existia $API_DIR/.env, no se toca."
fi
chmod 600 "$API_DIR/.env"

# servicio para que la API quede prendida siempre y arranque sola
cat > /etc/systemd/system/dcapi.service <<UNIT
[Unit]
Description=API Centro de Datos
After=network.target mariadb.service

[Service]
WorkingDirectory=${API_DIR}
EnvironmentFile=${API_DIR}/.env
ExecStart=${API_DIR}/venv/bin/uvicorn api_datacenter:app --host 0.0.0.0 --port ${API_PORT}
Restart=always

[Install]
WantedBy=multi-user.target
UNIT
systemctl daemon-reload
systemctl enable dcapi
systemctl restart dcapi


# FIREWALL (solo agrega UNA regla, no borra nada, asi no perdemos el SSH) 
echo " Abriendo el puerto ${API_PORT} solo a ${RED_PERMITIDA}..."
if command -v ufw >/dev/null 2>&1 && ufw status | grep -q "Status: active"; then
    # si UFW esta prendido usamos UFW
    ufw allow from "$RED_PERMITIDA" to any port "$API_PORT" proto tcp comment 'API Centro de Datos'
else
    # si no, iptables. El -C revisa si la regla ya existe para no repetirla
    if ! iptables -C INPUT -p tcp -s "$RED_PERMITIDA" --dport "$API_PORT" -j ACCEPT 2>/dev/null; then
        iptables -I INPUT -p tcp -s "$RED_PERMITIDA" --dport "$API_PORT" -j ACCEPT
    fi
fi


# VERIFICAR QUE TODO FUNCIONE 
echo "[6/6] Verificando..."
# la API tarda unos segunditos en arrancar, asi que probamos hasta 15 veces
RESPUESTA=""
for i in $(seq 1 15); do
    RESPUESTA="$(curl -s "http://127.0.0.1:${API_PORT}/salud" || true)"
    [ -n "$RESPUESTA" ] && break
    sleep 1
done
echo "MariaDB: $(systemctl is-active mariadb)   API: $(systemctl is-active dcapi)"
echo "Respuesta de /salud: ${RESPUESTA:-sin respuesta (revise: journalctl -u dcapi -n 30)}"


# GUARDAR LAS CLAVES PARA EL EQUIPO 
umask 077
cat > "$CREDENCIALES" <<RESUMEN
Centro de Bases de Datos - claves (solo root las puede ver)
Base de datos : ${DB_NAME}
Usuario BD    : ${DB_USER}
Contraseña BD : ${DB_PASS}
API KEY       : ${API_KEY}
URL API       : http://IP_DEL_SERVIDOR:${API_PORT}/docs
Configuracion : ${API_DIR}/.env
RESUMEN

echo
echo "Listo, las claves quedaron en $CREDENCIALES"
# aviso si todavia no se pusieron las claves de Salt y UrBackup
if [ "$SALT_PASS" = "cambiar" ] || [ "$URBACKUP_PASS" = "cambiar" ]; then
    echo "OJO: faltan las claves de Salt/UrBackup. Edite $API_DIR/.env y luego: systemctl restart dcapi"
fi
echo "===== Fin: $(date '+%F %T') ====="
echo "Finalizado "
