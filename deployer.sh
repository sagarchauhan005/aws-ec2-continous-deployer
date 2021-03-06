#!/usr/bin/env bash

# shellcheck disable=SC2059
RED="\033[1;31m\n"
NOCOLOR="\033[0m\n"
YELLOW='\033[0;33m'
GREEN='\033[0;32m'
WEBHOOK_PORT=9000

if [[ $EUID -ne 0 ]]; then
  printf "${RED}This script must be run as root${NOCOLOR}"
  exit 1
fi

printf "${GREEN}Please select the source of your git repository${NOCOLOR}"
printf "${GREEN}Enter the number corresponding to it to continue${NOCOLOR}"
printf "${GREEN}[1] Github${NOCOLOR}"
printf "${GREEN}[2] Bitbucket${NOCOLOR}"
read -r GIT_SOURCE

sleep 1
printf "${GREEN}Allowing 9000 port for webhook${NOCOLOR}"
sudo ufw allow $WEBHOOK_PORT/tcp

# Accept the name of the app
printf "${GREEN}Enter the name of the app you wish to deploy (avoid spaces and special character)${NOCOLOR}"
read -r app_name

#set hostname for ssh config
if [[ "$GIT_SOURCE" == 1 ]]; then
  hostname="github.com-$app_name"
fi

if [[ "$GIT_SOURCE" == 2 ]]; then
  hostname="bitbucket.org-$app_name"
fi

# Handle dependencies
printf "${YELLOW}Configuring deployment for $app_name.${NOCOLOR}"

sleep 1
command -v git >/dev/null 2>&1 ||
  {
    echo >&2 "Git is not installed. Installing.."
    yum install git
  }

command -v go >/dev/null 2>&1 ||
  {
    echo >&2 "Go is not installed. Installing.."
    apt install golang-go
  }

command -v webhook >/dev/null 2>&1 ||
  {
    echo >&2 "Please wait while we install the package. Installing.."
    sudo apt-get install webhook
  }
cd "$HOME" || exit

# create config for webhooks
app_hook="$HOME/webhooks"
cwd="$HOME/$app_name/deployment/"
hjson="$app_hook/hooks.json"
deploy_script="$HOME/$app_name/deploy.sh"

rm -r "$app_name"
mkdir -p "$app_name" || exit
mkdir -p "$app_hook" || exit
mkdir "$cwd" || exit
if [ ! -f "$hjson" ]
then
    touch "$hjson"
fi

touch "$deploy_script"

sleep 1
printf "${YELLOW}Please enter the branch name for this repo (eg : master, staging, feature etc).${NOCOLOR}"
read -r branch_name

if [ -z "${branch_name}" ]; then
  branch_name="master"
fi

# Accept the git repository link
sleep 1
printf "${YELLOW}Please enter the git repository SSH link (without clone command).${NOCOLOR}"
read -r git_repo
repo_folder_name=$(basename -s .git "$git_repo")

if [[ "$GIT_SOURCE" == 1 ]]; then
  clone_path="${git_repo/\github.com/$hostname}"
fi

if [[ "$GIT_SOURCE" == 2 ]]; then
  clone_path="${git_repo/\bitbucket.org/$hostname}"
fi

sleep 1
printf "${YELLOW}Initializing git in cwd.${NOCOLOR}"

cd "$cwd" || exit
git init
git remote add origin "$git_repo"

sleep 1
printf "${YELLOW}Please enter the absolute path (/srv/tracker/pim/) of your app root directory.${NOCOLOR}"
read -r app_root
base_folder_name=$(basename "$app_root")
dir_name=$(dirname "$app_root")
mv_final_path="$dir_name/$base_folder_name"
#write to deployer script
{
  echo "#!/bin/bash"
  echo "exec 1> command.log 2>&1"
  echo "set -x"
  #echo "rm -r $repo_folder_name" # removes the the last clone copy folder
  #echo "git clone $clone_path" # clones the latest copy
  #echo "rm -r $dir_name/version-backup/$repo_folder_name-latest-backup" # remove the last backup copy [Note required as of now, as its easier to push again then restore]
  #echo "cp -R $app_root $dir_name/version-backup/$repo_folder_name-latest-backup" # create a new backup of current folder [Note required as of now, as its easier to push again then restore]
  #echo "rm -r $app_root" # delete the existing current working app dir
  echo "cd $app_root || exit"
  echo "git fetch origin $branch_name"
  echo "git checkout --force origin/$branch_name"
  #echo "cp -R $repo_folder_name $mv_final_path" # copy the new cloned dir to new app
  echo "chmod -R 775 $mv_final_path" #change permission of new app folder
} >>"$deploy_script"

