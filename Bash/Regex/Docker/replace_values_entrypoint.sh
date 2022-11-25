#!/bin/sh

# Variables
CONF_FILE="${CONF_FILE:-"/etc/crowdsec/bouncers/crowdsec-cloudflare-bouncer.yaml"}"

# Output Version. Useful for troubleshooting
crowdsec-cloudflare-bouncer -version

# Run recovery mode if variable set
if [ "$RECOVERY" == "true" ]; then
    /usr/local/bin/crowdsec-cloudflare-bouncer -d
    echo "Cloudflare Cleanup Completed. Please remove 'RECOVERY' variable or set to 'false'."
    exit
fi

# Set Variable parameters
if [[ "$DOCKER" == "true" ]]; then

    # CrowdSec Config
    sed -i "/^crowdsec_lapi_url:/ s/:.*/: \${API_URL}/" $CONF_FILE
    sed -i "/^crowdsec_lapi_key:/ s/:.*/: \${API_KEY}/" $CONF_FILE
    sed -i "/^crowdsec_update_frequency:/ s/:.*/: \${UPDATE_FREQ}/" $CONF_FILE

    # Cloudflare Config
    sed -i "/^[[:space:]]*- id:/ s/:.*/: \${ID}/" $CONF_FILE
    sed -i "/^[[:space:]]*- token:/ s/:.*/: \${TOKEN}/" $CONF_FILE
    sed -i "/^[[:space:]]*- zone_id:/ s/:.*/: \${ZONE_ID}/" $CONF_FILE
    sed -i "/^[[:space:]]*- total_ip_list_capacity:/ s/:.*/: \${TOTAL_IP}/" $CONF_FILE
    
    # Bouncer Config
    sed -i "/log_level:/ s/:.*/: \${LOG_LEVEL}/" $CONF_FILE

    # Prometheus Config
    sed -i "/^[[:space:]]*enabled:/ s/:.*/: \${PROM_STATUS}/" $CONF_FILE
    sed -i "/^[[:space:]]*listen_addr:/ s/:.*/: \${PROM_ADDR}/" $CONF_FILE
    sed -i "/^[[:space:]]*listen_port:/ s/:.*/: \${PROM_PORT}/" $CONF_FILE
fi
    
# Start Bouncer
exec /usr/local/bin/crowdsec-cloudflare-bouncer -c $CONF_FILE
