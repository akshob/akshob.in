---
layout: post
title:  "Ubuntu Server - Tools"
date:   2023-01-25 16:30:00 -0000
categories: linux
---
If you've already setup a headless machine, follow this guide to make it more useful.

## Install essential packages

```bash
sudo apt-get install net-tools # ifconfig
sudo apt-get install hfsprogs # hfs+ support
```

## Setup `datapool`

If you have a few users that you want to share access to files then you need to make sure that they are all part of a single group and that the files in question are owned by said group. This is where the `datapool` group comes in. Create a group called `datapool` and add all the users that need access to the group. Then create a directory for each drive and set the group to `datapool`. Finally, add the current user to the `datapool` group.

```bash
sudo groupadd datapool

sudo mkdir /mnt/blackbear
sudo mkdir /mnt/cupcake
sudo mkdir /mnt/icecream
sudo mkdir /mnt/milkshake

sudo chgrp datapool /mnt/blackbear
sudo chgrp datapool /mnt/cupcake
sudo chgrp datapool /mnt/icecream
sudo chgrp datapool /mnt/milkshake

sudo chmod u+rwx,g+srwx,o-rwx /mnt/cupcake

sudo usermod -aG datapool $USER
```

For existing files, use the following command to change the group:

```bash
sudo chown -fR $USER:datapool /mnt/cupcake
find /mnt/cupcake -type f -exec chmod -fR u+rw-x,g+rw-x,o-rwx "{}" \;
find /mnt/cupcake -type d -exec chmod -fR u+rwx,g+srwx,o-rwx "{}" \;
```

## Configure FSTAB

The configuration file `/etc/fstab` contains the necessary information to automate the process of mounting partitions. In a nutshell, mounting is the process where a raw (physical) partition is prepared for access and assigned a location on the file system tree (or mount point). [More details](https://help.ubuntu.com/community/Fstab#Introduction%20to%20fstab)

To find the UUID of a drive, use the command: `sudo blkid`
To find the GID of a group, use the command: `id -g datapool` or `getent group datapool`

Mounting NTFS drives:

```bash
/dev/disk/by-uuid/A880F2E880F2BC3E /mnt/blackbear ntfs-3g defaults,uid=1000,gid=1001,umask=0007 0 1
```

Mounting HFS+ drives:

```bash
/dev/disk/by-uuid/9502f47e-8ff0-3608-9aab-a386d948e90d /mnt/icecream hfsplus defaults,uid=1000,gid=1001,umask=0007 0 1
/dev/disk/by-uuid/284a03a8-7fb4-3f57-821b-9f63a2b05d9b /mnt/cupcake hfsplus defaults,uid=1000,gid=1001,umask=0007 0 1
/dev/disk/by-uuid/2a1c3acd-f9bc-33a2-bf04-9db72f5162b9 /mnt/milkshake hfsplus defaults,uid=1000,gid=1001,umask=0007 0 1
```

> Pro Tip: To test fstab without rebooting, use the command: `sudo mount -a`

Sometimes HFS+ filesystems are mounted as read-only, probably due to a recent power failure.
Checking `sudo dmesg` you will see: `hfsplus: Filesystem was not cleanly unmounted, running fsck.hfsplus is recommended.  mounting read-only.`
Unmounting the drive, running `sudo fsck.hfsplus /dev/sdXX` to reset a flag, and afterward `sudo mount -a` re-mounted the drive read-write, per the configuration in `/etc/fstab`.

## Plex Media Server

```bash
curl https://downloads.plex.tv/plex-keys/PlexSign.key | gpg --dearmor | sudo tee /usr/share/keyrings/plex-archive-keyring.gpg >/dev/null
echo deb [signed-by=/usr/share/keyrings/plex-archive-keyring.gpg] https://downloads.plex.tv/repo/deb public main | sudo tee /etc/apt/sources.list.d/plexmediaserver.list
sudo apt-get update
sudo apt install plexmediaserver
```

To connect to the browser, enter the IP followed by the port `32400` and `/web/`. For example: `192.168.0.101:32400/web/`

Add plex user to the `datapool` group to access shared files:

```bash
sudo usermod -aG datapool plex
```

## qbittorrent

> Disclaimer: This section is purely for educational purposes only. I do not condone piracy.

Install qbittorrent for headless environments:

```bash
sudo apt install qbittorrent-nox
```

Create a user for qbittorrent:

```bash
sudo useradd -r -m qbittorrent
```

Add qbittorrent to the `datapool` group to access shared files:

```bash
sudo usermod -aG datapool qbittorrent
```

Create a systemd service file:

```bash
sudo vi /etc/systemd/system/qbittorrent.service
```

Add the following:

```bash
[Unit]
Description=qBittorrent
After=network.target

[Service]
Type=forking
User=qbittorrent
Group=datapool
UMask=007
ExecStart=/usr/bin/qbittorrent-nox -d --webui-port=8080
Restart=on-failure

[Install]
WantedBy=multi-user.target
```

Start the service and check the status:

```bash
sudo systemctl start qbittorrent
sudo systemctl status qbittorrent
```

Enable the service:

```bash
sudo systemctl enable qbittorrent
```

Access the web interface via `http://[YOUR IP ADDRESS]:8080`. The default username for this interface is `admin`, and the default password is `adminadmin`. You can change these settings by clicking on the "Tools" menu and selecting "Options". From there, click on "Web UI" in the sidebar. You can change the username and password from there. You can whitelist your local subnet by selecting "Bypass authentication for clients in whitelisted IP subnets". Whitelist local subnet `192.168.x.0/24`

> Logs: `sudo less /home/qbittorrent/.local/share/qBittorrent/logs/qbittorrent.log`

> Fixing samba share issues: https://forum.qbittorrent.org/viewtopic.php?p=43380

## X11

Install [XQuartz](https://www.xquartz.org/) on macOS to get X11 forwarding to work via `ssh`.

```bash
sudo apt-get install -y mesa-utils libgl1-mesa-dri
sudo apt-get install -y xdg-utils
```
