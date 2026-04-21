#!/bin/bash

# Kiểm tra các biến môi trường
if [ -z "$COOLIFY_URL" ] || [ -z "$COOLIFY_TOKEN" ]; then
  echo "Error: Missing COOLIFY_URL or COOLIFY_TOKEN"
  exit 1
fi

# 1. Lấy danh sách applications từ Coolify
apps=$(curl -s -H "Authorization: Bearer $COOLIFY_TOKEN" "$COOLIFY_URL/api/v1/applications")

# Kiểm tra nếu không lấy được danh sách
if [ $(echo "$apps" | jq '. | type') != "array" ]; then
  echo "Error: Could not fetch apps or invalid API response"
  exit 1
fi

# 2. Duyệt qua từng app
echo "$apps" | jq -c '.[]' | while read -r app; do
  uuid=$(echo "$app" | jq -r '.uuid')
  name=$(echo "$app" | jq -r '.name')
  image=$(echo "$app" | jq -r '.docker_registry_image_name')
  tag=$(echo "$app" | jq -r '.docker_registry_image_tag')

  # Chỉ kiểm tra nếu app có dùng Docker Image
  if [ "$image" != "null" ] && [ "$tag" != "null" ]; then
    echo "--- Checking App: $name ($image:$tag) ---"
    
    # Lấy Digest hiện tại từ Registry bằng regctl
    remote_digest=$(regctl image digest "$image:$tag" 2>/dev/null)
    
    if [ -z "$remote_digest" ]; then
      echo "Cannot fetch digest for $image:$tag, skipping..."
      continue
    fi

    # Đọc digest cũ từ file state (nếu có)
    state_file="state_${uuid}.txt"
    old_digest=""
    [ -f "$state_file" ] && old_digest=$(cat "$state_file")

    if [ "$remote_digest" != "$old_digest" ]; then
      echo "New version detected! Remote: $remote_digest"
      
      # 3. Gọi API Deploy của Coolify
      deploy_res=$(curl -s -o /dev/null -w "%{http_code}" \
        -H "Authorization: Bearer $COOLIFY_TOKEN" \
        "$COOLIFY_URL/api/v1/deploy?uuid=$uuid&force=true")

      if [ "$deploy_res" == "200" ]; then
        echo "Successfully triggered deployment for $name"
        echo "$remote_digest" > "$state_file"
      else
        echo "Failed to trigger deployment. HTTP Code: $deploy_res"
      fi
    else
      echo "No changes detected."
    fi
  fi
done
