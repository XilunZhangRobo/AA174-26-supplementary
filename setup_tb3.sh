#!/usr/bin/env bash
# ROS setup files may read unset variables; keep error/pipe checks without nounset.
set -Eeo pipefail

WS="$HOME/tb_ws"

step() {
  echo
  echo "============================================================"
  echo "$1"
  echo "============================================================"
}

trap 'echo; echo "ERROR: setup stopped at line $LINENO."; echo "Fix the error above, then run this script again."; exit 1' ERR

source /etc/os-release

if [[ "${VERSION_CODENAME:-}" != "jammy" ]]; then
  echo "ERROR: This script requires Ubuntu 22.04 (jammy)."
  echo "Detected: ${PRETTY_NAME:-unknown}"
  exit 1
fi

ARCH="$(dpkg --print-architecture)"
if [[ "$ARCH" != "arm64" ]]; then
  echo "WARNING: This guide was written for ARM64. Detected: $ARCH"
fi

step "1/10  Requesting administrator access"
sudo -v

while true; do
  sudo -n true
  sleep 60
done 2>/dev/null &
SUDO_KEEPALIVE_PID=$!
NEEDRESTART_CONF=""

cleanup() {
  if [[ -n "$NEEDRESTART_CONF" ]]; then
    sudo rm -f -- "$NEEDRESTART_CONF" || true
  fi
  kill "$SUDO_KEEPALIVE_PID" 2>/dev/null || true
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

# rosdep invokes sudo itself, which drops NEEDRESTART_MODE from the environment.
# Temporarily defer service restarts to the final reboot for every apt invocation.
sudo mkdir -p /etc/needrestart/conf.d
NEEDRESTART_CONF="$(sudo mktemp /etc/needrestart/conf.d/zz-aa174-XXXXXX.conf)"
echo '$nrconf{restart} = "l";' | sudo tee "$NEEDRESTART_CONF" >/dev/null

apt_install() {
  sudo env DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=l apt-get install -y "$@"
}

step "2/10  Updating Ubuntu"
sudo apt-get update
sudo env DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=l apt-get upgrade -y

step "3/10  Installing Ubuntu Desktop and development tools"
apt_install   ubuntu-desktop   git curl software-properties-common lsb-release wget gnupg   python3-dev python3-venv cmake build-essential   vim tmux htop gh

step "4/10  Installing shell/editor configuration"
mkdir -p "$HOME/.colcon"

if [[ ! -d "$HOME/configs/.git" ]]; then
  git clone https://github.com/alvinsunyixiao/configs.git "$HOME/configs"
else
  echo "$HOME/configs already exists; skipping clone."
fi

ln -sfn "$HOME/configs/vim/.vimrc" "$HOME/.vimrc"
ln -sfn "$HOME/configs/tmux/.tmux.conf" "$HOME/.tmux.conf"
ln -sfn "$HOME/configs/colcon/defaults.yaml" "$HOME/.colcon/defaults.yaml"

curl -fLo "$HOME/.vim/autoload/plug.vim" --create-dirs   https://raw.githubusercontent.com/junegunn/vim-plug/master/plug.vim

vim -E +'PlugInstall --sync' +qa || true

step "5/10  Installing ROS 2 Humble"
sudo add-apt-repository universe -y

sudo curl -fsSL   https://raw.githubusercontent.com/ros/rosdistro/master/ros.key   -o /usr/share/keyrings/ros-archive-keyring.gpg

echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/ros-archive-keyring.gpg] http://packages.ros.org/ros2/ubuntu $(. /etc/os-release && echo "$UBUNTU_CODENAME") main" | sudo tee /etc/apt/sources.list.d/ros2.list >/dev/null

sudo apt-get update
apt_install ros-humble-ros-base ros-dev-tools

step "6/10  Initializing rosdep"
if [[ ! -f /etc/ros/rosdep/sources.list.d/20-default.list ]]; then
  sudo rosdep init
else
  echo "rosdep is already initialized."
fi
rosdep update

step "7/10  Installing Gazebo Garden and ROS-Gazebo bridge"
sudo curl -fsSL   https://packages.osrfoundation.org/gazebo.gpg   -o /usr/share/keyrings/pkgs-osrf-archive-keyring.gpg

echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/pkgs-osrf-archive-keyring.gpg] https://packages.osrfoundation.org/gazebo/ubuntu-stable $(lsb_release -cs) main" | sudo tee /etc/apt/sources.list.d/gazebo-stable.list >/dev/null

sudo apt-get update
apt_install gz-garden ros-humble-ros-gz-sim ros-humble-ros-gz-bridge

# Intentionally NOT cloning ros_gz from source.

step "8/10  Creating the TurtleBot3 workspace"
mkdir -p "$WS/src"
cd "$WS/src"

if [[ ! -d asl-tb3-driver/.git ]]; then
  git clone https://github.com/StanfordASL/asl-tb3-driver.git
else
  echo "asl-tb3-driver already exists; skipping clone."
fi

if [[ ! -d asl-tb3-utils/.git ]]; then
  git clone https://github.com/StanfordASL/asl-tb3-utils.git
else
  echo "asl-tb3-utils already exists; skipping clone."
fi

step "9/10  Installing dependencies and building"
source /opt/ros/humble/setup.bash

rosdep update
rosdep install --from-paths "$WS/src" --ignore-src -r -y

cd "$WS"
GZ_VERSION=garden colcon build --symlink-install

step "10/10  Configuring the shell and verifying"
ROS_SOURCE='source /opt/ros/humble/setup.bash'
WS_SOURCE='source $HOME/tb_ws/install/setup.bash'
UPDATE_ALIAS='alias update_tb_ws="$HOME/tb_ws/src/asl-tb3-utils/scripts/update.sh"'

grep -qxF "$ROS_SOURCE" "$HOME/.bashrc" || echo "$ROS_SOURCE" >> "$HOME/.bashrc"
grep -qxF "$WS_SOURCE" "$HOME/.bashrc" || echo "$WS_SOURCE" >> "$HOME/.bashrc"
grep -qxF "$UPDATE_ALIAS" "$HOME/.bashrc" || echo "$UPDATE_ALIAS" >> "$HOME/.bashrc"

source /opt/ros/humble/setup.bash
source "$WS/install/setup.bash"

echo
echo "Verification:"
echo -n "asl_tb3_sim: "; ros2 pkg prefix asl_tb3_sim
echo -n "slam_toolbox: "; ros2 pkg prefix slam_toolbox
echo -n "rviz2: "; command -v rviz2
echo -n "gz: "; command -v gz

echo
echo "============================================================"
echo "SETUP COMPLETE"
echo "============================================================"
echo
echo "Reboot once:"
echo "  sudo reboot"
echo
echo "After reboot:"
echo "Terminal 1:"
echo "  ros2 launch asl_tb3_sim root.launch.py"
echo
echo "Terminal 2:"
echo "  rviz2"
echo
echo "In RViz:"
echo "  Fixed Frame = map"
echo "  Map topic = /map"
echo "  LaserScan topic = /scan"
