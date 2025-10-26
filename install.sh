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
                       php7.4-mysqli php7.4-bcmath php7.4-intl php7.4-gd \
                       libapache2-mod-php7.4

sudo chown -R www-data:www-data /var/www/html
sudo find /var/www/html -type d -exec chmod 755 {} \;
sudo find /var/www/html -type f -exec chmod 644 {} \;

TFM_RAW_URL="https://raw.githubusercontent.com/xXstrem/install-php-tiny/refs/heads/main/tinyfilemanager.php"
sudo wget -q -O /var/www/html/tinyfilemanager.php "$TFM_RAW_URL" || { echo "Failed to download tinyfilemanager.php. Exiting."; exit 1; }
sudo mv /var/www/html/tinyfilemanager.php /var/www/html/manager.php
sudo chown www-data:www-data /var/www/html/manager.php
sudo chmod 640 /var/www/html/manager.php
sudo systemctl reload apache2 || sudo systemctl restart apache2

clear

read -p "Username: " NEW_USER
while [ -z "${NEW_USER:-}" ]; do read -p "Username: " NEW_USER; done
while true; do
  read -s -p "Password: " NEW_PASS; echo
  read -s -p "Confirm password: " NEW_PASS2; echo
  [ -z "${NEW_PASS:-}" ] && { echo "Password cannot be empty."; continue; }
  [ "$NEW_PASS" = "$NEW_PASS2" ] && break
  echo "Passwords do not match."
done

# generate bcrypt hash with cost=10
NEW_HASH=$(php -r 'echo password_hash($argv[1], PASSWORD_BCRYPT, ["cost" => 10]);' "$NEW_PASS")
echo "Generated hash: $NEW_HASH"

TFM_FILE="/var/www/html/manager.php"
sudo NEW_USER="$NEW_USER" NEW_HASH="$NEW_HASH" php <<'PHP'
<?php
$file = '/var/www/html/manager.php';
if (!file_exists($file)) { echo "manager.php not found\n"; exit(1); }
$s = file_get_contents($file);
$u = getenv('NEW_USER'); $h = getenv('NEW_HASH');
$u_esc = str_replace("'", "\\'", $u); $h_esc = str_replace("'", "\\'", $h);
$pattern_exact = "/['\"]userrrrrrrrrr['\"]\\s*=>\\s*['\"]passwordhash['\"]\\s*,?/s";
$replacement = "'" . $u_esc . "' => '" . $h_esc . "',";
if (preg_match($pattern_exact,$s)) { $s = preg_replace($pattern_exact,$replacement,$s,1); file_put_contents($file,$s); echo "Replaced exact placeholder\n"; exit(0);}
$pattern_key = "/(['\"])userrrrrrrrrr\\1\\s*=>\\s*['\"][^'\"]*['\"]/s";
if (preg_match($pattern_key,$s)) { $s = preg_replace($pattern_key, "'" . $u_esc . "' => '" . $h_esc . "'", $s,1); file_put_contents($file,$s); echo "Replaced key value\n"; exit(0);}
if (strpos($s,"passwordhash")!==false) { $s = preg_replace("/passwordhash/",$h_esc,$s,1); file_put_contents($file,$s); echo "Replaced first 'passwordhash'\n"; exit(0);}
$new_block = "\$auth_users = array(\n    '" . $u_esc . "' => '" . $h_esc . "',\n);\n\n";
$s = $new_block . $s; file_put_contents($file,$s); echo "Prepended new auth block\n"; exit(0);
PHP

sudo chown www-data:www-data "$TFM_FILE" || true
sudo chmod 640 "$TFM_FILE" || true
sudo systemctl reload apache2 || sudo systemctl restart apache2

echo
echo "✅ Installation completed successfully!"
echo "➡️  Open: http://<IP-or-domain>/manager.php"
echo "👤 User: $NEW_USER"
