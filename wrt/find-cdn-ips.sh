#!/bin/sh

# 配置变量
START_IP=1
END_IP=254
MAX_JOBS=20            # 并发进程数

# 选择域名
echo "请选择要测试的域名:"
echo "  1) family.081112.cn"
echo "  2) video.081112.cn"
echo "  3) 自定义"
read -p "请输入序号（默认 1）: " DOMAIN_CHOICE

case "${DOMAIN_CHOICE:-1}" in
    2) DOMAIN="video.081112.cn" ;;
    3)
        read -p "请输入自定义域名: " DOMAIN
        ;;
    *) DOMAIN="family.081112.cn" ;;
esac

# 手动输入网段前三位（如 120.233.185）
read -p "请输入网段前三位（如 120.233.185）: " IP_PREFIX

echo "开始测试 $IP_PREFIX.$START_IP - $IP_PREFIX.$END_IP ..."

test_single_ip() {
    ip="$1"
    # 执行 curl 测试
    res=$(curl -sIv "https://$DOMAIN/" \
        --resolve "$DOMAIN:443:$ip" \
        --connect-timeout 2 \
        --max-time 4 2>&1 | grep "HTTP/2 200")

    if [ -n "$res" ]; then
        echo "$ip"
    fi
}

# 循环遍历 1~254
for i in $(seq $START_IP $END_IP); do
    ip="$IP_PREFIX.$i"
    
    # 放入后台并发执行
    test_single_ip "$ip" &

    # 通过统计 ps 中正在运行的 curl 数量来控制并发
    while [ $(ps | grep -c "[c]url") -ge $MAX_JOBS ]; do
        sleep 1
    done
done

# 等待所有后台任务完成
wait

echo "-----------------------------------"
echo "测试完成！"