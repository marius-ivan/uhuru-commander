#!/bin/bash

#This script does the following:
#- deploys a new micro bosh
#- copies necessary files to the new VM
#- runs build.sh as root on the new VM

. config.sh

function deploy_micro()
{
  micro_bosh_yml=deployments/micro_bosh/micro_bosh.yml

  ruby -e "
require 'yaml'
config = YAML.load_file('${micro_bosh_yml}')

config['network']['ip'] = '${micro_bosh_vm_ip}'


config['cloud']['properties']['vcenters'][0]['host'] = '${vsphere_host}'
config['cloud']['properties']['vcenters'][0]['address'] = '${vsphere_host}'
config['cloud']['properties']['vcenters'][0]['user'] = '${vsphere_user}'
config['cloud']['properties']['vcenters'][0]['password'] = '${vsphere_password}'

config['cloud']['properties']['vcenters'][0]['datacenters'][0]['name'] = '${datacenter}'
config['cloud']['properties']['vcenters'][0]['datacenters'][0]['vm_folder'] = '${vm_folder}'
config['cloud']['properties']['vcenters'][0]['datacenters'][0]['template_folder'] = '${template_folder}'
config['cloud']['properties']['vcenters'][0]['datacenters'][0]['disk_path'] = '${disk_path}'
config['cloud']['properties']['vcenters'][0]['datacenters'][0]['datastore_pattern'] = '${datastore}'
config['cloud']['properties']['vcenters'][0]['datacenters'][0]['persistent_datastore_pattern'] = '${datastore}'

config['cloud']['properties']['vcenters'][0]['datacenters'][0]['clusters'][0] = '${cluster}'

File.open('${micro_bosh_yml}', 'w') do |file|
 yaml = YAML.dump(config)
 file.write(yaml.gsub(\" \n\", \"\n\"))
 file.flush
end
"

  cd deployments

  echo "Running: bosh micro deployment micro_bosh"
  bosh micro deployment micro_bosh

  echo "Running: bosh micro deploy ${micro_stemcell}"
  bosh -n micro deploy ${micro_stemcell} || bosh -n micro deploy ${micro_stemcell} --update
  cd ..
}

function upload_files()
{
  mv ~/.ssh/known_hosts ~/.ssh/known_hosts.bk

  echo -e "${color_cyan}Uploading resources to micro VM ${color_white}'${micro_bosh_vm_ip}'${color_normal}"

  sshpass -p ${micro_bosh_vm_password} scp -o StrictHostKeyChecking=no build.sh                     ${micro_bosh_vm_user}@${micro_bosh_vm_ip}:/tmp
  sshpass -p ${micro_bosh_vm_password} scp -o StrictHostKeyChecking=no compilation_manifest.yml     ${micro_bosh_vm_user}@${micro_bosh_vm_ip}:/tmp
  sshpass -p ${micro_bosh_vm_password} scp -o StrictHostKeyChecking=no fs/etc/init.d/ucc            ${micro_bosh_vm_user}@${micro_bosh_vm_ip}:/tmp
  sshpass -p ${micro_bosh_vm_password} scp -o StrictHostKeyChecking=no fs/etc/init.d/ttyjs          ${micro_bosh_vm_user}@${micro_bosh_vm_ip}:/tmp
  sshpass -p ${micro_bosh_vm_password} scp -o StrictHostKeyChecking=no fs/etc/rc.local              ${micro_bosh_vm_user}@${micro_bosh_vm_ip}:/tmp
  sshpass -p ${micro_bosh_vm_password} scp -o StrictHostKeyChecking=no fs/usr/sbin/change_ips.sh    ${micro_bosh_vm_user}@${micro_bosh_vm_ip}:/tmp
  sshpass -p ${micro_bosh_vm_password} scp -o StrictHostKeyChecking=no fs/usr/sbin/net_conf.sh      ${micro_bosh_vm_user}@${micro_bosh_vm_ip}:/tmp
  sshpass -p ${micro_bosh_vm_password} scp -o StrictHostKeyChecking=no Gemfile                      ${micro_bosh_vm_user}@${micro_bosh_vm_ip}:/tmp
  sshpass -p ${micro_bosh_vm_password} scp -o StrictHostKeyChecking=no Gemfile.lock                 ${micro_bosh_vm_user}@${micro_bosh_vm_ip}:/tmp
  sshpass -p ${micro_bosh_vm_password} scp -o StrictHostKeyChecking=no config.sh                    ${micro_bosh_vm_user}@${micro_bosh_vm_ip}:/tmp

  sshpass -p ${micro_bosh_vm_password} ssh -o StrictHostKeyChecking=no ${micro_bosh_vm_user}@${micro_bosh_vm_ip} "echo ${micro_bosh_vm_password}|sudo -S mv /tmp/config.sh                  /root/"
  sshpass -p ${micro_bosh_vm_password} ssh -o StrictHostKeyChecking=no ${micro_bosh_vm_user}@${micro_bosh_vm_ip} "echo ${micro_bosh_vm_password}|sudo -S mv /tmp/build.sh                   /root/"
  sshpass -p ${micro_bosh_vm_password} ssh -o StrictHostKeyChecking=no ${micro_bosh_vm_user}@${micro_bosh_vm_ip} "echo ${micro_bosh_vm_password}|sudo -S mv /tmp/compilation_manifest.yml   /root/"
  sshpass -p ${micro_bosh_vm_password} ssh -o StrictHostKeyChecking=no ${micro_bosh_vm_user}@${micro_bosh_vm_ip} "echo ${micro_bosh_vm_password}|sudo -S mv /tmp/ucc                        /etc/init.d"
  sshpass -p ${micro_bosh_vm_password} ssh -o StrictHostKeyChecking=no ${micro_bosh_vm_user}@${micro_bosh_vm_ip} "echo ${micro_bosh_vm_password}|sudo -S mv /tmp/ttyjs                      /etc/init.d"
  sshpass -p ${micro_bosh_vm_password} ssh -o StrictHostKeyChecking=no ${micro_bosh_vm_user}@${micro_bosh_vm_ip} "echo ${micro_bosh_vm_password}|sudo -S mv /tmp/rc.local                   /etc"
  sshpass -p ${micro_bosh_vm_password} ssh -o StrictHostKeyChecking=no ${micro_bosh_vm_user}@${micro_bosh_vm_ip} "echo ${micro_bosh_vm_password}|sudo -S mv /tmp/change_ips.sh              /usr/sbin/"
  sshpass -p ${micro_bosh_vm_password} ssh -o StrictHostKeyChecking=no ${micro_bosh_vm_user}@${micro_bosh_vm_ip} "echo ${micro_bosh_vm_password}|sudo -S mv /tmp/net_conf.sh                /usr/sbin/"
  sshpass -p ${micro_bosh_vm_password} ssh -o StrictHostKeyChecking=no ${micro_bosh_vm_user}@${micro_bosh_vm_ip} "echo ${micro_bosh_vm_password}|sudo -S mv /tmp/Gemfile                    /root/"
  sshpass -p ${micro_bosh_vm_password} ssh -o StrictHostKeyChecking=no ${micro_bosh_vm_user}@${micro_bosh_vm_ip} "echo ${micro_bosh_vm_password}|sudo -S mv /tmp/Gemfile.lock               /root/"

  mv ~/.ssh/known_hosts.bk ~/.ssh/known_hosts
}

function start_stuff()
{
  mv ~/.ssh/known_hosts ~/.ssh/known_hosts.bk
  sshpass -p ${micro_bosh_vm_password} ssh -o StrictHostKeyChecking=no ${micro_bosh_vm_user}@${micro_bosh_vm_ip} "echo ${micro_bosh_vm_password}|sudo -S /root/build.sh $*"
  mv ~/.ssh/known_hosts.bk ~/.ssh/known_hosts
}

param_present 'deployer_setup_vm'       $* && deploy_micro
param_present 'deployer_upload'         $* && upload_files
param_present 'deployer_start_build'    $* && start_stuff $*
