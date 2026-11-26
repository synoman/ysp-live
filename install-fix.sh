#!/bin/sh
# ysp-live 一键安装与管理脚本（fork 自 synoman/ysp-live + 旧版 docker-compose 兼容修订版）
#
# 说明：
#   源码从你自己 fork 的仓库下载（默认 synoman/ysp-live），不再指向原作者 tmxk2020。
#   可用环境变量 REPO_OWNER 临时改归属者，例如 REPO_OWNER=someone sh xxx.sh 1
#
# 相比原仓库 install.sh 的改动：
#   1) 源码地址指向 REPO_OWNER（默认 synoman），不再写死原作者。
#   2) 新增 normalize_compose_file()：每次构建前自动检查项目 docker-compose.yml 的顶层
#      version 声明。缺失则按本机 Docker Engine 与 docker-compose 实际版本自动补写；
#      已有但过高的自动下调。彻底解决旧版 docker-compose 因缺少 version 声明而报
#      "Unsupported config option for services: 'ysp-live'" 的问题。
#   3) 明确区分 docker compose v2 与 docker-compose v1：v2 无需 version 字段，不改动；
#      v1 必须补，补完再构建。
#   4) 支持命令行直接传选项，如 sh install-ysp-live.sh 1 表示直接执行安装，免交互菜单。
#   5) 源码下载失败时可用环境变量 GH_PREFIX 走加速前缀重试。
#   6) 构建失败时补充内存/磁盘排查提示（N1 等 2G 内存设备常见构建被杀）。
#
# 用法（在设备上，root 身份）：
#   放入 /root 后执行：sh /root/install-ysp-live.sh          进入交互菜单
#   或直接安装：        sh /root/install-ysp-live.sh 1
#   GitHub 直连慢时：   GH_PREFIX=https://gh-proxy.com/ sh /root/install-ysp-live.sh 1

REPO_OWNER="${REPO_OWNER:-synoman}"
REPO_BRANCH="${REPO_BRANCH:-main}"

CONTAINER_NAME="ysp-live"
ROOT_DIR="/root/ysp-live"
PROJECT_DIR="$ROOT_DIR/ysp-live-${REPO_BRANCH}"
DATA_DIR="$PROJECT_DIR/data"
PORT="8767"
REPO_ZIP="https://codeload.github.com/${REPO_OWNER}/ysp-live/zip/refs/heads/${REPO_BRANCH}"
SOURCE_DIR_NAME="ysp-live-${REPO_BRANCH}"
GH_PREFIX="${GH_PREFIX:-}"

COMPOSE=""
COMPOSE_KIND=""

say() { printf '%s\n' "$*"; }
line() { say '============================================================'; }

get_local_ip() {
    ip_addr=""
    if command -v uci >/dev/null 2>&1; then
        ip_addr=$(uci get network.lan.ipaddr 2>/dev/null)
    fi
    if [ -z "$ip_addr" ] && command -v hostname >/dev/null 2>&1; then
        ip_addr=$(hostname -I 2>/dev/null | awk '{print $1}')
    fi
    [ -n "$ip_addr" ] || ip_addr="127.0.0.1"
    printf '%s' "$ip_addr"
}

show_links() {
    ip_addr=$(get_local_ip)
    line
    say "ysp-live 服务地址（源码来自 fork：${REPO_OWNER}/ysp-live）"
    printf '  播放列表： http://%s:%s/all.m3u\n' "$ip_addr" "$PORT"
    printf '  健康检查： http://%s:%s/health\n' "$ip_addr" "$PORT"
    printf '  诊断页面： http://%s:%s/diag\n' "$ip_addr" "$PORT"
    line
}

docker_compose_cmd() {
    if docker compose version >/dev/null 2>&1; then
        COMPOSE="docker compose"
        COMPOSE_KIND="v2"
    elif command -v docker-compose >/dev/null 2>&1; then
        COMPOSE="docker-compose"
        COMPOSE_KIND="v1"
    else
        say "错误：未找到 Docker Compose，请先安装 Docker Compose。"
        return 1
    fi
    say "使用构建命令：$COMPOSE（格式 $COMPOSE_KIND）"
    return 0
}

