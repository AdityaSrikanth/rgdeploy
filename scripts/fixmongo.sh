#!/bin/bash

if [ "$1" == "-h" ]  || [ $# -lt 4 ]; then
  echo "Usage: `basename $0` db_name admin_password user_name user_password"
  echo '    Param 1: Name of the DB you want to use for application user e.g. PROD-cc'
  echo '    Param 2: Administrator user password'
  echo '    Param 3: User to create e.g. App'
  echo '    Param 4: User password'
  echo '    Param 5: (optional) URL for SNS Callback'
  echo '             Will use public-host-name if not passed'
  echo '             e.g. https://myrg.example.com'
  exit 0
fi
[ -z RG_HOME ] && RG_HOME='/opt/deploy/sp2'
echo "RG_HOME=$RG_HOME"
# First check if the IP at which mongod is listening is correct
mymongoip=`cat /etc/mongod.conf | sed -n -e 's/bindIp: \([^,]*\).*/\1/p' | sed -e 's/\s*//'`
echo "Mongod configured to listen at $mymongoip"
myip=$(wget -q -O - http://169.254.169.254/latest/meta-data/local-ipv4)
echo "Private IP of this machine is $myip"
if [ "$mymongoip" != "$myip" ]; then
   echo "Mongo is listening on a different IP $mymongoip than the private ip of the machine $myip"
   exit 1
fi

myurl=$5
if [ -z $myurl ]; then
    public_host_name="$(wget -q -O - http://169.254.169.254/latest/meta-data/public-hostname)"
    baseurl="http://$public_host_name/"
else
    baseurl="$myurl/"
fi
systemctl is-active --quiet mongod
if [ $? -gt 0 ]; then
    echo "mongod service is not running. Starting..."
    service mongod start
    sleep 5
    systemctl is-active --quiet mongod
     if [ $? -gt 0 ]; then
        echo "Could not start mongod service"
        service mongod status
        exit 1
     fi
fi

# Modify the database to create roles and configs
echo "Modifying database $1 to create roles and configs"
mongo --host "$myip" "$1"<<EOF
db.createRole({
  role: "readWriteMinusDropRole",
  privileges: [
  {
    resource: { db: "$1", collection: ""},
    actions: [ "collStats", "dbHash", "dbStats", "find", "killCursors", "listIndexes", "listCollections", "convertToCapped", "createCollection", "createIndex", "dropIndex", "insert", "remove", "renameCollectionSameDB", "update"]} ],
    roles: []
  }
);
db.configs.remove({"key":"snsUrl"});
db.configs.insert({"key":"snsUrl","value":"$baseurl"});
use admin;
db.createUser({user: "admin",pwd: "$2",roles: [ { role: "userAdminAnyDatabase", db: "admin"},{role: "readWriteAnyDatabase", db: "admin"}]})
db.createUser({user: "$3", pwd: "$4", roles: [{role: 'readWriteMinusDropRole', db: "$1"}]})
EOF

[ $? -gt 0 ] && echo "Could not create roles and configs. Exiting!" && exit 1
rootca="${RG_HOME}/config/rootCA.key"
rlca="${RG_HOME}/config/RL-CA.pem"
mongodbkey="${RG_HOME}/config/mongodb.key"
mongodbcsr="${RG_HOME}/config/mongodb.csr"
mongodbcrt="${RG_HOME}/config/mongodb.crt"
echo "Creating mongodb.pem file"
host_name="$(wget -q -O - http://169.254.169.254/latest/meta-data/local-hostname | sed -e 's/\..*//')"
openssl genrsa -out "$rootca" 2048
openssl req -x509 -new -nodes -key "$rootca" -sha256 -days 1024 -out "$rlca" -subj "/CN=."
openssl genrsa -out "$mongodbkey" 2048
openssl req -new -key "$mongodbkey" -out "$mongodbcsr" -subj "/CN=$host_name"
openssl x509 -req -in "$mongodbcsr" -CA "$rlca" -CAkey "$rootca" -CAcreateserial -out "$mongodbcrt" -days 500 -sha256
cat "$mongodbkey" "$mongodbcrt" > "$RG_HOME/config/mongodb.pem"

echo "Roles Created. Enabling authorization in mongod.conf"
if [ -f /etc/mongod.conf ]; then
        echo "mongod.conf exists"
        sed  -i -e '/Enable ssl/, +4 s/^#//' -e "s/authorization:.*/authorization: enabled /" -e "s#PEMKeyFile:.*#PEMKeyFile: $RG_HOME/config/mongodb.pem#" -e "s#CAFile:.*#CAFile: $rlca#" /etc/mongod.conf
        cat /etc/mongod.conf | grep -e 'authorization' -e 'PEMKeyFile' -e 'CAFile'
        echo "Restarting MongoD"
        service mongod restart
        sleep 10
else
        echo 'Cannot find /etc/mongod.conf'
        exit 1
fi
