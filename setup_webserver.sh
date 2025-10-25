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

sudo apt-get install -y php7.4 php7.4-common php7.4-mbstring php7.4-zip php7.4-xml php7.4-curl unzip \
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

echo ""
echo "Installation completed successfully!" 
echo "Now open : http://<IP-or-domain>/manager.php" 
EOF

chmod +x /tmp/setup_webserver.sh
sudo /tmp/setup_webserver.sh
