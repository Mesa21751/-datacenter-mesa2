#!/usr/bin/env bash
#=====================================================================
# centro_datos_setup.sh  -  Ubuntu Server 24.04   (v2)
#
# herramientas de respaldo (UrBackup) y SaltStack.
#
# Este script es idempotente y se ejecuta de manera desatendida:
# lo puedes correr las veces que quieras sin que se dañe nada.
#
# Que hace:
#   - Hace respaldos de seguridad de la base de datos (dump diario
#     de MariaDB, listo para que UrBackup lo copie).
#   - Almacena los datos de alerta que manda Graylog.
#   - Guarda lo que devuelve SaltStack (returner MySQL).
#   - Expone una API REST en PHP para guardar y consultar todo eso.
#

set -euo pipefail

# Solo root puede correrlo; en modo desatendido apt no hace preguntas.
[ "$(id -u)" -eq 0 ] || { echo "Ejecuta como root (sudo)."; exit 1; }
export DEBIAN_FRONTEND=noninteractive

# ----------------------- Variables ----------------------------------
# Aqui se definen los valores por defecto y las rutas que usa todo
# el script. Cada variable se puede cambiar desde afuera con export.
RED_PREFIJO="${RED_PREFIJO:-192.168.12}"
RED_CIDR="${RED_PREFIJO}.0/24"
BIND_ADDRESS="${BIND_ADDRESS:-0.0.0.0}"
PUERTO_API="${PUERTO_API:-8080}"
ZONA_HORARIA="${ZONA_HORARIA:-America/El_Salvador}"

DB_AUD="db_auditoria"
DB_SALT="salt"
USER_API="usr_api_centro"
USER_SALT="salt_user"

ARCHIVO_CRED="/root/.centro_datos.env"
ARCHIVO_INTEGRACION="/root/centro_datos_integracion.txt"
DIR_API="/var/www/centro-datos-api"
DIR_CFG="/etc/centro-datos"
SCRIPT_DUMP="/usr/local/sbin/backup_mariadb.sh"
DIR_DUMPS="/var/backups/mariadb"

# Revisa que los valores de entrada tengan sentido antes de usarlos.
[[ "$RED_PREFIJO" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){2}$ ]] \
  || { echo "RED_PREFIJO invalido (ejemplo: 192.168.12)"; exit 1; }
[[ "$PUERTO_API" =~ ^[0-9]{2,5}$ ]] \
  || { echo "PUERTO_API invalido"; exit 1; }
[[ "$BIND_ADDRESS" =~ ^[0-9.]+$ ]] \
  || { echo "BIND_ADDRESS invalido"; exit 1; }

# Guarda las IPs que vengan del entorno; si hay, mandan sobre las
# que quedaron guardadas de otra ejecucion.
_ENV_G="${IP_GRAYLOG:-}"; _ENV_S="${IP_SALT:-}"; _ENV_U="${IP_URBACKUP:-}"

# ----------------------- Funciones ----------------------------------
# Genera una clave aleatoria de 32 caracteres.
generar() { openssl rand -hex 16; }

# Acepta solo caracteres seguros, para que no den problemas en
# SQL, PHP ni shell.
validar() {
  [[ "$2" =~ ^[A-Za-z0-9._-]+$ ]] \
    || { echo "Valor invalido en $1 (solo letras, numeros, . _ -)"; exit 1; }
}

# Escribe un archivo solo si su contenido cambio. Deja CAMBIO=1 si lo
# reescribio, para saber cuando hay que reiniciar un servicio.
# Uso: escribir_si_cambia ARCHIVO MODO USER:GRUPO < contenido
CAMBIO=0
escribir_si_cambia() {
  local destino="$1" modo="$2" dueno="$3" tmp
  tmp="$(mktemp)"
  cat > "$tmp"
  if [ -f "$destino" ] && cmp -s "$tmp" "$destino"; then
    CAMBIO=0
    chmod "$modo" "$destino"
    chown "$dueno" "$destino"
  else
    install -m "$modo" -o "${dueno%%:*}" -g "${dueno##*:}" "$tmp" "$destino"
    CAMBIO=1
  fi
  rm -f "$tmp"
}

# ----------------------- Credenciales -------------------------------
# Aqui se cargan las claves guardadas, o se generan si es la primera
# vez. Asi, al repetir el script, las contraseñas no cambian.
# Prioridad: archivo guardado > variable de entorno > se genera una nueva
if [ -f "$ARCHIVO_CRED" ]; then
  # shellcheck disable=SC1090
  source "$ARCHIVO_CRED"
