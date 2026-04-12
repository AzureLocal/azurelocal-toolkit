# CLI Basics

The OS10 CLI is the software interface you use to access a device running the software -- from the console or through a network connection. The CLI is an OS10-specific command shell that runs on top of a Linux-based OS kernel. By leveraging industry-standard tools and utilities, the CLI provides a powerful set of commands that you can use to monitor and configure devices running OS10.

## User accounts

OS10 defines two categories of user accounts:

- To log in to the CLI, use `admin` for the user name and password.
- To log in to the Linux shell, use `linuxadmin` for the user name and password.

> **NOTE:** You cannot delete the default `linuxadmin` user name. You can delete the default `admin` user name only if at least one OS10 user with the `sysadmin` role is configured.

For example, to access the OS10 CLI using an SSH connection:

1. Open an SSH session using the IP address of the device. You can also use PuTTY or a similar tool to access the device remotely.

```
ssh admin@ip-address
password: admin
```

2. Enter `admin` for both the default user name and password to log into OS10. You are automatically placed in EXEC mode.

```
OS10#
```

For example, to access the Linux shell using an SSH connection, enter `linuxadmin` as the user name and password:

```
ssh linuxadmin@management-ip-address
password: linuxadmin
```

## Key CLI features

| Feature | Description |
|---|---|
| Consistent command names | Commands that provide the same type of function have the same name, regardless of the portion of the system on which they are operating. For example, all `show` commands display software information and statistics, and all `clear` commands erase various types of system information. |
| Available commands | Information about available commands is provided at each level of the CLI command hierarchy. You can enter a question mark (`?`) at any level and view a list of the available commands, along with a short description of each command. |
| Command completion | Command completion for command names (keywords) and for command options is available at each level of the hierarchy. To complete a command or option that you have partially entered, click the Tab key or the Spacebar. If the partially entered letters are a string that uniquely identifies a command, the complete command name appears. A beep indicates that you have entered an ambiguous command, and the possible completions display. Completion also applies to other strings, such as interface names and configuration statements. |

## CLI command modes

The OS10 CLI has two top-level modes:

- **EXEC mode** -- Monitor, troubleshoot, check status, and network connectivity.
- **CONFIGURATION mode** -- Configure network devices.

When you enter CONFIGURATION mode, you are changing the current operating configuration, called the running configuration. By default, all configuration changes are automatically saved to the running configuration.

You can change this default behavior by switching to Transaction-Based Configuration mode. To switch to Transaction-Based Configuration mode, use the `start transaction` command. When you switch to the Transaction-Based Configuration mode and update the candidate configuration, changes to the candidate configuration are not added to the running configuration until you commit them to activate the configuration. The `start transaction` command applies only to the current session. Changing the configuration mode of the current session to the Transaction-Based Configuration mode does not affect the configuration mode of other CLI sessions.

- After you explicitly enter the `commit` command to save changes to the candidate configuration, the session switches back to the default behavior of automatically saving the configuration changes to the running configuration.
- When a session terminates while in the Transaction-Based Configuration mode, and you have not entered the `commit` command, the changes are maintained in the candidate configuration. You can start a new Transaction-Based Configuration mode session and continue with the remaining configuration changes.
- All sessions in Transaction-Based Configuration mode update the same candidate configuration. When you use the `commit` command on any session in Transaction-Based Configuration mode or you make configuration changes on any session in Non-Transaction-Based mode, you also commit the changes made to the candidate configuration in all other sessions running in the transaction-based configuration mode. This implies that inconsistent configuration changes may be applied to the running configuration. Dell recommends only making configuration changes on a single CLI session at a time.
- When you enter the `lock` command in a CLI session, configuration changes are disabled on all other sessions, whether they are in Transaction-Based Configuration mode or Non-Transaction-Based Configuration mode. For more information, see Candidate configuration.

## CLI command hierarchy

CLI commands are organized in a hierarchy. Commands that perform a similar function are grouped together under the same level of hierarchy. For example, all commands that display information about the system and the system software are grouped under the `show system` command, and all commands that display information about the routing table are grouped under the `show ip route` command.

To move directly to EXEC mode from any sub-mode, enter the `end` command. To move up one command mode, enter the `exit` command.

### CONFIGURATION mode

When you initially log in to OS10, you are placed in EXEC mode. To access CONFIGURATION mode, enter the `configure terminal` command. Use CONFIGURATION mode to manage interfaces, protocols, and features.

```
OS10# configure terminal
OS10(config)#
```

Interface mode is a sub-mode of CONFIGURATION mode. In Interface mode, you configure Layer 2 (L2) and Layer 3 (L3) protocols, and IPv4 and IPv6 services on an interface:

- Physical interfaces include the Management interface and Ethernet ports.
- Logical interfaces include Loopback, link aggregation group (LAG), and virtual local area networks (VLANs).

From CONFIGURATION mode, you can also configure L2 and L3 protocols with a specific protocol-configuration mode, such as Spanning-Tree Protocol (STP) or Border Gateway Protocol (BGP).

## Check device status

Use `show` commands to check the status of a device and monitor activities. See Related Videos section for more information.

- Enter `show ?` from EXEC mode to view a list of commands to monitor a device; for example:

```
OS10# show ?
  acl-table-usage          Show ACL table utilization
  alarms                   Display all current alarm situation in the system
  alias                    Show list of aliases
  bfd                      Show bfd session commands
  boot                     Show boot information
  candidate-configuration  Current candidate configuration
  class-map                Show QoS class-map configuration
  clock                    Show the system date and time
  ...
  users                    Show the current list of users logged into the system
                           and show the session id
  version                  Show the software version on the system
  virtual-network          Virtual-network info
  vlan                     Vlan status and configuration
  vlt                      Show VLT domain info
  vrrp                     VRRP group status
  ztd-status               Show ztd status
```

- Enter `show command-history` from EXEC mode to view trace messages for each executed command.

```
OS10# show command-history
    1    Thu Apr  20 19:44:38 UTC 2017  show vlan
    2    Thu Apr  20 19:47:01 UTC 2017  admin
    3    Thu Apr  20 19:47:01 UTC 2017  monitor hardware-components controllers view 0
    4    Thu Apr  20 19:47:03 UTC 2017  system general info system-version view
    5    Thu Apr  20 19:47:16 UTC 2017  admin
    6    Thu Apr  20 19:47:16 UTC 2017  terminal length 0
    7    Thu Apr  20 19:47:18 UTC 2017  terminal datadump
    8    Thu Apr  20 19:47:20 UTC 2017  %abc
    9    Thu Apr  20 19:47:22 UTC 2017  switchshow
   10    Thu Apr  20 19:47:24 UTC 2017  cmsh
```

- Enter `show system` from EXEC mode to view the system status information; for example:

```
OS10# show system
Node Id              : 1
MAC                  : 14:18:77:15:c3:e8
Number of MACs       : 256
Up Time              : 1 day 00:48:58
-- Unit 1 --
Status                     : up
System Identifier          : 1
Down Reason                : unknown
Digital Optical Monitoring : disable
System Location LED        : off
Required Type              : S4148F
Current Type               : S4148F
Hardware Revision          : X01
Software Version           : 10.5.1.0
Physical Ports             : 48x10GbE, 2x40GbE, 4x100GbE
BIOS                          : 3.33.0.0-3
System CPLD                   : 0.4
Master CPLD                   : 0.10
Slave CPLD                    : 0.7
-- Power Supplies --
PSU-ID  Status      Type    AirFlow   Fan  Speed(rpm)  Status
----------------------------------------------------------------
1       up          AC      NORMAL    1    13312       up
2       fail
-- Fan Status --
FanTray  Status      AirFlow   Fan  Speed(rpm)  Status
----------------------------------------------------------------
1        up          NORMAL    1    13195       up
2        up          NORMAL    1    13151       up
3        up          NORMAL    1    13239       up
4        up          NORMAL    1    13239       up
```

## Command help

To view a list of valid commands in any CLI mode, enter `?`; for example:

```
OS10# ?
  alarm                    Alarm commands
  alias                    Set alias for a command
  batch                    Batch Mode
  boot                     Tell the system where to access the software image at bootup
  clear                    Clear command
  clock                    Configure the system clock
  commit                   Commit candidate configuration
  configure                Enter configuration mode
  copy                     Perform a file copy operation
  crypto                   Cryptography commands
  ...
  ping                     ping -h shows help
  ping6                    ping6 -h shows help
  reload                   Reboot Networking Operating System
  show                     Show running system information
  start                    Activate transaction based configuration
  support-assist-activity  Support Assist related activity
  system                   System command
  terminal                 Set terminal settings
  traceroute               traceroute --help shows help
  unlock                   Unlock candidate configuration
  validate                 Validate candidate configuration
  write                    Copy from current system configuration
  ztd                      Cancel the current ZTD process.
```

```
OS10(config)# ?
  aaa                      Configure AAA
  alias                    Set alias for a command
  banner                   Configure banners
  bfd                      Enable bfd globally
  class-map                Configure class map
  clock                    Configure clock parameters
  control-plane            Control-plane configuration
  crypto                   Crypto commands
  dcbx                     DCBX commands
  default                  Configure default attributes
  dot1x                    Configure dot1x global information
  ...
  uplink-state-group       Create uplink state group
  username                 Create or modify users
  userrole                 Create custom user role
  virtual-network          Create a Virtual Network
  vlt-domain               VLT domain configurations
  vrrp                     Configure VRRP global attributes
  wred                     Configure WRED profile
```

## Candidate configuration

When you use OS10 configuration commands in Transaction-based configuration mode, changes do not take effect immediately and are stored in the candidate configuration. The configuration changes become active only after you commit the changes using the `commit` command. Changes in the candidate configuration are validated and applied to the running configuration.

The candidate configuration allows you to avoid introducing errors during an OS10 configuration session. You can make changes and then check them before committing them to the active, running configuration on the switch.

To check differences between the running configuration and the candidate configuration, use the `show diff candidate-configuration running-configuration` command.

For example, before entering Transaction mode, you can check that no new configuration commands are entered. If the `show` command does not return output, the candidate-configuration and running-configuration files are the same. Then start Transaction mode, configure new settings, and view the differences between the candidate and running configurations. Decide if you want to commit the changes to the running configuration. To delete uncommitted changes, use the `discard` command.

### View differences between candidate and running configurations

```
OS10# show diff candidate-configuration running-configuration
OS10#
OS10# start transaction
OS10# configure terminal
OS10(config)# interface vlan 100
OS10(conf-if-vl-100)# exit
OS10(config)# interface ethernet 1/1/15
OS10(conf-if-eth1/1/15)# switchport mode trunk
OS10(conf-if-eth1/1/15)# switchport trunk allowed vlan 100
OS10(conf-if-eth1/1/15)# end
OS10# show diff candidate-configuration running-configuration
!
interface ethernet1/1/15
switchport mode trunk
switchport trunk allowed vlan 100
!
interface vlan100
no shutdown
OS10#
```

### Commit configuration changes in candidate configuration in Transaction mode

1. Change to Transaction-based configuration mode from EXEC mode.

```
start transaction
```

2. Enter configuration commands. For example, enable an interface from INTERFACE mode.

```
interface ethernet 1/1/1
no shutdown
```

3. Save the configuration changes to the running configuration.

```
do commit
```

After you enter the `commit` command, the current OS10 session switches back to the default behavior of committing all configuration changes automatically.

```
OS10# start transaction
OS10# configure terminal
OS10(config)#
OS10(config)# interface ethernet 1/1/1
OS10(config-if-eth1/1/1)# no shutdown
OS10(config-if-eth1/1/1)# do commit
```

### Compressed configuration views

To display only interface-related configurations in the candidate configuration, use the `show candidate-configuration compressed` and `show running-configuration compressed` commands. These views display only the configuration commands for VLAN and physical interfaces.

```
OS10# show candidate-configuration compressed
interface breakout 1/1/1 map 40g-1x
interface breakout 1/1/2 map 40g-1x
interface breakout 1/1/3 map 40g-1x
interface breakout 1/1/4 map 40g-1x
...
interface breakout 1/1/30 map 40g-1x
interface breakout 1/1/31 map 40g-1x
interface breakout 1/1/32 map 40g-1x
ipv6 forwarding enable
username admin password $6$q9QBeYjZ$jfxzVqGhkxX3smxJSH9DDz7/3OJc6m5wjF8nnLD7/
VKx8SloIhp4NoGZs0I/UNwh8WVuxwfd9q4pWIgNs5BKH. role sysadmin
aaa authentication local
snmp-server contact http://www.dell.com/support
!
interface range ethernet 1/1/1-1/1/32
 switchport access vlan 1
 no shutdown
!
interface vlan 1
 no shutdown
!
interface mgmt1/1/1
 ip address dhcp
 no shutdown
 ipv6 enable
 ipv6 address autoconfig
!
support-assist
!
policy-map type application policy-iscsi
!
class-map type application class-iscsi
```

```
OS10# show running-configuration compressed
interface breakout 1/1/1 map 40g-1x
interface breakout 1/1/2 map 40g-1x
interface breakout 1/1/3 map 40g-1x
interface breakout 1/1/4 map 40g-1x
...
interface breakout 1/1/30 map 40g-1x
interface breakout 1/1/31 map 40g-1x
interface breakout 1/1/32 map 40g-1x
ipv6 forwarding enable
username admin password $6$q9QBeYjZ$jfxzVqGhkxX3smxJSH9DDz7/3OJc6m5wjF8nnLD7/
VKx8SloIhp4NoGZs0I/UNwh8WVuxwfd9q4pWIgNs5BKH. role sysadmin
aaa authentication local
snmp-server contact http://www.dell.com/support
!
interface range ethernet 1/1/1-1/1/32
 switchport access vlan 1
 no shutdown
!
interface vlan 1
 no shutdown
!
interface mgmt1/1/1
 ip address dhcp
 no shutdown
 ipv6 enable
 ipv6 address autoconfig
!
support-assist
!
policy-map type application policy-iscsi
!
class-map type application class-iscsi
```

