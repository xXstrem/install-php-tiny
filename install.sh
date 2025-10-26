#!/bin/bash
set -euo pipefail

# === System Environment Setup ===

export DEBIAN_FRONTEND=noninteractive
export NEEDRESTART_MODE=a

# Configure needrestart to avoid prompts during upgrade
sudo bash -c 'cat > /etc/needrestart/needrestart.conf <<CONF
$nrconf{restart} = "a";
CONF'

# Update and upgrade system packages
sudo apt-get update -y
sudo apt-get -y -o Dpkg::Options::="--force-confdef" \
               -o Dpkg::Options::="--force-confold" upgrade

# === Install Apache2 and Enable ===

sudo apt-get install -y apache2
sudo systemctl enable --now apache2

# === Install PHP 7.4 and Extensions ===

# Install utility packages and add PHP PPA
sudo apt-get install -y software-properties-common wget unzip
sudo add-apt-repository -y ppa:ondrej/php || true
sudo apt-get update -y

# Install PHP 7.4, extensions, and the required Apache module
sudo apt-get install -y php7.4 php7.4-cli php7.4-common php7.4-mbstring php7.4-zip php7.4-xml php7.4-curl unzip \
                       php7.4-mysqli php7.4-bcmath php7.4-intl php7.4-gd \
                       libapache2-mod-php7.4

# === Setup Tiny File Manager Permissions and Download ===

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

read -p "Username to set in manager.php: " NEW_USER
while [ -z "${NEW_USER:-}" ]; do
  echo "Username cannot be empty."
  read -p "Username to set in manager.php: " NEW_USER
done

while true; do
  read -s -p "Password: " NEW_PASS; echo
  read -s -p "Confirm password: " NEW_PASS2; echo
  [ -z "${NEW_PASS:-}" ] && { echo "Password cannot be empty."; continue; }
  [ "$NEW_PASS" = "$NEW_PASS2" ] && break
  echo "Passwords do not match. Try again."
done

# 2) Generate bcrypt hash (PHP CLI)
if ! command -v php >/dev/null 2>&1; then
  echo "Error: php CLI not found. Please install php-cli."
  exit 1
fi

NEW_HASH=$(php -r 'echo password_hash($argv[1], PASSWORD_BCRYPT);' "$NEW_PASS")
if [ -z "$NEW_HASH" ]; then
  echo "Error: failed to generate hash."
  exit 1
fi
echo "Generated hash length: ${#NEW_HASH}"

# 3) File paths and backup
TFM_FILE="/var/www/html/manager.php"
if [ ! -f "$TFM_FILE" ]; then
  echo "ERROR: $TFM_FILE not found. Aborting."
  exit 1
fi

BACKUP="/var/www/html/manager.php.bak.$(date +%s)"
sudo cp "$TFM_FILE" "$BACKUP"
echo "Backup created at: $BACKUP"

# 4) Safe replacement using PHP to avoid regex escaping issues
sudo NEW_USER="$NEW_USER" NEW_HASH="$NEW_HASH" php <<'PHP'
<?php
$file = '/var/www/html/manager.php';
if (!file_exists($file)) {
    echo "ERROR: manager.php not found at $file\n";
    exit(1);
}
$s = file_get_contents($file);

// Environment variables passed by sudo wrapper
$u = getenv('NEW_USER');
$h = getenv('NEW_HASH');
if ($u === false || $h === false) {
    echo "ERROR: NEW_USER or NEW_HASH env var missing\n";
    exit(1);
}

// Prepare escaped values for insertion
$u_esc = str_replace("'", "\\'", $u);
$h_esc = str_replace("'", "\\'", $h);

// 1) Try replace exact placeholder entry
$pattern_exact = "/['\"]userrrrrrrrrr['\"]\\s*=>\\s*['\"]passwordhash['\"]\\s*,?/s";
$replacement = "'" . $u_esc . "' => '" . $h_esc . "',";

if (preg_match($pattern_exact, $s)) {
    $s = preg_replace($pattern_exact, $replacement, $s, 1);
    file_put_contents($file, $s);
    echo "Replaced exact placeholder with user '{$u}' in $file\n";
    exit(0);
}

// 2) If key 'userrrrrrrrrr' exists, replace its value
$pattern_key = "/(['\"])userrrrrrrrrr\\1\\s*=>\\s*['\"][^'\"]*['\"]/s";
if (preg_match($pattern_key, $s)) {
    $s = preg_replace($pattern_key, "'" . $u_esc . "' => '" . $h_esc . "'", $s, 1);
    file_put_contents($file, $s);
    echo "Replaced key 'userrrrrrrrrr' value with new hash.\n";
    exit(0);
}

// 3) If literal 'passwordhash' exists anywhere in the file, replace first occurrence
if (strpos($s, "passwordhash") !== false) {
    $s = preg_replace("/passwordhash/", $h_esc, $s, 1);
    file_put_contents($file, $s);
    echo "Replaced first occurrence of 'passwordhash' with new hash.\n";
    exit(0);
}

// 4) If nothing matched, prepend a new $auth_users block (non-destructive)
$new_block = "\$auth_users = array(\n    '" . $u_esc . "' => '" . $h_esc . "',\n);\n\n";
$s = $new_block . $s;
file_put_contents($file, $s);
echo "No placeholder found; prepended new \$auth_users block with user '{$u}'.\n";
exit(0);
PHP

# 5) Fix ownership/permissions
sudo chown www-data:www-data "$TFM_FILE" || true
sudo chmod 640 "$TFM_FILE" || true

# 6) Summary
echo "Done. Check $TFM_FILE and login with username: $NEW_USER"
echo "Backup kept at: $BACKUP"








sudo chown www-data:www-data "$TFM_FILE"
sudo chmod 640 "$TFM_FILE"
sudo systemctl reload apache2 || sudo systemctl restart apache2

echo "✅ Installation completed successfully!"
echo "➡️  Open: http://<IP-or-domain>/manager.php"
echo "👤 User: $NEW_USER"
