#!/bin/bash
# IKUNS出品 - 哪吒监控入侵检测脚本
# 检测JWT密钥泄露、SSH后门、异常登录等入侵痕迹

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

echo "=========================================="
echo "哪吒监控 - 入侵痕迹检测脚本"
echo "IKUNS出品"
echo "=========================================="
echo ""

ALERT_COUNT=0

# ==========================================
# 1. 检测配置文件泄露
# ==========================================
echo "[1] 检测配置文件泄露风险"
echo "----------------------------------------"

CONFIG_PATH="/opt/nezha/dashboard/data/config.yaml"
if [ -f "$CONFIG_PATH" ]; then
    PERMS=$(stat -c "%a" "$CONFIG_PATH" 2>/dev/null || stat -f "%OLp" "$CONFIG_PATH" 2>/dev/null)
    echo "配置文件: $CONFIG_PATH"
    echo "权限: $PERMS"

    if [ "$PERMS" != "600" ] && [ "$PERMS" != "400" ]; then
        echo -e "${RED}[!] 警告: 配置文件权限过高，可能被读取！${NC}"
        echo -e "${YELLOW}建议: chmod 600 $CONFIG_PATH${NC}"
        ((ALERT_COUNT++))
    else
        echo -e "${GREEN}[√] 配置文件权限正常${NC}"
    fi

    # 检测jwt_secret_key
    if grep -q "jwt_secret_key" "$CONFIG_PATH"; then
        JWT_LEN=$(grep "jwt_secret_key" "$CONFIG_PATH" | cut -d: -f2 | tr -d ' ' | wc -c)
        echo "JWT密钥长度: $JWT_LEN 字节"

        if [ $JWT_LEN -lt 500 ]; then
            echo -e "${RED}[!] 警告: JWT密钥过短，可能被爆破！${NC}"
            ((ALERT_COUNT++))
        fi
    fi
else
    echo "未找到哪吒监控配置文件"
fi
echo ""

# ==========================================
# 2. 检测SSH后门
# ==========================================
echo "[2] 检测SSH后门植入"
echo "----------------------------------------"

AUTH_KEYS="/root/.ssh/authorized_keys"
if [ -f "$AUTH_KEYS" ]; then
    KEY_COUNT=$(grep -c "ssh-" "$AUTH_KEYS" 2>/dev/null || echo 0)
    echo "发现 $KEY_COUNT 个SSH公钥"

    if [ $KEY_COUNT -gt 0 ]; then
        echo ""
        echo "公钥列表:"
        echo "----------------------------------------"

        while IFS= read -r line; do
            if [[ $line == ssh-* ]]; then
                # 提取指纹
                FINGERPRINT=$(echo "$line" | ssh-keygen -lf /dev/stdin 2>/dev/null | awk '{print $2}')
                COMMENT=$(echo "$line" | awk '{print $NF}')
                KEY_TYPE=$(echo "$line" | awk '{print $1}')

                echo "类型: $KEY_TYPE"
                echo "指纹: $FINGERPRINT"
                echo "备注: $COMMENT"

                # 检测可疑特征
                if [[ "$COMMENT" == "my_access" ]] || [[ "$COMMENT" == *"backdoor"* ]]; then
                    echo -e "${RED}[!] 可疑公钥！备注名可疑${NC}"
                    ((ALERT_COUNT++))
                fi

                # 检查是否是本次攻击植入的公钥
                if echo "$line" | grep -q "INaBWgeVj6ZAq9zsuCrIbdZIuctB"; then
                    echo -e "${RED}[!!!] 发现本次攻击植入的后门公钥！${NC}"
                    echo -e "${YELLOW}清除命令: sed -i '/INaBWgeVj6ZAq9zsuCrIbdZIuctB/d' $AUTH_KEYS${NC}"
                    ((ALERT_COUNT++))
                fi

                echo "----------------------------------------"
            fi
        done < "$AUTH_KEYS"
    fi

    # 检查权限
    PERMS=$(stat -c "%a" "$AUTH_KEYS" 2>/dev/null || stat -f "%OLp" "$AUTH_KEYS" 2>/dev/null)
    if [ "$PERMS" != "600" ]; then
        echo -e "${RED}[!] 警告: authorized_keys权限异常: $PERMS${NC}"
        ((ALERT_COUNT++))
    fi
