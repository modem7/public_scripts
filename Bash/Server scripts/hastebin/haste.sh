#!/bin/bash
# Please install the following before running this script:
# curl and xclip

HASTE_URL="https://hastebin.mydomain.com/"
HASTE_UPLOAD_URL=$HASTE_URL'documents/'

raw=false

function help() {
    echo ""
    echo "  -r, --raw"
    echo "  prints the raw link"
    echo ""
    exit
}

function haste() {
    contents=$(cat $1)

    echo $(curl -X POST -s -d "$contents" $HASTE_UPLOAD_URL)
}

function makeUrl() {
    code=$(echo "$1" | awk -F '"' '{print $4}')

    if [ $2 = true ]; then
        url=$HASTE_URL'raw/'$code
    else
        url=$HASTE_URL$code
    fi

    echo $url
}

until [ -z $1 ]; do
    case $1 in
    -h | --help)
        help
        ;;

    -r | --raw)
        raw=true
        ;;

    *)
        result=$(haste $1)
        url=$(makeUrl $result $raw)

        echo $url
        ;;
    esac
    shift
done
