# Advanced CLI Tasks

## Overview

| Topic | Description |
|-------|-------------|
| Command alias | Provides information to create shortcuts for commonly used commands. |
| Batch mode | Provides information to run a batch file to perform multiple commands. |
| Linux shell commands | Provides information to run commands from the Linux shell. |
| OS9 commands | Provides information to enter configuration commands using an OS9 command syntax. |

## Command Alias

To create shortcuts for commonly used or long commands, use the `alias` command. A command alias executes long commands with parameters.

- To create a command alias that is persistent and available in other OS10 sessions, create the alias in CONFIGURATION mode.
- To create a command alias that is non-persistent and is used only in the current OS10 session, create the alias in EXEC mode. After you close the session, the alias is removed from the switch.

Create a command alias in EXEC or CONFIGURATION mode.

```
alias alias-name alias-value
```

- The `alias-name` is case-sensitive and has a maximum of 20 characters. It does not support existing keywords, parameters, and short form of keywords.
- The `alias-value` is the CLI command executed by the alias name. To enter command parameters, enter `$n`, where `n` is a number from 1 to 9 or an asterisk (`*`). Enter `$*` to enter up to nine parameters with the alias name.
- You cannot create a shortcut for the `alias` command.
- To delete an alias, use the `no alias alias-name` command.
- To view the currently configured aliases, use the `show alias [brief | detail]` command.

### Create an alias

```
OS10# alias showint "show interface $*"
OS10(config)# alias goint "interface ethernet $1"
```

### View alias output for showint

```
OS10# showint status
---------------------------------------------------------------------------------
Port            Description     Status   Speed    Duplex   Mode Vlan Tagged-Vlans
---------------------------------------------------------------------------------
Eth 1/1/1                       up       40G               A    1    -
Eth 1/1/2                       up       40G               A    1    -
Eth 1/1/3                       up       40G               A    1    -
Eth 1/1/4                       up       40G               A    1    -
Eth 1/1/5                       up       40G               A    1    -
Eth 1/1/6                       up       40G               A    1    -
Eth 1/1/7                       up       40G               A    1    -
Eth 1/1/8                       up       40G               A    1    -
Eth 1/1/9                       up       40G               A    1    -
Eth 1/1/10                      up       40G               A    1    -
...
```

### View alias output for goint

```
OS10(config)# goint 1/1/1
OS10(conf-if-eth1/1/1)#
```

### View alias information

```
OS10# show alias
Name                 Type
----                 ----
govlt                Config
goint                Config
shconfig             Local
showint              Local
shver                Local
Number of config aliases : 2
Number of local aliases : 3
```

### View alias information brief

Displays the first 10 characters of the alias value.

```
OS10# show alias brief
Name                 Type        Value
----                 ----        -----
govlt                Config      "vlt-domain..."
goint                Config      "interface ..."
shconfig             Local       "show runni..."
showint              Local       "show inter..."
shver                Local       "show versi..."
Number of config aliases : 2
Number of local aliases : 3
```

### View alias information in detail

Displays the entire alias value.

```
OS10# show alias detail
Name                 Type        Value
----                 ----        -----
govlt                Config      "vlt-domain $1"
goint                Config      "interface ethernet $1"
shconfig             Local       "show running-configuration"
showint              Local       "show interface $*"
shver                Local       "show version"
Number of config aliases : 2
Number of local aliases : 3
```

### Multiline Alias

You can create a multiline alias where you save a series of multiple commands in an alias. Multiline alias is supported only in the Configuration mode.

You cannot use the existing CLI keywords as alias names. The alias name is case-sensitive and can have a maximum of 20 characters.

- Create a multiline alias in CONFIGURATION mode. The switch enters the ALIAS mode.

  ```
  alias alias-name
  ```

- Enter the commands to run prefixed by the `line n` command in ALIAS mode. Enter the commands in double quotation marks and use `$n` to enter input parameters. You can substitute `$n` with either numbers ranging from 1 to 9 or with an asterisk (`*`) and enter the parameters while running the commands using the alias. When you are using asterisk (`*`), you can use all the input parameters. The maximum number of input parameters is 9.

  ```
  line nn command
  ```