### Prevent configuration changes

You can prevent configuration changes that are made on the switch in sessions other than the current CLI session using the `lock` command. To prevent and allow configuration changes in other sessions, use the `lock` and `unlock` commands in EXEC mode.

When you enter the `lock` command, users in other active CLI sessions cannot make configuration changes. When you close the CLI session in which you entered the `lock` command, configuration changes are automatically allowed in all other sessions.

```
OS10# lock
OS10# unlock
```

### Conflicting interface ranges

After you apply one or more VLANs to an interface using the `switchport trunk allowed vlan` command, and try to delete some of the VLANs from the candidate configuration, the system displays an error message. For example, the following is a configuration without conflicts:

```
OS10# start transaction
OS10# configure terminal
OS10(config)# interface range vlan 2-3
OS10(conf-range-vl-2-3)# exit
OS10(config)# interface range vlan 40-45
OS10(conf-range-vl-40-45)# exit
OS10(config)#
OS10(config)# interface range port-channel 2-3
OS10(conf-range-po-2-3)# switchport mode trunk
OS10(conf-range-po-2-3)# switchport trunk allowed vlan 2-3
OS10(conf-range-po-2-3)# switchport trunk allowed vlan 40-45
OS10(conf-range-po-2-3)# exit
OS10(config)# no interface range vlan 20-30
OS10(config)# do commit
```

The system already contains the following configuration:

```
OS10(config)# do show running-configuration interface port-channel
!
interface port-channel3
no shutdown
switchport mode trunk
switchport access vlan 1
switchport trunk allowed vlan 2-3,40-45
OS10(config)#
OS10(config)# do show running-configuration interface vlan
!
interface vlan1
no shutdown
!
interface vlan2
no shutdown
!
interface vlan3
no shutdown
!
interface vlan4
no shutdown
!
interface vlan5
no shutdown
```

The following depicts a conflicting configuration wherein a few VLANs are created and applied to an interface and then a subset of VLANs are removed from the candidate configuration:

```
OS10(config)# do start transaction
OS10(config)# interface range port-channel 3
OS10(conf-range-po-3)# switchport trunk allowed vlan 2-5
OS10(conf-range-po-3)# exit
OS10(config)# no interface range vlan 2-4
OS10(conf-range-po-3)# % Error:  Range configuration conflict - the last command was not applied. Please
commit (or discard) the rest of the configuration changes and retry.
```

If you see the error message, commit the entire configuration and then delete a sub set of VLANs.

```
OS10(conf-range-po-3)#do commit
OS10(conf-range-po-3)# do show running-configuration interface port-channel
!
interface port-channel3
no shutdown
switchport mode trunk
switchport access vlan 1
switchport trunk allowed vlan 2-5
OS10(conf-range-po-3)# do show running-configuration interface vlan
!
interface vlan1
no shutdown
!
interface vlan2
no shutdown
!
interface vlan3
no shutdown
!
interface vlan4
no shutdown
!
interface vlan5
no shutdown
OS10(conf-range-po-3)# no interface range vlan 2-4
OS10(config)# do show running-configuration interface vlan
!
interface vlan1
no shutdown
!
interface vlan5
no shutdown
OS10(config)# do show running-configuration interface port-channel
!
interface port-channel3
no shutdown
switchport mode trunk
switchport access vlan 1
switchport trunk allowed vlan 5
```

Sometimes, partial removal of VLANs may fail and display the following error message:

```
% Error:  The command failure resulted in disintegrated candidate configuration. Please
discard the current candidate configuration changes.
```

If you see this error message, discard the entire configuration using the `discard` command.

## Copy running configuration

The running configuration contains the current OS10 system configuration and consists of a series of OS10 commands. Copy the running configuration to a remote server or local directory as a backup or for viewing and editing. The running configuration is copied as a text file that you can view and edit with a text editor.

### Copy running configuration to local directory or remote server

```
OS10# copy running-configuration {config://filepath | home://filepath |
ftp://userid:passwd@hostip/filepath | scp://userid:passwd@hostip/filepath |
sftp://userid:passwd@hostip/filepath | tftp://hostip/filepath}
OS10# copy running-configuration scp://root:calvin@10.11.63.120/tmp/qaz.txt
```

### Copy file to running configuration

To apply a set of commands to the current running configuration and execute them immediately, copy a text file from a remote server or local directory. The copied commands do not replace the existing commands. If the copy command fails, any commands that were successfully copied before the failure occurred are maintained.

```
OS10# copy {config://filepath | home://filepath |
ftp://userid:passwd@hostip/filepath | scp://userid:passwd@hostip/filepath |
sftp://userid:passwd@hostip/filepath | tftp://hostip/filepath | http://userid@hostip/
filepath}
running-configuration
OS10# copy scp://root:calvin@10.11.63.120/tmp/qaz.txt running-configuration
```

### Copy running configuration to startup configuration

To display the configured settings in the current OS10 session, use the `show running-configuration`. To save new configuration settings across system reboots, copy the running configuration to the startup configuration file.

```
OS10# copy running-configuration startup-configuration
```

### Restore startup configuration

The startup configuration file, `startup.xml`, is stored in the config system folder. To create a backup version, copy the startup configuration to a remote server or the local `config:` or `home:` directories.

To restore a backup configuration, copy a local or remote file to the startup configuration and reload the switch. After downloading a backup configuration, enter the `reload` command, otherwise the configuration does not take effect until you reboot.

> **NOTE:** A non-default switch-port profile is not automatically restored. If the downloaded startup configuration you want to restore contains a non-default switch-port profile, you must manually configure and save the profile on the switch, and then reload the switch for the profile settings to take effect. If the backup startup file contains the default switch-port profile, you can simply copy the startup configuration file from the server and reload the switch.

**Copy file to startup configuration:**

```
OS10# copy {config://filepath | home://filepath |
ftp://userid:passwd@hostip/filepath | scp://userid:passwd@hostip/filepath |
sftp://userid:passwd@hostip/filepath | tftp://hostip/filepath} config://startup.xml
```

**Back up startup file:**

```
OS10# copy config://startup.xml config://backup-9-28.xml
```

**Restore startup file from backup:**

```
OS10# copy config://backup-9-28.xml config://startup.xml
OS10# reload
System configuration has been modified. Save? [yes/no]:no
```

**Back up startup file to server:**

```
OS10# copy config://startup.xml scp://userid:password@hostip/backup-9-28.xml
```

**Restore startup file from server:**

```
OS10# copy scp://admin:admin@hostip/backup-9-28.xml config://startup.xml
OS10# reload
System configuration has been modified. Save? [yes/no]:no
```

## Reload system image

Reboot the system manually using the `reload` command in EXEC mode. You are prompted to confirm the operation.

```
OS10# reload
System configuration has been modified. Save? [yes/no]:yes
Saving system configuration
Proceed to reboot the system? [confirm yes/no]:yes
```

To configure the OS10 image loaded at the next system boot, enter the `boot system` command in EXEC mode.

```
boot system {active | standby}
```

- Enter `active` to load the active OS10 image.
- Enter `standby` to load the standby OS10 image.

**Set next boot image:**

```
OS10# boot system standby
OS10# show boot
Current system image information:
===================================
Type       Boot Type   Active          Standby         Next-Boot
-------------------------------------------------------------------
Node-id 1  Flash Boot  [A] 10.2.9999E  [B] 10.2.9999E  [B] standby
```

## Filter show commands

You can filter `show` command output to view specific information, or start the command output at the first instance of a regular expression or phrase.

- **display-xml** -- Displays output in XML format.
- **except** -- Displays only text that does not match a pattern.
- **find** -- Searches for the first occurrence of a pattern and displays all further configurations.
- **grep** -- Displays only the text that matches a specified pattern. Special characters in regular expressions, such as `^` (matches the beginning of a text string), `$` (matches the end of a string), and `..` (matches any character in the string) are supported.
- **no-more** -- Does not paginate output.
- **save** -- Saves the output to a file.

**Display all output:**

```
OS10# show running-configuration | no-more
```

## Common OS10 commands

#### boot

Configures the OS10 image to use the next time the system boots up.

**Syntax**

```
boot system [active | standby]
```

**Parameters**

- `active` -- Reset the running image as the next boot image.
- `standby` -- Set the standby image as the next boot image.

**Default:** Not configured

**Command Mode:** EXEC

**Usage Information:** Use this command to configure the OS10 image that is reloaded at boot time. Use the `show boot` command to verify the next boot image. The `boot system` command applies immediately.

**Example**

```
OS10# boot system standby
```

**Supported Releases:** 10.2.0E or later

---

#### commit

Commits changes in the candidate configuration to the running configuration.

**Syntax**

```
commit
```

**Parameters:** None

**Default:** Not configured

**Command Mode:** EXEC

**Usage Information:** Use this command to save changes to the running configuration. Use the `do commit` command to save changes in CONFIGURATION mode.

**Example**

```
OS10# commit
```

**Example (configuration)**

```
OS10(config)# do commit
```

**Supported Releases:** 10.2.0E or later

---

#### configure

Enters CONFIGURATION mode from EXEC mode.

**Syntax**

```
configure {terminal}
```

**Parameters:** `terminal` -- Enters CONFIGURATION mode from EXEC mode.

**Default:** Not configured

**Command Mode:** EXEC

**Usage Information:** Enter `conf t` for auto-completion.

**Example**

```
OS10# configure terminal
OS10(config)#
```

**Supported Releases:** 10.2.0E or later

---

#### copy

Copies the current running configuration to the startup configuration and transfers files between an OS10 switch and a remote device.

**Syntax**

```
copy running-configuration [startup-configuration [insecure] | config://
filepath [insecure]| coredump://filepath | ftp://filepath | home://
filepath [insecure] | scp://filepath | sftp://filepath | supportbundle://
filepath | severity-profile profile-name [insecure] | tftp://filepath |
http://filepath | https://filepath [insecure]| usb://filepath]
```

**Parameters**

- `running-configuration startup-configuration` -- (Optional) Copy the current running configuration file to the startup configuration file. Use the `insecure` option to skip the peer certificate validation.
- `config://filepath [insecure]` -- (Optional) Copy the running configuration from the configuration directory. Use the `insecure` option to skip the peer certificate validation.
- `coredump://filepath` -- (Optional) Copy from the coredump directory.
- `ftp://userid:passwd@hostip/filepath` -- (Optional) Copy from a remote FTP server.
- `home://username/filepath [insecure]` -- (Optional) Copy from the home directory. Use the `insecure` option to skip the peer certificate validation.
- `scp://userid:passwd@hostip/filepath` -- (Optional) Copy from a remote SCP server.
- `sftp://userid:passwd@hostip/filepath` -- (Optional) Copy from a remote SFTP server.
- `supportbundle://filepath` -- (Optional) Copy from the support-bundle directory.
- `severity-profile://filepath [insecure]` -- (Optional) Copy from the severity-profile directory. Use the `insecure` option to skip the peer certificate validation.
- `tftp://hostip/filepath` -- (Optional) Copy from a remote TFTP server.
- `http://hostip/filepath` -- (Optional) Copy from a remote HTTP server.
- `https://hostip/filepath [insecure]` -- (Optional) Copy from a remote HTTPS server. Use the `insecure` option to skip the peer certificate validation.
- `usb:filepath` -- (Optional) Copy from a USB file system.

**Default:** Not configured

**Command Mode:** EXEC

**Usage Information**

Use this command to perform the following tasks:

- Save the running configuration to the startup configuration.
- Transfer coredump files to a remote location.
- Back up the startup configuration.
- Retrieve a previously backed-up configuration.
- Replace the startup configuration file.
- Transfer support bundles.

> **CAUTION:** Dell Technologies recommends not using the `copy` command to download an OS10 image to the switch. The downloaded image occupies a large amount of disk space. Use the `image download` command to download an OS10 image.

When using the `scp` and `sftp` options, always enter an absolute file path instead of a path relative to the home directory of the user account; for example:

```
copy config://startup.xml scp://dellos10:password@10.1.1.1/home/dellos10/backup.xml
```

Use the `copy` command with the `severity-profile` option to download or upload severity profiles from a remote location. When you copy a severity profile from a remote location to an OS10 switch, ensure that the name of the severity profile is different than that of the default profile (`default.xml`) or the active severity profile.

**Example**

```
OS10# dir coredump

Directory contents for folder: coredump
Date (modified)        Size (bytes)  Name
---------------------  ------------  ------------------
2017-02-15T19:05:41Z   12402278      core.netconfd-
pro.2017-02-15_19-05-09.gz

OS10# copy coredump://core.netconfd-pro.2017-02-15_19-05-09.gz scp://
os10user:os10passwd@10.11.222.1/home/os10/core.netconfd-pro.2017-02-15_19-05-09.gz
```

**Example: Copy startup configuration**

```
OS10# dir config
Directory contents for folder: config
Date (modified)        Size (bytes)  Name
---------------------  ------------  ------------
2017-02-15T20:38:12Z   54525         startup.xml

OS10# copy config://startup.xml scp://os10user:os10passwd@10.11.222.1/home/os10/backup.xml
```

**Example: Retrieve backed-up configuration**

```
OS10# copy scp://os10user:os10passwd@10.11.222.1/home/os10/backup.xml home://config.xml
OS10(conf-if-eth1/1/5)# dir home

Directory contents for folder: home
Date (modified)        Size (bytes)  Name
---------------------  ------------  -----------
...
2017-02-15T21:19:54Z   54525         config.xml
...
```

**Example: Download a custom severity profile from a remote location**

