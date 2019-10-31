#!/bin/bash
# exit when any command fails
set -e

# setup logging
epoch=$(date +%s)
exec 3>&1 4>&2
trap 'exec 2>&4 1>&3' 0 1 2 3 RETURN
exec 1>log.$epoch.out 2>&1

# keep track of the last executed command
trap 'last_command=$current_command; current_command=$BASH_COMMAND' DEBUG
# echo an error message before exiting
trap 'echo "\"${last_command}\" command failed with exit code $?."' EXIT

echo "$(date)"

if [[ $(id -u) -ne 0 ]]
then 
  echo "Please run as root" >&3
  exit 1
fi

echo "Backup Reclass" >&3
tar czvf reclass.bak.$epoch.tgz /srv/salt/reclass
# restore with "sudo tar xf reclass.bak.$epoch.tgz -C /"

echo "Backup salt-formula-linux" >&3
tar czvf salt-formula-linux.bak.$epoch.tgz /srv/salt/env/prd/linux

echo "Update system reclass model" >&3
cd /srv/salt/reclass/classes/system
head=$(git log --name-status HEAD^..HEAD --pretty=format:%h|head -1)
tag=$(git log -1 --format=format:"%h" 2018.4.0)
if [ "$head" != "$tag" ]
then
  echo "  Reclass model is not pointed at 2018.4.0" >&3
  recenttag=$(git describe --tags --abbrev=0)
  branchtag=$(git log -1 --format=format:"%h" $recenttag)
  if [ "$branchtag" != "$tag" ]
  then
    echo "    Not on 2018.4.0 branch - exiting" >&3	
    echo "    System reclass needs checking"
    exit 1
  fi  
  echo "    On 2018.4.0 branch - updating" >&3
fi

untracked=$(git diff-index --quiet HEAD --|| echo "1")
if [ "$untracked" = "1" ]
then
  echo "  Untracked changes - stashing" >&3	
  git stash
fi  
git pull origin release/2018.4.0
if [ "$untracked" = "1" ]
then
  echo "  Restoring untracked changes" >&3	
  git stash pop
fi

cd /srv/salt/reclass/classes/cluster
cluster=$(find ./ -name 'kvm.yml' -printf "%h\n"|grep infra|awk -F "/" '{print $2}'|sort -u)
cd /srv/salt/reclass/classes/cluster/$cluster

if [ -d "opencontrail" ]
then
  echo "Opencontrail detected" >&3
  echo "  Update opencontrail repos" >&3
  egrep -lRZ "system\.linux\.system\.repo\.mcp\.contrail" . | xargs -0 -l sed -i \
  's/system\.linux\.system\.repo\.mcp\.contrail/system.linux.system.repo.mcp.apt_mirantis.contrail/g'  || true

  if [ -f "opencontrail/compute.yml" ]
  then
    sed -i 's/classes:/classes:\n- system.linux.system.repo.mcp.apt_mirantis.contrail_ocata/g' opencontrail/compute.yml  || true 
  fi

  if [ -f "openstack/proxy.yml" ]
  then
    sed -i 's/classes:/classes:\n- system.linux.system.repo.mcp.apt_mirantis.contrail_ocata/g' openstack/proxy.yml  || true 
  fi

  if [ -f "openstack/control.yml" ]
  then
    sed -i 's/classes:/classes:\n- system.linux.system.repo.mcp.apt_mirantis.contrail_ocata/g' openstack/control.yml  || true 
  fi       	

  if ! grep linux_system_codename_contrail opencontrail/compute.yml
  then
    echo "  Adding linux_system_codename_contrail parameter for compute nodes" >&3
    sed -i 's/  _param:/  _param:\n    linux_system_codename_contrail: ${_param:linux_system_codename}/g' opencontrail/compute.yml	
  else
  	echo "  Updating linux_system_codename_contrail parameter for compute nodes" >&3
    sed -i '/linux_system_codename_contrail/d' opencontrail/compute.yml
    sed -i 's/  _param:/  _param:\n    linux_system_codename_contrail: ${_param:linux_system_codename}/g' opencontrail/compute.yml
  fi  

  if ! grep linux_repo_contrail_version opencontrail/init.yml
  then
    echo "  Adding linux_repo_contrail_version" >&3
    sed -i 's/  _param:/  _param:\n    linux_repo_contrail_version: 3.2/g' opencontrail/init.yml	
  else
  	echo "  Updating linux_repo_contrail_version parameter" >&3
    sed -i '/linux_repo_contrail_version/d' opencontrail/init.yml
    sed -i 's/  _param:/  _param:\n    linux_repo_contrail_version: 3.2/g' opencontrail/init.yml
  fi     