- (Optional) You can enter the default values to use for the parameters that are defined as `$n` in ALIAS mode.

  ```
  default n input-value
  ```

- (Optional) Enter a description for the multiline alias in ALIAS mode.

  ```
  description string
  ```

- Use the `no` form of the command to delete an alias in CONFIGURATION mode.

  ```
  no alias alias-name
  ```

You can modify an existing multiline alias by entering the corresponding ALIAS mode.

### Create a multiline alias

```
OS10(config)# alias mTest
OS10(config-alias-mTest)# line 1 "interface $1 $2"
OS10(config-alias-mTest)# line 2 "no shutdown"
OS10(config-alias-mTest)# line 3 "show configuration"
OS10(config-alias-mTest)# default 1 "ethernet"
OS10(config-alias-mTest)# default 2 "1/1/1"
OS10(config-alias-mTest)# description InterfaceDetails
```

### View alias output for mTest with default values

```
OS10(config)# mTest
OS10(config)# interface ethernet 1/1/1
OS10(conf-if-eth1/1/1)# no shutdown
OS10(conf-if-eth1/1/1)# show configuration
!
interface ethernet1/1/1
 no shutdown
 switchport access vlan 1
```

### View alias output for mTest with different values

```
OS10(config)# mTest ethernet 1/1/10
OS10(config)# interface ethernet 1/1/10
OS10(conf-if-eth1/1/10)# no shutdown
OS10(conf-if-eth1/1/10)# show configuration
!
interface ethernet1/1/10
 no shutdown
 switchport access vlan 1
```

### Modify an existing multiline alias

```
OS10(config)# alias mTest
OS10(config-alias-mTest)# line 4 "exit"
```

### View the commands saved in the multiline alias

```
OS10(config-alias-mTest)# show configuration
!
alias mTest
 description InterfaceDetails
 default 1 ethernet
 default 2 1/1/1
 line 1 "interface $1 $2"
 line 2 "no shutdown"
 line 3 "show configuration"
 line 4 exit
```

### View alias information (multiline)

```
OS10# show alias
Name                 Type
----                 ----
mTest                Config
Number of config aliases : 1
Number of local aliases : 0
```

### View alias information brief (multiline)

Displays the first 10 characters of each line of each alias.

```
OS10# show alias brief
Name                 Type        Value
----                 ----        -----
mTest                Config      line 1 "interface ..."
                                 line 2 "no shutdow..."
                                 line 3 "show confi..."
                                 default 1 "ethernet"
                                 default 2 "1/1/1"
Number of config aliases : 1
Number of local aliases : 0
```

### View alias detail (multiline)

Displays the entire alias value.

```
OS10# show alias detail
Name                 Type        Value
----                 ----        -----
mTest                Config      line 1 "interface $1 $2"
                                 line 2 "no shutdown"
                                 line 3 "show configuration"
                                 default 1 "ethernet"
                                 default 2 "1/1/1"
Number of config aliases : 1
Number of local aliases : 0
```

### Delete an alias

```
OS10(config)# no alias mTest
```

## Command Reference: Command Alias

### alias

Creates a command alias.

**Syntax**

```
alias alias-name alias-value
```

**Parameters**

- `alias-name` -- Enter the name of the alias up to a maximum of 20 characters.
- `alias-value` -- Enter the command to run in double quotation marks, and then `$` followed by either numbers ranging from 1 to 9 or an asterisk (`*`) with the parameters to run in the command. Use asterisk (`*`) to represent any number of parameters.

**Default**

Not configured

**Command Mode**

- EXEC
- CONFIGURATION

**Usage Information**

Use this command to create a shortcut to long commands along with arguments. Use the numbers 1 to 9 along with `$` to provide input parameters. The `no` version of this command deletes an alias.

**Example**

In this example, when you enter `showint status`, the text on the CLI changes to `show interface status`. The alias changes to the command specified in the alias definition.

