# Deliberately support the usual line-based nginx.conf layout. Fail rather than
# guess when events/limit directives are inline or split over multiple lines.
function fail(message) {
    print "ERROR: " message > "/dev/stderr"
    failed = 1
    exit 1
}
{
    line = $0
    code = line
    sub(/#.*/, "", code)

    if (code ~ /^[[:space:]]*worker_processes([[:space:]]|;)/) {
        if (code !~ /^[[:space:]]*worker_processes[[:space:]]+(auto|[0-9]+)[[:space:]]*;[[:space:]]*$/)
            fail("Put worker_processes on its own line in nginx.conf")
        if (++processes > 1) fail("Duplicate worker_processes in nginx.conf")
        sub(/worker_processes[[:space:]]+[^;]+;/, "worker_processes auto;", line)
    }
    if (code ~ /^[[:space:]]*worker_rlimit_nofile([[:space:]]|;)/) {
        if (code !~ /^[[:space:]]*worker_rlimit_nofile[[:space:]]+[0-9]+[[:space:]]*;[[:space:]]*$/)
            fail("Put worker_rlimit_nofile on its own line in nginx.conf")
        if (++rlimits > 1) fail("Duplicate worker_rlimit_nofile in nginx.conf")
        sub(/worker_rlimit_nofile[[:space:]]+[^;]+;/, "worker_rlimit_nofile " nofile ";", line)
    }
    if (code ~ /^[[:space:]]*events([[:space:]]|\{)/) {
        if (code !~ /^[[:space:]]*events[[:space:]]*\{[[:space:]]*$/)
            fail("Put events { and its closing brace on separate lines in nginx.conf")
        if (++events > 1) fail("Duplicate events block in nginx.conf")
        in_events = 1
    } else if (in_events) {
        if (code ~ /^[[:space:]]*worker_connections([[:space:]]|;)/) {
            if (code !~ /^[[:space:]]*worker_connections[[:space:]]+[0-9]+[[:space:]]*;[[:space:]]*$/)
                fail("Put worker_connections on its own line in nginx.conf")
            if (++connections_seen > 1) fail("Duplicate worker_connections in nginx.conf")
            sub(/worker_connections[[:space:]]+[^;]+;/, "worker_connections " connections ";", line)
        } else if (code ~ /^[[:space:]]*\}[[:space:]]*$/) {
            if (!connections_seen) print "    worker_connections " connections ";"
            in_events = 0
        } else if (code ~ /[{}]/) {
            fail("Unsupported events block layout in nginx.conf")
        }
    }
    print line
}
END {
    if (failed) exit 1
    if (events != 1 || in_events) fail("Expected one complete events block in nginx.conf")
    if (!processes) print "worker_processes auto;"
    if (!rlimits) print "worker_rlimit_nofile " nofile ";"
}
