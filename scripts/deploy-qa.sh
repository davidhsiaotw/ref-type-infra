#!/bin/bash
set -ex

echo "Starting deployment to QA EC2 ($QA_EC2_IP)..."

# Setup SSH key
SSH_KEY_FILE="deploy_key.pem"
echo "$SSH_PRIVATE_KEY" > "$SSH_KEY_FILE"
chmod 600 "$SSH_KEY_FILE"

echo "Transferring files to QA EC2..."
rsync -avz -e "ssh -i $SSH_KEY_FILE -o StrictHostKeyChecking=no" \
  compose.yaml \
  init.sql \
  ubuntu@"$QA_EC2_IP":~/app/

# Deploy using Docker Compose
echo "Executing deployment commands on QA EC2..."
ssh -i "$SSH_KEY_FILE" -o StrictHostKeyChecking=no ubuntu@"$QA_EC2_IP" \
  REGISTRY="$REGISTRY" REGION="$REGION" 'bash -s'<< 'EOF'
  set -e

  : "${REGISTRY:?Registry URL is missing}"
  : "${REGION:?AWS Region is missing}"

  cd ~/app
  
  # Authenticate with ECR
  echo "Authenticating with Amazon ECR..."
  aws ecr get-login-password --region $REGION | sudo docker login --username AWS --password-stdin $REGISTRY

  # Set environment variables for ECR images
  export BACKEND_IMAGE="$REGISTRY/ref-type/backend:latest"
  export FRONTEND_IMAGE="$REGISTRY/ref-type/frontend:latest"
  
  echo "Pulling latest images from ECR..."
  sudo -E docker compose pull
  
  echo "Restarting containers..."
  sudo -E docker compose up -d
  
  echo "Pruning old images..."
  sudo docker image prune -f
EOF

echo "Deployment to QA finished successfully."
