# Dell SmartFabric OS10 Zero-Touch Deployment

Zero-touch deployment (ZTD) allows OS10 users to automate switch deployment:

- Upgrade an existing OS10 image.
- Execute a CLI batch file to configure the switch.
- Execute a post-ZTD script to perform additional functions.

ZTD is enabled by default when you boot up a switch with a factory-installed OS10 for the first time or when you perform an ONIE: OS Install from the ONIE boot menu. When a switch boots up with OS10 in ZTD mode, it starts the DHCP client on all interfaces -- management and front-panel ports. ZTD configures all interfaces for untagged VLAN traffic. The switch obtains an IP address and a ZTD provisioning script URL from a DHCP server running on the network, and downloads and executes the ZTD script.

> **NOTE:** Zero-touch deployment refers to an OS10 feature, and not the ONIE automated provisioning.

- ZTD is supported only in an IPv4 network. ZTD is not supported by DHCPv6.
- If the switch accesses the DHCP server using a front-panel port, the port interface must be in non-breakout mode.
- At least one of the front-panel ports connected to the network on which the DHCP server is running must be in non-breakout mode.
- After booting up in ZTD mode, if a switch receives no DHCP server response with option 240 within five minutes, it automatically exits ZTD mode. During this time, you can abort ZTD by entering the `ztd cancel` command. The command unlocks the switch configuration so that you can enter OS10 CLI commands.
- When ZTD is enabled, the CLI is locked so you cannot enter OS10 configuration commands. Only the show commands are available.
- The ZTD process does not time out and runs continuously. To stop the ZTD process, you must enter one of the following commands: `ztd-stop`, `ztd-cancel`, or `configure terminal`.

If you accidentally stop the ZTD process; for example, by entering Configuration mode, but have not made any configuration changes, use the `ztd start` command to start the ZTD process. This command does not reload the switch, but starts only the ZTD process.

> **NOTE:** On rare occasions, when you enter the `configure terminal` command, the system goes in to the CONFIGURATION Mode, but you will not be able to enter any configuration commands. An error similar to the following appears:
>
> ```
> % Error: config locked.
> ```
>
> To recover from this error, use the `ztd cancel` EXEC command to cancel the ZTD process.

According to the contents of the provisioning script, ZTD performs these tasks in the following sequence. Although Steps 2, 3 and 4 are optional, you must enter a valid URL path for at least one of the `IMG_FILE`, `CLI_CONFIG_FILE`, and `POST_SCRIPT_FILE` variables. For example, if you only want to configure the switch, enter only a `CLI_CONFIG_FILE` URL value. In this case, ZTD does not upgrade the OS10 image and does not execute a post-ZTD script.