fi
IP_GRAYLOG="${_ENV_G:-${IP_GRAYLOG:-}}"
IP_SALT="${_ENV_S:-${IP_SALT:-}}"
IP_URBACKUP="${_ENV_U:-${IP_URBACKUP:-}}"
for v in IP_GRAYLOG IP_SALT IP_URBACKUP; do
  [[ -z "${!v}" || "${!v}" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]] \
    || { echo "$v invalida: ${!v}"; exit 1; }
done
: "${PASS_API_DB:=$(generar)}"
: "${PASS_SALT_DB:=$(generar)}"
: "${API_KEY:=$(generar)}"
validar PASS_API_DB "$PASS_API_DB"
validar PASS_SALT_DB "$PASS_SALT_DB"
validar API_KEY "$API_KEY"

# Guarda todo en un archivo que solo lee root (permisos 600).
(
  umask 077
  cat > "$ARCHIVO_CRED" <<EOF
PASS_API_DB='${PASS_API_DB}'
PASS_SALT_DB='${PASS_SALT_DB}'
API_KEY='${API_KEY}'
IP_GRAYLOG='${IP_GRAYLOG}'
IP_SALT='${IP_SALT}'
IP_URBACKUP='${IP_URBACKUP}'
EOF
)

# Arma la lista de quien puede entrar a la API y a MariaDB (Salt).
# Si no diste ninguna IP, deja pasar a toda la red interna.
ACCESO_API="127.0.0.1 ::1"
for ip in "$IP_GRAYLOG" "$IP_SALT" "$IP_URBACKUP"; do
  if [ -n "$ip" ] && [[ " $ACCESO_API " != *" $ip "* ]]; then
    ACCESO_API+=" $ip"
  fi
done
if [ "$ACCESO_API" = "127.0.0.1 ::1" ]; then
  ACCESO_API+=" ${RED_CIDR}"
fi
HOST_SALT="${IP_SALT:-${RED_PREFIJO}.%}"

# ----------------------- 1. Paquetes --------------------------------
# Esta parte instala MariaDB, Apache y PHP, y los deja encendidos.
echo "[1/7] Instalando paquetes..."
apt-get update -qq
apt-get install -y -qq mariadb-server mariadb-client apache2 php php-cli \
  php-mysql php-mbstring libapache2-mod-php curl openssl cron >/dev/null
systemctl enable --now mariadb apache2 >/dev/null 2>&1

# ----------------------- 2. MariaDB: configuracion ------------------
# Aqui se ajusta MariaDB: en que direccion escucha y que codificacion
# usa. Reinicia solo si algo cambio.
echo "[2/7] Configurando MariaDB..."
# El archivo 99 gana sobre 50-server.cnf, aunque Salt lo reescriba.
escribir_si_cambia /etc/mysql/mariadb.conf.d/99-centro-datos.cnf 644 root:root <<EOF
[mysqld]
bind-address = ${BIND_ADDRESS}
character-set-server = utf8mb4
collation-server = utf8mb4_unicode_ci
EOF
if [ "$CAMBIO" -eq 1 ]; then
  systemctl restart mariadb
fi

# ----------------------- 3. MariaDB: BDs y usuarios -----------------
# Esta parte limpia lo inseguro de fabrica, crea las dos bases de
# datos y los usuarios (uno para la API y otro para Salt) con sus
# permisos justos.
echo "[3/7] Creando bases de datos y usuarios..."
SQL="
-- Equivalente desatendido de mariadb-secure-installation
DROP USER IF EXISTS ''@'localhost';
DROP DATABASE IF EXISTS test;

CREATE DATABASE IF NOT EXISTS ${DB_AUD}  CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE DATABASE IF NOT EXISTS ${DB_SALT} CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;

-- Usuario de la API PHP (conexion por socket local)
CREATE USER IF NOT EXISTS '${USER_API}'@'localhost' IDENTIFIED BY '${PASS_API_DB}';
ALTER USER '${USER_API}'@'localhost' IDENTIFIED BY '${PASS_API_DB}';
GRANT SELECT, INSERT, UPDATE ON ${DB_AUD}.* TO '${USER_API}'@'localhost';
GRANT SELECT ON ${DB_SALT}.* TO '${USER_API}'@'localhost';"

# El usuario de Salt entra desde local y desde la IP del master.
for host in localhost "$HOST_SALT"; do
  SQL+="
CREATE USER IF NOT EXISTS '${USER_SALT}'@'${host}' IDENTIFIED BY '${PASS_SALT_DB}';
ALTER USER '${USER_SALT}'@'${host}' IDENTIFIED BY '${PASS_SALT_DB}';
GRANT SELECT, INSERT, UPDATE, DELETE ON ${DB_SALT}.* TO '${USER_SALT}'@'${host}';"
done
SQL+="
FLUSH PRIVILEGES;"
printf '%s\n' "$SQL" | mariadb

