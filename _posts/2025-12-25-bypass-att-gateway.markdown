---
layout: post
title:  "Bypassing AT&T Fiber Gateway with UniFi UCG Max"
date:   2025-12-25 16:30:00 -0000
categories: networking unifi att
---

AT&T Fiber requires their residential gateway (BGW210, BGW320) to authenticate to their network using 802.1X EAP-TLS certificates. While AT&T offers an "IP Passthrough" mode that can help reduce double-NAT issues, you're still limited by the gateway's NAT table size and have an extra hop in your network. This guide shows how to completely bypass the AT&T gateway using a UniFi UCG Max router with `wpa_supplicant`.

> **Warning**: This process involves extracting certificates from AT&T hardware and configuring advanced networking features. Proceed at your own risk and ensure you have a way to revert changes if needed.

## Understanding AT&T Fiber Authentication

AT&T Fiber uses 802.1X authentication with mutual TLS (mTLS) certificates to authenticate customer gateways. The authentication process requires three components:

1. **Supplicant/Client**: The AT&T gateway (BGW210, BGW320)
2. **Controller**: Handles access control before and after authentication
3. **RADIUS Server**: AT&T's authentication server that validates certificates

The key insight is that if we can extract the valid certificates from an AT&T gateway, we can use `wpa_supplicant` on any device to authenticate directly with AT&T's network.

## Prerequisites

Before starting, you'll need:

- An AT&T gateway (BGW210 or BGW320) for certificate extraction
- UniFi UCG Max router
- Basic knowledge of SSH and terminal commands
- Patience for the certificate extraction process

## Step 1: Extract Certificates from AT&T Gateway

