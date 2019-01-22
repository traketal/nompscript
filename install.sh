source functions.sh # load our functions
# copy functions to /etc
sudo cp -r functions.sh /etc/
#source $HOME/daemon_builder/.my.cnf

if [ -z "$STORAGE_USER" ]; then
STORAGE_USER=$([[ -z "$DEFAULT_STORAGE_USER" ]] && echo "veilnomp" || echo "$DEFAULT_STORAGE_USER")
fi
if [ -z "$STORAGE_ROOT" ]; then
STORAGE_ROOT=$([[ -z "$DEFAULT_STORAGE_ROOT" ]] && echo "/home/$STORAGE_USER" || echo "$DEFAULT_STORAGE_ROOT")
fi

if ! locale -a | grep en_US.utf8 > /dev/null; then
# Generate locale if not exists
hide_output locale-gen en_US.UTF-8
fi

export LANGUAGE=en_US.UTF-8
export LC_ALL=en_US.UTF-8
export LANG=en_US.UTF-8
export LC_TYPE=en_US.UTF-8

# Fix so line drawing characters are shown correctly in Putty on Windows. See #744.
export NCURSES_NO_UTF8_ACS=1

# Create the temporary installation directory if it doesn't already exist.
echo Creating the temporary NOMP installation folder...
if [ ! -d $STORAGE_ROOT/ ]; then
sudo mkdir -p $STORAGE_ROOT
sudo mkdir -p $STORAGE_ROOT/nomp
sudo mkdir -p $STORAGE_ROOT/nomp/site
sudo mkdir -p $STORAGE_ROOT/nomp/nomp_setup
sudo mkdir -p $STORAGE_ROOT/nomp/nomp_setup/tmp
sudo mkdir -p $STORAGE_ROOT/deamon_builder
sudo mkdir -p $STORAGE_ROOT/wallets
sudo mkdir -p $HOME/daemon_builder
fi
sudo setfacl -m u:$USER:rwx $STORAGE_ROOT
sudo setfacl -m u:$USER:rwx $STORAGE_ROOT/nomp
sudo setfacl -m u:$USER:rwx $STORAGE_ROOT/nomp/site
sudo setfacl -m u:$USER:rwx $STORAGE_ROOT/nomp/nomp_setup
sudo setfacl -m u:$USER:rwx $STORAGE_ROOT/daemon_builder
sudo setfacl -m u:$USER:rwx $STORAGE_ROOT/wallets
sudo setfacl -m u:$USER:rwx $STORAGE_ROOT/nomp/nomp_setup/tmp

# Check swap
echo Checking if swap space is needed and if so creating...
SWAP_MOUNTED=$(cat /proc/swaps | tail -n+2)
SWAP_IN_FSTAB=$(grep "swap" /etc/fstab)
ROOT_IS_BTRFS=$(grep "\/ .*btrfs" /proc/mounts)
TOTAL_PHYSICAL_MEM=$(head -n 1 /proc/meminfo | awk '{print $2}')
AVAILABLE_DISK_SPACE=$(df / --output=avail | tail -n 1)
if
[ -z "$SWAP_MOUNTED" ] &&
[ -z "$SWAP_IN_FSTAB" ] &&
[ ! -e /swapfile ] &&
[ -z "$ROOT_IS_BTRFS" ] &&
[ $TOTAL_PHYSICAL_MEM -lt 1900000 ] &&
[ $AVAILABLE_DISK_SPACE -gt 5242880 ]
then
echo "Adding a swap file to the system..."

# Allocate and activate the swap file. Allocate in 1KB chuncks
# doing it in one go, could fail on low memory systems
dd if=/dev/zero of=/swapfile bs=1024 count=$[1024*1024] status=none
if [ -e /swapfile ]; then
chmod 600 /swapfile
hide_output mkswap /swapfile
swapon /swapfile
fi

# Check if swap is mounted then activate on boot
if swapon -s | grep -q "\/swapfile"; then
echo "/swapfile  none swap sw 0  0" >> /etc/fstab
else
echo "ERROR: Swap allocation failed"
fi
fi

# Set timezone
echo Setting TimeZone to UTC...
if [ ! -f /etc/timezone ]; then
echo "Setting timezone to UTC."
echo "Etc/UTC" > sudo /etc/timezone
restart_service rsyslog
fi

# Add repository
echo Adding the required repsoitories...
if [ ! -f /usr/bin/add-apt-repository ]; then
echo "Installing add-apt-repository..."
hide_output sudo apt-get -y update
apt_install software-properties-common
fi

# Upgrade System Files
echo Updating system packages...
hide_output sudo apt-get update
echo Upgrading system packages...
if [ ! -f /boot/grub/menu.lst ]; then
apt_get_quiet upgrade
else
sudo rm /boot/grub/menu.lst
hide_output sudo update-grub-legacy-ec2 -y
apt_get_quiet upgrade
fi
echo Running Dist-Upgrade...
apt_get_quiet dist-upgrade
echo Running Autoremove...
apt_get_quiet autoremove

