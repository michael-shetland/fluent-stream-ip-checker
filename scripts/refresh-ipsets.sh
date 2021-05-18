#!/bin/sh
set -e

# Get Latest ipsets From Git hub
echo "Pulling latest FireHOL Blocked IPSets ..."
currentPWD=$PWD
cd /etc/firehol/ipsets
git reset --hard # Need to reset, else pull may fail
git pull
cd $currentPWD

# Execute update-ipsets
/usr/lib/firehol/update-ipsets.sh

# Save ipsets
echo "Saving IPSets ..."
ipset save -f /app/ipsets-backup

echo "Refresh IPSets completed"
