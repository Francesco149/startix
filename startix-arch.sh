#!/bin/sh

grep -q "mirrorlist-arch" /etc/pacman.conf && echo 'already done' && exit 1
sudo pacman -S artix-archlinux-support  &&
sudo pacman --remove --recursive \
  bpytop-git maim-git nitrogen-git nnn-git nodm-dgw nodm-runit slop-git sxiv-git

sudo sh -c 'cat >> /etc/pacman.conf' << EOF

# arch repos

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

sudo pacman -Syu &&
sudo pacman -Sy bpytop maim nitrogen nnn nodm slop sxiv
trizen -Sy --noconfirm nodm-runit
