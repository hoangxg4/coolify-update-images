#!/bin/bash

# Vô hiệu hóa in lệnh để bảo mật thông tin nhạy cảm
set +x

STATE_FILE="apps_state.json"
TEMP_CONFIG="remote_registries.json"

# 1. Tải file cấu hình từ URL Private
if [ -n "$CONFIG_URL" ] && [ -n "$MY_CONFIG_PAT" ]; then
    echo "🌐 Downloading private config from GitHub..."
    # Sử dụng PAT để tải file qua Raw URL của Private Repo
    status_code=$(curl -s -L -o "$TEMP_CONFIG" -w "%{http_code}" \
        -H "Authorization: token $MY_CONFIG_PAT" \
        "$CONFIG_URL")

    if [ "$status_code" -eq 200 ]; then
        echo "✅ Config downloaded successfully."
        CONFIG_FILE="$TEMP_CONFIG"
    else
        echo "❌ Failed to download config (HTTP $status_code). Check your PAT and URL."
        CONFIG_FILE=""
    fi
fi

# 2. Đăng nhập vào các Registry từ file vừa tải
if [ -f "$CONFIG_FILE" ]; then
    echo "🔑 Authenticating with private registries..."
    jq -c '.[]' "$CONFIG_FILE" | while read -r reg; do
        server=$(echo "$reg" | jq -r '.server')
        user=$(echo "$reg" | jq -r '.user')
        pass=$(echo "$reg" | jq -r '.pass')
        
        # Đăng nhập ẩn để bảo mật mật khẩu
        echo "$pass" | regctl registry login "$server" -u "$user" --pass-stdin > /dev/null 2>&1
    done
    # Xóa file cấu hình ngay sau khi login để đảm bảo an toàn
    [ -f "$TEMP_CONFIG" ] && rm "$TEMP_CONFIG"
fi

# 3. Khởi tạo file trạng thái nếu chưa có
[ ! -f "$STATE_FILE" ] && echo "{}" > "$STATE_FILE"

# 4. Lấy danh sách ứng dụng từ Coolify
apps=$(curl -s -H "Authorization: Bearer $COOLIFY_TOKEN" "$COOLIFY_URL/api/v1/applications")
if ! echo "$apps" | jq -e '. | type == "array"' > /dev/null; then
    echo "❌ Error: Cannot fetch applications from Coolify API."
    exit 1
fi

echo "🔍 Scanning for image updates..."

# 5. Duyệt danh sách ứng dụng
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

            # Nếu lần đầu thấy app: chỉ lưu trạng thái, không deploy
            if [ -z "$old_digest" ]; then
                echo "📌 First time seeing $uuid, syncing state..."
                tmp=$(mktemp)
                jq ".[\"$uuid\"] = \"$remote_digest\"" "$STATE_FILE" > "$tmp" && mv "$tmp" "$STATE_FILE"
                continue
            fi

            # Nếu digest thay đổi: kích hoạt deploy
            if [ "$remote_digest" != "$old_digest" ]; then
                echo "🚀 New version found for an app. Triggering deploy..."
                
                status=$(curl -s -o /dev/null -w "%{http_code}" \
                    -H "Authorization: Bearer $COOLIFY_TOKEN" \
                    "$COOLIFY_URL/api/v1/deploy?uuid=$uuid&force=true")

                if [ "$status" == "200" ]; then
                    tmp=$(mktemp)
                    jq ".[\"$uuid\"] = \"$remote_digest\"" "$STATE_FILE" > "$tmp" && mv "$tmp" "$STATE_FILE"
                else
                    echo "⚠️ Deploy failed (HTTP $status)"
                fi
            fi
        fi
    fi
done

echo "✅ Process finished."
