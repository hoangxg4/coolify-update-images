#!/bin/bash
set +x

STATE_FILE="apps_state.json"
TEMP_CONFIG="remote_registries.json"

# --- Hàm gửi thông báo Discord ---
send_discord_notification() {
  local app_id=$1
  if [ -n "$DISCORD_WEBHOOK" ]; then
    local message="🚀 **Coolify Update Detected**\n**App ID:** \`${app_id}\`\n**Status:** Deployment Triggered Successfully!"
    curl -s -H "Content-Type: application/json" -X POST -d "{\"content\": \"$message\"}" "$DISCORD_WEBHOOK" > /dev/null
  fi
}

# 1. Tải file cấu hình từ Repo Private
if [ -n "$CONFIG_URL" ] && [ -n "$MY_CONFIG_PAT" ]; then
    echo "🌐 Downloading private config..."
    status_code=$(curl -s -L -o "$TEMP_CONFIG" -w "%{http_code}" -H "Authorization: token $MY_CONFIG_PAT" "$CONFIG_URL")
    [ "$status_code" -eq 200 ] && CONFIG_FILE="$TEMP_CONFIG" || echo "⚠️ Could not download config (HTTP $status_code)"
fi

# 2. Đăng nhập Registry
if [ -f "$CONFIG_FILE" ]; then
    echo "🔑 Authenticating..."
    jq -c '.[]' "$CONFIG_FILE" 2>/dev/null | while read -r reg; do
        server=$(echo "$reg" | jq -r '.server')
        user=$(echo "$reg" | jq -r '.user')
        pass=$(echo "$reg" | jq -r '.pass')
        echo "$pass" | regctl registry login "$server" -u "$user" --pass-stdin > /dev/null 2>&1
    done
    [ -f "$TEMP_CONFIG" ] && rm "$TEMP_CONFIG"
fi

[ ! -f "$STATE_FILE" ] && echo "{}" > "$STATE_FILE"

# 3. Lấy danh sách app (Bổ sung kiểm tra lỗi)
echo "🔍 Fetching applications from Coolify..."
response=$(curl -s -w "\n%{http_code}" -H "Authorization: Bearer $COOLIFY_TOKEN" "$COOLIFY_URL/api/v1/applications")
http_status=$(echo "$response" | tail -n1)
apps=$(echo "$response" | sed '$d')

if [ "$http_status" != "200" ]; then
    echo "❌ API Error: Coolify returned HTTP $http_status"
    echo "Response: $apps" # Sẽ hiện lỗi để bạn debug (nhưng GitHub sẽ mask nếu trúng token)
    exit 1
fi

# 4. Duyệt và Kiểm tra Update
echo "$apps" | jq -c '.[]' 2>/dev/null | while read -r app; do
    uuid=$(echo "$app" | jq -r '.uuid')
    image=$(echo "$app" | jq -r '.docker_registry_image_name')
    tag=$(echo "$app" | jq -r '.docker_registry_image_tag')
    build_pack=$(echo "$app" | jq -r '.build_pack')

    if [ "$build_pack" == "dockerimage" ] && [ "$image" != "null" ]; then
        full_image="$image:$tag"
        remote_digest=$(regctl image digest "$full_image" 2>/dev/null)
        
        if [ -n "$remote_digest" ]; then
            old_digest=$(jq -r ".[\"$uuid\"] // empty" "$STATE_FILE")

            if [ -z "$old_digest" ]; then
                echo "📌 Syncing state for ${uuid:0:8}"
                tmp=$(mktemp)
                jq ".[\"$uuid\"] = \"$remote_digest\"" "$STATE_FILE" > "$tmp" && mv "$tmp" "$STATE_FILE"
                continue
            fi

            if [ "$remote_digest" != "$old_digest" ]; then
                echo "🚀 New version for ${uuid:0:8}. Deploying..."
                deploy_status=$(curl -s -o /dev/null -w "%{http_code}" \
                    -H "Authorization: Bearer $COOLIFY_TOKEN" \
                    "$COOLIFY_URL/api/v1/deploy?uuid=$uuid&force=true")

                if [ "$deploy_status" == "200" ]; then
                    tmp=$(mktemp)
                    jq ".[\"$uuid\"] = \"$remote_digest\"" "$STATE_FILE" > "$tmp" && mv "$tmp" "$STATE_FILE"
                    send_discord_notification "${uuid:0:8}"
                fi
            fi
        fi
    fi
done
echo "✅ Finished."
