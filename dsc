#!/bin/bash

# DSC 包管理器 - 适配自定义仓库规范
# 仓库结构：info.dsc install.sh delete.sh afterinstall.sh beforedelete.sh

set -e

DSC_ROOT="/etc/dsc"
MIRROR_FILE="$DSC_ROOT/repolist.d"
PKG_ROOT="/usr/local/dsc/pkg"
INSTALLED_FILE="$DSC_ROOT/installed.json"

# 颜色定义 - 参考 pacman 风格
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
CYAN='\033[0;36m'
WHITE='\033[0;37m'
GRAY='\033[0;90m'
BOLD='\033[1m'
NC='\033[0m' # 无颜色

# 图标定义 - 更简洁的符号
ICON_OK="✓"
ICON_ERROR="✗"
ICON_WARN="⚠"
ICON_INFO="ℹ"
ICON_PKG="📦"
ICON_GIT="🌐"
ICON_TRASH="🗑"
ICON_SEARCH="🔍"
ICON_INSTALL="↓"
ICON_DELETE="✗"
ICON_UPDATE="↻"
ICON_SUCCESS="✔"
ICON_FAILURE="✘"
ICON_ARROW="→"
ICON_DOWNLOAD="⬇"
ICON_CLOCK="⌛"
ICON_LIST="📋"
ICON_SOURCE="📡"

mkdir -p "$DSC_ROOT" "$PKG_ROOT"
touch "$MIRROR_FILE" "$INSTALLED_FILE"

# 日志函数 - 简化输出格式
log_info() {
    echo -e "${BLUE}::${NC} $1"
}

log_success() {
    echo -e "${GREEN}::${NC} $1"
}

log_error() {
    echo -e "${RED}::${NC} $1" >&2
}

log_warning() {
    echo -e "${YELLOW}::${NC} $1"
}

log_section() {
    echo -e "\n${BOLD}${CYAN}==>${NC}${BOLD} $1${NC}"
}

log_subsection() {
    echo -e "  ${CYAN}->${NC} $1"
}

log_cmd() {
    echo -e "  ${GRAY}$ICON_ARROW${NC} $1"
}

log_pkg_header() {
    echo -e "\n${BOLD}${PURPLE}${ICON_PKG}${NC} ${BOLD}$1${NC} ${GRAY}$2${NC}"
}

# 检查依赖
check_jq() {
    if ! command -v jq &>/dev/null; then
        log_error "需要 jq 解析 JSON"
        echo -e "${YELLOW}  请安装 jq:${NC}"
        echo "    apt install jq        # Debian/Ubuntu"
        echo "    yum install jq        # CentOS/RHEL"
        echo "    pacman -S jq          # Arch Linux"
        exit 1
    fi
}

# 获取包的所有仓库源（返回数组）
get_repo_sources() {
    local pkg="$1"
    local sources=$(jq -r ".\"$pkg\" // [] | if type==\"array\" then .[] else . end" "$MIRROR_FILE" 2>/dev/null)
    echo "$sources"
}

# 获取包的第一个仓库源（用于兼容旧版本）
get_first_repo() {
    local pkg="$1"
    local first=$(jq -r ".\"$pkg\" // [] | if type==\"array\" then .[0] else . end // \"null\"" "$MIRROR_FILE" 2>/dev/null)
    echo "$first"
}

# 检查包是否有仓库源
has_repo() {
    local pkg="$1"
    local sources=$(get_repo_sources "$pkg")
    [ -n "$sources" ]
}

# 获取包的所有仓库源数量
get_repo_count() {
    local pkg="$1"
    jq -r ".\"$pkg\" // [] | if type==\"array\" then length else 1 end" "$MIRROR_FILE" 2>/dev/null || echo "0"
}

# 列出包的所有仓库源（带序号）
list_repo_sources() {
    local pkg="$1"
    local sources=$(get_repo_sources "$pkg")
    
    if [ -z "$sources" ]; then
        return 1
    fi
    
    local index=1
    while IFS= read -r source; do
        if [ -n "$source" ]; then
            echo -e "  ${CYAN}[$index]${NC} $source"
            index=$((index + 1))
        fi
    done <<< "$sources"
    
    return 0
}

# 添加仓库源到包
add_repo_source() {
    local pkg="$1"
    local url="$2"
    
    # 检查 repolist.d 文件是否存在并初始化
    if [ ! -f "$MIRROR_FILE" ]; then
        echo "{}" > "$MIRROR_FILE"
    elif [ ! -s "$MIRROR_FILE" ]; then
        echo "{}" > "$MIRROR_FILE"
    fi
    
    # 获取当前仓库源
    local current=$(jq -c ".\"$pkg\" // []" "$MIRROR_FILE" 2>/dev/null)
    
    # 检查是否已存在相同的 URL
    local exists=$(echo "$current" | jq -r "if type==\"array\" then .[] else . end | select(. == \"$url\")" 2>/dev/null)
    
    if [ -n "$exists" ]; then
        log_warning "仓库源已存在: $url"
        return 1
    fi
    
    # 添加新源
    if [ "$current" = "[]" ] || [ -z "$current" ]; then
        # 第一个源，创建数组
        jq --arg p "$pkg" --arg u "$url" '.[$p] = [$u]' "$MIRROR_FILE" > "$MIRROR_FILE.tmp"
    else
        # 已有源，追加到数组
        if echo "$current" | jq -e 'type=="array"' >/dev/null 2>&1; then
            # 已经是数组
            jq --arg p "$pkg" --arg u "$url" '.[$p] += [$u]' "$MIRROR_FILE" > "$MIRROR_FILE.tmp"
        else
            # 是单个值，转换为数组
            local old_value=$(jq -r ".\"$pkg\"" "$MIRROR_FILE")
            jq --arg p "$pkg" --arg u "$url" --arg o "$old_value" '.[$p] = [$o, $u]' "$MIRROR_FILE" > "$MIRROR_FILE.tmp"
        fi
    fi
    
    mv "$MIRROR_FILE.tmp" "$MIRROR_FILE"
    log_success "仓库源添加成功: $url"
    return 0
}

