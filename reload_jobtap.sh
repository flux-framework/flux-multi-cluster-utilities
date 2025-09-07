# Remove plugin
flux jobtap remove select_and_delegate.so

sleep 1
# Load plugin
flux jobtap load "$PLUGIN_PATH" config="$CLUSTERS_JSON"

# Check dmesg
# flux dmesg