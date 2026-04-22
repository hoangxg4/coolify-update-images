#!/bin/bash

# Vô hiệu hóa in lệnh để bảo mật tuyệt đối
set +x

STATE_FILE="apps_state.json"

# 1. Đăng nhập vào các Private Registry (nếu có cấu hình)
if [ -n "$REGISTRIES_CONF" ]; then
    echo "🔑 Authenticating with private registries..."
    echo "$REGISTRIES_CONF" | jq -c '.[]' | while read -r reg; do
        server=$(echo "$reg" | jq -r '.server')
        user=$(echo "$reg" | jq -r '.user')
        pass=$(echo "$reg" | jq -r '.pass')
        
        # Đăng nhập bằng stdin để mật khẩu không hiện trong danh sách tiến trình
        echo "$pass" | regctl registry login "$server" -u "$user" --pass-stdin > /dev/null 2>&1
    done
fi

# Khởi tạo file state nếu chưa tồn tại
[ ! -f "$STATE_FILE" ] && echo "{}" > "$STATE_FILE"

# 2. Lấy danh sách ứng dụng từ Coolify
apps=$(curl -s -H "Authorization: Bearer $COOLIFY_TOKEN" "$COOLIFY_URL/api/v1/applications")

if ! echo "$apps" | jq -e '. | type == "array"' > /dev/null; then
    echo "❌ Error: Cannot connect to Coolify API or invalid Token."
    exit 1
fi

echo "🔍 Scanning for image updates..."

# 3. Duyệt qua từng ứng dụng
echo "$apps" | jq -c '.[]' | while read -r app; do
    uuid=$(echo "$app" | jq -r '.uuid')
    image=$(echo "$app" | jq -r '.docker_registry_image_name')
    tag=$(echo "$app" | jq -r '.docker_registry_image_tag')
    build_pack=$(echo "$app" | jq -r '.build_pack')

    # Chỉ xử lý ứng dụng sử dụng Docker Image
    if [ "$build_pack" == "dockerimage" ] && [ "$image" != "null" ]; then
        full_image="$image:$tag"
        
        # Lấy mã Digest (mã định danh duy nhất) của Image từ Registry
        remote_digest=$(regctl image digest "$full_image" 2>/dev/null)
        
        if [ -n "$remote_digest" ]; then
            # Lấy digest cũ từ file JSON trạng thái
            old_digest=$(jq -r ".[\"$uuid\"] // empty" "$STATE_FILE")

            # Trường hợp 1: Lần đầu tiên script thấy App này -> Chỉ lưu trạng thái, không Deploy
            if [ -z "$old_digest" ]; then
                echo "📌 Initializing state for app ${uuid:0:6}..."
                tmp=$(mktemp)
                jq ".[\"$uuid\"] = \"$remote_digest\"" "$STATE_FILE" > "$tmp" && mv "$tmp" "$STATE_FILE"
                continue
            fi

            # Trường hợp 2: Phát hiện Digest mới (Có bản cập nhật)
            if [ "$remote_digest" != "$old_digest" ]; then
                echo "🚀 Update detected! Triggering deploy..."
                
                # Gọi API Deploy của Coolify
                status=$(curl -s -o /dev/null -w "%{http_code}" \
                    -H "Authorization: Bearer $COOLIFY_TOKEN" \
                    "$COOLIFY_URL/api/v1/deploy?uuid=$uuid&force=true")

                if [ "$status" == "200" ]; then
                    # Cập nhật Digest mới vào file JSON
                    tmp=$(mktemp)
                    jq ".[\"$uuid\"] = \"$remote_digest\"" "$STATE_FILE" > "$tmp" && mv "$tmp" "$STATE_FILE"
                else
                    echo "⚠️ Failed to trigger deploy for ${uuid:0:6} (HTTP $status)"
                fi
            fi
        fi
    fi
done

echo "✅ All applications checked."
