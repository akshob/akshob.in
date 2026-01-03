---
layout: post
title:  "Headless Machine"
date:   2023-01-23 16:30:00 -0000
categories: linux
---
Headless machines refer to computers or servers that operate without a graphical user interface (GUI) or a monitor attached to them. These machines are typically managed remotely through command-line interfaces, web-based control panels, or specialized software applications.

I always like setting up all my machines as a headless machines and remote into them via `ssh` or `VNC`.

> If you're connecting to a Mac which is setup as a headless machine, the resolution is not great. Use a HDMI dummy plug (such as [this](https://www.adafruit.com/product/4247)) to force the Mac to think it is connected to a display.

## Picking a Distro

The main question is, which linux distro do you choose? There are so many of them. Just searching for "minimal linux distro" gives you tons of options.

I went with `Ubuntu Server`. It gives me the flexibility of making the server minimal or bulky depending on my needs. I've used `Ubuntu`, almost all packages support `Ubuntu`, and I like the `aptitude` package manager.

## How to install

- Pick a USB which is at least 4GB
- Download the server from [ubuntu downloads](https://ubuntu.com/download/server)
- Download [Etcher](https://www.balena.io/etcher) which is used to flash the OS image into the USB
- Flash Ubuntu Server image into the USB.

Now you have a live ubuntu server USB. For the first time setup, you will need to connect the machine to a monitor (only for setup), ethernet cable (wifi is not detected correctly for Mac hardware), wired keyboard.

- Plug in the live USB and boot into it (depending on the hardware it would be pressing different keys on the keyboard. For a Mac with intel chip, press and hold the Option (Alt) key on the keyboard when the machine starts)
- Go through the installation process (make sure you setup and enable SSH server)

Now you can keep the machine anywhere with a wired connection, and `ssh` into it to manage!
