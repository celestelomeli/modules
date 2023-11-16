#!/bin/bash

cat > index.html <<EOF
<h1>${server_text}</h1>
<p>DB address: ${db_address}</p>
<p>DB port: ${db_port}</p>
EOF


# Starts a lightweight HTTP server using BusyBox instructing it to run in foreground not as background daemon
# listen on specified port
nohup busybox httpd -f -p ${server_port} &

# nohup = ensure HTTP server continues running after user data script has completed
# amperstand allows script to continue executing without waiting for HTTP server to finish