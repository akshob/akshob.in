---
layout: post
title:  "Using Network Namespaces to Isolate VPN Traffic"
date:   2026-01-02 16:30:00 -0000
categories: linux networking
---

> Disclaimer: This article is purely for educational purposes only. Use responsibly and in compliance with your local laws and terms of service.

## Introduction

This guide documents my experience setting up a robust network namespace solution for running Mullvad VPN and qBittorrent in complete isolation on Ubuntu 24.04.3 LTS. The goal was to ensure torrent traffic only uses the VPN while maintaining normal operation of other services like Pi-hole, PiVPN, Plex, Jellyfin, HomeAssistant, and HomeBridge.

Network namespaces provide a sophisticated way to isolate network traffic on Linux systems. Unlike simple VPN clients that affect the entire system, this approach creates a separate network environment where only designated applications use the VPN tunnel.

### Key Benefits

- **Complete traffic isolation**: Only qBittorrent uses the VPN
- **Automatic kill-switch**: If VPN fails, torrenting stops completely
- **No interference**: Existing services remain unaffected
- **Robust architecture**: Persists across reboots using systemd
- **Security**: Applications cannot escape the namespace

### Architecture Overview

The solution uses a three-tier systemd service architecture:

1. **Infrastructure Service** (`netns-vpn.service`): Creates the namespace, virtual interfaces, and networking
2. **VPN Service** (`openvpn-vpn.service`): Runs OpenVPN inside the namespace
3. **Application Service** (`qbittorrent-vpn.service`): Runs qBittorrent inside the namespace
4. **WebUI Forwarder** (`vpn-webui.service`): Provides access to qBittorrent's web interface

## Prerequisites

Before starting, ensure you have:

- Ubuntu 24.04.3 LTS Server (or similar systemd-based distribution)
- Root access to your system
- Basic understanding of networking concepts
- A Mullvad VPN subscription (or other OpenVPN-compatible provider)
- Existing services you want to protect (Pi-hole, Plex, etc.)

Install required packages:

```bash
sudo apt update
sudo apt install openvpn iproute2 qbittorrent-nox socat curl iptables
```

## Step 1: Network Infrastructure Service

The foundation service creates and manages the isolated network namespace. This service must be idempotent to handle restarts properly.

Create `/etc/systemd/system/netns-vpn.service`:

```ini
[Unit]
Description=VPN Network Namespace Setup
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
TimeoutStopSec=10

# Configuration Variables
Environment=NS_NAME=vpn-ns
Environment=VETH_HOST=veth-host
Environment=VETH_NS=veth-ns
Environment=IP_HOST=10.200.1.1/24
Environment=IP_NS=10.200.1.2/24
Environment=DNS_SERVER=1.1.1.1

# Clean slate logic (idempotency) - ignore failures with '-' prefix
ExecStartPre=-/usr/sbin/ip netns delete ${NS_NAME}
ExecStartPre=-/usr/sbin/ip link delete ${VETH_HOST}
ExecStartPre=-/usr/sbin/iptables -t nat -D POSTROUTING -s 10.200.1.0/24 -j MASQUERADE

# 1. Create Namespace
ExecStart=/usr/sbin/ip netns add ${NS_NAME}

# 2. Create Loopback (required for many apps)
ExecStart=/usr/sbin/ip netns exec ${NS_NAME} ip link set dev lo up

# 3. Create Virtual Ethernet Pair
ExecStart=/usr/sbin/ip link add ${VETH_HOST} type veth peer name ${VETH_NS}
ExecStart=/usr/sbin/ip link set ${VETH_NS} netns ${NS_NAME}

# 4. Assign IPs and Bring Up
ExecStart=/usr/sbin/ip addr add ${IP_HOST} dev ${VETH_HOST}
ExecStart=/usr/sbin/ip link set ${VETH_HOST} up
ExecStart=/usr/sbin/ip netns exec ${NS_NAME} ip addr add ${IP_NS} dev ${VETH_NS}
ExecStart=/usr/sbin/ip netns exec ${NS_NAME} ip link set ${VETH_NS} up

# 5. Enable Routing in Namespace (Default Gateway -> Host)
ExecStart=/usr/sbin/ip netns exec ${NS_NAME} ip route add default via 10.200.1.1

# 6. Enable NAT on Host (Allows namespace to reach internet via Host's connection)
ExecStart=/usr/sbin/iptables -t nat -A POSTROUTING -s 10.200.1.0/24 -j MASQUERADE
ExecStart=/usr/sbin/sysctl -w net.ipv4.ip_forward=1

# 7. DNS Setup for Namespace (Prevents leaks)
ExecStart=/bin/mkdir -p /etc/netns/${NS_NAME}
ExecStart=/bin/sh -c "echo 'nameserver ${DNS_SERVER}' > /etc/netns/${NS_NAME}/resolv.conf"

# CLEANUP (On Stop)
ExecStop=/usr/sbin/iptables -t nat -D POSTROUTING -s 10.200.1.0/24 -j MASQUERADE
ExecStop=/usr/sbin/ip link delete ${VETH_HOST}
ExecStop=/usr/sbin/ip netns del ${NS_NAME}

[Install]
WantedBy=multi-user.target
```