fi

echo "Update apt repository" >&3
egrep -lRZ "system\.linux\.system\.repo\.mcp\.apt_mirantis\.saltstack_2016_3" . | xargs -0 -l sed -i \
's/system\.linux\.system\.repo\.mcp\.apt_mirantis\.saltstack_2016_3/system.linux.system.repo.mcp.apt_mirantis.saltstack/g' || true
egrep -lRZ "system\.linux\.system\.repo\.mcp\.extra" . | xargs -0 -l sed -i \
's/system\.linux\.system\.repo\.mcp\.extra/system.linux.system.repo.mcp.apt_mirantis.extra/g' || true
egrep -lRZ "system\.linux\.system\.repo\.mcp\.salt" . | xargs -0 -l sed -i \
's/system\.linux\.system\.repo\.mcp\.salt/system.linux.system.repo.mcp.apt_mirantis.salt-formulas/g' || true

echo "Add new parameters" >&3
if ! grep system.defaults infra/init.yml
then
  echo "  Adding system defaults" >&3	
  sed -i '/classes:/a - system.defaults' infra/init.yml
fi
if ! grep mcp_version infra/init.yml
then
  echo "Adding mcp version" >&3	
  mcp_version=$(grep apt_mk_version: infra/init.yml|cut -d':' -f2)
  sed -i "/apt_mk_version: 2018.4.0/a \    mcp_version:$mcp_version" infra/init.yml
fi

echo "Checking repository classes" >&3
if ! egrep -lRZ "system\.linux\.system\.repo\.mcp\.apt_mirantis\.update\."
then	
  echo "  Add update repository classes" >&3
  egrep -lRZ "system\.linux\.system\.repo\.mcp\.apt_mirantis\." . | xargs -0 -l sed -i \
's/\(\ *\)- \(system\.linux\.system\.repo\.mcp\.apt_mirantis\.\)\(ceph\|contrail\|contrail_ocata\|docker\|elastic\|extra\|openstack\|salt-formulas\|saltstack\|ubuntu\)/&\n\1- \2update.\3/g'
fi
echo "Remove old updates repository" >&3
sed -i '/- system.linux.system.repo.mcp.updates/d' infra/init.yml

echo "Update jenkins pipline parameter" >&3
newtext='jenkins_pipelines_branch: "release\/${_param:mcp_version}"'
oldtext=$(grep jenkins_pipelines_branch infra/init.yml| awk '{$1=$1};1'| sed 's/\//\\\//g')
sed -i "s/$oldtext/$newtext/g" infra/init.yml

echo "Refresh pillars" >&3
salt '*' saltutil.clear_cache && salt '*' saltutil.refresh_pillar

echo "Verify reclass compiles" >&3
salt '*' saltutil.sync_all 
reclass -i

echo "Update salt-formula-linux" >&3
apt-get install debsums -y
formula=$(dpkg -l | grep salt-formula-linux|awk '{print $3}')
formula_ver=$(cut -d'~' -f1 <<<$formula)
version=2017.4.1+201804181255.bb0708d~xenial1
version_ver=$(cut -d'~' -f1 <<<$version)
flag=1
if [ "$formula" != "$version" ]
then
  echo "  salt-formula-linux is not correct version" >&3
  if dpkg --compare-versions $formula_ver ge $version_ver
  then
    echo "    Formula is more recent..continuing" >&3
    flag=0
  elif dpkg --compare-versions $formula_ver le $version_ver 
  then
    echo "    Older package..upgrading" >&3	
    if ! debsums -s salt-formula-linux
    then
      echo "      Formula has been customized. Customizations will need re-applying. Exiting."
    fi  	
  else
    echo "    Unsure about package - needs manual check..exiting." >&3
    exit 1 
  fi   
fi

if [ "$flag" = "1" ]
then
  cd /tmp
  wget http://mirror.mirantis.com/update/2018.4.0/salt-formulas/xenial/pool/main/s/salt-formula-linux/salt-formula-linux_2017.4.1%2B201903271703.deac9a2~xenial1_all.deb \
  -O salt-formula-linux.deb
  dpkg -i salt-formula-linux.deb
