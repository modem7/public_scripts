#Script Information
#Creation Date: 25/11/2021
#Purpose: To create Splunk admin password, hash password with SHA512, HEC token, and SSH password
 
#Variables
splunkpass=$(< /dev/urandom tr -dc _A-Z-a-z-0-9 | head -c${1:-16};echo;)
sshpass=$(< /dev/urandom tr -dc _A-Z-a-z-0-9 | head -c${1:-16};echo;)
passwordhash=$(openssl passwd -6 $splunkpass)
uuid=$(uuidgen)
sslpass=$(< /dev/urandom tr -dc A-Z-a-z-0-9 | head -c${1:-16};echo;)
date=$(date)
 
clear
echo "$date"
echo
printf "\U1F6A7\U1F6A7\U1F6A7\U1F6A7\U1F6A7 Password and UUID Generator \U1F6A7\U1F6A7\U1F6A7\U1F6A7\U1F6A7\n"
echo
echo Splunk admin password:
echo "$splunkpass"
echo
echo Splunk admin password hash:
echo "$passwordhash"
echo
echo UUID/HEC Token:
echo "$uuid"
echo
echo SSH Password:
echo "$sshpass"
echo
echo SSL Cert Password:
echo "$sslpass"
