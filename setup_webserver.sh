cat <<'EOF' > /tmp/setup_webserver.sh
#!/bin/bash
set -euo pipefail

export DEBIAN_FRONTEND=noninteractive
export NEEDRESTART_MODE=a

# Ensure needrestart config
sudo sed -i 's/\$nrconf{restart}.*/$nrconf{restart} = "a";/' /etc/needrestart/needrestart.conf \
  || echo '$nrconf{restart} = "a";' | sudo tee -a /etc/needrestart/needrestart.conf

sudo apt-get update -y
sudo apt-get -y -o Dpkg::Options::="--force-confdef" \
                -o Dpkg::Options::="--force-confold" upgrade

sudo apt-get install -y apache2
sudo systemctl enable --now apache2

sudo apt-get install -y software-properties-common wget unzip
# add PPA for php7.4 if not present
sudo add-apt-repository -y ppa:ondrej/php || true
sudo apt-get update -y

# include php cli to generate bcrypt hashes
sudo apt-get install -y php7.4 php7.4-cli php7.4-common php7.4-mbstring php7.4-zip php7.4-xml php7.4-curl unzip \
                       php7.4-mysqli php7.4-bcmath php7.4-intl php7.4-gd

sudo chown -R www-data:www-data /var/www/html
sudo find /var/www/html -type d -exec chmod 755 {} \;
sudo find /var/www/html -type f -exec chmod 644 {} \;

# download tinyfilemanager raw and rename to manager.php
TFM_RAW_URL="https://raw.githubusercontent.com/prasathmani/tinyfilemanager/master/tinyfilemanager.php"
sudo wget -q -O /var/www/html/tinyfilemanager.php "$TFM_RAW_URL" || { echo "failed tinyfilemanager.php"; exit 1; }

sudo mv /var/www/html/tinyfilemanager.php /var/www/html/manager.php
sudo chown www-data:www-data /var/www/html/manager.php
sudo chmod 640 /var/www/html/manager.php

# reload apache
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

echo ""
# ask for username + password AFTER the banner (as requested)
read -p "Enter username to add to manager.php: " TFM_USER_RAW
while [ -z "${TFM_USER_RAW:-}" ]; do
  echo "Username cannot be empty. Try again."
  read -p "Enter username to add to manager.php: " TFM_USER_RAW
done

# sanitize username: allow only alnum, dot, underscore, hyphen
TFM_USER=$(echo "$TFM_USER_RAW" | sed 's/[^A-Za-z0-9._-]//g')
if [ -z "$TFM_USER" ]; then
  echo "After sanitization the username became empty. Exiting."
  exit 1
fi
if [ "$TFM_USER" != "$TFM_USER_RAW" ]; then
  echo "Note: username contained disallowed characters; using sanitized username: $TFM_USER"
fi

# prompt for password (hidden)
while true; do
  read -s -p "Enter password for user '$TFM_USER': " TFM_PASS
  echo
  read -s -p "Confirm password: " TFM_PASS2
  echo
  if [ -z "${TFM_PASS:-}" ]; then
    echo "Password cannot be empty. Try again."
    continue
  fi
  if [ "$TFM_PASS" = "$TFM_PASS2" ]; then
    break
  fi
  echo "Passwords do not match — try again."
done

# generate bcrypt hash using php
TFM_HASH=$(php -r 'echo password_hash($argv[1], PASSWORD_BCRYPT);' "$TFM_PASS")
if [ -z "$TFM_HASH" ]; then
  echo "Failed to generate password hash. Exiting."
  exit 1
fi

# prepare temp auth block
TMP_AUTH="/tmp/auth_block_$$.php"
cat > "$TMP_AUTH" <<EOF
\$auth_users = array(
    '$TFM_USER' => '$TFM_HASH'
);
EOF

TFM_FILE="/var/www/html/manager.php"

if [ ! -f "$TFM_FILE" ]; then
  echo "manager.php not found at $TFM_FILE. Exiting."
  rm -f "$TMP_AUTH"
  exit 1
fi

# Escape $ in hash for use in shell/Perl double-quoted replacement
ESC_HASH=$(printf '%s' "$TFM_HASH" | sed 's/\\/\\\\/g; s/\$/\\\$/g')

# Check if $auth_users array exists in target file
if grep -q "\$auth_users\s*=" "$TFM_FILE"; then
  # If username already exists, replace its hash
  if grep -qE "['\"]${TFM_USER}['\"]\s*=>\s*['\"][^'\"]*['\"]" "$TFM_FILE"; then
    echo "User '$TFM_USER' exists — updating hash."
    # use perl to replace the existing user's hash (escape $ in replacement)
    sudo perl -0777 -i -pe "s/(['\"])${TFM_USER}(['\"]\s*=>\s*['\"])[^'\"]*(['\"])/\$1${TFM_USER}\$2${ESC_HASH}\$3/s" "$TFM_FILE"
  else
    echo "User '$TFM_USER' not found — inserting new entry into \$auth_users array."
    # Insert new entry before the closing ');' of the $auth_users array.
    # append with a leading comma if array already has entries (perl non-greedy)
    sudo perl -0777 -i -pe "s/(\$auth_users\s*=\s*array\s*\(\s*)(.*?)(\s*\);)/\$1\$2,\n    '${TFM_USER}' => '${ESC_HASH}'\n\$3/s" "$TFM_FILE"
  fi
else
  echo "No \$auth_users array found — prepending a new block."
  # Prepend new block if none exists
  sudo bash -c "cat \"$TMP_AUTH\" \"$TFM_FILE\" > \"$TFM_FILE.new\" && mv \"$TFM_FILE.new\" \"$TFM_FILE\""
fi

# cleanup temp file
rm -f "$TMP_AUTH"

sudo chown www-data:www-data "$TFM_FILE"
sudo chmod 640 "$TFM_FILE"

sudo systemctl reload apache2 || sudo systemctl restart apache2

clear
cat <<'FIN'
Installation and configuration completed successfully!
Credentials were written (hashed) into /var/www/html/manager.php

Now open: http://<IP-or-domain>/manager.php
FIN
EOF

chmod +x /tmp/setup_webserver.sh
sudo /tmp/setup_webserver.sh
