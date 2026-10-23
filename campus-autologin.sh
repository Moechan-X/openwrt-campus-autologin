#!/bin/sh
# campus-autologin.sh - 校园网 Web 认证自动登录脚本 (OpenWrt)
#
# 工作原理:
#   1. 检测在线状态 (访问 generate_204 检测地址)
#   2. 离线时, 访问检测地址, 从 BRAS 的 302 重定向中动态提取认证参数
#      (wlanuserip / wlanacname / mac / nasip / userlocation 等, IP 变化无需改配置)
#   3. POST http://<portal>/api/portal/webauth 完成认证 (明文表单, 与网页端一致)
#   4. 校验结果并写 syslog (logread 可查)
#
# 用法:
#   campus-autologin.sh --once      单次检测+登录 (hotplug 调用)
#   campus-autologin.sh --watchdog  常驻看门狗 (init.d 服务调用)

. /lib/functions.sh

LOG_TAG="campus-autologin"

# 配置默认值 (可被 /etc/config/campus-autologin 覆盖)
CFG_USER=""
CFG_PASS=""
CFG_HOST="10.2.1.27"
CFG_CHECK="http://connect.rom.miui.com/generate_204"
CFG_INT=30
CFG_TPL=""

load_config() {
	config_load campus-autologin
	config_get CFG_USER login username
	config_get CFG_PASS login password
	config_get CFG_HOST login portal_host "$CFG_HOST"
	config_get CFG_CHECK login check_url "$CFG_CHECK"
	config_get CFG_INT login interval "$CFG_INT"
	config_get CFG_TPL login portal_url "$CFG_TPL"
}

log() {
	logger -t "$LOG_TAG" "$*"
}

have_curl() {
	command -v curl >/dev/null 2>&1
}

# 在线检测: curl 返回 204 即在线; 无 curl 时用 ping 兜底
is_online() {
	if have_curl; then
		[ "$(curl -s -o /dev/null -m 6 -w '%{http_code}' "$CFG_CHECK" 2>/dev/null)" = "204" ]
	else
		ping -c1 -W3 223.5.5.5 >/dev/null 2>&1
	fi
}

# 获取认证参数: 从重定向 Location 提取查询串, 失败则用固定模板
get_portal_query() {
	local loc=""
	if have_curl; then
		loc=$(curl -s -o /dev/null -m 6 -w '%{redirect_url}' "$CFG_CHECK" 2>/dev/null)
	else
		loc=$(uclient-fetch -q -O /dev/null "$CFG_CHECK" 2>&1 | grep -o 'http[^ "]*portal/webauth[^ "]*' | head -n1)
	fi
	case "$loc" in
		*portal/webauth*)
			printf '%s' "${loc#*\?}"
			return 0
			;;
	esac
	if [ -n "$CFG_TPL" ]; then
		printf '%s' "${CFG_TPL#*\?}"
		return 0
	fi
	return 1
}

# 执行登录
do_login() {
	local query resp message
	if [ -z "$CFG_USER" ] || [ -z "$CFG_PASS" ]; then
		log "未配置账号或密码, 请检查 /etc/config/campus-autologin"
		return 1
	fi
	query=$(get_portal_query) || {
		log "未收到 portal 重定向, 无法获取认证参数"
		return 1
	}

	if have_curl; then
		resp=$(curl -s -m 10 -X POST "http://$CFG_HOST/api/portal/webauth" \
			-H "Content-Type: application/x-www-form-urlencoded" \
			--data "${query}&userId=${CFG_USER}&passwd=${CFG_PASS}&loginMode=password" 2>/dev/null)
	else
		resp=$(uclient-fetch -q -O - --post-data="${query}&userId=${CFG_USER}&passwd=${CFG_PASS}&loginMode=password" \
			"http://$CFG_HOST/api/portal/webauth" 2>/dev/null)
	fi

	[ -z "$resp" ] && {
		log "认证服务器无响应"
		return 1
	}

	case "$resp" in
		*'"success":true'*)
			log "登录成功 (user=$CFG_USER)"
			return 0
			;;
		*)
			message=$(printf '%s' "$resp" | sed -n 's/.*"message":"\([^"]*\)".*/\1/p')
			[ -z "$message" ] && message=$(printf '%s' "$resp" | cut -c1-200)
			log "登录失败: $message"
			return 1
			;;
	esac
}

# 单次模式
run_once() {
	is_online && return 0
	log "检测到离线, 尝试登录..."
	do_login || return 1
	if is_online; then
		log "登录后网络已恢复"
	else
		log "登录请求已完成, 但网络仍未恢复"
		return 1
	fi
}

# 看门狗模式: 周期检测, 连续失败时指数退避 (上限 300s)
run_watchdog() {
	local fails=0 backoff
	while :; do
		if is_online; then
			fails=0
		else
			log "检测到离线, 尝试登录..."
			if do_login && is_online; then
				fails=0
				log "网络已恢复"
			else
				fails=$((fails + 1))
			fi
		fi
		backoff=$CFG_INT
		[ "$fails" -gt 3 ] && backoff=$((CFG_INT * (fails - 2)))
		[ "$backoff" -gt 300 ] && backoff=300
		sleep "$backoff"
	done
}

case "$1" in
	--watchdog)
		load_config
		run_watchdog
		;;
	--once | "")
		load_config
		run_once
		;;
	*)
		echo "usage: $0 [--once|--watchdog]"
		exit 1
		;;
esac
