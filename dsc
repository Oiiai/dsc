#!/bin/bash

# DSC 包管理器 - 适配自定义仓库规范
# 仓库结构：info.dsc install.sh delete.sh afterinstall.sh beforedelete.sh

set -e

DSC_ROOT="/etc/dsc"
MIRROR_FILE="$DSC_ROOT/mirrorlist.d"
PKG_ROOT="/usr/local/dsc/pkg"
INSTALLED_FILE="$DSC_ROOT/installed.json"

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
CYAN='\033[0;36m'
WHITE='\033[0;37m'
BOLD='\033[1m'
NC='\033[0m' # 无颜色

# 图标定义
ICON_OK="${GREEN}✓${NC}"
ICON_ERROR="${RED}✗${NC}"
ICON_WARN="${YELLOW}⚠${NC}"
ICON_INFO="${BLUE}ℹ${NC}"
ICON_PKG="${PURPLE}📦${NC}"
ICON_GIT="${CYAN}🔄${NC}"
ICON_TRASH="${RED}🗑${NC}"
ICON_SEARCH="${CYAN}🔍${NC}"
ICON_INSTALL="${GREEN}⬇${NC}"
ICON_DELETE="${RED}🗑${NC}"
ICON_UPDATE="${YELLOW}↻${NC}"
ICON_SUCCESS="${GREEN}✔${NC}"
ICON_FAILURE="${RED}✘${NC}"

mkdir -p "$DSC_ROOT" "$PKG_ROOT"
touch "$MIRROR_FILE" "$INSTALLED_FILE"

# 日志函数
log_info() {
    echo -e "${ICON_INFO} ${BLUE}$1${NC}"
}

log_success() {
    echo -e "${ICON_OK} ${GREEN}$1${NC}"
}

log_error() {
    echo -e "${ICON_ERROR} ${RED}$1${NC}" >&2
}

log_warning() {
    echo -e "${ICON_WARN} ${YELLOW}$1${NC}"
}

log_section() {
    echo -e "\n${BOLD}${CYAN}═══════════════════════════════════════════════════════════════${NC}"
    echo -e "${BOLD}${WHITE}  $1${NC}"
    echo -e "${BOLD}${CYAN}═══════════════════════════════════════════════════════════════${NC}"
}

log_cmd() {
    echo -e "${CYAN}→${NC} $1"
}

log_pkg_header() {
    echo -e "\n${ICON_PKG} ${BOLD}${WHITE}包: ${PURPLE}$1${NC} ${GRAY}[$2]${NC}"
    echo -e "${CYAN}───────────────────────────────────────────────────────${NC}"
}

# 检查依赖
check_jq() {
    if ! command -v jq &>/dev/null; then
        log_error "需要 jq 解析 JSON"
        echo -e "${YELLOW}请安装 jq:${NC}"
        echo "  apt install jq        # Debian/Ubuntu"
        echo "  yum install jq        # CentOS/RHEL"
        echo "  pacman -S jq          # Arch Linux"
        exit 1
    fi
}

# 获取包仓库地址
get_repo() {
    local pkg="$1"
    jq -r ".\"$pkg\" // \"null\"" "$MIRROR_FILE" 2>/dev/null
}

# 标记已安装
mark_installed() {
    local pkg="$1"
    if [ ! -s "$INSTALLED_FILE" ]; then
        echo "{\"$pkg\":\"installed\"}" > "$INSTALLED_FILE"
    else
        jq --arg p "$pkg" '.[$p] = "installed"' "$INSTALLED_FILE" > "$INSTALLED_FILE.tmp"
        mv "$INSTALLED_FILE.tmp" "$INSTALLED_FILE"
    fi
}

# 标记卸载
mark_removed() {
    local pkg="$1"
    jq --arg p "$pkg" 'del(.[$p])' "$INSTALLED_FILE" > "$INSTALLED_FILE.tmp"
    mv "$INSTALLED_FILE.tmp" "$INSTALLED_FILE"
}

# 判断是否安装
is_installed() {
    local pkg="$1"
    if [ ! -s "$INSTALLED_FILE" ]; then
        return 1
    fi
    jq -e ".\"$pkg\" == \"installed\"" "$INSTALLED_FILE" >/dev/null 2>&1
}

# 读取 info.dsc 中的字段
get_info() {
    local pkg="$1"
    local key="$2"
    local file="$PKG_ROOT/$pkg/info.dsc"
    if [ ! -f "$file" ]; then
        echo "未知"
        return
    fi
    awk -v k="$key" '$1==k {gsub("^= ","",$0); sub(/^[^=]*= /,""); print}' "$file" | head -n1
}

# 进度显示
show_progress() {
    local pid=$1
    local message=$2
    local spin='-\|/'
    local i=0
    while kill -0 $pid 2>/dev/null; do
        i=$(( (i+1) % 4 ))
        printf "\r${CYAN}[%c]${NC} %s" "${spin:$i:1}" "$message"
        sleep 0.1
    done
    printf "\r${GREEN}[✓]${NC} %s\n" "$message"
}

# ------------------------------
# 命令实现
# ------------------------------

