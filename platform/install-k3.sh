#!/bin/bash
#
# Archestra Platform Installer
# 
# This script automatically sets up Archestra with Kubernetes orchestration.
# It will:
# 1. Check for Docker
# 2. Install K3d (if needed)
# 3. Create a K3d cluster (if needed)
# 4. Configure kubeconfig for Docker access
# 5. Start Archestra with MCP orchestration enabled
#
# Usage:
#   curl -fsSL https://archestra.ai/install.sh | bash
#   OR
#   ./install.sh
#

set -e  # Exit on error

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# Configuration
CLUSTER_NAME="archestra-cluster"
CONTAINER_NAME="archestra"
KUBECONFIG_PATH="/tmp/archestra-kubeconfig.yaml"
ARCHESTRA_IMAGE="archestra/platform:latest"

# Helper functions
log_info() {
    echo -e "${CYAN}ℹ️  $1${NC}"
}

log_success() {
    echo -e "${GREEN}✅ $1${NC}"
}

log_error() {
    echo -e "${RED}❌ $1${NC}"
}

log_warning() {
    echo -e "${YELLOW}⚠️  $1${NC}"
}

log_step() {
    echo -e "${BLUE}$1${NC}"
}

print_banner() {
    echo ""
    echo -e "${CYAN}╔═══════════════════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║      🎭 Archestra Platform Installer                 ║${NC}"
    echo -e "${CYAN}╚═══════════════════════════════════════════════════════╝${NC}"
    echo ""
}

command_exists() {
    command -v "$1" >/dev/null 2>&1
}

# Detect OS
detect_os() {
    case "$(uname -s)" in
        Linux*)     echo "linux" ;;
        Darwin*)    echo "mac" ;;
        *)          echo "unknown" ;;
    esac
}

# Check Docker
check_docker() {
    log_step "🔍 Checking for Docker..."
    
    if ! command_exists docker; then
        log_error "Docker not found"
        echo ""
        log_info "Please install Docker first:"
        echo "  • Linux: https://docs.docker.com/engine/install/"
        echo "  • Mac: https://docs.docker.com/desktop/install/mac-install/"
        exit 1
    fi
    
    # Check if Docker daemon is running
    if ! docker info >/dev/null 2>&1; then
        log_error "Docker daemon is not running"
        log_info "Please start Docker and try again"
        exit 1
    fi
    
    log_success "Docker is installed and running"
}

# Check if K3d is installed
check_k3d() {
    log_step "🔍 Checking for K3d..."
    
    if command_exists k3d; then
        K3D_VERSION=$(k3d version | grep k3d | awk '{print $3}')
        log_success "K3d is already installed (version $K3D_VERSION)"
        return 0
    else
        log_warning "K3d not found"
        return 1
    fi
}

# Install K3d
install_k3d() {
    log_step "📦 Installing K3d..."
    
    OS=$(detect_os)
    
    case $OS in
        mac)
            if command_exists brew; then
                log_info "Installing K3d via Homebrew..."
                brew install k3d
            else
                log_info "Installing K3d via install script..."
                curl -s https://raw.githubusercontent.com/k3d-io/k3d/main/install.sh | bash
            fi
            ;;
        linux)
            log_info "Installing K3d via install script..."
            curl -s https://raw.githubusercontent.com/k3d-io/k3d/main/install.sh | bash
            ;;
        *)
            log_error "Unsupported operating system"
            exit 1
            ;;
    esac
    
    if command_exists k3d; then
        log_success "K3d installed successfully"
    else
        log_error "Failed to install K3d"
        exit 1
    fi
}

# Check if kubectl is installed
check_kubectl() {
    log_step "🔍 Checking for kubectl..."
    
    if command_exists kubectl; then
        log_success "kubectl is installed"
        return 0
    else
        log_warning "kubectl not found - installing..."
        install_kubectl
        return 0
    fi
}

# Install kubectl
install_kubectl() {
    OS=$(detect_os)
    
    case $OS in
        mac)
            if command_exists brew; then
                log_info "Installing kubectl via Homebrew..."
                brew install kubectl
            else
                log_info "Installing kubectl manually..."
                curl -LO "https://dl.k8s.io/release/$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/darwin/amd64/kubectl"
                chmod +x kubectl
                sudo mv kubectl /usr/local/bin/
            fi
            ;;
        linux)
            log_info "Installing kubectl..."
            curl -LO "https://dl.k8s.io/release/$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"
            chmod +x kubectl
            sudo mv kubectl /usr/local/bin/
            ;;
    esac
    
    if command_exists kubectl; then
        log_success "kubectl installed successfully"
    else
        log_error "Failed to install kubectl"
        exit 1
    fi
}

