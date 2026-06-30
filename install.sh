#!/bin/bash
# Copyright 2024 Mengning Software All rights reserved.

# 默认值
CONTAINER_NAME="DevStar-Studio-$(date +%Y%m%d-%H-%M-%S)"
IMAGE_TAG=latest
PORT=80         # 设置端口默认值为 80
SSH_PORT=2222     # 设置ssh默认端口号2222
DATA_DIR="$HOME/.devstar/data"  # 设置数据卷默认路径
CONTAINER_FILE="$HOME/.devstar/container_name"

usage() {
    echo " "
    echo "╔══════════════════════════════════════════════════════════════════════════════════╗"
    echo "║                   DevStar Studio  © Mengning Software 2026                       ║"
    echo "╚══════════════════════════════════════════════════════════════════════════════════╝"
    echo " "
    cat <<EOF
DevStar Studio

Usage: devstar [options]

Options:
    help, -h, --help,       Display this help message
    start                   Start DevStar Studio (default verson is latest)
        --version=<arg>     Specify the DevStar Studio Image Version (default verson is latest)
        --image=<arg>       Specify the DevStar Studio Image example: devstar-studio:latest
        --port=<arg>        Specify the port number (default port is 8080)
        --ssh-port=<arg>    Specify the ssh-port number (default ssh-port is 2222)
        --data-dir=<arg>    Specify the data directory (default data dir is '~/.devstar/data')
    stop                    Stop the running DevStar Studio
    logs                    View the logs of the devstar-studio container
    clean                   Clean up the running DevStar Studio, including deleting user data. Please use with caution.

Examples:
    devstar start --version=v2.0
    devstar stop
    devstar logs
    devstar clean
EOF
}

# 错误处理函数
error_handler() {
    devstar help
    exit 1
}

# 捕获错误信号
trap 'error_handler' ERR

# Exit immediately if a command exits with a non-zero status
set -e

# Colors for output
GREEN='\033[0;32m'
RED='\033[0;31m'
NC='\033[0m' # No Color

# Function to display success message
success() {
  echo -e "${GREEN}$1${NC}"
}

# Function to display failure message
failure()  {
  echo -e "${RED}$1${NC}"
}

DOCKER_CMD="sudo docker"
# OS Detection
if [ "$(uname -s)" = "Darwin" ]; then
  OS_ID="darwin"
  OS_VERSION="$(sw_vers -productVersion 2>/dev/null || uname -r)"
  DOCKER_CMD="docker"
elif [ -f /etc/os-release ]; then
  . /etc/os-release
  OS_ID="$ID"
  OS_VERSION="$VERSION_ID"
elif [ -f /etc/alpine-release ]; then
  OS_ID="alpine"
  OS_VERSION="$(cat /etc/alpine-release)"
else
  OS_ID="$(uname -s | tr '[:upper:]' '[:lower:]')"
  OS_VERSION="$(uname -r)"
fi
echo "[INFO] OS: $OS_ID $OS_VERSION"

