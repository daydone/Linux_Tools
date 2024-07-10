#!/bin/sh

##### NOTES: ######
# Authored and maintained by Tristan Walker
# This script does the vast majority of legwork to deploy a
# CONSOLIDATED Flow instance within NocTel. This script is NOT
# for use to deploy at customer location for on-premise (future).
#
# Be aware there are some manual steps that can't be avoided. Please
# execute these steps properly or you won't be happy.
#
# NOTE: symlinks may need to be fixed - make sure anything symlinked
# is pointing to /opt/nocflow and not /opt/noctel-flow
#
# -Manipulate the asterisk sip.conf file to fill in the user and pass
# for SIP trunk to VoIP server with minimal interaction
#
# -Build a custom ISO for CentOS 7 that locally contains all packages,
# scripts, files, etc. needed for deployment to remove the reliance on
# grabbing packages (and varying versions) from the internet.
#
# -Break out the installer to use getopt so flags can be passed to this
# script from the shell to designate what components to install (web+reporting,
# asterisk, mariadb, etc.).
#
# -Clean stuff up a bit and possibly re-organize execution.
#
# -Further distill what packages are needed
# 
# -Create internal wiki resources to help guide and more cleanly explain
# what installation looks like/entails.
#
# -The inevitable changes over time.
#
# -Versioning via source control

#### COLORS~~~ ####
BAD='\033[0;31m'
GOOD='\033[1;32m'
WARN='\033[0;33m'
INFO='\033[1;33m'
NC='\033[0m'


##### System Settling #####

#selinux
echo -e "##### Dealing with SELinux #####\n"
sed -i s/SELINUX=enforcing/SELINUX=permissive/g /etc/selinux/config
setenforce 0
echo -e "09 * * * * root /sbin/ntpdate time.noctel.com &> /dev/null\n" >> /etc/crontab

###### Package Checks ######
# Really important packages like wget, php, php-mysql, etc.
# mysql = mariadb
echo -e "##### Base System Package Installation #####\n"
yum -y install https://$(rpm -E '%{?centos:centos}%{!?centos:rhel}%{rhel}').iuscommunity.org/ius-release.rpm
yum -y install epel-release yum-plugin-replace
yum -y replace php --replace-with php56u
yum -y replace php-mbstring --replace-with php56u-mbstring
yum -y replace php-bcmath --replace-with php56u-bcmath
yum -y replace php-mysql --replace-with php56u-mysql
yum -y install php56u unzip wget mod_ssl php56u-mysql mariadb mariadb-server httpd git vim iftop php56u-mbstring screen ntp php56u-bcmath php56u-memcached php56u-bcmath php56u-mysql php56u-php

###### Service Checks ######

echo -e "##### Base Service Checks #####\n"

# httpd enabled
systemctl is-enabled httpd | grep "enabled" &> /dev/null
if [ $? == 0 ] ; then
	echo -e "${GOOD}INFO${NC}: httpd is enabled on this host. Looking good.\n"
else
	echo -e "${WARN}WARNING${NC}: httpd is not enabled on this host - configuring httpd to be an enabled service...\n"
	systemctl enable httpd
	echo -e "${INFO}INFO${NC}: httpd enabled on host.\n"
fi

systemctl status httpd | grep "active (running)" &> /dev/null
if [ $? == 0 ] ; then
	echo -e "${INFO}INFO${NC}: httpd is already running.\n"
else
	echo -e "${INFO}INFO${NC}: httpd is not running. Starting.\n"
	systemctl start httpd
fi

# firewall stuff here - firewalld is default, but should probably be iptables
echo -e "${INFO}INFO${NC}: Replacing firewalld with iptables...\n"
yum -y install iptables-services
systemctl stop firewalld && systemctl mask firewalld
echo -e "${GOOD}INFO${NC}: iptables installed, firewalld disabled.\n"