```
OS10# alias showint "show interface $*"
OS10# showint status
--------------------------------------------------------------------------
Port        Description     Status  Speed  Duplex  Mode Vlan Tagged-Vlans
--------------------------------------------------------------------------
Eth 1/1/1                   up      40G            A    1    -
Eth 1/1/2                   up      40G            A    1    -
Eth 1/1/3                   up      40G            A    1    -
Eth 1/1/4                   up      40G            A    1    -
Eth 1/1/5                   up      40G            A    1    -
Eth 1/1/6                   up      40G            A    1    -
Eth 1/1/7                   up      40G            A    1    -
Eth 1/1/8                   up      40G            A    1    -
Eth 1/1/9                   up      40G            A    1    -
Eth 1/1/10                  up      40G            A    1    -
Eth 1/1/11                  up      40G            A    1    -
Eth 1/1/12                  up      40G            A    1    -
Eth 1/1/13                  up      40G            A    1    -
Eth 1/1/14                  up      40G            A    1    -
Eth 1/1/15                  up      40G            A    1    -
Eth 1/1/16                  up      40G            A    1    -
Eth 1/1/17                  up      40G            A    1    -
Eth 1/1/18                  up      40G            A    1    -
Eth 1/1/19                  up      40G            A    1    -
Eth 1/1/20                  up      40G            A    1    -
Eth 1/1/21                  up      40G            A    1    -
Eth 1/1/22                  up      40G            A    1    -
Eth 1/1/23                  up      40G            A    1    -
Eth 1/1/24                  up      40G            A    1    -
Eth 1/1/25                  up      40G            A    1    -
Eth 1/1/26                  up      40G            A    1    -
Eth 1/1/27                  up      40G            A    1    -
Eth 1/1/28                  up      40G            A    1    -
Eth 1/1/29                  up      40G            A    1    -
Eth 1/1/30                  up      40G            A    1    -
Eth 1/1/31                  up      40G            A    1    -
Eth 1/1/32                  up      40G            A    1    -
--------------------------------------------------------------------------
```

In this example, when you enter `goint 1/1/1`, the text on the CLI changes to `interface ethernet 1/1/1`.

```
OS10(config)# alias goint "interface ethernet $1"
OS10(config)# goint 1/1/1
OS10(conf-if-eth1/1/1)#
```

**Supported Releases**

10.3.0E or later

### alias (multiline)

Creates a multiline command alias.

**Syntax**

```
alias alias-name
```

**Parameters**

- `alias-name` -- Enter the name of the multiline alias. A maximum of up to 20 characters.

**Default**

Not configured

**Command Mode**

CONFIGURATION

**Usage Information**

Use this command to save a series of multiple commands in an alias. The switch enters ALIAS mode when you create an alias. You can enter a series of commands to run using the `line` command. The `no` version of this command deletes an alias.

**Example**

```
OS10(config)# alias mTest
OS10(config-alias-mTest)# line 1 "interface $1 $2"
OS10(config-alias-mTest)# line 2 "no shutdown"
OS10(config-alias-mTest)# line 3 "show configuration"
```

**Supported Releases**

10.4.0E(R1) or later

### default (alias)

Configures default values for input parameters in a multiline alias.

**Syntax**

```
default n value
```

**Parameters**

- `n` -- Enter the number of the argument, from 1 to 9.
- `value` -- Enter the value for the input parameter.

**Default**

Not configured

**Command Mode**

ALIAS

**Usage Information**

To use special characters in the input parameter value, enclose the string in double quotation marks (`"`). The `no` version of this command removes the default value.

**Example**

```
OS10(config)# alias mTest
OS10(config-alias-mTest)# default 1 "ethernet 1/1/1"
```

**Supported Releases**

10.4.0E(R1) or later

### description (alias)

Configures a textual description for a multiline alias.

**Syntax**

```
description string
```

**Parameters**

- `string` -- Enter a text string for a multiline alias description.

**Default**

Not configured

**Command Mode**

ALIAS

**Usage Information**

- To use special characters as a part of the description string, enclose the string in double quotation marks (`"`).
- To use comma as a part of the description string add a double back slash before the comma.
- Spaces between characters are not preserved after entering this command unless you enclose the entire description in quotation marks, for example, `"text description."`.
- To overwrite any previous text strings that you configured as the description, enter a text string after the `description` command.
- The `no` version of this command removes the description.

**Example**

```
OS10(config)# alias mTest
OS10(config-alias-mTest)# description "This alias configures interfaces"
```

**Supported Releases**

