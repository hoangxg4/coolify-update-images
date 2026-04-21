#!/bin/bash

# Kiểm tra biến môi trường
if [ -z "$COOLIFY_URL" ] || [ -z "$COOLIFY_TOKEN" ]; then
  echo "❌ Error: Missing COOLIFY_URL or COOLIFY_TOKEN"
  exit 1
fi

echo "🚀 Starting Coolify Auto-Update Check..."

# 1. Lấy danh sách apps (Thêm Bearer vào header)
apps=$(curl -s -H "Authorization: Bearer $COOLIFY_TOKEN" "$COOLIFY_URL/api/v1/applications")

# Kiểm tra phản hồi có phải là mảng JSON không
if ! echo "$apps" | jq -e '. | type == "array"' > /dev/null; then
  echo "❌ Error: Invalid API response from Coolify"
  exit 1
fi

# 2. Lặp qua danh sách ứng dụng
echo "$apps" | jq -c '.[]' | while read -r app; do
  uuid=$(echo "$app" | jq -r '.uuid')
  name=$(echo "$app" | jq -r '.name')
  image=$(echo "$app" | jq -r '.docker_registry_image_name')
  tag=$(echo "$app" | jq -r '.docker_registry_image_tag')
  build_pack=$(echo "$app" | jq -r '.build_pack')

  # Chỉ xử lý các app dùng Docker Image (build_pack: dockerimage)
  if [ "$build_pack" == "dockerimage" ] && [ "$image" != "null" ]; then
    echo "🔍 Checking: $name ($image:$tag)"
    
    # Lấy Digest từ Registry (không pull)
    remote_digest=$(regctl image digest "$image:$tag" 2>/dev/null)
    
    if [ -z "$remote_digest" ]; then
      echo "   ⚠️ Skip: Could not fetch digest for $image"
      continue
    fi

    # Quản lý file trạng thái
    state_file="state_${uuid}.txt"
    old_digest=""
    [ -f "$state_file" ] && old_digest=$(cat "$state_file")

    if [ "$remote_digest" != "$old_digest" ]; then
      echo "   ✅ New version found! (Digest: ${remote_digest:0:15}...)"
      
      # 3. Kích hoạt Deploy qua API
      # Lưu ý: Endpoint deploy yêu cầu uuid qua query parameter
      deploy_res=$(curl -s -o /dev/null -w "%{http_code}" \
        -H "Authorization: Bearer $COOLIFY_TOKEN" \
        "$COOLIFY_URL/api/v1/deploy?uuid=$uuid&force=true")

      if [ "$deploy_res" == "200" ]; then
        echo "   🚀 Deployment triggered successfully."
        echo "$remote_digest" > "$state_file"
      else
        echo "   ❌ Deployment failed with HTTP code: $deploy_res"
      fi
    else
      echo "   😴 Up to date."
    fi
  fi
done
