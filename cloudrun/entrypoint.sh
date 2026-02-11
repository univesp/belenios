#!/bin/sh
set -e

# Cloud Run environment variables
: ${PORT:=8080}

# Paths
export BELENIOS_VARDIR=/tmp/belenios/var
export BELENIOS_RUNDIR=/tmp/belenios/run
export BELENIOS_BINDIR=/usr/bin  # Assuming installed via opam or system
export BELENIOS_SHAREDIR=/home/belenios/_run/usr/share/belenios-server # Based on demo build where it installs locally

# If we are using the demo build process where it builds locally in /home/belenios/_run
if [ -d "/home/belenios/_run" ]; then
    export BELENIOS_BINDIR=/home/belenios/_run/usr/bin
    export BELENIOS_SHAREDIR=/home/belenios/_run/usr/share/belenios-server
fi

export BELENIOS_CONFIG=/home/belenios/cloudrun/ocsigenserver.conf.in

echo "Cloud Run Entrypoint Starting..."
echo "Port: $PORT"
echo "VarDir: $BELENIOS_VARDIR"

# Create directories in /tmp
mkdir -p \
      $BELENIOS_VARDIR/etc \
      $BELENIOS_VARDIR/log \
      $BELENIOS_VARDIR/lib \
      $BELENIOS_VARDIR/upload \
      $BELENIOS_VARDIR/accounts \
      $BELENIOS_RUNDIR

if ! [ -d $BELENIOS_VARDIR/spool ]; then
    mkdir -p $BELENIOS_VARDIR/spool
    echo 1 > $BELENIOS_VARDIR/spool/version
fi

# Initialize files
touch $BELENIOS_VARDIR/password_db.csv
# We need to copy password_db from demo/ if it exists and we want initial users
if [ -f "demo/password_db.csv" ]; then
    cp demo/password_db.csv $BELENIOS_VARDIR/password_db.csv
fi
if [ -f "demo/dummy_logins.txt" ]; then
    cp demo/dummy_logins.txt $BELENIOS_VARDIR/demo_dummy_logins.txt
fi

# Prepare configuration
sed \
    -e "s@_VARDIR_@$BELENIOS_VARDIR@g" \
    -e "s@_RUNDIR_@$BELENIOS_RUNDIR@g" \
    -e "s@_SHAREDIR_@$BELENIOS_SHAREDIR@g" \
    -e "s@<port>8080</port>@<port>$PORT</port>@g" \
    $BELENIOS_CONFIG > $BELENIOS_VARDIR/etc/ocsigenserver.conf

# Add Belenios binary to path
PATH=$BELENIOS_BINDIR:$PATH:/usr/sbin



# Initialize SSH key if provided (for email relay)
if [ -n "$SSH_PRIVATE_KEY" ] || [ -n "$SSH_PRIVATE_KEY_B64" ]; then
    echo "Initializing SSH key..."
    mkdir -p /home/belenios/.ssh
    if [ -n "$SSH_PRIVATE_KEY_B64" ]; then
        echo "$SSH_PRIVATE_KEY_B64" | base64 -d > /home/belenios/.ssh/id_rsa
    else
        echo "$SSH_PRIVATE_KEY" > /home/belenios/.ssh/id_rsa
    fi
    chmod 600 /home/belenios/.ssh/id_rsa
    
    # Add relay host to known_hosts to avoid prompt
    if [ -n "$SMTP_RELAY_HOST" ]; then
        ssh-keyscan -p ${SMTP_RELAY_PORT:-22} $SMTP_RELAY_HOST >> /home/belenios/.ssh/known_hosts 2>/dev/null || true
    fi
    echo "SSH key initialized."
fi

echo "Starting server..."
exec belenios-server -c $BELENIOS_VARDIR/etc/ocsigenserver.conf "$@"