cmd_install() {
    [ $# -eq 0 ] && echo -e "${RED}错误：请指定要安装的包${NC}" && echo "用法：dsc install <包...>" && exit 1
    check_jq

    log_section "安装软件包"

    for pkg in "$@"; do
        log_pkg_header "$pkg" "安装中"
        
        repo=$(get_repo "$pkg")
        if [ "$repo" = "null" ]; then
            log_error "无对应源，请在 $MIRROR_FILE 中配置"
            continue
        fi

        log_info "源地址: $repo"
        
        cd "$PKG_ROOT"

        if [ -d "$pkg" ]; then
            log_info "更新本地源码..."
            cd "$pkg"
            git pull > /dev/null 2>&1 &
            show_progress $! "更新源码"
        else
            log_info "克隆仓库..."
            git clone "$repo" "$pkg" > /dev/null 2>&1 &
            show_progress $! "克隆仓库"
            cd "$pkg"
        fi

        # 必须有 info.dsc
        if [ ! -f info.dsc ]; then
            log_error "$pkg 没有 info.dsc，无法安装"
            continue
        fi

        # 显示包信息
        version=$(get_info "$pkg" version)
        author=$(get_info "$pkg" author)
        desc=$(get_info "$pkg" description)
        
        echo -e "${CYAN}┌─ 包信息${NC}"
        [ -n "$version" ] && echo -e "${CYAN}│${NC} 版本: $version"
        [ -n "$author" ] && echo -e "${CYAN}│${NC} 作者: $author"
        [ -n "$desc" ] && echo -e "${CYAN}│${NC} 描述: $desc"
        echo -e "${CYAN}└────────────────────────${NC}"

        # 安装脚本
        if [ -f install.sh ]; then
            chmod +x install.sh
            log_cmd "执行安装脚本..."
            if ./install.sh; then
                log_success "安装脚本执行成功"
            else
                log_error "安装脚本执行失败"
                continue
            fi
        else
            log_error "无 install.sh 安装脚本"
            continue
        fi

        # 安装后脚本
        if [ -f afterinstall.sh ]; then
            chmod +x afterinstall.sh
            log_cmd "执行安装后脚本..."
            ./afterinstall.sh && log_success "安装后脚本执行成功" || log_warning "安装后脚本执行失败"
        fi

        mark_installed "$pkg"
        echo -e "\n${ICON_SUCCESS} ${GREEN}${BOLD}[$pkg] 安装完成！${NC}"
    done
}

cmd_delete() {
    [ $# -eq 0 ] && echo -e "${RED}错误：请指定要卸载的包${NC}" && echo "用法：dsc delete <包...>" && exit 1
    check_jq

    log_section "卸载软件包"

    for pkg in "$@"; do
        log_pkg_header "$pkg" "卸载中"
        
        if ! is_installed "$pkg"; then
            log_warning "[$pkg] 未安装"
            continue
        fi

        pkg_dir="$PKG_ROOT/$pkg"
        cd "$pkg_dir" || continue

        # 卸载前脚本
        if [ -f beforedelete.sh ]; then
            chmod +x beforedelete.sh
            log_cmd "执行卸载前脚本..."
            ./beforedelete.sh && log_success "卸载前脚本执行成功" || log_warning "卸载前脚本执行失败"
        fi

        # 卸载脚本
        if [ -f delete.sh ]; then
            chmod +x delete.sh
            log_cmd "执行卸载脚本..."
            ./delete.sh && log_success "卸载脚本执行成功" || log_warning "卸载脚本执行失败"
        else
            log_warning "无 delete.sh，将直接删除文件"
        fi

        log_cmd "删除包目录..."
        rm -rf "$pkg_dir" && log_success "包目录已删除"
        
        mark_removed "$pkg"
        echo -e "\n${ICON_SUCCESS} ${GREEN}${BOLD}[$pkg] 已卸载${NC}"
    done
}

cmd_reinstall() {
    [ $# -eq 0 ] && echo -e "${RED}错误：请指定要重装的包${NC}" && echo "用法：dsc reinstall <包...>" && exit 1
    
    log_section "重新安装软件包"
    
    for pkg in "$@"; do
        echo -e "\n${ICON_UPDATE} ${YELLOW}重新安装: ${BOLD}$pkg${NC}"
        cmd_delete "$pkg"
        cmd_install "$pkg"
    done
}

cmd_update() {
    check_jq
    
    log_section "更新已安装的软件包"
    
    installed_pkgs=$(jq -r 'keys[]' "$INSTALLED_FILE" 2>/dev/null)
    [ -z "$installed_pkgs" ] && log_info "没有已安装的包" && return
    
    count=0
    for pkg in $installed_pkgs; do
        repo=$(get_repo "$pkg")
        [ "$repo" = "null" ] && continue
        
        dir="$PKG_ROOT/$pkg"
        [ -d "$dir/.git" ] || continue
        
        echo -e "\n${ICON_UPDATE} ${BOLD}${WHITE}$pkg${NC}"
        cd "$dir"
        
        # 检查更新
        git remote update > /dev/null 2>&1
        local_commit=$(git rev-parse HEAD)
        remote_commit=$(git rev-parse @{u} 2>/dev/null || echo "")
        
        if [ "$local_commit" != "$remote_commit" ] && [ -n "$remote_commit" ]; then
            log_info "发现更新，正在拉取..."
            git pull > /dev/null 2>&1 &
            show_progress $! "更新 $pkg"
            count=$((count + 1))
        else
            log_success "已是最新"
        fi
    done
    
    echo -e "\n${ICON_SUCCESS} ${GREEN}更新完成，共更新 $count 个包${NC}"
}

cmd_search() {
    [ $# -ne 1 ] && echo -e "${RED}错误：请指定搜索关键词${NC}" && echo "用法：dsc search <关键词>" && exit 1
    check_jq
    
    log_section "搜索软件包: $1"
    
    results=$(jq -r 'keys[]' "$MIRROR_FILE" 2>/dev/null | grep -i "$1" || true)
    
    if [ -z "$results" ]; then
        log_warning "未找到匹配的包: $1"
        return
    fi
    
    echo -e "${BOLD}${WHITE}找到以下匹配的包:${NC}\n"
    while IFS= read -r pkg; do
        if is_installed "$pkg"; then
            echo -e "  ${ICON_PKG} ${PURPLE}${BOLD}$pkg${NC} ${GREEN}[已安装]${NC}"
        else
            echo -e "  ${ICON_PKG} ${PURPLE}${BOLD}$pkg${NC} ${WHITE}[未安装]${NC}"
        fi
    done <<< "$results"
}

cmd_info() {
    [ $# -ne 1 ] && echo -e "${RED}错误：请指定包名${NC}" && echo "用法：dsc info <包>" && exit 1
    check_jq
    
    local pkg="$1"
    
    log_section "包信息: $pkg"
    
    repo=$(get_repo "$pkg")
    if [ "$repo" = "null" ]; then
        log_error "无此包"
        return
    fi

    echo -e "${BOLD}${WHITE}基本信息:${NC}"
    echo -e "  ${CYAN}源地址:${NC}  $repo"
    
    if is_installed "$pkg"; then
        echo -e "  ${CYAN}状态:${NC}    ${GREEN}已安装${NC}"
        
        # 从 info.dsc 读取详细信息
        if [ -f "$PKG_ROOT/$pkg/info.dsc" ]; then
            echo -e "\n${BOLD}${WHITE}包详细信息:${NC}"
            while IFS= read -r line; do
                if [[ "$line" =~ ^[a-zA-Z]+= ]]; then
                    key=$(echo "$line" | cut -d= -f1)
                    value=$(echo "$line" | cut -d= -f2-)
                    printf "  ${CYAN}%-12s${NC} %s\n" "$key:" "$value"
                fi
            done < "$PKG_ROOT/$pkg/info.dsc"
        fi
    else
        echo -e "  ${CYAN}状态:${NC}    ${YELLOW}未安装${NC}"
        echo -e "\n${YELLOW}提示:${NC} 使用 'dsc install $pkg' 安装此包"
    fi
}

# ------------------------------
# 入口
# ------------------------------

case "$1" in
    install) shift; cmd_install "$@" ;;
    delete|remove) shift; cmd_delete "$@" ;;
    reinstall) shift; cmd_reinstall "$@" ;;
    update) cmd_update ;;
    search) shift; cmd_search "$@" ;;
    info) shift; cmd_info "$@" ;;
    *)
        echo -e "${BOLD}${CYAN}╔════════════════════════════════════════════════════════════╗${NC}"
        echo -e "${BOLD}${CYAN}║                    DSC 包管理器 v1.0                       ║${NC}"
        echo -e "${BOLD}${CYAN}╚════════════════════════════════════════════════════════════╝${NC}"
        echo -e "\n${BOLD}${WHITE}用法:${NC}"
        echo -e "  ${GREEN}dsc install <包...>${NC}    安装一个或多个软件包"
        echo -e "  ${RED}dsc delete <包...>${NC}     卸载一个或多个软件包"
        echo -e "  ${YELLOW}dsc reinstall <包...>${NC} 重新安装一个或多个软件包"
        echo -e "  ${CYAN}dsc update${NC}             更新所有已安装的软件包"
        echo -e "  ${CYAN}dsc search <关键词>${NC}    搜索软件包"
        echo -e "  ${BLUE}dsc info <包>${NC}          显示软件包信息"
        
        echo -e "\n${BOLD}${WHITE}示例:${NC}"
        echo -e "  ${GREEN}dsc install nginx${NC}"
        echo -e "  ${RED}dsc delete mysql${NC}"
        echo -e "  ${YELLOW}dsc reinstall php${NC}"
        echo -e "  ${CYAN}dsc search web${NC}"
        echo -e "  ${BLUE}dsc info redis${NC}"
        
        echo -e "\n${BOLD}${WHITE}配置文件:${NC}"
        echo -e "  ${CYAN}$MIRROR_FILE${NC}   - 软件源配置"
        echo -e "  ${CYAN}$INSTALLED_FILE${NC} - 已安装包记录"
        echo -e "  ${CYAN}$PKG_ROOT${NC}      - 软件包存储目录"
        ;;
esac