10.4.0E(R1) or later

### line (alias)

Configures the commands to run in a multiline alias.

**Syntax**

```
line nn command
```

**Parameters**

- `nn` -- Enter the line number, from 1 to 99. The commands are run in the order of the line numbers.
- `command` -- Enter the command to run enclosed in double quotation marks (`"`).

**Default**

Not configured

**Command Mode**

ALIAS

**Usage Information**

The `no` version of this command removes the line number and the corresponding command from the multiline alias.

**Example**

```
OS10(config)# alias mTest
OS10(config-alias-mTest)# line 1 "interface $1 $2"
OS10(config-alias-mTest)# line 2 "no shutdown"
OS10(config-alias-mTest)# line 3 "show configuration"
```

**Supported Releases**

10.4.0E(R1) or later

### show alias

Displays configured alias commands available in both Persistent and Non-Persistent modes.

**Syntax**

```
show alias [brief | detail]
```

**Parameters**

- `brief` -- Displays brief information of the aliases.
- `detail` -- Displays detailed information of the aliases.

**Default**

None

**Command Mode**

EXEC

**Usage Information**

None

**Example**

```
OS10# show alias
Name                 Type
----                 ----
govlt                Config
goint                Config
mTest                Config
shconfig             Local
showint              Local
shver                Local
Number of config aliases : 3
Number of local aliases : 3
```

**Example (brief -- displays the first 10 characters of the alias value)**

```
OS10# show alias brief
Name                 Type        Value
----                 ----        -----
govlt                Config      "vlt-domain..."
goint                Config      "interface ..."
mTest                Config      line 1 "interface ..."
                                 line 2 "no shutdow..."
                                 line 3 "show confi..."
                                 default 1 "ethernet"
                                 default 2 "1/1/1"
shconfig             Local       "show runni..."
showint              Local       "show inter..."
shver                Local       "show versi..."
Number of config aliases : 3
Number of local aliases : 3
```

**Example (detail -- displays the entire alias value)**

```
OS10# show alias detail
Name                 Type        Value
----                 ----        -----
govlt                Config      "vlt-domain $1"
goint                Config      "interface ethernet $1"
mTest                Config      line 1 "interface $1 $2"
                                 line 2 "no shutdown"
                                 line 3 "show configuration"
                                 default 1 "ethernet"
                                 default 2 "1/1/1"
shconfig             Local       "show running-configuration"
showint              Local       "show interface $*"
shver                Local       "show version"
Number of config aliases : 3
Number of local aliases : 3
```

**Supported Releases**

10.3.0E or later

## Batch Mode

To execute a sequence of multiple commands, create and run a batch file. A batch file is an unformatted text file that contains two or more commands. Store the batch file in the home directory.

Use the `vi` editor or any other editor to create the batch file, then use the `batch` command to run the file. To run a series of commands in batch mode (non-interactive processing), use the `batch` command. OS10 automatically commits all commands in a batch file -- you do not have to enter the `commit` command.

If a command in the batch file fails, batch operation stops at that command. The remaining commands are not executed.

1. Create a batch file -- for example, `b.cmd` -- on a remote device by entering a series of commands.

   ```
   interface ethernet 1/1/1
   no shutdown
   no switchport
   ip address 172.17.4.1/24
   ```

2. Copy the command file to the home directory on the switch.

   ```
   OS10# copy scp://os10user:os10passwd@10.11.222.1/home/os10/b.cmd home://b.cmd
   OS10# dir home

   Directory contents for folder: home
   Date (modified)        Size (bytes)  Name
   ---------------------  ------------  ------
   2017-02-15T19:25:35Z   77            b.cmd

   ...
   ```

3. Execute the batch file using the `batch /home/username/filename` command in EXEC mode.

   ```
   OS10# batch /home/admin/b.cmd
   Jun 26 18:29:12 OS10 dn_l3_core_services[723]: Node.1-Unit.1:PRI:notice [os10:trap],
   %Dell (OS10) %log-notice:IP_ADDRESS_ADD: IP Address add is successful.
   IP 172.17.4.1/24 in VRF:default added successfully
   ```

