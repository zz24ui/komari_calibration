#!/bin/sh
# komari 流量校准脚本 (Debian / Alpine 通用)

FILE="/opt/komari/net_static.json"

# 需要 root 权限
if [ "$(id -u)" -ne 0 ]; then
    echo "请使用 root 权限运行此脚本。"
    exit 1
fi

# 检查文件
if [ ! -f "$FILE" ]; then
    echo "错误：未找到 $FILE，无需校准或路径有误。"
    exit 1
fi

# 检测系统类型
if command -v rc-service >/dev/null 2>&1; then
    OS="alpine"
elif command -v systemctl >/dev/null 2>&1; then
    OS="debian"
else
    echo "错误：无法识别系统（未找到 rc-service 或 systemctl）。"
    exit 1
fi

stop_service() {
    if [ "$OS" = "alpine" ]; then
        rc-service komari-agent stop
    else
        systemctl stop komari-agent.service
    fi
}

start_service() {
    if [ "$OS" = "alpine" ]; then
        rc-service komari-agent start
    else
        systemctl start komari-agent.service
    fi
}

# 检查 / 安装 jq
if ! command -v jq >/dev/null 2>&1; then
    echo "未检测到 jq，正在尝试安装..."
    if [ "$OS" = "alpine" ]; then
        apk add --no-cache jq
    else
        apt-get update && apt-get install -y jq
    fi
    if ! command -v jq >/dev/null 2>&1; then
        echo "错误：jq 安装失败，请手动安装后重试。"
        exit 1
    fi
fi

# 显示当前网卡及最后一条数据
echo "当前文件中的网卡数据（最后一条）："
jq -r '.interfaces | to_entries[] | "  \(.key): tx=\(.value[-1].tx) rx=\(.value[-1].rx) (共\(.value|length)条记录)"' "$FILE"
echo

# 输入数据
printf "请输入真实【上传】流量 (GB): "
read UP_GB
printf "请输入真实【下载】流量 (GB): "
read DOWN_GB

# 校验输入为非负数字
is_num() {
    echo "$1" | grep -Eq '^[0-9]+(\.[0-9]+)?$'
}
if ! is_num "$UP_GB" || ! is_num "$DOWN_GB"; then
    echo "错误：请输入有效的非负数字（可带小数）。"
    exit 1
fi

# GB 换算成字节 (1024^3)，取整
TX=$(awk -v g="$UP_GB"   'BEGIN{printf "%.0f", g*1024*1024*1024}')
RX=$(awk -v g="$DOWN_GB" 'BEGIN{printf "%.0f", g*1024*1024*1024}')

echo
echo "将设置：上传 tx=$TX 字节，下载 rx=$RX 字节"
printf "确认执行？(y/N): "
read CONFIRM
case "$CONFIRM" in
    y|Y|yes|YES) ;;
    *) echo "已取消。"; exit 0 ;;
esac

# 停止服务
echo "正在停止 komari-agent..."
stop_service

# 备份
BACKUP="${FILE}.bak.$(date +%Y%m%d%H%M%S)"
cp "$FILE" "$BACKUP" && echo "已备份到 $BACKUP"

# 修改：每个网卡只保留最后一条，并改写 tx / rx
TMP="${FILE}.tmp"
if jq --argjson tx "$TX" --argjson rx "$RX" '
    .interfaces |= with_entries(
        .value = [ (.value[-1] | .tx = $tx | .rx = $rx) ]
    )
' "$FILE" > "$TMP" && [ -s "$TMP" ]; then
    mv "$TMP" "$FILE"
    echo "已更新 $FILE"
else
    echo "错误：修改失败，已恢复原文件。"
    rm -f "$TMP"
    cp "$BACKUP" "$FILE"
fi

# 启动服务
echo "正在启动 komari-agent..."
start_service

echo "完成。当前内容："
cat "$FILE"
echo