fi  	

echo "Update Linux repos" >&3
# rerun the following salt states after restoring backup of reclass to revert
salt '*' cmd.run 'rm -v /etc/apt/preferences.d/* || true'
salt '*' cmd.run 'rm -v /etc/apt/preferences || true'
salt '*' cmd.run 'rm -v /etc/apt/sources.list /etc/apt/sources.list.d/* || true'
salt '*' saltutil.pillar_refresh
salt '*' saltutil.sync_all
salt 'cfg01*' state.apply reclass.storage
salt '*' saltutil.pillar_refresh
salt '*' saltutil.sync_all
salt '*' state.sls linux.system.repo
##

echo "Verify other Salt formulas" >&3
for i in $(dpkg-query -W -f='${Package}\n' | sed "s/ //g" |grep 'salt-formula-'); \
do debsums -s ${i}; done

echo "Update Salt formulas" >&3
salt -C I@salt:master state.apply salt.master
salt '*' saltutil.sync_all

echo "Run Jenkins piplines" >&3
host=$(salt "cid01*" pillar.get jenkins:client:master:host --out=txt|awk '{print $2}')
user=$(salt "cid01*" pillar.get jenkins:client:master:username --out=txt|awk '{print $2}')
password=$(salt "cid01*" pillar.get jenkins:client:master:password --out=txt|awk '{print $2}')
port=$(salt "cid01*" pillar.get jenkins:client:master:port --out=txt|awk '{print $2}')
credentials=$(salt "cid01*" pillar.get jenkins:client:job_template:git_mirror_downstream_common:template:scm:credentials --out=txt| awk '{print $2}')
targeturl=$(salt "cid01*" pillar.get jenkins:client:job_template:git_mirror_downstream_common:template:scm:url --out=txt| awk '{print $2}')
sourceurl=$(salt "cid01*" pillar.get jenkins:client:job_template:git_mirror_downstream_common:jobs:1:upstream --out=txt| awk '{print $2}')

generate_post_data()
{ 
  cat <<EOF	
json={"parameter": [
{"name":"BRANCHES", "value":"release/2018.4.0"}, 
{"name":"CREDENTIALS_ID", "value":"$credentials"}, 
{"name":"SOURCE_URL", "value":"$sourceul"}, 
{"name":"TARGET_URL", "value":"$targeturl"}]}
EOF
}

echo "Update mk-pipelines" >&3
job_url=http://$user:$password@$host:$port/job/git-mirror-downstream-mk-pipelines
job_status_url=${job_url}/lastBuild/api/json
grep_return_code=0
curl -X POST $job_url/build --data-urlencode "$(generate_post_data)"

set +e
while [ $grep_return_code -eq 0 ]
do
  sleep 30
  echo "checking build status..." >&3
  curl --silent $job_status_url | grep result\":null > /dev/null
  grep_return_code=$?
done
echo "  update finished" >&3  
set -e	

sshurl=$(salt -C I@jenkins:client pillar.get jenkins:client:job_template:git_mirror_downstream_common:template:param:TARGET_URL:default --out=txt| awk '{print $2}')
downstream=$(salt "cid01*" pillar.get jenkins:client:job_template:git_mirror_downstream_common:jobs:0:downstream --out=txt| awk '{print $2}')
sourceurl=$(salt "cid01*" pillar.get jenkins:client:job_template:git_mirror_downstream_common:jobs:0:upstream --out=txt| awk '{print $2}')
targeturl=$(sed s#"{{downstream}}"#"$downstream"# <<< "$sshurl")

echo "Update pipelines library" >&3
job_url=http://$user:$password@$host:$port/job/git-mirror-downstream-pipeline-library
job_status_url=${job_url}/lastBuild/api/json
grep_return_code=0
curl -X POST $job_url/build --data-urlencode "$(generate_post_data)"

set +e
while [ $grep_return_code -eq 0 ]
do
  sleep 30
  echo "checking build status..." >&3
  curl --silent $job_status_url | grep result\":null > /dev/null
  grep_return_code=$?
done
echo "  update finished" >&3
set -e

echo "Deploy update pipeline" >&3
salt 'cid01*' state.sls jenkins.client.job

echo "Commit reclass changes" >&3
cd /srv/salt/reclass/
git add -A
git commit -m "Repositories update for 2018.4.1"

echo "Finished" >&3
exit 0
