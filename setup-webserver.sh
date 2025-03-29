#!/bin/bash

# Error handling
set -e
trap 'echo "Error on line $LINENO"; exit 1' ERR

# Configuration
if [ -z "$1" ]; then
    read -p "Enter container name (default: webserver): " CONTAINER_NAME
    CONTAINER_NAME=${CONTAINER_NAME:-webserver}
else
    CONTAINER_NAME=$1
fi

CONTAINER_ROOT=/var/containers/$CONTAINER_NAME
CONTAINER_FS=$CONTAINER_ROOT/fs


# Check requirements
check_requirements() {
    command -v python3 >/dev/null 2>&1 || { echo "python3 is required"; exit 1; }
    [ "$(id -u)" -eq 0 ] || { echo "Must be root"; exit 1; }
    [ -d "$CONTAINER_FS" ] || { echo "Container $CONTAINER_NAME not found"; exit 1; }
}



# Setup Python environment
setup_python() {
    echo "Setting up Python environment..."
    PYTHON_VERSION=$(python3 -c 'import sys; print(f"{sys.version_info.major}.{sys.version_info.minor}")')
    PYTHON_PATH="/usr/lib/python$PYTHON_VERSION"
    
    # Create directories
    mkdir -p "$CONTAINER_FS/usr/bin"
    mkdir -p "$CONTAINER_FS$PYTHON_PATH"
    
    # Copy Python binary and libraries
    cp /usr/bin/python3 "$CONTAINER_FS/usr/bin/"
    cp -r "$PYTHON_PATH"/* "$CONTAINER_FS$PYTHON_PATH/"
    
    # Copy dynamic libraries
    echo "Copying Python dependencies..."
    for lib in $(ldd /usr/bin/python3 | grep -o '/[^ ]*'); do
        if [ -f "$lib" ]; then
            dir="$CONTAINER_FS$(dirname $lib)"
            mkdir -p "$dir"
            cp "$lib" "$dir/"
        fi
    done
}





# Main setup
main() {
    check_requirements
    
    echo "Setting up web server in $CONTAINER_NAME..."
    
    # Create web directory
    mkdir -p "$CONTAINER_FS/var/www/html"
    
    # Create Python server script
    cat > "$CONTAINER_FS/var/www/html/server.py" <<'EOF'
    from http.server import HTTPServer, BaseHTTPRequestHandler

    class SimpleHTTPRequestHandler(BaseHTTPRequestHandler):
        def do_GET(self):
            self.send_response(200)
            self.send_header('Content-type', 'text/html')
            self.end_headers()
            
            html_content = """
            <!DOCTYPE html>
            <html lang="en">
            <head>
                <meta charset="UTF-8">
                <meta name="viewport" content="width=device-width, initial-scale=1.0">
                <title>Stage 8 Sample App</title>
                <style>
                    body {
                        font-family: Arial, sans-serif;
                        text-align: center;
                        background: linear-gradient(to right, #4facfe, #00f2fe);
                        color: white;
                        margin: 0;
                        padding: 0;
                        display: flex;
                        justify-content: center;
                        align-items: center;
                        height: 100vh;
                    }
                    .container {
                        background: rgba(0, 0, 0, 0.5);
                        padding: 30px;
                        border-radius: 10px;
                        box-shadow: 0 4px 8px rgba(0, 0, 0, 0.2);
                    }
                    h1 {
                        font-size: 2.5rem;
                    }
                    p {
                        font-size: 1.2rem;
                    }
                </style>
            </head>
            <body>
                <div class="container">
                    <h1>🚀 Welcome to Stage 8 Sample App! 🎉</h1>
                    <p>This is a simple Python web application running on port 8000.</p>
                </div>
            </body>
            </html>
            """
            self.wfile.write(html_content.encode('utf-8'))

    if __name__ == '__main__':
        httpd = HTTPServer(('0.0.0.0', 8000), SimpleHTTPRequestHandler)
        print('Server running on port 8000...')
        httpd.serve_forever()
EOF

    # Create startup script
    cat > "$CONTAINER_FS/start-webserver" <<'EOF'
#!/bin/bash
cd /var/www/html
echo "Web server starting on port 8000"
exec python3 server.py
EOF

    # Make it executable
    chmod +x $CONTAINER_FS/start-webserver

    # Setup Python environment
    setup_python
    
    # Configure port forwarding
    iptables -t nat -A PREROUTING -p tcp --dport 80 -j DNAT --to-destination 10.0.0.2:8000
    iptables -A FORWARD -p tcp -d 10.0.0.2 --dport 8000 -j ACCEPT
    
    echo "Web server setup complete in $CONTAINER_NAME"
    echo "To start:"
    echo "1. Enter container: sudo ./isolate.sh $CONTAINER_NAME start"
    echo "2. Run: /start-webserver"
    echo "3. Access from host: curl http://10.0.0.2:8000"
}

main
