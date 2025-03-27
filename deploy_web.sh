#!/bin/bash

CONTAINER_NAME=${1:-webserver}
CONTAINER_FS=/var/containers/$CONTAINER_NAME/fs

# Install required packages in container filesystem
cp /usr/bin/python3 $CONTAINER_FS/usr/bin/
cp /usr/lib/x86_64-linux-gnu/{libpython3.so*,libexpat.so.1,libz.so.1,libssl.so.1.1,libcrypto.so.1.1} $CONTAINER_FS/lib/

# Create web server directory
mkdir -p $CONTAINER_FS/var/www
git clone https://github.com/yourusername/yourrepo.git $CONTAINER_FS/var/www/app

# Create a simple Python web server startup script
cat > $CONTAINER_FS/start_web.sh << 'EOF'
#!/bin/bash
cd /var/www/app
python3 -m http.server 8000
EOF

chmod +x $CONTAINER_FS/start_web.sh

# Create an entry point for the container
cat > $CONTAINER_FS/entrypoint.sh << 'EOF'
#!/bin/bash
# Start the web server
/start_web.sh &
# Keep the container running
exec /bin/bash
EOF

chmod +x $CONTAINER_FS/entrypoint.sh

echo "Web server deployed to container $CONTAINER_NAME"
echo "Start the container with: sudo ./isolate.sh $CONTAINER_NAME start"