## Step 2: OpenVPN Configuration and Service

### Why Custom Services Are Necessary

⚠️ **Important**: Do NOT use the standard `openvpn@.service` systemd service. Ubuntu 24.04's default OpenVPN service includes security hardening that prevents it from accessing network namespaces, resulting in errors like:

```text
setting the network namespace "vpn-ns" failed: Operation not permitted
```

### Prepare Mullvad Configuration

Download your OpenVPN configuration from [Mullvad's configuration page](https://mullvad.net/en/account/openvpn-config?platform=linux):

```bash
# Extract and prepare configuration files
unzip mullvad_*.zip
sudo mkdir -p /etc/openvpn/client/
sudo mv mullvad_*.conf /etc/openvpn/client/mullvad.conf
sudo mv mullvad_ca.crt /etc/openvpn/client/
sudo mv mullvad_userpass.txt /etc/openvpn/client/
```

### Create Custom OpenVPN Service

Create `/etc/systemd/system/openvpn-vpn.service`:

```ini
[Unit]
Description=OpenVPN in Isolated Namespace
Requires=netns-vpn.service
After=netns-vpn.service

[Service]
Type=simple
TimeoutStopSec=15
KillMode=process

# Run OpenVPN inside the namespace - this bypasses systemd restrictions
ExecStart=/usr/sbin/ip netns exec vpn-ns /usr/sbin/openvpn --config /etc/openvpn/client/mullvad.conf --cd /etc/openvpn/client

# Kill Switch / Firewall (Inside Namespace Only)
# These rules ensure that if VPN fails, no traffic can escape
ExecStartPost=/usr/sbin/ip netns exec vpn-ns iptables -A OUTPUT -o lo -j ACCEPT
ExecStartPost=/usr/sbin/ip netns exec vpn-ns iptables -A OUTPUT -d 10.200.1.0/24 -j ACCEPT
ExecStartPost=/usr/sbin/ip netns exec vpn-ns iptables -A OUTPUT -o tun+ -j ACCEPT
ExecStartPost=/usr/sbin/ip netns exec vpn-ns iptables -A OUTPUT -p udp -j ACCEPT
ExecStartPost=/usr/sbin/ip netns exec vpn-ns iptables -A OUTPUT -p tcp -j ACCEPT
ExecStartPost=/usr/sbin/ip netns exec vpn-ns iptables -P OUTPUT DROP

Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
```

## Step 3: qBittorrent Service

### Handling User Permission Issues

The qBittorrent service must run as root initially to join the network namespace, since `ip netns exec` requires `CAP_SYS_ADMIN` capabilities. Attempting to run the service as a regular user will fail with `Operation not permitted`.

Create `/etc/systemd/system/qbittorrent-vpn.service`:

```ini
[Unit]
Description=qBittorrent in VPN Namespace
Requires=openvpn-vpn.service
After=openvpn-vpn.service

[Service]
Type=simple
TimeoutStopSec=15
KillMode=process

# Must run as root to join namespace
User=root
Group=root
UMask=007

# Run qBittorrent inside the namespace
ExecStart=/usr/sbin/ip netns exec vpn-ns /usr/bin/qbittorrent-nox --webui-port=8080

Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
```

### Alternative: Using a Dedicated User

If you prefer to run qBittorrent as a specific user, use a wrapper script:

```bash
sudo tee /usr/local/bin/qbittorrent-vpn-wrapper << 'EOF'
#!/bin/bash
exec /usr/sbin/ip netns exec vpn-ns /usr/bin/setpriv --reuid=qbittorrent --regid=datapool --init-groups /usr/bin/qbittorrent-nox --webui-port=8080
EOF

sudo chmod +x /usr/local/bin/qbittorrent-vpn-wrapper
```

Then modify the service to use the wrapper:

```ini
ExecStart=/usr/local/bin/qbittorrent-vpn-wrapper
```

## Step 4: WebUI Forwarder Service

Since qBittorrent runs in the isolated namespace (`10.200.1.2`), it's not directly accessible from your LAN. We use `socat` to forward traffic from the host to the namespace.

Create `/etc/systemd/system/vpn-webui.service`:

```ini
[Unit]
Description=WebUI Forwarder for VPN Namespace
Requires=netns-vpn.service
After=netns-vpn.service

[Service]
Type=simple
TimeoutStopSec=10

# Listen on Host:8080 and forward to Namespace:8080
ExecStart=/usr/bin/socat TCP-LISTEN:8080,fork,reuseaddr TCP:10.200.1.2:8080

Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
```

## DNS Configuration and Troubleshooting

### Common DNS Issues

You may encounter DNS resolution failures inside the namespace:

```text
sudo ip netns exec vpn-ns curl ifconfig.me
curl: (6) Could not resolve host: ifconfig.me
```

This happens when the namespace doesn't have proper DNS configuration.

### DNS Resolution Setup

The namespace uses `/etc/netns/vpn-ns/resolv.conf` for DNS. The infrastructure service creates this automatically, but you may need to adjust it:

```bash
# Check current DNS configuration
sudo cat /etc/netns/vpn-ns/resolv.conf

# Use Cloudflare DNS (reliable)
sudo mkdir -p /etc/netns/vpn-ns
echo 'nameserver 1.1.1.1' | sudo tee /etc/netns/vpn-ns/resolv.conf

# Alternative: Use Mullvad DNS (after VPN is connected)
# echo 'nameserver 100.64.0.7' | sudo tee /etc/netns/vpn-ns/resolv.conf
```

### Host DNS Changes

You may notice your host's `/etc/resolv.conf` changes when services start. This is normal behavior:

- Ubuntu 24.04 uses `systemd-resolved` which dynamically manages DNS
- VPN services can push their own DNS servers
- This doesn't affect the namespace, which has its own DNS configuration

## Deployment and Service Management

### Enable and Start Services

Deploy the services in dependency order:

```bash
# Reload systemd configuration
sudo systemctl daemon-reload

# Enable and start infrastructure
sudo systemctl enable --now netns-vpn.service

# Enable and start VPN
sudo systemctl enable --now openvpn-vpn.service

# Enable and start WebUI forwarder
sudo systemctl enable --now vpn-webui.service

# Enable and start qBittorrent
sudo systemctl enable --now qbittorrent-vpn.service
```

### Service Restart Issues and Solutions

⚠️ **Common Problem**: Service restarts may hang indefinitely due to systemd waiting for cleanup operations.

**Symptoms**:
```bash
sudo systemctl restart netns-vpn.service
# Hangs indefinitely, requiring Ctrl+C
```

**Causes**:
- Network interfaces stuck in use by running processes
- iptables rules blocking cleanup
- OpenVPN not shutting down cleanly

**Solutions**:

1. **Stop services in reverse dependency order**:
```bash
sudo systemctl stop qbittorrent-vpn.service
sudo systemctl stop vpn-webui.service
sudo systemctl stop openvpn-vpn.service
sudo systemctl stop netns-vpn.service
```

2. **Force stop if needed**:
```bash
sudo systemctl stop --force openvpn-vpn.service
sudo systemctl stop --force netns-vpn.service
```

3. **Manual cleanup if services are stuck**:
```bash
# Kill any remaining processes
sudo pkill -f qbittorrent-nox
sudo pkill -f openvpn
# Clean up namespace manually
sudo ip netns delete vpn-ns 2>/dev/null || true
sudo ip link delete veth-host 2>/dev/null || true
sudo iptables -t nat -D POSTROUTING -s 10.200.1.0/24 -j MASQUERADE 2>/dev/null || true
```

## Verification and Testing

### Test VPN Connectivity

Verify that the VPN is working inside the namespace:

```bash
# Check VPN connection
sudo ip netns exec vpn-ns curl https://am.i.mullvad.net/connected
# Should output: "You are connected to Mullvad (server xxx). Your IP address is xxx"

# Check IP addresses
echo "Host IP:" && curl -s ifconfig.me
echo "Namespace IP:" && sudo ip netns exec vpn-ns curl -s ifconfig.me
```

The two IP addresses should be different, confirming the VPN is working.

### Access qBittorrent WebUI

Open your browser and navigate to:
```
http://YOUR_SERVER_IP:8080
```

Default credentials are usually:
- Username: `admin`
- Password: `adminadmin`

### Configure qBittorrent for Maximum Security

In the WebUI, go to **Tools** → **Options** → **Advanced**:

1. **Network Interface**: Select `tun0` (VPN interface)
2. **Optional IP Address**: Select the VPN IP address (usually starts with 10.x.x.x)

This ensures qBittorrent can only communicate through the VPN tunnel.

## Troubleshooting Common Issues

### DNS Resolution Failures

**Problem**: `Could not resolve host` errors in namespace

**Solution**:
```bash
# Test DNS resolution
sudo ip netns exec vpn-ns nslookup google.com

# Fix DNS configuration
sudo mkdir -p /etc/netns/vpn-ns
echo 'nameserver 1.1.1.1' | sudo tee /etc/netns/vpn-ns/resolv.conf
sudo systemctl restart netns-vpn.service
```

### qBittorrent Won't Start

**Problem**: Service fails with exit code 255

**Root Cause**: qBittorrent may fail due to config directory permission issues or conflicts with existing configurations.

**Solution**:

1. **Create a dedicated home directory** (recommended approach):
```bash
# Create dedicated directory for qBittorrent
sudo mkdir -p /var/lib/qbittorrent/.config/qBittorrent
sudo mkdir -p /var/lib/qbittorrent/.local/share/qBittorrent
sudo chown -R qbittorrent:datapool /var/lib/qbittorrent
```

2. **Update the wrapper script to use the dedicated HOME**:
```bash
sudo tee /usr/local/bin/qbittorrent-vpn-wrapper << 'EOF'
#!/bin/bash
exec /usr/sbin/ip netns exec vpn-ns /usr/bin/setpriv \
  --reuid=qbittorrent --regid=datapool --init-groups \
  env HOME=/var/lib/qbittorrent \
  /usr/bin/qbittorrent-nox --webui-port=8080
EOF
# Change permissions
sudo chmod +x /usr/local/bin/qbittorrent-vpn-wrapper
```

3. **Alternative: Test manually first**:
```bash
# Test with dedicated HOME directory
sudo HOME=/var/lib/qbittorrent ip netns exec vpn-ns /usr/bin/qbittorrent-nox --webui-port=8080
# Or test as root (simpler but less secure)
sudo ip netns exec vpn-ns /usr/bin/qbittorrent-nox --webui-port=8080
```

This approach isolates qBittorrent's configuration from the root user's home directory and provides a clean, dedicated environment for the application.

### WebUI Not Accessible

**Problem**: Cannot access qBittorrent WebUI from browser

**Solutions**:
1. Check if forwarder service is running:
```bash
sudo systemctl status vpn-webui.service
```

2. Verify port isn't blocked by firewall:
```bash
sudo ufw allow 8080
```

3. Test connectivity:
```bash
# From the server
curl http://localhost:8080
```

### Services Hanging on Restart

**Problem**: `systemctl restart` commands hang

**Solution**: Use the stop/start sequence instead:
```bash
# Stop all related services
sudo systemctl stop qbittorrent-vpn.service vpn-webui.service openvpn-vpn.service netns-vpn.service

# Start them back up
sudo systemctl start netns-vpn.service openvpn-vpn.service vpn-webui.service qbittorrent-vpn.service
```

## Monitoring and Maintenance

### Check Service Status

```bash
# Check all VPN-related services
sudo systemctl status netns-vpn.service openvpn-vpn.service vpn-webui.service qbittorrent-vpn.service

# View logs
sudo journalctl -u openvpn-vpn.service -f
sudo journalctl -u qbittorrent-vpn.service -f
```

### Verify Kill Switch

Test that traffic doesn't leak when VPN fails:

```bash
# Stop VPN service
sudo systemctl stop openvpn-vpn.service

# This should fail (no internet access)
sudo ip netns exec vpn-ns curl ifconfig.me

# Restart VPN
sudo systemctl start openvpn-vpn.service
```

## Cleanup and Removal

To completely remove the setup:

```bash
# Stop all services
sudo systemctl stop qbittorrent-vpn.service vpn-webui.service openvpn-vpn.service netns-vpn.service

# Disable services
sudo systemctl disable qbittorrent-vpn.service vpn-webui.service openvpn-vpn.service netns-vpn.service

# Remove service files
sudo rm /etc/systemd/system/netns-vpn.service
sudo rm /etc/systemd/system/openvpn-vpn.service
sudo rm /etc/systemd/system/qbittorrent-vpn.service
sudo rm /etc/systemd/system/vpn-webui.service

# Remove configuration files
sudo rm -rf /etc/openvpn/client/mullvad*
sudo rm -rf /etc/netns/vpn-ns/
sudo rm -f /usr/local/bin/qbittorrent-vpn-wrapper

# Reload systemd
sudo systemctl daemon-reload
```

## Real-World Experience and Lessons Learned

This setup was tested on a production Ubuntu 24.04.3 LTS server running multiple services:

- **Pi-hole**: DNS filtering (unaffected by VPN setup)
- **PiVPN with WireGuard**: Remote access VPN (operates independently)
- **Plex and Jellyfin**: Media servers with port forwarding (unaffected)
- **HomeAssistant**: Home automation platform (operates independently)
- **HomeBridge**: HomeKit integration (operates independently)
- **qBittorrent**: Torrent client (isolated to VPN namespace)

### Infrastructure Consolidation

This network namespace approach enabled me to consolidate from a two-machine setup to a single server. Previously, I needed separate systems to isolate VPN traffic from other services. With network namespaces, I can safely run all services on one machine without compromising security or functionality. The complete isolation provided by namespaces means there's no risk of VPN traffic affecting critical services like Pi-hole or home automation systems.

### Key Insights

1. **Systemd Security Restrictions**: Modern Ubuntu's OpenVPN service hardening prevents namespace access, requiring custom services.

2. **DNS Complexity**: Network namespaces need careful DNS configuration to prevent resolution failures.

3. **Service Dependencies**: Proper ordering and cleanup are crucial for reliable operation.

4. **WebUI Access**: Accessing services in isolated namespaces requires forwarding solutions like `socat`.

### Performance Impact

- **Minimal overhead**: Network namespace isolation adds negligible performance impact
- **Complete isolation**: VPN failures don't affect other services
- **Robust operation**: Setup survives reboots and service restarts

## Security Considerations

This setup provides enterprise-grade security for home servers:

- **Complete traffic isolation**: Only torrent traffic uses VPN
- **Automatic kill-switch**: No traffic leaks if VPN fails
- **Zero impact on existing services**: Pi-hole, Plex, HomeAssistant, etc. operate normally
- **Persistent across reboots**: systemd ensures automatic startup

## Credits and References

- [Linux Network Namespaces](https://man7.org/linux/man-pages/man7/network_namespaces.7.html)
- [OpenVPN Documentation](https://openvpn.net/community-resources/reference-manual-for-openvpn-2-4/)
- [Mullvad VPN](https://mullvad.net/en/)
- [systemd.exec](https://www.freedesktop.org/software/systemd/man/systemd.exec.html)
- [Ubuntu 24.04 systemd-resolved](https://ubuntu.com/server/docs/network-configuration)