1. ZTD downloads the files specified in the ZTD provisioning script -- OS10 image, CLI configuration batch file, and post-ZTD script.
   - In the provisioning script, enter the file names for the `IMG_FILE`, `CLI_CONFIG_FILE`, and `POST_SCRIPT_FILE` variables as shown in [ZTD provisioning script](#ztd-provisioning-script).
   - If no file names are specified, OS10 immediately exits ZTD and returns to CLI Configuration mode.
   - If the download of any of the specified files fails, ZTD stops. OS10 exits ZTD and unlocks CLI Configuration mode.
2. If you specify an OS10 image for `IMG_FILE`, ZTD installs the standby image. If you do not specify a configuration file for `CLI_CONFIG_FILE`, ZTD reloads the switch with the new OS10 image.
3. If you specify an OS10 CLI batch file with configuration commands for `CLI_CONFIG_FILE`, ZTD executes the commands in the PRE-CONFIG and POST-CONFIG sections. After executing the PRE-CONFIG commands, the switch reloads with the new OS10 image and then executes the POST-CONFIG commands. For more information, see [ZTD CLI batch file](#ztd-cli-batch-file).
4. If you specify a post-ZTD script file for `POST_SCRIPT_FILE`, ZTD executes the script. For more information, see [Post-ZTD script](#post-ztd-script).

> **NOTE:** The ZTD process performs a single switch reboot. The switch reboot occurs only if either a new OS10 image is installed or if the PRE-CONFIG section of the CLI batch file has configuration commands that are executed.

## ZTD Prerequisites

- Store the ZTD provisioning script on a server that supports HTTP connections.
- Store the OS10 image, CLI batch file, and post-ZTD script on a file server that supports either HTTP, FTP, SFTP, or TFTP connections.
- Configure the DHCP server to provide option 240 that returns the URL of the ZTD provisioning script.
- In the ZTD provisioning script, enter the URL locations of an OS10 image, CLI batch file, and/or post-ZTD script. Enter at least one URL, otherwise the ZTD fails and exits to CLI Configuration mode.

## ZTD Guidelines

- You can store the ZTD provisioning script, OS10 image, CLI batch file, and post-ZTD script on the same server, including the DHCP server.
- Write the ZTD provisioning script in bash.
- Write the post-ZTD script in bash or Python. Enter `#!/bin/bash` or `#!/usr/bin/python` as the first line in the script. The default python interpreter in OS10 is 2.7. Use only common Linux commands, such as `curl`, and common Python language constructs. OS10 only provides a limited set of Linux packages and Python libraries.

## Cancel ZTD in Progress

To exit ZTD mode and manually configure a switch by entering CLI commands, stop the ZTD process by entering the `ztd cancel` command. You can enter `ztd cancel` only when ZTD is in a waiting state; that is, before it receives an answer from the DHCP server. Otherwise, the command returns an error message; for example:

```
OS10# ztd cancel
% Error: ZTD cancel failed. ZTD process already started and cannot be cancelled at this
stage.
```

## Disable ZTD

To disable ZTD, enter the `reload` command. The switch reboots in ZTD disabled mode.

## Re-enable ZTD

To automatically upgrade OS10 and/or activate new configuration settings, re-enable ZTD by rebooting the switch using the `reload ztd` command. You are prompted to confirm the deletion of the startup configuration.

> **NOTE:** To upgrade OS10 without losing the startup configuration, back up the startup configuration before ZTD runs the provisioning script. Then use the backup startup configuration to restore the previous system configuration.

```
OS10# reload ztd
This action will remove startup-config [confirm yes/no]:
```

## View ZTD Status

```
OS10# show ztd-status
-----------------------------------
ZTD Status     : disabled
ZTD State      : completed
Protocol State : idle
Reason         : ZTD process completed successfully at Mon Jul 16 19:31:57 2018
-----------------------------------
```

## ZTD Logs

ZTD generates log messages about its current status.

```
[os10:notify], %Dell (OS10) %ZTD-IN-PROGRESS: Zero Touch Deployment
applying post configurations.
```

ZTD also generates failure messages.

```
[os10:notify], %Dell (OS10) %ZTD-FAILED: Zero Touch Deployment failed to
download the image.
```

## Troubleshoot Configuration Locked

When ZTD is enabled, the CLI configuration is locked. If you enter a CLI command, the error message `configuration is locked` displays. To configure the switch, disable ZTD by entering the `ztd cancel` command.

```
OS10# configure terminal
% Error: ZTD is in progress(configuration is locked).
OS10# ztd cancel
```

## ZTD DHCP Server Configuration

For ZTD operation, configure a DHCP server in the network by adding the required ZTD options; for example:

```
option domain-name "example.org";
option domain-name-servers ns1.example.org, ns2.example.org;
option ztd-provision-url code 240 = text;
default-lease-time 600;
max-lease-time 7200;
subnet 50.0.0.0 netmask 255.255.0.0 {
range 50.0.0.10 50.0.0.254;
option routers rtr-239-0-1.example.org, rtr-239-0-2.example.org;
}
host ztd-leaf1 {
hardware ethernet 90:b1:1c:f4:a9:b1;
fixed-address 50.0.0.8;
option ztd-provision-url "http://50.0.0.1/ztd.sh";
}
```

## ZTD Provisioning Script

Create a ZTD script file that you store on an HTTP server. Configure the URL of the script using DHCP option 240 (`ztd-provision-url`) on the DHCP server.

ZTD downloads and runs the script to upgrade the OS10 image, configure the switch, and run a post-ZTD script to perform other functions.

- Write the ZTD provisioning script in bash. Enter `#!/bin/bash` as the first line in the script. You can use the sample script in this section as a basis.
- For `IMG_FILE`, enter the URL path of the OS10 image to download and upgrade the switch. This image becomes the standby image.
- For `CLI_CONFIG_FILE`, enter the URL path of the CLI batch file to download and run.
- For `POST_SCRIPT_FILE`, enter the URL path of the script to run.
- ZTD requires all the ZTD scripts (provisioning, CLI batch file, and post-ZTD script) to be Unix-style line formatted.
- ZTD fails and exits to CLI Configuration mode if:
  - You do not specify at least one valid URL for the `IMG_FILE`, `CLI_CONFIG_FILE`, and `POST_SCRIPT_FILE` variables.
  - Any of the `IMG_FILE`, `CLI_CONFIG_FILE`, and `POST_SCRIPT_FILE` entries are invalid or if specified, the files cannot be downloaded.

For the `IMG_FILE`, `CLI_CONFIG_FILE`, and `POST_SCRIPT_FILE` files, you can specify HTTP, SCP, SFTP, or TFTP URLs. For example:

```
scp://userid:passwd@hostip/filepath
sftp://userid:passwd@hostip/filepath
```

### Example

```bash
#!/bin/bash
####################################################################
#
#
#            Example OS10 ZTD Provisioning Script
#
#
####################################################################
########## UPDATE THE BELOW CONFIG VARIABLES ACCORDINGLY ###########
########## ATLEAST ONE OF THEM SHOULD BE FILLED ####################
IMG_FILE="http://50.0.0.1/OS10.bin"
CLI_CONFIG_FILE="http://50.0.0.1/cli_config"
POST_SCRIPT_FILE="http://50.0.0.1/no_post_script.py"
################### DO NOT MODIFY THE LINES BELOW #######################
sudo os10_ztd_start.sh "$IMG_FILE" "$CLI_CONFIG_FILE" "$POST_SCRIPT_FILE"
########################      **END**     ###############################
```

## ZTD CLI Batch File

Create a CLI batch file that ZTD downloads and executes to configure a switch. The ZTD CLI batch file consists of two sections: PRE-CONFIG and POST-CONFIG.

When you enter the PRE-CONFIG and POST-CONFIG lines, you must enter a hash tag (`#`), followed by a space before the text PRE-CONFIG or POST-CONFIG. If the PRE-CONFIG section has no commands, do not leave a blank line between `# PRE-CONFIG` and `# POST-CONFIG`; for example:

```
# PRE-CONFIG
# POST-CONFIG
Hostname VxRail-fabric-LEAF-1
!
lldp enable
!
spanning-tree mode rstp
spanning-tree rstp priority 0
...
```

ZTD executes the PRE-CONFIG commands first using the currently running OS10 image, not the OS10 image specified in the provisioning script. ZTD saves the PRE-CONFIG settings to the startup configuration.

If PRE-CONFIG commands are present, ZTD reloads the switch before executing the commands in the POST-CONFIG section. Enter OS10 configuration commands that require a switch reload, such as `switch-port-profile`, in the PRE-CONFIG section. If ZTD installs a new OS10 image (`IMG_FILE`), the new image is activated after the reload.

ZTD then executes the POST-CONFIG commands and saves the new settings in the startup configuration. No additional switch reload is performed. Enter POST-CONFIG commands with the exact syntax displayed in `show running-configuration` output.

### Example

```
# PRE-CONFIG
switch-port-profile 1/1 profile-2
# POST-CONFIG
snmp-server community public ro
snmp-server contact NOC@dell.com
snmp-server location delltechworld
!
clock timezone GMT 0 0
!
hostname LEAF-1
!
ip domain-list networks.dell.com
ip name-server 192.0.2.8 192.0.2.1
!
ntp server 132.163.96.5 key 1 prefer
ntp server 129.6.15.32
!
!
logging server 10.22.0.99
```

## Post-ZTD Script

As a general guideline, use a post-ZTD script to perform any additional functions required to configure and operate the switch. In the ZTD provisioning script, specify the post-ZTD script path for the `POST_SCRIPT_FILE` variable. You can use a script to notify an orchestration server that the ZTD configuration is complete. The server can then configure additional settings on the switch.

For example, during the ZTD phase, you can configure only a management VLAN and IP address, then allow an Ansible orchestration server to perform complete switch configuration. Here is a sample curl script that is included in the post-ZTD script to contact an Ansible server:

```
/usr/bin/curl -H "Content-Type:application/json" -k -X POST \
--data '{"host_config_key":"'7d07e79ebdc8f7c292e495daac0fe16b'"}' \
-u admin:admin https://10.16.134.116/api/v2/job_templates/9/callback/
```

## ZTD Commands

### reload ztd

Reboots the switch and enables ZTD after the reload.

**Syntax**

```
reload ztd
```

| Parameter | Description |
|---|---|
| **Parameters** | None |
| **Default** | ZTD is enabled. |
| **Command Mode** | EXEC |

**Usage Information**

Use the `reload ztd` command to automatically upgrade OS10 and/or activate new configuration settings. When you reload ZTD, you are prompted to confirm the deletion of the startup configuration.

**Example**

```
OS10# reload ztd
```

**Supported Releases:** 10.4.1.0 or later

---

### show ztd-status

Displays the current ZTD status: enabled, disabled, or canceled.

**Syntax**

```
show ztd-status
```

| Parameter | Description |
|---|---|
| **Parameters** | None |
| **Default** | None |
| **Command Mode** | EXEC |

**Usage Information**

None

**Examples**

```
OS10# show ztd-status
-----------------------------------
ZTD Status     : disabled
ZTD State      : completed
Protocol State : idle
Reason         : ZTD process completed successfully at Mon Jul 16
19:31:57 2018
-----------------------------------
```

```
OS10# show ztd-status
-----------------------------------
ZTD Status     : disabled
ZTD State      : failed
Protocol State : idle
Reason         : ZTD process failed to download post script file
-----------------------------------
```

**Field Descriptions:**

- **ZTD Status** -- Current operational status: enabled or disabled.
- **ZTD State** -- Current ZTD state: initialized, in-progress, successfully completed, failed, or canceled while in progress.
- **Protocol State** -- Current state of ZTD protocol: initialized, idle while waiting to enable or complete ZTD process, waiting for DHCP post-hook callback, downloading files, installing image, executing pre-config or post-config CLI commands, or executing post-ZTD script file.
- **Reason** -- Description of a successful or failed ZTD process.

**Supported Releases:** 10.4.1.0 or later

---

### ztd cancel

Stops ZTD while in progress.

**Syntax**

```
ztd cancel
```

| Parameter | Description |
|---|---|
| **Parameters** | None |
| **Default** | ZTD is enabled. |
| **Command Mode** | EXEC |

**Usage Information**

After you cancel ZTD, you can enter CLI commands to configure the switch. The system cancels the ZTD process when you enter CLI Configuration mode. You can enter this command only when ZTD is in a waiting state; that is, before it receives an answer from the DHCP server. Otherwise, the command returns an error message. The `ztd stop` and `ztd cancel` commands perform the same function.

**Example**

```
OS10# ztd cancel
```

**Supported Releases:** 10.4.1.0 or later

---

### ztd start

Starts the ZTD process.

**Syntax**

```
ztd start
```

| Parameter | Description |
|---|---|
| **Parameters** | None |
| **Default** | Not configured |
| **Command Mode** | EXEC |
| **Security and Access** | Sysadmin and secadmin |

**Usage Information**

When you enter this command, if there are any configuration changes, the system prompts you for a confirmation to delete the startup configuration. If you have made configuration changes after the ZTD process stops, the system reloads. This command is similar to the `reload ztd` command. However, if you have not made any configuration changes after the ZTD process stops, this command does not reload the switch. It starts only the ZTD process.

**Example**

```
OS10# ztd start
```

**Supported Releases:** 10.5.2.0 or later

---

### ztd stop

Stops ZTD while in progress.

**Syntax**

```
ztd stop
```

| Parameter | Description |
|---|---|
| **Parameters** | None |
| **Default** | Not configured |
| **Command Mode** | EXEC |
| **Security and Access** | sysadmin and secadmin |

**Usage Information**

The system cancels the ZTD process when you enter CLI Configuration mode. The `ztd stop` and `ztd cancel` commands perform the same function. Use this command only when ZTD is in a waiting state; that is, before it receives an answer from the DHCP server. Otherwise, the command returns an error message.

**Example**

```
OS10# ztd stop
```

**Supported Releases:** 10.5.2.0 or later