# 删除包的指定仓库源
remove_repo_source() {
    local pkg="$1"
    local index="$2"  # 1-based index
    
    local current=$(jq -c ".\"$pkg\"" "$MIRROR_FILE" 2>/dev/null)
    
    if [ -z "$current" ] || [ "$current" = "null" ]; then
        log_error "包 '$pkg' 不存在"
        return 1
    fi
    
    # 如果是单个值，直接删除整个包
    if ! echo "$current" | jq -e 'type=="array"' >/dev/null 2>&1; then
        if [ "$index" = "1" ]; then
            jq --arg p "$pkg" 'del(.[$p])' "$MIRROR_FILE" > "$MIRROR_FILE.tmp"
            mv "$MIRROR_FILE.tmp" "$MIRROR_FILE"
            log_success "已删除包 '$pkg' 的唯一仓库源"
            return 0
        else
            log_error "无效的索引"
            return 1
        fi
    fi
    
    # 获取数组长度
    local length=$(echo "$current" | jq 'length')
    
    if [ "$index" -lt 1 ] || [ "$index" -gt "$length" ]; then
        log_error "索引超出范围 (1-$length)"
        return 1
    fi
    
    # 删除指定索引的元素（jq 索引从0开始）
    local jq_index=$((index - 1))
    local new_array=$(echo "$current" | jq "del(.[$jq_index])")
    
    # 如果数组为空，删除整个包
    if [ "$(echo "$new_array" | jq 'length')" -eq 0 ]; then
        jq --arg p "$pkg" 'del(.[$p])' "$MIRROR_FILE" > "$MIRROR_FILE.tmp"
    else
        jq --arg p "$pkg" --argjson a "$new_array" '.[$p] = $a' "$MIRROR_FILE" > "$MIRROR_FILE.tmp"
    fi
    
    mv "$MIRROR_FILE.tmp" "$MIRROR_FILE"
    log_success "已删除仓库源 #$index"
    return 0
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

# 获取所有已安装的包
get_installed_pkgs() {
    jq -r 'keys[]' "$INSTALLED_FILE" 2>/dev/null || true
}

# 获取所有仓库中的包
get_all_repo_pkgs() {
    jq -r 'keys[]' "$MIRROR_FILE" 2>/dev/null || true
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

# 进度显示 - 更简洁的动画
show_progress() {
    local pid=$1
    local message=$2
    local spin='-\|/'
    local i=0
    while kill -0 $pid 2>/dev/null; do
        i=$(( (i+1) % 4 ))
        printf "\r  ${CYAN}[%c]${NC} %s" "${spin:$i:1}" "$message"
        sleep 0.1
    done
    printf "\r  ${GREEN}[✓]${NC} %s\n" "$message"
}

# 确认批量操作
confirm_batch() {
    local action="$1"
    local count="$2"
    echo -e "${YELLOW}⚠ 警告:${NC} 您即将 $action ${BOLD}$count${NC} 个软件包"
    echo -n "确认继续？[y/N] "
    read -r answer
    if [[ ! "$answer" =~ ^[Yy]$ ]]; then
        log_info "操作已取消"
        return 1
    fi
    return 0
}

# ==================== 仓库管理功能 ====================

# 从 Git URL 提取包名
extract_pkgname_from_url() {
    local url="$1"
    # 移除末尾的 .git
    url="${url%.git}"
    # 移除末尾的 /
    url="${url%/}"
    
    # 从 GitHub URL 提取用户名/仓库名
    if [[ "$url" =~ github\.com[:/]([^/]+)/([^/]+) ]]; then
        echo "${BASH_REMATCH[1]}/${BASH_REMATCH[2]}"
    else
        # 如果不是标准格式，返回 URL 的最后两部分
        echo "$url" | awk -F'[/:]' '{print $(NF-1)"/"$NF}'
    fi
}

# 添加仓库命令
cmd_addrepo() {
    local url=""
    local pkgname=""
    local has_for_param=false
    
    # 解析参数
    while [ $# -gt 0 ]; do
        case "$1" in
            -for)
                has_for_param=true
                shift
                if [ $# -gt 0 ] && [[ ! "$1" =~ ^- ]]; then
                    pkgname="$1"
                    shift
                fi
                ;;
            *)
                if [ -z "$url" ]; then
                    url="$1"
                fi
                shift
                ;;
        esac
    done
    
    # 检查 URL 参数
    if [ -z "$url" ]; then
        log_error "请指定仓库 URL"
        echo "用法: dsc addrepo <URL> [-for <包名>]"
        echo ""
        echo "示例:"
        echo "  dsc addrepo https://github.com/Jia/111/ -for example"
        echo "  dsc addrepo https://github.com/Jia/111/"
        return 1
    fi
    
    # 确定包名
    if [ "$has_for_param" = true ] && [ -n "$pkgname" ]; then
        # 使用 -for 参数指定的包名
        log_info "使用指定的包名: $pkgname"
    else
        # 从 URL 自动提取包名
        pkgname=$(extract_pkgname_from_url "$url")
        log_info "从 URL 自动提取包名: $pkgname"
    fi
    
    # 添加仓库源
    if add_repo_source "$pkgname" "$url"; then
        echo ""
        echo "包名: $pkgname"
        echo "URL:  $url"
        echo ""
        echo "您现在可以使用以下命令："
        echo "  dsc info $pkgname          # 查看包信息"
        echo "  dsc install $pkgname       # 安装包（使用默认源）"
        echo "  dsc install $pkgname -list # 列出所有源"
        echo "  dsc install $pkgname -use 1 # 使用指定源安装"
    fi
}

# 查看所有仓库
cmd_listrepo() {
    check_jq
    
    log_section "已配置的仓库源"
    
    if [ ! -f "$MIRROR_FILE" ] || [ ! -s "$MIRROR_FILE" ] || [ "$(jq 'length' "$MIRROR_FILE" 2>/dev/null)" -eq 0 ]; then
        log_warning "没有配置任何仓库源"
        echo "使用 'dsc addrepo <URL>' 添加仓库源"
        return
    fi
    
    echo -e "${BOLD}当前配置的仓库:${NC}\n"
    
    jq -r 'keys[]' "$MIRROR_FILE" 2>/dev/null | while read -r pkg; do
        if [ -n "$pkg" ]; then
            local count=$(get_repo_count "$pkg")
            if is_installed "$pkg"; then
                echo -e "  ${PURPLE}${ICON_PKG}${NC} ${BOLD}$pkg${NC} ${GREEN}[已安装]${NC} ${GRAY}($count 个源)${NC}"
            else
                echo -e "  ${PURPLE}${ICON_PKG}${NC} ${BOLD}$pkg${NC} ${GRAY}[未安装]${NC} ${GRAY}($count 个源)${NC}"
            fi
            
            # 列出该包的所有源
            list_repo_sources "$pkg" | sed 's/^/    /'
            echo ""
        fi
    done
    
    echo -e "${GRAY}总包数: $(jq 'length' "$MIRROR_FILE" 2>/dev/null)${NC}"
}

# 删除单个仓库
cmd_rmrepo() {
    [ $# -eq 0 ] && log_error "请指定要删除的包名或使用 -all" && echo "用法: dsc rmrepo <包名> [索引] 或 dsc rmrepo -all" && return 1
    
    local pkg="$1"
    local index="$2"
    
    check_jq
    
    if [ ! -f "$MIRROR_FILE" ] || [ ! -s "$MIRROR_FILE" ]; then
        log_error "仓库文件不存在或为空"
        return 1
    fi
    
    # 检查包是否存在
    local sources=$(get_repo_sources "$pkg")
    if [ -z "$sources" ]; then
        log_error "包 '$pkg' 不存在于仓库源中"
        return 1
    fi
    
    # 如果没有指定索引，列出所有源让用户选择
    if [ -z "$index" ]; then
        local count=$(get_repo_count "$pkg")
        
        if [ "$count" -eq 1 ]; then
            # 只有一个源，直接询问是否删除
            local url=$(get_first_repo "$pkg")
            echo -e "包 '$pkg' 只有一个仓库源:"
            echo "  $url"
            echo -n "确认删除？[y/N] "
            read -r answer
            if [[ "$answer" =~ ^[Yy]$ ]]; then
                remove_repo_source "$pkg" 1
            else
                log_info "操作已取消"
            fi
            return
        fi
        
        echo -e "包 '$pkg' 有多个仓库源，请选择要删除的源:"
        list_repo_sources "$pkg"
        echo -n "请输入要删除的源编号 (1-$count): "
        read -r index
        
        if ! [[ "$index" =~ ^[0-9]+$ ]] || [ "$index" -lt 1 ] || [ "$index" -gt "$count" ]; then
            log_error "无效的编号"
            return 1
        fi
    fi
    
    # 检查是否已安装
    if is_installed "$pkg"; then
        log_warning "包 '$pkg' 已安装，删除仓库源不会卸载包"
    fi
    
    # 显示要删除的源
    local url_to_delete=$(get_repo_sources "$pkg" | sed -n "${index}p")
    echo -e "即将删除仓库源:"
    echo "  包名: $pkg"
    echo "  索引: #$index"
    echo "  URL:  $url_to_delete"
    echo -n "确认删除？[y/N] "
    read -r answer
    if [[ ! "$answer" =~ ^[Yy]$ ]]; then
        log_info "操作已取消"
        return 0
    fi
    
    remove_repo_source "$pkg" "$index"
}

# 删除所有仓库
cmd_rmrepo_all() {
    check_jq
    
    log_section "删除所有仓库源"
    
    if [ ! -f "$MIRROR_FILE" ] || [ ! -s "$MIRROR_FILE" ] || [ "$(jq 'length' "$MIRROR_FILE" 2>/dev/null)" -eq 0 ]; then
        log_warning "没有配置任何仓库源"
        return
    fi
    
    local total=$(jq 'length' "$MIRROR_FILE")
    
    # 显示将要删除的仓库
    echo -e "${BOLD}将删除以下仓库源:${NC}\n"
    jq -r 'keys[]' "$MIRROR_FILE" 2>/dev/null | while read -r pkg; do
        echo "  - $pkg"
        list_repo_sources "$pkg" | sed 's/^/      /'
    done
    echo ""
    
    # 检查是否有已安装的包
    local installed_count=0
    local installed_list=""
    while IFS= read -r pkg; do
        if is_installed "$pkg"; then
            installed_count=$((installed_count + 1))
            installed_list="${installed_list}  - $pkg\n"
        fi
    done < <(get_all_repo_pkgs)
    
    if [ $installed_count -gt 0 ]; then
        log_warning "以下 $installed_count 个包已安装，删除仓库源不会卸载它们："
        echo -e "$installed_list"
    fi
    
    if ! confirm_batch "删除全部 $total 个包的仓库源" "$total"; then
        return
    fi
    
    echo "{}" > "$MIRROR_FILE"
    log_success "已删除全部仓库源"
}

# 清理失效的仓库源
cmd_clean() {
    check_jq
    
    log_section "清理失效的仓库源"
    
    if [ ! -f "$MIRROR_FILE" ] || [ ! -s "$MIRROR_FILE" ] || [ "$(jq 'length' "$MIRROR_FILE" 2>/dev/null)" -eq 0 ]; then
        log_warning "没有配置任何仓库源"
        return
    fi
    
    local temp_file="$MIRROR_FILE.tmp.$$"
    cp "$MIRROR_FILE" "$temp_file"
    
    local invalid_count=0
    local invalid_list=""
    
    # 检查每个包的每个源
    jq -r 'keys[]' "$MIRROR_FILE" 2>/dev/null | while read -r pkg; do
        local sources=$(get_repo_sources "$pkg")
        local index=1
        
        while IFS= read -r url; do
            if [ -z "$url" ]; then
                index=$((index + 1))
                continue
            fi
            
            log_cmd "检查 $pkg 源 #$index ..."
            
            local is_valid=false
            if [[ "$url" =~ ^https?:// ]]; then
                if curl --output /dev/null --silent --head --fail --connect-timeout 5 "$url"; then
                    is_valid=true
                fi
            elif [[ "$url" =~ ^file:// ]]; then
                local path="${url#file://}"
                if [ -e "$path" ]; then
                    is_valid=true
                fi
            else
                # 无法验证的格式，视为有效
                is_valid=true
                log_info "$pkg 源 #$index 跳过检查 (无法验证)"
            fi
            
            if [ "$is_valid" = true ]; then
                log_success "$pkg 源 #$index 有效"
            else
                log_warning "$pkg 源 #$index 无效 (无法访问)"
                invalid_count=$((invalid_count + 1))
                invalid_list="${invalid_list}  - $pkg 源 #$index: $url\n"
                # 从临时文件中删除这个源
                remove_repo_source_from_file "$temp_file" "$pkg" "$index"
            fi
            
            index=$((index + 1))
        done <<< "$sources"
    done
    
    if [ $invalid_count -eq 0 ]; then
        log_success "所有仓库源都有效"
        rm -f "$temp_file"
        return
    fi
    
    echo -e "\n${YELLOW}发现 $invalid_count 个失效的仓库源:${NC}"
    echo -e "$invalid_list"
    
    echo -n "是否删除这些失效的仓库源？[y/N] "
    read -r answer
    if [[ "$answer" =~ ^[Yy]$ ]]; then
        mv "$temp_file" "$MIRROR_FILE"
        log_success "已删除 $invalid_count 个失效的仓库源"
    else
        rm -f "$temp_file"
        log_info "操作已取消"
    fi
}

# 从指定文件中删除仓库源（辅助函数）
remove_repo_source_from_file() {
    local file="$1"
    local pkg="$2"
    local index="$3"  # 1-based index
    
    local current=$(jq -c ".\"$pkg\"" "$file" 2>/dev/null)
    [ -z "$current" ] || [ "$current" = "null" ] && return
    
    # 如果是数组
    if echo "$current" | jq -e 'type=="array"' >/dev/null 2>&1; then
        local jq_index=$((index - 1))
        local new_array=$(echo "$current" | jq "del(.[$jq_index])")
        if [ "$(echo "$new_array" | jq 'length')" -eq 0 ]; then
            jq --arg p "$pkg" 'del(.[$p])' "$file" > "$file.new"
        else
            jq --arg p "$pkg" --argjson a "$new_array" '.[$p] = $a' "$file" > "$file.new"
        fi
    else
        # 单个值，直接删除整个包
        jq --arg p "$pkg" 'del(.[$p])' "$file" > "$file.new"
    fi
    
    mv "$file.new" "$file"
}

# ==================== 包管理功能 ====================

cmd_install() {
    [ $# -eq 0 ] && echo -e "${RED}错误：请指定要安装的包${NC}" && echo "用法：dsc install <包...> [选项]" && exit 1
    
    local use_source=""
    local list_sources=false
    local pkgs=()
    
    # 解析参数
    while [ $# -gt 0 ]; do
        case "$1" in
            -use)
                shift
                if [ $# -gt 0 ] && [[ ! "$1" =~ ^- ]]; then
                    use_source="$1"
                    shift
                else
                    log_error "-use 需要指定源索引"
                    return 1
                fi
                ;;
            -list)
                list_sources=true
                shift
                ;;
            -all)
                cmd_install_all
                return
                ;;
            *)
                pkgs+=("$1")
                shift
                ;;
        esac
    done
    
    check_jq
    log_section "正在安装软件包"
    
    for pkg in "${pkgs[@]}"; do
        if [ "$list_sources" = true ]; then
            cmd_list_sources "$pkg"
        else
            cmd_install_single "$pkg" "$use_source"
        fi
    done
}

# 列出包的源
cmd_list_sources() {
    local pkg="$1"
    
    if ! has_repo "$pkg"; then
        log_error "包 '$pkg' 没有配置仓库源"
        return 1
    fi
    
    local count=$(get_repo_count "$pkg")
    echo -e "\n${BOLD}${PURPLE}${ICON_PKG}${NC} ${BOLD}$pkg${NC} 的仓库源 (共 $count 个):"
    list_repo_sources "$pkg"
    echo ""
    
    if is_installed "$pkg"; then
        echo -e "${GREEN}此包已安装${NC}"
    else
        echo -e "使用以下命令安装:"
        echo "  dsc install $pkg         # 使用默认源 (源 #1)"
        echo "  dsc install $pkg -use 2  # 使用源 #2 安装"
    fi
}

cmd_install_single() {
    local pkg="$1"
    local use_source="$2"  # 可选的源索引
    
    log_pkg_header "$pkg" "安装中"
    
    # 获取所有源
    local sources=()
    while IFS= read -r source; do
        [ -n "$source" ] && sources+=("$source")
    done < <(get_repo_sources "$pkg")
    
    if [ ${#sources[@]} -eq 0 ]; then
        log_error "包 '$pkg' 没有配置仓库源，请在 $MIRROR_FILE 中配置"
        return 1
    fi
    
    # 确定要使用的源
    local selected_sources=()
    if [ -n "$use_source" ]; then
        # 用户指定了源索引
        if [[ "$use_source" =~ ^[0-9]+$ ]]; then
            if [ "$use_source" -lt 1 ] || [ "$use_source" -gt ${#sources[@]} ]; then
                log_error "源索引超出范围 (1-${#sources[@]})"
                return 1
            fi
            selected_sources=("${sources[$((use_source-1))]}")
            log_info "使用指定的源 #$use_source: ${selected_sources[0]}"
        else
            # 可能是 URL 部分匹配
            local matched=false
            for i in "${!sources[@]}"; do
                if [[ "${sources[$i]}" == *"$use_source"* ]]; then
                    selected_sources=("${sources[$i]}")
                    log_info "使用匹配的源 #$((i+1)): ${selected_sources[0]}"
                    matched=true
                    break
                fi
            done
            if [ "$matched" = false ]; then
                log_error "未找到匹配的源: $use_source"
                return 1
            fi
        fi
    else
        # 使用所有源，按顺序尝试
        selected_sources=("${sources[@]}")
        log_info "将按顺序尝试 ${#selected_sources[@]} 个源"
    fi
    
    # 尝试安装
    local success=false
    local attempted=0
    
    for repo in "${selected_sources[@]}"; do
        attempted=$((attempted + 1))
        
        if [ ${#selected_sources[@]} -gt 1 ]; then
            log_subsection "尝试源 #$attempted: $repo"
        else
            log_subsection "源地址: $repo"
        fi
        
        cd "$PKG_ROOT"
        
        # 克隆或更新仓库
        if [ -d "$pkg" ]; then
            log_cmd "更新本地源码..."
            cd "$pkg"
            
            # 检查当前远程地址是否匹配
            local current_remote=$(git config --get remote.origin.url 2>/dev/null || echo "")
            if [ "$current_remote" != "$repo" ]; then
                log_warning "远程地址不匹配，将重新克隆"
                cd "$PKG_ROOT"
                rm -rf "$pkg"
                git clone "$repo" "$pkg" > /dev/null 2>&1 &
                show_progress $! "克隆 $pkg (新源)"
                cd "$pkg"
            else
                git pull > /dev/null 2>&1 &
                show_progress $! "更新 $pkg"
            fi
        else
            log_cmd "克隆仓库..."
            git clone "$repo" "$pkg" > /dev/null 2>&1 &
            show_progress $! "克隆 $pkg"
            cd "$pkg"
        fi
        
        # 检查 info.dsc
        if [ ! -f info.dsc ]; then
            log_error "$pkg 没有 info.dsc，无法安装"
            if [ ${#selected_sources[@]} -eq 1 ] || [ $attempted -eq ${#selected_sources[@]} ]; then
                continue
            else
                log_warning "尝试下一个源..."
                cd "$PKG_ROOT"
                rm -rf "$pkg"
                continue
            fi
        fi
        
        # 显示包信息
        version=$(get_info "$pkg" version)
        author=$(get_info "$pkg" author)
        desc=$(get_info "$pkg" description)
        
        echo -e "  ${GRAY}┌─ 包信息 ──────────────────────${NC}"
        [ -n "$version" ] && echo -e "  ${GRAY}│${NC} 版本: $version"
        [ -n "$author" ] && echo -e "  ${GRAY}│${NC} 作者: $author"
        [ -n "$desc" ] && echo -e "  ${GRAY}│${NC} 描述: $desc"
        echo -e "  ${GRAY}└───────────────────────────────${NC}"
        
        # 执行安装脚本
        if [ -f install.sh ]; then
            chmod +x install.sh
            log_cmd "执行安装脚本..."
            if ./install.sh; then
                log_success "安装脚本执行成功"
                success=true
                break
            else
                log_error "安装脚本执行失败"
                if [ ${#selected_sources[@]} -gt 1 ] && [ $attempted -lt ${#selected_sources[@]} ]; then
                    log_warning "尝试下一个源..."
                    cd "$PKG_ROOT"
                    rm -rf "$pkg"
                    continue
                else
                    break
                fi
            fi
        else
            log_error "无 install.sh 安装脚本"
            if [ ${#selected_sources[@]} -gt 1 ] && [ $attempted -lt ${#selected_sources[@]} ]; then
                log_warning "尝试下一个源..."
                cd "$PKG_ROOT"
                rm -rf "$pkg"
                continue
            else
                break
            fi
        fi
    done
    
    if [ "$success" = true ]; then
        # 执行安装后脚本
        if [ -f afterinstall.sh ]; then
            chmod +x afterinstall.sh
            log_cmd "执行安装后脚本..."
            ./afterinstall.sh && log_success "安装后脚本执行成功" || log_warning "安装后脚本执行失败"
        fi
        
        mark_installed "$pkg"
        echo -e "  ${GREEN}${ICON_SUCCESS}${NC} ${GREEN}${BOLD}[$pkg] 安装完成！${NC}"
        return 0
    else
        log_error "所有安装尝试均失败"
        return 1
    fi
}

cmd_install_all() {
    check_jq
    
    log_section "安装所有未安装的软件包"
    
    # 获取所有仓库中的包
    local all_pkgs=$(get_all_repo_pkgs)
    if [ -z "$all_pkgs" ]; then
        log_warning "没有配置任何仓库源"
        return
    fi
    
    # 找出未安装的包
    local to_install=()
    local installed_count=0
    
    while IFS= read -r pkg; do
        if is_installed "$pkg"; then
            installed_count=$((installed_count + 1))
        else
            to_install+=("$pkg")
        fi
    done <<< "$all_pkgs"
    
    local total=${#to_install[@]}
    
    if [ $total -eq 0 ]; then
        log_success "所有包都已安装（共 $installed_count 个）"
        return
    fi
    
    echo -e "发现 ${BOLD}$total${NC} 个未安装的包，${BOLD}$installed_count${NC} 个已安装的包"
    echo -e "\n${BOLD}将安装以下包:${NC}"
    for pkg in "${to_install[@]}"; do
        local count=$(get_repo_count "$pkg")
        echo "  - $pkg ($count 个源)"
    done
    echo ""
    
    if ! confirm_batch "安装全部 $total 个未安装的包" "$total"; then
        return
    fi
    
    local success=0
    local failed=0
    
    for pkg in "${to_install[@]}"; do
        if cmd_install_single "$pkg"; then
            success=$((success + 1))
        else
            failed=$((failed + 1))
        fi
    done
    
    echo -e "\n${GREEN}==>${NC} 批量安装完成: ${GREEN}$success 成功${NC}, ${RED}$failed 失败${NC}"
}

cmd_delete() {
    local all_mode=false
    
    # 检查是否是 -all 参数
    if [ "$1" = "-all" ]; then
        all_mode=true
        shift
    fi
    
    if [ "$all_mode" = true ]; then
        cmd_delete_all
    else
        [ $# -eq 0 ] && echo -e "${RED}错误：请指定要卸载的包${NC}" && echo "用法：dsc delete <包...> 或 dsc delete -all" && exit 1
        check_jq

        log_section "正在卸载软件包"

        for pkg in "$@"; do
            cmd_delete_single "$pkg"
        done
    fi
}

cmd_delete_single() {
    local pkg="$1"
    
    log_pkg_header "$pkg" "卸载中"
    
    if ! is_installed "$pkg"; then
        log_warning "[$pkg] 未安装"
        return 1
    fi

    pkg_dir="$PKG_ROOT/$pkg"
    cd "$pkg_dir" || return 1

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
    echo -e "  ${GREEN}${ICON_SUCCESS}${NC} ${GREEN}${BOLD}[$pkg] 已卸载${NC}"
}

cmd_delete_all() {
    check_jq
    
    log_section "卸载所有已安装的软件包"
    
    local installed_pkgs=$(get_installed_pkgs)
    if [ -z "$installed_pkgs" ]; then
        log_warning "没有已安装的包"
        return
    fi
    
    local total=$(echo "$installed_pkgs" | wc -l)
    
    echo -e "${BOLD}将卸载以下 $total 个已安装的包:${NC}"
    while IFS= read -r pkg; do
        echo "  - $pkg"
    done <<< "$installed_pkgs"
    echo ""
    
    echo -e "${YELLOW}⚠ 注意:${NC} 这将只卸载软件包，不会删除仓库源"
    if ! confirm_batch "卸载全部 $total 个已安装的包" "$total"; then
        return
    fi
    
    local success=0
    local failed=0
    
    while IFS= read -r pkg; do
        if cmd_delete_single "$pkg"; then
            success=$((success + 1))
        else
            failed=$((failed + 1))
        fi
    done <<< "$installed_pkgs"
    
    echo -e "\n${GREEN}==>${NC} 批量卸载完成: ${GREEN}$success 成功${NC}, ${RED}$failed 失败${NC}"
}

cmd_reinstall() {
    local all_mode=false
    
    # 检查是否是 -all 参数
    if [ "$1" = "-all" ]; then
        all_mode=true
        shift
    fi
    
    if [ "$all_mode" = true ]; then
        cmd_reinstall_all
    else
        [ $# -eq 0 ] && echo -e "${RED}错误：请指定要重装的包${NC}" && echo "用法：dsc reinstall <包...> 或 dsc reinstall -all" && exit 1
        
        log_section "重新安装软件包"
        
        for pkg in "$@"; do
            log_pkg_header "$pkg" "重新安装"
            cmd_delete_single "$pkg"
            cmd_install_single "$pkg"
        done
    fi
}

cmd_reinstall_all() {
    check_jq
    
    log_section "重新安装所有已安装的软件包"
    
    local installed_pkgs=$(get_installed_pkgs)
    if [ -z "$installed_pkgs" ]; then
        log_warning "没有已安装的包"
        return
    fi
    
    local total=$(echo "$installed_pkgs" | wc -l)
    
    echo -e "${BOLD}将重新安装以下 $total 个已安装的包:${NC}"
    while IFS= read -r pkg; do
        echo "  - $pkg"
    done <<< "$installed_pkgs"
    echo ""
    
    if ! confirm_batch "重新安装全部 $total 个已安装的包" "$total"; then
        return
    fi
    
    local success=0
    local failed=0
    
    while IFS= read -r pkg; do
        log_pkg_header "$pkg" "重新安装"
        if cmd_delete_single "$pkg" && cmd_install_single "$pkg"; then
            success=$((success + 1))
        else
            failed=$((failed + 1))
        fi
    done <<< "$installed_pkgs"
    
    echo -e "\n${GREEN}==>${NC} 批量重新安装完成: ${GREEN}$success 成功${NC}, ${RED}$failed 失败${NC}"
}

cmd_update() {
    check_jq
    
    log_section "正在更新已安装的软件包"
    
    installed_pkgs=$(get_installed_pkgs)
    [ -z "$installed_pkgs" ] && log_info "没有已安装的包" && return
    
    count=0
    for pkg in $installed_pkgs; do
        # 获取第一个可用的源
        repo=$(get_first_repo "$pkg")
        [ "$repo" = "null" ] && continue
        
        dir="$PKG_ROOT/$pkg"
        [ ! -d "$dir" ] && continue
        
        log_pkg_header "$pkg" "检查更新"
        cd "$dir"
        
        # 如果是 git 仓库
        if [ -d ".git" ]; then
            # 检查当前远程地址是否匹配任一源
            local current_remote=$(git config --get remote.origin.url 2>/dev/null || echo "")
            local use_repo="$repo"
            
            # 如果当前远程不在源列表中，尝试更新
            if ! get_repo_sources "$pkg" | grep -q "$current_remote"; then
                log_warning "当前远程地址不在源列表中"
                # 仍然尝试更新，但如果失败会提示
            fi
            
            # 检查更新
            git remote update > /dev/null 2>&1
            local_commit=$(git rev-parse HEAD)
            remote_commit=$(git rev-parse @{u} 2>/dev/null || echo "")
            
            if [ "$local_commit" != "$remote_commit" ] && [ -n "$remote_commit" ]; then
                log_cmd "发现更新，正在拉取..."
                git pull > /dev/null 2>&1 &
                show_progress $! "更新 $pkg"
                count=$((count + 1))
            else
                log_success "已是最新"
            fi
        else
            log_warning "不是 git 仓库，无法更新"
        fi
    done
    
    echo -e "\n${GREEN}==>${NC} 更新完成，共更新 $count 个包"
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
    
    echo -e "${BOLD}仓库中找到以下匹配的包:${NC}\n"
    while IFS= read -r pkg; do
        local count=$(get_repo_count "$pkg")
        if is_installed "$pkg"; then
            echo -e "  ${PURPLE}${ICON_PKG}${NC} ${BOLD}$pkg${NC} ${GREEN}[已安装]${NC} ${GRAY}($count 个源)${NC}"
        else
            echo -e "  ${PURPLE}${ICON_PKG}${NC} ${BOLD}$pkg${NC} ${GRAY}[未安装]${NC} ${GRAY}($count 个源)${NC}"
        fi
    done <<< "$results"
}

cmd_info() {
    [ $# -ne 1 ] && echo -e "${RED}错误：请指定包名${NC}" && echo "用法：dsc info <包>" && exit 1
    check_jq
    
    local pkg="$1"
    
    log_section "包信息: $pkg"
    
    if ! has_repo "$pkg"; then
        log_error "无此包"
        return
    fi
    
    local count=$(get_repo_count "$pkg")
    echo -e "${BOLD}仓库信息:${NC}"
    echo -e "  源数量: ${CYAN}$count${NC}"
    echo -e "  源列表:"
    list_repo_sources "$pkg" | sed 's/^/    /'
    
    if is_installed "$pkg"; then
        echo -e "  状态:   ${GREEN}已安装${NC}"
        
        # 从 info.dsc 读取详细信息
        if [ -f "$PKG_ROOT/$pkg/info.dsc" ]; then
            echo -e "\n${BOLD}包详细信息:${NC}"
            while IFS= read -r line; do
                if [[ "$line" =~ ^[a-zA-Z]+= ]]; then
                    key=$(echo "$line" | cut -d= -f1)
                    value=$(echo "$line" | cut -d= -f2-)
                    printf "  ${CYAN}%-10s${NC} %s\n" "$key:" "$value"
                fi
            done < "$PKG_ROOT/$pkg/info.dsc"
        fi
    else
        echo -e "  状态:   ${YELLOW}未安装${NC}"
        echo -e "\n${YELLOW}提示:${NC} 使用 '${GREEN}dsc install $pkg${NC}' 安装此包"
        echo -e "       使用 '${GREEN}dsc install $pkg -list${NC}' 查看所有源"
        echo -e "       使用 '${GREEN}dsc install $pkg -use 2${NC}' 使用指定源安装"
    fi
}

# ==================== 主入口 ====================

case "$1" in
    install) shift; cmd_install "$@" ;;
    delete|remove) shift; cmd_delete "$@" ;;
    reinstall) shift; cmd_reinstall "$@" ;;
    update) cmd_update ;;
    search) shift; cmd_search "$@" ;;
    info) shift; cmd_info "$@" ;;
    addrepo) shift; cmd_addrepo "$@" ;;
    listrepo) cmd_listrepo ;;
    rmrepo) 
        shift
        if [ "$1" = "-all" ]; then
            cmd_rmrepo_all
        else
            cmd_rmrepo "$@"
        fi
        ;;
    clean) cmd_clean ;;
    *)
        echo -e "${BOLD}${CYAN}   ___    ____   ____   ${NC}"
        echo -e "${BOLD}${CYAN}  |    \ / ___| / ___|  ${NC}${BOLD}DSC 包管理器 v1.0${NC}"
        echo -e "${BOLD}${CYAN}  | |\ | | |__  | |      ${NC}${GRAY}作者：YuFeng0v0${NC}"
        echo -e "${BOLD}${CYAN}  | |/ | |___ | | |__   ${NC}"
        echo -e "${BOLD}${CYAN}  |____/ \____| \____|  ${NC}"
        echo -e "\n${BOLD}用法:${NC}"
        echo -e "  ${GREEN}dsc install <包...>${NC}               安装软件包（自动选择第一个源）"
        echo -e "  ${GREEN}dsc install <包> -list${NC}            列出包的所有源"
        echo -e "  ${GREEN}dsc install <包> -use <索引/URL>${NC}  使用指定源安装"
        echo -e "  ${GREEN}dsc install -all${NC}                  安装所有未安装的包"
        echo -e "  ${RED}dsc delete <包...>${NC}                卸载软件包"
        echo -e "  ${RED}dsc delete -all${NC}                   卸载所有已安装的包"
        echo -e "  ${YELLOW}dsc reinstall <包...>${NC}             重新安装软件包"
        echo -e "  ${YELLOW}dsc reinstall -all${NC}                重新安装所有已安装的包"
        echo -e "  ${BLUE}dsc update${NC}                        更新所有软件包"
        echo -e "  ${CYAN}dsc search <关键词>${NC}               搜索软件包"
        echo -e "  ${PURPLE}dsc info <包>${NC}                     显示包信息"
        echo -e "  ${GREEN}dsc addrepo <URL> [-for <包名>]${NC}   添加仓库源"
        echo -e "  ${BLUE}dsc listrepo${NC}                      列出所有仓库源"
        echo -e "  ${RED}dsc rmrepo <包名> [索引]${NC}          删除指定仓库源"
        echo -e "  ${RED}dsc rmrepo -all${NC}                   删除所有仓库源"
        echo -e "  ${YELLOW}dsc clean${NC}                         清理失效的仓库源"
        
        echo -e "\n${BOLD}示例:${NC}"
        echo -e "  ${GREEN}dsc addrepo https://github.com/user/repo.git -for example${NC}  添加源 "
        echo -e "  ${GREEN}dsc addrepo https://mirror.com/repo.git -for example${NC}       添加第二个源"
        echo -e "  ${GREEN}dsc install example -list${NC}                                  列出所有源"
        echo -e "  ${GREEN}dsc install example -use 2${NC}                                 使用第二个源安装"
        echo -e "  ${GREEN}dsc install -all${NC}                                           安装所有未安装的包"
        echo -e "  ${RED}dsc rmrepo example 1${NC}                                       删除 example 的第一个源"
        
        echo -e "\n${BOLD}配置文件:${NC}"
        echo -e "  ${GRAY}$MIRROR_FILE${NC}"
        echo -e "  ${GRAY}$INSTALLED_FILE${NC}"
        echo -e "  ${GRAY}$PKG_ROOT${NC}"
        ;;
esac