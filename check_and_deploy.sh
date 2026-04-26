#!/bin/bash
set +x

STATE_FILE="apps_state.json"
STATE_FILE_ENC="apps_state.json.enc"
TEMP_CONFIG="remote_registries.json"

echo "::add-mask::$COOLIFY_URL"

# --- Hàm gửi thông báo Discord ---
send_discord_notification() {
  local uuid=$1; local name=$2; local image=$3; local tag=$4; local fqdn=$5
  local p_uuid=$6; local e_uuid=$7
  local time=$(date -u +"%Y-%m-%d %H:%M:%S UTC")
  
  # Sử dụng cấu trúc số ít /environment/ chuẩn của UI
  local dashboard_link="${COOLIFY_URL}/project/${p_uuid}/environment/${e_uuid}/application/${uuid}"
  
  local fqdn_link="N/A"
  [[ -n "$fqdn" && "$fqdn" != "null" ]] && fqdn_link="🌐 [Visit Site]($fqdn)"

  if [ -n "$DISCORD_WEBHOOK" ]; then
    local payload=$(cat <<EOF
{
  "embeds": [{
    "title": "🚀 New Update Deployed: $name",
    "url": "$dashboard_link",
    "color": 3066993,
    "fields": [
      { "name": "🌍 Live URL", "value": "$fqdn_link", "inline": true },
      { "name": "🏷️ Tag", "value": "\`${tag}\`", "inline": true },
      { "name": "🖥️ Dashboard", "value": "[Open Full Dashboard]($dashboard_link)", "inline": false },
      { "name": "📦 Image", "value": "\`${image}\`", "inline": false }
    ],
    "footer": { "text": "Coolify Auto Deploy • $time" }
  }]
}
EOF
)
    curl -s -H "Content-Type: application/json" -X POST -d "$payload" "$DISCORD_WEBHOOK" > /dev/null
  fi
}

# 1. Tải config và giải mã state
if [ -n "$CONFIG_URL" ] && [ -n "$MY_CONFIG_PAT" ]; then
    curl -s -L -o "$TEMP_CONFIG" -H "Authorization: token $MY_CONFIG_PAT" "$CONFIG_URL"
    [ -f "$TEMP_CONFIG" ] && CONFIG_FILE="$TEMP_CONFIG"
fi
if [ -f "$CONFIG_FILE" ]; then
    STATE_PWD=$(jq -r '.state_pass // empty' "$CONFIG_FILE")
    if [ -f "$STATE_FILE_ENC" ] && [ -n "$STATE_PWD" ]; then
        openssl enc -aes-256-cbc -d -pbkdf2 -iter 100000 -in "$STATE_FILE_ENC" -out "$STATE_FILE" -k "$STATE_PWD" 2>/dev/null
    fi
fi
[ ! -f "$STATE_FILE" ] && echo "{}" > "$STATE_FILE"

# 2. Login Registries
if [ -f "$CONFIG_FILE" ]; then
    jq -c '.registries[]' "$CONFIG_FILE" 2>/dev/null | while read -r reg; do
        server=$(jq -r '.server' <<< "$reg"); user=$(jq -r '.user' <<< "$reg"); pass=$(jq -r '.pass' <<< "$reg")
        printf "%s" "$pass" | regctl registry login "$server" -u "$user" --pass-stdin > /dev/null 2>&1
    done
fi

# 3. Xây dựng Map Project/Environment (Dùng printf & pipe thẳng để tránh lỗi JSON parse)
echo "📡 Mapping Project structure..."
MAP_FILE=$(mktemp)
echo "[]" > "$MAP_FILE"

curl -s -H "Authorization: Bearer $COOLIFY_TOKEN" "$COOLIFY_URL/api/v1/projects" | jq -c '.[]' | while read -r project; do
    p_uuid=$(printf "%s" "$project" | jq -r '.uuid')
    
    envs_raw=$(curl -s -H "Authorization: Bearer $COOLIFY_TOKEN" "$COOLIFY_URL/api/v1/projects/$p_uuid/environments")
    new_map=$(printf "%s" "$envs_raw" | jq -c --arg puuid "$p_uuid" '.[] | {id: .id, p_uuid: $puuid, e_uuid: .uuid}')
    combined=$(jq -s '.[0] + .[1]' "$MAP_FILE" <(printf "%s" "$new_map" | jq -s '.'))
    printf "%s\n" "$combined" > "$MAP_FILE"
done

# 4. Kiểm tra Updates và Trigger Deploy
echo "🔍 Scanning for applications updates..."
curl -s -H "Authorization: Bearer $COOLIFY_TOKEN" "$COOLIFY_URL/api/v1/applications" | jq -c '.[]' | while read -r app; do
    uuid=$(printf "%s" "$app" | jq -r '.uuid')
    name=$(printf "%s" "$app" | jq -r '.name')
    image=$(printf "%s" "$app" | jq -r '.docker_registry_image_name')
    tag=$(printf "%s" "$app" | jq -r '.docker_registry_image_tag')
    fqdn=$(printf "%s" "$app" | jq -r '.fqdn')
    env_id=$(printf "%s" "$app" | jq -r '.environment_id')
    build_pack=$(printf "%s" "$app" | jq -r '.build_pack')

    if [ "$build_pack" == "dockerimage" ] && [ "$image" != "null" ]; then
        remote_digest=$(regctl image digest "$image:$tag" 2>/dev/null)
        
        if [ -n "$remote_digest" ]; then
            old_digest=$(jq -r ".[\"$uuid\"] // empty" "$STATE_FILE")
            
            if [ "$remote_digest" != "$old_digest" ]; then
                # Lấy UUID Map từ file tạm
                p_uuid=$(jq -r --arg eid "$env_id" '.[] | select(.id == ($eid|tonumber)) | .p_uuid' "$MAP_FILE" | head -n 1)
                e_uuid=$(jq -r --arg eid "$env_id" '.[] | select(.id == ($eid|tonumber)) | .e_uuid' "$MAP_FILE" | head -n 1)

                echo "🚀 Deploying $name ($image:$tag)..."
                status=$(curl -s -o /dev/null -w "%{http_code}" -H "Authorization: Bearer $COOLIFY_TOKEN" "$COOLIFY_URL/api/v1/deploy?uuid=$uuid&force=true")
                
                if [ "$status" == "200" ]; then
                    tmp=$(mktemp); jq ".[\"$uuid\"] = \"$remote_digest\"" "$STATE_FILE" > "$tmp" && mv "$tmp" "$STATE_FILE"
                    send_discord_notification "$uuid" "$name" "$image" "$tag" "$fqdn" "$p_uuid" "$e_uuid"
                    echo "   ✅ Success!"
                else
                    echo "   ❌ Deploy failed with status: $status"
                fi
            fi
        fi
    fi
done

# 5. Mã hóa lại & Dọn dẹp
if [ -n "$STATE_PWD" ]; then
    openssl enc -aes-256-cbc -salt -pbkdf2 -iter 100000 -in "$STATE_FILE" -out "$STATE_FILE_ENC" -k "$STATE_PWD"
    rm -f "$STATE_FILE"
fi
rm -f "$TEMP_CONFIG" "$MAP_FILE"
echo "✅ CI/CD Scan Finished."
