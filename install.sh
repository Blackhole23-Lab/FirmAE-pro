#!/bin/bash

set -e  # Exit on error
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "[*] Starting FirmAE installation with binwalk3 support..."

# ============================================
# Basic Dependencies
# ============================================
echo "[*] Installing basic dependencies..."
sudo apt update
sudo apt install -y curl wget tar git ruby python3 python3-pip bc
sudo python3 -m pip install --upgrade pip
sudo python3 -m pip install coloredlogs

# ============================================
# Docker Setup
# ============================================
echo "[*] Setting up Docker..."
sudo apt install -y docker.io
sudo groupadd docker 2>/dev/null || true
sudo usermod -aG docker $USER

# ============================================
# PostgreSQL Setup
# ============================================
echo "[*] Setting up PostgreSQL..."
sudo apt install -y postgresql
sudo /etc/init.d/postgresql restart
sudo -u postgres bash -c "psql -c \"CREATE USER firmadyne WITH PASSWORD 'firmadyne';\"" 2>/dev/null || true
sudo -u postgres createdb -O firmadyne firmware 2>/dev/null || echo "Database already exists"
sudo -u postgres psql -d firmware < ./database/schema 2>/dev/null || true
echo "listen_addresses = '172.17.0.1,127.0.0.1,localhost'" | sudo -u postgres tee --append /etc/postgresql/*/main/postgresql.conf
echo "host all all 172.17.0.1/24 trust" | sudo -u postgres tee --append /etc/postgresql/*/main/pg_hba.conf
sudo /etc/init.d/postgresql restart

sudo apt install -y libpq-dev
python3 -m pip install psycopg2 psycopg2-binary

sudo apt install -y busybox-static bash-static fakeroot dmsetup kpartx netcat-openbsd nmap python3-psycopg2 snmp uml-utilities util-linux vlan

# ============================================
# Binwalk3 Installation
# ============================================
echo "[*] Installing binwalk3 and dependencies..."

# Install build dependencies for binwalk3
echo "[*] Installing build dependencies..."
sudo apt install -y build-essential pkg-config libssl-dev

# Install Rust toolchain (required for binwalk3 native binary)
if ! command -v cargo &> /dev/null; then
  echo "[*] Installing Rust toolchain..."
  curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y --default-toolchain stable
  export PATH="$HOME/.cargo/bin:$PATH"
  source "$HOME/.cargo/env"
else
  echo "[+] Rust toolchain already installed"
  source "$HOME/.cargo/env" 2>/dev/null || true
fi

# Verify Rust installation
if ! cargo --version &> /dev/null; then
  echo "[-] ERROR: Rust installation failed!"
  exit 1
fi
echo "[+] Rust version: $(cargo --version)"

# Install binwalk3 Python module (provides Python API)
echo "[*] Installing binwalk3 Python module..."
sudo python3 -m pip install binwalk3

# Compile and install binwalk3 native binary from source
echo "[*] Compiling binwalk3 native binary from source..."
BINWALK_BUILD_DIR="/tmp/binwalk-v3-build"
rm -rf "$BINWALK_BUILD_DIR"

git clone --depth 1 --branch v3.1.0 https://github.com/ReFirmLabs/binwalk.git "$BINWALK_BUILD_DIR"
cd "$BINWALK_BUILD_DIR"
cargo build --release

# Install the binary
sudo cp target/release/binwalk /usr/local/bin/binwalk3
sudo chmod +x /usr/local/bin/binwalk3

# Verify installation
if binwalk3 --help &> /dev/null; then
  echo "[+] binwalk3 binary installed successfully: $(which binwalk3)"
else
  echo "[-] WARNING: binwalk3 binary installation may have issues"
fi

# Cleanup
cd "$SCRIPT_DIR"
rm -rf "$BINWALK_BUILD_DIR"

# ============================================
# Extraction Tool Dependencies
# ============================================
echo "[*] Installing extraction tool dependencies..."

# Install system packages for extraction tools
sudo apt install -y mtd-utils gzip bzip2 tar arj lhasa p7zip p7zip-full cabextract \
  fusecram cramfsswap squashfs-tools sleuthkit default-jdk cpio lzop lzma srecord \
  zlib1g-dev liblzma-dev liblzo2-dev unzip