# iptables rules go here
rm -f /etc/sysconfig/iptables
echo -e "*filter\n:INPUT ACCEPT [0:0]\n:FORWARD ACCEPT [0:0]\n:OUTPUT ACCEPT [0:0]\n-A INPUT -m state --state RELATED,ESTABLISHED -j ACCEPT\n-A INPUT -p icmp -j ACCEPT\n-A INPUT -i lo -j ACCEPT\n# HTTPD\n-A INPUT -m state --state NEW -m tcp -p tcp --dport 80 -j ACCEPT\n-A INPUT -m state --state NEW -m tcp -p tcp --dport 443 -j ACCEPT\n# SSH\n-A INPUT -m state --state NEW -m tcp -p tcp -s 10.0.64.0/19 --dport 22 -j ACCEPT\n# SNMP\n-A INPUT -m state --state NEW -m udp -p udp -s 10.0.90.101 --dport 161 -j ACCEPT\n# NFS\n-A INPUT -m state --state NEW -m udp -p udp --dport 2049 -s 10.0.64.0/19 -j ACCEPT\n-A INPUT -m state --state NEW -m tcp -p tcp --dport 2049 -s 10.0.64.0/19 -j ACCEPT\n-A INPUT -m state --state NEW -m udp -p udp --dport 111 -s 10.0.64.0/19 -j ACCEPT\n-A INPUT -m state --state NEW -m tcp -p tcp --dport 111 -s 10.0.64.0/19 -j ACCEPT\n-A INPUT -m state --state NEW -m udp -p udp --dport 32769 -s 10.0.64.0/19 -j ACCEPT\n-A INPUT -m state --state NEW -m tcp -p tcp --dport 32803 -s 10.0.64.0/19 -j ACCEPT\n-A INPUT -m state --state NEW -m udp -p udp --dport 892 -s 10.0.64.0/19 -j ACCEPT\n-A INPUT -m state --state NEW -m tcp -p tcp --dport 892 -s 10.0.64.0/19 -j ACCEPT\n-A INPUT -m state --state NEW -m udp -p udp --dport 875 -s 10.0.64.0/19 -j ACCEPT\n-A INPUT -m state --state NEW -m tcp -p tcp --dport 875 -s 10.0.64.0/19 -j ACCEPT\n-A INPUT -m state --state NEW -m udp -p udp --dport 662 -s 10.0.64.0/19 -j ACCEPT\n-A INPUT -m state --state NEW -m tcp -p tcp --dport 662 -s 10.0.64.0/19 -j ACCEPT\n# VoIP\n-A INPUT -m state --state NEW -m udp -p udp --dport 1024:65534 -j ACCEPT\n-A INPUT -j REJECT --reject-with icmp-host-prohibited\n-A FORWARD -j REJECT --reject-with icmp-host-prohibited\nCOMMIT" > /etc/sysconfig/iptables

systemctl start iptables && systemctl enable iptables
echo -e "${GOOD}INFO${NC}: iptables started and set on startup. Production firwall rules set.\n"

systemctl is-enabled iptables | grep "enabled" &> /dev/null
if [ $? == 0 ] ; then
	echo -e "${GOOD}INFO${NC}: looking good.\n"
else
	echo -e "${WARN}ERROR${NC}: iptables is not enabled on host. This is not a breaking issue, but please do remediate this after.\n"
fi

###### VoIP Related ######

echo -e "##### Hold Onto Your Butts, We're Doing VoIP Setup #####\n"

# Sox
echo -e "### Installing and Configuring Sox ###\n"
su -c 'yum -y localinstall --nogpgcheck http://download1.rpmfusion.org/free/el/updates/7/x86_64/r/rpmfusion-free-release-7-1.noarch.rpm'
yum -y install lame lame-devel libogg-devel vorbis-tools libvorbis-devel flac-devel libmad libmad-devel twolame twolame-devel gcc gcc-c++ autoconf automake

# Grab epel
rpm -ivh http://dl.fedoraproject.org/pub/epel/7/x86_64/Packages/e/epel-release-7-11.noarch.rpm

wget https://downloads.sourceforge.net/project/sox/sox/14.4.2/sox-14.4.2.tar.gz
tar xvzf sox-14.4.2.tar.gz
cd sox-14.4.2
./configure
make -s
make install
echo "include /usr/local/lib" >> /etc/ld.so.conf
/sbin/ldconfig
cd ..

