#!/bin/bash
set +x

STATE_FILE="apps_state.json"
STATE_FILE_ENC="apps_state.json.enc"
TEMP_CONFIG="remote_registries.json"

# 0. Masking Coolify URL để bảo mật log
echo "::add-mask::$COOLIFY_URL"

# 1. Tải file cấu hình từ Repo Private
if [ -n "$CONFIG_URL" ] && [ -n "$MY_CONFIG_PAT" ]; then
    status_code=$(curl -s -L -o "$TEMP_CONFIG" -w "%{http_code}" \
        -H "Authorization: token $MY_CONFIG_PAT" \
        "$CONFIG_URL")
    [ "$status_code" -eq 200 ] && CONFIG_FILE="$TEMP_CONFIG"
fi

# 2. Lấy Password và Giải mã file State
if [ -f "$CONFIG_FILE" ]; then
    # Đọc state_pass từ Object cha
    STATE_PWD=$(jq -r '.state_pass // empty' "$CONFIG_FILE")

    if [ -f "$STATE_FILE_ENC" ] && [ -n "$STATE_PWD" ]; then
        openssl enc -aes-256-cbc -d -pbkdf2 -iter 100000 -in "$STATE_FILE_ENC" -out "$STATE_FILE" -k "$STATE_PWD" 2>/dev/null
    fi
fi

# Đảm bảo có file JSON để xử lý (nếu giải mã thất bại hoặc file mới)
[ ! -f "$STATE_FILE" ] && echo "{}" > "$STATE_FILE"

# 3. Đăng nhập vào các Registry (Đọc từ mảng .registries)
if [ -f "$CONFIG_FILE" ]; then
    echo "🔑 Authenticating with registries..."
    jq -c '.registries[]' "$CONFIG_FILE" 2>/dev/null | while read -r reg; do
        server=$(echo "$reg" | jq -r '.server')
        user=$(echo "$reg" | jq -r '.user')
        pass=$(echo "$reg" | jq -r '.pass')
        echo "$pass" | regctl registry login "$server" -u "$user" --pass-stdin > /dev/null 2>&1
    done
fi

# 4. Lấy danh sách app từ Coolify
response=$(curl -s -w "\n%{http_code}" -H "Authorization: Bearer $COOLIFY_TOKEN" "$COOLIFY_URL/api/v1/applications")
http_status=$(echo "$response" | tail -n1)
apps=$(echo "$response" | sed '$d')

if [ "$http_status" != "200" ]; then
    echo "❌ API Error: Coolify returned HTTP $http_status"
    exit 1
fi

# 5. Kiểm tra Update
echo "🔍 Scanning apps..."
updated=false
echo "$apps" | jq -c '.[]' 2>/dev/null | while read -r app; do
    uuid=$(echo "$app" | jq -r '.uuid')
    image=$(echo "$app" | jq -r '.docker_registry_image_name')
    tag=$(echo "$app" | jq -r '.docker_registry_image_tag')
    build_pack=$(echo "$app" | jq -r '.build_pack')

    if [ "$build_pack" == "dockerimage" ] && [ "$image" != "null" ]; then
        remote_digest=$(regctl image digest "$image:$tag" 2>/dev/null)
        
        if [ -n "$remote_digest" ]; then
            old_digest=$(jq -r ".[\"$uuid\"] // empty" "$STATE_FILE")

            if [ -z "$old_digest" ]; then
                tmp=$(mktemp)
                jq ".[\"$uuid\"] = \"$remote_digest\"" "$STATE_FILE" > "$tmp" && mv "$tmp" "$STATE_FILE"
                updated=true
                continue
            fi

            if [ "$remote_digest" != "$old_digest" ]; then
                deploy_status=$(curl -s -o /dev/null -w "%{http_code}" \
                    -H "Authorization: Bearer $COOLIFY_TOKEN" \
                    "$COOLIFY_URL/api/v1/deploy?uuid=$uuid&force=true")

                if [ "$deploy_status" == "200" ]; then
                    tmp=$(mktemp)
                    jq ".[\"$uuid\"] = \"$remote_digest\"" "$STATE_FILE" > "$tmp" && mv "$tmp" "$STATE_FILE"
                    updated=true
                    [ -n "$DISCORD_WEBHOOK" ] && curl -s -H "Content-Type: application/json" -X POST -d "{\"content\": \"🚀 **Updated:** \`${uuid:0:8}\`\"}" "$DISCORD_WEBHOOK" > /dev/null
                fi
            fi
        fi
    fi
done

# 6. Mã hóa lại file state và dọn dẹp
if [ -n "$STATE_PWD" ]; then
    openssl enc -aes-256-cbc -salt -pbkdf2 -iter 100000 -in "$STATE_FILE" -out "$STATE_FILE_ENC" -k "$STATE_PWD"
    rm "$STATE_FILE"
fi
[ -f "$TEMP_CONFIG" ] && rm "$TEMP_CONFIG"
echo "✅ Finished."
