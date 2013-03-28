#!/bin/bash

local_ip=`ifconfig eth0|grep -w inet|cut -f 2 -d ":"|cut -f 1 -d " "`
PATH="/var/vcap/bosh/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:/usr/X11R6/bin"
TERM="xterm"

. config.sh

function switch_to_http_sub_modules()
{
    sed -i "s/git@github.com:/https:\/\/${git_user}:${git_password}@github.com\//g" .gitmodules
}

function install_packages()
{
    apt-get update
    apt-get -y install git-core ftp zerofree postgresql-client gpm dialog ipcalc

    cd /root/
    gem install bundler
    bundle install --system
}

function get_commander()
{
    rm -rf /var/vcap/store/ucc

    pwd=`pwd`
    cd /root
    git clone ${git_commander_repo}
    cd private-uhuru-commander
    git reset --hard ${git_commander_commit}
    switch_to_http_sub_modules

    mkdir /var/vcap/store/ucc
    mv private-uhuru-commander/* /var/vcap/store/ucc/
    rm -rf private-uhuru-commander

    cd /var/vcap/store/ucc/web-ui/config
    rm -f /var/vcap/store/ucc/web-ui/config/infrastructure.yml

    cd /var/vcap/store/ucc/web-ui/bin
    bundle install
    cd ${pwd}
}


function stemcells()
{
    pwd=`pwd`

    bosh --user admin --password admin target localhost
    bosh login admin admin

    mkdir /var/vcap/data/permanenttmp

    mount -o bind /var/vcap/data/permanenttmp /tmp
    chmod 1777 /tmp

    cd /var/vcap/store/ucc/web-ui/resources

    ftp -inv ${ftp_host}<<END_FTP
user ${ftp_user} ${ftp_password}
cd bosh/stemcells
binary
passive
get ${windows_stemcell}
get ${windows_sql_stemcell}
get ${linux_stemcell}
get ${linux_php_stemcell}
bye
END_FTP

    bosh upload stemcell /var/vcap/store/ucc/web-ui/resources/${windows_stemcell}
    bosh upload stemcell /var/vcap/store/ucc/web-ui/resources/${windows_sql_stemcell}
    bosh upload stemcell /var/vcap/store/ucc/web-ui/resources/${linux_stemcell}
    bosh upload stemcell /var/vcap/store/ucc/web-ui/resources/${linux_php_stemcell}

    cd ${pwd}
}

function create_release()
{
    rm -rf /var/vcap/store/ucc/web-ui/resources/private-cf-release/dev_releases
    pwd=`pwd`
    git clone ${git_cf_release}
    cd private-cf-release
    git reset --hard ${git_cf_release_commit}
    switch_to_http_sub_modules
    ./update

    bosh --non-interactive create release --with-tarball
    release_tarball=`ls /var/vcap/store/ucc/web-ui/resources/private-cf-release/dev_releases/*.tgz`
    bosh upload release ${release_tarball}
    cd ${pwd}
    rm -rf /var/vcap/store/ucc/web-ui/resources/private-cf-release
}

function cleanup()
{
    rm -f /root/.bash_history
    rm -f /root/.ssh/*
    rm -f /root/build.sh
    rm -f /var/vcap/data/tmp/private-cf-release/dev_releases/bosh-release-122.1-dev.tgz
    rm -f /root/compilation_manifest.yml
    rm -f /root/Gemfile
    rm -f /root/Gemfile.lock
}

function configure_init()
{
    chmod 1777 /tmp

    update-rc.d ucc defaults 99
    update-rc.d ttyjs defaults 99

    cat /etc/service/agent/run|grep -v "/var/vcap/bosh/agent/bin/agent" >/tmp/agent_run
    echo '#exec /usr/bin/nice -n -10 /var/vcap/bosh/agent/bin/agent -c -I $(cat /etc/infrastructure)' >>/tmp/agent_run
    mv -f /tmp/agent_run /etc/service/agent/run

    echo "*/1 * * * * service ucc status || service ucc restart" >/var/spool/cron/crontabs/vcap
    echo "*/1 * * * * service ttyjs status || service ttyjs restart" >>/var/spool/cron/crontabs/vcap
    chown vcap.vcap /var/spool/cron/crontabs/vcap
}

function deploy_cf()
{
    echo "update stemcells set name=replace(name, 'empty-', '')" | PGPASSWORD="postgres" psql -U postgres -h localhost -d bosh

    uuid=`bosh status|grep UUID|awk '{print $2}'`
    sed -i s/REPLACEME/${uuid}/g /root/compilation_manifest.yml

    bosh deployment /root/compilation_manifest.yml

    for i in `seq 1 10` ;
    do
        bosh --non-interactive deploy
        [ $? -eq 0 ] &&
        {
            echo "update stemcells set name='empty-' || name" | PGPASSWORD="postgres" psql -U postgres -h localhost -d bosh
            break
        }
    done
}

function install_tty_js()
{
    cwd=`pwd`
    rm -rf /var/vcap/store/ucc/tty.js

    cd /tmp
    mkdir nodejs
    cd nodejs
    wget -N http://nodejs.org/dist/node-latest.tar.gz
    tar xzvf node-latest.tar.gz && cd `ls -rd node-v*`
    ./configure
    make install

    cd ..
    mkdir npm
    cd npm
    wget http://npmjs.org/install.sh --no-check-certificate
    bash install.sh
    cd ..

    git clone ${git_ttyjs}
    cd private-ttyjs
    git reset --hard ${git_ttyjs_commit}
    cd ..

    mkdir /var/vcap/store/ucc/tty.js
    mv private-tty.js/* /var/vcap/store/ucc/tty.js/

    rm -rf private-tty.js npm nodejs

    cd /var/vcap/store/ucc/tty.js/
    npm install

    cd ${cwd}
}

function zero_free()
{
    cd /root
    monit stop all
    sleep 60
    umount /tmp
    umount /tmp
    umount /tmp
    umount /dev/sdc1
    zerofree /dev/sdc1
    umount /dev/loop0
    umount /dev/sdb2
    zerofree /dev/sdb2
}


param_present 'micro_packages'          $* && install_packages
param_present 'micro_commander'         $* && get_commander
param_present 'micro_stemcells'         $* && stemcells
param_present 'micro_create_release'    $* && create_release
param_present 'micro_config_daemons'    $* && configure_init
param_present 'micro_ttyjs'             $* && install_tty_js
param_present 'micro_compile'           $* && deploy_cf
param_present 'micro_cleanup'           $* && cleanup
param_present 'micro_zero_free'         $* && zero_free
