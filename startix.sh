#!/bin/sh

[ "$(id -u)" != 0 ] && echo "you must run this as root" && exit 1
! command -v curl >/dev/null 2>&1 && echo "please install curl" && exit 1
command -v parted >/dev/null 2>&1 || pacman -Sy --noconfirm parted
! command -v parted >/dev/null 2>&1 && echo "please install parted" && exit 1

yesno() {
    echo "$*? (y/n)"
    read -r answer
    case "$answer" in
      y*|Y*) ;;
      *) echo "canceled" && return 1 ;;
    esac
}

isbios() {
  if [ "$BIOS" ]; then
    [ "$BIOS" = "1" ] && return
    return 1
  fi
  [ ! -d /sys/firmware/efi/efivars ] && return
}

drives() {
  find /dev/disk/by-id/* | sed '/-part[0-9]\+$/d'
}

if ! mount | grep -q /mnt/artix; then
  defaultdrive="$(drives | sed '/\/usb-/d;1q')"
  echo "################################################################################"
  drives
  echo "################################################################################"
  echo
  echo "WARNING: all the data on the drive will be wiped"
  echo "enter the install drive. either refer to the list above or check /dev/disk/by-id"
  while :; do
    echo
    echo "drive name (defaults to $defaultdrive):"
    read -r drivename
    [ "$drivename" ] || drivename="$defaultdrive"
    drive="$(readlink -f "$drivename")" && [ -e "$drive" ] && break
    echo "ERROR: this drive doesn't exist"
  done

  echo "you are about to wipe $drivename ($drive)"
  yesno "this will wipe all the data on that drive. are you sure" || exit

  mkdir -p /mnt/artix
  dd if=/dev/zero "of=$drive" count=10 && sync || exit
  if isbios; then
    echo "partitioning for BIOS"
    parted --script "$drive" \
      mklabel msdos \
      mkpart primary ext4 1MiB 100% \
      set 1 boot on &&
    mkfs.ext4 "${drive}1" &&
    mount "${drive}1" /mnt/artix || exit
  else
    echo "partitioning for EFI"
    parted --script "$drive" \
      mklabel gpt \
      mkpart primary fat32 1MiB 501MiB \
      set 1 esp on \
      mkpart primary ext4 501MiB 100% &&
    mkfs.fat -F32 "${drive}1" &&
    mkfs.ext4 "${drive}2" &&
    mount "${drive}2" /mnt/artix &&
    mkdir -p /mnt/artix/efi &&
    mount "${drive}1" /mnt/artix/efi || exit
  fi
fi

base_packages() {
  [ "$ARTIX_CACHE" ] &&
    command -v rsync &&
    echo "copying cache" &&
    rsync -rv "$ARTIX_CACHE/" /mnt/artix/ || return
  bs base base-devel runit elogind-runit || return
  bs linux-firmware linux linux-headers || return
  bs nfs-utils gvim xorg-server nodm git xorg-xinit xorg-xset xterm nitrogen parcellite vi openssh \
    openssh-runit wpa_supplicant dhcpcd picom nnn sxiv qt5ct grub os-prober curl sv-helper\
    noto-fonts noto-fonts-cjk noto-fonts-emoji dunst networkmanager networkmanager-runit maim \
    man-pages \
    || return
}
chaotic_multilib_packages() {
  pac -S powerpill || return
  pow -S linux-tkg-pds linux-tkg-pds-headers brave lib32-vulkan-radeon vulkan-radeon \
    vulkan-icd-loader lib32-vulkan-icd-loader steam-native-runtime adwaita-qt \
    papirus-icon-theme-git bpytop mangohud xboxdrv || return
  # TODO: replace brave with something non shill that uses up to date chromium
}
aur_packages() {
  pac -Rdd libxft
  tri -S transset-df nodm-runit apulse adwaita-dark ttf-hack-ligatured xboxdrv-runit \
    libxft-bgra-git ttf-scientifica ufetch-git || return
}

if ! isbios && ! mount | grep '/mnt/artix/efi type vfat'; then
  echo "you must mount your EFI system partition at /mnt/artix/efi"
  echo "it needs to be a FAT32 partition, recommended size is ~500MB"
  echo "format it with"
  echo "  mkfs.fat -F32 /dev/sdXN"
  echo "where XN are the disk letter and partition number, such as /dev/sda1"
  echo "DO NOT GET THIS WRONG! otherwise you will wipe other partitions"
  echo
  echo "if you intended to do a BIOS install, force by exporting BIOS=1"
  echo
  echo "please mount it and call me again"
  exit 1
fi

cr() {
  artools-chroot /mnt/artix "$@"
}

bs() {
  basestrap /mnt/artix "$@"
}

pac() {
  cr pacman --noconfirm "$@"
}

pow() {
  cr powerpill --noconfirm "$@"
}

tri() {
  udo trizen --noconfirm "$@"
}

udo() {
  # very janky way to do it but I need to be able to pipe in stuff
  user="$(cr id -un -- 1000)"
  echo "su - '$user' -c '$*'" > /mnt/artix/udo.sh
  chmod +x /mnt/artix/udo.sh
  cr sh /udo.sh
}

sv_enable() {
  ln -s "/etc/runit/sv/$1" /mnt/artix/etc/runit/runsvdir/default/ || return
}

sv_conf() {
  f="/mnt/artix/etc/runit/sv/$1/conf"
  cat > "$f" && chmod +x "$f" || return
}

do_step() {
  grep -q "^$*\$" /mnt/artix/install-steps && return
  echo ":: $*"
  "$@" || exit
  echo "$@" >> /mnt/artix/install-steps || exit
}

last_step() {
  rm /mnt/artix/install-steps
  rm /mnt/artix/udo.sh
  echo ":: done"
}

do_step base_packages

system_config() {
  fstabgen -U /mnt/artix > /mnt/artix/etc/fstab || return

  tzone="$(readlink /etc/localtime)"
  ln -svf "$tzone" /mnt/artix/etc/localtime

  cat > /mnt/artix/etc/locale.conf << EOF
export LANG="en_US.UTF-8"
export LC_COLLATE="C"
EOF
  echo '%wheel ALL=(ALL) NOPASSWD: ALL' > /mnt/artix/etc/sudoers.d/wheel-nopasswd || return

  cat > /mnt/artix/etc/pam.d/nodm << EOF
#%PAM-1.0

auth      include   system-local-login
account   include   system-local-login
password  include   system-local-login
session   include   system-local-login
EOF
}
do_step system_config

locale_gen() {
  echo 'en_US.UTF-8 UTF-8' >> /mnt/artix/etc/locale.gen || return
  cr locale-gen || return
}
do_step locale_gen

chaotic_aur() {
  cr pacman-key --keyserver hkp://keyserver.ubuntu.com -r 3056513887B78AEB 8A9E14A07010F7E3 &&
  cr pacman-key --lsign-key 3056513887B78AEB &&
  cr pacman-key --lsign-key 8A9E14A07010F7E3 || return
  cat > /mnt/artix/etc/pacman.conf << EOF
#
# /etc/pacman.conf
#
# See the pacman.conf(5) manpage for option and repository directives

[options]
HoldPkg     = pacman glibc
Architecture = auto
CheckSpace
SigLevel    = Required DatabaseOptional
LocalFileSigLevel = Optional

# artix repos. these should stay above arch ones so they have priority

#[gremlins]
#Include = /etc/pacman.d/mirrorlist

[system]
Include = /etc/pacman.d/mirrorlist

[world]
Include = /etc/pacman.d/mirrorlist

#[galaxy-gremlins]
#Include = /etc/pacman.d/mirrorlist

[galaxy]
Include = /etc/pacman.d/mirrorlist

# If you want to run 32 bit applications on your x86_64 system,
# enable the lib32 repositories as required here.

#[lib32-gremlins]
#Include = /etc/pacman.d/mirrorlist

[lib32]
Include = /etc/pacman.d/mirrorlist

# An example of a custom package repository.  See the pacman manpage for
# tips on creating your own repositories.
#[custom]
#SigLevel = Optional TrustAll
#Server = file:///home/custompkgs

[chaotic-aur]
Include = /etc/pacman.d/chaotic-mirrorlist

# arch linux repos

#[testing]
#Include = /etc/pacman.d/mirrorlist-arch

[extra]
Include = /etc/pacman.d/mirrorlist-arch

#[community-testing]
#Include = /etc/pacman.d/mirrorlist-arch

[community]
Include = /etc/pacman.d/mirrorlist-arch

#[multilib-testing]
#Include = /etc/pacman.d/mirrorlist-arch

[multilib]
Include = /etc/pacman.d/mirrorlist-arch
EOF
  curl 'https://aur.archlinux.org/cgit/aur.git/plain/mirrorlist?h=chaotic-mirrorlist' \
    > /mnt/artix/etc/pacman.d/chaotic-mirrorlist &&
  pac -Syuu && pac -S chaotic-mirrorlist chaotic-keyring || return
}
do_step chaotic_aur
do_step chaotic_multilib_packages

bootloader() {
  echo 'GRUB_CMDLINE_LINUX="amd_iommu=on intel_iommu=on iommu=pt rd.driver.pre=vfio-pci pcie_acs_override=downstream,multifunction default_hugepagesz=1GB hugepagesz=1GB radeon.si_support=0 amdgpu.si_support=1 radeon.cik_support=0 amdgpu.cik_support=1 amdgpu.ppfeaturemask=0xffffffff amdgpu.gpu_recovery=1 amdgpu.lockup_timeout=10000,10000,10000,10000 job_hang_limit=10000 usbhid.kbpoll=1 usbhid.mousepoll=1 usbhid.jspoll=1 noibrs noibpb nopti nospectre_v2 nospectre_v1 l1tf=off nospec_store_bypass_disable no_stf_barrier mds=off mitigations=off"' \
    >> /mnt/artix/etc/default/grub
  if isbios; then
    echo "
your install is detected to be BIOS. for your safety, you should doublecheck and install the
bootloader yourself.

please install the boot loader by running:

  artools-chroot /mnt/artix grub-install --target=i386-pc --recheck /dev/sdX

where sdX is the disk you are installing to

here are your mountpoints, the root disk is probably the one you want to install to:"
    mount | grep /mnt/artix
    echo
    echo "BE CAREFUL, if you pick the wrong disk you could disk wiping other bootloaders"
    echo
    while :; do
      echo "press any key after you have installed the bootloader"
      read -r
      cr grub-mkconfig -o /boot/grub/grub.cfg && break
    done
  else
    pow -S efibootmgr || return
    cr grub-install --removable --target=x86_64-efi --efi-directory=/efi --bootloader-id=grub ||
      return
    cr grub-mkconfig -o /boot/grub/grub.cfg || return
  fi
}
do_step bootloader

users() {
  echo "set your root password:"
  while ! cr passwd; do :; done

  user="$ARTIX_USER"
  while [ ! "$user" ] || ! cr useradd -m "$user"; do
    echo "enter your username:"
    read -r user
  done

  cr usermod -a -G wheel,kvm "$user" || return

  echo "enter the password for ${user}:"
  while ! cr passwd "$user"; do :; done

  hostname="$ARTIX_HOSTNAME"
  while [ ! "$hostname" ]; do
    echo "enter your hostname:"
    read -r hostname
  done

  echo "$hostname" > /mnt/artix/etc/hostname
}
do_step users

user_config() {
  udo 'cat > ~/.vimrc' << "EOF"
set clipboard=unnamedplus
set shiftwidth=2
set smarttab
set tabstop=2
set autoindent
set nowrap
set noswapfile
set backup
set undofile
set relativenumber
set colorcolumn=100
set wildmenu
set path+=**
let g:netrw_liststyle=3
highlight LineNr ctermfg=darkgrey
highlight CursorLineNr ctermfg=grey
highlight Pmenu ctermbg=darkgrey
highlight PmenuSel ctermbg=grey ctermfg=black
highlight ColorColumn ctermbg=grey
syntax on

function NoTabs()
  set expandtab
  set softtabstop=0
  set listchars=tab:>~,nbsp:_,trail:.
  set list
endfunction

function Tabs()
  set noexpandtab
  set softtabstop=4
  set listchars=tab:\ \ ,nbsp:_,trail:.
  set list
endfunction

call NoTabs()

command! NoTabs call NoTabs()
command! Tabs call Tabs()
EOF

  udo 'cat > ~/.Xresources' << "EOF"
xterm*faceName: PxPlus IBM VGA8
xterm*faceNameDoublesize: Unifont
xterm*faceSize: 12
xterm*allowBoldFonts: false
xterm*background: grey
xterm*foreground: black
xterm*reverseVideo: true
xterm*termName: xterm-256color
xterm*VT100.Translations: #override \
  Shift <Key>Insert: insert-selection(CLIPBOARD) \n\
  Ctrl Shift <Key>V: insert-selection(CLIPBOARD) \n\
  Ctrl Shift <Key>C: copy-selection(CLIPBOARD)
EOF

  udo 'cat > ~/.xinitrc' << "EOF"
export QT_QPA_PLATFORMTHEME=qt5ct
export GTK2_RC_FILE="$HOME/.config/gtk-2.0/gtkrc-2.0"
export _JAVA_AWT_WM_NONREPARENTING=1 # for ghidra and other shitty java uis
export MANGOHUD=1
export EDITOR=vim
export BROWSER=brave
export TERMINAL=uxterm
export WINEPREFIX="$HOME/.cache/wine"

xset m 0 0                        # no mouse accel
xset r rate 200 60                # keyboard repeat rate
xset s off -dpms                  # no display blanking
picom &
parcellite &
dunst &
nitrogen --restore
xrdb ~/.Xresources
exec dwm
EOF
  chmod +x /mnt/artix/home/loli/.xinitrc || return

  udo 'curl -Ls https://raw.githubusercontent.com/jarun/nnn/master/plugins/getplugs | sh'
  udo 'mkdir -p ~/.config/service ~/.config/sv'
  udo 'cat > ~/.bashrc' << "EOF"
export NNN_PLUG='m:imgview;e:preview-tabbed;w:wall;y:.cbcp'
export NNN_FIFO=/tmp/nnn.fifo
export SVDIR="$HOME/.config/service"

# If not running interactively, don't do anything else
[[ $- != *i* ]] && return

source /usr/share/nnn/quitcd/quitcd.bash_zsh

set -o vi
bind '"\e[24~":"\C-un\n"'

alias mk='make clean && make'
alias mi='mk && sudo make install'

alias xi='trizen --movepkg --sync'
alias xr='trizen --remove --recursive'
alias xu='sudo pacman --noconfirm --sync --refresh && \
  sudo powerpill --noconfirm --sync --sysupgrade --sysupgrade && \
  trizen --noconfirm --sync --refresh --sysupgrade --sysupgrade && \
  sudo pacman --noconfirm --files --refresh'
alias xq='trizen --sync --search'
alias xl='trizen --query --quiet --explicit'
alias xf='trizen --files --regex'

alias pq='pacman --sync --search'

pkgs_by_date() {
  (awk -F: '
    BEGIN { OFS=FS }
    /^Name/ { name=$2 }
    /^Install Date/ {
      $1=""
      gsub(/^[: ]+/,"",$0)
      system("1>&2 printf \"%d packages scanned...\r\" " NR " && \
        echo $(date -d \"" $0 "\" --rfc-3339=seconds)" name)
    }
  ' && 1>&2 printf "\nsorting...\n") | sort -n
}

alias xla='trizen --query --info | pkgs_by_date'
alias xle='trizen --query --info --explicit | pkgs_by_date'
alias xls='trizen --query --info --explicit --unrequired | pkgs_by_date'

[ -n "$XTERM_VERSION" ] && transset-df --id "$WINDOWID" 0.9 >/dev/null
EOF
  udo 'chmod +x ~/.bashrc' || return

  udo 'mkdir -p ~/.config/picom' || return
  udo 'cat > ~/.config/picom/picom.conf' << "EOF"
unredir-if-possible = true
no-fading-openclose = true
shadow = true
shadow-exclude = [ "!focused" ]
EOF

  udo 'mkdir -p ~/.config/gtk-2.0'
  udo 'cat > ~/.config/gtk-2.0/gtkrc-2.0' << "EOF"
gtk-theme-name = "Adwaita-dark"
gtk-icon-theme-name = "Papirus-Dark"
EOF

  udo 'mkdir -p ~/.config/gtk-3.0'
  udo 'cat > ~/.config/gtk-3.0/settings.ini' << "EOF"
[Settings]
gtk-theme-name=Adwaita-dark
gtk-icon-theme-name=Papirus-Dark
EOF

  udo 'mkdir -p ~/.cache'
  curl https://reeee.ee/in4q90.png | udo 'cat > ~/.cache/wallpaper.png'
  udo 'mkdir -p ~/.config/nitrogen'
  user="$(cr id -un -- 1000)"
  udo 'cat > ~/.config/nitrogen/bg-saved.cfg' << EOF
[xin_-1]
file=/home/$user/.cache/wallpaper.png
mode=5
bgcolor=#000000
EOF

  udo 'mkdir -p ~/.config/qt5ct'
  udo 'cat > ~/.config/qt5ct/qt5ct.conf' << "EOF"
[Appearance]
color_scheme_path=/usr/share/qt5ct/colors/waves.conf
custom_palette=false
icon_theme=Papirus-Dark
standard_dialogs=gtk3
style=Adwaita-Dark

[Fonts]
fixed=@Variant(\0\0\0@\0\0\0\"\0H\0\x61\0\x63\0k\0 \0\x46\0\x43\0 \0L\0i\0g\0\x61\0t\0u\0r\0\x65\0\x64@$\0\0\0\0\0\0\xff\xff\xff\xff\x5\x1\0\x32\x10)
general=@Variant(\0\0\0@\0\0\0\x12\0N\0o\0t\0o\0 \0S\0\x61\0n\0s@$\0\0\0\0\0\0\xff\xff\xff\xff\x5\x1\0\x39\x10)

[Interface]
activate_item_on_single_click=1
buttonbox_layout=0
cursor_flash_time=1000
dialog_buttons_have_icons=1
double_click_interval=400
gui_effects=@Invalid()
keyboard_scheme=2
menus_have_icons=true
show_shortcuts_in_context_menus=true
stylesheets=@Invalid()
toolbutton_style=4
underline_shortcut=1
wheel_scroll_lines=3

[SettingsWindow]
geometry=@ByteArray(\x1\xd9\xd0\xcb\0\x3\0\0\0\0\0\x1e\0\0\0\x17\0\0\x4\xcf\0\0\x4-\0\0\0!\0\0\0\x1a\0\0\x4\xcc\0\0\x4*\0\0\0\0\0\0\0\0\a\x80\0\0\0!\0\0\0\x1a\0\0\x4\xcc\0\0\x4*)
EOF

  udo 'mkdir -p ~/.config/dunst'
  udo 'cat > ~/.config/dunst/dunstrc' << "EOF"
# TODO: make this config more compact
[global]
  monitor = 0
  follow = keyboard
  geometry = "300x5-30+20"
  indicate_hidden = yes
  shrink = no
  transparency = 0
  notification_height = 0
  separator_height = 1
  padding = 8
  horizontal_padding = 8
  frame_width = 2
  frame_color = "#bebebe"
  separator_color = frame
  sort = yes
  idle_threshold = 120
  font = PxPlus IBM VGA8
  line_height = 0
  markup = full
  format = "%s\n%b"
  alignment = left
  show_age_threshold = 60
  word_wrap = yes
  ellipsize = end
  ignore_newline = no
  stack_duplicates = true
  hide_duplicate_count = false
  show_indicators = yes
  icon_position = left
  max_icon_size = 32
  icon_path = /usr/share/icons/gnome/16x16/status/:/usr/share/icons/gnome/16x16/devices/
  sticky_history = yes
  history_length = 10000
  browser = /usr/bin/brave
  always_run_script = true
  title = Dunst
  class = Dunst
  startup_notification = false
  verbosity = mesg
  corner_radius = 0
  force_xinerama = false
  mouse_left_click = close_current
  mouse_middle_click = do_action
  mouse_right_click = close_all

[experimental]
  per_monitor_dpi = false

[shortcuts]
  close = ctrl+space
  close_all = ctrl+shift+space
  history = ctrl+grave
  context = ctrl+shift+period

[urgency_low]
  background = "#333333"
  foreground = "#bebebe"
  timeout = 5
  #icon = /path/to/icon

[urgency_normal]
  background = "#333333"
  foreground = "#bebebe"
  timeout = 10
  #icon = /path/to/icon

[urgency_critical]
  background = "#900000"
  foreground = "#ffffff"
  frame_color = "#ff0000"
  timeout = 0
  # Icon for notifications with critical urgency, uncomment to enable
  #icon = /path/to/icon

[fullscreen_show_critical]
  msg_urgency = critical
  fullscreen = show

# example of changing urgency and running extra scripts on matching notifs
#[mail]
#  summary = *mutt-wizard*
#  script = ~/bin/alert.sh
#  urgency = critical

# vim: ft=cfg
EOF
}
do_step user_config || return

makepkg_threads() {
  sed -i "s/^#MAKEFLAGS=.*/MAKEFLAGS=\"-j$(nproc)\"/" /mnt/artix/etc/makepkg.conf
}
do_step makepkg_threads

