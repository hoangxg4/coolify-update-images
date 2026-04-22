#!/bin/bash
set +x

STATE_FILE="apps_state.json"

# Khởi tạo file state nếu chưa có
if [ ! -f "$STATE_FILE" ]; then
  echo "{}" > "$STATE_FILE"
fi

# 1. Lấy danh sách apps
apps=$(curl -s -H "Authorization: Bearer $COOLIFY_TOKEN" "$COOLIFY_URL/api/v1/applications")

if ! echo "$apps" | jq -e '. | type == "array"' > /dev/null; then
  echo "❌ API Error"
  exit 1
fi

echo "Checking for updates..."

# Duyệt danh sách
echo "$apps" | jq -c '.[]' | while read -r app; do
  uuid=$(echo "$app" | jq -r '.uuid')
  image=$(echo "$app" | jq -r '.docker_registry_image_name')
  tag=$(echo "$app" | jq -r '.docker_registry_image_tag')
  build_pack=$(echo "$app" | jq -r '.build_pack')

  if [ "$build_pack" == "dockerimage" ] && [ "$image" != "null" ]; then
    
    # Lấy digest từ Registry
    remote_digest=$(regctl image digest "$image:$tag" 2>/dev/null)
    
    # QUAN TRỌNG: Chỉ so sánh nếu lấy được remote_digest
    if [ -n "$remote_digest" ]; then
      # Lấy digest cũ từ file JSON
      old_digest=$(jq -r ".[\"$uuid\"] // empty" "$STATE_FILE")

      if [ "$remote_digest" != "$old_digest" ]; then
        echo "Update detected for an app (ID: ${uuid:0:6})..."
        
        deploy_status=$(curl -s -o /dev/null -w "%{http_code}" \
          -H "Authorization: Bearer $COOLIFY_TOKEN" \
          "$COOLIFY_URL/api/v1/deploy?uuid=$uuid&force=true")

        if [ "$deploy_status" == "200" ]; then
          # Cập nhật vào file JSON tạm
          tmp=$(mktemp)
          jq ".[\"$uuid\"] = \"$remote_digest\"" "$STATE_FILE" > "$tmp" && mv "$tmp" "$STATE_FILE"
        fi
      fi
    fi
  fi
done