# 按 Docker Engine 版本与 docker-compose v1 版本，算出双方都支持的最高 compose file 格式
compose_max_format() {
    ev=$(docker version --format '{{.Server.Version}}' 2>/dev/null | tr -d '\r')
    cv=""
    if [ "$COMPOSE_KIND" = "v1" ]; then
        cv=$(docker-compose version --short 2>/dev/null | tr -d '\r')
    fi
    awk -v ev="$ev" -v cv="$cv" 'BEGIN{
        m = 3.6;
        if (ev != "") {
            split(ev, a, ".");
            e = (a[1] + 0) * 100 + (a[2] + 0);
            if (e >= 2010) m = 3.9;
            else if (e >= 1903) m = 3.8;
            else if (e >= 1806) m = 3.7;
            else if (e >= 1802) m = 3.6;
            else if (e >= 1712) m = 3.5;
            else if (e >= 1709) m = 3.4;
            else if (e >= 1706) m = 3.3;
            else m = 3.2;
        }
        if (cv != "") {
            split(cv, b, ".");
            if ((b[1] + 0) == 1) {
                c = 1 * 100 + (b[2] + 0);
                if (c >= 127) cm = 3.8;
                else if (c >= 125) cm = 3.7;
                else if (c >= 123) cm = 3.7;
                else if (c >= 121) cm = 3.6;
                else if (c >= 118) cm = 3.5;
                else cm = 3.3;
                if (cm < m) m = cm;
            }
        }
        printf "%.1f", m;
    }'
}

# 核心修复：让 docker-compose.yml 的 version 字段与本机 Docker/Compose 匹配
normalize_compose_file() {
    yml="$1"
    [ -f "$yml" ] || { say "错误：未找到 $yml"; return 1; }
    if [ "$COMPOSE_KIND" != "v1" ]; then
        return 0
    fi
    want=$(compose_max_format)
    [ -n "$want" ] || want="3.6"
    cur=$(grep -m1 -E '^version:' "$yml" 2>/dev/null | cut -d: -f2- | tr -d " \t\"'")
    if [ -n "$cur" ]; then
        final=$(awk -v c="$cur" -v w="$want" 'BEGIN{
            cc = c + 0; ww = w + 0;
            if (cc <= 0 || cc > ww) printf "%.1f", ww; else printf "%.1f", cc
        }')
        if [ "$final" = "$cur" ]; then
            say "  兼容检查：docker-compose.yml 的 version \"$cur\" 与本机兼容，无需改动。"
            return 0
        fi
        say "  兼容处理：version \"$cur\" 超出本机支持上限，下调为 \"$final\"。"
        want="$final"
        tmp="$yml.fixtmp"
        awk -v v="$want" 'done == 0 && $0 ~ /^version:/ { print "version: \"" v "\""; done = 1; next } { print }' "$yml" > "$tmp" || { rm -f "$tmp"; return 1; }
    else
        say "  兼容处理：为 docker-compose.yml 补充 version: \"$want\"（旧版 docker-compose 必需）。"
        tmp="$yml.fixtmp"
        awk -v v="$want" 'BEGIN { print "version: \"" v "\"" } { print }' "$yml" > "$tmp" || { rm -f "$tmp"; return 1; }
    fi
    [ -s "$tmp" ] || { rm -f "$tmp"; say "错误：写入 version 字段失败。"; return 1; }
    mv "$tmp" "$yml" || { rm -f "$tmp"; return 1; }
    return 0
}

download_zip() {
    dest="$1"
    url="$2"
    if command -v curl >/dev/null 2>&1; then
        curl -fL --connect-timeout 20 --retry 2 "$url" -o "$dest" && return 0
    fi
    if command -v wget >/dev/null 2>&1; then
        wget -O "$dest" "$url" && return 0
    fi
    say "错误：系统需要安装 curl 或 wget。"
    return 1
}