# Check if K3d cluster exists
check_k3d_cluster() {
    log_step "🔍 Checking for K3d cluster..."
    
    if k3d cluster list | grep -q "$CLUSTER_NAME"; then
        # Check if cluster is running
        if k3d cluster list | grep "$CLUSTER_NAME" | grep -q "running"; then
            log_success "K3d cluster '$CLUSTER_NAME' is running"
            return 0
        else
            log_warning "K3d cluster '$CLUSTER_NAME' exists but is not running"
            log_info "Starting cluster..."
            k3d cluster start "$CLUSTER_NAME"
            log_success "Cluster started"
            return 0
        fi
    else
        log_warning "K3d cluster '$CLUSTER_NAME' not found"
        return 1
    fi
}

# Create K3d cluster
create_k3d_cluster() {
    log_step "🚀 Creating K3d cluster '$CLUSTER_NAME'..."
    
    # Create cluster with API port exposed
    k3d cluster create "$CLUSTER_NAME" \
        --api-port 6443 \
        --servers 1 \
        --agents 0 \
        --wait
    
    if [ $? -eq 0 ]; then
        log_success "K3d cluster created successfully"
        
        # Wait a bit for cluster to fully initialize
        log_info "Waiting for cluster to be ready..."
        sleep 5
    else
        log_error "Failed to create K3d cluster"
        exit 1
    fi
}

# Configure kubeconfig for Docker access
configure_kubeconfig() {
    log_step "⚙️  Configuring kubeconfig for Docker access..."
    
    # Export kubeconfig from K3d
    k3d kubeconfig get "$CLUSTER_NAME" > "$KUBECONFIG_PATH"
    
    if [ ! -f "$KUBECONFIG_PATH" ]; then
        log_error "Failed to export kubeconfig"
        exit 1
    fi
    
    # Modify kubeconfig to use host.docker.internal
    # This allows the Docker container to reach the K3d cluster on the host
    
    # Replace 0.0.0.0 with host.docker.internal
    sed -i.bak 's|https://0.0.0.0:|https://host.docker.internal:|g' "$KUBECONFIG_PATH"
    
    # Also handle 127.0.0.1 just in case
    sed -i.bak 's|https://127.0.0.1:|https://host.docker.internal:|g' "$KUBECONFIG_PATH"
    
    # Remove backup file
    rm -f "${KUBECONFIG_PATH}.bak"
    
    log_success "Kubeconfig configured at: $KUBECONFIG_PATH"
    
    # Verify the configuration
    if grep -q "host.docker.internal" "$KUBECONFIG_PATH"; then
        log_success "Server address updated to host.docker.internal"
    else
        log_warning "Failed to update server address in kubeconfig"
    fi
}

# Pull Archestra Docker image
pull_archestra_image() {
    log_step "📦 Pulling Archestra Docker image..."
    
    if docker pull "$ARCHESTRA_IMAGE"; then
        log_success "Image pulled successfully"
    else
        log_error "Failed to pull Archestra image"
        exit 1
    fi
}

# Check if Archestra container already exists
check_existing_container() {
    if docker ps -a --format '{{.Names}}' | grep -q "^${CONTAINER_NAME}$"; then
        log_warning "Archestra container already exists"
        echo ""
        read -p "Remove existing container and reinstall? [Y/n]: " response
        response=${response:-Y}
        
        if [[ "$response" =~ ^[Yy]$ ]]; then
            log_info "Removing existing container..."
            docker rm -f "$CONTAINER_NAME" >/dev/null 2>&1
            log_success "Existing container removed"
        else
            log_info "Keeping existing container"
            log_info "Use 'docker start $CONTAINER_NAME' to start it"
            exit 0
        fi
    fi
}

