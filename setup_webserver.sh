cat <<'EOF' > /tmp/setup_webserver.sh
#!/bin/bash
set -euo pipefail

export DEBIAN_FRONTEND=noninteractive
export NEEDRESTART_MODE=a

sudo sed -i 's/\$nrconf{restart}.*/$nrconf{restart} = "a";/' /etc/needrestart/needrestart.conf \
  || echo '$nrconf{restart} = "a";' | sudo tee -a /etc/needrestart/needrestart.conf

sudo apt-get update -y
sudo apt-get -y -o Dpkg::Options::="--force-confdef" \
                -o Dpkg::Options::="--force-confold" upgrade

sudo apt-get install -y apache2
sudo systemctl enable --now apache2

sudo apt-get install -y software-properties-common
sudo add-apt-repository -y ppa:ondrej/php
sudo apt-get update -y

# include php cli to generate bcrypt hashes
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

echo
echo "Enter credentials to protect manager.php (these will be stored hashed inside the file)."
read -p "Username: " TFM_USER

while true; do
  read -s -p "Password: " TFM_PASS
  echo
  read -s -p "Confirm Password: " TFM_PASS2
  echo
  if [ -z "$TFM_PASS" ]; then
    echo "Password cannot be empty. Try again."
    continue
  fi
  if [ "$TFM_PASS" = "$TFM_PASS2" ]; then
    break
  fi
  echo "Passwords do not match — try again."
done

TFM_HASH=$(php -r 'echo password_hash($argv[1], PASSWORD_BCRYPT);' "$TFM_PASS")
if [ -z "$TFM_HASH" ]; then
  echo "Failed to generate password hash. Exiting."
  exit 1
fi

TMP_AUTH="/tmp/auth_block_$$.php"
sudo bash -c "cat > \"$TMP_AUTH\" <<'AUTH'
\$auth_users = array(
    '$TFM_USER' => '$TFM_HASH'
);
AUTH
"

sudo perl -0777 -i -pe 'BEGIN{ $r = do q('"$TMP_AUTH"'); } s/\$auth_users\s*=\s*array\s*\([^;]*\);/$r/s' /var/www/html/manager.php

if ! grep -q "\$auth_users\s*=" /var/www/html/manager.php; then
  sudo sed -i "1i$(sudo cat "$TMP_AUTH" | sed 's/\\/\\\\/g; s/\\$/\\$/' )" /var/www/html/manager.php
fi

# cleanup temp file
sudo rm -f "$TMP_AUTH"

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

echo ""
echo "Installation completed successfully!"
echo "Now open : http://<IP-or-domain>/manager.php"
EOF

chmod +x /tmp/setup_webserver.sh
sudo /tmp/setup_webserver.sh