# 构建 Docker 配置 JSON
get_docker_config() {
    local registry="$1"
    cat <<EOF
{
  "registry-mirrors": [
    "https://docker.m.daocloud.io",
    "https://docker.mirrors.ustc.edu.cn",
    "https://hub-mirror.c.163.com"
  ],
  "insecure-registries": ["$registry"]
}
EOF
}
# Function to set insecure registry
set_insecure_registry() {
  # ci环境下跳过在job容器中的无效设置
  if [[ "${CI}" == "true" ]] || [[ "${GITEA_ACTIONS}" == "true" ]]; then
      echo "检测到CI环境,跳过Docker Demon配置"
      return 0
  fi
  local HOST="${1}"
  local PORT="${2}"
  local registry="$HOST:$PORT"

  # 选择配置文件
  local config_file="/etc/docker/daemon.json"
  # 判断是否使用 Docker Desktop
  local use_docker_desktop=false
  if docker info 2>/dev/null | grep -q "Operating System:.*Docker Desktop"; then
    config_file="$HOME/.docker/daemon.json"
    use_docker_desktop=true
  fi

  # 检查 registry 是否已配置
  if [[ -f "$config_file" ]] && grep -q "\"$registry\"" "$config_file" 2>/dev/null; then
    return 0
  fi

  # 检查配置文件目录是否存在
  local config_dir=$(dirname "$config_file")
  if [[ ! -d "$config_dir" ]]; then
    echo "配置目录 $config_dir 不存在（可能在CI容器中），跳过配置"
    return 0
  fi

  # 情况1：配置文件不存在或为空 → 自动创建
  if [[ ! -f "$config_file" ]] || [[ ! -s "$config_file" ]]; then
    echo "配置文件 $config_file 不存在，正在自动配置 insecure-registry: $registry"
    if [ "$use_docker_desktop" = true ]; then
        get_docker_config "$registry" > "$config_file"
        echo "========================================"
        echo "⚠️  需要手动重启 Docker Desktop 使配置生效"
        echo "========================================"
    else
        get_docker_config "$registry" | sudo tee "$config_file" > /dev/null
        if sudo systemctl restart docker 2>/dev/null; then
            echo "✅ Docker 服务已重启"
        else
            echo "⚠️  请手动重启 Docker 服务"
        fi
    fi
    return 0
  fi

  # 情况2：配置文件已存在且有内容 → 提示用户手动配置
  local is_zh=true
  if [[ "${LANG}" != zh* ]]; then
    is_zh=false
  fi

  echo ""
  echo "========================================"
  echo ""
  if $is_zh; then
    echo "提示: DevStar 内置容器镜像仓库默认要求 HTTPS 安全认证。"
    echo "如果您未使用 HTTPS，请手动配置 Docker 跳过安全认证检查，配置方法如下："
    echo ""
    echo "  1. 编辑 Docker 配置文件: $config_file"
    echo "  2. 添加或修改以下内容:"
    echo ""
    echo '     "insecure-registries": ["'"$registry"'"]'
    echo ""
    if [ "$use_docker_desktop" = true ]; then
      echo "  3. 保存文件并重启 Docker Desktop"
    else
      echo "  3. 保存文件并重启 Docker 服务:"
      echo "     sudo systemctl restart docker"
    fi
    echo ""
    failure "  安全警告: 跳过安全认证存在安全风险，请仅在可信内网环境或开发测试环境中使用。"
  else
    echo "Notice: The DevStar built-in container image registry requires HTTPS by default."
    echo "If you are not using HTTPS, please manually configure Docker to skip security verification:"
    echo ""
    echo "  1. Edit the Docker configuration file: $config_file"
    echo "  2. Add or modify the following entry:"
    echo ""
    echo '     "insecure-registries": ["'"$registry"'"]'
    echo ""
    if [ "$use_docker_desktop" = true ]; then
      echo "  3. Save the file and restart Docker Desktop"
    else
      echo "  3. Save the file and restart the Docker service:"
      echo "     sudo systemctl restart docker"
    fi
    echo ""
    failure "  WARNNING: Skipping security verification may introduce security risks."
    failure "  Only use in trusted internal networks or development/test environments."
  fi
  echo ""
  echo "========================================"
  echo ""
}

# Package Manager Helpers
Install_Package() {
    PKG="$1"
    case "$OS_ID" in
        darwin)
            if command -v brew >/dev/null 2>&1; then
                brew install "$PKG"
            else
                failure "[WARN] Homebrew not found. Please install $PKG manually."
            fi
            ;;
        ubuntu|debian)
            sudo apt-get update -y
            DEBIAN_FRONTEND=noninteractive sudo apt-get install -y "$PKG"
            ;;
        alpine)
            sudo apk add --no-cache "$PKG"
            ;;
        centos|rhel|fedora|openEuler|openeuler)
            sudo dnf install -y "$PKG" || sudo yum install -y "$PKG"
            ;;
        *)
            failure "[WARN] Unknown OS, cannot install $PKG"
            ;;
    esac
}