# test to see if mp3 support is present
sox | grep "mp3"
if [ $? == 0 ] ; then
	echo -e "${GOOD}INFO${NC}: Sox successfully installed with mp3 support.\n"
else
	echo -e "${BAD}ERROR${NC}: Sox either not successfully installed or does not include mp3 support. Exiting.\n"
	exit 1
fi

###### DbFace Setup #####

echo -e "##### Flow Reporting Setup #####\n"

echo -e "### Installing and Configuring Ioncube Loader ###\n"

# grab ioncube tar:
wget http://downloads3.ioncube.com/loader_downloads/ioncube_loaders_lin_x86-64.tar.gz
tar xvzf ioncube_loaders_lin_x86-64.tar.gz

### figure out php version, default module path, and ini location ###

# ini finding:
_phpini=`php --ini | grep "Loaded Configuration File" | awk -v N=4 '{print $N}'`

# Set a timezone to avoid a problem later...
echo "date.timezone = UTC" >> $_phpini

# php version - only need major and sub version:
_phpver=`php -v | grep "(cli)" | awk -v N=2 '{print $N}' | cut -d '.' -f 1,2`

# figure out php module directory:
_phpmods=`php -i | grep "extension_dir => /" | awk -F ' => ' '{print $2;}'`

### Install ioncube to PHP ###

# Move the appropriate ioncube module to the php mods directory:
_ioncube="ioncube_loader_lin_$_phpver.so"
cp ioncube/$_ioncube $_phpmods/

# Modify php.ini to use ioncube loader
# The placement in the ini for this actually doesn't matter
echo -e "\nzend_extension = $_phpmods/$_ioncube" >> $_phpini

# Restart httpd to finalize ioncube loader install
systemctl restart httpd 
systemctl status httpd | grep "active (running)" &> /dev/null
if [ $? == 0 ] ; then
	echo -e "${GOOD}INFO${NC}: httpd restarted correctly.\n"
else
	echo -e "${BAD}ERROR${NC}: httpd was unable to restart correctly. Please check configuration - particularly the php.ini file, which is located at $_phpini.\nThis script will now exit.\n"
exit 1
fi

### Finalize ioncube install ###

# Check PHP to see it's using ioncube loader: 
php -v | grep "with the ionCube PHP Loader (enabled)" &> /dev/null
if [ $? == 0 ] ; then
	echo -e "${GOOD}CHECK PASSED${NC}: ioncube loader installed.\n"
	echo -e "${INFO}NEXT${NC}: Cleaning up unneeded directories and files from ioncube install...\n"
	rm -rf ioncube_loaders_lin_x86-64.tar.gz
# Give notice if ioncube was no bueno...
else
	echo -e "${BAD}ERROR${NC}: ioncube loader not detected. This installer will abort. Please check that PHP is installed with a version between 4, 5, and 7 (not 6) and that Apache (httpd) is installed on this host.\n"
	echo  -e "${BAD}NOTICE${NC}: Rolling back change to $_phpini...\n"
	sed -i '$ d' $_phpini
	exit 1
fi

### Install reporting component ###
#Unfortunately right now this simply presumes php 5.4

# grab the zip
#wget https://s3-ap-southeast-1.amazonaws.com/download-dbface/v8/dbface_php5.4.zip
#mv dbface_php5.4.zip /opt/
#cd /opt
#mkdir dbface
#unzip dbface_php5.4.zip -d dbface/

#_dbface="/opt/dbface"


# set permissions
#chmod -R 777 $_dbface/config/ ; chmod -R 777 $_dbface/user/ ; chmod 777 $_dbface/application/cache/ ; chmod 777 $_dbface/application/logs/ 

# symlink to wherever
# ln -s <source> <dest>
#echo -e "NOTICE: Don't forget to symlink dbface to /var/www/html/ - TODO implemented.\n"