fetch_source() {
    TMP_DIR="$ROOT_DIR/.update-tmp"
    ZIP_FILE="$ROOT_DIR/ysp-live-latest.zip"
    rm -rf "$TMP_DIR"
    mkdir -p "$TMP_DIR" || return 1
    say "[1/4] 正在从 GitHub 下载最新项目文件（来源：${REPO_OWNER}/ysp-live）..."
    command -v unzip >/dev/null 2>&1 || { say "错误：系统需要安装 unzip。"; return 1; }
    if ! download_zip "$ZIP_FILE" "$REPO_ZIP"; then
        if [ -n "$GH_PREFIX" ]; then
            say "      直连失败，改用加速前缀重试..."
            download_zip "$ZIP_FILE" "${GH_PREFIX}${REPO_ZIP}" || return 1
        else
            say "      直连 GitHub 失败。可加镜像前缀重试，例如："
            say "      GH_PREFIX=https://gh-proxy.com/ sh $0 1"
            return 1
        fi
    fi
    unzip -q "$ZIP_FILE" -d "$TMP_DIR" || return 1
    # 兼容解压后目录名与预期不一致的情况：自动定位含 Dockerfile 的项目目录
    if [ -d "$TMP_DIR/$SOURCE_DIR_NAME" ]; then
        SOURCE_DIR="$TMP_DIR/$SOURCE_DIR_NAME"
    else
        SOURCE_DIR=$(find "$TMP_DIR" -maxdepth 2 -name Dockerfile -printf '%h\n' 2>/dev/null | head -n1)
    fi
    [ -n "$SOURCE_DIR" ] && [ -f "$SOURCE_DIR/Dockerfile" ] || { say "错误：下载的项目中缺少 Dockerfile。"; return 1; }
    [ -f "$SOURCE_DIR/docker-compose.yml" ] || { say "错误：下载的项目中缺少 docker-compose.yml。"; return 1; }
    return 0
}

mem_hint() {
    free -m 2>/dev/null | awk 'NR<=2 {print "      " $0}'
    say "      若上面可用内存不足 300MB，建议先加 swap/zram 再重试构建。"
}

do_install() {
    command -v docker >/dev/null 2>&1 || { say "错误：未检测到 Docker，请先安装 Docker。"; return 1; }
    docker_compose_cmd || return 1
    mkdir -p "$ROOT_DIR" || return 1
    fetch_source || { say "错误：项目下载或解压失败，原有安装未作任何更改。"; return 1; }

    # 用户数据独立备份，更新完成后再恢复。
    OLD_PROJECT="$ROOT_DIR/project-old-$(date +%Y%m%d%H%M%S)"
    if [ -d "$DATA_DIR" ]; then
        mkdir -p "$ROOT_DIR/data-backup"
        cp -a "$DATA_DIR/." "$ROOT_DIR/data-backup/" 2>/dev/null
    fi
    if [ -d "$PROJECT_DIR" ]; then
        mv "$PROJECT_DIR" "$OLD_PROJECT" || return 1
    fi
    mv "$SOURCE_DIR" "$PROJECT_DIR" || {
        [ -d "$OLD_PROJECT" ] && mv "$OLD_PROJECT" "$PROJECT_DIR"
        return 1
    }
    if [ -d "$ROOT_DIR/data-backup" ] && [ ! -d "$PROJECT_DIR/data" ]; then
        mkdir -p "$PROJECT_DIR/data"
        cp -a "$ROOT_DIR/data-backup/." "$PROJECT_DIR/data/" 2>/dev/null
    fi
    mkdir -p "$PROJECT_DIR/data"

    normalize_compose_file "$PROJECT_DIR/docker-compose.yml" || {
        say "错误：compose 文件兼容性处理失败，原有安装未作任何更改。"
        rm -rf "$PROJECT_DIR"
        [ -d "$OLD_PROJECT" ] && mv "$OLD_PROJECT" "$PROJECT_DIR"
        return 1
    }
    cd "$PROJECT_DIR" || return 1

    say "[2/4] 正在构建新版镜像，当前服务暂时保持运行..."
    $COMPOSE build
    result=$?
    if [ "$result" -ne 0 ]; then
        say "错误：镜像构建失败，当前运行中的容器未停止。"
        mem_hint
        rm -rf "$PROJECT_DIR"
        [ -d "$OLD_PROJECT" ] && mv "$OLD_PROJECT" "$PROJECT_DIR"
        return 1
    fi
    say "[3/4] 正在使用新版本重启服务..."
    docker rm -f "$CONTAINER_NAME" >/dev/null 2>&1 || true
    $COMPOSE up -d --remove-orphans
    result=$?
    if [ "$result" -ne 0 ]; then
        say "错误：新版容器启动失败，正在恢复上一版本..."
        mem_hint
        FAILED_PROJECT="$ROOT_DIR/project-failed-$(date +%Y%m%d%H%M%S)"
        mv "$PROJECT_DIR" "$FAILED_PROJECT" 2>/dev/null
        [ -d "$OLD_PROJECT" ] && mv "$OLD_PROJECT" "$PROJECT_DIR"
        if [ -d "$PROJECT_DIR" ]; then
            cd "$PROJECT_DIR" && $COMPOSE up -d --build
        fi
        return 1
    fi
    say "[4/4] 正在等待服务启动..."
    sleep 3
    if command -v curl >/dev/null 2>&1; then
        curl -fsS "http://127.0.0.1:$PORT/health" >/dev/null 2>&1
        health=$?
    else
        wget -qO- "http://127.0.0.1:$PORT/health" >/dev/null 2>&1
        health=$?
    fi
    if [ "$health" -eq 0 ]; then
        say "部署完成：健康检查接口响应正常。"
    else
        say "容器已启动，但健康检查接口暂未响应，请查看运行日志。"
    fi
    show_links
}

