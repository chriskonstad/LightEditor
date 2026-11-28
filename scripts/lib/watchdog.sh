# Runs a command with a hang detector. Source this file, then:
#
#   watch_run <log> <stall seconds> <limit seconds> <command…>
#
# The command's output goes to <log>. If the log stops growing for <stall seconds>
# (no progress), or the command runs past <limit seconds>, it's stopped with its
# whole process group and the function returns 124 after printing HUNG and the
# log's last lines, so a deadlock fails in minutes instead of holding a run for
# an hour. Otherwise it returns the command's own status.

watch_run() {
    local log=$1 stall=$2 limit=$3
    shift 3
    : > $log
    # A process group of its own, so stopping it stops everything it started.
    setopt local_options monitor
    "$@" >> $log 2>&1 &
    local pid=$! started=$SECONDS last_size=-1 last_change=$SECONDS reason=""
    unsetopt monitor
    while kill -0 $pid 2>/dev/null; do
        sleep 5
        local size=$(stat -f %z $log 2>/dev/null || echo 0)
        if (( size != last_size )); then
            last_size=$size
            last_change=$SECONDS
        fi
        if (( SECONDS - last_change >= stall )); then
            reason="no output for $stall s"
        elif (( SECONDS - started >= limit )); then
            reason="still running after $limit s"
        fi
        if [[ -n $reason ]]; then
            kill -TERM -$pid 2>/dev/null
            sleep 3
            kill -KILL -$pid 2>/dev/null
            wait $pid 2>/dev/null
            {
                echo
                echo "HUNG: $reason; stopped. Last output:"
            } >> $log
            return 124
        fi
    done
    wait $pid
}