aur() {
  udo '
    rm -rf ~/trizen;
    git clone https://aur.archlinux.org/trizen.git ~/trizen &&
    cd ~/trizen &&
    makepkg -si --noconfirm &&
    cd &&
    rm -rf ~/trizen
  ' || return
}
do_step aur
do_step aur_packages

services() {
  sv_conf nodm << EOF
NODM_USER="$user"
NODM_XSESSION="/home/$user/.xinitrc"
EOF
  sv_enable nodm || return
  sv_enable xboxdrv || return
  sv_enable NetworkManager || return
  sv_enable sshd || return
}
do_step services

unmanaged() {
  curl -L 'https://github.com/pocketfood/Fontpkg-PxPlus_IBM_VGA8/raw/master/PxPlus_IBM_VGA8.ttf' \
    > /mnt/artix/usr/share/fonts/TTF/PxPlus_IBM_VGA8.ttf
  cr fc-cache -fv
  udo '
    mkdir -p ~/src &&
    rm -rf ~/src/dmenu && git clone https://github.com/Francesco149/dmenu ~/src/dmenu &&
    rm -rf ~/src/dwm && git clone https://github.com/Francesco149/dwm ~/src/dwm &&
    cd ~/src/dmenu && make && sudo make install &&
    cd ~/src/dwm && make && sudo make install
  ' || return
}
do_step unmanaged

