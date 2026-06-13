#!/bin/bash
set -e

echo "=== MoodleMathU Docker Entrypoint ==="

# ──────────────────────────────────────────────
# 1. Instalar extensiones PHP necesarias para Moodle 5
# ──────────────────────────────────────────────
if [ ! -f /usr/local/lib/php/extensions/.moodle_deps_installed ]; then
  echo "[1/5] Instalando dependencias del sistema..."
  apt-get update -qq && apt-get install -y --no-install-recommends \
    libpng-dev libjpeg-dev libwebp-dev libfreetype6-dev \
    libzip-dev libxml2-dev libonig-dev libcurl4-openssl-dev \
    libssl-dev libicu-dev libxslt1-dev \
    unzip git \
    2>/dev/null

  echo "[2/5] Instalando extensiones PHP..."
  docker-php-ext-configure gd --with-freetype --with-jpeg --with-webp
  docker-php-ext-install -j$(nproc) \
    gd zip pdo pdo_mysql mysqli \
    intl xml xsl soap opcache \
    mbstring exif curl

  a2enmod rewrite

  touch /usr/local/lib/php/extensions/.moodle_deps_installed
  echo "[2/5] Extensiones PHP instaladas."
fi

# ──────────────────────────────────────────────
# 2. Configuración PHP
# ──────────────────────────────────────────────
cat > /usr/local/etc/php/conf.d/moodle.ini << 'PHP_INI'
max_execution_time = 300
max_input_vars = 5000
memory_limit = 256M
post_max_size = 100M
upload_max_filesize = 100M
date.timezone = America/Bogota
PHP_INI

# ──────────────────────────────────────────────
# 3. Configurar Apache
# ──────────────────────────────────────────────
cat > /etc/apache2/sites-available/000-default.conf << 'APACHE_CONF'
<VirtualHost *:80>
    DocumentRoot /var/www/html
    <Directory /var/www/html>
        Options FollowSymLinks
        AllowOverride All
        Require all granted
    </Directory>
    ErrorLog ${APACHE_LOG_DIR}/error.log
    CustomLog ${APACHE_LOG_DIR}/access.log combined
</VirtualHost>
APACHE_CONF

# ──────────────────────────────────────────────
# 4. Crear directorio de datos Moodle
# ──────────────────────────────────────────────
mkdir -p /var/moodledata
chown -R www-data:www-data /var/moodledata
chmod 0777 /var/moodledata

# ──────────────────────────────────────────────
# 5. Generar config.php si no existe
# ──────────────────────────────────────────────
if [ ! -f /var/www/html/config.php ]; then
  echo "[3/5] Generando config.php..."
  cat > /var/www/html/config.php << MOODLE_CFG
<?php
unset(\$CFG);
global \$CFG;
\$CFG = new stdClass();

\$CFG->dbtype    = 'mariadb';
\$CFG->dblibrary = 'native';
\$CFG->dbhost    = '${MOODLE_DBHOST}';
\$CFG->dbname    = '${MOODLE_DBNAME}';
\$CFG->dbuser    = '${MOODLE_DBUSER}';
\$CFG->dbpass    = '${MOODLE_DBPASS}';
\$CFG->prefix    = 'mdl_';
\$CFG->dboptions = array(
  'dbpersist' => 0,
  'dbport'    => '',
  'dbsocket'  => '',
  'dbcollation' => 'utf8mb4_unicode_ci',
);

\$CFG->wwwroot   = '${MOODLE_WWWROOT}';
\$CFG->dataroot  = '${MOODLE_DATAROOT}';
\$CFG->admin     = 'admin';
\$CFG->directorypermissions = 0777;

require_once(__DIR__ . '/lib/setup.php');
MOODLE_CFG
  chown www-data:www-data /var/www/html/config.php
  echo "[3/5] config.php generado."
fi

# ──────────────────────────────────────────────
# 6. Esperar BD usando PHP mysqli (sin mysql client)
# ──────────────────────────────────────────────
echo "[4/5] Esperando base de datos..."
until php -r "
  \$conn = @new mysqli('${MOODLE_DBHOST}', '${MOODLE_DBUSER}', '${MOODLE_DBPASS}', '${MOODLE_DBNAME}');
  if (\$conn->connect_error) { exit(1); }
  exit(0);
" 2>/dev/null; do
  echo "  DB no disponible aun, reintentando en 3s..."
  sleep 3
done
echo "  DB lista."

TABLE_COUNT=$(php -r "
  \$conn = new mysqli('${MOODLE_DBHOST}', '${MOODLE_DBUSER}', '${MOODLE_DBPASS}', '${MOODLE_DBNAME}');
  \$r = \$conn->query(\"SELECT COUNT(*) as c FROM information_schema.tables WHERE table_schema='${MOODLE_DBNAME}'\");
  \$row = \$r->fetch_assoc();
  echo \$row['c'];
" 2>/dev/null || echo "0")

if [ "$TABLE_COUNT" -lt "5" ]; then
  echo "[4/5] Instalando Moodle por primera vez (puede tomar 2-5 minutos)..."
  php /var/www/html/admin/cli/install_database.php \
    --agree-license \
    --fullname="${MOODLE_SITENAME}" \
    --shortname="MoodleMathU" \
    --adminuser="${MOODLE_ADMIN}" \
    --adminpass="${MOODLE_ADMINPASS}" \
    --adminemail="${MOODLE_ADMINEMAIL}" \
    --non-interactive \
    2>&1 || echo "[WARN] Posible instalacion previa, continuando..."
  echo "[4/5] Instalacion completada."
else
  echo "[4/5] Base de datos ya existe ($TABLE_COUNT tablas), omitiendo instalacion."
fi

# ──────────────────────────────────────────────
# 7. Permisos y arrancar Apache
# ──────────────────────────────────────────────
chown -R www-data:www-data /var/www/html
chmod -R 755 /var/www/html

echo "[5/5] Iniciando Apache..."
exec apache2-foreground