4. (Optional) Verify the new commands in the running configuration.

   ```
   OS10# show running-configuration interface ethernet 1/1/1
   !
   interface ethernet1/1/1
   no shutdown
   no switchport
   ip address 172.17.4.1/24
   ```

### batch

Executes a series of commands in a batch file using non-interactive processing.

**Syntax**

```
batch {string | /home/filepath | config://filepath}
```

**Parameters**

- `string` -- Enter the batch file name.
- `/home/filepath` -- Enter the username and the filepath as follows: `batch /home/username/filename`.
- `config://filepath` -- Enter the filepath.

**Default**

Not configured

**Command Mode**

EXEC

**Usage Information**

Use this command to create a batch command file on a remote machine. Copy the command file to the home directory on your switch. This command executes commands in batch mode. OS10 automatically commits all commands in a batch file; you do not have to enter the `commit` command. To display the files stored in the home directory, enter `dir home`. To view the files stored in the home directory, use the `dir home` command.

**Example**

```
batch /home/admin/b.cmd
Jun 26 18:29:12 OS10 dn_l3_core_services[723]: Node.1-Unit.1:PRI:notice [os10:trap],
%Dell (OS10) %log-notice:IP_ADDRESS_ADD: IP Address add is successful.
IP 172.17.4.1/24 in VRF:default added successfully
```

**Supported Releases**

10.2.0E or later

## Linux Shell Commands

From the Linux shell, you can run a single command or a series of commands in a batch file.

> **NOTE:** When you log in through SSH as a `linuxadmin`, you may not be able to run commands such as `show running-configuration` and `configure terminal`. You can use the `sudo` command to run these commands as the admin user, for example:
>
> - `sudo -u admin clish -c 'show version'`
> - `sudo -u admin 'clish -B /home/admin/script_1.txt'`

### Linux command examples

**Run a single command using the `-c` option:**

```
admin@OS10:/opt/dell/os10/bin$ clish -c "show version"
New user admin logged in at session 10
Network Operating System
OS Version: 10.6.0.1
Build Version: 10.6.0.1.215
Build Time: 2024-04-12T21:35:41+0000
System Type: S5248F-ON
Architecture: x86_64
Up Time: 1 day 00:54:13
User admin logged out at session 10
admin@OS10:/opt/dell/os10/bin$
```

**Run a batch file using the `-B` option:**

1. Create a batch file -- for example, `batch_cfg.txt` -- with a series of executable commands.

   ```
   configure terminal
   router bgp 100
   neighbor 100.1.1.1
   remote-as 104
   no shutdown
   ```

2. Run the batch file.

   ```
   admin@OS10:/opt/dell/os10/bin$ clish -B ~/batch_cfg.txt
   New user admin logged in at session 15
   ```

3. Verify the BGP settings configured by the batch file.

   ```
   admin@OS10:/opt/dell/os10/bin$ clish -c "show running-configuration bgp"
   New user admin logged in at session 16
   !
   router bgp 100
    !
    neighbor 100.1.1.1
     remote-as 104
     no shutdown
   admin@OS10:/opt/dell/os10/bin$
   User admin logged out at session 16
   ```

**Display the interface configuration using `ifconfig -a`:**

The Linux kernel port numbers that correspond to front-panel port, link aggregation group (LAG), and VLAN interfaces are displayed. LAG interfaces are in `boportchannel-number` format. VLAN interfaces are in `brvlan-id` format. In this example, `e101-001-0` identifies port 1/1/1.