chmod +x "$deploy_script"

# check jq dependencies
command -v jq >/dev/null 2>&1 ||
  {
    echo >&2 "Jq is not installed. Installing.."
    apt install jq
  }

sleep 1
printf "${GREEN}Enter your server IP${NOCOLOR}"
sleep 1
read -r server_ip

if [[ "$GIT_SOURCE" == 1 ]]; then

  branch="refs/heads/$branch_name"

  sleep 1
  printf "${GREEN}Enter your secret key (Please make sure this is UNIQUE. You need to paste the same in github account)${NOCOLOR}"
  read -r secret

  sleep 1
  printf "${GREEN}Creating webhook config json${NOCOLOR}"

  if [[ -s $hjson ]]; then

    printf "${GREEN}Webhook config json file is NOT EMPTY. Updating the new config${NOCOLOR}"
    jsonConfig=$(jq -n --arg id "$app_name" \
      --arg cwd "$cwd" \
      --arg deployer "$deploy_script" \
      --arg secret "$secret" \
      --arg branch "$branch" \
      --arg deploy_script "$deploy_script" \
      '{"id": $id,"execute-command": $deploy_script,"command-working-directory": $cwd,"response-message": "Executing deploy script...","trigger-rule": {"and":[{"match": {"type": "payload-hash-sha1","secret": $secret,"parameter": {"source": "header","name": "X-Hub-Signature"}}}, {"match": {"type": "value","value": $branch,"parameter": {"source": "payload","name": "ref"}}}]} }')

    updatedJsonConfig=$(jq --argjson updatedJson "$jsonConfig" --argjson groupInfo "$(<"$hjson")" '.[length] += $updatedJson' "$hjson")
    echo "$updatedJsonConfig" >"$hjson"
  else
    printf "${GREEN}Webhook config json file is EMPTY. Adding the new config${NOCOLOR}"
    jq -n --arg id "$app_name" \
      --arg cwd "$cwd" \
      --arg deployer "$deploy_script" \
      --arg secret "$secret" \
      --arg branch "$branch" \
      --arg deploy_script "$deploy_script" \
      '[{"id": $id,"execute-command": $deploy_script,"command-working-directory": $cwd,"response-message": "Executing deploy script...","trigger-rule": {"and":[{"match": {"type": "payload-hash-sha1","secret": $secret,"parameter": {"source": "header","name": "X-Hub-Signature"}}}, {"match": {"type": "value","value": $branch,"parameter": {"source": "payload","name": "ref"}}}]} }]' >"$hjson"
  fi

  sleep 1
  # shellcheck disable=SC2059
  printf "${GREEN}Please copy the below webhook url. Paste the same in your github webhook${NOCOLOR}"
  echo "==============================================================================================="
  echo "http://$server_ip:9000/hooks/$app_name"
  echo "==============================================================================================="
  sleep 2

fi