The certificate extraction process uses the automated script from the [0x888e/certs](https://github.com/0x888e/certs) repository for BGW210/BGW320 gateways.

> **Important**: The original AT&T firmware download links referenced in the 0x888e/certs repository are no longer accessible. The required firmware files can be downloaded from [here](https://mega.nz/folder/iY4k1boB#YxEuPXHHPuT5IzoUQaT-LA) or [here](https://z.blueion.dev/folder/cmfvxq9iu006401mx7jlyvjxn).

### Certificate Extraction Process

> **Note**: This process has been tested and verified working on BGW210. BGW320 should work similarly but has not been personally tested.

1. **Prepare the gateway**: Downgrade to firmware version 3.18.2
2. **Physical setup**:
   - Connect your computer directly to LAN1 on the BGW
   - Unplug any ONT/SFP connections (only power and your computer should be connected)
   - Configure your NIC with static IP: 192.168.1.11, gateway: 192.168.1.254
3. **Run the extraction script**:

   ```bash
   git clone https://github.com/0x888e/certs.git
   cd certs
   python download.py
   ```

4. **Follow the prompts** and let the script automatically extract the certificate data

> **Important Gotcha**: When the script instructs you to restart the gateway, use the web interface restart option, not the physical power button. Log into the router at 192.168.1.254 and restart from there. This is crucial for the timing of the extraction process.

### Cleanup: Upgrade to Current Firmware

After successfully extracting the certificates, upgrade your BGW210 back to a current firmware version:

1. **Download the latest firmware** (4.28.6 did not work for me but 4.26.11 did)
2. **Flash the firmware** using the same web interface process (Diagnostics → Update)
3. **Wait for completion** and automatic reboot

This ensures your gateway is running current firmware with all security updates while you proceed with the UniFi configuration.

## Step 2: Convert Certificates

After extracting the raw certificate data, convert it to `wpa_supplicant` compatible format using the `mfg_dat_decode` tool:

1. **Download mfg_dat_decode** from [devicelocksmith.com](https://www.devicelocksmith.com/2018/12/eap-tls-credentials-decoder-for-nvg-and.html)
2. **Extract and run the tool**:

   ```bash
   # Navigate to the folder containing your extracted certificates
   cd ./certs  # or wherever you have mfg.dat and other cert files
   
   # Extract the mfg_dat_decode tool directly here
   tar xzvf mfg_dat_decode_1_04.tar.gz 
   
   # Make the tool executable
   chmod +x mfg_dat_decode
   
   # Run the conversion tool
   ./mfg_dat_decode
   ```

This will generate an output file like `./certs/EAP-TLS_8021x_XXXXX-XXXXXXXX.tar.gz` containing the necessary `.pem` files and `wpa_supplicant.conf` configuration.

## Step 3: Configure UniFi UCG Max

### Enable SSH Access

Before configuring the UCG Max, you need to enable SSH access:

1. Open the UniFi Network console
2. Navigate to **Settings** → **System** → **Console** (path may vary by router model and firmware version)
3. Enable **SSH** access
4. Set a secure password if prompted
5. Apply the changes

> **Note**: The exact path to SSH settings may differ depending on your UCG Max firmware version. Look for "Console", "SSH", or "Device Authentication" settings in the System or Advanced sections.

### Install wpa_supplicant

SSH into your UCG Max:

```bash
ssh root@<UCG_MAX_IP>

# Update package list and install
apt update -y
apt install -y wpasupplicant

# Create directory for certificates
mkdir -p /etc/wpa_supplicant/certs
```

> **UCG Max Specific Note**: The UCG Max uses `eth4` as the WAN interface. This is different from other UniFi gateways, so make sure to use the correct interface name in all commands.

### Copy Certificates and Configuration

From your computer, copy the extracted certificate files to the UCG Max:

```bash
# Copy certificate files
scp *.pem root@<UCG_MAX_IP>:/etc/wpa_supplicant/certs/

# Copy configuration file
scp wpa_supplicant.conf root@<UCG_MAX_IP>:/etc/wpa_supplicant/
```

### Update Configuration Paths

On the UCG Max, update the certificate paths in the configuration:

```bash
# Update paths in wpa_supplicant.conf
sed -i 's,ca_cert=",ca_cert="/etc/wpa_supplicant/certs/,g' /etc/wpa_supplicant/wpa_supplicant.conf
sed -i 's,client_cert=",client_cert="/etc/wpa_supplicant/certs/,g' /etc/wpa_supplicant/wpa_supplicant.conf
sed -i 's,private_key=",private_key="/etc/wpa_supplicant/certs/,g' /etc/wpa_supplicant/wpa_supplicant.conf
```

## Step 4: Configure UniFi Network Settings

### Set VLAN ID for WAN

In the UniFi Network console:

1. Go to **Settings** → **Internet** → **Primary (WAN1)**
2. Enable **VLAN ID** and set it to `0`
3. **Apply** the changes

> **Note**: This change will temporarily break internet connectivity until `wpa_supplicant` is running.

### Spoof MAC Address

The MAC address in your `wpa_supplicant.conf` must match the WAN interface:

1. In UniFi console: **Settings** → **Internet** → WAN settings
2. Enable **MAC Address Clone**
3. Enter the MAC address from your `wpa_supplicant.conf` file

## Step 5: Test wpa_supplicant

### Initial Test

Connect your ONT cable to the UCG Max WAN port and test authentication:

```bash
# Test wpa_supplicant (use eth4 for UCG Max)
wpa_supplicant -i eth4 -D wired -c /etc/wpa_supplicant/wpa_supplicant.conf
```

> **Critical Gotcha for UCG Max**: Make sure you're using `eth4` for the interface parameter (`-i eth4`). The UCG Max WAN port maps to `eth4`, not `eth1` like some other UniFi devices. This is specified in the documentation but easy to miss.

Look for these success messages:

```text
Successfully initialized wpa_supplicant
eth4: CTRL-EVENT-EAP-SUCCESS EAP authentication completed successfully
eth4: CTRL-EVENT-CONNECTED - Connection to XX:XX:XX:XX:XX:XX completed
```

If successful, press `Ctrl+C` to stop the test.

## Step 6: Configure Automatic Startup

### Create systemd Service

Rename the configuration file to match the systemd service pattern:

```bash
cd /etc/wpa_supplicant
mv wpa_supplicant.conf wpa_supplicant-wired-eth4.conf
```

### Enable and Start Service

```bash
# Start the service
systemctl start wpa_supplicant-wired@eth4

# Check status
systemctl status wpa_supplicant-wired@eth4

# Enable for automatic startup
systemctl enable wpa_supplicant-wired@eth4
```

### Add Failure Recovery

Create failure tolerance configuration:

```bash
mkdir -p /etc/systemd/system/wpa_supplicant-wired@.service.d/

cat > /etc/systemd/system/wpa_supplicant-wired@.service.d/restart-on-failure.conf << EOF
[Unit]
# Allow up to 10 attempts within a 3 minute window
StartLimitIntervalSec=180
StartLimitBurst=10

[Service]
# Enable restarting on failure
Restart=on-failure
# Wait 10 seconds between restart attempts
RestartSec=10
EOF

# Reload systemd configuration
systemctl daemon-reload
systemctl restart wpa_supplicant-wired@eth4.service
```

## Step 7: Survive Firmware Updates

UniFi firmware updates will remove the `wpasupplicant` package. Create an automatic reinstallation service:

### Download Required Packages

```bash
mkdir -p /etc/wpa_supplicant/packages
cd /etc/wpa_supplicant/packages

# Download packages (URLs may change - check for latest versions)
wget http://security.debian.org/debian-security/pool/updates/main/w/wpa/wpasupplicant_2.9.0-21+deb11u3_arm64.deb
wget http://ftp.us.debian.org/debian/pool/main/p/pcsc-lite/libpcsclite1_1.9.1-1_arm64.deb
```

### Create Reinstallation Service

```bash
cat > /etc/systemd/system/reinstall-wpa.service << EOF
[Unit]
Description=Reinstall and start/enable wpa_supplicant
AssertPathExistsGlob=/etc/wpa_supplicant/packages/wpasupplicant*arm64.deb
AssertPathExistsGlob=/etc/wpa_supplicant/packages/libpcsclite1*arm64.deb
ConditionPathExists=!/sbin/wpa_supplicant

After=network-online.target
Requires=network-online.target

# Allow up to 10 attempts within ~300 seconds
StartLimitIntervalSec=300
StartLimitBurst=10

[Service]
Type=oneshot
ExecStartPre=/usr/bin/dpkg -Ri /etc/wpa_supplicant/packages
ExecStart=/bin/systemctl start wpa_supplicant-wired@eth4
ExecStartPost=/bin/systemctl enable wpa_supplicant-wired@eth4

Restart=on-failure
RestartSec=20

[Install]
WantedBy=multi-user.target
EOF

# Enable the service
systemctl daemon-reload
systemctl enable reinstall-wpa.service
```

## Troubleshooting

### Common Issues

1. **Authentication fails**:
   - Verify MAC address spoofing is working: `ip link show eth4`
   - Check certificate file paths in `wpa_supplicant.conf`
   - Ensure VLAN 0 is configured on WAN

2. **Wrong interface errors**:
   - Double-check you're using `eth4` for UCG Max
   - Use `ip link show` to verify interface names

3. **Service fails to start after reboot**:
   - Check if `wpa_supplicant` package was removed: `which wpa_supplicant`
   - Verify the reinstall service is enabled: `systemctl status reinstall-wpa`

### Useful Commands

```bash
# Check wpa_supplicant logs
journalctl -u wpa_supplicant-wired@eth4.service -f

# Test configuration manually
wpa_supplicant -i eth4 -D wired -c /etc/wpa_supplicant/wpa_supplicant-wired-eth4.conf -d

# Check interface status
ip link show eth4

# Verify MAC address
cat /sys/class/net/eth4/address
```

## Conclusion

Successfully bypassing the AT&T gateway with a UniFi UCG Max provides several benefits:

- **Eliminates double NAT** issues
- **Reduces network latency** by removing an extra hop
- **Improves network reliability** with enterprise-grade UniFi hardware
- **Provides better control** over your network configuration

The key gotchas specific to this setup are:

1. **Restart the gateway via web interface** during certificate extraction, not the power button
2. **Use `eth4` interface** for UCG Max, not `eth1` or other interfaces mentioned in generic guides
3. **Be patient** with the certificate extraction process - it may take several attempts

This setup has been tested and works reliably with the UCG Max. The automatic recovery mechanisms ensure that firmware updates won't break your internet connection permanently.

## References

- [Jim Angel's comprehensive bypass guide](https://www.jimangel.io/posts/bypassing-att-fiber-gateway-on-udmp/)
- [Certificate extraction tool](https://github.com/0x888e/certs)
- [UniFi gateway wpa_supplicant setup guide](https://github.com/evie-lau/Unifi-gateway-wpa-supplicant)
- [mfg_dat_decode certificate conversion tool](https://www.devicelocksmith.com/2018/12/eap-tls-credentials-decoder-for-nvg-and.html)