else
    echo -e "${GREEN}[√] 未发现authorized_keys文件${NC}"
fi
echo ""

# ==========================================
# 3. 检测异常SSH登录
# ==========================================
echo "[3] 检测异常SSH登录记录"
echo "----------------------------------------"

# 最近的SSH登录
echo "最近10次SSH登录:"
if command -v last &>/dev/null; then
    last -n 10 2>/dev/null | grep -E "root|pts" || echo "无相关登录记录"
elif command -v journalctl &>/dev/null; then
    journalctl -u sshd --no-pager -n 20 2>/dev/null | grep -iE "accepted|session opened" | tail -10 || echo "无相关登录记录"
else
    echo -e "${YELLOW}[!] 警告: last 和 journalctl 均不可用，无法检查登录历史${NC}"
    echo -e "${YELLOW}建议: 安装 util-linux 包以获取 last 命令${NC}"
fi

# 检查失败的登录尝试
FAIL_COUNT=$(grep "Failed password" /var/log/auth.log 2>/dev/null | wc -l)
if [ $FAIL_COUNT -eq 0 ]; then
    FAIL_COUNT=$(grep "Failed password" /var/log/secure 2>/dev/null | wc -l)
fi

echo ""
echo "SSH登录失败次数: $FAIL_COUNT"
if [ $FAIL_COUNT -gt 100 ]; then
    echo -e "${RED}[!] 警告: 检测到大量SSH登录失败，可能正在被暴力破解！${NC}"
    ((ALERT_COUNT++))
fi

# 检查当前SSH连接
CURRENT_SSH=$(who | grep -c "pts")
echo "当前SSH会话数: $CURRENT_SSH"
if [ $CURRENT_SSH -gt 3 ]; then
    echo -e "${YELLOW}[?] 注意: SSH会话数较多${NC}"
    who
fi
echo ""

# ==========================================
# 4. 检测JWT Token异常
# ==========================================
echo "[4] 检测JWT Token伪造痕迹"
echo "----------------------------------------"

# 检查哪吒监控日志中的异常token
NEZHA_LOG="/opt/nezha/dashboard/app.log"
if [ -f "$NEZHA_LOG" ]; then
    echo "分析最近的JWT验证记录..."

    # 检测同一token多IP登录
    SUSPICIOUS=$(grep -i "jwt\|token\|unauthorized" "$NEZHA_LOG" 2>/dev/null | tail -50)
    if [ ! -z "$SUSPICIOUS" ]; then
        UNAUTH_COUNT=$(echo "$SUSPICIOUS" | grep -c -i "unauthorized")
        echo "最近50条记录中Unauthorized次数: $UNAUTH_COUNT"

        if [ $UNAUTH_COUNT -gt 10 ]; then
            echo -e "${RED}[!] 警告: 检测到大量认证失败，可能有人在尝试伪造JWT！${NC}"
            ((ALERT_COUNT++))
        fi
    fi
else
    echo "未找到哪吒监控日志文件"
fi
echo ""

# ==========================================
# 5. 检测目录穿越攻击痕迹
# ==========================================
echo "[5] 检测目录穿越攻击日志"
echo "----------------------------------------"