# invite to sanity check:
#echo -e "NOTICE: At this point you should check that reporting is properly installed and reachable. Also apply licensing at necessary and modify configs to suit the deployment's needs.\n"

##### And Now the Repo Pulling Stuff... ######

echo -e "##### Preparing the Repo - Some Manual Steps Will Ensue #####\n"

#run ssh-keygen - cat out ~/.ssh/id_rsa.pub
echo -e "${INFO}INFO${NC}: Invoking ssh-keygen...\n"
# this SHOULD generate the default key w/o any prompts
ssh-keygen -t rsa -N ""

echo -e "${INFO}INFO${NC}: Please copy the following output into an SSH access key for the repo:\n"
cat ~/.ssh/id_rsa.pub

#Pause - tell user to create the access only entry in BB for repo
echo -e "\n\n${INFO}Press any key to proceed after adding the sshkey to access for the repo.\n"
read -n 1 -s

#Resume - pull master after initializing repo in /opt
echo -e "${INFO}INFO${NC}: Now attempting to clone the repo.\n"
cd /opt
git init
echo -e "yes\n" | git clone git@bitbucket.org:tristan_walker/noctel-flow.git

#Once repo is cloned, move configs around to where they need to be

echo -e "### Doing the Switcheroo on the Repo Directory Naming. Symlinks *Will* Break ###\n"
cd /opt
mv noctel-flow/ nocflow/

#Pushing reporting to a local copy sidesteps git pull issues
#Particularly as this doesn't really change version to version
ln -s /opt/nocflow/cp/ /var/www/html/cp
cp /opt/nocflow/reporting/ /opt/nocflow/reporting-local
ln -s /opt/nocflow/reporting-local/ /opt/nocflow/cp/reporting
chmod 777 /opt/nocflow/cp/img/avatars

_reporting="/opt/nocflow/reporting-local"
mkdir /opt/nocflow/reporting/application/cache
chmod -R 777 $_reporting/config/ ; chmod -R 777 $_reporting/user/ ; chmod 777 $_reporting/application/cache/ ; chmod 777 $_reporting/application/logs/

echo "127.0.0.1 flow " >> /etc/hosts

# CHANGE THIS since the dir structure in repo will match the system
echo -e "### Starting Flow Services - These Will Fail to Start If Symlinks are Bad ###\n"

#This failed on the Chevs install...
cp /opt/nocflow/usr/lib/systemd/system/nf-pnc.service /usr/lib/systemd/system/ ; cp /opt/nocflow/usr/lib/systemd/system/nf-mediamonitor.service /usr/lib/systemd/system/
systemctl enable nf-pnc ; systemctl start nf-pnc
systemctl enable nf-mediamonitor ; systemctl start nf-mediamonitor

# Create a cron job to check for updates to Flow every day at midnight
_git=`which git`
#echo "0 8 * * * root cd /opt/nocflow && $_git pull origin master &> /dev/null" >> /etc/crontab  

##### Asterisk #####

echo -e "##### Here Comes Big Bad Asterisk - Some Manual Steps Will Ensue #####\n"
# get needed packages - GraphicsMagick is put here because it's in EPEL
yum -y install openssl-devel mysql-devel ncurses-devel newt-devel libxml2-devel kernel-devel gcc gcc-c++ sqlite-devel libuuid-devel json-glib-devel libtool GraphicsMagick

# setup stupid jansson for asterisk...grrrrr....
echo -e "### Stupid Jansson... ###\n"
cd /usr/src/
git clone https://github.com/akheron/jansson.git
cd jansson
autoreconf -i
./configure -prefix=/usr/
make && make install

# Now address Asterisk
cd ~
wget http://downloads.asterisk.org/pub/telephony/asterisk/asterisk-13-current.tar.gz

tar xvfz asterisk*
_astdir=`ls -d */ | grep asterisk`
cd $_astdir

#config and compile - this WILL prompt a menu
#Just hit Save & Exit without making any changes
./configure --libdir=/usr/lib64 && make menuselect && make && make install && make config

#this might change
_repopath="/opt/nocflow"