Ensure_Command() {
    CMD="$1"
    PKG="$2"

    if ! command -v "$CMD" >/dev/null 2>&1; then
        echo "[INFO] Installing $PKG for command: $CMD"
        if [ "$(id -u 2>/dev/null)" -eq 0 ] || sudo -nv >/dev/null 2>&1; then
            Install_Package "$PKG"
        else
            failure "Permission Denied to Install Package $PKG"
        fi
    fi
}
# 检测URL是否可达
is_url_reachable() {
    local url="$1"
    local http_code
    http_code=$(curl --connect-timeout 3 --max-time 5 -s -o /dev/null -w "%{http_code}" "$url" 2>/dev/null)
    [[ "$http_code" =~ ^(2|3|4)[0-9][0-9]$ ]]
}

# 官方 Docker 安装（300s 超时）
install_docker_official() {
    echo "Installing Docker via official script (timeout: 30s)..."
    timeout --foreground 300 bash -c "curl -fsSL https://get.docker.com | sudo sh" || true
}

# Aliyun 镜像安装 Docker —— Ubuntu/Debian（500s 超时）
install_docker_aliyun_apt() {
      echo "Installing Docker via Aliyun mirror for Debian/Ubuntu..."
      timeout --foreground 500 bash -c "
          set -e
          . /etc/os-release
          case \"\$ID\" in
              ubuntu) DOCKER_OS='ubuntu' ;;
              debian) DOCKER_OS='debian' ;;
              *) echo \"Unsupported OS: \$ID\"; exit 1 ;;
          esac

          sudo mkdir -p /etc/apt/keyrings
          curl -fsSL \"https://mirrors.aliyun.com/docker-ce/linux/\${DOCKER_OS}/gpg\" \
              | sudo gpg --dearmor --yes -o /etc/apt/keyrings/docker.gpg
          echo \"deb [arch=\$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
              https://mirrors.aliyun.com/docker-ce/linux/\${DOCKER_OS} \
              \$VERSION_CODENAME stable\" \
              | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
          sudo apt-get update -y
          DEBIAN_FRONTEND=noninteractive sudo apt-get install -y \
              docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
      " || true
  }