# Install binwalk extraction dependencies using deps.sh from v2.3.4
# (These tools are still needed for binwalk3)
echo "[*] Installing binwalk extraction dependencies..."
DEPS_SCRIPT="/tmp/binwalk_deps.sh"
wget -q https://raw.githubusercontent.com/ReFirmLabs/binwalk/v2.3.4/deps.sh -O "$DEPS_SCRIPT"
sed -i 's/^install_ubireader//g' "$DEPS_SCRIPT"
sed -i 's/^REQUIRED_UTILS="wget tar python"/REQUIRED_UTILS="wget tar python3"/g' "$DEPS_SCRIPT"
chmod +x "$DEPS_SCRIPT"
echo y | bash "$DEPS_SCRIPT" || echo "[!] Some dependencies from deps.sh failed (non-critical)"
rm -f "$DEPS_SCRIPT"

# Install Python extraction tools
echo "[*] Installing Python extraction tools..."
python3 -m pip install jefferson python-lzo cstruct ubi_reader

# Install yaffshiv manually
echo "[*] Installing yaffshiv..."
YAFFSHIV_DIR="/tmp/yaffshiv-install"
rm -rf "$YAFFSHIV_DIR"
git clone https://github.com/devttys0/yaffshiv.git "$YAFFSHIV_DIR"
cd "$YAFFSHIV_DIR"
sudo python3 setup.py install
cd "$SCRIPT_DIR"
rm -rf "$YAFFSHIV_DIR"

# Install additional Python dependencies
sudo apt install -y python3-magic openjdk-8-jdk unrar

# ============================================
# FirmAE Core Components
# ============================================
echo "[*] Installing FirmAE core components..."
sudo cp core/unstuff /usr/local/bin/

# ============================================
# Analyzer and Initializer Setup
# ============================================
echo "[*] Setting up analyzers and initializers..."
sudo apt install -y python3-bs4
python3 -m pip install selenium

# Install Google Chrome
if ! command -v google-chrome &> /dev/null; then
  echo "[*] Installing Google Chrome..."
  wget -q https://dl.google.com/linux/direct/google-chrome-stable_current_amd64.deb
  sudo dpkg -i google-chrome-stable_current_amd64.deb || sudo apt -fy install
  rm -f google-chrome-stable_current_amd64.deb
else
  echo "[+] Google Chrome already installed"
fi

# Install ChromeDriver
if ! test -e "./analyses/chromedriver"; then
  echo "[*] Installing ChromeDriver..."
  wget -q https://chromedriver.storage.googleapis.com/2.38/chromedriver_linux64.zip
  unzip -q chromedriver_linux64.zip -d ./analyses/
  rm -f chromedriver_linux64.zip
else
  echo "[+] ChromeDriver already installed"
fi

# Install RouterSploit dependencies
echo "[*] Installing RouterSploit dependencies..."
python3 -m pip install -r ./analyses/routersploit/requirements.txt
cd ./analyses/routersploit && patch -p1 < ../routersploit_patch 2>/dev/null || echo "[!] RouterSploit patch already applied"
cd "$SCRIPT_DIR"

# ============================================
# QEMU Setup
# ============================================
echo "[*] Installing QEMU..."
sudo apt install -y qemu-system-arm qemu-system-aarch64 qemu-system-mips qemu-system-x86 qemu-utils

# ============================================
# Installation Verification
# ============================================
echo ""
echo "============================================"
echo "Installation Verification"
echo "============================================"

# Check binwalk3
if python3 -c "import binwalk; print(binwalk.__version__)" &> /dev/null; then
  BINWALK_VERSION=$(python3 -c "import binwalk; print(binwalk.__version__)")
  echo "[+] binwalk Python module: v${BINWALK_VERSION}"
else
  echo "[-] WARNING: binwalk Python module not found!"
fi

if command -v binwalk3 &> /dev/null; then
  echo "[+] binwalk3 binary: $(which binwalk3)"
else
  echo "[-] WARNING: binwalk3 binary not found!"
fi

# Check Rust
if command -v cargo &> /dev/null; then
  echo "[+] Rust: $(cargo --version)"
else
  echo "[-] WARNING: Rust not found!"
fi

# Check extraction tools
echo ""
echo "Extraction tools:"
for tool in jefferson ubi_reader; do
  if python3 -c "import $tool" &> /dev/null 2>&1; then
    echo "[+] $tool: installed"
  else
    echo "[-] $tool: NOT installed"
  fi
done

echo ""
echo "============================================"
echo "[+] Installation complete!"
echo "============================================"
echo ""
echo "NOTE: If you installed Rust for the first time, run:"
echo "  source \$HOME/.cargo/env"
echo "Or restart your terminal to use binwalk3."
echo ""
