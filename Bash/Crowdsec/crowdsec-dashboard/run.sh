#!/bin/sh

set -e

# Variables
export MB_DB_TYPE="h2"
export MB_DB_FILE="/opt/crowdsec/metabase.db"
export MB_JETTY_HOST="0.0.0.0"
export MB_JETTY_PORT="3000"
# Set min + max java heap size. Recommended to be half your RAM.
export JAVAMIN="256m"
export JAVAMAX="256m"

java -Xms$JAVAMIN -Xmx$JAVAMAX -jar metabase.jar >> /var/log/metabase.log
