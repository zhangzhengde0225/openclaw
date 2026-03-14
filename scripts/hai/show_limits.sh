#!/bin/bash

if [ -f /sys/fs/cgroup/cpu.max ]; then
    # cgroup v2
    read quota period < /sys/fs/cgroup/cpu.max
    if [ "$quota" = "max" ]; then
        echo "CPU: unlimited"
    else
        cores=$(awk "BEGIN {printf \"%.2f\", $quota / $period}")
        echo "CPU cores: $cores"
    fi

    mem=$(cat /sys/fs/cgroup/memory.max)
    if [ "$mem" = "max" ]; then
        echo "Memory: unlimited"
    else
        gb=$(awk "BEGIN {printf \"%.2f\", $mem / 1024 / 1024 / 1024}")
        echo "Memory: ${gb} GB"
    fi

elif [ -f /sys/fs/cgroup/cpu/cpu.cfs_quota_us ]; then
    # cgroup v1
    quota=$(cat /sys/fs/cgroup/cpu/cpu.cfs_quota_us)
    period=$(cat /sys/fs/cgroup/cpu/cpu.cfs_period_us)
    if [ "$quota" -eq -1 ]; then
        echo "CPU: unlimited"
    else
        cores=$(awk "BEGIN {printf \"%.2f\", '$quota' / '$period'}")
        echo "CPU cores: $cores"
    fi

    mem=$(cat /sys/fs/cgroup/memory/memory.limit_in_bytes)
    gb=$(awk "BEGIN {printf \"%.2f\", '$mem' / 1024 / 1024 / 1024}")
    echo "Memory: ${gb} GB"

else
    echo "Cannot detect cgroup version."
fi
