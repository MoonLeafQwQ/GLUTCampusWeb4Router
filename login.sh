#!/bin/sh
#=============================================================================
# 这是一个基于Openwrt路由的自动登录脚本
# 推荐使用方法: 由 cron 每分钟调用一次, 检测到断线时自动重新登录校园网
# 需要wget / ping
# 模拟浏览器向 Dr.COM eportal 网关发送 HTTP 登录请求
# 整体工作流程 (每次被 cron 调用时):
#   1. 先PING阿里DNS来检测是否在线（ICMP在未登录的时候是发不出去的，但是dns port 53是可以请求的）
#   2. 探测期间在线 → 直接退出
#   3. 探测到离线   → do_login 发起登录 (最多 2 次尝试)
#=============================================================================

#=======================  用户配置区 ========================================
USERNAME="  "          # 校园网账号
PASSWORD="  "              # 校园网密码


#   0 = 校园网   1 = 电信   2 = 移动   3 = 联通   4 = 广电
ISP="   "

SERVER="172.16.2.2" 
PORT="801"
LOG_FILE="/var/log/autologin.log" # 日志文件
#=============================================================================

log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') $*" | tee -a "$LOG_FILE"
}

#-----------------------------------------------------------------------------
# fetch_rcn: 从认证服务器获取一次性随机令牌 rcn
#   每次登录前必须先请求 loadConfig 接口拿到新的 rcn, 再随登录请求一起提交;
#   服务端校验 rcn 有效才会处理登录。若获取失败返回空, 由调用方用内置值兜底
#-----------------------------------------------------------------------------
fetch_rcn() {
    local resp
    resp=$(wget -q -O - --timeout=5 \
        "http://${SERVER}:${PORT}/eportal/portal/page/loadConfig?callback=dr1001&jsVersion=4.X&v=$(date +%s)&lang=zh" 2>/dev/null)
    [ -z "$resp" ] && return 1
    local rcn_val
    rcn_val=$(echo "$resp" | sed -n 's/.*"rcn"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')
    [ -n "$rcn_val" ] && echo "$rcn_val" && return 0
    return 1
}

#-----------------------------------------------------------------------------
# check_online: 在线状态检测
#   最多探测 10 次, 每次 ping 公网 223.5.5.5 (1 秒超时)
#   - 任意一次失败 → 立即判定离线 (return 1), 尽快转去登录
#   - 连续 10 次 (~50 秒) 全部成功 → 判定在线 (return 0)
#   设计成多次持续探测而非单次 ping, 是为了过滤瞬时网络抖动,
#   避免误判离线而反复登录 —— 频繁重复登录会触发 Dr.COM 的
#   error5 "waitsec <3" 频繁登录限制
#-----------------------------------------------------------------------------
check_online() {
    local i
    for i in $(seq 1 10); do
        if ! ping -c 1 -W 1 223.5.5.5 >/dev/null 2>&1; then
            log "第${i}次检测离线，立即登录"
            return 1
        fi
        [ $i -lt 10 ] && sleep 5
    done
    return 0
}

#-----------------------------------------------------------------------------
# do_login: 执行登录, 最多尝试 2 次 (第 2 次前等 5 秒)
#   关键登录参数 (GET /drcom/login):
#     DDDDD    = 账号 (纯数字, 不区分运营商; 运营商由 R3 单独标识)
#     upass    = 密码 (明文传输, Dr.COM 4.X 协议本身无加密)
#     R3       = 运营商编号, 见文件顶部配置区 ISP 注释
#     rcn      = 一次性防重放令牌, 由 fetch_rcn 提前获取
#     v        = 当前时间戳, 防止代理/浏览器缓存旧响应
#     callback = dr1006 → 服务端以 JSONP 形式返回: dr1006({"result":..,"msga":".."})
#
#   响应解析与处理:
#     result = 1                → 登录成功
#     msga 含 "clientip online"  → 本机IP已有在线会话, 不再重复登录
#     msga 含 "error5 waitsec<3" → 触发频繁登录限制 (与上次登录间隔 <3 秒),
#                                  本轮先等 5 秒再试第 2 次
#     其余情况                  → 记日志失败, 等下一分钟 cron 再试
#-----------------------------------------------------------------------------
do_login() {
    local account="$USERNAME"
    local attempt rcn attempt_count=0

    for attempt in 1 2; do
        attempt_count=$((attempt_count + 1))
        [ $attempt -gt 1 ] && log "第${attempt}次尝试..." && sleep 5

        rcn=$(fetch_rcn)
        [ -z "$rcn" ] && rcn="WV2kxUZP"

        log "正在登录... 账号: ${account}  rcn: ${rcn}"

        local params
        params="callback=dr1006"
        params="${params}&DDDDD=${account}"
        params="${params}&upass=${PASSWORD}"
        params="${params}&0MKKey=123456"
        params="${params}&R1=0"
        params="${params}&R2="
        params="${params}&R3=${ISP}"
        params="${params}&R6=0"
        params="${params}&para=00"
        params="${params}&v6ip="
        params="${params}&R7=0"
        params="${params}&login_t=0"
        params="${params}&js_status=0"
        params="${params}&is_page=1"
        params="${params}&is_page_new=7266"
        params="${params}&terminal_type=1"
        params="${params}&checkPerceive=1"
        params="${params}&lang=zh-cn"
        params="${params}&rcn=${rcn}"
        params="${params}&jsVersion=4.2.1"
        params="${params}&v=$(date +%s)"
        params="${params}&lang=zh"

        local url="http://${SERVER}/drcom/login?${params}"

        local resp
        resp=$(wget -q -O - --timeout=5 \
            --header="User-Agent: Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/149.0.0.0 Safari/537.36 Edg/149.0.0.0" \
            --header="Referer: http://${SERVER}/" \
            "$url" 2>&1)

        if [ $? -ne 0 ]; then
            log "登录请求失败"
            continue
        fi

        local login_result login_msg
        login_result=$(echo "$resp" | sed -n 's/.*"result"[[:space:]]*:[[:space:]]*\([0-9]*\).*/\1/p')
        login_msg=$(echo "$resp" | sed -n 's/.*"msga"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')
#-----------------------------------------------------------------------------
# msga 为 "clientip online" 时视为"已在线",直接成功退出
#-----------------------------------------------------------------------------
        if echo "$login_msg" | grep -q "clientip online\|clienttip online"; then
            log "已在线"
            return 0
        fi

        if [ "$login_result" = "1" ]; then
            log "登录成功"
            return 0
        fi

        if echo "$login_msg" | grep -q "error5 waitsec <3"; then
            log "登录受限 (${login_msg})，5秒后重试"
            continue
        fi

        log "登录失败 (msga=${login_msg:-无})"
    done

    log "两次尝试均失败，退出"
    return 1
}

#-----------------------------------------------------------------------------
# once_mode: 单次执行主流程 (配合 cron 每分钟跑一次)
#   先查在线状态: 在线就退出; 离线才调用 do_login
#-----------------------------------------------------------------------------
once_mode() {
    if check_online; then
        log "当前在线"
        exit 0
    fi

    do_login
    exit $?
}

case "${1:-login}" in
    login)  once_mode ;;
    check)
        check_online && { log "当前在线"; exit 0; } || { log "当前离线"; exit 1; } ;;
    *)      exit 1 ;;
esac
