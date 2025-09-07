# Run 7 continuously running jobs
echo "Submitting 7 jobs to be assigned randomly"
flux submit --setattr="FLUX_DELEGATE_SELECTION_POLICY=random" -N 1 flux start sleep inf 
flux submit --setattr="FLUX_DELEGATE_SELECTION_POLICY=random" -N 1 flux start sleep inf 
flux submit --setattr="FLUX_DELEGATE_SELECTION_POLICY=random" -N 1 flux start sleep inf 
flux submit --setattr="FLUX_DELEGATE_SELECTION_POLICY=random" -N 1 flux start sleep inf 
flux submit --setattr="FLUX_DELEGATE_SELECTION_POLICY=random" -N 1 flux start sleep inf 
flux submit --setattr="FLUX_DELEGATE_SELECTION_POLICY=random" -N 1 flux start sleep inf 
flux submit --setattr="FLUX_DELEGATE_SELECTION_POLICY=random" -N 1 flux start sleep inf 

# Get jobids using flux jobs
jobids="$(flux jobs -n | tr -s " " | grep "flux R " | cut -d " " -f 2 | paste -sd" ")"

echo "Checking running jobs on $NUM_CLUSTERS clusters"

for jobid in $jobids; 
do
    echo "Load on $jobid:"
    flux proxy ${jobid} flux jobs
done

# For least pending queue tests, run
# flux submit --setattr="FLUX_DELEGATE_SELECTION_POLICY=least_pending" -N 1 hostname

# For shortest matching job test, run
# flux submit --setattr="FLUX_DELEGATE_SELECTION_POLICY=shortest_match" -N 1 hostname

# For explicit random matching job test, run
# flux submit --setattr="FLUX_DELEGATE_SELECTION_POLICY=random" -N 1 hostname
