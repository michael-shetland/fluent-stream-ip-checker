#!/bin/bash
set -e

# Set IPSet Listing
ipsetListLevel1=('feodo' 'palevo' 'sslbl' 'zeus' 'zeus_badips' 'dshield' 'spamhaus_drop' 'spamhaus_edrop' 'bogons' 'fullbogons')

# Restore ipsets
if [ -f "/app/ipsets-backup" ]; then
  ipset restore -f /app/ipsets-backup
fi

# Initialize IPSets
if [ ! -f "/etc/firehol/ipsets/initialized" ]; then
  # Clone ipsets
  if [ ! -d "/etc/firehol/ipsets/.git" ]; then
    echo "Downloading FireHOL Blocked IPSets ..."
    git clone \
      --depth=1 \
      --branch=master \
      https://github.com/firehol/blocklist-ipsets.git \
      /etc/firehol/ipsets
  fi

  # Create and Enable default ipsets
  echo "Creating and Enabling Desired FireHOL Blocked IPSets ..."
  set +e
  for x in ${ipsetListLevel1[@]}; do 
    ipset -L $x >/dev/null 2>&1
    if [ $? -ne 0 ]; then
      echo "Creating IPSet '$x' ..."
      ipset create $x hash:net;

      echo "Enabling IPSet '$x' ..."
      /usr/lib/firehol/update-ipsets.sh enable $x;
    fi  
  done
  set -e

  echo "yes" > /etc/firehol/ipsets/initialized
fi

# Refresh IPSets
/app/scripts/refresh-ipsets.sh

# Start Application
node /app/dist/main