# Aliyun 镜像安装 Docker —— CentOS/RHEL/Fedora（500s 超时）
install_docker_aliyun_dnf() {
      echo "Installing Docker via Aliyun mirror for RHEL/Fedora/CentOS..."

      local os_ver="" ver_major="" docker_repo="centos"
      if [ -f /etc/os-release ]; then
          . /etc/os-release
          os_ver="$VERSION_ID"
      fi
      ver_major="${os_ver%%.*}"

      # 根据发行版选择正确的 Docker repo
      case "${ID,,}" in
          centos)   docker_repo="centos" ;;
          rhel)     docker_repo="rhel"   ;;
          fedora)   docker_repo="fedora" ;;
          *)        docker_repo="centos" ;;  # fallback
      esac

      timeout --foreground 500 bash -c "
          set -e

          if [ \"$ver_major\" -ge 8 ] 2>/dev/null; then
              sudo dnf install -y dnf-plugins-core 2>/dev/null
          else
              sudo yum install -y yum-utils 2>/dev/null
          fi

          sudo dnf config-manager --add-repo \
              https://mirrors.aliyun.com/docker-ce/linux/$docker_repo/docker-ce.repo 2>/dev/null \
              || sudo yum-config-manager --add-repo \
              https://mirrors.aliyun.com/docker-ce/linux/$docker_repo/docker-ce.repo 2>/dev/null

          if [ \"$docker_repo\" != \"fedora\" ] && [ \"$ver_major\" -ge 8 ] 2>/dev/null; then
              sudo sed -i \"s/\\\$releasever/$ver_major/g\" /etc/yum.repos.d/docker-ce.repo 2>/dev/null || true
          fi

          sudo dnf install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin 2>/dev/null \
              || sudo yum install -y docker-ce docker-ce-cli containerd.io 2>/dev/null \
              || true
      " || true
  }

# Aliyun 镜像安装 Docker —— Alpine（500s 超时）
install_docker_alpine() {
    echo "Installing Docker for Alpine (timeout: 30s)..."
    timeout --foreground 500 bash -c "
        set -e
        sudo sed -i 's/dl-cdn.alpinelinux.org/mirrors.aliyun.com/g' /etc/apk/repositories 2>/dev/null || true
        sudo apk add --no-cache docker docker-cli containerd
    " || true
}

# Detect the OS type and install dependencies
function install_dependencies {
  echo "install_dependencies for DevStar Studio ... "
  case "$OS_ID" in
      darwin)
        # macOS: Docker Desktop includes docker, no ip command needed
        if ! command -v docker >/dev/null 2>&1; then
          Ensure_Command docker docker
        fi
        # 检查 Docker daemon，如果未运行则尝试启动 Colima
        if ! docker info >/dev/null 2>&1; then
          Ensure_Command colima colima
          brew install qemu  || true
          colima start  || true
          if ! docker info >/dev/null 2>&1; then
              failure "'brew install qemu colima && colima start' DO NOT Working!"
              failure "Docker Desktop is required on macOS. Please install from https://www.docker.com/products/docker-desktop/"
              exit 1
          fi
        fi
        ;;
      ubuntu|debian|centos|rhel|fedora|alpine)
        Ensure_Command ip iproute2
        if ! command -v docker >/dev/null 2>&1; then

            # 检测网络环境：测试 Aliyun 镜像站是否可达
            if is_url_reachable "https://mirrors.aliyun.com"; then
                echo "Domestic network detected, using Aliyun mirror..."
                case "$OS_ID" in
                    ubuntu|debian)
                        install_docker_aliyun_apt
                        ;;
                    centos|rhel|fedora)
                        install_docker_aliyun_dnf
                        ;;
                    alpine)
                        install_docker_alpine
                        ;;
                esac
            else
                echo "International network detected, using official install..."
                install_docker_official
            fi

            # 最终校验
            if ! command -v docker >/dev/null 2>&1; then
                failure "Docker installation failed. Please install Docker manually."
                exit 1
            fi
        fi
        if ! docker info >/dev/null 2>&1; then
            sudo systemctl enable docker
            sudo systemctl start docker
            sudo usermod -aG docker $USER
            echo -e "\n\033[33m[NOTE] User added to 'docker' group.\033[0m"
            echo -e "\033[33m[NOTE] Please REBOOT later to apply permission changes.\033[0m\n"
        fi
        ;;
      openEuler|openeuler)
        Ensure_Command ip iproute2
        if ! command -v docker >/dev/null 2>&1; then
            (
                # 添加 Docker 官方源（使用 CentOS 源）
                sudo dnf install -y dnf-utils && \
                sudo dnf config-manager --add-repo https://mirrors.aliyun.com/docker-ce/linux/centos/docker-ce.repo && \
                # 关键：将源中的版本号强制改为 7（openEuler 兼容 CentOS 7）
                sudo sed -i 's/\$releasever/7/g' /etc/yum.repos.d/docker-ce.repo && \
                # 安装 Docker（跳过 GPG 检查以防签名问题）
                sudo dnf install -y docker-ce docker-ce-cli containerd.io --nogpgcheck
            ) >/dev/null 2>&1

            if ! command -v docker >/dev/null 2>&1; then
                failure "Docker is required on $OS_ID. Automatic installation failed. Please install Docker manually."
                exit 1
            fi
        fi
        if ! docker info >/dev/null 2>&1; then
            sudo systemctl enable docker
            sudo systemctl start docker
            sudo usermod -aG docker $USER
            echo -e "\n\033[33m[NOTE] User added to 'docker' group.\033[0m"
            echo -e "\033[33m[NOTE] Please REBOOT later to apply permission changes.\033[0m\n"
        fi
        ;;
      *)
        failure "Unsupported OS: $OS_ID. "
        ;;
  esac
}

# Function to pull_images
function pull_images {
  echo "pull images for DevStar Studio ... "
  echo "439ffb6e2cce9ecb4568a5c54750ef290831d2ef" | docker login -u public devstar.cn --password-stdin > /dev/null 2>&1 || true
  if docker pull devstarcn/devstar-studio:$IMAGE_TAG; then
    docker tag devstarcn/devstar-studio:$IMAGE_TAG devstar.cn/devstar/devstar-studio:latest
    success "Successfully pulled devstar.cn/devstar/devstar-studio:latest"
  else
    docker pull devstar.cn/devstar/devstar-studio:$IMAGE_TAG
    docker tag devstar.cn/devstar/devstar-studio:$IMAGE_TAG devstar.cn/devstar/devstar-studio:latest
    success "Successfully pulled devstar.cn/devstar/devstar-studio:latest"
  fi
  if docker pull devstarcn/actions-runner:latest; then
    docker tag devstarcn/actions-runner:latest devstar.cn/devstar/actions-runner:latest
    success "Successfully pulled devstar.cn/devstar/actions-runner:latest"
  else
    docker pull devstar.cn/devstar/actions-runner:latest
    docker tag devstar.cn/devstar/actions-runner:latest devstarcn/actions-runner:latest
    success "Successfully pulled devstar.cn/devstar/actions-runner:latest"
  fi
  docker logout devstar.cn  > /dev/null 2>&1 || true
}

