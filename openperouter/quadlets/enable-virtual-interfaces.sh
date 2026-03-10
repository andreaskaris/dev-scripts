#!/bin/bash
# Inject ENABLE_VIRTUAL_INTERFACES=true into assisted-service.env
# so that the assisted-service inventory includes virtual interfaces (bridges, etc.).
# Runs before assisted-service-pod.service.

ENV_FILE="/usr/local/share/assisted-service/assisted-service.env"

echo "Checking for $ENV_FILE..."
if [ ! -f "$ENV_FILE" ]; then
    echo "ERROR: File $ENV_FILE does not exist. Failing to trigger systemd restart."
    exit 1
fi

if grep -q "^ENABLE_VIRTUAL_INTERFACES=" "$ENV_FILE"; then
    echo "ENABLE_VIRTUAL_INTERFACES already set. Exiting cleanly."
    exit 0
fi

echo "Injecting ENABLE_VIRTUAL_INTERFACES=true..."
if echo "ENABLE_VIRTUAL_INTERFACES=true" >> "$ENV_FILE"; then
    echo "SUCCESS: Injection complete."
    exit 0
else
    echo "ERROR: Failed to write to $ENV_FILE."
    exit 1
fi
