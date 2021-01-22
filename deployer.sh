#!/usr/bin/env bash

RED="\033[1;31m\n"
NOCOLOR="\033[0m\n"
YELLOW='\033[0;33m'
GREEN='\033[0;32m'

if [[ $EUID -ne 0 ]]; then
   printf "${RED}This script must be run as root${NOCOLOR}"
   exit 1
fi

# Accept the name of the app
printf "${GREEN}Enter the name of the app you wish to deploy (avoid spaces and special character)${NOCOLOR}"
read -r app_name

#set hostname for ssh config
hostname="github.com-$app_name"

# Handle dependencies
printf "${YELLOW}Configuring deployment for $app_name.${NOCOLOR}"

sleep 1
command -v git >/dev/null 2>&1 ||
{ echo >&2 "Git is not installed. Installing..";
  yum install git
}

command -v go >/dev/null 2>&1 ||
{ echo >&2 "Go is not installed. Installing..";
  apt  install golang-go
}

command -v webhook >/dev/null 2>&1 ||
{ echo >&2 "Please wait while we install the package. Installing..";
  sudo apt-get install webhook
}
cd "$HOME" || exit

# create config for webhooks
app_hook="$HOME/$app_name/webhooks"
cwd="$HOME/$app_name/deployment/"
hjson="$HOME/$app_name/webhooks/hooks.json"
deploy_script="$HOME/$app_name/webhooks/deploy.sh"

rm -r "$app_name"
mkdir "$app_name" || exit
mkdir "$app_hook"
mkdir "$cwd"
touch "$hjson"
touch "$deploy_script"

# Accept the git repository link
sleep 1
printf "${YELLOW}Please enter the git repository SSH link (without clone command).${NOCOLOR}"
read -r git_repo
repo_folder_name=$(basename -s .git "$git_repo");
clone_path="${git_repo/\github.com/$hostname}"
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
#//TODO Make the name of the backup folder dynamic
{
  echo "#!/bin/bash"
  echo "rm -r $repo_folder_name >& rm-existing-clone.txt"
  echo "git clone $clone_path >& clone.txt"
  echo "rm -r $dir_name/latest-backup >& rm-backup.txt"
  echo "cp -R $app_root $dir_name/latest-backup >& backup.txt"
  echo "rm -r $app_root >& rm-app.txt"
  echo "cp -R $repo_folder_name $mv_final_path >& cp.txt"
  echo "chmod -R 775 $mv_final_path"
  echo "touch script_ran.txt"
} >> "$deploy_script"

chmod +x "$deploy_script"

sleep 1
printf "${GREEN}Enter your secret key (Please make sure this is unqiue. You need to paste the same in github account)${NOCOLOR}"
read -r secret

# check jq dependencies
command -v jq >/dev/null 2>&1 ||
{ echo >&2 "Jq is not installed. Installing..";
  apt install jq
}

sleep 1
printf "${GREEN}Creating webhook config json${NOCOLOR}"
jq -n --arg id "$app_name" \
      --arg cwd "$cwd" \
      --arg deployer "$deploy_script" \
      --arg secret "$secret" \
      --arg deploy_script "$deploy_script" \
'[{"id": $id,"execute-command": $deploy_script,"command-working-directory": $cwd,"response-message": "Executing deploy script...","trigger-rule": {"match": {"type": "payload-hash-sha1","secret": $secret,"parameter": {"source": "header","name": "X-Hub-Signature"}}}}]' > "$hjson"

sleep 1
printf "${GREEN}Copied webhook to etc.${NOCOLOR}"
cp -R "$hjson" "/etc/webhook.conf"
cd "$HOME" || exit

sleep 1
printf "${GREEN}Enter your server IP${NOCOLOR}"
sleep 1
read -r server_ip

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
if [ $? -eq 0 ]; then
cat >> ~/.ssh/config <<EOF
Host $hostalias
        Hostname github.com
        User git
        AddKeysToAgent yes
    IdentitiesOnly yes
        IdentityFile $keypath
EOF
fi

# copy paste the keys in your github deploy keys section
sleep 1

printf "${GREEN} Please copy paste the below mentioned ssk keys and paste into your repo settings.${NOCOLOR}"
sleep 1
cat "$keypath_pub"

#restart webhook
sleep 1
printf "${GREEN} Restarted webhook.${NOCOLOR}"
service webhook restart