# Start Archestra container
start_archestra() {
    log_step "🚀 Starting Archestra Platform..."
    
    # Determine if we need --add-host flag (Linux needs it, Mac/Docker Desktop has it by default)
    ADD_HOST_FLAG=""
    if [ "$(detect_os)" = "linux" ]; then
        ADD_HOST_FLAG="--add-host host.docker.internal:host-gateway"
    fi
    
    # Start container with K8s orchestration enabled
    docker run -d \
        --name "$CONTAINER_NAME" \
        -p 9000:9000 \
        -p 3000:3000 \
        $ADD_HOST_FLAG \
        -v "$KUBECONFIG_PATH:/app/kubeconfig" \
        -v archestra-postgres-data:/var/lib/postgresql/data \
        -v archestra-app-data:/app/data \
        -e ARCHESTRA_ORCHESTRATOR_KUBECONFIG=/app/kubeconfig \
        -e ARCHESTRA_ORCHESTRATOR_LOAD_KUBECONFIG_FROM_CURRENT_CLUSTER=false \
        -e ARCHESTRA_ORCHESTRATOR_K8S_NAMESPACE=default \
        "$ARCHESTRA_IMAGE"
    
    if [ $? -eq 0 ]; then
        log_success "Archestra container started"
    else
        log_error "Failed to start Archestra container"
        exit 1
    fi
}

# Wait for Archestra to be ready
wait_for_archestra() {
    log_step "⏳ Waiting for Archestra to start..."
    
    MAX_ATTEMPTS=30
    ATTEMPT=0
    
    while [ $ATTEMPT -lt $MAX_ATTEMPTS ]; do
        if docker logs "$CONTAINER_NAME" 2>&1 | grep -q "started on port"; then
            log_success "Archestra is ready!"
            return 0
        fi
        
        ATTEMPT=$((ATTEMPT + 1))
        sleep 2
        echo -n "."
    done
    
    echo ""
    log_warning "Archestra may still be starting. Check logs with:"
    echo "  docker logs -f $CONTAINER_NAME"
}

# Print success message and next steps
print_success() {
    echo ""
    echo -e "${GREEN}╔═══════════════════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║      🎉 Archestra Installation Complete!            ║${NC}"
    echo -e "${GREEN}╚═══════════════════════════════════════════════════════╝${NC}"
    echo ""
    echo -e "${CYAN}🌐 Access Archestra:${NC}"
    echo "   Web UI:  http://localhost:3000"
    echo "   API:     http://localhost:9000"
    echo ""
    echo -e "${CYAN}📋 Useful commands:${NC}"
    echo "   View logs:    docker logs -f $CONTAINER_NAME"
    echo "   Stop:         docker stop $CONTAINER_NAME"
    echo "   Restart:      docker restart $CONTAINER_NAME"
    echo "   Remove:       docker rm -f $CONTAINER_NAME"
    echo ""
    echo -e "${CYAN}🎯 MCP Orchestration:${NC}"
    echo "   Status:       ENABLED ✅"
    echo "   Cluster:      $CLUSTER_NAME"
    echo "   Namespace:    default"
    echo ""
    echo -e "${CYAN}📚 Documentation:${NC}"
    echo "   Docs:         https://archestra.ai/docs"
    echo "   Community:    https://archestra.ai/slack"
    echo ""
    
    # Try to open browser
    if command_exists open; then
        log_info "Opening browser..."
        sleep 3
        open http://localhost:3000 >/dev/null 2>&1 &
    elif command_exists xdg-open; then
        log_info "Opening browser..."
        sleep 3
        xdg-open http://localhost:3000 >/dev/null 2>&1 &
    else
        log_info "Please open http://localhost:3000 in your browser"
    fi
}

# Main installation flow
main() {
    print_banner
    
    # Step 1: Check prerequisites
    check_docker
    check_kubectl
    
    # Step 2: Setup K3d
    if ! check_k3d; then
        install_k3d
    fi
    
    # Step 3: Setup K3d cluster
    if ! check_k3d_cluster; then
        create_k3d_cluster
    fi
    
    # Step 4: Configure kubeconfig
    configure_kubeconfig
    
    # Step 5: Pull Archestra image
    pull_archestra_image
    
    # Step 6: Check for existing container
    check_existing_container
    
    # Step 7: Start Archestra
    start_archestra
    
    # Step 8: Wait for startup
    wait_for_archestra
    
    # Step 9: Print success message
    print_success
}

# Error handler
trap 'log_error "Installation failed. Check the error above."; exit 1' ERR

# Run main function
main

exit 0