```
copy scp://username:password@a.b.c.d//file-path/mySevProf.xml severity-profile://mySevProf_1.xml
```

**Example: Replace the startup configuration**

```
OS10# home://config.xml config://startup.xml
```

**Example: Insecure option**

```
OS10#copy https://100.104.93.171/upgrade/https_test config://https_test insecure
OS10#copy config://https_test https://100.104.93.171/upgrade/https_test insecure
OS10#copy home://https_test https://100.104.93.171/upgrade/https_test insecure
OS10#copy running-configuration  https://100.104.93.171/upgrade/https_test insecure
OS10#copy severity-profile://https_test  https://100.104.93.171/upgrade/https_test insecure
```

**Supported Releases:** 10.2.0E or later

---

#### delete

Removes or deletes a file, including the startup configuration file.

**Syntax**

```
delete [config://filepath | coredump://filepath | home://filepath |
image://filepath | startup-configuration | severity-profile profile-name
| supportbundle://filepath | usb://filepath]
```

**Parameters**

- `config://filepath` -- (Optional) Delete from the configuration directory.
- `coredump://filepath` -- (Optional) Delete from the coredump directory.
- `home://filepath` -- (Optional) Delete from the home directory.
- `image://filepath` -- (Optional) Delete from the image directory.
- `startup-configuration` -- (Optional) Delete the startup configuration.
- `severity-profile` -- (Optional) Delete from severity profile directory, `severity-profile://filepath`.
- `supportbundle://filepath` -- (Optional) Delete from the support-bundle directory.
- `usb://filepath` -- (Optional) Delete from the USB file system.

**Default:** Not configured

**Command Mode:** EXEC

**Usage Information**

Use this command to remove a regular file, software image, or startup configuration. Removing the startup configuration restores the system to the factory default. You must reboot the switch using the `reload` command for the operation to take effect.

> **NOTE:**
> - Use caution when removing the startup configuration.
> - When the system disk space is low, a syslog message displays:
>   ```
>   SYS_STAT_LOW_DISK_SPACE: Warning! Configuration directory has
>   0.0% free. Please delete unnecessary files from home directory.
>   ```
>   When you see this error, delete unwanted files from the home directory or you may encounter degraded system performance.

**Example**

```
OS10# delete startup-configuration
OS10# delete severity-profile://mySevProf.xml
```

**Supported Releases:** 10.2.0E or later

---

#### dir

Displays files that are stored in available directories.

**Syntax**

```
dir {config | coredump | home | image | severity-profile | supportbundle | usb}
```

**Parameters**

- `config` -- (Optional) Folder containing configuration files.
- `coredump` -- (Optional) Folder containing coredump files.
- `home` -- (Optional) Folder containing files in your home directory.
- `image` -- (Optional) Folder containing image files.
- `severity-profile` -- (Optional) Folder containing alarm severity profiles.
- `supportbundle` -- (Optional) Folder containing support bundle files.
- `usb` -- (Optional) Folder containing files on a USB drive.

**Default:** Not configured

**Command Mode:** EXEC

**Security and Access:** Netadmin, sysadmin, secadmin, and netoperator

**Usage Information:** The `dir` command requires at least one parameter. Use the `dir config` command to display configuration files. From Release 10.5.6.4 and later, this command is accessible to the netoperator role.

**Example**

```
OS10# dir
  config           Folder containing configuration files
  coredump         Folder containing coredump files
  home             Folder containing files in user's home directory
  image            Folder containing image files
  severity-profile Folder containing severity profiles
  supportbundle    Folder containing support bundle files
```

**Example (config)**

```
OS10# dir config
Directory contents for folder: config
Date (modified)        Size (bytes)  Name
---------------------  ------------  -----------
2017-04-26T15:23:46Z   26704         startup.xml
OS10# dir severity-profile
Date (modified)       Size (bytes)  Name
--------------------- ------------  -------------
2019-03-27T15:24:06Z  46741         default.xml
2019-04-01T11:22:33Z  456           mySevProf.xml
```

**Supported Releases:** 10.2.0E or later

---

#### discard

Discards changes made to the candidate configuration file.

**Syntax**

```
discard
```

**Parameters:** None

**Default:** Not configured

**Command Mode:** EXEC

**Usage Information:** None

**Example**

```
OS10# discard
```

**Supported Releases:** 10.2.0E or later

---

#### do

Executes most commands from all CONFIGURATION modes without returning to EXEC mode.

**Syntax**

```
do command
```

**Parameters:** `command` -- Enter an EXEC-level command.

**Default:** Not configured

**Command Mode:** INTERFACE

**Usage Information:** None

**Example**

```
OS10(config)# interface ethernet 1/1/7
OS10(conf-if-eth1/1/7)# no shutdown
OS10(conf-if-eth1/1/7)# do show running-configuration
...
!
interface ethernet1/1/7
 no shutdown
!
...
```

**Supported Releases:** 10.2.0E or later

---

#### end

Returns to EXEC mode from any other command mode.

**Syntax**

```
end
```

**Parameters:** None

**Default:** Not configured

**Command Mode:** All

**Usage Information:** Use the `end` command to return to EXEC mode to verify currently configured settings with `show` commands.

**Example**

```
OS10(config)# end
OS10#
```

**Supported Releases:** 10.2.0E or later

---

#### exit

Returns to the next higher command mode.

**Syntax**

```
exit
```

**Parameters:** None

**Default:** Not configured

**Command Mode:** All

**Usage Information:** None

**Example**

```
OS10(conf-if-eth1/1/1)# exit
OS10(config)#
```

**Supported Releases:** 10.2.0E or later

---

#### hostname

Sets the system hostname.

**Syntax**

```
hostname name
```

**Parameters:** `name` -- Enter the hostname of the switch, a maximum of 64 characters.

**Default:** OS10

**Command Mode:** CONFIGURATION

**Usage Information:** The hostname is used in the OS10 command-line prompt. The `no` version of this command resets the hostname to OS10.

**Example**

```
OS10(config)# hostname R1
R1(config)#
```

**Supported Releases:** 10.3.0E or later

---

#### image cancel

Cancels an image or firmware file download that is in progress.

**Syntax**

```
image cancel
```

**Parameters:** None

**Default:** Not configured

**Command Mode:** EXEC

**Usage Information:** The `image cancel` command cancels a file download from a server, such as an OS10 binary image or firmware upgrade, that is in progress. After an image download completes, the command has no effect. The command also removes any pending firmware upgrades on the switch.

**Example**

```
OS10# image cancel
```

**Supported Releases:** 10.2.0E or later

---

#### image copy

Copies the active image to the standby location.

**Syntax**

```
image copy active-to-standby
```

**Parameters:** `active-to-standby` -- Enter to copy the entire active image to the standby location, a mirror image.

**Default:** Not configured

**Command Mode:** EXEC

**Usage Information:** Duplicate the active, running software image to the standby image location.

**Example**

```
OS10# image copy active-to-standby
```

**Supported Releases:** 10.2.0E or later

---

#### image download

Downloads a new software image or firmware file to the local file system.

**Syntax**

```
image download file-url
```

**Parameters**

`file-url` -- Enter the URL of the image file:

- `ftp://userid:passwd@hostip/filepath` -- Enter the path to copy from the remote FTP server.
- `http://hostip/filepath` -- Enter the path to copy from the remote HTTP server.
- `scp://userid:passwd@hostip/filepath` -- Enter the path to copy from the remote SCP file system.
- `sftp://userid:passwd@hostip/filepath` -- Enter the path to copy from the remote SFTP file system.
- `tftp://hostip/filepath` -- Enter the path to copy from the remote TFTP file system.
- `usb://filepath` -- Enter the path to copy from the USB file system.
- `https://hostip/filepath [insecure]` -- Enter the HTTPS path to download the image using the HTTPS protocol. Use the `insecure` option to skip the peer certificate validation.

**Default:** Not configured

**Command Mode:** EXEC

**Usage Information**

This command downloads image files to the image directory. Use the `dir image` command to display the contents of the image directory. OS10 SW image files are large, and occupy a significant amount of disk space. Dell Technologies recommends removing unnecessary image files from the image directory using the `delete` command; for example:

```
delete image://OS10EE-10.2.0.bin
```

Use the `show image status` command to view the download progress. When using the `scp` and `sftp` options, always enter an absolute file path instead of a path relative to the home directory of the user account; for example:

```
image download sftp://dellos10:password@10.1.1.1/home/dellos10/images/PKGS_OS10EE-10.4.3.bin
```

**Example**

```
OS10# image download sftp://dellos10:adminTo%40%20@10.1.1.1/home/
dellos10/images/PKGS_OS10-Enterprise-10.4.0E.55-installer-x86_64.bin
```

**Example (HTTPS)**

```
OS10#image download https://100.104.93.171/os10image.bin
OS10#image download https://100.104.93.171/upgrade/https_test insecure
```

**Supported Releases:** 10.2.0E or later

---

#### image gpg-key key-server

Installs the GPG key into the switch GPG key ring.

**Syntax**

```
image gpg-key key-server key-server-name key-id key-id-string
```

**Parameters**

- `key-server-name` -- Hostname address of the GPG key server.
- `key-id-string` -- Key ID of the GPG key to be installed.

**Default:** None

**Security and Access:** sysadmin

**Command Mode:** EXEC

**Usage Information:** This command uses the key-server name and key-id to install the key into the switch GPG key ring. Use this command before you use the `image verify` or `image secure-install` commands with the GPG option. If the key is not installed in the key ring, the `image verify` and `image secure-install` commands fail when used with the GPG key.

**Example**

```
OS10# image gpg-key key-server keyserver.ubuntu.com key-id 7FDA043B
```

**Supported Releases:** 10.5.1.0 or later

---

#### image install

Installs a new image or firmware file from a previously downloaded file or from a remote location.

**Syntax**

```
image install file-url [downgrade-config-file downgrade-config-file-name]
```

**Parameters**

- `file-url` -- Location of the image or firmware file:
  - `ftp://userid:passwd@hostip/filepath` -- Enter the path to install from a remote FTP server.
  - `http://hostip/filepath` -- Enter the path to install from the remote HTTP server.
  - `scp://userid:passwd@hostip/filepath` -- Enter the path to install from a remote SCP file system.
  - `sftp://userid:passwd@hostip/filepath` -- Enter the path to install from a remote SFTP file system.
  - `tftp://hostip/filepath` -- Enter the path to install from a remote TFTP file system.
  - `image://filename` -- Enter the path to use to install the image from a local file system.
  - `usb://filepath` -- Enter the path to use to install the image from the USB file system.
  - `https://hostip/filepath [insecure]` -- Enter the HTTPS path to install the image using the HTTPS protocol. Use the `insecure` option to skip the peer certificate validation.
- `downgrade-config-file downgrade-config-file-name` -- (Optional) Enter the name of the saved configuration file from the home directory in the `home://<filename>.xml` format. The specified configuration file gets applied while booting the downgrade image. This parameter is available from Release 10.5.5.5, and it is applicable for software downgrade only. You can use this parameter when downgrading to Release 10.5.5.5 or later from two previous major releases. For example, if the running version is 10.5.8.x, this parameter is supported until Release 10.5.6.x.

> **NOTE:** If the configuration file that is provided with the `downgrade-config-file` option contains unsupported CLI commands or invalid configurations, the system displays the following error message:
> ```
> The given downgrade-config file is invalid during downgrade.
> Rebooting once again to load the default configs.
> ```
> Then, the system automatically reboots and loads the default configuration settings.

**Default:** All

**Command Mode:** EXEC

**Usage Information**

Use the `show image status` command to view the installation progress. When running this command with the `downgrade-config-file` parameter, the firmware file name must be in the standard release convention (`PKGS_OS10-Enterprise-x.x.x.xbuster-installer-x86_64.bin` or `Network_Firmware_xxxxx.exe`). Renamed firmware file names are not supported.

> **NOTE:** Using front ports for image copying may result in slow download speeds. Dell Technologies recommends installing the image exclusively through the management port to optimize the process.

You can provide OS10 or ONIE images with this command. Dell Upgrade Package (DUP) can contain either an OS10 image, an ONIE image, or both. If you attempt a subsequent image installation of the same image type without reloading the switch, the second action overwrites or cancels the first one. For example, if you install OS10 10.5.5.6 and then install OS10 10.5.5.8 without a reload, the second installation overwrites the first installation. However, if the subsequent image installation is of a different image type (for example, OS10 10.5.5.8 and ONIE firmware 3.40.5.1-20), both installations take effect after reloading the switch. ONIE images are installed only during the subsequent boot after an image install request. The show commands do not reflect ONIE images until the switch is reloaded.

**Example**

```
OS10# image install ftp://10.206.28.174:/PKGS_OS10-Enterprise-10.4.0E.55-installer-x86_64.bin
```

**Example (DUP)**

```
OS10# image install image://Network_Firmware_0NPM9_WN64_10.5.5.0.P1_A00.exe
```

**Example (HTTPS)**

```
OS10#image install https://100.10.10.17/os10image.bin
OS10#image install https://100.10.10.17/upgrade/https_test insecure
```

**Example (restore saved downgrade configuration)**

```
OS10# image install image://PKGS_OS10-Enterprise-10.5.5.5.220buster-
installer-x86_64.bin downgrade-config-file home://config_5.5.xml
```

**Supported Releases:** 10.2.0E or later

---

#### image secure-install

Validates and installs the specified image.

**Syntax**

```
image secure-install image-filepath {sha256 signature signature-filepath
| gpg signature signature-filepath | pki signature signature-filepath
public-key key-file} [downgrade-config-file downgrade-config-file-name]
```

**Parameters**