```
admin@OS10:~# ifconfig -a
e101-001-0: flags=4163<UP,BROADCAST,RUNNING,MULTICAST>  mtu 1500
        inet6 fe80::20c:29ff:feed:9ea9  prefixlen 64  scopeid 0x20<link>
     ether 00:0c:29:ed:9e:a9  txqueuelen 1000  (Ethernet)
        RX packets 266262  bytes 18763391 (17.8 MiB)
        RX errors 0  dropped 8293  overruns 0  frame 0
        TX packets 18754  bytes 3963136 (3.7 MiB)
        TX errors 0  dropped 0 overruns 0  carrier 0  collisions 0

bo1: flags=5123<UP,BROADCAST,MASTER,MULTICAST>  mtu 1500  >>>  port-channel
        inet6 fe80::20c:29ff:feed:9f11  prefixlen 64  scopeid 0x20<link>
        ether 00:0c:29:ed:9f:11  txqueuelen 1000  (Ethernet)
        RX packets 0  bytes 0 (0.0 B)
        RX errors 0  dropped 0  overruns 0  frame 0
        TX packets 0  bytes 0 (0.0 B)
        TX errors 0  dropped 1 overruns 0  carrier 0  collisions 0

br1: flags=4419<UP,BROADCAST,RUNNING,PROMISC,MULTICAST>  mtu 1500 >>> vlan1
        inet6 fe80::20c:29ff:feed:9f12  prefixlen 64  scopeid 0x20<link>
        ether 00:0c:29:ed:9f:12  txqueuelen 1000  (Ethernet)
        RX packets 257964  bytes 12155776 (11.5 MiB)
        RX errors 0  dropped 0  overruns 0  frame 0
        TX packets 10287  bytes 900262 (879.1 KiB)
        TX errors 0  dropped 0 overruns 0  carrier 0  collisions 0
```

**Capture packets using `tcpdump`:**

Use the `tcpdump -i kernel-port-number` command to capture all packets received on a specified port interface. Press `Ctrl+C` to stop the packet output display. For example, to capture the packets received on the Ethernet 1/1/1 interface, enter:

```
admin@OS10:~# tcpdump -i e101-001-0
tcpdump: verbose output suppressed, use -v or -vv for full protocol decode
listening on e101-001-0, link-type EN10MB (Ethernet), capture size 262144 bytes
11:35:07.538133 STP 802.1w, Rapid STP, Flags [Learn, Forward, Agreement], bridge-id
8001.00:0c:29:74:3b:7e.8204, length 43
11:35:07.538467 STP 802.1w, Rapid STP, Flags [Learn, Forward, Agreement], bridge-id
8001.00:0c:29:74:3b:7e.8204, length 43
11:35:08.416291 LLDP, length 343: OS10
11:35:09.067621 IP6 fe80::20c:29ff:feed:9f12 > ff02::1:ffed:9ea9: ICMP6, neighbor
solicitation, who has fe80::20c:29ff:feed:9ea9, length 32
^C
4 packets captured
4 packets received by filter
0 packets dropped by kernel
1 packet dropped by interface
root@OS10:~#
```

**Run show commands remotely using an SSH session:**

Only show commands are supported. Enter the `$ ssh admin@ip-address "show-command"` command, where `ip-address` is the IP address of the switch.

```
$ ssh admin@10.11.98.39 "show version"
admin@10.11.98.39's password:
Network Operating System
OS Version: 10.6.0.1
Build Version: 10.6.0.1.215
Build Time: 2024-04-12T21:35:41+0000
System Type: S5248F-ON
Architecture: x86_64
Up Time: 1 day 00:54:13
```

## Using OS9 Commands

To enter configuration commands using an OS9 command syntax, use the `feature config-os9-style` command in CONFIGURATION mode and log out of the session. If you do not log out of the OS10 session, configuration changes made with OS9 command syntaxes do not take effect. After you log in again, you can enter OS9 commands, but only in the new session.

For example, to use OS9 commands to configure VLAN 11 on Ethernet port 1/1/15:

```
OS10(config)# feature config-os9-style
OS10(config)# interface vlan 11
OS10(conf-if-vl-11)# tagged ethernet 1/1/15
OS10(conf-if-vl-11)# show configuration
!
interface vlan11
 no shutdown
 tagged ethernet 1/1/15
```

To disable OS9 configuration-style mode, use the `no feature config-os9-style` command.

### feature config-os9-style

Configures the command-line interface to accept OS9 command syntaxes.

**Syntax**

```
feature config-os9-style
```

**Parameters**

None

**Default**

Not configured

**Command Mode**

CONFIGURATION

**Usage Information**

After you enter the `feature config-os9-style` command, log out of the session and log back in. In the next session, you can enter configuration commands in OS9 syntax. The `no` version of the command disables the feature.

**Example**

```
OS10(config)# feature config-os9-style
OS10(config)# interface vlan 11
OS10(conf-if-vl-11)# tagged ethernet 1/1/15
```

**Supported Releases**

10.3.0E or later