cp "$_repopath/usr/local/bin/ast" /usr/local/bin/
cp "$_repopath/usr/lib/systemd/system/asterisk.service" /usr/lib/systemd/system/
cp "$_repopath/etc/asterisk/*" /etc/asterisk/
rm -f /var/lib/asterisk/agi-bin
ln -s "$_repopath/agi-bin/" /var/lib/asterisk/agi-bin

systemctl enable asterisk
systemctl start asterisk

echo -e "### Please Sanity Check sip.conf for This Host ###\n"

#restart crond because at this point there will likely be
#several jobs for NocTel and Flow
systemctl restart crond

# TODO - probably also want to put up a solid httpd.conf to minimize
# config variation or human error.
cp -f "$_repopath/etc/conf/httpd.conf" /etc/httpd/conf/
systemctl restart httpd

# Add inputs for variables to the noctel.conf file that will be different for each instance
# stuff like dbpass, dbbase, etc. - this will grow over time.

# Add in some prompts for info that can't be seeded - the instance is usually the hostname.noctel.com, so flow-noctel.noctel.com (bad example)

echo -e "[flow]\ndbhost=127.0.0.1\ndbuser=control\ndbpass=lfVM2Xh7Lrgg9-Q\ndbbase=flow" > /etc/noctel.conf

##### Logrotate & Syslog ######

echo -e "##### Log Rotation #####\n"

#nocflow rotation
echo -e "/var/log/nocflow.log {\ndaily\nrotate 30\nmissingok\ncompress\ndelaycompress\nnotifempty\n}" > /etc/logrotate.d/nocflow

#httpd
echo -e "/var/log/httpd/*log {\ndaily\nrotate 14\nmissingok\nnotifempty\nsharedscripts\ndelaycompress\npostrotate\n    /bin/systemctl reload httpd.service > /dev/null 2>/dev/null || true\nendscript\n}" > /etc/logrotate.d/httpd

#asterisk
echo -e "/var/log/asterisk/*_log
/var/log/asterisk/debug
/var/log/asterisk/warning {
	hourly	
	rotate 3
	missingok
	compress
	postrotate
		/usr/sbin/asterisk -rx 'logger reload' > /dev/null 2> /dev/null
	endscript
}
/var/log/asterisk/messages {
	daily
	rotate 30
	missingok
	compress
	delaycompress
	notifempty
	sharedscripts
	postrotate
		/usr/sbin/asterisk -rx 'logger reload' > /dev/null 2> /dev/null
	endscript
}" > /etc/logrotate.d/asterisk

#/var/log/messages
echo -e "/var/log/messages {\ndaily\nrotate 30\nmissingok\ncompress\ndelaycompress\nnotifempty\n}" > /etc/logrotate.d/messages

# TODO - add in syslog configs for ELK? At the very least, NMS config.

##### DB Manipulation ######

echo -e "##### Mucking with the DB #####\n"

echo -e "### Starting MariaDB/MySQL Secure Install - Manual Steps Ensue ###\n"
systemctl restart mariadb
systemctl enable mariadb

echo -e "${INFO}NOTICE${NC}: Be sure to store the password for the root mysql user in 1Pass.\n"
mysql_secure_installation

echo -e "${INFO}INPUT${NC}: Please enter the mysql root password that  was just used in the setup process.\n"
read -s sqlpw

# DB IMPORT AND CREATE HERE
echo -e "### Creating and Seeding Default Data ###\n"

echo "CREATE DATABASE flow;" | mysql -u root -p$sqlpw
mysql -u root -p$sqlpw flow < /opt/nocflow/db/flow.sql
cp /opt/nocflow/db/flow-default-data.sql.gz ~/
gunzip ~/flow-default-data.sql.gz
mysql -u root -p$sqlpw flow < /opt/nocflow/db/flow-default-data.sql
echo -e "ALTER TABLE `agent` ADD `vmextension` VARCHAR(128) NOT NULL AFTER `extension`;" | mysql -u root -p$sqlpw flow

echo -e "${INFO}INFO${NC}: Creating the fetch_global user function.\n"
cat /opt/nocflow/db/global_fetch | mysql -u root -p$sqlpw