- `image-filepath` -- Enter the absolute path name of the OS10 image file.
- `sha256 signature signature-filepath` -- Verify the SHA-256 cryptographic hash signature of the image file.
- `gpg signature signature-filepath` -- Verify the GNU privacy guard signature of the image file.
- `pki signature signature-filepath public-key key-file` -- Verify the PKI-signed digital signature of the image file.
- `downgrade-config-file downgrade-config-file-name` -- (Optional) Enter the name of the saved configuration file from the home directory in the `home://<filename>.xml` format. The specified configuration file gets applied while booting the downgrade image. This parameter is available from Release 10.5.5.5, and it is applicable for software downgrade only. You can use this parameter when downgrading to Release 10.5.5.5 or later from two previous major releases. For example, if the running version is 10.5.8.x, this parameter is supported until Release 10.5.6.x.

> **NOTE:** If the configuration file that is provided with the `downgrade-config-file` option contains unsupported CLI commands or invalid configurations, the system displays the following error message:
> ```
> The given downgrade-config file is invalid during downgrade.
> Rebooting once again to load the default configs.
> ```
> Then, the system automatically reboots and loads the default configuration settings.

**Default:** None

**Security and Access:** sysadmin

**Command Mode:** EXEC

**Usage Information:** This command is available only when you enable secure boot. This command is similar to the `image install` command. The system, before installing the image, verifies the signature of the OS10 image file using hash-based authentication, GNU privacy guard (GnuPG or GPG)-based signatures, or digital signatures (PKI-signed). For GPG validation, before you validate the OS10 image, use the `image gpg-key` command to install the GPG key in the switch keyring. When running this command with the `downgrade-config-file` parameter, the firmware file name must be in the standard release convention (`PKGS_OS10-Enterprise-x.x.x.xbuster-installer-x86_64.bin` or `Network_Firmware_xxxxx.exe`). Renamed firmware file names are not supported.

**Example - sha256**

```
OS10# image secure-install image://
PKGS_OS10-Enterprise-10.4.9999EX.3342stretch-installer-x86_64.bin
sha256 signature tftp://10.16.127.7/users/PKGS_OS10-
Enterprise-10.4.9999EX.3342stretch-installer-x86_64.bin.sha256
```

**Example - GPG key**

```
OS10# image secure-install image://
PKGS_OS10-Enterprise-10.4.9999EX.3342stretch-installer-x86_64.bin
gpg signature tftp://10.16.127.7/users/PKGS_OS10-
Enterprise-10.4.9999EX.3342stretch-installer-x86_64.bin.gpg
```

**Example - PKI signature**

```
OS10# image secure-install image://
PKGS_OS10-Enterprise-10.4.9999EX.3342stretch-installer-x86_64.bin
pki signature tftp://10.16.127.7/users/PKGS_OS10-
Enterprise-10.4.9999EX.3342stretch-installer-x86_64.bin.sha256.base64
public-key tftp://10.16.127.7/users/DellOS10.cert.pem
```

**Example - Restore saved downgrade configuration**

```
OS10# image secure-install image://
PKGS_OS10-Enterprise-10.5.5.5.220buster-installer-x86_64.bin
sha256 signature tftp://10.10.10.7/users/PKGS_OS10-
Enterprise-10.5.5.5.220buster-installer-x86_64.bin.sha256 downgrade-
config-file home://config_5.5.xml
```

**Supported Releases:** 10.5.1.0 or later

---

#### image verify

Verifies the OS10 image file using sha256, PKI, or GPG signatures.

**Syntax**

```
image verify image-filepath {sha256 signature signature-filepath | gpg
signature signature-filepath | pki signature signature-filepath public-
key key-file}
```

**Parameters**

- `image-filepath` -- Enter the absolute path name of the OS10 image file.
- `sha256 signature signature-filepath` -- Verify the SHA-256 cryptographic hash signature of the image file.
- `gpg signature signature-filepath` -- Verify the GNU privacy guard signature of the image file.
- `pki signature signature-filepath public-key key-file` -- Verify the PKI-signed digital signature of the image file.

**Default:** None

**Security and Access:** Sysadmin

**Command Mode:** EXEC

**Usage Information:** This command verifies the signature of the OS10 image file using hash-based authentication, GNU privacy guard (GnuPG or GPG)-based signatures, or digital signatures (PKI-signed). For GPG validation, before you validate the OS10 image, use the `image gpg-key` command to install the GPG key in the switch keyring.

**Example - sha256**

```
OS10# image verify image://
PKGS_OS10-Enterprise-10.4.9999EX.3342stretch-installer-x86_64.bin
pki signature tftp://10.16.127.7/users/PKGS_OS10-
Enterprise-10.4.9999EX.3342stretch-installer-x86_64.bin.sha256.base64
public-key tftp://10.16.127.7/users/DellOS10.cert.pem
Image verified successfully.
```

**Example - GPG key**

```
OS10# image verify image://
PKGS_OS10-Enterprise-10.4.9999EX.3342stretch-installer-x86_64.bin
gpg signature tftp://10.16.127.7/users/PKGS_OS10-
Enterprise-10.4.9999EX.3342stretch-installer-x86_64.bin.gpg
```

**Example - PKI**

```
OS10# image verify image://
PKGS_OS10-Enterprise-10.4.9999EX.3342stretch-installer-x86_64.bin
pki signature tftp://10.16.127.7/users/PKGS_OS10-
Enterprise-10.4.9999EX.3342stretch-installer-x86_64.bin.sha256.base64
public-key tftp://10.16.127.7/users/DellOS10.cert.pem
Image verified successfully.
```

**Supported Releases:** 10.5.1.0 or later

---

#### ip sftp source-interface

Configures the source interface for SFTP requests.

**Syntax**

```
ip sftp source-interface interface
```

**Parameters**

`interface` -- Specify the interface information.

- `ethernet node/slot/port[:subport]` -- Enter a physical Ethernet interface.
- `loopback number` -- Enter a Loopback interface, from 0 to 16383.
- `mgmt 1/1/1` -- Enter the management interface.
- `port-channel channel-id` -- Enter the LAG ID, from 1 to 999 or 1001 to 2000.
- `vlan vlan-id` -- Enter a VLAN ID, from 1 to 4093.

**Default:** Not configured.

**Command Mode:** CONFIGURATION

**Security and Access:** sysadmin and secadmin

**Usage Information:** Use this command to configure the source IP address for the outgoing SFTP packets when transferring the files using the SFTP protocol. The `no` version of this command disables the configured source interface.

**Example**

```
OS10(config)# ip sftp source-interface ethernet 1/1/1
```

**Supported Releases:** 10.6.0.2 or later

---

#### ip scp source-interface

Configures the source interface for SCP requests.

**Syntax**

```
ip scp source-interface interface
```

**Parameters**

`interface` -- Specify the interface information.

- `ethernet node/slot/port[:subport]` -- Enter a physical Ethernet interface.
- `loopback number` -- Enter a Loopback interface, from 0 to 16383.
- `mgmt 1/1/1` -- Enter the management interface.
- `port-channel channel-id` -- Enter the LAG ID, from 1 to 999 or 1001 to 2000.
- `vlan vlan-id` -- Enter a VLAN ID, from 1 to 4093.

**Default:** Not configured.

**Command Mode:** CONFIGURATION

**Security and Access:** sysadmin and secadmin

**Usage Information:** Use this command to configure the source IP address for the outgoing SCP packets when transferring the files using the SCP protocol. The `no` version of this command disables the configured source interface.

**Example**

```
OS10(config)# ip scp source-interface ethernet 1/1/1
```

**Supported Releases:** 10.6.0.2 or later

---

#### license

Installs a license file from a local or remote location.

**Syntax**

```
license install [ftp: | http: | https: | localfs: | scp: | sftp: | tftp: | usb:] filepath
```

**Parameters**

- `ftp:` -- (Optional) Install from the remote file system (`ftp://userid:passwd@hostip/filepath`)
- `http:` -- (Optional) Install from the remote file system (`http://hostip/filepath`)
- `https:` -- (Optional) Install from the remote file system (`https://filepath`)
- `localfs:` -- (Optional) Install from the local file system (`localfs://filepath`)
- `scp:` -- (Optional) Request from the remote file system (`scp://userid:passwd@hostip/filepath`)
- `sftp:` -- (Optional) Request from the remote file system (`sftp://userid:passwd@hostip/filepath`)
- `tftp:` -- (Optional) Request from the remote file system (`tftp://hostip/filepath`)
- `usb:` -- (Optional) Request from the USB file system (`usb://filepath`)

**Default:** Not configured

**Command Mode:** EXEC

**Usage Information:** Use this command to install the license file. For more information, see Dell SmartFabric OS10 Installation, Upgrade, and Downgrade Guide. OS10 requires a perpetual license to run beyond the 120-day trial period. The license file is installed in the `/mnt/license` directory.

**Example**

```
OS10# license install scp://user:userpwd/10.1.1.10/CFNNX42-NOSEnterprise-License.lic
License installation success.
```

**Supported Releases:** 10.3.0E or later

---

#### lock

Locks the candidate configuration and prevents any configuration changes on any other CLI sessions, either in Transaction or Non-Transaction-Based Configuration mode.

**Syntax**

```
lock
```

**Parameters:** None

**Default:** Not configured

**Command Mode:** EXEC

**Usage Information:** The `lock` command fails if there are uncommitted changes in the candidate configuration.

**Example**

```
OS10# lock
```

**Supported Releases:** 10.2.0E or later

---

#### management route

Configures an IPv4/IPv6 static route the Management port uses. To configure multiple management routes, repeat the command.

**Syntax**

```
management route {ipv4-address/mask | ipv6-address/prefix-length}
{forwarding-router-address | managementethernet}
```

**Parameters**

- `ipv4-address/mask` -- Enter an IPv4 network address in dotted-decimal format (A.B.C.D), then a subnet mask in prefix-length format (/xx).
- `ipv6-address/prefix-length` -- Enter an IPv6 address in x:x:x:x::x format with the prefix length in /xxx format. The prefix range is /0 to /128.
- `forwarding-router-address` -- Enter the next-hop IPv4/IPv6 address of a forwarding router (gateway) for network traffic from the Management port.
- `managementethernet` -- Configure the Management port as the interface for the route and associates the route with the Management interface.

**Default:** Not configured

**Command Mode:** CONFIGURATION

**Usage Information:** Management routes are separate from IP routes and are only used to manage the switch through the Management port. To display the currently configured IPv4 and IPv6 management routes, use the `show ip management-route` and `show ipv6 management-route` commands.

**Example (IPv4)**

```
OS10(config)# management route 10.10.20.0/24 10.1.1.1
OS10(config)# management route 172.16.0.0/16 managementethernet
```

**Example (IPv6)**

```
OS10(config)# management route 10::/64 10::1
```

**Supported Releases:** 10.2.2E or later

---

#### move

Moves or renames a file in the configuration or home system directories.

**Syntax**

```
move [config: | home: | usb:]
```

**Parameters**

- `config:` -- Move from the configuration directory (`config://filepath`).
- `home:` -- Move from the home directory (`home://filepath`).
- `usb:` -- Move from the USB file system (`usb://filepath`).

**Default:** Not configured

**Command Mode:** EXEC

**Usage Information:** Use the `dir config` command to view the directory contents.

**Example**

```
OS10# move config://startup.xml config://startup-backup.xml
```

**Example (dir)**

```
OS10# dir config
Directory contents for folder: config
Date (modified)        Size (bytes)  Name
---------------------  ------------  -----------
2017-04-26T15:23:46Z   26704         startup.xml
```

**Supported Releases:** 10.2.0E or later

---

#### no

Disables or deletes commands in EXEC mode.

**Syntax**

```
no [alias | debug | support-assist-activity | terminal]
```

**Parameters**

- `alias` -- Remove an alias definition.
- `debug` -- Disable debugging.
- `support-assist-activity` -- SupportAssist-related activity.
- `terminal` -- Reset terminal settings.

**Default:** Not configured

**Command Mode:** EXEC

**Usage Information:** Use this command in EXEC mode to disable or remove a configuration. Use the `no ?` in CONFIGURATION mode to view available commands.

**Example**

```
OS10# no alias goint
```

**Supported Releases:** 10.2.0E or later

---

#### ping

Tests network connectivity to an IPv4 device.

**Syntax**

```
ping [vrf {management | vrf-name}] [-4] [-aAbBdDfhLnOqrRUvV] [-c count]
[-i interval] [-I interface] [-m mark] [-M pmtudisc_option] [-l preload]
[-p pattern] [-Q tos] [-s packetsize] [-S sndbuf] [-t ttl] [-T
timestamp_option] [-w deadline] [-W timeout] [hop1 ...] destination
```

**Parameters**

- `vrf management` -- (Optional) Pings an IPv4 address in the management virtual routing and forwarding (VRF) instance.
- `vrf vrf-name` -- (Optional) Ping an IP address in a specified VRF instance.
- `-4` -- (Optional) Uses the IPv4 route over the IPv6 route when both IPv4 and IPv6 default routes are configured. For example, `OS10# ping vrf management -4 dell.com`.
- `-a` -- (Optional) Audible ping.
- `-A` -- (Optional) Adaptive ping. An interpacket interval adapts to the round-trip time so that one (or more, if you set the preload option) unanswered probe is present in the network. The minimum interval is 200 msec for a nonsuper user, which corresponds to Flood mode on a network with a low round-trip time.
- `-b` -- (Optional) Pings a broadcast address.
- `-B` -- (Optional) Does not allow ping to change the source address of probes. The source address is bound to the address used when the ping starts.
- `-c count` -- (Optional) Stops the ping after sending the specified number of ECHO_REQUEST packets until the timeout expires.
- `-d` -- (Optional) Sets the SO_DEBUG option on the socket being used.
- `-D` -- (Optional) Prints the timestamp before each line.
- `-h` -- (Optional) Displays help for this command.
- `-i interval` -- (Optional) Enter the interval in seconds to wait between sending each packet, the default is 1 second.
- `-I interface-name or interface-ip-address` -- (Optional) Enter the source interface name without spaces or the interface IP address. The interface that is specified with this option is designated as an exit interface, and packets are forced to be sent out from the configured interface. The following values are supported:
  - For a physical Ethernet interface, enter `ethernetnode/slot/port`; for example, `ethernet1/1/1`.
  - For a VLAN interface, enter `vlanvlan-id`; for example, `vlan10`.
  - For a Loopback interface, enter `loopbackid`; for example, `loopback1`.
  - For a link aggregation group (LAG) interface, enter `port-channelchannel-id`; for example, `port-channel`.
