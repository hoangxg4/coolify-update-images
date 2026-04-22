#!/bin/bash
set +x

STATE_FILE="apps_state.json"
TEMP_CONFIG="remote_registries.json"

# --- Hàm gửi thông báo Discord ---
send_discord_notification() {
  local app_id=$1
  if [ -n "$DISCORD_WEBHOOK" ]; then
    local message="🚀 **Coolify Update Detected**\n**App ID:** \`${app_id}\`\n**Status:** Deployment Triggered Successfully!"
    curl -s -H "Content-Type: application/json" \
         -X POST \
         -d "{\"content\": \"$message\"}" \
         "$DISCORD_WEBHOOK" > /dev/null
  fi
}

# 1. Tải file cấu hình (Giữ nguyên logic cũ)
if [ -n "$CONFIG_URL" ] && [ -n "$MY_CONFIG_PAT" ]; then
    curl -s -L -o "$TEMP_CONFIG" -H "Authorization: token $MY_CONFIG_PAT" "$CONFIG_URL"
    CONFIG_FILE="$TEMP_CONFIG"
fi

# 2. Đăng nhập Registry (Giữ nguyên logic cũ)
if [ -f "$CONFIG_FILE" ]; then
    jq -c '.[]' "$CONFIG_FILE" | while read -r reg; do
        server=$(echo "$reg" | jq -r '.server')
        user=$(echo "$reg" | jq -r '.user')
        pass=$(echo "$reg" | jq -r '.pass')
        echo "$pass" | regctl registry login "$server" -u "$user" --pass-stdin > /dev/null 2>&1
    done
    [ -f "$TEMP_CONFIG" ] && rm "$TEMP_CONFIG"
fi

[ ! -f "$STATE_FILE" ] && echo "{}" > "$STATE_FILE"

# 3. Lấy danh sách app
apps=$(curl -s -H "Authorization: Bearer $COOLIFY_TOKEN" "$COOLIFY_URL/api/v1/applications")

# 4. Duyệt và Kiểm tra
echo "$apps" | jq -c '.[]' | while read -r app; do
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
                tmp=$(mktemp)
                jq ".[\"$uuid\"] = \"$remote_digest\"" "$STATE_FILE" > "$tmp" && mv "$tmp" "$STATE_FILE"
                continue
            fi

            if [ "$remote_digest" != "$old_digest" ]; then
                status=$(curl -s -o /dev/null -w "%{http_code}" \
                    -H "Authorization: Bearer $COOLIFY_TOKEN" \
                    "$COOLIFY_URL/api/v1/deploy?uuid=$uuid&force=true")

                if [ "$status" == "200" ]; then
                    # Cập nhật state
                    tmp=$(mktemp)
                    jq ".[\"$uuid\"] = \"$remote_digest\"" "$STATE_FILE" > "$tmp" && mv "$tmp" "$STATE_FILE"
                    # GỬI THÔNG BÁO DISCORD
                    send_discord_notification "${uuid:0:8}"
                fi
            fi
        fi
    fi
done