# 检查nginx/web服务器日志
WEB_LOGS=("/var/log/nginx/access.log" "/opt/nezha/dashboard/access.log")
for LOG in "${WEB_LOGS[@]}"; do
    if [ -f "$LOG" ]; then
        echo "检查日志: $LOG"

        # 检测路径穿越特征
        TRAVERSAL=$(grep -E "\.\./|%2e%2e|dashboard\.\./|config\.yaml" "$LOG" 2>/dev/null | tail -5)
        if [ ! -z "$TRAVERSAL" ]; then
            echo -e "${RED}[!] 发现目录穿越攻击痕迹:${NC}"
            echo "$TRAVERSAL"
            ((ALERT_COUNT++))
        else
            echo -e "${GREEN}[√] 未发现明显的目录穿越攻击${NC}"
        fi
    fi
done
echo ""

# ==========================================
# 6. 检测可疑进程和网络连接
# ==========================================
echo "[6] 检测可疑进程和连接"
echo "----------------------------------------"

# 检查哪吒监控进程
NEZHA_PROC=$(ps aux | grep -E "nezha|dashboard" | grep -v grep)
if [ ! -z "$NEZHA_PROC" ]; then
    echo "哪吒监控进程:"
    echo "$NEZHA_PROC"
else
    echo -e "${RED}[!] 警告: 未发现哪吒监控进程，可能已被关闭！${NC}"
    ((ALERT_COUNT++))
fi

echo ""
echo "监听的端口:"
if command -v ss &>/dev/null; then
    ss -tlnp 2>/dev/null | grep -E ":8008|:22" || echo "未发现相关监听端口"
elif command -v netstat &>/dev/null; then
    netstat -tlnp 2>/dev/null | grep -E ":8008|:22" || echo "未发现相关监听端口"
else
    echo -e "${YELLOW}[!] 警告: ss 和 netstat 均不可用，无法检查端口${NC}"
fi

# 检查异常的外连
echo ""
echo "检查可疑的外连接..."
if command -v ss &>/dev/null; then
    SUSPICIOUS_CONN=$(ss -tn state established 2>/dev/null | grep -v -E "127\.0\.0\.1|::1" | wc -l)
elif command -v netstat &>/dev/null; then
    SUSPICIOUS_CONN=$(netstat -ant 2>/dev/null | grep ESTABLISHED | grep -v -E "127\.0\.0\.1|::1" | wc -l)
else
    SUSPICIOUS_CONN=0
fi
if [ $SUSPICIOUS_CONN -gt 20 ]; then
    echo -e "${YELLOW}[?] 注意: 发现 $SUSPICIOUS_CONN 个外部连接${NC}"
fi
echo ""

# ==========================================
# 7. 检测历史命令记录
# ==========================================
echo "[7] 检测历史命令中的可疑操作"
echo "----------------------------------------"

HISTORY_FILES=("/root/.bash_history" "/root/.zsh_history" "/home/*/.bash_history")
SUSPICIOUS_CMDS=0