- `-l preload` -- (Optional) Enter the number of packets that ping sends before waiting for a reply. Only a superuser may preload more than three.
- `-L` -- (Optional) Suppress the Loopback of multicast packets for a multicast target address.
- `-m mark` -- (Optional) Tags the packets sent to ping a remote device. Use this option with policy routing.
- `-M pmtudisc_option` -- (Optional) Enter the path MTU (PMTU) discovery strategy:
  - `do` prevents fragmentation, including local.
  - `want` performs PMTU discovery and fragments large packets locally.
  - `dont` does not set the Don't Fragment (DF) flag.
- `-p pattern` -- (Optional) Enter a maximum of 16 pad bytes to fill out the packet you send to diagnose data-related problems in the network; for example, `-p ff` fills the sent packet with all 1's.
- `-Q tos` -- (Optional) Enter a maximum of 1500 bytes in decimal or hexadecimal datagrams to set quality of service (QoS)-related bits.
- `-s packetsize` -- (Optional) Enter the number of data bytes to send, from 1 to 65468, default 56.
- `-S sndbuf` -- (Optional) Set the sndbuf socket. By default, the sndbuf socket buffers one packet maximum.
- `-t ttl` -- (Optional) Enter the IPv4 time-to-live (TTL) value in seconds.
- `-T timestamp option` -- (Optional) Set special IP timestamp options. Valid values for timestamp option: `tsonly` (only timestamps), `tsandaddr` (timestamps and addresses), or `tsprespec host1 [host2 [host3 [host4]]]` (timestamp prespecified hops).
- `-v` -- (Optional) Verbose output.
- `-V` -- (Optional) Display the version and exit.
- `-w deadline` -- (Optional) Enter the time-out value in seconds before the ping exits regardless of how many packets send or receive.
- `-W timeout` -- (Optional) Enter the time to wait for a response in seconds. This setting affects the time-out only if there is no response, otherwise ping waits for two round-trip times (RTTs).
- `hop1 ...` -- (Optional) Enter the IPv4 addresses of the prespecified hops for the ping packet to take.
- `destination` -- Enter the IP address that you are testing connectivity on.

**Default:** Not configured

**Command Mode:** EXEC

**Usage Information:** This command uses an ICMP ECHO_REQUEST datagram to receive an ICMP ECHO_RESPONSE from a network host or gateway. Each ping packet has an IPv4 and ICMP header, then a time value and some "pad" bytes used to fill out the packet. A ping operation sends a packet to a specified IP address and then measures the time that it takes to get a response from the address or device. If the destination IP address is active, replies are sent back from the server including the IP address, number of bytes sent, lapse time in milliseconds, and TTL, which is the number of hops back from the source to the destination. When you use the `-I` option and enter an IP address, OS10 considers it as the source address. If you use an interface name instead of the IP address, OS10 considers it as the egress interface. With the `-I` option, if you ping a reachable IP address using the IP address of a loopback interface as the source interface, the ping succeeds. However, if you ping a reachable IP address using the name of the loopback interface as the source interface, the ping fails. This is because the system considers the loopback interface as the egress interface.

**Example**

```
OS10# ping 20.1.1.1
PING 20.1.1.1 (20.1.1.1) 56(84) bytes of data.
64 bytes from 20.1.1.1: icmp_seq=1 ttl=64 time=0.079 ms
64 bytes from 20.1.1.1: icmp_seq=2 ttl=64 time=0.081 ms
64 bytes from 20.1.1.1: icmp_seq=3 ttl=64 time=0.133 ms
64 bytes from 20.1.1.1: icmp_seq=4 ttl=64 time=0.124 ms
^C
--- 20.1.1.1 ping statistics ---
4 packets transmitted, 4 received, 0% packet loss, time 2997ms
rtt min/avg/max/mdev = 0.079/0.104/0.133/0.025 ms
```

**Supported Releases:** 10.2.0E or later

---

#### ping6

Tests network connectivity to an IPv6 device.

**Syntax**

```
ping6 [vrf {management | vrf-name}] [-aAbBdDfhLnOqrRUvV] [-c count] [-i
interval] [-I interface] [-l preload] [-m mark] [-M pmtudisc_option] [-N
nodeinfo_option] [-p pattern] [-Q tclass] [-s packetsize] [-S sndbuf] [-t
ttl] [-T timestamp_option] [-w deadline] [-W timeout] destination
```

**Parameters**

- `vrf management` -- (Optional) Pings an IPv6 address in the management VRF instance.
- `vrf vrf-name` -- (Optional) Pings an IPv6 address in a specified VRF instance.
- `-a` -- (Optional) Audible ping.
- `-A` -- (Optional) Adaptive ping. An interpacket interval adapts to the round-trip time so that one (or more, if you set the preload option) unanswered probe is present in the network. The minimum interval is 200 msec for a nonsuper user, which corresponds to Flood mode on a network with a low round-trip time.
- `-b` -- (Optional) Pings a broadcast address.
- `-B` -- (Optional) Does not allow ping to change the source address of probes. The source address is bound to the address used when the ping starts.
- `-c count` -- (Optional) Stops the ping after sending the specified number of ECHO_REQUEST packets until the timeout expires.
- `-d` -- (Optional) Sets the SO_DEBUG option on the socket being used.
- `-D` -- (Optional) Prints the timestamp before each line.
- `-F flowlabel` -- (Optional) Sets a 20-bit flow label on echo request packets. If the value is zero, the kernel allocates a random flow label.
- `-h` -- (Optional) Displays help for this command.
- `-i interval` -- (Optional) Enter the interval in seconds to wait between sending each packet, the default is 1 second.
- `-I interface-name or interface-ip-address` -- (Optional) Enter the source interface name without spaces or the interface IP address:
  - For a physical Ethernet interface, enter `ethernetnode/slot/port`; for example, `ethernet1/1/1`.
  - For a VLAN interface, enter `vlanvlan-id`; for example, `vlan10`.
  - For a Loopback interface, enter `loopbackid`; for example, `loopback1`.
  - For a LAG interface, enter `port-channelchannel-id`; for example, `port-channel`.
- `-l preload` -- (Optional) Enter the number of packets that ping sends before waiting for a reply. Only a superuser may preload more than three.
- `-L` -- (Optional) Suppress the Loopback of multicast packets for a multicast target address.
- `-m mark` -- (Optional) Tags the packets sent to ping a remote device. Use this option with policy routing.
- `-M pmtudisc_option` -- (Optional) Enter the path MTU (PMTU) discovery strategy:
  - `do` prevents fragmentation, including local.
  - `want` performs PMTU discovery and fragments large packets locally.
  - `dont` does not set the Don't Fragment (DF) flag.
- `-p pattern` -- (Optional) Enter a maximum of 16 pad bytes to fill out the packet you send to diagnose data-related problems in the network; for example, `-p ff` fills the sent packet with all 1's.
- `-Q tos` -- (Optional) Enter a maximum of 1500 bytes in decimal or hexadecimal datagrams to set the quality of service (QoS)-related bits.
- `-s packetsize` -- (Optional) Enter the number of data bytes to send, from 1 to 65468, default 56.
- `-S sndbuf` -- (Optional) Set the sndbuf socket. By default, the sndbuf socket buffers one packet maximum.
- `-t ttl` -- (Optional) Enter the IPv6 time-to-live (TTL) value in seconds.
- `-T timestamp option` -- (Optional) Set special IP timestamp options. Valid values for timestamp option: `tsonly` (only timestamps), `tsandaddr` (timestamps and addresses), or `tsprespec host1 [host2 [host3 [host4]]]` (timestamp prespecified hops).
- `-v` -- (Optional) Verbose output.
- `-V` -- (Optional) Display the version and exit.
- `-w deadline` -- (Optional) Enter the time-out value in seconds before the ping exits regardless of how many packets are sent or received.
- `-W timeout` -- (Optional) Enter the time to wait for a response in seconds. This setting affects the time-out only if there is no response, otherwise ping waits for two round-trip times (RTTs).
- `hop1 ...` -- (Optional) Enter the IPv6 addresses of the prespecified hops for the ping packet to take.
- `destination` -- Enter the IPv6 destination address in the A:B::C:D format, where you are testing connectivity.

**Default:** Not configured

**Command Mode:** EXEC

**Usage Information:** This command uses an ICMP ECHO_REQUEST datagram to receive an ICMP ECHO_RESPONSE from a network host or gateway. Each ping packet has an IPv6 and ICMP header, then a time value and some "pad" bytes used to fill out the packet. A pingv6 operation sends a packet to a specified IPv6 address and then measures the time that it takes to get a response from the address or device. When you use the `-I` option and enter an IP address, OS10 considers it as the source address. If you use an interface name instead of the IP address, OS10 considers it as the egress interface. With the `-I` option, if you ping a reachable IP address using the IP address of a loopback interface as the source interface, the ping succeeds. However, if you ping a reachable IP address using the name of the loopback interface as the source interface, the ping fails. This is because the system considers the loopback interface as the egress interface.

**Example**

```
OS10# ping6 20::1
PING 20::1(20::1) 56 data bytes
64 bytes from 20::1: icmp_seq=1 ttl=64 time=2.07 ms
64 bytes from 20::1: icmp_seq=2 ttl=64 time=2.21 ms
64 bytes from 20::1: icmp_seq=3 ttl=64 time=2.37 ms
64 bytes from 20::1: icmp_seq=4 ttl=64 time=2.10 ms
^C
--- 20::1 ping statistics ---
4 packets transmitted, 4 received, 0% packet loss, time 3005ms
rtt min/avg/max/mdev = 2.078/2.194/2.379/0.127 ms
```

**Supported Releases:** 10.2.0E or later

---

#### reload

Reloads the software and reboots the ONIE-enabled device.

**Syntax**

```
reload [at | cancel | in | onie | ztd]
```

**Parameters**

- `at` -- Schedule reboot of the networking operating system to take place at the specified time.
- `cancel` -- Cancel a scheduled reboot.
- `in` -- Schedule reboot of the networking operating system after the specified time.
- `onie` -- Reboot the networking operating system in the ONIE mode.

> **NOTE:** This parameter is not supported on the S3248T-ON platform.

- `ztd` -- Reboot the networking operating system in the ZTD-enabled mode.

**Default:** Not configured

**Command Mode:** EXEC

**Usage Information**

> **NOTE:** Use caution while using this command as it reloads the OS10 image and reboots the device.

**Example**

```
OS10# reload
Proceed to reboot the system? [confirm yes/no]:y
```

**Supported Releases:** 10.2.0E or later

---

#### reload fast

Forcefully reloads the software and reboots the ONIE-enabled device.

**Syntax**

```
reload [fast]
```

**Parameters:** `fast` -- Forcefully reloads the software.

**Default:** Not configured

**Security and Access:** sysadmin

**Command Mode:** EXEC

**Usage Information:** Ensure to save the unsaved configurations before using this command as it reloads the OS10 image in a nongraceful way.

**Example**

```
OS10# reload fast
This reload option would just do a direct linux reboot and not
anything else. Even unsaved configurations would be lost. Do you
still want to proceed ? [yes/no]:y
```

**Supported Releases:** 10.5.5.5 or later

---

#### show boot

Displays detailed information about the boot image.

**Syntax**

```
show boot [detail]
```

**Parameters:** None

**Default:** Not configured

**Command Mode:** EXEC

**Security and Access:** Netadmin, sysadmin, secadmin, and netoperator

**Usage Information:** The Next-Boot field displays the image that the next reload uses. From Release 10.5.6.4 and later, this command is accessible to the netoperator role.

**Example**

```
OS10# show boot
Current system image information:
===================================
Type      Boot Type      Active        Standby        Next-Boot
----------------------------------------------------------------
Node-id 1 Flash Boot  [A] 10.5.0.4   [B] 10.5.1.0   [B] standby
```

**Example (detail)**

```
OS10# show boot detail
Current system image information detail:
==========================================
Type:                     Node-id 1
Boot Type:                Flash Boot
Active Partition:         A
Active SW Version:        10.5.0.4
Active SW Build Version:  10.5.0.4.650
Active Kernel Version:    Linux 4.9.189
Active Build Date/Time:   2020-02-11T11:13:08Z
Standby Partition:        B
Standby SW Version:       10.5.1.0
Standby SW Build Version: 10.5.1.0.123
Standby Build Date/Time:  2020-02-12T02:34:02Z
Next-Boot:                standby[B]
```

**Supported Releases:** 10.2.0E or later

---

#### show candidate-configuration

Displays the current candidate configuration file.

**Syntax**

```
show candidate-configuration [aaa | access-list | as-path | bfd | bgp
| class-map | community-list | compressed | control-plane | dot1x |
extcommunity-list | evpn | fefd | igmp | interface [virtual-network vn-
id] | ip dhcp snooping | lacp | line | lldp | logging | management-route
| mld | monitor | ntp | nve | ospf | ospfv3 | password-attributes | pim |
policy-map | port-security | prefix-list | privilege | qos-map | radius-
server | route | route-map | sflow | smartfabric | snmp | spanning-tree
| support-assist | system-qos | tacacs-server | telemetry | trust-map |
uplink-state-group | userrole | users | virtual-network | vlt | vrf |
wred-profile]
```