makepkg_march() {
  sed -i "
    s/^C\(XX\)\{0,1\}FLAGS=.*/C\1FLAGS=\"-flto -march=native -mtune=native -O2 -pipe -fno-plt\"/;
  " /mnt/artix/etc/makepkg.conf
}
do_step makepkg_march

last_step

echo "
* you can chroot into the install to make any final adjustments with
  artools-chroot /mnt/artix

* the detected timezone is $(readlink /mnt/artix/etc/localtime) . if that's not correct, change it
  by running this from inside the chroot:

  ln -svf /usr/share/zoneinfo/Your/Timezone /etc/localtime
  hwclock --systohc

* sudo is configured to NOT ask for a password. if you don't like that, change or remove
  /mnt/artix/etc/sudoers.d/wheel-nopasswd

* nodm is configured to auto login without a password.if you don't like that, change or remove
  /mnt/artix/etc/pam.d/nodm

* sshd is enabled by default, remove /mnt/artix/etc/runit/runsvdir/default/sshd to disable it
* spectre/meltdown mitigations are disabled for performance, edit /mnt/artix/etc/default/grub to
  re-enable them if you wish

if you are making this install for a different machine that uses BIOS and it doesn't boot, you will
need to boot a live iso on the target machine, mount and chroot into the install and do

  mkinitcpio -P

once you're done, unmount with

  umount -R /mnt/artix

if you provided a cache, also do this:

  umount /var/cache/pacman/pkg/

and reboot into your brand new install
"