show_logs() {
    docker logs --tail 200 -f "$CONTAINER_NAME"
}

health_check() {
    if command -v curl >/dev/null 2>&1; then
        curl -sS "http://127.0.0.1:$PORT/health"
    else
        wget -qO- "http://127.0.0.1:$PORT/health"
    fi
    say ""
}

do_uninstall() {
    say "此操作将删除 ysp-live 容器和项目文件。"
    say "默认保留用户数据；如需彻底删除，请选择“彻底卸载”。"
    printf '确认继续吗？[y/N]：'
    read answer
    case "$answer" in y|Y|yes|YES) ;; *) say "已取消操作。"; return 0 ;; esac
    docker rm -f "$CONTAINER_NAME" >/dev/null 2>&1 || true
    if [ -d "$DATA_DIR" ]; then
        mkdir -p "$ROOT_DIR/data-backup"
        cp -a "$DATA_DIR/." "$ROOT_DIR/data-backup/" 2>/dev/null
    fi
    if [ -d "$PROJECT_DIR" ]; then
        cd / 2>/dev/null
        rm -rf "$PROJECT_DIR"
    fi
    say "容器和项目文件已删除，备份数据保存在：$ROOT_DIR/data-backup"
}

do_purge() {
    say "警告：此操作将永久删除容器、镜像、项目文件及所有保存的数据，且无法恢复！"
    printf '请输入 DELETE 确认彻底删除：'
    read answer
    [ "$answer" = "DELETE" ] || { say "已取消操作。"; return 0; }
    docker rm -f "$CONTAINER_NAME" >/dev/null 2>&1 || true
    docker image ls --format '{{.Repository}}:{{.Tag}}' 2>/dev/null | grep '^ysp-live:' | while read img; do
        docker image rm "$img" >/dev/null 2>&1 || true
    done
    cd / 2>/dev/null
    rm -rf "$ROOT_DIR"
    say "彻底卸载完成。"
}

do_choice() {
    case "$1" in
        1) do_install ;;
        2) show_links ;;
        3) show_logs ;;
        4) health_check ;;
        5) do_uninstall ;;
        6) do_purge ;;
        0) say "已退出。"; return 0 ;;
        *) say "无效选项，请输入 0-6。" ;;
    esac
}

menu() {
    while :; do
        line
        say "ysp-live 安装与管理工具（fork 自 ${REPO_OWNER}/ysp-live，兼容旧版 compose 修订版）"
        line
        say "1) 安装或更新到 fork 仓库最新版本"
        say "2) 查看服务访问地址"
        say "3) 查看容器实时日志"
        say "4) 检查服务运行状态"
        say "5) 卸载程序（保留用户数据）"
        say "6) 彻底卸载（同时删除所有用户数据）"
        say "0) 退出"
        line
        printf '请输入选项 [0-6]：'
        read choice
        do_choice "$choice"
        [ "$choice" = "0" ] && return 0
    done
}

if [ "${YSP_LIB_ONLY:-0}" = "1" ]; then
    return 0 2>/dev/null || exit 0
fi

if [ "$(id -u 2>/dev/null)" != "0" ]; then
    say "错误：请使用 root 用户运行此脚本。"
    exit 1
fi

if [ "$#" -gt 0 ]; then
    do_choice "$1"
    exit $?
fi

menu
