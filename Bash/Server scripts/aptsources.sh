#!/bin/bash

CODENAME="$(lsb_release -cs)"

for file in /etc/apt/sources.list.d/*.list; 
   do
      APT_URL="$(cat $file | grep -Eo '(http|https)://[a-zA-Z0-9./?=_-]*' | sort | uniq)"
      CURRENT_CODES="$(cat $file | rev | awk '{NF=2}1' | rev | awk '{print $1;}')"
      LENGTH=${#APT_URL}
      [[ ${APT_URL:LENGTH-1:1} != */ ]] && APT_URL="$APT_URL/"; :
      NEW_APT_URL="${APT_URL}dists/${CODENAME}"
      echo -n "$NEW_APT_URL"
      STATUS=$(curl --head --location --write-out %{http_code} --silent --output /dev/null ${NEW_APT_URL})
      if [[ $STATUS == 200 ]]; then
         echo -en "\e[93m OK\033[0m"
         for code in $CURRENT_CODES;
            do
               [[ $code != $CODENAME ]] && sudo sed -i "s/$code/$CODENAME/g" $file
         done;
         sudo sed -i 's/^# \(.*\) # disabled on upgrade to.*/\1/g' $file
         echo -e "\e[92m DONE\033[0m"
      else
         echo -e "\e[91m NOT FOUND\033[0m"
      fi
done;