Arch Linux Eyun Community Repository
====

### Usage

(1) Add repo:

```
[eyun]
SigLevel = Never
Server = https://mirrors.eyun.cf/archlinux/$arch/$repo
```
to your /etc/pacman.conf .

(2) Import PGP Keys:
```
sudo pacman -Syy && sudo pacman -S eyun-keyring
```

(3) Remove 'SigLevel' or change it to other value
```
sudo sed -i -r '/^\[eyun]/,/^\[\w+]/{/^SigLevel\s*=.*/d}' /etc/pacman.conf
```
