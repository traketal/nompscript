
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
