cat <<'EOF' > /tmp/setup_webserver.sh
#!/bin/bash
set -euo pipefail

sudo apt update && sudo apt upgrade -y

sudo apt install -y apache2
sudo systemctl enable --now apache2

sudo apt-get install -y software-properties-common
sudo add-apt-repository -y ppa:ondrej/php
sudo apt update

sudo apt install -y php7.4 php7.4-common php7.4-mbstring php7.4-zip php7.4-xml php7.4-curl unzip \
                    php7.4-mysqli php7.4-bcmath php7.4-intl php7.4-gd

sudo chown -R www-data:www-data /var/www/html
sudo find /var/www/html -type d -exec chmod 755 {} \;
sudo find /var/www/html -type f -exec chmod 644 {} \;

TFM_RAW_URL="https://raw.githubusercontent.com/prasathmani/tinyfilemanager/master/tinyfilemanager.php"
sudo wget -q -O /var/www/html/tinyfilemanager.php "$TFM_RAW_URL" || { echo "failed tinyfilemanager.php"; exit 1; }

sudo chown www-data:www-data /var/www/html/tinyfilemanager.php
sudo chmod 640 /var/www/html/tinyfilemanager.php

sudo systemctl reload apache2 || sudo systemctl restart apache2
EOF


chmod +x /tmp/setup_webserver.sh
sudo /tmp/setup_webserver.sh