# Resolve the GID that /var/run/docker.sock actually has *inside* a container.
#
# The previous logic ran `stat -c %g /var/run/docker.sock` on the host where this
# script runs, and assumed that GID equals the socket's GID inside the container.
# That assumption is wrong when the socket is proxied across namespaces/distros,
# e.g. Docker Desktop's WSL2 backend: the host-side path may report a placeholder
# GID (such as 65534/nogroup) while the engine bind-mounts a socket whose
# in-container GID is something else (such as 108). Adding the host-side GID then
# leaves the studio's non-root user out of the socket's real group -> permission
# denied when talking to the Docker API.
#
# Instead, probe the real in-container GID by mounting the socket into a throwaway
# container and reading it there. Fall back to the host-side value, then to 0.
function resolve_docker_socket_gid {
  local probe_image="$1"
  local gid=""

  if [[ -n "$probe_image" ]]; then
    gid=$(${DOCKER_CMD} run --rm --entrypoint stat \
            -v /var/run/docker.sock:/var/run/docker.sock \
            "$probe_image" -c %g /var/run/docker.sock 2>/dev/null | tr -dc '0-9') || gid=""
  fi

  if [[ -z "$gid" ]]; then
    gid=$(stat -c %g /var/run/docker.sock 2>/dev/null | tr -dc '0-9') || gid=""
  fi

  printf '%s' "${gid:-0}"
}

# Function to start
function start {
  echo "Starting DevStar Studio ... "
  install_dependencies

  # 创建用于持久化存储DevStar相关的配置和用户数据
  mkdir -p "$DATA_DIR"
  # Resolve DOMAIN_NAME and configure insecure registry BEFORE install(),
  # because install() may fall back to pulling from devstar.cn (HTTP registry).
  if [ "$OS_ID" = "darwin" ]; then
    # macOS: get IP from network interface
    DOMAIN_NAME=$(ipconfig getifaddr en0 2>/dev/null || echo "localhost")
  else
    chown 1000:1000 "$DATA_DIR"
    DOMAIN_NAME=$(ip route get 1 2>/dev/null | awk '{print $7; exit}')

    if [[ -f "/.dockerenv" ]]; then
      if [[ -S "/var/run/docker.sock" ]] && command -v docker >/dev/null 2>&1; then
          # DooD 环境 - 获取宿主机IP
          DOMAIN_NAME=$(ip route | grep default | awk '{print $3}' 2>/dev/null)
      fi
      # 普通容器环境保持原来的容器IP
    fi
  fi

  # set insecure registry (must precede install() to avoid docker pull hanging)
  set_insecure_registry $DOMAIN_NAME $PORT

  # 启动devstar-studio容器
  if [[ -z "$IMAGE_STR" ]]; then
      pull_images
  fi
  if [[ -z "$IMAGE_STR" ]]; then
      IMAGE_STR=devstar.cn/devstar/devstar-studio:$IMAGE_TAG
  fi
  echo "image=$IMAGE_STR"

  DOCKER_SOCKET_GID=$(resolve_docker_socket_gid "$IMAGE_STR" 2>/dev/null | grep -E '^[0-9]+$' || echo 0)
  DOCKER_SOCKET_BINDING="-v /var/run/docker.sock:/var/run/docker.sock --group-add ${DOCKER_SOCKET_GID}"

  mkdir -p "$(dirname "$CONTAINER_FILE")"
  if [[ -e "$CONTAINER_FILE" ]]; then
      stop
  fi
  echo "$CONTAINER_NAME" > "$CONTAINER_FILE"

  # run with chosen docker/podman command
  ${DOCKER_CMD} run --restart=always --name $CONTAINER_NAME -d -p $PORT:3000 -p $SSH_PORT:$SSH_PORT $DOCKER_SOCKET_BINDING -v ${DATA_DIR}:/var/lib/gitea -v ${DATA_DIR}:/etc/gitea -e HOST_DATA_DIR=${DATA_DIR} $IMAGE_STR
  # 打开 `http://localhost:8080` 完成安装。
  success "----------------------------------------------------------------------------"
  success "DevStar started in http://$DOMAIN_NAME:$PORT successfully!"
  success "The config options will be written to: ${DATA_DIR}/app.ini "
  success "----------------------------------------------------------------------------"
  exit 0
}

