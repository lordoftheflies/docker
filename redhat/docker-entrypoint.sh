#!/usr/bin/env bash
set -e

# set default value if not set
[ -z "$CMON_PASSWORD" ] && cmon_password='cmon' || cmon_password=$CMON_PASSWORD
[ -z "$MYSQL_ROOT_PASSWORD" ] && mysql_root_password='password' || mysql_root_password=$MYSQL_ROOT_PASSWORD

CMON_CONFIG=/etc/cmon.cnf
SSH_KEY=/root/.ssh/id_rsa
WWWROOT=/var/www/html
CMONAPI_BOOTSTRAP=$WWWROOT/cmonapi/config/bootstrap.php
CMONAPI_DATABASE=$WWWROOT/cmonapi/config/database.php
CCUI_BOOTSTRAP=$WWWROOT/clustercontrol/bootstrap.php
BANNER_FILE='/root/README_IMPORTANT'
IP_ADDRESS=$(hostname -I)
MYSQL_CMON_CNF=/etc/my_cmon.cnf

# check mysql status
DATADIR=/var/lib/mysql
PIDFILE=${DATADIR}/mysqld.pid
[ -f $PIDFILE ] && rm -f $PIDFILE
echo 'Checking MySQL daemon..'
[ -z $(pidof mysqld_safe) ] && service mysql start || (killall -9 mysqld && service mysql start)

# import data
if [ ! -e $MYSQL_CMON_CNF ]; then
	# configure ClusterControl Controller
	echo "Setting up minimal $CMON_CONFIG.."
	cat /dev/null > $CMON_CONFIG
	cat > "$CMON_CONFIG" << EOF
mysql_port=3306
mysql_hostname=$IP_ADDRESS
mysql_password=$cmon_password
hostname=$IP_ADDRESS
EOF

	echo 'Setting up ClusterControl UI and CMONAPI..'
	## configure ClusterControl UI & CMONAPI
	CMON_TOKEN=$(python -c 'import uuid; print uuid.uuid4()' | sha1sum | cut -f1 -d' ')
	sed -i "s|GENERATED_CMON_TOKEN|$CMON_TOKEN|g" $CMONAPI_BOOTSTRAP
	sed -i "s|MYSQL_PASSWORD|$cmon_password|g" $CMONAPI_DATABASE
	sed -i "s|MYSQL_PORT|3306|g" $CMONAPI_DATABASE
	sed -i "s|DBPASS|$cmon_password|g" $CCUI_BOOTSTRAP
	sed -i "s|DBPORT|3306|g" $CCUI_BOOTSTRAP

	echo 'Generating SSH key..'
	## configure SSH
	AUTHORIZED_FILE=/root/.ssh/authorized_keys
	KNOWN_HOSTS=/root/.ssh/known_hosts
	ssh-keygen -t rsa -N "" -f $SSH_KEY
	cat ${SSH_KEY}.pub >> $AUTHORIZED_FILE
	KEY_TYPE=$(awk {'print $1'} ${SSH_KEY}.pub)
	PUB_KEY=$(awk {'print $2'} ${SSH_KEY}.pub)
	echo "$IP_ADDRESS $KEY_TYPE $PUB_KEY" >> $KNOWN_HOSTS
	chmod 600 $AUTHORIZED_FILE
	
	echo 'Importing CMON data..'
	mysql -uroot -h127.0.0.1 -e 'create schema cmon; create schema dcps;' && \
		mysql -f -uroot -h127.0.0.1 cmon < /usr/share/cmon/cmon_db.sql && \
			mysql -f -uroot -h127.0.0.1 cmon < /usr/share/cmon/cmon_data.sql && \
				mysql -f -uroot -h127.0.0.1 dcps < $WWWROOT/clustercontrol/sql/dc-schema.sql

	# configure CMON user & password
	echo 'Configuring CMON user and MySQL root password..'
	TMPFILE=/tmp/configure_cmon.sql
	cat > "$TMPFILE" << EOF
UPDATE mysql.user SET Password=PASSWORD('$mysql_root_password') WHERE User='root';
DELETE FROM mysql.user WHERE User='';
DELETE FROM mysql.user WHERE User='root' AND Host NOT IN ('localhost', '127.0.0.1', '::1');
DROP DATABASE IF EXISTS test; DELETE FROM mysql.db WHERE DB='test' OR DB='test\\_%';
GRANT ALL PRIVILEGES ON *.* TO 'cmon'@'localhost' IDENTIFIED BY '$cmon_password' WITH GRANT OPTION;
GRANT ALL PRIVILEGES ON *.* TO 'cmon'@'127.0.0.1' IDENTIFIED BY '$cmon_password' WITH GRANT OPTION;
GRANT ALL PRIVILEGES ON *.* TO 'cmon'@'$IP_ADDRESS' IDENTIFIED BY '$cmon_password' WITH GRANT OPTION;
REPLACE INTO dcps.apis(id, company_id, user_id, url, token) VALUES (1, 1, 1, 'https://127.0.0.1/cmonapi', '$CMON_TOKEN');
FLUSH PRIVILEGES;
EOF

	mysql -uroot -h127.0.0.1 < $TMPFILE; rm -f $TMPFILE
	
	echo 'Configuring CMON MySQL defaults file..'
	cat > "$MYSQL_CMON_CNF" << EOF
[mysql_cmon]
user=cmon
password=$cmon_password
EOF

fi

## Start the services
service cmon restart
service sshd restart

## generate a README-IMPORTANT! file to notify the generated credentials
if [ ! -e $BANNER_FILE ]; then
	echo "Please remember following information which produced by the entrypoint file" > $BANNER_FILE
	[ -z "$CMON_PASSWORD" ] && echo "Generated CMON password: $cmon_password" >> $BANNER_FILE || echo "CMON password: $cmon_password" >> $BANNER_FILE
	[ -z "$MYSQL_ROOT_PASSWORD" ] &&	echo "Generated MySQL root password: $mysql_root_password" >> $BANNER_FILE || echo "MySQL root password: $mysql_root_password" >> $BANNER_FILE
	echo "Generated ClusterControl API Token: $CMON_TOKEN" >> $BANNER_FILE
	echo "Detected IP address: $IP_ADDRESS" >> $BANNER_FILE
	echo "To access ClusterControl UI, go to http://${IP_ADDRESS}/clustercontrol" >> $BANNER_FILE
	echo "!! Remove this file once you notified !!" >> $BANNER_FILE
fi

/usr/sbin/httpd -D FOREGROUND