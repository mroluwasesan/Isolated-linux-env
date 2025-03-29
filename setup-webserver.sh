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

# 2. Create the Python server script
cat > $CONTAINER_FS/var/www/html/server.py <<'EOF'
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

# 3. Create startup script for Python web server
cat > $CONTAINER_FS/start-webserver <<'EOF'
#!/bin/bash
# Start Python web server
cd /var/www/html
echo "Web server starting on port 8000"
exec python3 server.py
EOF

# 4. Make it executable
chmod +x $CONTAINER_FS/start-webserver

# 5. Copy Python binary and dependencies if not already present
echo "Copying Python and dependencies..."
cp /usr/bin/python3 $CONTAINER_FS/usr/bin/

# Copy Python standard libraries
PYTHON_VERSION=$(python3 --version | awk '{print $2}' | cut -d. -f1-2)
mkdir -p $CONTAINER_FS/usr/lib/python$PYTHON_VERSION
cp -r /usr/lib/python$PYTHON_VERSION/* $CONTAINER_FS/usr/lib/python$PYTHON_VERSION/

# Copy other Python directories
[ -d "/usr/lib/python3.8" ] && cp -r /usr/lib/python3.8 $CONTAINER_FS/usr/lib/
[ -d "/usr/lib/python3.8/lib-dynload" ] && cp -r /usr/lib/python3.8/lib-dynload $CONTAINER_FS/usr/lib/python3.8/
[ -f "/usr/lib/python3.8.zip" ] && cp /usr/lib/python3.8.zip $CONTAINER_FS/usr/lib/

# Copy required libraries
for lib in $(ldd /usr/bin/python3 | grep -o '/[^ ]*'); do
    lib_dir=$(dirname $lib)
    mkdir -p $CONTAINER_FS$lib_dir
    cp $lib $CONTAINER_FS$lib_dir/
done

echo "Web server setup complete in $CONTAINER_NAME"
echo "To start:"
echo "1. Enter container: sudo ./isolate.sh $CONTAINER_NAME start"
echo "2. Run: /start-webserver"
echo "3. Access from host: curl http://10.0.0.2:8000"





# 6. Set up iptables for port forwarding
sudo iptables -t nat -A PREROUTING -p tcp --dport 80 -j DNAT --to-destination 10.0.0.2:8000
sudo iptables -A FORWARD -p tcp -d 10.0.0.2 --dport 8000 -j ACCEPT