**Parameters**

- `aaa` -- (Optional) Current operating AAA configuration.
- `access-list` -- (Optional) Current operating access-list configuration.
- `as-path` -- (Optional) Current operating as-path configuration.
- `bfd` -- (Optional) Current operating BFD configuration.
- `bgp` -- (Optional) Current operating BGP configuration.
- `class-map` -- (Optional) Current operating class-map configuration.
- `community-list` -- (Optional) Current operating community-list configuration.
- `compressed` -- (Optional) Current operating configuration in compressed format.
- `control-plane` -- (Optional) Current operating control-plane configuration.
- `dot1x` -- (Optional) Current operating dot1x configuration.
- `evpn` -- (Optional) Current operating EVPN configuration.
- `extcommunity-list` -- (Optional) Current operating extcommunity-list configuration.
- `interface` -- (Optional) Current operating interface configuration.
  - `virtual-network vn-id` -- (Optional) Current virtual network configuration.
- `fefd` -- (Optional) Current operating FEFD configuration.
- `igmp` -- (Optional) Current operating IGMP configuration.
- `ip dhcp snooping` -- (Optional) Current operating DHCP snooping information.
- `lacp` -- (Optional) Current operating LACP configuration.
- `lldp` -- (Optional) Current operating LLDP configuration.
- `logging` -- (Optional) Current operating logging configuration.
- `management-route` -- (Optional) Current operating management route configuration.
- `mld` -- (Optional) Current operating MLD configuration.
- `monitor` -- (Optional) Current operating monitor session configuration.
- `ntp` -- (Optional) Current operating NTP configuration.
- `nve` -- (Optional) Current operating NVE configuration.
- `ospf` -- (Optional) Current operating OSPF configuration.
- `ospfv3` -- (Optional) Current operating OSPFv3 configuration.
- `password-attributes` -- (Optional) Current operating passwords attributes configuration.
- `pim` -- (Optional) Current operating PIM configuration.
- `port-security` -- (Optional) Current operating port security configuration.
- `policy-map` -- (Optional) Current operating policy-map configuration.
- `prefix-list` -- (Optional) Current operating prefix-list configuration.
- `privilege` -- (Optional) Current operating user privilege configuration.
- `qos-map` -- (Optional) Current operating qos-map configuration.
- `radius-server` -- (Optional) Current operating radius-server configuration.
- `route` -- (Optional) Current operating management route configuration.
- `route-map` -- (Optional) Current operating route-map configuration.
- `sflow` -- (Optional) Current operating sFlow configuration.
- `smartfabric` -- (Optional) Current operating SmartFabric configuration.
- `snmp` -- (Optional) Current operating SNMP configuration.
- `spanning-tree` -- (Optional) Current operating spanning-tree configuration.
- `support-assist` -- (Optional) Current operating support-assist configuration.
- `system-qos` -- (Optional) Current operating system-qos configuration.
- `tacacs-server` -- (Optional) Current operating TACACS server configuration.
- `telemetry` -- (Optional) Current operating telemetry configuration.
- `trust-map` -- (Optional) Current operating trust-map configuration.
- `uplink-state-group` -- (Optional) Current operating Uplink State Group configuration.
- `users` -- (Optional) Current operating users configuration.
- `userrole` -- (Optional) Current operating user role configuration.
- `virtual-network` -- (Optional) Current operating virtual network configuration.
- `vlt` -- (Optional) Current operating VLT domain configuration.
- `vrf` -- (Optional) Current operating VRF configuration.
- `wred-profile` -- (Optional) Current operating WRED profile configuration.

**Default:** Not configured

**Command Mode:** EXEC

**Usage Information:** None

**Example**

```
OS10# show candidate-configuration
! Version 10.2.9999E
! Last configuration change at Apr  11 10:36:43 2017
!
username admin
password $6$q9QBeYjZ$jfxzVqGhkxX3smxJSH9DDz7/3OJc6m5wjF8nnLD7/
VKx8SloIhp4NoGZs0I/UNwh8WVuxwfd9q4pWIgNs5BKH.
aaa authentication local
snmp-server contact http://www.dell.com/support
snmp-server location "United States"
logging monitor disable
ip route 0.0.0.0/0 10.11.58.1
!
interface ethernet1/1/1
 switchport access vlan 1
 no shutdown
!
interface ethernet1/1/2
 switchport access vlan 1
 no shutdown
!
interface ethernet1/1/3
 switchport access vlan 1
 no shutdown
!
interface ethernet1/1/4
 switchport access vlan 1
 no shutdown
!
interface ethernet1/1/5
 switchport access vlan 1
 no shutdown
!
--more--
```

**Example (compressed)**

```
OS10# show candidate-configuration compressed
username admin
password $6$q9QBeYjZ$jfxzVqGhkxX3smxJSH9DDz7/3OJc6m5wjF8nnLD7/
VKx8SloIhp4NoGZs0I/UNwh8WVuxwfd9q4pWIgNs5BKH.
aaa authentication local
snmp-server contact http://www.dell.com/support
snmp-server location "United States"
logging monitor disable
ip route 0.0.0.0/0 10.11.58.1
!
interface range ethernet 1/1/1-1/1/32
 switchport access vlan 1
 no shutdown
!
interface vlan 1
 no shutdown
!
interface mgmt1/1/1
 ip address 10.11.58.145/8
 no shutdown
 ipv6 enable
 ipv6 address autoconfig
!
support-assist
!
policy-map type application policy-iscsi
!
class-map type application class-iscsi
```

**Supported Releases:** 10.2.0E or later

---

#### show environment

Displays information about environmental system components, such as temperature, fan, and voltage.

**Syntax**

```
show environment
```

**Parameters:** None

**Default:** Not configured

**Command Mode:** EXEC

**Usage Information:** None

**Example**

```
OS10# show environment
Unit    State             Temperature
-------------------------------------
1       up                43
Thermal sensors
Unit   Sensor-Id        Sensor-name                               Temperature
------------------------------------------------------------------------------
1       1           CPU On-Board temp sensor                          32
1       2           Switch board  temp sensor                         28
1       3           System Inlet Ambient-1 temp sensor                27
1       4           System Inlet Ambient-2 temp sensor                25
1       5           System Inlet Ambient-3 temp sensor                26
1       6           Switch board 2 temp sensor                        31
1       7           Switch board 3 temp sensor                        41
1       8           NPU temp sensor                                   43
```

**Supported Releases:** 10.2.0E or later

---

#### show image firmware

Displays any pending firmware upgrades and the status of past firmware upgrades.

**Syntax**

```
show image firmware
```

**Parameters:** None

**Default:** Not configured

**Command Mode:** EXEC

**Usage Information:** If you install an OS10 firmware file, the firmware upgrade is stored as a pending installation until you reload the switch. To view the contents of the firmware upgrade, use the `show image firmware` command. No entries are displayed in the show command output if there are no pending or past firmware upgrades available.

**Example**

```
OS10# show image firmware
Pending Firmware Upgrade(s)
====================================
  #   Name                                                  Version
      Date
 --- ----------------------------------------------------
--------------- ---------------------

Past Firmware Upgrade(s)
====================================
  Name                                                      Version
    Result
 ---------------------------------------------------------
------------- ----------------
  onie-firmware-x86_64-dellemc_s5200_c3538-r0.3.40.5.1-6.
3.40.5.1-6    Success
  onie-updater
3.40.1.1-5    Fail
  onie-updater-x86_64-dellemc_s5200_c3538-r0.3.40.1.1-6
3.40.1.1-6    Fail
```

**Supported Releases:** 10.5.0 or later

---

#### show image gpg-keys

Displays the information of the GNU Privacy Guard (GPG) keys in the switch GPG keyring.

**Syntax**

```
show image gpg-keys
```

**Parameters:** None

**Default:** Not configured

**Command Mode:** EXEC

**Usage Information:** Use this command to verify if the GPG keys have been downloaded successfully.

**Example**

```
OS10# show image gpg-keys
/root/.gnupg/pubring.kbx
------------------------
pub rsa4096 2022-06-09 [C] [expires: 2032-06-06]
0B711XYZE0E37X2YZ32367219FD5A00009E251BF
uid [unknown] Dell Technologies Inc. (Dell Networking)
<gpg.NW@dell.com>
sub rsa4096 2022-06-09 [S] [expires: 2026-03-15]
```

**Example (No GPG keys are installed)**

```
OS10# show image gpg-keys
No GPG keys installed
```

**Supported Releases:** 10.6.0.1 or later

---

#### show image status

Displays image transfer and installation information.

**Syntax**

```
show image status
```

**Parameters:** None

**Default:** Not configured

**Command Mode:** EXEC

**Usage Information:** On older versions of OS10, the `image install` command may appear unresponsive and does not display the current image status. Duplicate the SSH or Telnet session and reenter the `show image status` command to view the current status.

**Example**

```
OS10# show image status
Image Upgrade State:     install
==================================================
File Transfer State:     idle
--------------------------------------------------
  State Detail:          Completed: No error
  Task Start:            2019-01-03T17:37:49Z
  Task End:              2019-01-03T17:38:04Z
  Transfer Progress:     100 %
  Transfer Bytes:        489894821 bytes
  File Size:             489894821 bytes
  Transfer Rate:         31657 kbps
Installation State:      install
--------------------------------------------------
  State Detail:          In progress: Installing
  Task Start:            2019-01-03T17:38:04Z
  Task End:              0000-00-00T00:00:00Z
```

**Supported Releases:** 10.2.0E or later

---

#### show inventory

Displays system inventory information.

**Syntax**

```
show inventory
```

**Parameters:** None

**Default:** Not configured

**Command Mode:** EXEC

**Usage Information:** None

**Example**

```
OS10# show inventory
Product               : S4148F-ON
Description           : S4148F-ON 48x10GbE, 2x40GbE QSFP+, 4x100GbE QSFP28 Inte
Software version      : 10.5.1.0
Product Base          :
Product Serial Number :
Product Part Number   :
Unit Type                 Part Number Rev  Piece Part ID             Svc Tag  E
-------------------------------------------------------------------------------
* 1  S4148F-ON            09H9MN      X01  TW-09H9MN-28298-713-0026  9531XC2  1
  1  S4148F-ON-PWR-1-AC   06FKHH      A00  CN-06FKHH-28298-6B5-03NY
  1  S4148F-ON-FANTRAY-1  0N7MH8      X01  TW-0N7MH8-28298-713-0101
  1  S4148F-ON-FANTRAY-2  0N7MH8      X01  TW-0N7MH8-28298-713-0102
  1  S4148F-ON-FANTRAY-3  0N7MH8      X01  TW-0N7MH8-28298-713-0103
  1  S4148F-ON-FANTRAY-4  0N7MH8      X01  TW-0N7MH8-28298-713-0104
```

**Supported Releases:** 10.2.0E or later

---

#### show ip management-route

Displays the IPv4 routes that are used to access the Management port.

**Syntax**

```
show ip management-route [all | connected | dynamic | static summary]
```

**Parameters**

- `all` -- (Optional) Display the IPv4 routes that the Management port uses.
- `connected` -- (Optional) Display only routes directly connected to the Management port.
- `dynamic` -- (Optional) Display active management routes that a routing protocol learned.
- `summary` -- (Optional) Display the number of active and non-active management routes and their remote destinations.
- `static` -- (Optional) Display active static management routes.

**Default:** Not configured

**Command Mode:** EXEC

**Usage Information:** Use this command to view the IPv4 static and connected routes that are configured for the Management port. Use the `management route` command to configure an IPv4 or IPv6 management route.

**Example**

```
OS10# show ip management-route
 Destination        Gateway              State       Source
-----------------------------------------------------------------
192.168.10.0/24     managementethernet   Connected   Connected
```

**Supported Releases:** 10.2.2E or later

---

#### show ipv6 management-route

Displays the IPv6 routes that are used to access the Management port.

**Syntax**

```
show ipv6 management-route [all | connected | static | summary]
```

**Parameters**

- `all` -- (Optional) Display the IPv6 routes that the Management port uses.
- `connected` -- (Optional) Display only routes directly connected to the Management port.
- `summary` -- (Optional) Display the number of active and non-active management routes and their remote destinations.
- `static` -- (Optional) Display active static management routes.

**Default:** Not configured

**Command Mode:** EXEC

**Usage Information:** Use this command to view the IPv6 static and connected routes that are configured for the Management port. Use the `management route` command to configure an IPv4 or IPv6 management route.

**Example**

```
OS10# show ipv6 management-route
Destination    Gateway                 State
-----------    -------                 -----
2001:34::0/64  ManagementEthernet 1/1  Connected
2001:68::0/64  2001:34::16             Active
```

**Supported Releases:** 10.2.2E or later

---

#### show license status

Displays license status information.

**Syntax**

```
show license status
```

**Parameters:** None

**Default:** Not configured

**Command Mode:** EXEC

**Usage Information:** Use the `show license status` command to verify the current license for running OS10, its duration, and the service tag assigned to the switch.

**Example**

```
OS10# show license status
System Information
---------------------------------------------------------
Vendor Name          :   DELL
Product Name         :   S4148F-ON
Hardware Version     :   X01
Platform Name        :   x86_64-dell_s4100_c2338-r0
PPID                 :   TW09H9MN282987130026
Service Tag          :   9531XC2
Product Base         :
Product Serial Number:
Product Part Number  :
License Details
----------------
Software        :        OS10-Enterprise
Version         :        10.5.5.0P1
License Type    :        PERPETUAL
License Duration:        Unlimited
License Status  :        Active
License location:        /mnt/license/9531XC2.lic
--------------------------------------------------------
```

**Supported Releases:** 10.3.0E or later

---

#### show running-configuration

Displays the configuration currently running on the device.

**Syntax**

