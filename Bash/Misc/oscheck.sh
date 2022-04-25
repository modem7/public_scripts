#!/usr/bin/env bash

function osCheck {

    if [ `which yum` ]; then
        echo "OS is RHEL. This script only works on Ubuntu/Debian"
        exit
    elif [ `which apt` ]; then
       echo "OS is Debian/Ubuntu"
    elif [ `which apk` ]; then
       echo "OS is Alpine. This script only works on Ubuntu/Debian"
       exit
    else
       echo "Unknown OS. This script only works on Ubuntu/Debian"
       exit
    fi
}

function userCheck {

    if [[ $(id -u) -ne 0 ]]; then
        echo "Please run as root"
	exit
    fi

}

userCheck
osCheck
