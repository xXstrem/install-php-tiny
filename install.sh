#!/bin/bash
set -euo pipefail

export DEBIAN_FRONTEND=noninteractive
export NEEDRESTART_MODE=a

sudo bash -c 'cat > /etc/needrestart/needrestart.conf <<CONF
$nrconf{restart} = "a";
CONF'

sudo apt-get update -y
sudo apt-get -y -o Dpkg::Options::="--force-confdef" \
                -o Dpkg::Options::="--force-confold" upgrade

sudo apt-get install -y apache2
sudo systemctl enable --now apache2

sudo apt-get install -y software-properties-common wget unzip
sudo add-apt-repository -y ppa:ondrej/php || true
sudo apt-get update -y

sudo apt-get install -y php7.4 php7.4-cli php7.4-common php7.4-mbstring php7.4-zip php7.4-xml php7.4-curl unzip \
                       php7.4-mysqli php7.4-bcmath php7.4-intl php7.4-gd

sudo chown -R www-data:www-data /var/www/html
sudo find /var/www/html -type d -exec chmod 755 {} \;
sudo find /var/www/html -type f -exec chmod 644 {} \;

TFM_RAW_URL="https://raw.githubusercontent.com/prasathmani/tinyfilemanager/master/tinyfilemanager.php"
sudo wget -q -O /var/www/html/tinyfilemanager.php "$TFM_RAW_URL" || { echo "failed tinyfilemanager.php"; exit 1; }
sudo mv /var/www/html/tinyfilemanager.php /var/www/html/manager.php
sudo chown www-data:www-data /var/www/html/manager.php
sudo chmod 640 /var/www/html/manager.php
sudo systemctl reload apache2 || sudo systemctl restart apache2

clear
cat <<'BANNER'
  ______ _ _        __  __                                   
 |  ____(_) |      |  \/  |                                  
 | |__   _| | ___  | \  / | __ _ _ __   __ _  __ _  ___ _ __ 
 |  __| | | |/ _ \ | |\/| |/ _` | '_ \ / _` |/ _` |/ _ \ '__|
 | |    | | |  __/ | |  | | (_| | | | | (_| | (_| |  __/ |   
 |_|    |_|_|\___| |_|  |_|\__,_|_| |_|\__,_|\__, |\___|_|   
                                              __/ |          
                                             |___/           
BANNER

# Ask for username and password (or use environment vars)
if [ -z "${TFM_USER:-}" ] || [ -z "${TFM_PASS:-}" ]; then
  read -p "Enter username: " TFM_USER
  while [ -z "$TFM_USER" ]; do
    echo "Username cannot be empty."
    read -p "Enter username: " TFM_USER
  done
  while true; do
    read -s -p "Enter password: " TFM_PASS
    echo
    read -s -p "Confirm password: " TFM_PASS2
    echo
    [ -z "$TFM_PASS" ] && { echo "Password cannot be empty."; continue; }
    [ "$TFM_PASS" = "$TFM_PASS2" ] && break
    echo "Passwords do not match."
  done
fi

# 1) ادخل اسم المستخدم وكلمة المرور تفاعلياً (نفّذ السطور التالية)
read -p "Username: " TFM_USER
while [ -z "${TFM_USER:-}" ]; do
  echo "Username cannot be empty."
  read -p "Username: " TFM_USER
done

while true; do
  read -s -p "Password: " TFM_PASS; echo
  read -s -p "Confirm password: " TFM_PASS2; echo
  [ -z "${TFM_PASS:-}" ] && { echo "Password cannot be empty."; continue; }
  [ "$TFM_PASS" = "$TFM_PASS2" ] && break
  echo "Passwords do not match — try again."
done

# 2) ولّد الهاش باستخدام PHP CLI
TFM_HASH=$(php -r 'echo password_hash($argv[1], PASSWORD_BCRYPT);' "$TFM_PASS")
echo "Generated hash length: ${#TFM_HASH}"

# 3) استدعاء آمن بــ sudo + heredoc (بدون '-') للتعديل داخل manager.php
sudo TFM_USER="$TFM_USER" TFM_HASH="$TFM_HASH" php <<'PHP'
<?php
$file = '/var/www/html/manager.php';
if (!file_exists($file)) {
    echo "ERROR: manager.php not found at $file\n";
    exit(1);
}
$s = file_get_contents($file);

// extract existing auth entries
preg_match_all("/['\"]([^'\"]+)['\"]\s*=>\s*['\"]([^'\"]+)['\"]/",$s,$m,PREG_SET_ORDER);
$arr = array();
foreach($m as $p){ $arr[$p[1]] = $p[2]; }

// get env vars
$u = getenv('TFM_USER');
$h = getenv('TFM_HASH');
$arr[$u] = $h;

// build new auth block
$new = "\$auth_users = array(\n";
foreach($arr as $k => $v){
  $k_esc = str_replace("'", "\\'", $k);
  $v_esc = str_replace("'", "\\'", $v);
  $new .= "    '".$k_esc."' => '".$v_esc."',\n";
}
$new .= ");";

// replace existing block or prepend
if (preg_match("/\\$auth_users\\s*=\\s*array\\s*\\([^;]*\\);/s",$s)) {
  $s = preg_replace("/\\$auth_users\\s*=\\s*array\\s*\\([^;]*\\);/s", $new, $s, 1);
} else {
  $s = $new . "\n" . $s;
}

file_put_contents($file, $s);
echo "Updated $file (user: $u)\n";
PHP

# 4) تحقق سريع
echo "---- auth lines in manager.php ----"
sudo grep -n "\$auth_users" /var/www/html/manager.php || true
sudo tail -n 20 /var/www/html/manager.php



sudo chown www-data:www-data "$TFM_FILE"
sudo chmod 640 "$TFM_FILE"
sudo systemctl reload apache2 || sudo systemctl restart apache2

echo
echo "✅ Installation completed successfully!"
echo "➡️  Open: http://<IP-or-domain>/manager.php"
echo "👤 User: $TFM_USER"
