#!/bin/bash
# Script to easily create maintenance window issue for Upptime.
# Author: modem7 - https://github.com/modem7
# Date: 14/09/2021

##################################
###### Change these values #######
##################################

# Edit Timezone if required
export TZ=Europe/London

# Enter how long your maintenance window is for
mainthour="1" # 0 value allowed
maintmin="30" # 0 value allowed

# Enter services to be down (make sure to keep the quotes, and comma separate the values)
expecteddown="website, analytics"

###########################################
###### Don't change these variables #######
###########################################

# Start time variable. Don't change.
    starttime=$(date +"%Y-%m-%dT%H:%M:%S%z")

# Maintenance window variables. Don't change.
    maintwindow="${mainthour} hours ${maintmin} minutes"

    endtime=$(date -d "${maintwindow} hence" +"%Y-%m-%dT%H:%M:%S%z")

    nicestart=$(date -d "$(echo ${starttime} | sed 's/T/ /')")
    niceend=$(date -d "$(echo ${endtime} | sed 's/T/ /')")

#####################
###### Output #######
#####################

# Output required fields for maintenance issue.
echo "#################### Copy values below ####################"
echo "### Scheduled maintenance"
echo "Affected services: _**$expecteddown**_"
echo "Lasting from _**$nicestart**_ to _**$niceend**_"
echo
echo "<!--"
echo "start: $starttime"
echo "end: $endtime"
echo "expectedDown: $expecteddown"
echo "-->"
echo "#################### Copy values above ####################"
