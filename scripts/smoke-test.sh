#!/bin/bash
set -e

# EC2_IP and SSH_PRIVATE_KEY are passed via env
SSH_KEY_FILE="temp_key.pem"
echo "$SSH_PRIVATE_KEY" > "$SSH_KEY_FILE"
chmod 600 "$SSH_KEY_FILE"

echo "Transferring source code and docker-install script to dynamic EC2 ($EC2_IP)..."
tar -czf source.tar.gz -C source .
scp -i "$SSH_KEY_FILE" -o StrictHostKeyChecking=no source.tar.gz infra/docker-install.sh ubuntu@"$EC2_IP":~/

echo "Setting up and running app on dynamic EC2..."
ssh -i "$SSH_KEY_FILE" -o StrictHostKeyChecking=no ubuntu@"$EC2_IP" << 'EOF'
  set -e
  # Install Docker if missing
  if ! command -v docker &> /dev/null; then
    chmod +x docker-install.sh
    ./docker-install.sh
  fi

  sudo usermod -aG docker ubuntu
  sudo systemctl start docker

  mkdir -p app && tar -xzf source.tar.gz -C app && cd app

  # Create dummy .env for smoke test
  cat > .env << ENV_EOF
MYSQL_ROOT_PASSWORD=password
MYSQL_DATABASE=testdb
MYSQL_USER=user
MYSQL_PASSWORD=password
DB_HOST=db
DB_USER=user
DB_PASSWORD=password
DB_DATABASE=testdb
JWT_SECRET_KEY=secret
ENV_EOF

  # Start the app
  sudo docker compose up -d --build

  echo "Waiting for app to be ready (checking /leaderboard)..."
  MAX_RETRIES=20
  COUNT=0
  # check port 8081 (backend) for the /leaderboard endpoint
  until [ $(curl -s -o /dev/null -w "%{http_code}" http://localhost:8081/leaderboard) -eq 200 ] || [ $COUNT -eq $MAX_RETRIES ]; do
    echo "Waiting for backend... ($COUNT/$MAX_RETRIES)"
    sleep 5
    COUNT=$((COUNT+1))
  done

  if [ $COUNT -eq $MAX_RETRIES ]; then
    echo "Smoke test failed: Backend did not respond to /leaderboard in time."
    sudo docker compose logs
    exit 1
  fi

  # Verify data retrieval
  echo "Verifying data retrieval..."
  RESPONSE=$(curl -s http://localhost:8081/leaderboard)
  if [[ "$RESPONSE" == *"\"Status\":\"Success\""* ]] && [[ "$RESPONSE" == *"\"leaderboard\""* ]]; then
    echo "Smoke test passed: Successfully retrieved leaderboard data!"
  else
    echo "Smoke test failed: Response did not contain expected structure. Response: $RESPONSE"
    exit 1
  fi

  echo "All smoke tests passed successfully!"
EOF
