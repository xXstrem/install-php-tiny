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

TFM_RAW_URL="https://raw.githubusercontent.com/prasathmani/tinyfilemanager/master/tinyfilemanager.php"
sudo wget -q -O /var/www/html/tinyfilemanager.php "$TFM_RAW_URL" || { echo "Failed to download tinyfilemanager.php. Exiting."; exit 1; }
sudo mv /var/www/html/tinyfilemanager.php /var/www/html/manager.php
sudo chown www-data:www-data /var/www/html/manager.php
sudo chmod 640 /var/www/html/manager.php
sudo systemctl reload apache2 || sudo systemctl restart apache2

clear

# === User Credential Input ===

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

# === Generate Hash and Update Configuration ===

# Generate bcrypt hash
TFM_HASH=$(php -r 'echo password_hash($argv[1], PASSWORD_BCRYPT);' "$TFM_PASS")
TFM_FILE="/var/www/html/manager.php"

if [ ! -f "$TFM_FILE" ]; then
  echo "manager.php not found at $TFM_FILE. Exiting."
  exit 1
fi

# Create a temporary PHP script to safely update the auth_users array
TFM_PHP_SCRIPT=$(mktemp)
cat <<'PHP_CODE' > "$TFM_PHP_SCRIPT"
<?php
// Get path, user, and hash from environment variables
$file = getenv('TFM_FILE'); 
$u = getenv('TFM_USER');
$h = getenv('TFM_HASH');

if (!file_exists($file)) { echo "manager.php not found\n"; exit(1); }
$s = file_get_contents($file);

// Regex to capture the entire $auth_users = array(...) block
// This is crucial for overwriting the default users and comments
$regex = '/(\$auth_users\s*=\s*array\s*\()([\s\S]*?)(\);)/i';

// Build the new auth entry
$new_auth_entries = "";
$k_esc = str_replace("'", "\\'", $u);
$v_esc = str_replace("'", "\\'", $h);
$new_auth_entries .= "\n    '".$k_esc."' => '".$v_esc."',\n";

// Build the replacement block (containing ONLY the new user)
$new_block = "\$auth_users = array(" . $new_auth_entries . ");";

// Replace the old $auth_users block entirely with the new one
if (preg_match($regex, $s)) {
    $s = preg_replace($regex, $new_block, $s, 1);
} else {
    // Fallback: If not found, prepend the new block (unlikely for TFM)
    $s = $new_block . "\n" . $s;
}

file_put_contents($file, $s);
echo "ok\n";
PHP_CODE

# Execute the temporary script using sudo
sudo TFM_USER="$TFM_USER" TFM_HASH="$TFM_HASH" TFM_FILE="$TFM_FILE" php "$TFM_PHP_SCRIPT"

# Clean up the temporary file
rm -f "$TFM_PHP_SCRIPT"

# === Final Cleanup and Confirmation ===

sudo chown www-data:www-data "$TFM_FILE"
sudo chmod 640 "$TFM_FILE"
sudo systemctl reload apache2 || sudo systemctl restart apache2

echo
echo "✅ Installation completed successfully!"
echo "➡️  Open: http://<IP-or-domain>/manager.php"
echo "👤 User: $TFM_USER"
