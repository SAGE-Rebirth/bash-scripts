#!/bin/bash

# === CONFIGURATION ===
CLUSTER_NAME="be-test-ecs"   # <-- change this to your ECS cluster name

# List of ECS services (from screenshot)
services=(
  test-be-notification-service
  test-be-post-service
  test-be-product-service
  test-be-services-service
  test-be-subscribe-service
  test-be-travel-service
  test-be-user-service
  test-be-userfeed-service
  test-be-video-service
  test-be-videofeed-service
  test-be-wallet-service
  test-be-ai-service
  test-be-auth-service
  test-be-booking-service
  test-be-call-chat-service
  test-be-channel-product-service
  test-be-channel-service
  test-be-chat-service
  test-be-docs-service
  test-be-earn-service
  test-be-group-chat-service
  test-be-inventory-service
  test-be-job-service
  test-be-language-service
  test-be-map-service
)

# === ACTION ===
for service in "${services[@]}"; do
  echo "⏸️ Pausing $service ..."
  aws ecs update-service --cluster "$CLUSTER_NAME" --service "$service" --desired-count 0
  if [ $? -eq 0 ]; then
    echo "✅ Successfully paused $service"
  else
    echo "❌ Failed to pause $service"
  fi
done

echo "🎯 All selected ECS services processed."
