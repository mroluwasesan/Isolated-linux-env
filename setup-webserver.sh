#!/bin/bash

if [ -z "$1" ]; then
    read -p "Enter container name (default: webserver): " CONTAINER_NAME
    CONTAINER_NAME=${CONTAINER_NAME:-webserver}
else
    CONTAINER_NAME=$1
fi

# Configuration
CONTAINER_NAME=${1:-webserver}
CONTAINER_ROOT=/var/containers/$CONTAINER_NAME
CONTAINER_FS=$CONTAINER_ROOT/fs

# Check root
[ "$(id -u)" -ne 0 ] && { echo "Must be root"; exit 1; }

# Verify container exists
[ ! -d "$CONTAINER_FS" ] && { echo "Container $CONTAINER_NAME not found"; exit 1; }

# Install web server components
echo "Setting up web server in $CONTAINER_NAME..."

# 1. Create web directory structure
mkdir -p $CONTAINER_FS/var/www/html
chmod 755 $CONTAINER_FS/var/www

# 2. Create a simple index.html
cat > $CONTAINER_FS/var/www/html/index.html <<'EOF'
<!DOCTYPE html>
<html>
<head>
    <title>Container Web Server</title>
    <style>
        body { font-family: Arial, sans-serif; margin: 40px; }
        h1 { color: #446688; }
    </style>
</head>
<body>
    <h1>Hello from Container $CONTAINER_NAME!</h1>
    <p>This page is served from an isolated environment.</p>
    <p>Current time: <span id="time"></span></p>
    <script>
        document.getElementById('time').textContent = new Date().toLocaleString();
    </script>
</body>
</html>
EOF

# 3. Create startup script for Python web server
cat > $CONTAINER_FS/start-webserver <<'EOF'
#!/bin/bash
# Start Python web server
cd /var/www/html
echo "Web server starting on port 8000"
exec python3 -m http.server 8000
EOF

# 4. Make it executable
chmod +x $CONTAINER_FS/start-webserver

# 5. Copy Python binary and dependencies if not already present
if [ ! -f "$CONTAINER_FS/usr/bin/python3" ]; then
    echo "Copying Python and dependencies..."
    cp /usr/bin/python3 $CONTAINER_FS/usr/bin/
    
    # Copy required libraries
    for lib in $(ldd /usr/bin/python3 | grep -o '/[^ ]*'); do
        lib_dir=$(dirname $lib)
        mkdir -p $CONTAINER_FS$lib_dir
        cp $lib $CONTAINER_FS$lib_dir/
    done
fi

echo "Web server setup complete in $CONTAINER_NAME"
echo "To start:"
echo "1. Enter container: sudo ./isolate.sh $CONTAINER_NAME start"
echo "2. Run: /start-webserver"
echo "3. Access from host: curl http://10.0.0.2:8000"