# Borra los accesos viejos de salt_user que ya no correspondan
# (por ejemplo, si cambiaste la IP del master).
while read -r h; do
  [ -z "$h" ] && continue
  if [ "$h" != "localhost" ] && [ "$h" != "$HOST_SALT" ]; then
    mariadb -e "DROP USER IF EXISTS '${USER_SALT}'@'${h}';"
  fi
done < <(mariadb -N -e "SELECT host FROM mysql.global_priv WHERE user='${USER_SALT}';")

# ----------------------- 4. MariaDB: tablas -------------------------
# Aqui se crean las tablas. Con IF NOT EXISTS no se pierde nada si
# ya estaban.
echo "[4/7] Creando tablas..."
mariadb "$DB_AUD" <<'SQL'
-- Equipos: inventario de maquinas, lo usan los respaldos
CREATE TABLE IF NOT EXISTS equipos (
  id             INT UNSIGNED AUTO_INCREMENT PRIMARY KEY,
  nombre         VARCHAR(100) NOT NULL,
  ip             VARCHAR(45)  NULL,
  rol            VARCHAR(30)  NULL,
  fecha_registro TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
  UNIQUE KEY uq_equipos_nombre (nombre)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- Respaldos: copias de UrBackup y dumps de MariaDB
CREATE TABLE IF NOT EXISTS respaldos (
  id              BIGINT UNSIGNED AUTO_INCREMENT PRIMARY KEY,
  equipo_id       INT UNSIGNED NOT NULL,
  origen          VARCHAR(30) NOT NULL DEFAULT 'urbackup',
  tipo            ENUM('completo','incremental','archivos','imagen') NOT NULL DEFAULT 'incremental',
  estado          ENUM('ok','advertencia','error') NOT NULL,
  inicio          DATETIME NOT NULL,
  fin             DATETIME NULL,
  tamano_bytes    BIGINT UNSIGNED NULL,
  ruta            VARCHAR(255) NULL,
  detalle         TEXT NULL,
  fecha_recepcion TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
  UNIQUE KEY uq_respaldo (equipo_id, origen, tipo, inicio),
  KEY idx_respaldos_estado (estado, inicio),
  CONSTRAINT fk_respaldos_equipo FOREIGN KEY (equipo_id)
    REFERENCES equipos(id) ON DELETE CASCADE ON UPDATE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- Alertas: las que manda Graylog (misma estructura del Paso 5.1 del manual)
CREATE TABLE IF NOT EXISTS alertas_sistema (
  id               INT AUTO_INCREMENT PRIMARY KEY,
  timestamp_evento DATETIME NOT NULL,
  origen           VARCHAR(100) NOT NULL,
  nivel_prioridad  VARCHAR(20)  NOT NULL,
  tipo_evento      VARCHAR(100) NOT NULL,
  mensaje          TEXT NOT NULL,
  raw_payload      JSON NULL,
  fecha_recepcion  TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
  KEY idx_alertas_fecha (timestamp_evento),
  KEY idx_alertas_nivel (nivel_prioridad)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;
SQL

# Tablas de SaltStack: es el esquema oficial del returner MySQL.
mariadb "$DB_SALT" <<'SQL'
CREATE TABLE IF NOT EXISTS `jids` (
  `jid`  VARCHAR(255) NOT NULL,
  `load` MEDIUMTEXT NOT NULL,
  UNIQUE KEY `jid` (`jid`)
) ENGINE=InnoDB;

CREATE TABLE IF NOT EXISTS `salt_returns` (
  `fun`        VARCHAR(50)  NOT NULL,
  `jid`        VARCHAR(255) NOT NULL,
  `return`     MEDIUMTEXT   NOT NULL,
  `id`         VARCHAR(255) NOT NULL,
  `success`    VARCHAR(10)  NOT NULL,
  `full_ret`   MEDIUMTEXT   NOT NULL,
  `alter_time` TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
  KEY `id` (`id`),
  KEY `jid` (`jid`),
  KEY `fun` (`fun`)
) ENGINE=InnoDB;

CREATE TABLE IF NOT EXISTS `salt_events` (
  `id`         BIGINT NOT NULL AUTO_INCREMENT,
  `tag`        VARCHAR(255) NOT NULL,
  `data`       MEDIUMTEXT NOT NULL,
  `alter_time` TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
  `master_id`  VARCHAR(255) NOT NULL,
  PRIMARY KEY (`id`),
  KEY `tag` (`tag`)
) ENGINE=InnoDB;
SQL

# ----------------------- 5. API en PHP ------------------------------
# Esta parte despliega la API REST en PHP: guarda su configuracion,
# escribe el codigo y la publica con Apache en su propio puerto.
echo "[5/7] Desplegando la API PHP..."
mkdir -p "$DIR_CFG" "$DIR_API"
chown root:www-data "$DIR_CFG" "$DIR_API"
chmod 750 "$DIR_CFG"

# Configuracion de la API: la base de datos, la clave y la zona horaria.
escribir_si_cambia "$DIR_CFG/api.php" 640 root:www-data <<EOF
<?php
return [
    'db_nombre'  => '${DB_AUD}',
    'db_usuario' => '${USER_API}',
    'db_clave'   => '${PASS_API_DB}',
    'api_key'    => '${API_KEY}',
    'zona'       => '${ZONA_HORARIA}',
];
EOF

# Datos para que el script de respaldo local le hable a la API.
escribir_si_cambia "$DIR_CFG/cliente.env" 600 root:root <<EOF
API_URL='http://127.0.0.1:${PUERTO_API}'
API_KEY='${API_KEY}'
EOF

# Codigo de la API. Las comillas en el heredoc evitan que Bash
# toque algo del PHP.
escribir_si_cambia "$DIR_API/index.php" 644 root:www-data <<'PHP'
<?php
declare(strict_types=1);
header('Content-Type: application/json; charset=utf-8');

// Carga la configuracion y fija la zona horaria.
$cfg = require '/etc/centro-datos/api.php';
date_default_timezone_set($cfg['zona']);

// Valores permitidos para respaldos y niveles de alerta.
const TIPOS     = ['completo', 'incremental', 'archivos', 'imagen'];
const ESTADOS_R = ['ok', 'advertencia', 'error'];
const NIVELES   = [1 => 'baja', 2 => 'media', 3 => 'alta', 4 => 'critica'];

// Manda la respuesta en JSON con su codigo HTTP y termina.
function responder(int $codigo, mixed $datos): never
{
    http_response_code($codigo);
    echo json_encode($datos, JSON_UNESCAPED_UNICODE | JSON_UNESCAPED_SLASHES);
    exit;
}

// Lee el JSON que llega en el cuerpo; si no es valido, responde 400.
function cuerpo(): array
{
    $d = json_decode(file_get_contents('php://input') ?: '', true);
    if (!is_array($d)) {
        responder(400, ['error' => 'Se esperaba un cuerpo JSON']);
    }
    return $d;
}

// Limpia un texto y lo corta al largo maximo.
function texto(mixed $v, int $max): string
{
    return mb_substr(trim(is_scalar($v) ? (string)$v : ''), 0, $max);
}

// Convierte una fecha (texto o numero) al formato de MariaDB.
function fecha(mixed $v): ?string
{
    if ($v === null || $v === '') {
        return null;
    }
    $t = is_numeric($v) ? (int)$v : strtotime((string)$v);
    return $t ? date('Y-m-d H:i:s', $t) : null;
}

// Cuantos resultados devolver (entre 1 y 500, por defecto 100).
function limite(): int
{
    return min(500, max(1, (int)($_GET['limite'] ?? 100)));
}

// Registra el equipo si no existe y devuelve su id.
function idEquipo(PDO $pdo, string $nombre): int
{
    $pdo->prepare('INSERT INTO equipos (nombre) VALUES (?)
                   ON DUPLICATE KEY UPDATE id = LAST_INSERT_ID(id)')
        ->execute([$nombre]);
    return (int)$pdo->lastInsertId();
}

// ---- Ruteo: /<recurso>[/<sub>]  (el prefijo /api es opcional) ----
// Aqui se saca de la URL que recurso piden y con que metodo.
$ruta    = trim((string)parse_url($_SERVER['REQUEST_URI'] ?? '/', PHP_URL_PATH), '/');
$ruta    = (string)preg_replace('#^api(/|$)#', '', $ruta);
$partes  = $ruta === '' ? [] : explode('/', $ruta);
$recurso = $partes[0] ?? '';
$metodo  = $_SERVER['REQUEST_METHOD'] ?? 'GET';

try {
    // Conexion a la base de datos con el usuario de la API.
    $pdo = new PDO(
        "mysql:host=localhost;dbname={$cfg['db_nombre']};charset=utf8mb4",
        $cfg['db_usuario'], $cfg['db_clave'],
        [PDO::ATTR_ERRMODE => PDO::ERRMODE_EXCEPTION,
         PDO::ATTR_DEFAULT_FETCH_MODE => PDO::FETCH_ASSOC]
    );

    // /salud no pide clave: sirve para ver si la API y la BD responden.
    if ($recurso === 'salud') {
        $pdo->query('SELECT 1');
        responder(200, ['estado' => 'ok']);
    }

    // Todo lo demas exige la clave, por cabecera X-API-Key o ?key=
    $clave = $_SERVER['HTTP_X_API_KEY'] ?? ($_GET['key'] ?? '');
    if (!hash_equals($cfg['api_key'], (string)$clave)) {
        responder(401, ['error' => 'API key invalida']);
    }

    // Compatible con el webhook del manual: un POST a la raiz es una alerta.
    if ($recurso === '' && $metodo === 'POST') {
        $recurso = 'alertas';
    }

    switch ($recurso) {

        // Raiz: lista los recursos disponibles.
        case '':
            responder(200, ['recursos' => ['salud', 'equipos', 'respaldos', 'alertas', 'salt/retornos']]);

        // Equipos: GET los lista, POST registra uno o actualiza su ip y rol.
        case 'equipos':
            if ($metodo === 'GET') {
                responder(200, $pdo->query('SELECT id, nombre, ip, rol, fecha_registro FROM equipos ORDER BY nombre')->fetchAll());
            }
            if ($metodo === 'POST') {
                $d = cuerpo();
                $nombre = texto($d['nombre'] ?? '', 100);
                if ($nombre === '') {
                    responder(400, ['error' => 'El campo "nombre" es obligatorio']);
                }
                $pdo->prepare('INSERT INTO equipos (nombre, ip, rol) VALUES (?, ?, ?)
                               ON DUPLICATE KEY UPDATE ip = COALESCE(VALUES(ip), ip),
                                                       rol = COALESCE(VALUES(rol), rol)')
                    ->execute([$nombre, isset($d['ip']) ? texto($d['ip'], 45) : null,
                               isset($d['rol']) ? texto($d['rol'], 30) : null]);
                responder(200, ['id' => idEquipo($pdo, $nombre), 'nombre' => $nombre]);
            }
            responder(405, ['error' => 'Metodo no permitido']);

        // Respaldos (UrBackup y dumps de MariaDB):
        // GET los consulta con filtros, POST registra uno.
        case 'respaldos':
            if ($metodo === 'GET') {
                $sql = 'SELECT r.id, e.nombre AS equipo, r.origen, r.tipo, r.estado, r.inicio, r.fin,
                               r.tamano_bytes, r.ruta, r.detalle
                        FROM respaldos r JOIN equipos e ON e.id = r.equipo_id';
                $where = []; $args = [];
                foreach (['equipo' => 'e.nombre', 'estado' => 'r.estado', 'origen' => 'r.origen'] as $p => $col) {
                    if (!empty($_GET[$p])) { $where[] = "$col = ?"; $args[] = (string)$_GET[$p]; }
                }
                $sql .= ($where ? ' WHERE ' . implode(' AND ', $where) : '')
                      . ' ORDER BY r.inicio DESC LIMIT ' . limite();
                $st = $pdo->prepare($sql);
                $st->execute($args);
                responder(200, $st->fetchAll());
            }
            if ($metodo === 'POST') {
                $d = cuerpo();
                $equipo = texto($d['equipo'] ?? '', 100);
                $tipo   = $d['tipo'] ?? 'incremental';
                $estado = $d['estado'] ?? '';
                $inicio = fecha($d['inicio'] ?? null);
                if ($equipo === '' || $inicio === null
                    || !in_array($tipo, TIPOS, true) || !in_array($estado, ESTADOS_R, true)) {
                    responder(400, ['error' => 'Requeridos: equipo, inicio, estado (' . implode('|', ESTADOS_R) . '); opcional tipo (' . implode('|', TIPOS) . ')']);
                }
                $tam = $d['tamano_bytes'] ?? null;
                // Si reenvias el mismo respaldo (equipo, origen, tipo, inicio), se actualiza.
                $pdo->prepare('INSERT INTO respaldos (equipo_id, origen, tipo, estado, inicio, fin, tamano_bytes, ruta, detalle)
                               VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                               ON DUPLICATE KEY UPDATE estado = VALUES(estado), fin = VALUES(fin),
                                   tamano_bytes = VALUES(tamano_bytes), ruta = VALUES(ruta), detalle = VALUES(detalle)')
                    ->execute([idEquipo($pdo, $equipo), texto($d['origen'] ?? 'urbackup', 30) ?: 'urbackup',
                               $tipo, $estado, $inicio, fecha($d['fin'] ?? null),
                               is_numeric($tam) ? (int)$tam : null,
                               isset($d['ruta']) ? texto($d['ruta'], 255) : null,
                               isset($d['detalle']) ? texto($d['detalle'], 5000) : null]);
                responder(201, ['guardado' => true]);
            }
            responder(405, ['error' => 'Metodo no permitido']);

        // Alertas (Graylog u otra fuente):
        // GET las consulta con filtros, POST guarda una nueva.
        case 'alertas':
            if ($metodo === 'GET') {
                $sql = 'SELECT id, timestamp_evento, origen, nivel_prioridad, tipo_evento, mensaje, fecha_recepcion
                        FROM alertas_sistema';
                $where = []; $args = [];
                foreach (['nivel' => 'nivel_prioridad', 'origen' => 'origen', 'tipo' => 'tipo_evento'] as $p => $col) {
                    if (!empty($_GET[$p])) { $where[] = "$col = ?"; $args[] = (string)$_GET[$p]; }
                }
                $sql .= ($where ? ' WHERE ' . implode(' AND ', $where) : '')
                      . ' ORDER BY timestamp_evento DESC, id DESC LIMIT ' . limite();
                $st = $pdo->prepare($sql);
                $st->execute($args);
                responder(200, $st->fetchAll());
            }
            if ($metodo === 'POST') {
                $d  = cuerpo();
                // Acepta el cuerpo de Graylog ({"event": {...}}) o un JSON simple.
                $ev = is_array($d['event'] ?? null) ? $d['event'] : $d;
                $prio = $ev['priority'] ?? $ev['nivel'] ?? 'media';
                $nivel = is_numeric($prio) ? (NIVELES[(int)$prio] ?? (string)$prio) : (string)$prio;
                $tipo  = $d['event_definition_title'] ?? $ev['event_definition_title']
                         ?? $ev['tipo_evento'] ?? 'Alerta sin titulo';
                $pdo->prepare('INSERT INTO alertas_sistema
                                 (timestamp_evento, origen, nivel_prioridad, tipo_evento, mensaje, raw_payload)
                               VALUES (?, ?, ?, ?, ?, ?)')
                    ->execute([
                        fecha($ev['timestamp'] ?? $ev['fecha'] ?? null) ?? date('Y-m-d H:i:s'),
                        texto($ev['source'] ?? $ev['origen'] ?? 'Graylog-Server', 100),
                        texto($nivel, 20),
                        texto($tipo, 100) ?: 'Alerta sin titulo',
                        texto($ev['message'] ?? $ev['mensaje'] ?? '', 65000) ?: 'Sin detalle adicional',
                        json_encode($d, JSON_UNESCAPED_UNICODE),
                    ]);
                responder(201, ['status' => 'success', 'id' => (int)$pdo->lastInsertId()]);
            }
            responder(405, ['error' => 'Metodo no permitido']);

        // Salt: solo lectura de lo que guarda el returner (/salt/retornos).
        case 'salt':
            if ($metodo === 'GET' && ($partes[1] ?? '') === 'retornos') {
                responder(200, $pdo->query('SELECT id AS minion, fun, jid, success, alter_time
                                            FROM salt.salt_returns
                                            ORDER BY alter_time DESC LIMIT ' . limite())->fetchAll());
            }
            responder(404, ['error' => 'Usa /salt/retornos']);

        default:
            responder(404, ['error' => 'Recurso no encontrado']);
    }
} catch (PDOException $e) {
    // El detalle del error queda en el log; el cliente solo ve un mensaje general.
    error_log('API centro-datos: ' . $e->getMessage());
    responder(500, ['error' => 'Error de base de datos']);
}
PHP

# Apache: la API va en su propio puerto y solo la ve localhost y las
# IPs permitidas. No toca el sitio por defecto del puerto 80.
escribir_si_cambia /etc/apache2/conf-available/centro-datos-api.conf 644 root:root <<EOF
Listen ${PUERTO_API}
<VirtualHost *:${PUERTO_API}>
    ServerName centro-datos-api
    DocumentRoot ${DIR_API}
    <Directory ${DIR_API}>
        Options -Indexes
        AllowOverride None
        Require ip ${ACCESO_API}
        FallbackResource /index.php
    </Directory>
    ErrorLog \${APACHE_LOG_DIR}/centro-datos-api-error.log
    CustomLog \${APACHE_LOG_DIR}/centro-datos-api-access.log combined
</VirtualHost>
EOF
a2enconf -q centro-datos-api
apache2ctl configtest >/dev/null 2>&1 || { echo "Error en la configuracion de Apache"; apache2ctl configtest; exit 1; }
systemctl restart apache2

# ----------------------- 6. Respaldos de MariaDB para UrBackup ------
# Esta parte crea el respaldo de seguridad: un script que hace el dump
# completo de MariaDB, lo comprime, borra los viejos y lo registra en
# la API. Un cron lo ejecuta cada dia para que UrBackup lo copie.
echo "[6/7] Configurando dump diario de MariaDB..."
mkdir -p "$DIR_DUMPS"
chmod 700 "$DIR_DUMPS"

escribir_si_cambia "$SCRIPT_DUMP" 700 root:root <<'DUMP'
#!/usr/bin/env bash
# Dump completo de MariaDB (guarda 3 dias) y registro del resultado en la API.
set -uo pipefail
DIR="/var/backups/mariadb"
LOG="/var/log/mariadb_backup.log"
RETENCION_DIAS=3
FECHA="$(date +%Y%m%d_%H%M%S)"
DESTINO="${DIR}/full_backup_${FECHA}.sql.gz"
INICIO="$(date '+%Y-%m-%d %H:%M:%S')"

mkdir -p "$DIR"; chmod 700 "$DIR"
echo "[$INICIO] Iniciando mariadb-dump..." >> "$LOG"

# Hace el dump a un .part; si sale bien lo renombra y borra los viejos.
if mariadb-dump --all-databases --single-transaction --quick \
     --routines --triggers --events 2>>"$LOG" | gzip -9 > "${DESTINO}.part"; then
  mv "${DESTINO}.part" "$DESTINO"
  chmod 600 "$DESTINO"
  ESTADO="ok"; DETALLE="Dump completado"
  find "$DIR" -type f -name '*.sql.gz' -mtime +"$RETENCION_DIAS" -delete
  echo "[$(date '+%F %T')] Respaldo completado: $DESTINO" >> "$LOG"
else
  rm -f "${DESTINO}.part"
  ESTADO="error"; DETALLE="Fallo mariadb-dump"; DESTINO=""
  echo "[$(date '+%F %T')] ERROR: fallo mariadb-dump" >> "$LOG"
fi

# Avisa a la API como quedo el respaldo. Si esto falla, el respaldo
# no se ve afectado.
if [ -f /etc/centro-datos/cliente.env ]; then
  # shellcheck disable=SC1091
  . /etc/centro-datos/cliente.env
  TAM=0; [ -n "$DESTINO" ] && TAM="$(stat -c %s "$DESTINO")"
  curl -fsS --max-time 10 -X POST "${API_URL}/respaldos" \
    -H "X-API-Key: ${API_KEY}" -H "Content-Type: application/json" \
    -d "{\"equipo\":\"$(hostname -s)\",\"origen\":\"dump-mariadb\",\"tipo\":\"completo\",\"estado\":\"${ESTADO}\",\"inicio\":\"${INICIO}\",\"fin\":\"$(date '+%Y-%m-%d %H:%M:%S')\",\"tamano_bytes\":${TAM},\"ruta\":\"${DESTINO}\",\"detalle\":\"${DETALLE}\"}" \
    >/dev/null 2>>"$LOG" || echo "[$(date '+%F %T')] Aviso: no se pudo registrar en la API" >> "$LOG"
fi
[ "$ESTADO" = "ok" ]
DUMP

# Programa el dump todos los dias a la 01:30.
escribir_si_cambia /etc/cron.d/backup-mariadb 644 root:root <<EOF
# Dump diario de MariaDB (lo recoge UrBackup desde ${DIR_DUMPS})
30 1 * * * root ${SCRIPT_DUMP}
EOF

# Si el cliente de UrBackup ya esta instalado, activa su dump nativo
# de MariaDB (https://www.urbackup.org/backup_mysql.html). Solo cambia
# una linea "...ENABLE...=0" a 1.
UB_CONF="/usr/local/etc/urbackup/mariadbdump.conf"
UB_ESTADO="cliente UrBackup no encontrado (instalalo y vuelve a ejecutar el script)"
if [ -f "$UB_CONF" ]; then
  if grep -qiE '^[[:space:]]*[A-Za-z_]*ENABLE[A-Za-z_]*=0' "$UB_CONF"; then
    sed -i -E 's/^([[:space:]]*[A-Za-z_]*[Ee][Nn][Aa][Bb][Ll][Ee][A-Za-z_]*=)0/\11/' "$UB_CONF"
    UB_ESTADO="dump nativo de UrBackup ACTIVADO en $UB_CONF"
  else
    UB_ESTADO="revisa $UB_CONF (no se encontro la linea de activacion en 0 o ya esta activa)"
  fi
fi

# ----------------------- Guia de integracion ------------------------
# Aqui se arma la guia con los datos para conectar Salt, Graylog y
# UrBackup. Primero se detecta la IP de este equipo en la red interna.
IP_SRV="$(ip -4 -o addr show 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | grep "^${RED_PREFIJO}\." | head -n1 || true)"
IP_SRV="${IP_SRV:-$(hostname -I | awk '{print $1}')}"
IP_SRV="${IP_SRV:-127.0.0.1}"

# Reglas de firewall sugeridas: una por cada IP que definiste.
# Si no definiste ninguna, solo deja un aviso.
if [ -n "$IP_GRAYLOG$IP_SALT$IP_URBACKUP" ]; then
  REGLAS_FW=""
  if [ -n "$IP_GRAYLOG" ]; then
    REGLAS_FW+="iptables -A INPUT -p tcp -s ${IP_GRAYLOG} --dport ${PUERTO_API} -j ACCEPT   # Graylog -> API"$'\n'
  fi
  if [ -n "$IP_SALT" ]; then
    REGLAS_FW+="iptables -A INPUT -p tcp -s ${IP_SALT} --dport 3306 -j ACCEPT   # Salt master -> MariaDB"$'\n'
  fi
  if [ -n "$IP_URBACKUP" ]; then
    REGLAS_FW+="iptables -A INPUT -p tcp -s ${IP_URBACKUP} --dport 35621:35623 -j ACCEPT   # servidor UrBackup -> cliente"$'\n'
  fi
else
  REGLAS_FW="# No definiste IP_GRAYLOG / IP_SALT / IP_URBACKUP: la API y Salt aceptan toda ${RED_CIDR}.
# Limita 3306 y ${PUERTO_API} a las IPs de las otras computadoras en tu firewall."
fi

# Escribe la guia (solo la puede leer root, porque lleva claves).
(
  umask 077
  cat > "$ARCHIVO_INTEGRACION" <<EOF
==== SaltStack (en el master: /etc/salt/master.d/returner-mysql.conf) ====
master_job_cache: mysql
mysql.host: '${IP_SRV}'
mysql.port: 3306
mysql.user: '${USER_SALT}'
mysql.pass: '${PASS_SALT_DB}'
mysql.db: '${DB_SALT}'
# Requiere el modulo MySQL de Python en el master (python3-mysqldb,
# o "salt-pip install mysqlclient" si Salt es onedir). Reinicia salt-master.

==== Graylog (Alerts > Notifications > HTTP Notification, URL) ====
http://${IP_SRV}:${PUERTO_API}/alertas?key=${API_KEY}
# Si Graylog corre en este mismo equipo: http://127.0.0.1:${PUERTO_API}/alertas?key=${API_KEY}

==== UrBackup ====
Dumps de MariaDB:  ${DIR_DUMPS}  (diario 01:30, rotacion 3 dias)
Agrega esa carpeta a las rutas a respaldar de este cliente en UrBackup.
Estado del dump nativo: ${UB_ESTADO}
Registrar un respaldo en la API (desde cualquier equipo de la red):
curl -X POST http://${IP_SRV}:${PUERTO_API}/respaldos \\
  -H "X-API-Key: ${API_KEY}" -H "Content-Type: application/json" \\
  -d '{"equipo":"nodo-datos","origen":"urbackup","tipo":"incremental","estado":"ok","inicio":"2026-10-21 02:00:00","fin":"2026-10-21 02:14:00","tamano_bytes":523456789}'

==== Firewall de ESTA computadora (iptables) ====
${REGLAS_FW}

==== Consultas ====
curl -H "X-API-Key: ${API_KEY}" "http://${IP_SRV}:${PUERTO_API}/alertas?nivel=alta"
curl -H "X-API-Key: ${API_KEY}" "http://${IP_SRV}:${PUERTO_API}/respaldos?estado=error"
curl -H "X-API-Key: ${API_KEY}" "http://${IP_SRV}:${PUERTO_API}/salt/retornos"
EOF
)

# ----------------------- 7. Verificacion ----------------------------
# Aqui se comprueba que la API responde, tanto /salud como /equipos
# (este ultimo con la clave), y se muestra un resumen.
echo "[7/7] Verificando..."
curl -fsS "http://127.0.0.1:${PUERTO_API}/salud"; echo
curl -fsS -H "X-API-Key: ${API_KEY}" "http://127.0.0.1:${PUERTO_API}/equipos"; echo

echo
echo "Listo."
echo "  Credenciales:        ${ARCHIVO_CRED}"
echo "  Guia de integracion: ${ARCHIVO_INTEGRACION}"
echo "  UrBackup:            ${UB_ESTADO}"
echo "  Acceso a la API:     ${ACCESO_API}"
echo "  Salt master (3306):  ${HOST_SALT}"