echo Installing Base system packages...
apt_install python3 python3-dev python3-pip \
wget curl git sudo coreutils bc \
haveged pollinate unzip \
unattended-upgrades cron ntp fail2ban screen

# ### Seed /dev/urandom
echo Initializing system random number generator...
hide_output dd if=/dev/random of=/dev/urandom bs=1 count=32 2> /dev/null
hide_output sudo pollinate -q -r

# Install `ufw` which provides a simple firewall configuration.
echo Installing UFW...
apt_install ufw

# Allow incoming connections.
ufw_allow ssh;
ufw_allow http;
ufw_allow https;

echo Installing NOMP Required system packages...
if [ -f /usr/sbin/apache2 ]; then
echo Removing apache...
hide_output apt-get -y purge apache2 apache2-*
hide_output apt-get -y --purge autoremove
fi
hide_output sudo apt-get update
apt_install build-essential libtool autotools-dev \
autoconf pkg-config libssl-dev libboost-all-dev git \
libminiupnpc-dev libgmp3-dev

echo Installing Node 8.x
cd $STORAGE_ROOT/nomp/nomp_setup/tmp
curl -sL https://raw.githubusercontent.com/creationix/nvm/v0.33.8/install.sh -o install_nvm.sh
hide_output bash install_nvm.sh
export NVM_DIR="$HOME/.nvm"
[ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh"  # This loads nvm
[ -s "$NVM_DIR/bash_completion" ] && \. "$NVM_DIR/bash_completion"  # This loads nvm bash_completion
source ~/.profile
hide_output nvm install 8.11.4
hide_output nvm use 8.11.4
echo Downloading NOMP Repo...
hide_output sudo git clone https://github.com/Larcea/node-open-mining-portal.git $STORAGE_ROOT/nomp/nomp_setup/nomp


echo Installing Redis...
apt_install build-essential tcl

cd $STORAGE_ROOT/nomp/nomp_setup/tmp
hide_output curl -O http://download.redis.io/redis-stable.tar.gz
hide_output tar xzvf redis-stable.tar.gz
cd redis-stable
hide_output make
hide_output sudo make install
sudo mkdir /etc/redis
sudo cp -r $STORAGE_ROOT/nomp/nomp_setup/tmp/redis-stable/redis.conf /etc/redis

sudo sed -i 's/supervised no/supervised systemd/g' /etc/redis/redis.conf
sudo sed -i 's|dir ./|dir /var/lib/redis|g' /etc/redis/redis.conf

echo '
[Unit]
Description=Redis In-Memory Data Store
After=network.target
[Service]
User=redis
Group=redis
ExecStart=/usr/local/bin/redis-server /etc/redis/redis.conf
ExecStop=/usr/local/bin/redis-cli shutdown
Restart=always
[Install]
WantedBy=multi-user.target
' | sudo -E tee /etc/systemd/system/redis.service >/dev/null 2>&1

hide_output sudo adduser --system --group --no-create-home redis
sudo mkdir /var/lib/redis
sudo chown redis:redis /var/lib/redis
sudo chmod 770 /var/lib/redis
sudo systemctl start redis
sudo systemctl enable redis

echo Database build complete...

echo Building web file structure and copying files...
cd $STORAGE_ROOT/nomp/nomp_setup/nomp
sudo cp -r $STORAGE_ROOT/nomp/nomp_setup/nomp/. $STORAGE_ROOT/nomp/site/


echo Setting correct folder permissions...
whoami=`whoami`
sudo usermod -aG www-data $whoami
sudo usermod -a -G www-data $whoami
sudo usermod -a -G veilnomp $whoami
sudo usermod -a -G veilnomp www-data

sudo find $STORAGE_ROOT/nomp/site/ -type d -exec chmod 775 {} +
sudo find $STORAGE_ROOT/nomp/site/ -type f -exec chmod 664 {} +

sudo chgrp www-data $STORAGE_ROOT -R
sudo chmod g+w $STORAGE_ROOT -R

echo Web build complete...

echo Download and Build coin from tar...
sudo mkdir $STORAGE_ROOT/daemon_builder/veil
sudo mkdir $STORAGE_ROOT/daemon_builder/veil/src
cd $STORAGE_ROOT/daemon_builder/veil/
wget https://github.com/Veil-Project/veil/releases/download/v1.0.0.10/veil-1.0.0-x86_64-linux-gnu.tar.gz
tar xvfz veil-1.0.0-x86_64-linux-gnu.tar.gz
cd $STORAGE_ROOT/daemon_builder/veil/veil-1.0.0/

clear

# Strip and copy to /usr/bin

sudo cp $STORAGE_ROOT/daemon_builder/veil/veil-1.0.0/veild /usr/bin
sudo cp $STORAGE_ROOT/daemon_builder/veil/veil-1.0.0/veild /usr/bin


# Make the new wallet folder and autogenerate the coin.conf
if [[ ! -e '$STORAGE_ROOT/wallets' ]]; then
sudo mkdir -p $STORAGE_ROOT/wallets
fi

sudo setfacl -m u:$USER:rwx $STORAGE_ROOT/wallets
mkdir -p $STORAGE_ROOT/wallets/.veil

rpcpassword=$(openssl rand -base64 29 | tr -d "=+/")
rpcport=$(EPHYMERAL_PORT)

echo 'rpcuser=NOMPrpc
rpcpassword=rpcpasswordchangeme
rpcport=14250
rpcthreads=8
rpcallowip=127.0.0.1
# onlynet=ipv4
maxconnections=12
daemon=1
gen=0
' | sudo -E tee $STORAGE_ROOT/wallets/.veil/veil.conf >/dev/null 2>&1
' | sudo -E tee $HOME/.veil/veil.conf >/dev/null 2>&1
# echo "Starting Veil"
# /usr/bin/veild -generateseed=1 -daemon=1
# /usr/bin/veild -datadir=$STORAGE_ROOT/wallets/.veil -conf=veil.conf -daemon -shrinkdebugfile
# /usr/bin/veild -datadir=$HOME/.veil -conf=veil.conf -daemon -shrinkdebugfile
# Create easy daemon start file
echo '
veild -datadir=$STORAGE_ROOT/wallets/.veil -conf=veil.conf -daemon -shrinkdebugfile
veild -datadir=$HOME/.veil -conf=veil.conf -daemon -shrinkdebugfile
' | sudo -E tee /usr/bin/veil >/dev/null 2>&1
sudo chmod +x /usr/bin/veil

echo 'rpcpassword=rpcpasswordchangeme
rpcport=14250'| sudo -E tee $HOME/daemon_builder/.my.cnf

# Create function for random unused port
function EPHYMERAL_PORT(){
    LPORT=32768;
    UPORT=60999;
    while true; do
        MPORT=$[$LPORT + ($RANDOM % $UPORT)];
        (echo "" >/dev/tcp/127.0.0.1/${MPORT}) >/dev/null 2>&1
        if [ $? -ne 0 ]; then
            echo $MPORT;
            return 0;
        fi
    done
}

echo "Making the NOMPness Monster"

cd $STORAGE_ROOT/nomp/site/

# NPM install and update, user can ignore errors
npm install
npm i npm@latest -g

# Create the coin pool json file
cd $STORAGE_ROOT/nomp/site/pool_configs
sudo cp -r litecoin_example.json veil.json

#Generate new wallet address
# wallet="$(veil-cli -datadir=$STORAGE_ROOT/wallets/.veil -conf="$veil.conf" getnewbasecoinaddress)"

# Allow user account to bind to port 80 and 443 with out sudo privs
apt_install authbind
sudo touch /etc/authbind/byport/80
sudo touch /etc/authbind/byport/443
sudo chmod 777 /etc/authbind/byport/80
sudo chmod 777 /etc/authbind/byport/443

echo Boosting server performance for NOMP...
# Boost Network Performance by Enabling TCP BBR
hide_output sudo apt install -y --install-recommends linux-generic-hwe-16.04
echo 'net.core.default_qdisc=fq' | hide_output sudo tee -a /etc/sysctl.conf
echo 'net.ipv4.tcp_congestion_control=bbr' | hide_output sudo tee -a /etc/sysctl.conf

# Tune Network Stack
echo 'net.core.wmem_max=12582912' | hide_output sudo tee -a /etc/sysctl.conf
echo 'net.core.rmem_max=12582912' | hide_output sudo tee -a /etc/sysctl.conf
echo 'net.ipv4.tcp_rmem= 10240 87380 12582912' | hide_output sudo tee -a /etc/sysctl.conf
echo 'net.ipv4.tcp_wmem= 10240 87380 12582912' | hide_output sudo tee -a /etc/sysctl.conf
echo 'net.ipv4.tcp_window_scaling = 1' | hide_output sudo tee -a /etc/sysctl.conf
echo 'net.ipv4.tcp_timestamps = 1' | hide_output sudo tee -a /etc/sysctl.conf
echo 'net.ipv4.tcp_sack = 1' | hide_output sudo tee -a /etc/sysctl.conf
echo 'net.ipv4.tcp_no_metrics_save = 1' | hide_output sudo tee -a /etc/sysctl.conf
echo 'net.core.netdev_max_backlog = 5000' | hide_output sudo tee -a /etc/sysctl.conf

echo Tuning complete...


