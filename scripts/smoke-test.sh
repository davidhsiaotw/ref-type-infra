#!/bin/bash
set -e

SSH_KEY_FILE="temp_key.pem"
echo "$SSH_PRIVATE_KEY" > "$SSH_KEY_FILE"
chmod 600 "$SSH_KEY_FILE"

echo "Transferring Docker images and install script to dynamic EC2 ($EC2_IP)..."
rsync -avz -e "ssh -i $SSH_KEY_FILE -o StrictHostKeyChecking=no" \
  frontend.tar.gz \
  backend.tar.gz \
  compose.local.yaml \
  init.sql \
  infra/scripts/docker-install.sh \
  ubuntu@"$EC2_IP":~/

echo "Setting up and running app on dynamic EC2..."
ssh -i "$SSH_KEY_FILE" -o StrictHostKeyChecking=no ubuntu@"$EC2_IP" \
  DB_HOST="$DB_HOST" DB_USER="$DB_USER" DB_PASSWORD="$DB_PASSWORD" DB_PORT="$DB_PORT" DB_DATABASE="$DB_DATABASE" << 'EOF'
  set -e
  # Install Docker if missing
  if ! command -v docker &> /dev/null; then
    echo ">>> STARTING DOCKER INSTALLATION..."
    chmod +x docker-install.sh
    ./docker-install.sh
    echo ">>> DOCKER INSTALLATION FINISHED."
  else
    echo ">>> Docker is already installed."
  fi

  sudo usermod -aG docker ubuntu
  sudo systemctl start docker

  # Load Docker images
  echo ">>> Loading Docker images..."
  sudo docker load -i frontend.tar.gz
  sudo docker load -i backend.tar.gz

  # Create dummy .env for smoke test
  cat > .env << ENV_EOF
DB_HOST="$DB_HOST"
DB_USER="$DB_USER"
DB_PASSWORD="$DB_PASSWORD"
DB_DATABASE="$DB_DATABASE"
JWT_SECRET_KEY=secret
ENV_EOF

  echo "Applying database schema to RDS..."
  mysql -h "$DB_HOST" -P "$DB_PORT" -u "$DB_USER" -p"$DB_PASSWORD" "$DB_DATABASE" < init.sql

  trap 'sudo docker compose -f compose.local.yaml logs; exit 1' ERR
  # Start the app using local database
  echo ">>> STARTING CONTAINERS..."
  sudo docker compose -f compose.local.yaml up -d --no-build --no-deps backend frontend

  MAX_RETRIES=20
  COUNT=0
  echo "Checking frontend health on port 3001..."
  # check port 3001 (frontend)
  until curl -s http://localhost:3001 | grep -q "<div id=\"root\">" || [ $COUNT -eq $MAX_RETRIES ]; do
    echo "Waiting for frontend... ($COUNT/$MAX_RETRIES)"
    sleep 5
    COUNT=$((COUNT+1))
  done
  if [ $COUNT -eq $MAX_RETRIES ]; then
    echo "Smoke test failed: Frontend did not respond in time."
    sudo docker compose -f compose.local.yaml logs
    exit 1
  fi

  COUNT=0
  echo "Checking backend health on port 8081..."
  # check port 8081 (backend) for the /leaderboard endpoint
  until [ $(curl -s -o /dev/null -w "%{http_code}" http://localhost:8081/leaderboard) -eq 200 ] || [ $COUNT -eq $MAX_RETRIES ]; do
    echo "Waiting for backend... ($COUNT/$MAX_RETRIES)"
    sleep 5
    COUNT=$((COUNT+1))
  done

  if [ $COUNT -eq $MAX_RETRIES ]; then
    echo "Smoke test failed: Backend did not respond to /leaderboard in time."
    sudo docker compose -f compose.local.yaml logs
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
