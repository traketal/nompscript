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
if [ ! -d $STORAGE_ROOT/nomp/nomp_setup ]; then
sudo mkdir -p $STORAGE_ROOT/nomp/nomp_setup
sudo mkdir -p $STORAGE_ROOT/nomp/nomp_setup/tmp
sudo mkdir -p $STORAGE_ROOT/nomp/site
sudo mkdir -p $STORAGE_ROOT/nomp/starts
sudo mkdir -p $STORAGE_ROOT/wallets
sudo mkdir -p $HOME/multipool/daemon_builder
fi
sudo setfacl -m u:$USER:rwx $STORAGE_ROOT/nomp
sudo setfacl -m u:$USER:rwx $STORAGE_ROOT/nomp/site
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

if [ -z "$DISABLE_FIREWALL" ]; then
# Install `ufw` which provides a simple firewall configuration.
echo Installing UFW...
apt_install ufw

# Allow incoming connections.
ufw_allow ssh;
ufw_allow http;
ufw_allow https;

# ssh might be running on an alternate port. Use sshd -T to dump sshd's #NODOC
# settings, find the port it is supposedly running on, and open that port #NODOC
# too. #NODOC
SSH_PORT=$(sshd -T 2>/dev/null | grep "^port " | sed "s/port //") #NODOC
if [ ! -z "$SSH_PORT" ]; then
if [ "$SSH_PORT" != "22" ]; then

echo Opening alternate SSH port $SSH_PORT. #NODOC
ufw_allow $SSH_PORT #NODOC

fi
fi

sudo ufw --force enable;
fi #NODOC

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
hide_output sudo git clone https://github.com/traketal/node-open-mining-portal.git $STORAGE_ROOT/nomp/nomp_setup/nomp


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
sudo usermod -a -G crypto-data $whoami
sudo usermod -a -G crypto-data www-data

sudo find $STORAGE_ROOT/nomp/site/ -type d -exec chmod 775 {} +
sudo find $STORAGE_ROOT/nomp/site/ -type f -exec chmod 664 {} +

sudo chgrp www-data $STORAGE_ROOT -R
sudo chmod g+w $STORAGE_ROOT -R

echo Web build complete...

echo Download and Build coin from tar...

clear

# LS the SRC dir to have user input bitcoind and bitcoin-cli names
cd $STORAGE_ROOT/daemon_builder/temp_coin_builds/$coindir/src/
find . -maxdepth 1 -type f \( -perm -1 -o \( -perm -10 -o -perm -100 \) \) -printf "%f\n"
read -e -p "Please enter the coind name from the directory above, example bitcoind :" coind
read -e -p "Is there a coin-cli, example bitcoin-cli [y/N] :" ifcoincli

if [[ ("$ifcoincli" == "y" || "$ifcoincli" == "Y") ]]; then
read -e -p "Please enter the coin-cli name :" coincli
fi

clear

# Strip and copy to /usr/bin
sudo strip $STORAGE_ROOT/daemon_builder/temp_coin_builds/$coindir/src/$coind
sudo cp $STORAGE_ROOT/daemon_builder/temp_coin_builds/$coindir/src/$coind /usr/bin
if [[ ("$ifcoincli" == "y" || "$ifcoincli" == "Y") ]]; then
sudo strip $STORAGE_ROOT/daemon_builder/temp_coin_builds/$coindir/src/$coincli
sudo cp $STORAGE_ROOT/daemon_builder/temp_coin_builds/$coindir/src/$coincli /usr/bin
fi

# Make the new wallet folder and autogenerate the coin.conf
if [[ ! -e '$STORAGE_ROOT/wallets' ]]; then
sudo mkdir -p $STORAGE_ROOT/wallets
fi

sudo setfacl -m u:$USER:rwx $STORAGE_ROOT/wallets
mkdir -p $STORAGE_ROOT/wallets/."${coind::-1}"

rpcpassword=$(openssl rand -base64 29 | tr -d "=+/")
rpcport=$(EPHYMERAL_PORT)

echo 'rpcuser=NOMPrpc
rpcpassword='${rpcpassword}'
rpcport='${rpcport}'
rpcthreads=8
rpcallowip=127.0.0.1
# onlynet=ipv4
maxconnections=12
daemon=1
gen=0
' | sudo -E tee $STORAGE_ROOT/wallets/."${coind::-1}"/"${coind::-1}".conf >/dev/null 2>&1
' | sudo -E tee $HOME/."${coind::-1}"/"${coind::-1}".conf >/dev/null 2>&1
echo "Starting ${coind::-1}"
/usr/bin/veild -generateseed=1 -daemon=1
/usr/bin/"${coind}" -datadir=$STORAGE_ROOT/wallets/."${coind::-1}" -conf="${coind::-1}.conf" -daemon -shrinkdebugfile
/usr/bin/"${coind}" -datadir=$HOME/."${coind::-1}" -conf="${coind::-1}.conf" -daemon -shrinkdebugfile
# Create easy daemon start file
echo '
"${coind}" -datadir=$STORAGE_ROOT/wallets/."${coind::-1}" -conf="${coind::-1}.conf" -daemon -shrinkdebugfile
"${coind}" -datadir=$HOME/."${coind::-1}" -conf="${coind::-1}.conf" -daemon -shrinkdebugfile
' | sudo -E tee /usr/bin/"${coind::-1}" >/dev/null 2>&1
sudo chmod +x /usr/bin/"${coind::-1}"
# If we made it this far everything built fine removing last coin.conf and build directory
sudo rm -r $STORAGE_ROOT/daemon_builder/temp_coin_builds/.lastcoin.conf
sudo rm -r $STORAGE_ROOT/daemon_builder/temp_coin_builds/$coindir
sudo rm -r $HOME/multipool/daemon_builder/.my.cnf
echo 'rpcpassword='${rpcpassword}'
rpcport='${rpcport}''| sudo -E tee $HOME/multipool/daemon_builder/.my.cnf