```
show running-configuration [aaa | access-list | as-path | bfd | bgp
[vrf vrf-name] [neighbor {ip-address | interface interface-type | class-
map | community-list | compressed | control-plane | crypto | dot1x |
extcommunity-list | evpn | fefd | igmp | interface [virtual-network vn-
id] | ip dhcp snooping | lacp | line | lldp | logging | management-route
| mld | monitor | ntp | nve | ospf | ospfv3 | password-attributes | pim |
policy-map | port-security | prefix-list | privilege | qos-map | radius-
server | route | route-map | sflow | smartfabric | snmp | spanning-tree
| support-assist | system-qos | tacacs-server | telemetry | trust-map |
uplink-state-group | userrole | users | virtual-network | vlt | vrf |
wred-profile]
```

**Parameters**

- `aaa` -- (Optional) Current operating AAA configuration.
- `access-list` -- (Optional) Current operating access-list configuration.
- `as-path` -- (Optional) Current operating as-path configuration.
- `bfd` -- (Optional) Current operating BFD configuration.
- `bgp` -- (Optional) Current operating BGP configuration.
  - `[vrf vrf-name]` -- Enter the VRF name.
  - `[neighbor [ip-address | interface interface-type` -- Enter the interface IP address or interface name.
- `class-map` -- (Optional) Current operating class-map configuration.
- `community-list` -- (Optional) Current operating community-list configuration.
- `compressed` -- (Optional) Current operating configuration in compressed format.
- `control-plane` -- (Optional) Current operating control-plane configuration.
- `crypto` -- (Optional) Current operating cryptographic configuration.
- `dot1x` -- (Optional) Current operating dot1x configuration.
- `evpn` -- (Optional) Current operating EVPN configuration.
- `extcommunity-list` -- (Optional) Current operating extcommunity-list configuration.
- `interface` -- (Optional) Current operating interface configuration.
  - `virtual-network vn-id` -- (Optional) Current virtual network configuration.
- `fefd` -- (Optional) Current operating FEFD configuration.
- `igmp` -- (Optional) Current operating IGMP configuration.
- `ip dhcp snooping` -- (Optional) Current operating DHCP snooping information.
- `lacp` -- (Optional) Current operating LACP configuration.
- `lldp` -- (Optional) Current operating LLDP configuration.
- `logging` -- (Optional) Current operating logging configuration.
- `management-route` -- (Optional) Current operating management route configuration.
- `mld` -- (Optional) Current operating MLD configuration.
- `monitor` -- (Optional) Current operating monitor session configuration.
- `ntp` -- (Optional) Current operating NTP configuration.
- `nve` -- (Optional) Current operating NVE configuration.
- `ospf` -- (Optional) Current operating OSPF configuration.
- `ospfv3` -- (Optional) Current operating OSPFv3 configuration.
- `password-attributes` -- (Optional) Current operating passwords attributes configuration.
- `pim` -- (Optional) Current operating PIM configuration.
- `port-security` -- (Optional) Current operating port security configuration.
- `policy-map` -- (Optional) Current operating policy-map configuration.
- `prefix-list` -- (Optional) Current operating prefix-list configuration.
- `privilege` -- (Optional) Current operating user privilege configuration.
- `qos-map` -- (Optional) Current operating qos-map configuration.
- `radius-server` -- (Optional) Current operating radius-server configuration.
- `route` -- (Optional) Current operating management route configuration.
- `route-map` -- (Optional) Current operating route-map configuration.
- `sflow` -- (Optional) Current operating sFlow configuration.
- `smartfabric` -- (Optional) Current operating SmartFabric configuration.
- `snmp` -- (Optional) Current operating SNMP configuration.
- `spanning-tree` -- (Optional) Current operating spanning-tree configuration.
- `support-assist` -- (Optional) Current operating support-assist configuration.
- `system-qos` -- (Optional) Current operating system-qos configuration.
- `tacacs-server` -- (Optional) Current operating TACACS server configuration.
- `telemetry` -- (Optional) Current operating telemetry configuration.
- `trust-map` -- (Optional) Current operating trust-map configuration.
- `uplink-state-group` -- (Optional) Current operating Uplink State Group configuration.
- `users` -- (Optional) Current operating users configuration.
- `userrole` -- (Optional) Current operating user role configuration.
- `virtual-network` -- (Optional) Current operating virtual network configuration.
- `vlt` -- (Optional) Current operating VLT domain configuration.
- `vrf` -- (Optional) Current operating VRF configuration.
- `wred-profile` -- (Optional) Current operating WRED profile configuration.

**Default:** Not configured

**Command Mode:** EXEC

**Usage Information:** None

**Example**

```
OS10# show running-configuration
! Version 10.2.9999E
! Last configuration change at Apr  11 01:25:02 2017
!
username admin
password $6$q9QBeYjZ$jfxzVqGhkxX3smxJSH9DDz7/3OJc6m5wjF8nnLD7/
VKx8SloIhp4NoGZs0I/UNwh8WVuxwfd9q4pWIgNs5BKH.
aaa authentication local
snmp-server contact http://www.dell.com/support
snmp-server location "United States"
logging monitor disable
ip route 0.0.0.0/0 10.11.58.1
!
interface ethernet1/1/1
 switchport access vlan 1
 no shutdown
!
interface ethernet1/1/2
 switchport access vlan 1
 no shutdown
!
interface ethernet1/1/3
 switchport access vlan 1
 no shutdown
!
interface ethernet1/1/4
 switchport access vlan 1
 no shutdown
!
interface ethernet1/1/5
 switchport access vlan 1
 no shutdown
!
interface ethernet1/1/6
 switchport access vlan 1
 no shutdown
--more--
```

**Example (compressed)**

```
OS10# show running-configuration compressed
username admin
password $6$q9QBeYjZ$jfxzVqGhkxX3smxJSH9DDz7/3OJc6m5wjF8nnLD7/
VKx8SloIhp4NoGZs0I/UNwh8WVuxwfd9q4pWIgNs5BKH.
aaa authentication local
snmp-server contact http://www.dell.com/support
snmp-server location "United States"
logging monitor disable
ip route 0.0.0.0/0 10.11.58.1
!
interface range ethernet 1/1/1-1/1/32
 switchport access vlan 1
 no shutdown
!
interface vlan 1
 no shutdown
!
interface mgmt1/1/1
 ip address 10.11.58.145/8
 no shutdown
 ipv6 enable
 ipv6 address autoconfig
!
support-assist
!
policy-map type application policy-iscsi
!
class-map type application class-iscsi
```

**Example (password-attributes)**

```
OS10(config)# show running-configuration password-attributes
!
password-attributes password-expiry 200
password-attributes character-restriction upper 2
password-attributes character-restriction lower 2
password-attributes character-restriction numeric 2
password-attributes min-length 6
```

**Example (users)**

```
OS10(config)# show running-configuration users
username admin password **** role sysadmin priv-lvl 15
username delluser password **** role sysadmin priv-lvl 15 password-expiry 210
```

**Supported Releases:** 10.2.0E or later

---

#### show startup-configuration

Displays the contents of the startup configuration file.

**Syntax**

```
show startup-configuration [compressed]
```

**Parameters:** `compressed` -- (Optional) View a compressed version of the startup configuration file.

**Default:** Not configured

**Command Mode:** EXEC

**Usage Information:** None

**Example**

```
OS10# show startup-configuration
username admin
password $6$q9QBeYjZ$jfxzVqGhkxX3smxJSH9DDz7/3OJc6m5wjF8nnLD7/
VKx8SloIhp4NoGZs0I/UNwh8WVuxwfd9q4pWIgNs5BKH.
aaa authentication local
snmp-server contact http://www.dell.com/support
snmp-server location "United States"
ip route 0.0.0.0/0 10.11.58.1
!
interface ethernet1/1/1
 switchport access vlan 1
 no shutdown
!
interface ethernet1/1/2
 switchport access vlan 1
 no shutdown
!
interface ethernet1/1/3
 switchport access vlan 1
 no shutdown
!
interface ethernet1/1/4
 switchport access vlan 1
 no shutdown
!
interface ethernet1/1/5
 switchport access vlan 1
 no shutdown
!
--more--
```

**Example (compressed)**

```
OS10# show startup-configuration compressed
username admin
password $6$q9QBeYjZ$jfxzVqGhkxX3smxJSH9DDz7/3OJc6m5wjF8nnLD7/
VKx8SloIhp4NoGZs0I/UNwh8WVuxwfd9q4pWIgNs5BKH.
aaa authentication local
snmp-server contact http://www.dell.com/support
snmp-server location "United States"
ip route 0.0.0.0/0 10.11.58.1
!
interface range ethernet 1/1/1-1/1/32
 switchport access vlan 1
 no shutdown
!
interface vlan 1
 no shutdown
!
interface mgmt1/1/1
 ip address 10.11.58.145/8
 no shutdown
 ipv6 enable
 ipv6 address autoconfig
!
support-assist
!
policy-map type application policy-iscsi
!
class-map type application class-iscsi
```

**Supported Releases:** 10.2.0E or later

---

#### show system

Displays system information.

**Syntax**

```
show system [brief | node-id]
```

**Parameters**

- `brief` -- View an abbreviated list of the system information.
- `node-id` -- View the node ID number.

**Default:** Not configured

**Command Mode:** EXEC

**Usage Information**

Starting from Release 10.5.4.0, this command displays the following additional information:

- Firmware details of the switch such as ONIE version, ONIE firmware updater version, SSD version, DIAG OS version, and PCIe version.
- Input power, average input power, and average power start time per power supply unit (PSU).

This command displays the average power consumption per power supply unit (PSU) additionally on the following platforms:

- Release 10.5.5.5 and later
  - S5224F-ON
  - S5248F-ON
  - S5296F-ON
  - S5448F-ON
  - Z9432F-ON
- Release 10.5.6.4 and later
  - E3224F-ON
  - Z9264F-ON
  - Z9664F-ON

**Example**

```
OS10# show system
Node Id              : 1
MAC                  : e8:b5:d0:0e:0e:00
Number of MACs       : 640
Up Time              : 00:00:53
DiagOS               : 3.54.3.5-2
PCIe Version         : 2.10
-- Unit 1 --
Status                     : up
Down Reason                : unknown
Digital Optical Monitoring : disable
System Location LED        : off
Required Type              : Z9664F
Current Type               : Z9664F
Hardware Revision          : X01
Software Version           : 10.5.6.4
Physical Ports             : 64x400GbE, 2x10G
BaseBoard CPLD                :   0.13
ONIE                          :   3.54.1.D-4
BMC                           :   2.00
BIOS                          :   3.54.0.D-6
Port CPLD2                    :   1.1
OCORE-FPGA@pci_0000_01_00.0   :   1.8
Firmware Updater              :   3.54.5.1-1
SSD                           :   SBR13000
Port CPLD1                    :   1.1
-- Power Supplies --
PSU-ID Status Type Power(w) AvgPower(w) AvgPowerStartTime AirFlow
------------------------------------------------------------------
1      up     AC   160      160         02/01/2024-17:46  NORMAL
2      up     AC   160      160         02/01/2024-17:46  REVERSE
     Fan  Speed(rpm)  Status
     ------------------------
     1    9180        up
     1    6375        up
-- Fan Status --
FanTray  Status  AirFlow   Fan  Speed(rpm)  Status
---------------------------------------------------
1        up      NORMAL    1    8107        up
                           2    7504        up
2        up      NORMAL    1    7973        up
                           2    7437        up
3        up      NORMAL    1    8107        up
                           2    7504        up
4        up      NORMAL    1    8107        up
                           2    7504        up
```

**Example (node-id)**

```
OS10# show system node-id 1 fanout-configured
Interface      Breakout capable     Breakout state
-----------------------------------------------------
Eth 1/1/5         No                BREAKOUT_1x1
Eth 1/1/6         No                BREAKOUT_1x1
Eth 1/1/7         No                BREAKOUT_1x1
Eth 1/1/8         No                BREAKOUT_1x1
Eth 1/1/9         No                BREAKOUT_1x1
Eth 1/1/10        No                BREAKOUT_1x1
Eth 1/1/11        No                BREAKOUT_1x1
Eth 1/1/12        No                BREAKOUT_1x1
Eth 1/1/13        No                BREAKOUT_1x1
Eth 1/1/14        No                BREAKOUT_1x1
Eth 1/1/15        No                BREAKOUT_1x1
Eth 1/1/16        No                BREAKOUT_1x1
Eth 1/1/17        No                BREAKOUT_1x1
Eth 1/1/18        No                BREAKOUT_1x1
Eth 1/1/19        No                BREAKOUT_1x1
Eth 1/1/20        No                BREAKOUT_1x1
Eth 1/1/21        No                BREAKOUT_1x1
Eth 1/1/22        No                BREAKOUT_1x1
Eth 1/1/23        No                BREAKOUT_1x1
Eth 1/1/24        No                BREAKOUT_1x1
Eth 1/1/25        Yes               BREAKOUT_1x1
```

**Example (brief)**

```
OS10# show system brief
Node Id           : 1
MAC               : 14:18:77:15:c3:e8
-- Unit --
Unit  Status      ReqType     CurType     Version
----------------------------------------------------------------
1     up          S4148F      S4148F      10.5.1.0
-- Power Supplies --
PSU-ID  Status      Type    AirFlow   Fan  Speed(rpm)  Status
----------------------------------------------------------------
1       up          AC      NORMAL    1    13312       up
2       fail
-- Fan Status --
FanTray  Status      AirFlow   Fan  Speed(rpm)  Status
----------------------------------------------------------------
1        up          NORMAL    1    13195       up
2        up          NORMAL    1    13151       up
3        up          NORMAL    1    13239       up
4        up          NORMAL    1    13239       up
```

**Supported Releases:** 10.2.0E or later

---

#### show version

Displays software version information.