if [[ "$GIT_SOURCE" == 2 ]]; then

  branch="$branch_name"
  sleep 1
  # shellcheck disable=SC2059
  printf "${GREEN}Enter your secret key (Please make sure this is unqiue. This shall act as your API SECRET for webhook)${NOCOLOR}"
  read -r secret

  hash="$(echo -n "$secret" | md5sum | awk '{print $1}')"

  printf "${GREEN}Creating webhook config json${NOCOLOR}"

  if [[ -s $hjson ]]; then

    printf "${GREEN}Webhook config json file is NOT EMPTY. Updating the new config${NOCOLOR}"
    jsonConfig=$(jq -n --arg id "$app_name" \
      --arg cwd "$cwd" \
      --arg deployer "$deploy_script" \
      --arg hash "$hash" \
      --arg branch "$branch" \
      --arg deploy_script "$deploy_script" \
      '{"id": $id,"execute-command": $deploy_script,"command-working-directory": $cwd,"response-message": "Executing deploy script...","trigger-rule": {"and":[{"match": {"type": "value","value": $hash,"parameter": {"source": "url","name": "key"}}}, {"match": {"type": "value","value": $branch,"parameter": {"source": "payload","name": "push.changes.0.new.name"}}}]}}')

    updatedJsonConfig=$(jq --argjson updatedJson "$jsonConfig" --argjson groupInfo "$(<"$hjson")" '.[length] += $updatedJson' "$hjson")
    echo "$updatedJsonConfig" >"$hjson"
  else
    printf "${GREEN}Webhook config json file is EMPTY. Adding the new config${NOCOLOR}"
    jq -n --arg id "$app_name" \
      --arg cwd "$cwd" \
      --arg deployer "$deploy_script" \
      --arg hash "$hash" \
      --arg branch "$branch" \
      --arg deploy_script "$deploy_script" \
      '[{"id": $id,"execute-command": $deploy_script,"command-working-directory": $cwd,"response-message": "Executing deploy script...","trigger-rule": {"and":[{"match": {"type": "value","value": $hash,"parameter": {"source": "url","name": "key"}}}, {"match": {"type": "value","value": $branch,"parameter": {"source": "payload","name": "push.changes.0.new.name"}}}]}}]' >"$hjson"
  fi
  sleep 1
  # shellcheck disable=SC2059
  printf "${GREEN}Please copy the below webhook url. Paste the same in your bitbucket webhook${NOCOLOR}"
  echo "==============================================================================================="
  echo "http://$server_ip:9000/hooks/$app_name?key=$hash"
  echo "==============================================================================================="
  sleep 2
fi

sleep 1
printf "${GREEN}Copied webhook to etc.${NOCOLOR}"
cp -R "$hjson" "/etc/webhook.conf"
cd "$HOME" || exit

# start webhook
printf "${GREEN}Initializing webhook${NOCOLOR}"
webhook -hooks "$hjson" -ip "$server_ip"

sleep 1
# Generating SSH keys
printf "${GREEN}Generating SSH keys${NOCOLOR}"
email="$app_name@greenhonchos.com"
hostalias="$hostname"
keypath="$HOME/.ssh/${hostname}_rsa"
keypath_pub="$HOME/.ssh/${hostname}_rsa.pub"

printf "${GREEN}Just press enter, when asked for passphrase${NOCOLOR}"
ssh-keygen -t rsa -C "$email" -f "$keypath"

if [[ "$GIT_SOURCE" == 1 ]]; then
  if [ $? -eq 0 ]; then
    cat >>~/.ssh/config <<EOF
    Host $hostalias
            Hostname github.com
            User git
            AddKeysToAgent yes
        IdentitiesOnly yes
            IdentityFile $keypath
EOF
  fi
fi

if [[ "$GIT_SOURCE" == 2 ]]; then
  if [ $? -eq 0 ]; then
    cat >>~/.ssh/config <<EOF
    Host $hostalias
            Hostname bitbucket.org
            User git
            AddKeysToAgent yes
        IdentitiesOnly yes
            IdentityFile $keypath
EOF
  fi
fi

# copy paste the keys in your github deploy keys section
sleep 1

printf "${GREEN} Please copy paste the below mentioned ssk keys and paste into your repo settings.${NOCOLOR}"
sleep 1
cat "$keypath_pub"

#update remote url
cd "$app_root" || exit
git remote set-url origin "$clone_path"
printf "${GREEN} Remote url updated.${NOCOLOR}"

sleep 1
printf "${GREEN} Restarted webhook.${NOCOLOR}"
service webhook restart

printf "${YELLOW}------------------------------------------------${NOCOLOR}"
printf "${RED}Important Information${NOCOLOR}"
printf "${GREEN}* In case of Github webhook, make sure Content type is application/json.${NOCOLOR}"
printf "${GREEN}* Check is Host key is added in known hosts.${NOCOLOR}"
printf "${GREEN}* Make sure AWS Port are allowed.${NOCOLOR}"
printf "${GREEN}* In case webhook doesn't match, try restarting service webhook ${NOCOLOR}"
printf "${GREEN}* In case webhook doesn't match, try restarting ssh : service ssh restart${NOCOLOR}"
printf "${GREEN}* For your front-end app, make sure to update apache.conf file as well. Replace public with dist in path.${NOCOLOR}"