for HIST_FILE in "${HISTORY_FILES[@]}"; do
    for file in $HIST_FILE; do
        if [ -f "$file" ]; then
            echo "检查历史文件: $file"

            # 检测SSH后门植入相关命令
            if grep -q "authorized_keys\|ssh-keygen\|ssh-ed25519\|base64.*ssh" "$file" 2>/dev/null; then
                echo -e "${RED}[!] 发现SSH后门相关命令:${NC}"
                grep -E "authorized_keys|ssh-keygen|ssh-ed25519|base64.*ssh" "$file" | tail -5
                ((SUSPICIOUS_CMDS++))
                ((ALERT_COUNT++))
            fi

            # 检测目录穿越/配置读取
            if grep -q "config.yaml\|\.\.\/\|curl.*dashboard" "$file" 2>/dev/null; then
                echo -e "${RED}[!] 发现配置文件读取命令:${NC}"
                grep -E "config.yaml|\.\.\/|curl.*dashboard" "$file" | tail -5
                ((SUSPICIOUS_CMDS++))
                ((ALERT_COUNT++))
            fi

            # 检测JWT相关操作
            if grep -q "jwt\|token.*echo\|base64.*eyJ" "$file" 2>/dev/null; then
                echo -e "${YELLOW}[?] 发现JWT/Token相关命令:${NC}"
                grep -E "jwt|token.*echo|base64.*eyJ" "$file" | tail -3
                ((SUSPICIOUS_CMDS++))
            fi

            # 检测痕迹清除命令
            if grep -q "history -c\|> .*log\|rm.*history\|shred\|unset HISTFILE" "$file" 2>/dev/null; then
                echo -e "${RED}[!] 发现痕迹清除命令:${NC}"
                grep -E "history -c|> .*log|rm.*history|shred|unset HISTFILE" "$file" | tail -5
                ((SUSPICIOUS_CMDS++))
                ((ALERT_COUNT++))
            fi

            # 检测提权/下载恶意脚本
            if grep -q "wget\|curl.*sh\|chmod.*777\|chmod.*+s" "$file" 2>/dev/null; then
                echo -e "${YELLOW}[?] 发现下载/提权相关命令:${NC}"
                grep -E "wget|curl.*sh|chmod.*777|chmod.*\+s" "$file" | tail -5
                ((SUSPICIOUS_CMDS++))
            fi

            # 检测反弹shell
            if grep -q "nc.*-e\|bash -i\|/dev/tcp\|python.*socket" "$file" 2>/dev/null; then
                echo -e "${RED}[!!!] 发现反弹shell命令:${NC}"
                grep -E "nc.*-e|bash -i|/dev/tcp|python.*socket" "$file" | tail -5
                ((SUSPICIOUS_CMDS++))
                ((ALERT_COUNT++))
            fi

            # 统计历史命令总数
            TOTAL_CMDS=$(wc -l < "$file" 2>/dev/null)
            echo "历史命令总数: $TOTAL_CMDS"

            # 检查是否被清空
            if [ $TOTAL_CMDS -lt 10 ]; then
                echo -e "${RED}[!] 警告: 历史命令过少，可能已被清除！${NC}"
                ((ALERT_COUNT++))
            fi

            echo ""
        fi
    done
done

if [ $SUSPICIOUS_CMDS -eq 0 ]; then
    echo -e "${GREEN}[√] 未在历史命令中发现明显的可疑操作${NC}"
fi
echo ""

# ==========================================
# 8. 检测最近修改的敏感文件
# ==========================================
echo "[8] 检测最近修改的敏感文件"
echo "----------------------------------------"

echo "最近24小时修改的敏感文件:"
FOUND_FILES=0
while read -r file; do
    [ -z "$file" ] && continue
    MTIME=$(stat -c "%y" "$file" 2>/dev/null || stat -f "%Sm" "$file" 2>/dev/null)
    echo "$file (修改时间: $MTIME)"
    ((FOUND_FILES++))
done < <(find /root/.ssh /opt/nezha -type f -mtime -1 2>/dev/null)
if [ $FOUND_FILES -eq 0 ]; then
    echo -e "${GREEN}[√] 最近24小时无敏感文件变动${NC}"
fi
echo ""

# ==========================================
# 总结
# ==========================================
echo "=========================================="
echo "检测完成"
echo "=========================================="
echo ""

if [ $ALERT_COUNT -eq 0 ]; then
    echo -e "${GREEN}[√] 未发现明显的入侵痕迹${NC}"
    echo ""
    echo "建议定期执行本脚本进行安全检查"
else
    echo -e "${RED}[!!!] 发现 $ALERT_COUNT 个安全问题！${NC}"
    echo ""
    echo "紧急处理建议:"
    echo "1. 立即检查并清除异常SSH公钥"
    echo "2. 修改root密码"
    echo "3. 重新生成JWT密钥"
    echo "4. 检查最近的登录日志"
    echo "5. 考虑重装系统"
fi

echo ""
echo "=========================================="
echo "IKUNS出品"
echo "=========================================="