**Syntax**

```
show version
```

**Parameters:** None

**Default:** Not configured

**Command Mode:** EXEC

**Usage Information:** None

**Example**

```
OS10# show version
Dell SmartFabric OS10 Enterprise
Copyright (c) 1999-2024 by Dell Inc. All Rights Reserved.
OS Version: 10.6.0.1
Build Version: 10.6.0.1.215
Build Time: 2023-04-01T21:35:41+0000
System Type: S5248F-ON
Architecture: x86_64
Up Time: 1 day 00:54:13
```

**Supported Releases:** 10.2.0E or later

---

#### start

Activates Transaction-Based Configuration mode for the active session.

**Syntax**

```
start transaction
```

**Parameters:** `transaction` -- Enables the transaction-based configuration.

**Default:** Not configured

**Command Mode:** EXEC

**Usage Information:** Use the `start` command to save changes to the candidate configuration before applying configuration changes to the running configuration.

> **NOTE:** Before you start a transaction, you must lock the session using the `lock` command in EXEC mode. Otherwise, the configuration changes from other sessions are committed.

**Example**

```
OS10# start transaction
```

**Supported Releases:** 10.3.1E or later

---

#### system

Runs a Linux command from within OS10.

**Syntax**

```
system command
```

**Parameters:** `command` -- Enter the Linux command to run.

**Default:** Not configured

**Command Mode:** EXEC

**Usage Information:** None

**Example**

```
OS10# system bash
admin@OS10:~$ pwd
/config/home/admin
admin@OS10:~$ exit
OS10#
```

**Supported Releases:** 10.2.0E or later

---

#### system-cli disable

Disables the system command.

**Syntax**

```
system-cli disable
```

**Parameters:** None

**Default:** Enabled

**Command Mode:** CONFIGURATION

**Usage Information:** The `no` version of this command enables OS10 system command.

**Example**

```
OS10# configure terminal
OS10(config)# system-cli disable
```

**Supported Releases:** 10.4.3.0 or later

---

#### system-user linuxadmin disable

Disables the linuxadmin account.

**Syntax**

```
system-user linuxadmin disable
```

**Parameters:** None

**Default:** Not configured

**Command Mode:** CONFIGURATION

**Usage Information:** The `linuxadmin` account allows you to access the Linux shell. Use the `system-user linuxadmin disable` command to disable Linux shell access. You can still run Linux commands from the OS10 command-line interface using the `system` command. To disable the `system` command from running Linux commands, use the `system-cli disable` command.

**Example**

```
OS10(config)# system-user linuxadmin disable
```

**Supported Releases:** 10.4.3.0 or later

---

#### system identifier

Sets a nondefault unit ID in a nonstacking configuration.

**Syntax**

```
system identifier system-id
```

**Parameters:** `system-id` -- Enter the system ID, from 1 to 9.

**Default:** Not configured

**Command Mode:** CONFIGURATION

**Usage Information:** The system ID displays in the stack LED on the switch front panel.

**Example**

```
OS10(config)# system identifier 1
```

**Supported Releases:** 10.3.0E or later

---

#### terminal

Sets the number of lines to display on the terminal and enables logging.

**Syntax**

```
terminal {length lines | monitor}
```

**Parameters**

- `length lines` -- Enter the number of lines to display on the terminal from 0 to 512; default 24.
- `monitor` -- Enables logging on the terminal.

**Default:** 24 terminal lines

**Command Mode:** EXEC

**Usage Information:** Enter zero (0) for the terminal to display without pausing.

**Example**

```
OS10# terminal monitor
```

**Supported Releases:** 10.2.0E or later

---

#### traceroute

Displays the routes that packets take to travel to an IP address.

**Syntax**

```
traceroute [vrf {management | vrf-name}] host [-46dFITnreAUDV] [-f
first_ttl] [-g gate,...] [-i device] [-m max_ttl] [-N squeries] [-p port]
[-t tos] [-l flow_label] [-w waittime] [-q nqueries] [-s src_addr] [-z
sendwait] [--fwmark=num] host [packetlen]
```

**Parameters**

- `vrf management` -- (Optional) Traces the route to an IP address in the management VRF instance.
- `vrf vrf-name` -- (Optional) Traces the route to an IP address in the specified VRF instance.
- `host` -- Enter the host to trace packets from.
- `-i interface` -- (Optional) Enter the IP address of the interface through which traceroute sends packets. By default, the interface is selected according to the routing table.
- `-m max_ttl` -- (Optional) Enter the maximum number of hops for the maximum time-to-live value that traceroute probes. The default is 30.
- `-p port` -- (Optional) Enter a destination port:
  - For UDP tracing, enter the destination port base that traceroute uses. The destination port number is incremented by each probe.
  - For ICMP tracing, enter the initial ICMP sequence value, incremented by each probe.
  - For TCP tracing, enter the constant destination port to connect.
- `-P protocol` -- (Optional) Use a raw packet of the specified protocol for traceroute. The default protocol is 253 (RFC 3692).
- `-s source_address` -- (Optional) Enter an alternative source address of one of the interfaces. By default, the address of the outgoing interface is used.
- `-q nqueries` -- (Optional) Enter the number of probe packets per hop. The default is 3.
- `-N squeries` -- (Optional) Enter the number of probe packets sent out simultaneously to accelerate traceroute. The default is 16.
- `-t tos` -- (Optional) For IPv4, enter the type of service (ToS) and precedence values to use. 16 sets a low delay; 8 sets a high throughput.
- `-UL` -- (Optional) Use UDPLITE for tracerouting. The default port is 53.
- `-w waittime` -- (Optional) Enter the time in seconds to wait for a response to a probe. The default is 5 seconds.
- `-z sendwait` -- (Optional) Enter the minimal time interval to wait between probes. The default is 0. A value greater than 10 specifies a number in milliseconds, otherwise it specifies a number of seconds. This option is useful when routers rate-limit ICMP messages.
- `--mtu` -- (Optional) Discovers the maximum transmission unit (MTU) from the path being traced.
- `--back` -- (Optional) Prints the number of backward hops when different from the forward direction.
- `host` -- (Required) Enter the name or IP address of the destination device.
- `packet_len` -- (Optional) Enter the total size of the probing packet. The default is 60 bytes for IPv4 and 80 for IPv6.

**Default:** Not configured

**Command Mode:** EXEC

**Usage Information:** None

**Example**

```
OS10# traceroute www.dell.com
traceroute to www.dell.com (23.73.112.54), 30 hops max, 60 byte packets
 1  10.11.97.254 (10.11.97.254)  4.298 ms  4.417 ms  4.398 ms
 2  10.11.3.254 (10.11.3.254)  2.121 ms  2.326 ms  2.550 ms
 3  10.11.27.254 (10.11.27.254)  2.233 ms  2.207 ms  2.391 ms
 4  Host65.hbms.com (63.80.56.65)  3.583 ms  3.776 ms  3.757 ms
 5  host33.30.198.65 (65.198.30.33)  3.758 ms  4.286 ms  4.221 ms
 6  3.GigabitEthernet3-3.GW3.SCL2.ALTER.NET (152.179.99.173)  4.428 ms  2.593 ms  3.243 ms
 7  0.xe-7-0-1.XL3.SJC7.ALTER.NET (152.63.48.254)  3.915 ms  3.603 ms  3.790 ms
 8  TenGigE0-4-0-5.GW6.SJC7.ALTER.NET (152.63.49.254)  11.781 ms  10.600 ms  9.402 ms
 9  23.73.112.54 (23.73.112.54)  3.606 ms  3.542 ms  3.773 ms
```

**Example (IPv6)**

```
OS10# traceroute 20::1
traceroute to 20::1 (20::1), 30 hops max, 80 byte packets
 1  20::1 (20::1)  2.622 ms  2.649 ms  2.964 ms
```

**Supported Releases:** 10.2.0E or later

---

#### unlock

Unlocks a previously locked candidate configuration file.

**Syntax**

```
unlock
```

**Parameters:** None

**Default:** Not configured

**Command Mode:** EXEC

**Usage Information:** None

**Example**

```
OS10# unlock
```

**Supported Releases:** 10.2.0E or later

---

#### usb enable

Enables or disables USB access.

**Syntax**

```
[no] usb enable
```

**Parameters:** None

**Default:** Disabled

**Security and Access:** sysadmin

**Command Mode:** CONFIGURATION

**Usage Information:** This command is used to enable or disable USB drives. The `no` version of this command disables all the USB drives in the switch.

**Example (Enable USB)**

```
OS10(config)# usb enable
```

**Example (Disable USB)**

```
OS10(config)# no usb enable
```

**Supported Releases:** 10.5.5.5 or later

---

#### username password role

Creates an authentication entry based on a username and password, and assigns a role to the user.

**Syntax**

```
username username password password role role [priv-lvl privilege-level]
[password-expiry expiry-time]
```

**Parameters**

- `username username` -- Enter a text string. It must contain a minimum of one and a maximum of 32 alphanumeric characters.

> **NOTE:** While creating a user account using the `username password role` command, the username attribute must adhere to the following regular expression: `^[a-z_][a-z0-9_-]*[$]?$`

- `password password` -- Enter a text string. A maximum of 32 alphanumeric characters; nine characters minimum. Password prefixes `$1$`, `$5$`, and `$6$` are not supported in clear-text passwords.
- `role role` -- Enter a user role:
  - `sysadmin` -- Full access to all commands in the system, exclusive access to commands that manipulate the file system, and access to the system shell. A system administrator can create user IDs and user roles.
  - `secadmin` -- Full access to configuration commands that set security policy and system access, such as password strength, AAA authorization, and cryptographic keys. A security administrator can display security information, such as cryptographic keys, login statistics, and log information.
  - `netadmin` -- Full access to configuration commands that manage traffic flowing through the switch, such as routes, interfaces, and ACLs. A network administrator cannot access configuration commands for security features or view security information.
  - `netoperator` -- Access to EXEC mode to view the current configuration with limited access. A network operator cannot modify any configuration setting on a switch.
- `priv-lvl privilege-level` -- Enter a privilege level, from 0 to 15. If you do not specify the `priv-lvl` option, the system assigns privilege level 1 for the `netoperator` role and privilege level 15 for the `sysadmin`, `secadmin`, and `netadmin` roles.
- `password-expiry expiry-time` -- (Optional) Enter the password expiration time in days, from 60 to 240 days. Starting from 10.5.5.5, if this parameter is not specified, this command sets the password expiration time to 0, indicating that the password never expires and password change is not enforced upon first login. From Release 10.5.5.0 up to 10.5.5.4, the default password expiration time is set to 180 days.

**Default**

- User name and password entries are in clear text.
- There is no default user role.
- The default privilege levels are level 1 for `netoperator`, and level 15 for `sysadmin`, `secadmin`, and `netadmin`.
- If you do not configure the password expiration time for a user account, the global password expiration time is used by default.

**Security and Access:** sysadmin and secadmin

**Command Mode:** CONFIGURATION

**Usage Information**

By default, the password must be at least nine alphanumeric characters. Only the following special characters are supported:

```
! # % & ' ( ) ; < = > [ ] * + - . / : ^ _
```

Enter the password in clear text. It is converted to SHA-512 format in the running configuration. For backward compatibility with OS10 releases 10.3.1E and earlier, passwords entered in MD-5, SHA-256, and SHA-512 formats are supported. To create a hash value for a plain text password, you can use the passlib library in Python. For example:

```python
from passlib.hash import sha256_crypt
>>> sha256_crypt.hash("Delluser@123")
'$5$rounds=535000$4a83B3VeM6lrKmWQ$lPJfqHBnCY4rtuCM1PsyUqOeY7kIFxJpbmsde4PV4g4'
```

You can follow the same process for MD5 and SHA-512 hashes as well. Use the generated hash value in the command as shown below:

```
OS10(config)# username delluser password
************************************************************************
******* role sysadmin
OS10(config)#
```

> **NOTE:** When you create or modify a password, the password string that you input appears as a string of asterisks instead of plain text.

You cannot assign a privilege level higher than privilege level 1 to a user with the `netoperator` role and higher than privilege level 2 for a `sysadmin`, `secadmin`, and `netadmin` roles. To increase the required password strength, use the `password-attributes` command. The `no` version of this command deletes the authentication for a user. Supported on the MX9116n and MX5108n switches in Full Switch mode starting in release 10.4.0E(R3S). Also supported in SmartFabric mode starting in release 10.5.0.1. To set the password expiration time for a specific user, use the `password-expiry` parameter. If you do not want the password to expire, set the expiration time to 0.

> **NOTE:** When a user logs in for the first time using the temporary password that is set up during the creation of their user account, OS10 prompts the user to change the password. To disable the prompt for resetting the temporary password for a specific user account, set the password expiration time to 0. Starting from Release 10.5.5.0P1, use the `password-change` command to change the password.

Starting from Release 10.6.1.0, this command is accessible to the secadmin role. Users with the secadmin role can only modify user passwords and cannot change any other user settings or parameters. The secadmin role does not have permission to modify the sysadmin user account.

**Example**

```
OS10(config)# username delluser password newpwd404 role sysadmin priv-lvl 10 password-expiry 230
```

**Supported Releases**

- 10.2.0E or later
- 10.6.1.0 or later -- Accessible to the secadmin role.

---

#### write

Copies the current running configuration to the startup configuration file.

**Syntax**

```
write {memory}
```

**Parameters:** `memory` -- Copy the current running configuration to the startup configuration.

**Default:** Not configured

**Command Mode:** EXEC

**Usage Information:** This command has the same effect as the `copy running-configuration startup-configuration` command. The running configuration is not saved to a local configuration file other than the startup configuration. Use the `copy` command to save running configuration changes to a local file.

**Example**

```
OS10# write memory
```

**Supported Releases:** 10.2.0E or later
