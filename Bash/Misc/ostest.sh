#!/usr/bin/env bash
    if [ -f /etc/os-release ]; then
        # freedesktop.org and systemd
        . /etc/os-release
        OS=$ID
        OSNAME=$NAME
        VER=$VERSION_ID
    elif type lsb_release >/dev/null 2>&1; then
        # linuxbase.org
        OS=$(lsb_release -si)
        VER=$(lsb_release -sr)
    elif [ -f /etc/lsb-release ]; then
        # For some versions of Debian/Ubuntu without lsb_release command
        . /etc/lsb-release
        OS=$DISTRIB_ID
        VER=$DISTRIB_RELEASE
    #########################################
    #Unsure about the below - needs checking#
    #########################################
    elif [ -f /etc/debian_version ]; then
        # Older Debian/Ubuntu/etc.
        OS=Debian
        VER=$(cat /etc/debian_version)
    elif [ -f /etc/debian_version ]; then
        # Older Debian/Ubuntu/etc.
        OS=Debian
        VER=$(cat /etc/debian_version)
    elif [ -f /etc/SuSe-release ]; then
        # Older SuSE/etc.
        OS=$(cat /etc/SuSe-release)
    elif [ -f /etc/redhat-release ]; then
        # Older Red Hat, CentOS, etc.
        OS=(cat /etc/redhat-release)
    elif [ -f /etc/centos-release ]; then
        # Older CentOS.
        OS=(cat /etc/centos-release)
    ###############
    #End of unsure#
    ###############
    else
        # Fall back to uname, e.g. "Linux <version>", also works for BSD, etc.
        OS=$(uname -s)
        VER=$(uname -r)
    fi
    if [ "${OS,,}" = "fedora" ]; then
        echo "OS is $OSNAME $VER. This script only works on Ubuntu/Debian"
        exit
    elif
        [ "${OS,,}" = "ubuntu" ]; then
        echo "OS is $OSNAME $VER. Hurrah!"
    elif
        [ "${OS,,}" = "arch" ]; then
        echo "OS is $OSNAME $VER. This script only works on Ubuntu/Debian"
        exit
    else
        echo "$OSNAME is Unknown OS. This script only works on Ubuntu/Debian"
        exit
    fi