#Import the timezone table into mysql core db to be able to use CONVERT_TZ
mysql_tzinfo_to_sql /usr/share/zoneinfo | mysql -u root -p$sqlpw mysql

echo -e "${INFO}INFO${NC}: Creating the default Flow admin user, please provide the MySQL root pw.\n"
echo  'INSERT INTO user SET id=10001, username="admin",password=md5("GoFlow!"),status="active",klevel=4;' | mysql -u root -p$sqlpw flow


# This is the user that writes to the DB from the web UI
echo -e "${INFO}INFO${NC}: Creating the Flow web MySQL User and Reporting User.\n"

# Add in the default users needed by the system
echo -e "CREATE USER 'control'@'localhost' IDENTIFIED BY 'lfVM2Xh7Lrgg9-Q';GRANT SELECT, INSERT, UPDATE, DELETE ON *.* TO 'control'@'localhost' IDENTIFIED BY 'lfVM2Xh7Lrgg9-Q' REQUIRE NONE WITH MAX_QUERIES_PER_HOUR 0 MAX_CONNECTIONS_PER_HOUR 0 MAX_UPDATES_PER_HOUR 0 MAX_USER_CONNECTIONS 0; FLUSH PRIVILEGES;" | mysql -u  root -p$sqlpw

echo -e "${INFO}INFO${NC}: Granting execute permissions on functions to users.\n"

echo -e "GRANT EXECUTE ON FUNCTION flow.fetch_global TO 'control'@'localhost';" | mysql -u root -p$sqlpw

echo -e "CREATE USER 'reporting'@'127.0.0.1' IDENTIFIED BY 'LNc8mJMtM\$Fu\$J'; GRANT SELECT ON *.* TO 'reporting'@'127.0.0.1'; GRANT EXECUTE ON FUNCTION flow.fetch_global TO 'reporting'@'127.0.0.1'; FLUSH PRIVILEGES;" | mysql -u root -p$sqlpw

#Don't know what to do for this...does this need rsync?
echo -e "${INFO}INFO${NC}: Creating DB backup user.\n"

echo -e "${INFO}Please provide a randomly generated password for the backup user: \n"
read -s bpass
echo -e "CREATE USER 'backup'@'localhost' IDENTIFIED BY '$bpass'; GRANT USAGE ON *.* TO 'backup'@'localhost' IDENTIFIED BY '$bpass' ; GRANT SELECT, LOCK TABLES, SHOW VIEW, EVENT, TRIGGER ON *.* TO 'backup'@'localhost' ; FLUSH PRIVILEGES;" | mysql -u root -p$sqlpw 

#schedule the mysqldump for 04:00 UTC
cd ~
mkdir flow_backups
mv /opt/nocflow/backups/backup.sh ~/flow_backups/
chmod 755 ~/flow_backups/ ; chmod +x ~/flow_backups/backup.sh
sed -i -e "s/REPLACETHISPW/${bpass}/g" ~/flow_backups/backup.sh

#Presumes script is already there - needs to be in the repo
echo -e "\n31 4 * * * root /root/flow_backups/backup.sh &> /dev/null\n" >> /etc/crontab

# Add in jobs for the pruning scripts that will be added
#echo -e "0 4 * * * root php /opt/nocflow/bin BLAH BLAH BLAH &> /dev/null\n"

# Need to do this so any configuration that puts you into ast can run commands
systemctl restart asterisk
systemctl restart nf-pnc ; systemctl restart nf-mediamonitor
touch /var/log/nocflow.log
chmod 777 /var/log/nocflow.log
systemctl restart crond

echo -e "\n\n${INFO}Please do check your confs: httpd.conf, sip.conf, and php.ini among other things. This script is not perfect. If something failed earlier on, review and remediate."

echo -e "${WARN}TAKE NOTE${NC}: There are still likely straggling dev references in configuration and actual code. So sanity check those places. php.ini and httpd.conf need to be carried over/modified from a working instance while things are settled in.\n\nThat is all."

exit 0
