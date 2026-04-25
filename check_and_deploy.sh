#!/bin/bash
set +x

STATE_FILE="apps_state.json"
STATE_FILE_ENC="apps_state.json.enc"
TEMP_CONFIG="remote_registries.json"

echo "::add-mask::$COOLIFY_URL"

# --- Hàm gửi thông báo Discord với Link FQDN và Dashboard ---
send_discord_notification() {
  local uuid=$1; local name=$2; local image=$3; local tag=$4
  local fqdn=$5; local project_uuid=$6; local env_uuid=$7
  local time=$(date -u +"%Y-%m-%d %H:%M:%S UTC")
  
  # Xây dựng link Dashboard chính xác theo cấu trúc bạn gửi
  local dashboard_link="${COOLIFY_URL}/project/${project_uuid}/environment/${env_uuid}/application/${uuid}"
  
  # Xử lý hiển thị FQDN (Link trang web)
  local fqdn_display="N/A"
  [ -z "$fqdn" ] || [ "$fqdn" == "null" ] && fqdn_display="No FQDN configured" || fqdn_display="[Click to visit App]($fqdn)"

  if [ -n "$DISCORD_WEBHOOK" ]; then
    local payload=$(cat <<EOF
{
  "embeds": [{
    "title": "🚀 Coolify Deployment: $name",
    "url": "$dashboard_link",
    "color": 3066993,
    "description": "Click the title or the Dashboard link below to manage this container.",
    "fields": [
      { "name": "🌐 Live Site (FQDN)", "value": "$fqdn_display", "inline": false },
      { "name": "🖥️ Dashboard", "value": "[Open Coolify Dashboard]($dashboard_link)", "inline": false },
      { "name": "📦 Image", "value": "\`${image}\`", "inline": true },
      { "name": "🏷️ Tag", "value": "\`${tag}\`", "inline": true },
      { "name": "🆔 UUID", "value": "\`${uuid}\`", "inline": false }
    ],
    "footer": { "text": "Auto-deployer • $time" }
  }]
}
EOF
)
    curl -s -H "Content-Type: application/json" -X POST -d "$payload" "$DISCORD_WEBHOOK" > /dev/null
  fi
}

# 1. Tải config
if [ -n "$CONFIG_URL" ] && [ -n "$MY_CONFIG_PAT" ]; then
    status_code=$(curl -s -L -o "$TEMP_CONFIG" -w "%{http_code}" -H "Authorization: token $MY_CONFIG_PAT" "$CONFIG_URL")
    [ "$status_code" -eq 200 ] && CONFIG_FILE="$TEMP_CONFIG"
fi

# 2. Giải mã state
if [ -f "$CONFIG_FILE" ]; then
    STATE_PWD=$(jq -r '.state_pass // empty' "$CONFIG_FILE")
    if [ -f "$STATE_FILE_ENC" ] && [ -n "$STATE_PWD" ]; then
        openssl enc -aes-256-cbc -d -pbkdf2 -iter 100000 -in "$STATE_FILE_ENC" -out "$STATE_FILE" -k "$STATE_PWD" 2>/dev/null
    fi
fi
[ ! -f "$STATE_FILE" ] && echo "{}" > "$STATE_FILE"

# 3. Login Registries
if [ -f "$CONFIG_FILE" ]; then
    jq -c '.registries[]' "$CONFIG_FILE" 2>/dev/null | while read -r reg; do
        server=$(echo "$reg" | jq -r '.server'); user=$(echo "$reg" | jq -r '.user'); pass=$(echo "$reg" | jq -r '.pass')
        echo "$pass" | regctl registry login "$server" -u "$user" --pass-stdin > /dev/null 2>&1
    done
fi

# 4. Fetch Apps
response=$(curl -s -H "Authorization: Bearer $COOLIFY_TOKEN" "$COOLIFY_URL/api/v1/applications")
apps=$response

# 5. Check & Deploy
echo "🔍 Scanning apps..."
echo "$apps" | jq -c '.[]' 2>/dev/null | while read -r app; do
    uuid=$(echo "$app" | jq -r '.uuid')
    name=$(echo "$app" | jq -r '.name')
    image=$(echo "$app" | jq -r '.docker_registry_image_name')
    tag=$(echo "$app" | jq -r '.docker_registry_image_tag')
    fqdn=$(echo "$app" | jq -r '.fqdn')
    
    # Lấy thêm UUID của Project và Environment để build link Dashboard
    project_uuid=$(echo "$app" | jq -r '.environment.project.uuid')
    env_uuid=$(echo "$app" | jq -r '.environment.uuid')
    
    if [ "$(echo "$app" | jq -r '.build_pack')" == "dockerimage" ] && [ "$image" != "null" ]; then
        remote_digest=$(regctl image digest "$image:$tag" 2>/dev/null)
        if [ -n "$remote_digest" ]; then
            old_digest=$(jq -r ".[\"$uuid\"] // empty" "$STATE_FILE")
            if [ -z "$old_digest" ]; then
                tmp=$(mktemp); jq ".[\"$uuid\"] = \"$remote_digest\"" "$STATE_FILE" > "$tmp" && mv "$tmp" "$STATE_FILE"
                continue
            fi
            if [ "$remote_digest" != "$old_digest" ]; then
                status=$(curl -s -o /dev/null -w "%{http_code}" -H "Authorization: Bearer $COOLIFY_TOKEN" "$COOLIFY_URL/api/v1/deploy?uuid=$uuid&force=true")
                if [ "$status" == "200" ]; then
                    tmp=$(mktemp); jq ".[\"$uuid\"] = \"$remote_digest\"" "$STATE_FILE" > "$tmp" && mv "$tmp" "$STATE_FILE"
                    # Gửi noti với 7 tham số
                    send_discord_notification "$uuid" "$name" "$image" "$tag" "$fqdn" "$project_uuid" "$env_uuid"
                fi
            fi
        fi
    fi
done

# 6. Re-encrypt & Clean
if [ -n "$STATE_PWD" ]; then
    openssl enc -aes-256-cbc -salt -pbkdf2 -iter 100000 -in "$STATE_FILE" -out "$STATE_FILE_ENC" -k "$STATE_PWD"
    rm -f "$STATE_FILE"
fi
[ -f "$TEMP_CONFIG" ] && rm -f "$TEMP_CONFIG"
echo "✅ Finished."
