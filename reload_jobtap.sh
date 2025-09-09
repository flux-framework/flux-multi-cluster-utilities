# If the plugin exists, remove it first
ret=$(flux jobtap list | grep -q select_and_delegate.so && echo "exists")
if [ "$ret" == "exists" ];
then
    flux jobtap remove select_and_delegate.so
fi

echo "[setup] Loading jobtap plugin:"
echo "        $PLUGIN_PATH"

# Load plugin
flux jobtap load "$PLUGIN_PATH" config="$CLUSTERS_JSON"
if [ "$?" == 0 ];
then
    echo "[setup] Loaded jobtap plugin successfully."
fi

# Check dmesg
# flux dmesg