# Function to stop
function stop {
  echo "Stopping DevStar Studio ... "
  if [[ -e "$CONTAINER_FILE" ]]; then
    if [ $( ${DOCKER_CMD} ps -a --filter "name=$(cat "$CONTAINER_FILE")" -q | wc -l) -gt 0 ]; then
      ${DOCKER_CMD} stop $( ${DOCKER_CMD} ps -a --filter "name=$(cat "$CONTAINER_FILE")" -q) && \
      ${DOCKER_CMD} rm -f $( ${DOCKER_CMD} ps -a --filter "name=$(cat "$CONTAINER_FILE")" -q) || true
    fi
    rm -rf $CONTAINER_FILE
  fi
}

# Function to logs
function logs {
  # 查看devstar-studio容器的运行日志
  echo "=== 容器日志:$(cat "$CONTAINER_FILE") ==="
  ${DOCKER_CMD} logs $(cat "$CONTAINER_FILE")
}

# Function to clean
function clean {
  stop
  if [ $( ${DOCKER_CMD} ps -a --filter "name=^/DevStar-Studio-" -q | wc -l) -gt 0 ]; then
    ${DOCKER_CMD} stop $( ${DOCKER_CMD} ps -a --filter "name=^/DevStar-Studio-" -q) && ${DOCKER_CMD} rm -f $( ${DOCKER_CMD} ps -a --filter "name=^/DevStar-Studio-" -q)
  fi
  if [ $( ${DOCKER_CMD} ps -a --filter "name=^/runner-" -q | wc -l) -gt 0 ]; then
    ${DOCKER_CMD} stop $( ${DOCKER_CMD} ps -a --filter "name=^/runner-" -q) && ${DOCKER_CMD} rm -f $( ${DOCKER_CMD} ps -a --filter "name=^/runner-" -q)
  fi
  read -p "警告：即将永久删除数据卷 $DATA_DIR 'YES' 确认: " confirm
  if [[ "$confirm" == "YES" ]]; then
      sudo rm -rf "$DATA_DIR"
  fi
}

# Main script
case "$1" in
  -h|--help|help)
    usage
    ;;
  install_dependencies)
    install_dependencies
    ;;
  pull_images)
    pull_images
    ;;
  start|restart)
    shift
    # Parse options (compatible with both GNU and BSD/macOS)
    while [ $# -gt 0 ]; do
        case "$1" in
            --port=*)
                PORT="${1#*=}"
                echo "The Port is: $PORT"
                shift ;;
            --ssh-port=*)
                SSH_PORT="${1#*=}"
                echo "The SSH_Port is: $SSH_PORT"
                shift ;;
            --data-dir=*)
                DATA_DIR="${1#*=}"
                echo "The data-dir is: $DATA_DIR"
                shift ;;
            --version=*)
                IMAGE_TAG="${1#*=}"
                echo "The DevStar Studio Image Version is: $IMAGE_TAG"
                shift ;;
            --image=*)
                IMAGE_STR="${1#*=}"
                echo "The DevStar Studio Image: $IMAGE_STR"
                shift ;;
            --)
                shift
                break ;;
            *)
                shift ;;
        esac
    done
    start
    ;;
  stop)
    stop
    ;;
  logs)
    logs
    ;;
  clean)
    clean
    ;;
  *)
    failure "Unrecognized option: $1"
    success "Copyright 2026 Mengning Software All rights reserved."
    usage
    ;;
esac
