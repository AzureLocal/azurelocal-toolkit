# Security

Dell SmartFabric OS10 has several security features to protect the usability and integrity of the data available in the switch. OS10 also has security features to the user network from attacks and restrict network traffic.

## Switch security

Dell SmartFabric OS10 has various inbuilt security features to secure the administrative access to the switch.

## User management

OS10 controls the user access to the switch and what can they do after login based on the set roles and privileges.

### Configuration notes

All Dell PowerSwitches except S4200-Series, S5200 Series, and Z9332F-ON:

- **Admin User** — You can delete the default admin username, as long as there is a local user with sysadmin role present. The default admin user sees a warning message in MOTD, unless the user password is changed or the user is deleted.
- **Linux Admin User** — Password of the linuxadmin user must be modified via OS10 Command Line Interface (CLI). The linuxadmin user can also be enabled or disabled via another CLI.

Example (password modification):

```
OS10(config)# system-user linuxadmin password Dell@Force10!@
OS10(config)# exit
OS10# write memory
OS10#
OS10# exit
```

Example (disable):

```
OS10(config)# system-user linuxadmin disable
OS10(config)#
```

Example (enable):

```
OS10(config)# no system-user linuxadmin disable
OS10(config)#
```

> **NOTE:** Only the linuxadmin user has SFTP access to the OS10 switch.

### User accounts

OS10 allows you to create user accounts to access the OS10 switches. Each user account is defined with a username, password, and a role to limit OS10 switch access.

> **NOTE:** The time taken to login for nondefault users is longer compared to the default users (admin and linuxadmin), as long as the default users continue to use the default password. If the default password is changed for the default users, their login time also increases.

### Role-based access control

RBAC provides control for access and authorization. Users are granted permissions based on defined roles—not on their individual system user ID. Create user roles based on job functions to help users perform their associated job functions. You can assign each user only a single role, and many users can have the same role. A user role authenticates and authorizes a user at login, and places the user in EXEC mode. For more information, see CLI basics.

OS10 supports four predefined roles: `sysadmin`, `secadmin`, `netadmin`, and `netoperator`. Each user role assigns permissions that determine the commands that a user can enter, and the actions a user can perform. RBAC provides an efficient way to administer user rights. If a user role matches one of the allowed user roles for a command, command authorization is granted.

The OS10 RBAC model provides separation of duty and greater security. It places limitations on each role permission to allow you to partition tasks. For greater security, only some user roles can view events, audits, and security system logs.

### Assign user role

To limit OS10 system access, assign a role when you configure each user.

- Enter a username, password, and role in CONFIGURATION mode.

  `username username password password role role`

  - `username username` — Enter a text string. A maximum of 32 alphanumeric characters; one character minimum.
  - `password password` — Enter a text string. A maximum of 32 alphanumeric characters; nine characters minimum.
  - `role role` — Enter a user role:
    - `sysadmin` — Full access to all commands in the system, exclusive access to commands that manipulate the file system, and access to the system shell. A system administrator can create user IDs and user roles.
    - `secadmin` — Full access to configuration commands that set security policy and system access, such as password strength, AAA authorization, and cryptographic keys. A security administrator can display security information, such as cryptographic keys, login statistics, and log information.
    - `netadmin` — Full access to configuration commands that manage traffic flowing through the switch, such as routes, interfaces, and ACLs. A network administrator cannot access configuration commands for security features or view security information.
    - `netoperator` — Access to EXEC mode to view the current configuration with limited access. A network operator cannot modify any configuration setting on a switch.

### Create user and assign role

```
OS10(config)# username smith password silver403! role sysadmin
```

### View users

```
OS10# show users
Index Line   User        Role       Application Login-Time                    Location          Privilege-
                                    Idle                                                        Level
---- -----  ----------- ----------- ----------- ------ ---------------------  ---------------- ----------
1    ttyS0  admin       sysadmin    clish       00:14 2024-09-13 T 17:03:55Z  console           15
2    pts/0  admin       sysadmin    -i          3.6s  2024-09-13 T 17:05:57Z  console           15
3    pts/1  pepper      netadmin    bash        00:08 2024-09-13 T 17:06:51Z  10.10.10.10 [ssh] 15
4    pts/2  netopusr    netoperator bash        00:08 2024-09-13 T 17:10:42Z  10.10.10.10 [ssh] 1
5    pts/3  secadminusr secadmin    bash        1.2s  2024-09-13 T 17:17:59Z  10.10.10.10 [ssh] 15
```

### Linuxadmin user configuration

OS10 supports two factory-default users: admin and linuxadmin. Use the admin user name to log in to the command-line interface. Use the linuxadmin user name to access the Linux shell.

To manage the default linuxadmin user from the CLI, you can:

- Configure a lost or forgotten linuxadmin password.
- Disable the linuxadmin user.

> **NOTE:** These tasks allow you to manage only the default linuxadmin user, not other Linux users created at the root level.

### Configure linuxadmin password from CLI

To configure a password for the linuxadmin user, use the `system-user linuxadmin password {clear-text-password | hashed-password}` command in CONFIGURATION mode. Save the new password using the `write memory` command. For example:

```
OS10(config)# system-user linuxadmin password Dell@admin10!@
OS10(config)# exit
OS10# write memory
OS10(config)# system-user linuxadmin
password $6$3M55wOYy$Sw1V9Ok3GE4Hmf6h1ARH.dBHy9gpEFYUvdu15ZpnCYzt.nJjFm0VIz/rQvvJeX6krRtfYs2ZqBl6TkmLGAwtM
OS10(config)# exit
OS10# write memory
```

The linuxadmin password configured from the CLI takes precedence across reboots over the password configured from the Linux shell.

Verify the linuxadmin password using the `show running-configuration` command.

```
OS10# show running-configuration
system-user linuxadmin password
$6$5DdOHYg5$JCE1vMSmkQOrbh31U74PIPv7lyOgRmba1IxhkYibppMXs1KM4Y.gbTPcxyMP/PHUkMc5rdk/ZLv9Sfv3ALtB61
```

### Disable linuxadmin user

To disable or lock the linuxadmin user, use the `system-user linuxadmin disable` command in CONFIGURATION mode.

```
OS10(config)# system-user linuxadmin disable
```

To re-enable or unlock the linuxadmin user, use the `no system-user linuxadmin disable` command in CONFIGURATION mode.

```
OS10(config)# no system-user linuxadmin disable
```

### Privilege levels

Controlling terminal access to a switch is one method of securing the device and network. To increase security, you can limit user access to a subset of commands using privilege levels.

Configure privilege levels, add commands to them, and restrict access to the command line with passwords. The system supports 16 privilege levels:

- **Level 0** — Provides users the least privilege, restricting access to basic commands.
- **Level 1** — Provides access to a set of show commands and certain operations such as ping, traceroute, and so on.
- **Level 15** — Provides access to all available commands for a particular user role.
- **Levels 0, 1, and 15** — System configured privilege levels with a predefined command set.
- **Levels 2 to 14** — Not configured. You can customize these levels for different users and access rights.

Privilege levels inherit the commands that are supported on all lower levels. After logging in with a user role, a user has access to commands assigned to his privilege level and lower levels.

For users assigned to the `sysadmin`, `netadmin`, and `secadmin` roles, you cannot configure a privilege level lower than two. You can configure `netoperator` users with privilege levels 0 or 1.

After you assign commands to privilege levels, assign the privilege level to users with the `username` command. Use the `enable password privilege-level` command to switch between privilege levels and access the commands that are supported at each level. The `disable` command takes the user to a lower level.

When a remote user logs in, OS10 checks for a match in the local system. If a local user entry is found, the privilege level of the local user is applied to the remote user for the login session. If no match is found in the local system, OS10 assigns a default privilege level according to the role of the remote user:

- `sysadmin`, `secadmin`, and `netadmin` roles: Level 15
- `netoperator` role: Level 1

> **NOTE:** The role of a local user in the system and the remote user who logs in must be the same at both ends.

Starting for Release 10.5.4.4, the OS10 RADIUS client can process the privilege level attribute. The privilege level attribute is treated as a Dell vendor-specific TLV attribute. If the RADIUS server sends the privilege level attribute for a user, the OS10 RADIUS client extracts the privilege level value from the RADIUS packet and configures the privilege level for the user accordingly. Use the `show users` and `show privilege` commands to view the privilege levels configured for different users. In the previous releases, OS10 can only process the role attribute from RADIUS servers.

You must configure the privilege level on the RADIUS server using the vendor-specific attribute (VSA). The vendor ID of Dell Technologies is 674. Create a VSA with Name = `DellEMC-AVpair`, OID = 1, Type = string. For example, to set the privilege level of a user to 6, enter VSA as follows: `DellEMC-AVpair := "shell:privLvl=6"`.

The following is a sample output of the privilege level attribute that is captured from a RADIUS server packet with the privilege level value set to 6 for a user.

```
Vendor-Specific Attribute (26), length: 9, Value:Vendor: Unknown (674)
Vendor Attribute: 1, Length: 1, Value: 6
```

The following is the `show users` output that is taken on the OS10 device after the privilege level attribute has been set to a value of 6 from the RADIUS server for a username user1.

```
OS10# show users
Index Line   User        Role       Application Login-Time                    Location          Privilege-
                                    Idle                                                        Level
---- -----  ----------- ----------- ----------- ------ ---------------------  ---------------- ----------
1    ttyS0  admin       sysadmin    clish       00:14 2024-09-13 T 17:03:55Z  console           15
2    pts/0  admin       sysadmin    -i          3.6s  2024-09-13 T 17:05:57Z  console           15
3    pts/1  pepper      netadmin    bash        00:08 2024-09-13 T 17:06:51Z  10.10.10.10 [ssh] 15
4    pts/2  netopusr    netoperator bash        00:08 2024-09-13 T 17:10:42Z  10.10.10.10 [ssh] 1
5    pts/3  secadminusr secadmin    bash        1.2s  2024-09-13 T 17:17:59Z  10.10.10.10 [ssh] 15
```

### Configure privilege levels

To restrict CLI access, create the required privilege levels for user roles, assign commands to each level, and assign privilege levels to users.

1. Create privilege levels in CONFIGURATION mode.

   `privilege mode priv-lvl privilege-level command-string`

   - `mode` — Enter the privilege mode used to access CLI modes:
     - `exec` — Accesses EXEC mode.
     - `configure` — Accesses class-map, DHCP, logging, monitor, openflow, policy-map, QoS, telemetry, CoS, Tmap, UFD, VLT, VN, VRF, WRED, and alias modes.
     - `interface` — Accesses Ethernet, fibre-channel, loopback, management, null, port-group, lag, breakout, range, and VLAN modes.
     - `route-map` — Accesses route-map mode.
     - `router` — Accesses router-bgp and router-ospf modes.
     - `line` — Accesses line-vty mode.
   - `priv-lvl privilege-level` — Enter the number of a privilege level, from 2 to 14.
   - `command-string` — Enter the commands supported at the privilege level.

2. Create a username, password, and role, and assign a privilege level in CONFIGURATION mode.

   `username username password password role role priv-lvl privilege-level`

   - `username username` — Enter a text string; 32 alphanumeric characters maximum; one character minimum.
   - `password password` — Enter a text string; 32 alphanumeric characters maximum, nine characters minimum.
   - `role role` — Enter a user role:
     - `sysadmin` — Full access to all commands in the system, exclusive access to commands that manipulate the file system, and access to the system shell. A system administrator can create user IDs and user roles.
     - `secadmin` — Full access to configuration commands that set security policy and system access, such as password strength, AAA authorization, and cryptographic keys. A security administrator can display security information, such as cryptographic keys, login statistics, and log information.
     - `netadmin` — Full access to configuration commands that manage traffic flowing through the switch, such as routes, interfaces, and ACLs. A network administrator cannot access configuration commands for security features or view security information.
     - `netoperator` — Access to EXEC mode to view the current configuration with limited access. A network operator cannot modify any configuration setting on a switch.
   - `priv-lvl privilege-level` — Enter a privilege level, from 0 to 15. If you do not specify the `priv-lvl` option, the system assigns privilege level 1 for the `netoperator` user and privilege level 15 for the `sysadmin`, `secadmin`, and `netadmin` users.

The following is an example of configuring privilege levels and assigning them to a user:

```
OS10(config)# privilege exec priv-lvl 12 "show version"
OS10(config)# privilege exec priv-lvl 12 "configure terminal"
OS10(config)# privilege configure priv-lvl 12 "interface ethernet"
OS10(config)# privilege interface priv-lvl 12 "ip address"
OS10(config)# username delluser password $6$Yij02Phe2n6whp7b$ladskj0HowijIlkajg981 role secadmin priv-lvl 12
```

The following example shows the privilege level of the current user:

```
OS10# show privilege
Current privilege level is 15.
```

The following example displays the privilege levels of all users who are logged into OS10:

```
OS10# show users
Index Line   User  Role     Application Idle Login-Time            Location         Privilege
----- ------ ----- -----   ----------- ---- -----------            --------         ---------
1     pts/0  admin sysadmin bash        >24h 2018-09-08 T06:51:37Z 10.14.1.91 [ssh] 15
2     pts/1  netad netadmin bash        >24h 2018-09-08 T06:54:33Z 10.14.1.91 [ssh] 10
```

### Configure enable password for a privilege level

After you configure privilege levels for users, assign commands to each level, and enable password to access each level:

1. Configure a privilege level and assign commands to it in CONFIGURATION mode.

   `privilege mode priv-lvl privilege-level command-string`

   - `mode` — Enter the privilege mode used to access CLI modes:
     - `exec` — Accesses EXEC mode.
     - `configure` — Accesses class-map, DHCP, logging, monitor, openflow, policy-map, QoS, telemetry, CoS, Tmap, UFD, VLT, VN, VRF, WRED, and alias modes.
     - `interface` — Accesses Ethernet, fibre-channel, loopback, management, null, port-group, lag, breakout, range, and VLAN modes.
     - `route-map` — Accesses route-map mode.
     - `router` — Accesses router-bgp and router-ospf modes.
     - `line` — Accesses line-vty mode.
   - `priv-lvl privilege-level` — Enter the number of a privilege level, from 2 to 14.
   - `command-string` — Enter the command supported at the privilege level.

   For sysadmin, netadmin, and secadmin roles, you cannot configure a privilege level less than 2.

2. Configure an enable password for each privilege level in CONFIGURATION mode.

   `enable password encryption-type password-string priv-lvl privilege-level`

   - `encryption-type` — Enter an encryption type for the password entry:
     - `0` — Use plain text with no password encryption.
     - `sha-256` — Encrypt the password using the SHA-256 algorithm.
     - `sha-512` — Encrypt the password using the SHA-512 algorithm.
   - `priv-lvl privilege-level` — Enter a privilege level, from 1 to 15.

```
OS10(config)# privilege exec priv-lvl 3 "show version"
OS10(config)# enable password 0 P@$$w0Rd priv-lvl 3
OS10(config)# privilege exec priv-lvl 12 "configure terminal"
OS10(config)# privilege configure priv-lvl 12 route-map
OS10(config)# privilege route-map priv-lvl 12 "set local-preference"
OS10(config)# enable password sha-256 $5$2uThib1o$84p.tykjmz/w7j26ymoKBjrb7uepkUB priv-lvl 12
```

### Passwords for user accounts

OS10 allows you to configure password check and strength for the user accounts.

#### Configuration notes

All Dell PowerSwitches except S4200-Series, S5200 Series, and Z9332F-ON:

When you enter a password in an OS10 command, either at a password prompt or in the command syntax, you can enter only alphanumeric and certain special characters - `$ - _ . + ! * ' ()` - unencoded. You cannot enter any other special characters in the password. Use URL encoding instead.

For example, in the image download command, the password `a@b` is not accepted: `image download ftp://username:a@b@10.11.63.122/filename`. You must enter the password as `image download ftp://username:a%40b@10.11.63.122/filename`. The URL encoding for `@` is `%40`. For information about other characters that require URL encoding, go to URL Encoding.

### Enable user lockout

By default, a maximum of three consecutive failed password attempts is supported on the switch. You can set a limit to the maximum number of allowed password retries with a specified lockout period for the user ID. Audit logs include authentication failures on the console as well.

This feature is available only for the `sysadmin` and `secadmin` roles.

> **NOTE:** If you are downgrading OS10 to a release earlier than 10.5.2.1, check the `password-attributes` command and ensure that only the supported parameters are configured.

- Configure user lockout settings in CONFIGURATION mode.

  `password-attributes {[max-retry number ] [lockout-period minutes] [console-exempt]}`

  - `max-retry number` — Sets the maximum number of consecutive failed login attempts for a user before the user is locked out, from 0 to 16; default 3.
  - `lockout-period minutes` — Sets the amount of time that a user ID is prevented from accessing the system after exceeding the maximum number of failed login attempts, from 0 to 43,200; default 5.

    > **NOTE:** Dell Technologies recommends that you configure the lockout period to be a nonzero value. If you set this value to zero, no lockout period is configured. Any number of failed login attempts do not lock out a user.

  - `console-exempt` — Applicable only if the user lockout feature is enabled. Enables the user to log in through the console, even though the user ID is blocked because of an existing lockout.

When a user is locked out due to exceeding the maximum number of failed login attempts, other users can still access the switch.

### Configure user lockout

```
OS10(config)# password-attributes max-retry 4 lockout period 360 console-exempt
```

### Simple password check

By default, OS10 uses a strong password check when you configure username passwords with the `username username password password role role [priv-lvl privilege-level]` command.

To turn off the strong password check and configure simpler passwords with no restrictions, use the `service simple-password` command.

To disable the simple password check and return to the default strong password check, use the `no service simple-password` command.

- Enter the command in CONFIGURATION mode.

  `service simple-password`

### Enable simple password check

```
OS10(config)# username abhishek password madmiamadam role sysadmin
     %Error: Password fail:  it does not contain enough DIFFERENT characters
OS10(config)# service simple-password
OS10(config)# username abhishek password madmiamadam role sysadmin
OS10(config)#
```

### Password strength

By default, the password you configure with the `username password role` and `enable password priv-lvl` commands must be at least nine alphanumeric characters. To increase password strength, you can create stronger password rules using the `password-attributes` command. These password rules apply to the username and privilege-level password configuration.

When you enter the command, at least one parameter is required. When you enter the `character-restriction` parameter, at least one option is required.

- Create rules for stronger passwords in CONFIGURATION mode.

  `password-attributes {[min-length number] [character-restriction {[upper number] [lower number][numeric number] [special-char number]}}`

  - `min-length number` — Enter the minimum number of required alphanumeric characters, from 6 to 32; default 9.
  - `character-restriction` — Enter a requirement for the alphanumeric characters in a password:
    - `upper number` — Minimum number of uppercase characters required, from 0 to 31; default 0.
    - `lower number` — Minimum number of lowercase characters required, from 0 to 31; default 0.
    - `numeric number` — Minimum number of numeric characters required, from 0 to 31; default 0.
    - `special-char number` — Minimum number of special characters required, from 0 to 31; default 0.

To turn off the strong password check enabled with the `password-attributes` command, use the `service simple-password` command. No password rules, except for the minimum 9-character requirement, are applied to the username and privilege-level passwords. To revert to the configured `password-attributes` settings, use the `no service simple-password` command.

### Create strong password rules

```
OS10(config)# password-attributes min-length 7 character-restriction upper 4 numeric 2
```

### Display password rules

```
OS10(config)# show running-configuration password-attributes
!
password-attributes character-restriction upper 4
password-attributes character-restriction numeric 2
password-attributes min-length 7
```

### Disable strong password check

```
OS10(config)# password-attributes min-length 7 character-restriction upper 4 numeric 2
OS10(config)# username admin2 password 4newhire4 role sysadmin
  %Error: Password fail:  it does not contain enough DIFFERENT characters
OS10(config)# enable password 0 4newhire4 priv-lvl 5
  %Error: Password it does not contain enough DIFFERENT characters.
OS10(config)# service simple-password
OS10(config)# username admin2 password 4newhire4 role sysadmin
OS10(config)# enable password 0 4newhire4 priv-lvl 5
```

### Re-enable strong password check

```
OS10(config)# no service simple-password
```

### Minimum password age

The minimum password age setting in OS10 defines the number of days a user must wait before changing their password again. This feature helps prevent users from cycling through passwords rapidly to reuse old ones, thereby enhancing password security.

The `password-attributes min-password-age` command is used to configure the minimum number of days a user must wait before changing their password again. This value can be set between 1 and 30 days. Once configured, the minimum password age policy is immediately applied to both existing and newly created local user accounts. OS10 enforces this policy based on the date of the last password change, not the exact time. For example, if the minimum age is set to 1 day, a user who changes their password today is allowed to change it again any time starting from the next calendar day.

The `no password-attributes min-password-age` command disables this restriction, allowing users to change their passwords at any time, regardless of when the last change occurred.

> **NOTE:** This command is not applicable to the linuxadmin user. The min-password-age attribute does not affect accounts managed outside the OS10 local user database.

### Obscure passwords

To obscure passwords in show command output so that text characters do not display, use the `service obscure-password` command. The command obscures the passwords configured for username, NTP, BGP, SNMP, RADIUS servers, LDAP servers, and TACACS+ servers. To disable the obscure passwords function, use the `no service obscure-password` command.

- Enter the command in CONFIGURATION mode.

  `service obscure-password`

### Obscure OS10 passwords

```
OS10(config)# service obscure-password
OS10(config)# show running-configuration users
username admin password **** role sysadmin priv-lvl 15
username test1 password **** role sysadmin priv-lvl 15
OS10(config)# show running-configuration radius-server
radius-server host 10.2.2.2 key 9 ****
OS10(config)# show running-configuration tacacs-server
tacacs-server host 10.1.1.1 auth-port 7777 key 9 ****
```

### Disable obscure passwords

```
OS10(config)# no service obscure-password
OS10(config)# show running-configuration users
username admin password $6$q9QBeYjZ$jfxzVqGhkxX3smxJSH9DDz7/3OJc6m5wjF8nnLD7/VKx8SloIhp4NoGZs0I/UNwh8WVuxwfd9q4pWIgNs5BKH role sysadmin priv-lvl 15
username test1 password $6$rounds=656000$50vutEWA9w3ImvF.$2pSDnaINYTKCQ6WAlJqeabiFQNRvUgui3.6vR2e.L/D7DBwnV0QtY.KtOBTZAIDDT5.AFWxQHVgs2/V3jC3yG1 role sysadmin priv-lvl 15
OS10(config)# show running-configuration radius-server
radius-server host 10.2.2.2 key 9
3c0e479bd43bb5baf4ebb16e1317a845f01f832e25a03836c70bd26b9754d6a0
OS10(config)# show running-configuration tacacs-server
tacacs-server host 10.1.1.1 auth-port 7777 key 9
27ca79bf3cbf351708c8d19caf50815661dcd0638719a06c865e88090d03558b
```

#### Configuration notes

All Dell PowerSwitches:

- Obscure password (`service obscure-password`) is enabled by default when upgrading to 10.5.2.0 or later if the setting is not changed before the upgrade.
- If the Obscure password configuration is explicitly disabled before the upgrade, it remains disabled after the upgrade as well.

### Change your own password

When you log in for the first time using the temporary password, OS10 prompts you to change the password. You can change the password of the logged-in user account using the `password-change` command.

#### Restrictions and limitations

- The password must not contain the initial four characters of the username.
- You cannot use the last four passwords of the user account.
- The `password-change` command is not available in a Telnet session.

Change the password in EXEC mode.

1. Change the password in EXEC mode using the `password-change` command.

   ```
   OS10# password-change
   password_change is executed for user admin
   The current session will be terminated and a password change prompt will appear at the next login. You must change the password to access the OS10 Prompt.
   Do you still want to change password ? [yes/no]: yes
   OS10# Session killed for Re-authentication. Please log-in again
   ```

2. The password change prompt appears at the next login.

   ```
   OS10 login: delluser
   Password:
   WARNING: Your password has expired.
   You must change your password now and login again!
   Changing password for delluser.
   Current password:
   New password:
   Retype new password:
   passwd: password updated successfully
   ```

### Password expiration

Starting from Release 10.5.5.5, the default user password expiration time is 0, indicating that the password never expires and password change is not enforced upon first login. From Release 10.5.5.0 up to 10.5.5.4, the default password expiration time is 180 days. You can set the password expiration time globally or for an individual user account by using the below commands.

- `password-attributes password-expiry <expiry-time>`
- `username <username> password <password> role <role> priv-lvl <priv-lvl> password-expiry <expiry-time>`

A warning message is displayed in the session 10 days before the password expiration date. When the password expires after the specified number of days, a password change prompt appears in the session.

**Syslog and SNMP trap notifications for user password expiry** — Starting from Release 10.5.6.0, SmartFabric OS10 supports syslog and SNMP trap notifications for user password expiry. These notifications are triggered when a user password is about to expire in a configured number of days. The syslog notification feature is disabled by default and must be enabled using `password-attributes expiry-notification-enable` command. Similarly, SNMP traps for password expiry are also disabled by default and can be enabled using the `snmp-server enable traps expiry` command.

#### Restrictions and limitations

- You cannot set the password expiration time for the linuxadmin account.
- When you upgrade from a previous release to release 10.5.5 or later, the password-expiry configuration is not applied to the existing user accounts. If required, you must reconfigure the user accounts using the `username` command.
- By default, the password expiration configuration is not applied to the admin user account. If required, you can configure the expiration time using the `username` command.
- The password expiry feature applies exclusively to locally created users. If a user is created in both the RADIUS, LDAP, or TACACS servers and locally (OS10), the password expiry feature does not apply to such user.

### Set the global password expiration time

To set the password expiration time for all the users, use `password-attributes password-expiry <expiry-time>` command. This feature is available only for the sysadmin and secadmin roles.

1. Enter the CONFIGURATION mode.

   ```
   OS10# configure terminal
   OS10(config)#
   ```

2. Set the password expiration time in days, from 60 to 240 days.

   ```
   OS10(config)# password-attributes password-expiry 190
   ```

To reset parameters to their default values, use the `no password-attributes` command.

### Set the password expiration time for the user account

To set the password expiration time for an individual user, use `username <username> password <password> role <role> priv-lvl <priv-lvl> password-expiry <expiry-time>` command. This feature is available only for the sysadmin roles. If you do not configure the password expiration time for a user account, the global password expiration time is used by default.

### Set the password expiration time

1. Enter the CONFIGURATION mode.

   ```
   OS10# configure terminal
   OS10(config)#
   ```

2. Set the password expiration time in days, from 60 to 240 days.

   ```
   OS10(config)# username delluser password ******** role sysadmin priv-lvl 15 password-expiry 230
   ```

### Set the password to no expiration

1. Enter the CONFIGURATION mode.

   ```
   OS10# configure terminal
   OS10(config)#
   ```

2. Set the password expiration time to "0."

   ```
   OS10(config)# username delluser password ****** role sysadmin priv-lvl 15 password-expiry 0
   ```

### Password reset

When the `password-reset` command is run, the password for the specified user is reset. Upon their next login attempt, the user is prompted to change their password.

Only sysadmin and secadmin users can run this command. However, a secadmin user cannot reset the password for a sysadmin user, as the secadmin role has lower privileges.

> **NOTE:** This command supports password resets only for locally created users. It cannot reset passwords for system users (for example, linuxadmin) or AAA users.

### Resetting a user password

To reset a user password:

1. Enter the `password-reset` command in EXEC mode to reset the password for the specified user:

   ```
   OS10# password-reset delluser
   Resetting password for the user delluser
   Do you want to proceed ? [yes/no(default)]:yes
   Password is reset for delluser
   ```

2. The password for delluser is reset. The password change prompt appears at the next login.

   ```
   OS10 login: delluser
   Password:
   You are required to change your password immediately (administrator enforced).
   You are required to change your password immediately (administrator enforced).
   Linux OS10 6.1.135 #1d SMP PREEMPT_DYNAMIC Debian 6.1.135-1  x86_64
   The programs included with the Debian GNU/Linux system are free software;
   the exact distribution terms for each program are described in the
   individual files in /usr/share/doc/*/copyright.
   Debian GNU/Linux comes with ABSOLUTELY NO WARRANTY, to the extent
   permitted by applicable law.
   -*-*-*-*-*-*-*-*-*-*-*-*-*-*-*-*-*-*-*-*-*-*-*-*-*-*-*-*-*-*-*-*-
   -*         Dell SmartFabric OS10 Enterprise                    *-
   -*                                                             *-
   -* Copyright (c) 1999-2025 by Dell Inc. All Rights Reserved.   *-
   -*                                                             *-
   -*-*-*-*-*-*-*-*-*-*-*-*-*-*-*-*-*-*-*-*-*-*-*-*-*-*-*-*-*-*-*-*-
   This product is protected by U.S. and international copyright and
   intellectual property laws. Dell and the Dell logo are
   trademarks of Dell Inc. in the United States and/or other
   jurisdictions. All other marks and names mentioned herein may be
   trademarks of their respective companies.
   WARNING: Your password has expired.
   You must change your password now and log in again!
   Changing password for delluser.
   Current password:
   New password:
   Retype new password:
   passwd: password updated successfully
   ```

## User management commands

#### disable

Lowers the privilege level.

**Syntax**

`disable privilege-level`

**Parameters**

`privilege-level` — Enter the privilege level, from 0 to 15.

**Defaults**

1

**Command Mode**

Privileged EXEC

**Usage Information**

If you do not specify a privilege level, the system assigns level 1.

**Example**

```
OS10# disable
OS10# disable 6
```

**Supported Releases**

10.4.3.0 or later

#### enable

Enables a specific privilege level.

**Syntax**

`enable privilege-level`

**Parameters**

`privilege-level` — Enter the configured privilege level, from 0 to 15.

**Defaults**

15

**Command Mode**

Exec

**Usage Information**

Dell Technologies recommends configuring a password for privilege level 15 using the `enable password` command. If you do not configure a password for a level, you can switch to that level without entering a password, unless a password is configured for a highest intermediate level. If you configure a password for an intermediate level, enter that password when prompted. To access privilege level 15, you must configure the `enable password` command. If you do not configure a password for privilege level 15, you cannot enter level 15. For privilege levels 0 to 14, the `enable password` command is optional. Privilege levels inherit all permitted commands from all lower levels. For example, if you log in to privilege level 10 using the `enable 10` command, all commands that are assigned to privilege level 10 and lower are available for use.

**Example**

```
OS10# enable
OS10# enable 10
```

**Supported Releases**

10.4.3.0 or later

#### enable password priv-lvl

Sets a password for a privilege level.

**Syntax**

`enable password encryption-type password-string priv-lvl privilege-level`

**Parameters**

- `encryption-type` — Enter the type of password encryption:
  - `0` — Use an unencrypted password.
  - `sha-256` — Use an SHA-256 encrypted password.
  - `sha-512` — Use an SHA-512 encrypted password.
- `priv-lvl privilege-level` — Enter a privilege number from 1 to 15.

**Defaults**

Not configured

**Command Mode**

CONFIGURATION

**Usage Information**

To increase the required password strength, create stronger password rules using the `password-attributes` command. The no version of this command removes a privilege-level password. To create a hash value for a plain text password, you can use the passlib library in Python. For example:

```
from passlib.hash import sha256_crypt
>>> sha256_crypt.hash("Delluser@123")
'$5$rounds=535000$4a83B3VeM6lrKmWQ$lPJfqHBnCY4rtuCM1PsyUqOeY7kIFxJpbmsde4PV4g4'
```

You can follow the same process for SHA-512 hash as well. Use the generated hash value in the command as shown below:

```
OS10(config)# enable password sha-256 ***************************************************************************** priv-lvl 12
```

> **NOTE:** When you create or modify a password, the password string that you input appears as a string of asterisks instead of plain text.

**Example**

```
OS10(conf)# enable password 0 P@$$w0Rd priv-lvl 12
OS10(conf)# enable password sha-256 $5$2uThib1o$84p.tykjmz/w7j26ymoKBjrb7uepkUB priv-lvl 12
OS10(conf)# enable password sha-512 $6$Yij02Phe2n6whp7b$ladskj0HowijIlkajg981 priv-lvl 12
OS10# enable 12
password:
OS10# show privilege
Current privilege level is 12.
```

**Supported Releases**

10.4.3.0 or later

#### password-attributes

Configures rules for password entries.

**Syntax**

`password-attributes {[min-length number] [character-restriction {[upper number] [lower number] [numeric number] [special-char number]} [min-password-age number] [password-expiry expiry-time] expiry-notification-enable time-in-days}`

**Parameters**

- `min-length number` — (Optional) Sets the minimum number of required alphanumeric characters, from 6 to 32; default 9.
- `character-restriction`:
  - `upper number` — (Optional) Sets the minimum number of uppercase characters that are required, from 0 to 31; default 0.
  - `lower number` — (Optional) Sets the minimum number of lowercase characters that are required, from 0 to 31; default 0.
  - `numeric number` — (Optional) Sets the minimum number of numeric characters that are required, from 0 to 31; default 0.
  - `special-char number` — (Optional) Sets the minimum number of special characters that are required, from 0 to 31; default 0.
- `min-password-age number` — (Optional) Sets the minimum number of days between password changes, from 1 to 30 days. The no version of the min-password-age command removes this restriction, allowing users to change their passwords at any time.
- `password-expiry expiry-time` — (Optional) Sets the password expiration time in days, from 60 to 240 days; default 0.
- `expiry-notification-enable` — (Optional) Sets the expiry notification time in days, from 2 to 60; default 10. When enabled, SmartFabric OS10 generates a syslog message when a user password is about to expire before the configured password expiration time. It also generates a syslog message on the day of a user password expiry.

**Default**

- Minimum length: 9 characters
- Uppercase characters: 0
- Lowercase characters: 0
- Numeric characters: 0
- Special characters: 0
- Minimum password age: 0 (Users can change their password immediately after a previous change.)
- Password expiration time: 0 (180 days only in Release 10.5.5.0 to 10.5.5.4; 0 from Release 10.5.5.5 onwards)
- Expiry notification: 10 days

**Security and Access**

sysadmin and secadmin

**Command Mode**

CONFIGURATION

**Usage Information**

By default, the password you configure with the `username password` command must be at least nine alphanumeric characters. Use this command to increase password strength. When you enter the command, at least one parameter is required. When you enter the `character-restriction` parameter, at least one option is required. To reset parameters to their default values, use the `no password-attributes` command. Use the `password-expiry` parameter to set the password expiration time globally for all the user accounts. Use the `expiry-notification-enable` parameter to enable sending a syslog message for password expiry notifications.

**Example**

```
OS10(config)# password-attributes min-length 6 character-restriction upper 2 lower 2 numeric 2 password-expiry 190
```

**Example (expiry notification)**

```
OS10(config)# password-attributes expiry-notification-enable 35
OS10(config)# no password-attributes expiry-notification-enable
```

**Example (minimum password age)**

```
OS10(config)# password-attributes min-password-age 9
OS10(config)# no password-attributes min-password-age
```

**Supported Releases**

- 10.4.0E(R1) or later
- 10.6.1.0 or later — Added the `min-password-age number` parameter.

#### password-attributes max-retry lockout-period console-exempt

Configures a maximum number of consecutive failed login attempts, the lockout period, and console login exemption for the user ID.

**Syntax**

`password-attributes {[max-retry number] [lockout-period minutes] [console-exempt]}`

**Parameters**

- `max-retry number` — (Optional) Sets the maximum number of consecutive failed login attempts for a user before the user is locked out, from 0 to 16.
- `lockout-period minutes` — (Optional) Sets the amount of time that a user ID is prevented from accessing the system after exceeding the maximum number of failed login attempts, from 0 to 43,200.
- `console-exempt` — Applicable only if the user lockout feature is enabled. Enables the user to log in through the console, even though the user ID is blocked because of the existing lockout.

**Default**

- Maximum number of retries: 3
- Lockout period: 5 minutes

**Command Mode**

CONFIGURATION

**Usage Information**

To remove the configured `max-retry` or `lockout-period` or `console-exempt` settings, use the `no password-attributes {max-retry | lockout-period | console-exempt}` command. When a user is locked out due to exceeding the maximum number of failed login attempts, other users can still access the switch. If the `console-exempt` option is enabled, the locked out user can log in through the console, even though the user ID is locked out because of failed password attempts.

> **NOTE:** Dell Technologies recommends that you configure the lockout period to be a nonzero value. If you set this value to zero, no lockout period is configured. Any number of failed login attempts do not lock out a user.

**Example**

```
OS10(config)# password-attributes max-retry 5 lockout-period 30 console-exempt
```

**Supported Releases**

10.4.1.0 or later

#### password-change

Changes the password of the user account.

**Syntax**

`password-change`

**Parameters**

None

**Default**

None

**Security and Access**

sysadmin, secadmin, netadmin, and netoperator

**Command Mode**

EXEC

**Usage Information**

Use this command to change the password of the logged-in user. Starting from Release 10.6.1.0, this command is accessible to the netoperator role.

> **NOTE:** You cannot change the password in a Telnet session.

**Example**

```
OS10# password-change
password_change is executed for user admin
The current session will be terminated and a password change prompt will appear at the next login. You must change the password to access the OS10 Prompt.
Do you still want to change password ? [yes/no]: yes
OS10# Session killed for Re-authentication. Please log-in again
```

The password change prompt appears at the next login.

```
OS10 login: delluser
Password:
WARNING: Your password has expired.
You must change your password now and login again!
Changing password for delluser.
Current password:
New password:
Retype new password:
passwd: password updated successfully
```

**Supported Releases**

- 10.5.5.0P1 or later
- 10.6.1.0 or later — Accessible to the netoperator role.

#### password-reset

Configures password reset for the user.

**Syntax**

`password-reset username`

**Parameters**

- `username` — Enter the username to enable password reset.

**Default**

None

**Security and Access**

sysadmin and secadmin

**Command Mode**

EXEC

**Usage Information**

Use this command to set the user password to expire and prompt the user to change it at the next login.

> **NOTE:** A user with the secadmin role cannot configure password reset for the sysadmin user.

**Example**

```
OS10# password-reset delluser
Resetting password for the user delluser
Do you want to proceed ? [yes/no(default)]:yes
Password is reset for delluser
```

**Supported Releases**

10.6.1.0 or later

#### privilege

Creates a privilege level and associates commands with it.

**Syntax**

`privilege mode priv-lvl privilege-level command-string`

**Parameters**

- `mode` — Enter the privilege mode used to access CLI modes:
  - `exec` — Accesses EXEC mode.
  - `configure` — Accesses class-map, DHCP, logging, monitor, OpenFlow, policy-map, QoS, telemetry, CoS, Tmap, UFD, VLT, VN, VRF, WRED, and alias modes.
  - `interface` — Accesses Ethernet, fibre-channel, loopback, management, null, port-group, lag, breakout, range, and VLAN modes.
  - `route-map` — Accesses route-map mode.
  - `router` — Accesses router-bgp and router-ospf modes.
  - `line` — Accesses line-vty mode.
- `priv-lvl privilege-level` — Enter the number of a privilege level, from 2 to 14.
- `command-string` — Enter the commands supported at the privilege level.

**Defaults**

Not configured

**Command Mode**

CONFIGURATION

**Usage Information**

For users assigned to sysadmin, netadmin, and secadmin roles, you cannot configure a privilege level less than 2. If a command that you associate with a privilege level has a space, enter the command in double quotes ("). If a command does not have a space or if it has keywords that are separated by a hyphen, double quotes are not required. The no version of this command removes a command from a privilege level.

**Example**

```
OS10(config)# privilege exec priv-lvl 3 "configure terminal"
OS10(config)# privilege configure priv-lvl 3 "interface ethernet"
OS10(config)# privilege interface priv-lvl  "ip address"
OS10(config)# privilege configure priv-lvl 3 route-map
OS10(config)# privilege route-map priv-lvl 3 "set local-preference"
```

**Supported Releases**

10.4.3.0 or later

#### service simple-password

Disables the strong password check configured with `username password role` and `password-attributes` commands.

**Syntax**

`service simple-password`

**Parameters**

None

**Default**

Not configured

**Command Mode**

CONFIGURATION

**Usage Information**

Use the `service simple-password` command to turn off the strong password checks so that you can configure passwords with no restrictions. To revert to the configured stronger password settings, use the `no service simple-password` command.

**Example**

```
OS10(config)# service simple-password
```

**Supported Releases**

10.5.0 or later

#### service obscure-password

Obscures passwords in show command output.

**Syntax**

`service obscure-password`

**Parameters**

None

**Default**

Enabled

**Command Mode**

CONFIGURATION

**Usage Information**

Use `service obscure-password` command so that the text characters of passwords are not displayed in show command output. The command obscures the passwords that you configure for username, NTP, BGP, SNMP, RADIUS servers, LDAP servers, and TACACS+ servers. To disable the obscure passwords function, use the `no service obscure-password` command.

**Example**

```
OS10(config)# service obscure-password
```

**Supported Releases**

10.5.0 or later

#### show users

Displays information for all users who are logged into OS10.

**Syntax**

`show users`

**Parameters**

None

**Default**

Not configured

**Command Mode**

EXEC

**Usage Information**

Starting from Release 10.4.3.0, this command displays the privilege levels of all users on OS10.

**Example**

```
OS10# show users
Index Line   User        Role       Application Login-Time                    Location          Privilege-Level
--- -----  ----------- ----------- ----------- ------ ---------------------  ---------------- ----------
1    ttyS0  admin       sysadmin    clish       00:14 2024-09-13 T 17:03:55Z  console           15
2    pts/0  admin       sysadmin    -i          3.6s  2024-09-13 T 17:05:57Z  console           15
3    pts/1  pepper      netadmin    bash        00:08 2024-09-13 T 17:06:51Z  10.10.10.10 [ssh] 15
4    pts/2  netopusr    netoperator bash        00:08 2024-09-13 T 17:10:42Z  10.10.10.10 [ssh] 1
5    pts/3  secadminusr secadmin    bash        1.2s  2024-09-13 T 17:17:59Z  10.10.10.10 [ssh] 15
```

**Supported Releases**

10.2.0E or later

#### show privilege

Displays your current privilege level.

**Syntax**

`show privilege`

**Parameters**

None

**Defaults**

Not configured

**Command Mode**

EXEC

**Example**

```
OS10# show privilege
Current privilege level is 15.
```

**Supported Releases**

10.4.3.0 or later

#### show running-configuration privilege

Displays the configured privilege levels of all users.

**Syntax**

`show running-configuration privilege`

**Parameters**

None

**Defaults**

Not configured

**Command Mode**

EXEC

**Example**

```
OS10# show running-configuration privilege
privilege exec priv-lvl 3 configure
privilege configure priv-lvl 4 "interface ethernet"
enable password sha-512 $6$Yij02Phe2n6whp7b$ladskj0HowijIlkajg981 priv-lvl 12
```

**Supported Releases**

10.4.3.0 or later

#### system-user linuxadmin password

Configures a password for the linuxadmin user.

**Syntax**

`system-user linuxadmin password {clear-text-password | hashed-password}`

**Parameters**

None

**Defaults**

Not configured

**Command Mode**

CONFIGURATION

**Usage Information**

Use this command to set a clear-text or hashed-password for the linuxadmin user.

> **NOTE:** When you create or modify a password, the password string that you input appears as a string of asterisks instead of plain text.

**Example**

```
OS10(config)# system-user linuxadmin password Dell@Force10!@
OS10(config)# system-user linuxadmin password $6$3M55wOYy$Sw1V9Ok3GE4Hmf6h1ARH.dBHy9gpEFYUvdu15ZpnCYzt.nJjFm0VIz/rQvvJeX6krRtfYs2ZqBl6TkmLGAwtM
```

**Supported Releases**

10.4.3.0 or later

#### system-user linuxadmin disable

Disables the linuxadmin user.

**Syntax**

`[no] system-user linuxadmin disable`

**Parameters**

None

**Defaults**

Enabled

**Command Mode**

CONFIGURATION

**Usage Information**

Use this command to disable and lock the linuxadmin user. The no version of the command enables and unlocks the linuxadmin user.

**Example**

```
OS10(config)# system-user linuxadmin disable
OS10(config)# no system-user linuxadmin disable
```

**Supported Releases**

10.4.3.0 or later

#### userrole inherit

Reconfigures the default netoperator role and permissions that OS10 assigns by default to a RADIUS, TACACS+, or LDAP-authenticated user with an unknown user role or privilege level. You can also configure an unknown RADIUS, TACACS+, or LDAP user role to inherit permissions from an existing OS10 role.

**Syntax**

`userrole {default | name} inherit existing-role-name`

**Parameters**

- `default inherit` — Reconfigure the default permissions that are assigned to an authenticated user with a missing or unknown role or privilege level.
- `name inherit` — Enter the name of the RADIUS, TACACS+, or LDAP user role that inherits permissions from an OS10 user role; 32 characters maximum.
- `existing-role-name` — Assign the permissions associated with an OS10 user role:
  - `sysadmin` — Full access to all commands in the system, exclusive access to commands that manipulate the file system, and access to the system shell. A system administrator can create user IDs and user roles.
  - `secadmin` — Full access to configuration commands that set security policy and system access, such as password strength, AAA authorization, and cryptographic keys. A security administrator can display security information, such as cryptographic keys, login statistics, and log information.
  - `netadmin` — Full access to configuration commands that manage traffic flowing through the switch, such as routes, interfaces, and ACLs. A network administrator cannot access configuration commands for security features or view security information.
  - `netoperator` — Access to EXEC mode to view the current configuration with limited access. A network operator cannot modify any configuration setting on a switch.

**Default**

OS10 assigns the netoperator role to a user authenticated by a RADIUS, TACACS+, or LDAP server with a missing or unknown role or privilege level.

**Command Mode**

CONFIGURATION

**Usage Information**

When a RADIUS, TACACS+, or LDAP server authenticates a user and does not return a role or privilege level, or returns an unknown role or privilege level, OS10 assigns the netoperator role to the user by default. Use this command to change the default role from netoperator to another role, or to translate an unknown role returned by the LDAP server to any of the OS10-defined roles. To assign OS10 user role permissions to an unknown user role, enter the RADIUS, TACACS+, or LDAP name with the `inherit existing-role-name` value. The no version of the command resets the role to netoperator.

**Example**

```
OS10(config)# userrole default inherit sysadmin
```

**Supported Releases**

10.4.0E(R3P3) or later

#### username password role

Creates an authentication entry based on a username and password, and assigns a role to the user.

**Syntax**

`username username password password role role [priv-lvl privilege-level] [password-expiry expiry-time]`

**Parameters**

- `username username` — Enter a text string. It must contain a minimum of one and a maximum of 32 alphanumeric characters.

  > **NOTE:** While creating a user account using the `username password role` command, the username attribute must adhere to the following regular expression: `^[a-z_][a-z0-9_-]*[$]?$`

- `password password` — Enter a text string. A maximum of 32 alphanumeric characters; nine characters minimum. Password prefixes `$1$`, `$5$`, and `$6$` are not supported in clear-text passwords.
- `role role` — Enter a user role:
  - `sysadmin` — Full access to all commands in the system, exclusive access to commands that manipulate the file system, and access to the system shell. A system administrator can create user IDs and user roles.
  - `secadmin` — Full access to configuration commands that set security policy and system access, such as password strength, AAA authorization, and cryptographic keys. A security administrator can display security information, such as cryptographic keys, login statistics, and log information.
  - `netadmin` — Full access to configuration commands that manage traffic flowing through the switch, such as routes, interfaces, and ACLs. A network administrator cannot access configuration commands for security features or view security information.
  - `netoperator` — Access to EXEC mode to view the current configuration with limited access. A network operator cannot modify any configuration setting on a switch.
- `priv-lvl privilege-level` — Enter a privilege level, from 0 to 15. If you do not specify the `priv-lvl` option, the system assigns privilege level 1 for the `netoperator` role and privilege level 15 for the `sysadmin`, `secadmin`, and `netadmin` roles.
- `password-expiry expiry-time` — (Optional) Enter the password expiration time in days, from 60 to 240 days. Starting from 10.5.5.5, if this parameter is not specified, this command sets the password expiration time to 0, indicating that the password never expires and password change is not enforced upon first login. From Release 10.5.5.0 up to 10.5.5.4, the default password expiration time is set to 180 days.

**Default**

- User name and password entries are in clear text.
- There is no default user role.
- The default privilege levels are level 1 for `netoperator`, and level 15 for `sysadmin`, `secadmin`, and `netadmin`.
- If you do not configure the password expiration time for a user account, the global password expiration time is used by default.

**Security and Access**

sysadmin and secadmin

**Command Mode**

CONFIGURATION

**Usage Information**

By default, the password must be at least nine alphanumeric characters. Only the following special characters are supported:

```
! # % & ' ( ) ; < = > [ ] * + - . / : ^ _
```

Enter the password in clear text. It is converted to SHA-512 format in the running configuration. For backward compatibility with OS10 releases 10.3.1E and earlier, passwords entered in MD-5, SHA-256, and SHA-512 formats are supported.

You cannot assign a privilege level higher than privilege level 1 to a user with the `netoperator` role and higher than privilege level 2 for a `sysadmin`, `secadmin`, and `netadmin` roles. To increase the required password strength, use the `password-attributes` command. The no version of this command deletes the authentication for a user. Supported on the MX9116n and MX5108n switches in Full Switch mode starting in release 10.4.0E(R3S). Also supported in SmartFabric mode starting in release 10.5.0.1. To set the password expiration time for a specific user, use the `password-expiry` parameter. If you do not want the password to expire, set the expiration time to 0.

> **NOTE:** When a user logs in for the first time using the temporary password that is set up during the creation of their user account, OS10 prompts the user to change the password. To disable the prompt for resetting the temporary password for a specific user account, set the password expiration time to 0. Starting from Release 10.5.5.0P1, use the `password-change` command to change the password.

Starting from Release 10.6.1.0, this command is accessible to the secadmin role. Users with the secadmin role can only modify user passwords and cannot change any other user settings or parameters. The secadmin role does not have permission to modify the sysadmin user account.

**Example**

```
OS10(config)# username delluser password newpwd404 role sysadmin priv-lvl 10 password-expiry 230
```

**Supported Releases**

- 10.2.0E or later
- 10.6.1.0 or later — Accessible to the secadmin role.

## AAA

Authentication, authorization, and accounting (AAA) services secure networks against unauthorized access. In addition to local authentication, OS10 supports remote authentication dial-in user service (RADIUS), Lightweight Directory Access Protocol (LDAP), and terminal access controller access control system (TACACS+) client/server authentication systems. For RADIUS, LDAP, and TACACS+, an OS10 switch acts as a client and sends authentication requests to a server that contains all user authentication and network service access information.

A RADIUS, LDAP, or TACACS+ server provides: authentication of user credentials, authorization using role-based permissions, and accounting services. You can configure the security protocol that is used for different login methods and users. RADIUS provides limited authorization and accounting services compared to TACACS+ or LDAP. If you use a RADIUS, LDAP, or TACACS+ security server, configure the required security parameters on the server by following the procedures in the server documentation.

### AAA configuration

On the switch, AAA configuration consists of setting up access control and accounting services:

1. Configure the authentication methods used to allow access to the switch.
2. Configure the level of command authorization for authenticated users.
3. Configure security settings for user sessions.
4. Enable AAA accounting.

### AAA authentication

An OS10 switch uses a list of authentication methods to define the types of authentication and the sequence in which they apply. By default, OS10 uses only the local authentication method.

The authentication methods in the method list run in the order you configure them. Re-enter the methods to change the order. The local authentication method remains enabled even if you remove all configured methods in the list using the `no aaa authentication login {console | default}` command.

- Configure the AAA authentication method in CONFIGURATION mode.

  `aaa authentication login {console | default} {local | group radius | group tacacs+ | group ldap}`

  - `console` — Configure authentication methods for console logins.
  - `default` — Configure authentication methods for nonconsole such as SSH and Telnet logins.
  - `local` — Use the local username, password, and role entries configured with the `username password role` command.
  - `group radius` — Configure RADIUS servers using the `radius-server host` command.
  - `group tacacs+` — Configure TACACS+ servers using the `tacacs-server host` command.
  - `group ldap` — Configure LDAP servers using the `ldap-server host` command.

### Configure user role on server

If a console user logs in with RADIUS, LDAP, or TACACS+ authentication, the role you configured for the user on the RADIUS, LDAP, or TACACS+ server applies. User authentication fails if no role is configured on the authentication server.

To authenticate a user on OS10 through a TACACS+ server, configure the mandatory role with a value. This example uses Cisco ISE as the AAA server and the TACACS server configuration is shown in the following figure. This example uses the sysadmin role along with the corresponding privilege level 15 on the TACACS+ Server.

> **NOTE:** OS10 supports only the VSA for assigning user roles. The priv-level is supported only for RADIUS; other VSAs are not supported.

Also, you must configure the user role on the RADIUS, LDAP, or TACACS+ server using the vendor-specific attribute (VSA). If VSA is not configured or is configured incorrectly, the switch can log in with privilege level 1. The vendor ID of Dell Technologies is 674. Create a VSA with Name = `DellEMC-Group-Name`, OID = 2, Type = string. Valid values for `DellEMC-Group-Name` are:

**Table 102. OS10 user roles and privilege levels**

| User role | Default privilege level |
|-----------|-------------------------|
| sysadmin | 15 |
| secadmin | 15 |
| netadmin | 15 |
| netoperator | 1 |

Use the VSA `DellEMC-Group-Name` values when you create users on a RADIUS, LDAP, or TACACS+ server.

For more information about privilege levels, see Privilege levels.

For detailed information about how to configure vendor-specific attributes on a RADIUS, LDAP, or TACACS+ server, see the respective RADIUS, LDAP, or TACACS+ server documentation.

### Configure AAA authentication

```
OS10(config)# aaa authentication login default group radius local
OS10(config)# do show running-configuration aaa
aaa authentication login default group radius local
aaa authentication login console local
```

### Remove AAA authentication methods

```
OS10(config)# no aaa authentication login default
OS10(config)# do show running-configuration aaa
aaa authentication login default local
aaa authentication login console local
```

### User re-authentication

To prevent users from accessing resources and performing tasks that they are not authorized to perform, OS10 requires users to re-authenticate by logging in again when:

- Adding or removing a RADIUS server using the `radius-server host` command
- Adding or removing an authentication method using the `aaa authentication login {console | default} {local | group radius | group tacacs+}` command

By default, user re-authentication is disabled. You can enable this feature so that user re-authentication is required when any of these actions are performed. In these cases, logged-in users are logged out of the switch and all OS10 sessions terminate.

### Enable user re-authentication

- Enable user re-authentication in CONFIGURATION mode.

  `aaa re-authenticate enable`

The no version of this command disables user re-authentication.

### AAA with RADIUS authentication

To configure a RADIUS server for authentication, enter the server IP address or hostname, and the key that is used to authenticate the OS10 switch on a RADIUS host. You can enter the authentication key in plain text or encrypted format. You can change the User Datagram Protocol (UDP) port number on the server.

- Configure a RADIUS authentication server in CONFIGURATION mode. By default, a RADIUS server uses UDP port 1812.

  `radius-server host {hostname | ip-address}  key {0 authentication-key | 9 authentication-key | authentication-key} [auth-port port-number]`

To configure more than one RADIUS server, re-enter the `radius-server host` command multiple times. If you configure multiple RADIUS servers, OS10 attempts to connect in the order you configured them. An OS10 switch connects with the configured RADIUS servers one at a time, until a RADIUS server responds with an accept or reject response. The switch tries to connect with a server for the configured number of retransmit retries and timeout period.

Configure global settings for the timeout and retransmit attempts that are allowed on RADIUS servers. By default, OS10 supports three RADIUS authentication attempts and times out after five seconds. No source interface is configured. The default VRF instance is used to contact RADIUS servers.

> **NOTE:** You cannot configure both a nondefault VRF instance (including management VRF) and a source interface simultaneously for RADIUS authentication.

> **NOTE:** A RADIUS server that is configured with a hostname is not supported on a nondefault VRF.

- Configure the number of times OS10 retransmits a RADIUS authentication request in CONFIGURATION mode, from 0 to 100 retries; the default is 3.

  `radius-server retransmit retries`

- Configure the timeout period used to wait for an authentication response from a RADIUS server in CONFIGURATION mode, from 0 to 1000 seconds; the default is 5.

  `radius-server timeout seconds`

- (Optional) Specify an interface whose IP address is used as the source IP address for user authentication with RADIUS servers in CONFIGURATION mode. By default, no source interface is configured. OS10 selects the source IP address of any interface from which a packet is sent to a RADIUS server. An interface may have two IPv4 addresses and multiple IPv6 addresses. The selected OS10 source interface matches the version of the RADIUS server IP address: IPv4 or IPv6.

  - For an IPv4 RADIUS server, the primary IPv4 address is used.
  - For an IPv6 server, any of the global IPv6 addresses that are configured on the interface are used.
  - If no address of the same IP version as the RADIUS server is configured, RADIUS authentication is performed with no source interface, using the IP address of the management interface. The management IP address serves as the RADIUS network access server (NAS) IP address on the switch.

  `ip radius source-interface interface`

On the RADIUS server, you must update the configured IP routes using the Linux command line so that the source interface routes match the NAS IP route. If OS10 uses a RADIUS server VRF instance, a RADIUS server source interface is not supported and cannot be configured.

- (Optional) When you use management VRF for RADIUS authentication, configure the IP address of the network access server (NAS) using the `radius-server nas-ip-address` command.

  `radius-server nas-ip-address ipv4-address`

- (Optional) By default, the switch uses the default VRF instance to communicate with RADIUS servers. You can optionally configure a nondefault or the management VRF instance for RADIUS authentication in CONFIGURATION mode.

  ```
  radius-server vrf management
  radius-server vrf vrf-name
  ```

> **NOTE:** Before a RADIUS request is sent from Dell SmartFabric OS10, a DNS query is sent to resolve the name or IP address of the RADIUS server. So, when the IP name servers are configured and these name servers are unreachable, it may result in an SSH time-out. In this case, it is better to increase the IP SSH login-grace-time.

### Configure RADIUS server

```
OS10(config)# radius-server host 1.2.4.5 key secret1
OS10(config)# radius-server retransmit 10
OS10(config)# radius-server timeout 10
OS10(config)# ip radius source-interface mgmt 1/1/1
```

### Configure RADIUS server for non-default VRFs

```
OS10(config)# ip vrf blue
OS10(conf-vrf)# exit
OS10(config)# radius-server vrf blue
```

### Configure RADIUS server for management VRF

```
OS10(config)# ip vrf management
OS10(conf-vrf)# exit
OS10(config)# radius-server nas-ip-address 10.5.1.1
```

### View RADIUS server configuration

```
OS10# show running-configuration
...
radius-server host 1.2.4.5 key 9 3a95c26b2a5b96a6b80036839f296babe03560f4b0b7220d6454b3e71bdfc59b
radius-server retransmit 10
radius-server timeout 10
ip radius source-interface mgmt 1/1/1
...
```

### Delete RADIUS server

```
OS10# no radius-server host 1.2.4.5
```

### RADIUS over TLS authentication

Traditional RADIUS-based user authentication runs over UDP and uses the MD5 message-digest algorithm for secure communications. To provide enhanced security in RADIUS user authentication exchanges, RFC 6614 defines the RADIUS over Transport Layer Security (TLS) protocol. RADIUS over TLS secures the entire authentication exchange in a TLS connection and provides additional security by:

- Performing mutual authentication of a client and server using public key infrastructure (PKI) certificates
- Encrypting the entire authentication exchange so that neither the user ID nor password is vulnerable to discovery

RADIUS over TLS authentication requires that X.509v3 PKI certificates are configured on a certification authority (CA) and installed on the switch. For more information, including a complete RADIUS over TLS use case, see X.509v3 certificates.

> **NOTE:** If you enable FIPS using the `crypto fips enable` command, RADIUS over TLS operates in FIPS mode. In FIPS mode, RADIUS over TLS requires that a FIPS-compliant certificate and key pair are installed on the switch. In non-FIPS mode, RADIUS over TLS requires that a certificate is installed as a non-FIPS certificate. For information about how to install FIPS-compliant and non-FIPS certificates, see Request and install host certificates.

To configure RADIUS over TLS user authentication, use the `radius-server host tls` command. Enter the server IP address or host name, and the shared secret key used to authenticate the OS10 switch on a RADIUS host. You must enter the name of an X.509v3 security profile to use with RADIUS over TLS authentication — see Security profiles. You can enter the authentication key in plain text or encrypted format. By default, RADIUS over TLS connections use TCP port 2083, and require that the authentication key is radsec. You can change the TCP port number on the server.

- Configure a RADIUS over TLS authentication on a RADIUS server in CONFIGURATION mode.

  `radius-server host {hostname | ip-address} tls security-profile profile-name [auth-port port-number] key {0 authentication-key | 9 authentication-key | authentication-key}`

To configure more than one RADIUS server for RADIUS over TLS authentication, re-enter the `radius-server host tls` command multiple times. If you configure multiple RADIUS servers, OS10 attempts to connect in the order you configured them. An OS10 switch connects with the configured RADIUS servers one at a time, until a RADIUS server responds with an accept or reject response. The switch tries to connect with a server for the configured number of retransmit retries and timeout period.

A security profile determines the X.509v3 certificate on the switch to use for TLS authentication with a RADIUS server. To configure a security profile for an OS10 application, see Security profiles.

Configure global settings for the timeout and retransmit attempts allowed on RADIUS servers as described in RADIUS authentication.

### Configure RADIUS over TLS authentication server

```
OS10(config)# radius-server host 1.2.4.5 tls security-profile radius-prof key radsec
OS10(config)# radius-server retransmit 10
OS10(config)# radius-server timeout 10
```

### AAA with TACACS+ authentication

Configure a TACACS+ authentication server by entering the server IP address or hostname. You must also enter a text string for the key that is used to authenticate the OS10 switch on a TACACS+ host. The Transmission Control Protocol (TCP) port entry is optional.

TACACS+ provides greater data security by encrypting the entire protocol portion in a packet that is sent from the switch to an authentication server. RADIUS encrypts only passwords.

- Configure a TACACS+ authentication server in CONFIGURATION mode. By default, a TACACS+ server uses TCP port 49 for authentication.

  `tacacs-server host {hostname | ip-address}  key {0 authentication-key | 9 authentication-key | authentication-key} [auth-port port-number]`

Re-enter the `tacacs-server host` command multiple times to configure more than one TACACS+ server. If you configure multiple TACACS+ servers, OS10 attempts to connect in the order you configured them. An OS10 switch connects with the configured TACACS+ servers one at a time, until a TACACS+ server responds with an accept or reject response.

Configure a global timeout setting that is allowed on TACACS+ servers. By default, OS10 times out after five seconds. No source interface is configured. The default VRF instance is used to contact TACACS+ servers.

> **NOTE:** You cannot configure both a nondefault VRF instance and a source interface simultaneously for TACACS+ authentication.

> **NOTE:** A TACACS+ server that is configured with a hostname is not supported on a nondefault VRF.

- Configure the global timeout used to wait for an authentication response from TACACS+ servers in CONFIGURATION mode, from 1 to 1000 seconds; the default is 5.

  `tacacs-server timeout seconds`

- (Optional) Specify an interface whose IP address is used as the source IP address for user authentication with a TACACS+ server in CONFIGURATION mode. By default, no source interface is configured. OS10 selects the source IP address of any interface from which a packet is sent to a TACACS+ server.

  > **NOTE:** If you configure a source interface which has no IP address, the IP address of the management interface is used.

  `ip tacacs source-interface interface`

- (Optional) By default, the switch uses the default VRF instance to communicate with TACACS+ servers. You can optionally configure a nondefault or the management VRF instance for TACACS+ authentication in CONFIGURATION mode.

  ```
  tacacs-server vrf management
  tacacs-server vrf vrf-name
  ```

### Configure TACACS+ server

```
OS10(config)# tacacs-server host 1.2.4.5 key mysecret
OS10(config)# ip tacacs source-interface loopback 2
```

### Configure TACACS+ server for non-default VRFs

```
OS10(config)# ip vrf blue
OS10(conf-vrf)# exit
OS10(config)# tacacs-server vrf blue
```

### View TACACS+ server configuration

```
OS10# show running-configuration
...
tacacs-server host 1.2.4.5 key 9 3a95c26b2a5b96a6b80036839f296babe03560f4b0b7220d6454b3e71bdfc59b
ip tacacs source-interface loopback 2
...
```

### Delete TACACS+ server

```
OS10# no tacacs-server host 1.2.4.5
```

### TACACS as Primary Authentication

The AAA authentication configuration must be present as one of the authentication methods. The following error message is displayed when you attempt to configure AAA authentication without first configuring the local authentication method:

```
% Error: local authentication not configured
```

After upgrading to 10.5.1 from an earlier release, there is no change in the AAA authentication configuration when this configuration has the local authentication method configured.

### AAA with LDAP authentication

The Lightweight Directory Access Protocol (LDAP) authentication feature in SmartFabric OS10 enables centralized user management and enhanced security by integrating with LDAP servers, including support for LDAP over TLS (LDAPS). This integration allows for seamless authentication of users across telnet login, SSH login, and console connections.

> **NOTE:** The LDAP implementation is qualified for compatibility with OpenLDAP and 389 Directory Server.

> **NOTE:** By default, the switch uses the UID attribute for authentication. To ensure a successful login, this attribute must be populated in the Advanced Attributes section of the Active Directory account on the domain controller.

Configure an LDAP authentication server by entering the server IP address or hostname, and port number. Optionally, you can configure TLS along with a security profile to enhance security. By default, LDAP uses port number 389 for plain TCP and 636 for TLS connections. Before configuring LDAP as an authentication method, ensure that at least one LDAP server is configured and available.

- Configure an LDAP authentication server in CONFIGURATION mode.

  `ldap-server host {hostname | ip-address} [tls on security-profile profilename] [port server_port_value]`

  You can run this command multiple times to configure additional LDAP servers. A maximum of 10 LDAP servers can be configured. If you configure multiple LDAP servers, OS10 attempts to connect in the order you configured them. OS10 switch connects with the configured LDAP servers one at a time, and the next LDAP server is used only when the current LDAP server becomes unreachable.

- Configures LDAP server properties, such as base distinguished name (DN), bind DN, and bind password in CONFIGURATION mode.

  `ldap-server {{basedn ldap_base_val} | {binddn binddn_val} | {bindpw {0 bindpw_val | 9 encrypted_bindpw_val | bindpw_val}}}`

  Ensure that in the case of multiple LDAP servers, the configuration remains consistent across all LDAP servers that are configured in OS10.

- Configure mapping of LDAP attributes and object classes to OS10 roles in CONFIGURATION mode.

  `ldap-server map {{[attribute attribute_from_val to attribute_to_val]} | {[objectclass objectclass_from_val to objectclass_to_val]} | {[defaultattribute-value default_from_val to default_to_val]} | {[overrideattribute-value override_from_val to override_to_val]}}`

  This command allows the mapping of attributes, default attribute values, override attribute values, and object classes to different values. Use the `userrole` command to map any unknown LDAP server returned role to system-defined roles.

- Configure unknown LDAP user roles to inherit permissions from existing OS10 roles. If no valid LDAP roles are returned from the LDAP server, OS10 assigns the default role netoperator. Run the following command only if you want to change the default role from netoperator to another role, or to translate an unknown role that is returned by the LDAP server to any of the OS10-defined roles.

  `userrole {default | name} inherit existing-role-name`

  If local user account exists for the same username, OS10 assigns the privilege level that is associated with the local user account. If no local user account exists, the privilege level of the LDAP user is determined by their group membership in LDAP. OS10 assigns privilege levels based on default settings, ranging from 0 to 15.

- Enable LDAP-related debugging in EXEC mode.

  `debug ldap`

  Debug print statements that are generated during LDAP debugging are logged in the journalctl log.

### Configure LDAP server

```
OS10(config)# ldap-server host 10.10.10.10 tls on security-profile ldapSecurityProfile port 638
```

Or,

```
OS10(config)# ldap-server host 11.11.11.11
```

### Configure LDAP server parameters

```
OS10(config)# ldap-server basedn "dc=ldapserver3 dc=com"
OS10(config)# ldap-server binddn "cn=admin dc=ldapserver3 dc=com"
OS10(config)# ldap-server bindpw *********
```

### View LDAP server configuration

```
OS10# show ldap-server
-----------------------------------
LDAP Global Configuration
-----------------------------------
basedn : dc=ldapserver3 dc=com
binddn : cn=admin dc=ldapserver3 dc=com
bindpw : Password has been set successfully
--------------------------------------------
HOST         PORT  TLS  SECURITY-PROFILE
--------------------------------------------
10.10.10.10  636   on   newProfile
```

### Delete LDAP server

```
OS10(config)# no ldap-server host 10.10.10.10
```

### TLS and FIPS Compliance

SmartFabric OS10 adheres to FIPS-compliant standards for LDAP TLS connections, ensuring that strict security protocols are followed, regardless of whether FIPS mode is explicitly enabled.

### Supported Cipher Suites in FIPS Mode

LDAP implementation supports the following FIPS-compliant cipher suites, even when FIPS mode is not enabled:

- **Supported Protocols:** TLS 1.2 and TLS 1.3
- **TLS 1.3 Cipher Suites:** `TLS_AES_256_GCM_SHA384` and `TLS_AES_128_GCM_SHA256`
- **TLS 1.2 Cipher Suites:** `TLS_ECDHE_ECDSA_AES_256_GCM_SHA384`, `TLS_ECDHE_ECDSA_AES_128_GCM_SHA256`, `TLS_ECDHE_RSA_AES_256_GCM_SHA384`, and `TLS_ECDHE_RSA_AES_128_GCM_SHA256`.

> **NOTE:** If the LDAP server does not support a matching cipher suite and protocol version, the connection fails.

#### Restrictions and limitations

The following restrictions and limitations are applicable for this feature in OS10 Release 10.6.0.1:

- OS10 selects the communication interface based on routing table entries. Manual configuration of communication options such as Ethernet, Loopback, LAG, management interface, and VLANs is not supported.
- LDAP uses only the default Virtual Routing and Forwarding (VRF) for communication. Configuration of a nondefault VRF instance (including management VRF) for LDAP authentication is not supported.
- When downgrading from Release 10.6.0.1 with LDAP authentication enabled to an older release that does not support LDAP authentication, OS10 defaults to using the local authentication method or other configured remote authentication method (such as RADIUS or TACACS+). LDAP-related configuration is lost.

### Configure authorization

AAA command authorization controls user access to a set of commands that are assigned to users and is performed after user authentication. When enabled, AAA authorization checks a remote authorization server for each command that a user enters on the switch. If the commands that are entered by the user are configured in the remote server for that user, the remote server authorizes the usage of the command.

By default, the role you configure with the `username password role` command sets the level of CLI commands that a user can access.

An OS10 switch uses a list of authorization methods and the sequence in which they apply to determine the level of command authorization that is granted to a user. You can configure authorization methods with the `aaa authorization` command. You can also configure TACACS+ server-based authorization. By default, OS10 uses only the local authorization method.

The authorization methods in the method list run in the order you configure them. Re-enter the methods to change the order. The local authorization method remains enabled even if you remove all configured methods in the list using the `no aaa authorization` command.

- Enable authorization and configure the authorization methods for CLI access in CONFIGURATION mode. Re-enter the command to configure additional authorization methods and CLI access.

  > **NOTE:** OS10 does not support the `local group tacacs+` order of authorization methods, which is supported in OS9. The OS10 command syntax is as follows:

  `aaa authorization {commands | config-commands | exec-commands} {role user-role} {console | default} {[group tacacs+] [local]}`

  - `commands` — Configure authorization for all CLI commands, including all EXEC and configuration commands.
  - `config-commands` — Configure authorization only for configuration commands.
  - `exec-commands` — Configure authorization only for EXEC commands.
  - `role user-role` — Configure command authorization for a user role: `sysadmin`, `secadmin`, `netadmin`, or `netoperator`.
  - `console` — Configure authorization for console-entered commands.
  - `default` — Configure authorization for non-console-entered commands and commands that are entered in nonconsole sessions, such as in SSH and VTY.
  - `group tacacs+` — Use the TACACS+ servers that are configured with the `tacacs-server host` command for command authorization.
  - `local` — Use the local username, password, and role entries configured with the `username password role` command for command authorization.

> **NOTE:** Custom user roles are supported, but the custom privilege levels are not supported. The default privilege level based on the user role is assigned.

For detailed information about how to configure vendor-specific attributes on a security server, see the respective RADIUS, LDAP, or TACACS+ server documentation.

### Examples: AAA authorization

- All commands that are entered from a console session with the sysadmin user role are authorized using configured TACACS+ servers first, and local user credentials next, if TACACS+ servers are not reachable or configured.

  ```
  OS10(config)# aaa authorization commands role sysadmin console group tacacs+ local
  ```

- All configuration commands that are entered from a nonconsole session with the sysadmin user role are authorized using the configured TACACS+ servers.

  ```
  OS10(config)# aaa authorization config-commands role sysadmin default group tacacs+
  ```

### Remove AAA authorization methods

```
OS10(config)# no aaa authorization commands role sysadmin console
```

### Enable AAA accounting

To record information about all user-entered commands, use the AAA accounting feature — not supported for RADIUS accounting. AAA accounting records login and command information in OS10 sessions on console connections using the console option and remote connections using the default option, such as Telnet and SSH.

AAA accounting sends accounting messages:

- Sends a start notice when a process begins, and a stop notice when the process ends using the `start-stop` option
- Sends only a stop notice when a process ends using the `stop-only` option
- No accounting notices are sent using the `none` option
- Logs all accounting notices in syslog using the `logging` option
- Logs all accounting notices on configured TACACS+ servers using the `group tacacs+` option

#### Enable AAA accounting

- Enable AAA accounting in CONFIGURATION mode.

  `aaa accounting commands all {console | default} {start-stop | stop-only | none} [logging] [group tacacs+]`

The no version of this command disables AAA accounting.

**Example**

The following example enables AAA accounting for all commands on the console. And also enables the system to send a start notice when a process begins, and a stop notice when the process ends to the console and a TACACS+ server.

```
OS10(config)# aaa accounting commands all console start-stop logging group tacacs+
```

### Transport Layer Security

Transport Layer Security (TLS) is a protocol that provides communication security between the client and server applications.

**Upgrade to Transport Layer Security (TLS)** — In the SmartFabric OS10, 10.5.6.0 release, the TLS is upgraded to version 1.3. By default, OS10 uses TLS 1.3 to secure all communication protocols, connections, or applications over SSL or TLS. The following OS10 applications and services use TLS:

**Table 103. OS10 applications and services**

| OS10 applications and services | Usage |
|--------------------------------|-------|
| HTTPS Server (nginx) | Server |
| HTTPS Client (nginx) | Client |
| RADIUS | Client |
| syslog-ng | Client |
| Telemetry | Client |
| OpenFlow | Client |
| gNMI | Client |

## AAA commands

#### aaa accounting

Enables AAA accounting.

**Syntax**

`aaa accounting exec commands all {console | default} {start-stop | stop-only | none} [logging] [group tacacs+]`

**Parameters**

- `exec` — Record user authentication events.
- `commands all` — Record all user-entered commands. RADIUS accounting does not support this option.
- `console` — Record all user authentication and logins or all user-entered commands in OS10 sessions on console connections.
- `default` — Record all user authentication and logins or all user-entered commands in OS10 sessions on remote connections; for example, Telnet and SSH.
- `start-stop` — Send a start notice when a process begins, and a stop notice when the process ends.
- `stop-only` — Send only a stop notice when a process ends.
- `none` — No accounting notices are sent.
- `logging` — Logs all accounting notices in syslog.
- `group tacacs+` — Logs all accounting notices on the first reachable TACACS+ server.

**Default**

AAA accounting is disabled.

**Command Mode**

CONFIGURATION

**Usage Information**

You can enable the recording of accounting events in both the syslog and on TACACS+ servers. The no version of the command disables AAA accounting.

**Example**

```
OS10(config)# aaa accounting commands all console start-stop logging group tacacs+
```

**Supported Releases**

10.4.1.0 or later

#### aaa authentication login

Configures the AAA authentication method for console, SSH, and Telnet logins.

**Syntax**

`aaa authentication login {console | default} {local | group radius | group tacacs+ | group ldap}`

**Parameters**

- `console` — Configure authentication methods for console logins.
- `default` — Configure authentication methods for SSH and Telnet logins.
- `local` — Use the local username, password, and role entries configured with the `username password role` command.
- `group radius` — Use the RADIUS servers configured with the `radius-server host` command.
- `group tacacs+` — Use the TACACS+ servers that are configured with the `tacacs-server host` command.
- `group ldap` — Use the LDAP servers that are configured with the `ldap-server host` command.

**Default**

Local authentication

**Command Mode**

CONFIGURATION

**Usage Information**

In SmartFabric mode, the local authentication method must be configured along with TACACS, RADIUS, or LDAP authentication. Before configuring LDAP as an authentication method, ensure that at least one LDAP server is set up and available as long as the LDAP authentication method is in use. To reorder the AAA authentication methods, execute the CLI command again. The no version of this command removes all configured authentication methods and defaults to using local authentication.

**Example**

```
OS10(config)# aaa authentication login default group radius local
OS10(config)# do show running-configuration aaa
aaa authentication login default group radius local
aaa authentication login console local
OS10(config)# no aaa authentication login default
OS10(config)# do show running-configuration aaa
aaa authentication login default local
aaa authentication login console local
```

**Supported Releases**

10.4.1.0 or later

#### aaa authorization

Enables authorization and configure the authorization methods for CLI access.

**Syntax**

`aaa authorization {commands | config-commands | exec-commands} {role user-role} {console | default} {[group tacacs+] [local]}`

**Parameters**

- `commands` — Configure authorization for all CLI commands, including all EXEC and configuration commands.
- `config-commands` — Configure authorization only for configuration commands.
- `exec-commands` — Configure authorization only for EXEC commands.
- `role user-role` — Configure command authorization for a user role: sysadmin, secadmin, netadmin, or netoperator.
- `console` — Configure authorization for console-entered commands.
- `default` — Configure authorization for non-console-entered commands and commands that are entered in non-console sessions, such as in SSH and VTY.
- `group tacacs+` — Use the TACACS+ servers that are configured with the `tacacs-server host` command for command authorization.
- `local` — Use the local username, password, and role entries configured with the `username password role` command for command authorization.

**Default**

Local authorization

**Command Mode**

CONFIGURATION

**Usage Information**

Re-enter the command to configure additional authorization methods and CLI access. The authorization methods in the method list perform in the order that you configure them. Re-enter the methods to change the order. The local authorization method remains enabled even if you remove all configured methods in the list using the `no aaa authorization` command. If a console user logs in with TACACS+ authorization, the role you configured for the user on the TACACS+ server applies. If no role is configured on the security server, user authorization fails.

**Example**

```
OS10(config)# aaa authorization commands role sysadmin console group tacacs+ local
OS10(config)# aaa authorization config-commands role sysadmin default group tacacs+
OS10(config)# no aaa authorization commands role sysadmin console
```

**Supported Releases**

10.5.1.0 or later

#### aaa reauthenticate enable

Requires user reauthentication after a change in the authentication method or server.

**Syntax**

`aaa re-authenticate enable`

**Parameters**

None

**Default**

Disabled

**Command Mode**

EXEC

**Usage Information**

After you enable user reauthentication and change the authentication method or server, users are logged out of the switch and prompted to log in again to reauthenticate. User reauthentication is triggered by:

- Adding or removing a RADIUS server as a configured server host with the `radius-server host` command.
- Adding or removing an authentication method with the `aaa authentication [local | radius]` command.

The no version of the command disables user reauthentication.

**Example**

```
OS10(config)# aaa re-authenticate enable
```

**Supported Releases**

10.4.0E(R1) or later

#### debug ldap

Enables LDAP debugging.

**Syntax**

`[no] debug ldap`

**Parameters**

None

**Defaults**

Disabled

**Command Mode**

EXEC

**Security and access**

sysadmin and secadmin

**Usage Information**

The no version of this command disables LDAP debugging.

**Example**

```
OS10# debug ldap
```

**Supported Releases**

10.6.0.1 or later

#### ip radius source-interface

Specifies the interface whose IP address is used as the source IP address for user authentication with a RADIUS server.

**Syntax**

`ip radius source-interface interface`

**Parameters**

`interface`:

- `ethernet node/slot/port[:subport]` — Enter a physical Ethernet interface.
- `loopback number` — Enter a Loopback interface, from 0 to 16383.
- `mgmt 1/1/1` — Enter the management interface.
- `port-channel channel-id` — Enter a LAG ID, from 1 to 28.
- `vlan vlan-id` — Enter a VLAN ID, from 1 to 4093.
- `virtual-network virtual-network-id` — Enter a virtual network, from 1 to 65535.

**Default**

Not configured.

**Command Mode**

CONFIGURATION

**Usage Information**

By default, no source interface is configured. OS10 selects the source IP address as the IP address of the interface from which a packet is sent to the RADIUS server. The no version of this command removes the configured source interface.

**Example**

```
OS10(config)# ip radius source-interface ethernet 1/1/10
```

**Example (virtual-network)**

```
OS10(config)# ip radius source-interface virtual-network 1234
```

**Supported Releases**

- 10.4.3.1 or later
- 10.6.0.2 or later — Added support for the virtual-network type in the RADIUS source interface.

#### ip tacacs source-interface

Specifies the interface whose IP address is used as the source IP address for user authentication with a TACACS+ server.

**Syntax**

`ip tacacs source-interface interface`

**Parameters**

`interface`:

- `ethernet node/slot/port[:subport]` — Enter a physical Ethernet interface.
- `loopback number` — Enter a Loopback interface, from 0 to 16383.
- `mgmt 1/1/1` — Enter the management interface.
- `port-channel channel-id` — Enter a LAG ID, from 1 to 28.
- `vlan vlan-id` — Enter a VLAN ID, from 1 to 4093.

**Default**

Not configured.

**Command Mode**

CONFIGURATION

**Usage Information**

By default, no source interface is configured. OS10 selects the source IP address as the IP address of the interface from which a packet is sent to the TACACS+ server. The no version of this command removes the configured source interface.

**Example**

```
OS10(config)# ip tacacs source-interface ethernet 1/1/10
```

**Supported Releases**

10.4.1.0 or later

#### ldap-server

Configures the LDAP server properties.

**Syntax**

`ldap-server {{basedn ldap_base_val} | {binddn binddn_val} | {bindpw {0 bindpw_val | 9 encrypted_bindpw_val | bindpw_val}}`

**Parameters**

- `ldap_base_val` — Enter the base distinguished name (DN) that identifies the entry in the LDAP directory from which search operations are initiated by LDAP clients. The supported format is `"dc=string dc=string"`. You can include one or more components, which are separated by spaces, and the entire string must be wrapped in quotes. For example, `"dc=example dc=com"` represents the domain "example.com."
- `binddn_val` — Enter the username that is used to search and request the authentication to the LDPA server. The supported format is `"cn=string dc=string"`. The "cn" specifies the name of an entry, while "dc" denotes parts of a domain name. You can include zero or more domain components, which are separated by spaces, and the entire string must be wrapped in quotes. For example, `"cn=Dell dc=example dc=com"` identifies the entry for "Dell" in the domain "example.com."
- `0 bindpw_val` — Enter the password for the bind DN to access the LDAP server in plain text.
- `9 encrypted_bindpw_val` — Enter the password for the bind DN to access the LDAP server in encrypted format.
- `bindpw_val` — Enter the password in plain text. It is not necessary to enter 0 before the password. The plain text bind password values are masked with asterisks.

**Defaults**

None

**Command Mode**

CONFIGURATION

**Security and access**

sysadmin and secadmin

**Usage Information**

The no version of this command resets the values to the default.

**Example**

```
OS10(config)# ldap-server basedn "dc=ldapserver3 dc=com"
OS10(config)# ldap-server binddn "cn=admin dc=ldapserver3 dc=com"
OS10(config)# ldap-server bindpw 9 b39f6b6cfe05816ba3518cda1b89f0e13127263c6d13b1f37a04085c75440e92
```

**Supported Releases**

10.6.0.1 or later

#### ldap-server host

Configures an LDAP server that is used to authenticate the switch on the server.

**Syntax**

`ldap-server host {hostname | ip-address} [tls on security-profile profilename] [port server_port_num]`

**Parameters**

- `hostname` — Enter the hostname of the LDAP server; for example, `server01.example.com`.
- `ip-address` — Enter the IPv4 or IPv6 address of the LDAP server in A.B.C.D or x:x:x:x::x format.
- `profilename` — (Optional) Specifies the name of an X.509v3 security profile to use with LDAP over TLS authentication.
- `server_port_num` — (Optional) Specifies the server port number. Default values are 389 when TLS is disabled and 636 when TLS is enabled.

**Default**

Not configured

**Command Mode**

CONFIGURATION

**Security and access**

sysadmin and secadmin

**Usage Information**

This command enables the configuration of an LDAP server with the required security options. To configure multiple LDAP servers, run this command multiple times. A maximum of 10 LDAP servers can be configured. The no version of this command removes an LDAP server configuration.

**Example (with TLS)**

```
OS10(config)# ldap-server host 10.10.10.10 tls on security-profile ldapSecurityProfile port 638
```

**Example (without TLS)**

```
OS10(config)# ldap-server host 11.11.11.11
```

**Example (Delete LDAP server)**

```
OS10(config)# no ldap-server host 11.11.11.11
```

**Supported Releases**

10.6.0.1 or later

#### ldap-server map

Configures mapping of LDAP attributes and object classes to OS10 roles.

**Syntax**

`ldap-server map {{[attribute attribute_from_val to attribute_to_val]} | {[objectclass objectclass_from_val to objectclass_to_val]} | {[defaultattribute-value default_from_val to default_to_val]} | {[overrideattribute-value override_from_val to override_to_val]}}`

**Parameters**

- `attribute attribute_from_val to attribute_to_val` — Maps LDAP attributes to OS10 attributes.
- `objectclass objectclass_from_val to objectclass_to_val` — Maps LDAP object classes to OS10 object classes.
- `defaultattribute-value default_from_val to default_to_val` — Maps default attribute values for LDAP attributes.
- `overrideattribute-value override_from_val to override_to_val` — Allows overriding default attribute values with custom values.

**Defaults**

None

**Command Mode**

CONFIGURATION

**Security and access**

sysadmin and secadmin

**Usage Information**

Ensure that the configuration remains consistent across all LDAP servers that are configured in SmartFabric OS10. The no version of this command (`no ldap-server map {[attribute attribute_from_val] | [objectclass objectclass_from_val] | [defaultattribute-value default_from_val] | [overrideattribute-value override_from_val]}`) deletes the configuration.

**Example**

```
OS10(config)# ldap-server map objectclass posixAccount to UnixAccount
OS10(config)# no ldap-server map objectclass posixAccount to UnixAccount
```

**Supported Releases**

10.6.0.1 or later

#### radius-server host

Configures a RADIUS server and the key that is used to authenticate the switch on the server.

**Syntax**

`radius-server host {hostname | ip-address} key {0 authentication-key | 9 authentication-key | authentication-key} [auth-port port-number]`

**Parameters**

- `hostname` — Enter the hostname of the RADIUS server.
- `ip-address` — Enter the IPv4 (A.B.C.D) or IPv6 (x:x:x:x::x) address of the RADIUS server.
- `key 0 authentication-key` — Enter an authentication key in plain text. A maximum of 42 characters.
- `key 9 authentication-key` — Enter an authentication key in encrypted format. A maximum of 128 characters.
- `authentication-key` — Enter an authentication in plain text. A maximum of 42 characters. It is not necessary to enter 0 before the key.
- `auth-port port-number` — (Optional) Enter the UDP port number used on the server for authentication, from 1 to 65535, default 1812.

**Default**

Not configured

**Command Mode**

CONFIGURATION

**Usage Information**

The authentication key must match the key that is configured on the RADIUS server. You cannot enter spaces in the key. The `show running-configuration` output displays both unencrypted and encrypted keys in encrypted format. Configure global settings for the timeout and retransmit attempts that are allowed on RADIUS servers using the `radius-server retransmit` and `radius-server timeout` commands. The no version of this command removes a RADIUS server configuration.

**Example**

```
OS10(config)# radius-server host 1.5.6.4 key secret1
```

**Supported Releases**

10.2.0E or later

#### radius-server host tls

Configures a RADIUS server for RADIUS over TLS user authentication and secure communication. For RADIUS over TLS authentication, the radsec shared key and a security profile that uses an X.509v3 certificate are required.

**Syntax**

`radius-server host {hostname | ip-address} tls security-profile profile-name [auth-port tcp-port-number] key {0 authentication-key | 9 authentication-key | authentication-key}`

**Parameters**

- `hostname` — Enter the hostname of the RADIUS server.
- `ip-address` — Enter the IPv4 (A.B.C.D) or IPv6 (x:x:x:x::x) address of the RADIUS server.
- `tls` — Enter tls to secure RADIUS server communication using the TLS protocol.
- `security-profile profile-name` — Enter the name of an X.509v3 security profile to use with RADIUS over TLS authentication. To configure a security profile for an OS10 application, see Security profiles.
- `auth-port tcp-port-number` — (Optional) Enter the TCP port number that the server uses for authentication. The range is from 1 to 65535. The default is 2083.
- `key 0 authentication-key` — Enter the radsec shared key in plain text.
- `key 9 authentication-key` — Enter the radsec shared key in encrypted format.
- `authentication-key` — Enter the radsec shared key in plain text. It is not necessary to enter 0 before the key.

**Default**

TCP port 2083 on a RADIUS server for RADIUS over TLS communication

**Command Mode**

CONFIGURATION

**Usage Information**

For RADIUS over TLS authentication, configure the radsec shared key on the server and OS10 switch. The `show running-configuration` output displays both the unencrypted and encrypted key in encrypted format. Configure global settings for the timeout and retransmit attempts that are allowed on a RADIUS over TLS servers using the `radius-server retransmit` and `radius-server timeout` commands. RADIUS over TLS authentication requires that X.509v3 PKI certificates are configured on a certification authority and installed on the switch. For more information, including a complete RADIUS over TLS example, see X.509v3 certificates. The no version of this command removes a RADIUS server from RADIUS over TLS communication.

**Example**

```
OS10(config)# radius-server host 1.5.6.4 tls security-profile radius-admin key radsec
```

**Supported Releases**

10.4.3.0 or later

#### radius-server retransmit

Configures the number of authentication attempts allowed on RADIUS servers.

**Syntax**

`radius-server retransmit retries`

**Parameters**

`retries` — Enter the number of retry attempts, from 0 to 10.

**Default**

An OS10 switch retransmits a RADIUS authentication request three times.

**Command Mode**

CONFIGURATION

**Usage Information**

Use this command to globally configure the number of retransmit attempts allowed for authentication requests on RADIUS servers. The no version of this command resets the value to the default.

**Example**

```
OS10(config)# radius-server retransmit 5
```

**Supported Releases**

10.2.0E or later

#### radius-server timeout

Configures the timeout that is used to resend RADIUS authentication requests.

**Syntax**

`radius-server timeout seconds`

**Parameters**

`seconds` — Enter the time in seconds for retransmission, from 1 to 100.

**Default**

An OS10 switch stops sending RADIUS authentication requests after five seconds.

**Command Mode**

CONFIGURATION

**Usage Information**

Use this command to globally configure the timeout value used on RADIUS servers. The no version of this command resets the value to the default.

**Example**

```
OS10(config)# radius-server timeout 90
```

**Supported Releases**

10.2.0E or later

#### radius-server vrf

Configures the RADIUS server for the management or nondefault VRF instance.

**Syntax**

`radius-server vrf {management | vrf-name}`

**Parameters**

- `management` — Enter the keyword to configure the RADIUS server for the management VRF instance.
- `vrf-name` — Enter the keyword then the name of the VRF to configure the RADIUS server for that nondefault VRF instance.

**Defaults**

Not configured

**Command Mode**

CONFIGURATION

**Usage Information**

Use this command to associate RADIUS servers with a VRF. If you do not configure a VRF on the RADIUS server list, the servers are on the default VRF. RADIUS server lists and VRFs have one-to-one mapping. The no version of this command removes the RADIUS server from the management VRF instance.

**Example**

```
OS10(config)# radius-server vrf management
OS10(config)# radius-server vrf blue
```

**Supported Releases**

10.4.0E(R1) or later

#### tacacs-server host

Configures a TACACS+ server and the key that is used to authenticate the switch on the server.

**Syntax**

`tacacs-server host {hostname | ip-address} key {0 authentication-key | 9 authentication-key | authentication-key} [auth-port port-number]`

**Parameters**

- `hostname` — Enter the hostname of the TACACS+ server.
- `ip-address` — Enter the IPv4 (A.B.C.D) or IPv6 (x:x:x:x::x) address of the TACACS+ server.
- `key 0 authentication-key` — Enter an authentication key in plain text. A maximum of 42 characters.
- `key 9 authentication-key` — Enter an authentication key in encrypted format with a maximum of 128 characters.
- `authentication-key` — Enter an authentication in plain text with a maximum of 42 characters. It is not necessary to enter 0 before the key.
- `key authentication-key` — Enter a text string for the encryption key used to authenticate the switch on the TACACS+ server. A maximum of 42 characters.

**Default**

Not configured

**Command Mode**

CONFIGURATION

**Usage Information**

The authentication key must match the key that is configured on the TACACS+ server. You cannot enter spaces in the key. The `show running-configuration` output displays both unencrypted and encrypted keys in encrypted format. Configure the global timeout that is allowed for authentication requests on TACACS+ servers using the `tacacs-server timeout` command. By default, OS10 times out an authentication attempt on a TACACS+ server after five seconds. The no version of this command removes a TACACS+ server configuration.

**Example**

```
OS10(config)# tacacs-server host 1.5.6.4 key secret1
```

**Supported Releases**

10.4.0E(R2) or later

#### tacacs-server timeout

Configures the global timeout that is used for authentication attempts on TACACS+ servers.

**Syntax**

`tacacs-server timeout seconds`

**Parameters**

`seconds` — Enter the timeout period used to wait for an authentication response from a TACACS+ server, from 1 to 1000 seconds.

**Default**

5 seconds

**Command Mode**

CONFIGURATION

**Usage Information**

The no version of this command resets the TACACS+ server timeout to the default.

**Example**

```
OS10(config)# tacacs-server timeout 360
```

**Supported Releases**

10.4.0E(R2) or later

#### tacacs-server vrf

Creates an association between a TACACS server group and a VRF and source interface.

**Syntax**

`tacacs-server vrf {management | vrf-name}`

**Parameters**

- `management` — Enter the keyword to associate TACACS servers to the management VRF instance. This option restricts the TACACS server association to the management VRF only.
- `vrf-name` — Enter the keyword then the name of the VRF to associate TACACS servers with that VRF.

**Defaults**

None.

**Command Mode**

CONFIGURATION

**Usage Information**

Use this command to associate TACACS servers with a VRF instance. If you do not configure a VRF in the TACACS server list, the servers are on the default VRF instance. TACACS server lists and VRFs have one-to-one mapping. When you remove the VRF instance, the TACACS server lists are also removed automatically. The no version of this command resets the value to the default.

**Example**

```
[no] tacacs-server management
[no] tacacs-server vrf red
```

**Supported Releases**

10.4.3.0E or later

#### show ldap-server

Displays the details of the configured LDAP servers.

**Syntax**

`show ldap-server`

**Parameters**

None

**Defaults**

None

**Command Mode**

EXEC

**Security and access**

sysadmin and secadmin

**Usage Information**

Use this command to view the configured LDAP servers, authentication methods, and related settings.

**Example**

```
OS10# show ldap-server
-----------------------------------
LDAP Global Configuration
-----------------------------------
basedn : dc=ldapserver3 dc=com
binddn : cn=admin dc=ldapserver3 dc=com
bindpw : Password has been set successfully
--------------------------------------------
HOST         PORT  TLS  SECURITY-PROFILE
--------------------------------------------
10.10.10.10  636   on   newProfile
```

**Supported Releases**

10.6.0.1 or later

#### show running-config ldap-server

Displays current configuration of LDAP servers.

**Syntax**

`show running-config ldap-server`

**Parameters**

None

**Defaults**

None

**Command Mode**

EXEC

**Security and access**

sysadmin and secadmin

**Usage Information**

None

**Example**

```
OS10# show running-configuration ldap-server
ldap-server host 10.10.10.10 tls on security-profile ldapprofile
ldap-server basedn "dc=ldapserver3 dc=com"
ldap-server binddn "cn=admin dc=ldapserver3 dc=com"
ldap-server bindpw 9 b39f6b6cfe05816ba3518cda1b89f0e13127263c6d13b1f37a04085c75440e92
```

**Supported Releases**

10.6.0.1 or later

## Multi-Factor Authentication through RSA SecurID

SmartFabric OS10 allows users to implement Multi-Factor Authentication (MFA) using RSA SecurID. MFA adds an extra layer of security when logging on a Dell PowerSwitch system.

This feature enables the use of RSA SecurID MFA for authenticating user access or roles on an OS10 device. It serves as the second authentication factor, supplementing the first configured authentication factor such as local, LDAP, RADIUS, or TACACS+ methods. MFA offers several benefits, including enhancing account and data security against hackers, reducing the risk associated with poor password practices, and aiding users in maintaining regulatory compliance.

The RSA SecurID authentication mechanism consists of a token (either hardware or software) assigned to a user, which generates an authentication code at fixed intervals and a random key (seed). Each token has a unique seed, which is loaded into the corresponding RSA SecurID server (RSA Authentication Manager) upon token purchase. When this feature is enabled, the user is required to enter both their Personal Identification Number (PIN) and the number that is currently displayed on their RSA SecurID token for authentication.

To enable multi-factor authentication, use the `aaa authentication login mfa rsa-securid [console-exempt]` command. To disable it, use the `no aaa authentication login mfa` command.

> **NOTE:** When MFA is enabled and the RSA SecurID server cannot be reached, the second authentication factor is considered a failure. If console-exempt is not configured, the device becomes inaccessible through all login methods.

### Restrictions and limitations

The following restrictions and limitations apply to this feature:

- The RSA SecurID client can operate exclusively on the default VRF. Therefore, the RSA SecurID server must be located within the default VRF network.
- Only a single RSA server can be configured at any given time.

### Configure MFA through RSA SecurID

To enable MFA through RSA SecurID as a second factor of authentication, in addition to the first authentication factor (which could be local, RADIUS, LDAP, or TACACS+ methods that have been previously configured), the following configuration commands must be run in the exact order provided:

1. Enter the CONFIGURATION mode.

   ```
   OS10# configure terminal
   OS10(config)#
   ```

2. Install the root CA certificate corresponding to the RSA server.

   ```
   OS10(config)# crypto ca-cert install home://cacert.pem
   ```

3. Configure the RSA server details with the previously added root CA certificate of the RSA server.

   ```
   OS10(config)# mfa rsa-server host rsa.dsrl.local client-id os10.dsrl.local client-key 8wx1886173bikmg8911zh8d48qv63bc3444dbbea748axpj1jo9zki8n893mu837 ca-certificate cacert.pem port 6666 connection-timeout 4 read-timeout 4
   ```

4. Enable the MFA service.

   ```
   OS10(config)# aaa authentication login mfa rsa-securid
   ```

Following these steps, upon initiating an SSH connection to this device in a new session, the system prompts for the SecurID passcode authentication once the first authentication factor has been successfully completed.

## MFA through RSA SecurID commands

#### aaa authentication login mfa

Configures the Multi-Factor Authentication (MFA).

**Syntax**

- `aaa authentication login mfa rsa-securid [console-exempt]`
- `no aaa authentication login mfa`

**Parameters**

- `rsa-securid` — Configure the MFA through RSA SecurID method.
- `console-exempt` — Disable MFA method for console access.

**Default**

None

**Command Mode**

CONFIGURATION

**Security and access**

sysadmin

**Usage Information**

The no version of this command disables MFA authentication.

**Example**

```
OS10(config)# aaa authentication login mfa rsa-securid
OS10(config)#no aaa authentication login mfa
```

**Supported Releases**

10.5.6.1 or later

#### debug mfa

Enables printing of debugging messages that are related to the RSA SecurID MFA service.

**Syntax**

`debug mfa`

**Parameters**

None

**Default**

None

**Command Mode**

EXEC

**Security and access**

sysadmin and secadmin

**Usage Information**

After running this command, the last 75 lines of the CIAM logs are displayed in journalctl logs. To see new logs, you must run this command again.

**Example**

```
OS10# debug mfa
```

**Supported Releases**

10.5.6.1 or later

#### mfa rsa-server

Configures the RSA SecurID server.

**Syntax**

- `mfa rsa-server host {hostname | ip-address} client-id client-id client-key {0 key-value | 9 key-value | key-value} ca-certificate certificate-name [port port-number] [connection-timeout connection-timeout-value] [read-timeout read-timeout-value]`
- `no mfa rsa-server host [hostname]`

**Parameters**

- `host {hostname|ip-address` — Enter the keyword host followed by the hostname or IP address of the RSA SecurID server.
- `client-id client-id` — Enter the keyword client-id followed by the unique identifier of the system as a client of the SecurID service, which the SecurID service assigned.
- `client-key {0 key-value | 9 key-value | key-value}` — Enter the keyword client-key followed by the key that is associated with the client ID, which the SecurID service assigned.
  - `0 key-value | key-value` — Enter a client-key in plain text. The maximum length of the key is 64 characters. It is not required to prefix the key with a zero (0).
  - `9 key-value` — Enter a client-key in encrypted format. The maximum length of the key is 192 characters.
- `ca-certificate certificate-name` — Enter the keyword ca-certificate followed by the root CA certificate of the RSA server in .pem format.
- `port port-number` — (Optional) Enter the keyword port followed by the port number of the RSA SecurID server. The supported values are from 1025 to 49151, and the default port number is 5555.
- `connection-timeout connection-timeout` — (Optional) Enter the keyword connection-timeout followed by the timeout in seconds for connection to the RSA SecurID server. The default value is 2 seconds. The supported values are from 2 to 5 seconds.
- `read-timeout read-timeout` — (Optional) Enter the keyword read-timeout followed by the timeout in seconds to read from the RSA SecurID server. The default value is 2 seconds. The supported values are from 2 to 5 seconds.

**Default**

- `port` — 5555
- `connection-timeout` — 2 seconds
- `read-timeout` — 2 seconds

**Command Mode**

CONFIGURATION

**Security and access**

sysadmin

**Usage Information**

Port and timeout parameters are optional with default values. The no version of the command removes the MFA RSA server configuration.

**Example**

```
OS10(config)# mfa rsa-server host rsa.dsrl.local client-id os10.dsrl.local client-key 5wx1886173bikmg5911zh5d28qv63bc3242dbbea728axpj1jo9zki5n593mu537 ca-certificate ca.cert.pem port 6666 connection-timeout 2 read-timeout 2
OS10(config)#no mfa rsa-server host rsa.dsrl.local
```

**Supported Releases**

10.5.6.1 or later

#### show mfa

Displays multi-factor authentication-related information such as MFA service status and selected MFA option.

**Syntax**

`show mfa`

**Parameters**

None

**Default**

None

**Command Mode**

EXEC

**Security and access**

sysadmin and secadmin

**Usage Information**

Use this command to view information about the MFA service.

**Example**

```
OS10# show mfa
MFA Service Status : Running
MFA Authentication : RSA SecurID
```

**Supported Releases**

10.5.6.1 or later

#### show running-configuration aaa

Displays the running configuration of MFA.

**Syntax**

`show running-configuration aaa`

**Parameters**

None

**Default**

Not configured

**Command Mode**

EXEC

**Security and access**

sysadmin and secadmin

**Usage Information**

Use this command to view information about the MFA configuration.

**Example**

```
OS10# show running-configuration aaa
aaa authentication login default local
aaa authentication login console local
aaa authentication login mfa rsa-securid
```

**Supported Releases**

10.5.6.1 or later

#### show running-configuration mfa-rsa-server

Displays the running configuration of the MFA RSA server.

**Syntax**

`show running-configuration mfa-rsa-server`

**Parameters**

None

**Default**

Not configured

**Command Mode**

EXEC

**Security and access**

sysadmin, netadmin, and secadmin

**Usage Information**

Use this command to view the MFA RSA server configuration information.

**Example**

```
OS10# show running-configuration mfa-rsa-server
mfa rsa-server host rsa.dsrl.local client-id os10.dsrl.local client-key 9 **** ca-certificate cacert.pem connection-timeout 5 read-timeout 3
```

**Supported Releases**

10.5.6.1 or later

## Boot security

OS10 protects boot operation by allowing you to add GRUB password and image integrity validation.

### Bootloader protection

To prevent unauthorized users with malicious intent from accessing your switch, protect the bootloader using a GRUB password. OS10 allows you to enable, disable, and view bootloader protection.

This feature is available only for the sysadmin and secadmin roles.

> **NOTE:** When you enable bootloader protection, keep a copy of a configured username and password. You cannot access the switch without configured credentials.

- Enable bootloader protection in EXEC mode. Use the `boot protect enable` command to configure a username and password. You can configure up to three users per switch.

  ```
  OS10# boot protect enable username root password calvin
  ```

  Disable bootloader protection for a specified user by using the `boot protect disable` command.

### Enable bootloader protection

```
OS10# boot protect enable username root password calvin
```

### Disable bootloader protection

```
OS10# boot protect disable username root
```

### Display bootloader protectection

```
OS10# show boot protect
Boot protection enabled
Authorized users: root linuxadmin admin
```

### Secure Boot

OS10 secure boot verifies the authenticity and integrity of the OS10 image. Secure boot protects a system from malicious code being loaded and executed during the boot process.

Using secure boot, you can validate the OS10 image during installation and on demand at any time.

Secure boot:

- verifies the OS10 image with the digital signature before installation
- prevents the OS10 software, including the kernel and system files, from being compromised during the boot operation
- protects and validates the startup configuration file at startup

OS10 checks the validity of the OS10 image before you install or upgrade your system:

- To check the validity of the OS10 image before you upgrade, see Validate and upgrade OS10 image.
- To check the validity of the OS10 image before you install it, see Validate OS10 image before manual installation from ONIE.

If you have already installed Release 10.5.1.0 or later, to enable secure boot, see Enable secure boot.

> **NOTE:** You cannot directly go to ONIE from OS10, when secure boot is enabled. OS10 GRUB menu has options only for OS10 A and B. When you reload from OS10 to ONIE and when secure boot is enabled in OS10, go to BIOS and choose ONIE to boot.

> **NOTE:** Starting from Release 10.6.1.0, secure boot is supported in both Full Switch and SmartFabric modes on all Dell PowerSwitch platforms. Previously, secure boot was supported only in full switch mode. Secure boot commands are not applicable or available for MX-Series platforms.

### Enable secure boot in OS10

Enabling the secure boot feature prevents the OS10 software (kernel and system binaries) from being compromised during the boot operation.

Secure boot is disabled by default. To enable secure boot, use the `secure-boot enable` command or RESTCONF API.

> **NOTE:**
> - On some switches, OS10 secure boot is enabled by default.
> - Secure boot is always enabled on the S3248T-ON platform and cannot be disabled. Therefore, the `secure-boot enable` command to enable or disable it is not supported.

OS10 stores the kernel signatures and system-file hashes internally. When you enable secure boot, OS10 uses the signatures and hashes to validate the binaries during the next and future reboots.

OS10 has two images, A and B. One image is active, which is the current running version and used as the running software at the next system reload. The other image remains standby, used for software upgrades.

> **NOTE:** When you reload the switch from OS10 to ONIE and when secure boot is enabled in OS10, select ONIE from the BIOS to boot. You cannot directly go to ONIE from OS10, when secure boot is enabled.

You can use the `secure-boot verify` command to validate the kernel, system binaries, and startup configuration file for both the installed images at any time.

```
secure-boot verify {kernel | file-system-integrity | startup-config}
```

After a switch reboot:

- If kernel binary file validation fails, OS10 returns to the GRUB menu. The system returns to the GRUB menu when the kernel binary, kernel signature file, or both have been compromised. To load OS10, reboot your system using the other OS10 image. After OS10 loads, reinstall the OS10 image to replace the invalid image.
- If the OS10 system binary file validation fails, the OS10 image loads only in EXEC mode. Configuration mode is blocked. You can reboot your system using the other OS10 image and replace the invalid image with a valid OS10 image.
- If both the installed OS10 images are compromised, you must install a new image using ONIE. For more information, see Dell SmartFabric OS10 Installation, Upgrade, and Downgrade Guide.
- If the validation of the kernel and OS10 system binary files succeeds, OS10 loads successfully.

> **NOTE:** If you are installing an OS10 image using zero touch deployment (ZTD):
> - Secure boot is disabled after ZTD reloads the switch.
> - ZTD cannot validate the image with Dell public key (PKI/sha256/GPG keys) and hence cannot perform secure installation of the OS10 image. However, if a secure boot configuration is present in the ZTD configuration file, it is applied and the following secure boot features are available after installation:
>   - Kernel validation during reboot
>   - OS10 system binary files validation during reboot
>   - Startup configuration file protection
>   - All secure boot CLI commands are available

After the switch reboots, the system applies the protected version of the startup configuration. If a protected version of the startup configuration file is not available, the system applies the default configuration. You can check the status of the secure boot operation using the `show secure-boot status` and `show secure boot file-integrity-status` commands. The show command output displays the combined status of various secure boot features, including:

- Was secure boot used for the last reboot?
- Is secure boot enabled?
- Is the startup configuration protected?
- Were any OS10 binary files added, modified, or deleted?

```
OS10# show secure-boot status
Last boot was via secure boot : yes
Secure boot configured : yes
Latest startup config protected: yes
OS10# show secure-boot file-integrity-status
File Integrity Status: OK
```

### Protect the startup configuration file

Protecting the startup configuration file saves a copy of the current startup configuration file internally. During switch boot up, the protected version of the startup configuration is loaded.

If you make OS10 configuration changes and save them to the startup configuration, protect the current startup configuration file by using the `secure-boot protect startup-config` command. This command is supported in the sysadmin, secadmin, and netadmin roles.

When you enable secure boot and you try to save configuration changes using the `write memory` command, a warning message prompts you to first protect the startup configuration file:

```
Configuration has changed and secure boot is enabled. The protection of the configuration needs to be updated prior to reboot.
```

If you reboot the system using the `reload` command and either the startup configuration is not protected or there are unsaved changes in the protected startup configuration, the warning message is displayed. The system reboot is not performed until you protect the current startup configuration file using the `secure-boot protect startup-config` command.

If you reboot the system using a non-CLI method, such as power cycling, the last protected startup configuration is loaded. Any unsaved changes to the current startup configuration are lost. If the startup configuration is not protected, the default startup configuration settings are loaded.

Use the `secure-boot verify startup configuration` command to check if the current configuration is protected.

```
secure-boot verify startup-config
```

### Validate OS10 image file on demand

You can validate an OS10 image file at any time using the `image verify` command in EXEC mode.

OS10 verifies the signature of the image files using hash-based authentication, GNU privacy guard (GnuPG or GPG)-based signatures, or digital signatures (PKI-signed).

```
image verify image://PKGS_OS10-Enterprise-10.4.9999EX.3342stretch-installer-x86_64.bin pki signature tftp://10.16.127.7/users/PKGS_OS10-Enterprise-10.4.9999EX.3342stretch-installer-x86_64.bin.sha256.base64 public-key tftp://10.16.127.7/users/DellOS10.cert.pem
```

The image package that is verified consists of:

- `PKGS_OS10-Enterprise-10.4.9999EX.3342stretch-installer-x86_64.bin` — OS10 image binary
- `PKGS_OS10-Enterprise-10.4.9999EX.3342stretch-installer-x86_64.bin.sha256.base64` — PKI signature of the OS10 image binary
- `PKGS_OS10-Enterprise-10.4.9999EX.3342stretch-installer-x86_64.bin.sha256` — The sha256 hash of the OS10 image binary
- `PKGS_OS10-Enterprise-10.4.9999EX.3342stretch-installer-x86_64.bin.gpg` — GNU privacy guard (GnuPG or GPG) signature of the OS10 image binary
- `DellOS10.cert.pem` — Dell public key certificate

### Validate the OS10 kernel, system binaries, and startup configuration file

You can validate the OS10 kernel binary image, system binary files, and startup configuration file at system startup and CLI execution using the `secure-boot verify` command in EXEC mode.

```
OS10# secure-boot verify {kernel | file-system-integrity | startup-config}
```

### Enable secure boot in BIOS

See Z9432F-ON, S5448F-ON, Z9664F-ON, and S3248T-ON platform installation guides to enable secure boot in BIOS.

> **NOTE:**
> - When OS10 boot up fails due to BIOS secure boot validation failure, reinstall OS10 from ONIE. See Dell SmartFabric OS10 Installation, Upgrade, and Downgrade Guide for the steps to install.
> - BIOS Secure is supported only on Z9432F-ON, S5448F-ON, Z9664F-ON, and S3248T-ON platforms.
> - On some switches, secure boot is enabled by default in the BIOS.

### ZTD and secure boot

When you enable secure boot in the BIOS, the BIOS validates the NOS boot loader during boot.

The OS10 images (from 10.5.2) that support BIOS secure boot sign the boot loader (OS10 GRUB) with the DELL standard PKI key and the corresponding public key is loaded in the BIOS during manufacturing. When the secure boot is enabled in BIOS, you cannot use ZTD to install any third-party NOS image that does not support the secure boot feature. In such cases, manually disable the feature in the BIOS using the BIOS UI to install third-party NOS images that does not support the secure boot feature.

### Validate and upgrade OS10 image

You can validate and upgrade the OS10 installer image files with digital signatures using the `image secure-install` command in EXEC mode.

```
OS10# image secure-install image-filepath {sha256 signature signature-filepath | gpg signature signature-filepath | pki signature signature-filepath public-key key-file}
```

The OS10 image installer verifies the signature of the image files using hash-based authentication, GNU privacy guard (GnuPG or GPG)-based signatures, or digital signatures (PKI-signed). Upgraded image files are installed after they are successfully validated.

> **NOTE:**
> - When secure boot is enabled and you install an OS10 image upgrade, the `image install` command is disabled. Use the `image secure-install` command instead. For more information, see Dell SmartFabric OS10 Installation, Upgrade, and Downgrade Guide.
> - If secure boot is not enabled, you can validate an OS10 image using PKI after you manually install the image by using the `image verify` command. PKI image validation occurs only once during the installation, not during each reload. After you manually install the image using the `image install` command, the image is extracted. The original binary image is not stored in the system.

### Validate OS10 image before manual installation from ONIE

When you manually install an OS10 image using ONIE, you can validate the image using hash-based authentication (sha256) or digital certificates (PKI-signed).

The signature for the OS10 installer image is provided with the downloaded OS10 .tar file. You can extract the OS10 binary file image from the .tar file and install it from a local server. For more information, see Dell SmartFabric OS10 Installation, Upgrade, and Downgrade Guide.

To validate and install an image using the X.509v3 certificate and OS10 image signature, use the `onie-nos-install` command during a manual installation.

```
$ onie-nos-install image_url pki signature_filepath certificate_filepath
```

Or

```
$ onie-nos-install image_url sha256 signature_filepath
```

The OS10 image installer verifies the signature of the image files using hash-based authentication or digital signatures (PKI-signed). The image files are installed after they are successfully validated.

### View certificate information

Use the `show secure-boot pki-certificates` command in EXEC mode to view the certificate information.

When working with CA certificates, view the certificate information using the `show secure-boot pki-certificates` command in EXEC mode.

```
OS10# show secure-boot pki-certificates
Certificate Key Id   :  123
Version Number       : 3 (0x2)
Serial Number        : 17154672033164819608 (0xee11a353271dfc98)
Signature Algorithm  : sha256WithRSAEncryption
Issuer               : C=IN, ST=Some-State, L=some-city, O=Internet Widgits Pty Ltd
Validity             : Aug  1 11:45:39 2019 GMT - Jul 31 11:45:39 2020 GMT
Certificate Key Id   :  124
Version Number       : 3 (0x2)
Serial Number        : 17154672033164819608 (0xee11a353271dfc98)
Signature Algorithm  : sha256WithRSAEncryption
Issuer               : C=IN, ST=Some-State, L=some-city, O=Internet Widgits Pty Ltd
Validity             : Aug  1 11:45:39 2019 GMT - Jul 31 11:45:39 2020 GMT
```

### Revoke an installed key

If either the public key or private key that is used in CA certificates is compromised, revoke the key by using the `revoke key` command in EXEC mode.

For `key-id`, enter the local file path where the downloaded or locally generated private key is stored.

```
OS10# revoke key key-id
```

The key is moved to the Revoked state.

### Recover from image validation failures

This section explains how to recover from image validation failures and provides the recovery steps for the various failure scenarios.

Secure boot validates both the installed images. If validation fails for one of the images, you can install the other image. If validation fails for both the images, reinstall the OS10 image from ONIE.

### OS10 kernel validation fails for one installed OS10 image

If kernel validation fails, the system enters GRUB mode. To recover from this validation failure:

1. Select the other installed OS10 image from the GRUB menu.
2. Reboot the system using the other installed OS10 image.
3. Replace the invalid OS10 image with a valid image using the `image secure-install` command.

```
OS10# image secure-install image://PKGS_OS10-Enterprise-10.4.9999EX.3342stretch-installer-x86_64.bin pki signature tftp://10.16.127.7/users/PKGS_OS10-Enterprise-10.4.9999EX.3342stretch-installer-x86_64.bin.sha256.base64 public-key tftp://10.16.127.7/users/DellOS10.cert.pem
```

### OS10 kernel validation fails for both installed OS10 images

If kernel validation fails for both installed images, the system enters GRUB mode. Use the `secure-boot verify kernel` command to check the kernel validation status. To recover from this validation failure:

1. Boot into ONIE.
2. Install a valid OS10 image using the `onie-nos-install` command. For more information, see Dell SmartFabric OS10 Installation, Upgrade, and Downgrade Guide.

### OS10 system binary validation fails for one installed OS10 image

If the system binary validation fails for one of the installed images, you can log into OS10 CLI EXEC mode. You cannot access CONFIGURATION mode. The following log message appears when you use the `show logging log-file` command:

```
Dell (OS10) %SECURE_BOOT: OS10 sytem file integrity failed. OS10 image needs to be reinstalled.
```

To recover from this validation failure:

1. Reload the system using the `reload` command.
2. Select the other installed image from the GRUB menu and load that image.
3. Reboot the system using the other installed OS10 image.
4. Replace the invalid OS10 image with a valid image using the `image secure-install` command.

```
OS10# image secure-install image://PKGS_OS10-Enterprise-10.4.9999EX.3342stretch-installer-x86_64.bin pki signature tftp://10.16.127.7/users/PKGS_OS10-Enterprise-10.4.9999EX.3342stretch-installer-x86_64.bin.sha256.base64 public-key tftp://10.16.127.7/users/DellOS10.cert.pem
```

### OS10 system binary validation fails for both installed OS10 images

If the system binary validation fails for one of the installed images, the system allows you to log into OS10 CLI EXEC mode. You cannot access CONFIGURATION mode. The following log message appears when you use the `show logging log-file` command:

```
Dell (OS10) %SECURE_BOOT: OS10 sytem file integrity failed. OS10 image needs to be reinstalled.
```

To recover from this validation failure:

1. Boot into ONIE.
2. Install a valid OS10 image using the `onie-nos-install` command.

## Boot security commands

#### boot protect disable username

Allows you to disable bootloader protection.

**Syntax**

`boot protect disable username username`

**Parameters**

- `username` — Enter the username to disable bootloader protection.

**Default**

Disabled

**Command Mode**

EXEC

**Usage Information**

You can disable bootloader protection for each individual user.

**Example**

```
OS10# boot protect disable username root
```

**Supported Releases**

10.4.3.0 or later

#### boot protect enable username password

Allows you to enable bootloader protection.

**Syntax**

`boot protect enable username username password password`

**Parameters**

- `username` — Enter the username to provide access to bootloader protection.
- `password` — Enter a password for the specified username.

**Default**

Disabled

**Command Mode**

EXEC

**Usage Information**

You can enable bootloader protection by running this command. You can configure a maximum of three username and password pairs for bootloader protection.

**Example**

```
OS10# boot protect enable username root password calvin
```

**Supported Releases**

10.4.3.0 or later

#### image gpg-key key-server

Installs the GPG key into the switch GPG key ring.

**Syntax**

`image gpg-key key-server key-server-name key-id key-id-string`

**Parameters**

- `key-server-name` — Hostname address of the GPG key server.
- `key-id-string` — Key ID of the GPG key to be installed.

**Default**

None

**Security and Access**

sysadmin

**Command Mode**

EXEC

**Usage Information**

This command uses the key-server name and key-id to install the key into the switch GPG key ring. Use this command before you use the `image verify` or `image secure-install` commands with the GPG option. If the key is not installed in the key ring, the `image verify` and `image secure-install` commands fail when used with the GPG key.

**Example**

```
OS10# image gpg-key key-server keyserver.ubuntu.com key-id 7FDA043B
```

**Supported Releases**

10.5.1.0 or later

#### image secure-install

Validates and installs the specified image.

**Syntax**

`image secure-install image-filepath {sha256 signature signature-filepath | gpg signature signature-filepath | pki signature signature-filepath public-key key-file} [downgrade-config-file downgrade-config-file-name]`

**Parameters**

- `image-filepath` — Enter the absolute path name of the OS10 image file.
- `sha256 signature signature-filepath` — Verify the SHA-256 cryptographic hash signature of the image file.
- `gpg signature signature-filepath` — Verify the GNU privacy guard signature of the image file.
- `pki signature signature-filepath public-key key-file` — Verify the PKI-signed digital signature of the image file.
- `downgrade-config-file downgrade-config-file-name` — (Optional) Enter the name of the saved configuration file from the home directory in the `home://<filename>.xml` format. The specified configuration file gets applied while booting the downgrade image. This parameter is available from Release 10.5.5.5, and it is applicable for software downgrade only. You can use this parameter when downgrading to Release 10.5.5.5 or later from two previous major releases. For example, if the running version is 10.5.8.x, this parameter is supported until Release 10.5.6.x.

  > **NOTE:** If the configuration file that is provided with the `downgrade-config-file` option contains unsupported CLI commands or invalid configurations, the system displays the following error message:
  >
  > ```
  > The given downgrade-config file is invalid during downgrade.
  > Rebooting once again to load the default configs.
  > ```
  >
  > Then, the system automatically reboots and loads the default configuration settings.

**Default**

None

**Security and Access**

sysadmin

**Command Mode**

EXEC

**Usage Information**

This command is available only when you enable secure boot. This command is similar to the `image install` command. The system, before installing the image, verifies the signature of the OS10 image file using hash-based authentication, GNU privacy guard (GnuPG or GPG)-based signatures, or digital signatures (PKI-signed). For GPG validation, before you validate the OS10 image, use the `image gpg-key` command to install the GPG key in the switch keyring. When running this command with the `downgrade-config-file` parameter, the firmware file name must be in the standard release convention (`PKGS_OS10-Enterprise-x.x.x.xbuster-installer-x86_64.bin` or `Network_Firmware_xxxxx.exe`). Renamed firmware file names are not supported.

**Example - sha256**

```
OS10# image secure-install image://PKGS_OS10-Enterprise-10.4.9999EX.3342stretch-installer-x86_64.bin sha256 signature tftp://10.16.127.7/users/PKGS_OS10-Enterprise-10.4.9999EX.3342stretch-installer-x86_64.bin.sha256
```

**Example - GPG key**

```
OS10# image secure-install image://PKGS_OS10-Enterprise-10.4.9999EX.3342stretch-installer-x86_64.bin gpg signature tftp://10.16.127.7/users/PKGS_OS10-Enterprise-10.4.9999EX.3342stretch-installer-x86_64.bin.gpg
```

**Example - PKI signature**

```
OS10# image secure-install image://PKGS_OS10-Enterprise-10.4.9999EX.3342stretch-installer-x86_64.bin pki signature tftp://10.16.127.7/users/PKGS_OS10-Enterprise-10.4.9999EX.3342stretch-installer-x86_64.bin.sha256.base64 public-key tftp://10.16.127.7/users/DellOS10.cert.pem
```

**Example - Restore saved downgrade configuration**

```
OS10# image secure-install image://PKGS_OS10-Enterprise-10.5.5.5.220buster-installer-x86_64.bin sha256 signature tftp://10.10.10.7/users/PKGS_OS10-Enterprise-10.5.5.5.220buster-installer-x86_64.bin.sha256 downgrade-config-file home://config_5.5.xml
```

**Supported Releases**

10.5.1.0 or later

#### image verify

Verifies the OS10 image file using sha256, PKI, or GPG signatures.

**Syntax**

`image verify image-filepath {sha256 signature signature-filepath | gpg signature signature-filepath | pki signature signature-filepath public-key key-file}`

**Parameters**

- `image-filepath` — Enter the absolute path name of the OS10 image file.
- `sha256 signature signature-filepath` — Verify the SHA-256 cryptographic hash signature of the image file.
- `gpg signature signature-filepath` — Verify the GNU privacy guard signature of the image file.
- `pki signature signature-filepath public-key key-file` — Verify the PKI-signed digital signature of the image file.

**Default**

None

**Security and Access**

Sysadmin

**Command Mode**

EXEC

**Usage Information**

This command verifies the signature of the OS10 image file using hash-based authentication, GNU privacy guard (GnuPG or GPG)-based signatures, or digital signatures (PKI-signed). For GPG validation, before you validate the OS10 image, use the `image gpg-key` command to install the GPG key in the switch keyring.

**Example-sha256**

```
OS10# image verify image://PKGS_OS10-Enterprise-10.4.9999EX.3342stretch-installer-x86_64.bin pki signature tftp://10.16.127.7/users/PKGS_OS10-Enterprise-10.4.9999EX.3342stretch-installer-x86_64.bin.sha256.base64 public-key tftp://10.16.127.7/users/DellOS10.cert.pem
Image verified successfully.
```

**Example-GPG key**

```
OS10# image verify image://PKGS_OS10-Enterprise-10.4.9999EX.3342stretch-installer-x86_64.bin gpg signature tftp://10.16.127.7/users/PKGS_OS10-Enterprise-10.4.9999EX.3342stretch-installer-x86_64.bin.gpg
```

**Example-PKI**

```
OS10# image verify image://PKGS_OS10-Enterprise-10.4.9999EX.3342stretch-installer-x86_64.bin pki signature tftp://10.16.127.7/users/PKGS_OS10-Enterprise-10.4.9999EX.3342stretch-installer-x86_64.bin.sha256.base64 public-key tftp://10.16.127.7/users/DellOS10.cert.pem
Image verified successfully.
```

**Supported Releases**

10.5.1.0 or later

#### secure-boot enable

Enables secure boot.

**Syntax**

`secure-boot enable`

**Parameters**

None

**Default**

Disabled

**Security and Access**

sysadmin

**Command Mode**

CONFIGURATION

**Usage Information**

If you enable secure boot, ensure that you manually protect the startup configuration file before you reload the switch. The protected version of the startup configuration file is applied during the boot up process. If a protected version of the startup configuration file is not available, the system applies the default configuration. The no version of this command removes the configuration.

> **NOTE:** Secure boot is always enabled on the S3248T-ON platform and cannot be disabled. Therefore, this command is not supported on the S3248T-ON platform.

**Example**

```
OS10# secure-boot enable
```

**Supported Releases**

10.5.1.0 or later

#### secure-boot grub-key

Allows you to switch between standard and autogenerated key options.

**Syntax**

`secure-boot grub-key{standard | auto-generated}`

**Parameters**

- `standard` — Dell Technologies recommends that GPG key is used by GRUB to validate the OS10 kernel. The kernel is signed with the key during build time.
- `auto-generated` — The GPG keys are generated internally during OS10 installation and this key is used by the GRUB to validate the OS10 kernel. The kernel is signed with the key during image installation.

**Default**

None

**Security and Access**

Sysadmin and secadmin

**Command Mode**

EXEC

**Usage Information**

None

**Example**

```
DELL# secure-boot grub-key auto-generated
DELL# secure-boot grub-key standard
```

**Supported Releases**

10.5.2.0 or later

#### secure-boot protect startup-config

Protects the startup configuration file and its hash value.

**Syntax**

`secure-boot protect startup-config`

**Parameters**

None

**Default**

None

**Security and Access**

sysadmin, secadmin, netadmin

**Command Mode**

EXEC

**Usage Information**

This CLI is available only when you enable secure boot. If the startup configuration file is deleted or compromised, use the protected version of the startup configuration file to restore the configuration during a reboot.

**Example**

```
OS10# secure-boot protect startup-config
```

**Supported Releases**

10.5.1.0 or later

#### secure-boot revoke key

Revokes an installed key.

**Syntax**

`secure-boot revoke key key-id`

**Parameters**

`key-id` — key number of the installed key that is compromised.

**Default**

None

**Security and Access**

Sysadmin

**Command Mode**

EXEC

**Usage Information**

Use this command to revoke an installed key that is compromised.

**Example**

```
OS10# secure-boot revoke key 5
```

**Supported Releases**

10.5.1.0 or later

#### secure-boot verify

Validates the kernel, system, and startup configuration binary files of both the OS10 installed images.

**Syntax**

`secure-boot verify {kernel | file-system-integrity | startup-config}`

**Parameters**

- `kernel` — Validate the kernel image.
- `file-system-integrity` — Validate the OS10 system binaries.
- `startup-config` — Validate the startup configuration file.

**Default**

None

**Security and Access**

Sysadmin

**Command Mode**

EXEC

**Usage Information**

None

**Example 1 - Kernel verification**

```
OS10# secure-boot verify kernel
Active Partition
Kernel signature verified:success
Standby Partition
Kernel signature verified:success
```

**Example 2 - File system verification**

```
OS10# secure-boot verify file-system-integrity
Active Partition
File-system integrity verified:success
Standby Partition
File-system integrity verified:success
```

**Example 3 - Startup configuration verification**

```
OS10# secure-boot verify startup-config
Latest startup config protected: yes
```

**Supported Releases**

10.5.1.0 or later

#### show boot protect

Displays the current list of configured users that have access to bootloader protection.

**Syntax**

`show boot protect`

**Parameters**

None

**Default**

Not configured

**Command Mode**

EXEC

**Usage Information**

Displays the current list of authorised users for bootloader protection, but hides their passwords for security reasons.

**Example (Disabled)**

```
OS10# show boot protect
Boot protection disabled
```

**Example (Enabled)**

```
OS10# show boot protect
Boot protection enabled
Authorized users: root linuxadmin admin
```

**Supported Releases**

10.4.3.0 or later

#### show secure-boot

Displays the secure boot or file integrity status.

**Syntax**

`show secure-boot {status | file-integrity-status}`

**Parameters**

- `status` — Displays secure boot status.
- `file-integrity-status` — (Applicable only when you enable the secure boot feature) Displays file integrity status.

**Default**

None

**Security and Access**

Sysadmin and secadmin

**Command Mode**

EXEC

**Usage Information**

None

**Example 1**

```
OS10# show secure-boot status
Last boot was via secure boot : yes
Secure boot configured : yes
Latest startup config protected: yes
BIOS secure boot:
BIOS Secure boot configured: yes
```

**Example 2**

```
OS10# show secure-boot file-integrity-status
File Integrity Status: OK
```

**Example 3**

```
OS10# show secure-boot file-integrity-status
File Integrity Status: Failed
Potential Security Issues:
Files modified:
/opt/dell/os10/bin/dn_l3_core_services
Files added:
/opt/dell/os10/bin/trojan1
/opt/dell/os10/bin/virus123
```

**Supported Releases**

10.5.1.0 or later

#### show secure-boot pki-certificates

Displays PKI certificates that are installed in the system.

**Syntax**

`show secure-boot pki-certificates`

**Parameters**

None

**Default**

None

**Security and Access**

Sysadmin and secadmin

**Command Mode**

EXEC

**Usage Information**

None

**Example**

```
OS10# show secure-boot pki-certificates
Certificate Key Id   :  123
Version Number       : 3 (0x2)
Serial Number        : 17154672033164819608 (0xee11a353271dfc98)
Signature Algorithm  : sha256WithRSAEncryption
Issuer               : C=IN, ST=Some-State, L=some-city, O=Internet Widgits Pty Ltd
Validity             : Aug  1 11:45:39 2019 GMT - Jul 31 11:45:39 2020 GMT
Certificate Key Id   :  124
Version Number       : 3 (0x2)
Serial Number        : 17154672033164819608 (0xee11a353271dfc98)
Signature Algorithm  : sha256WithRSAEncryption
Issuer               : C=IN, ST=Some-State, L=some-city, O=Internet Widgits Pty Ltd
Validity             : Aug  1 11:45:39 2019 GMT - Jul 31 11:45:39 2020 GMT
```

**Supported Releases**

10.5.1.0 or later

## Switch management access

OS10 provides security to all management access through console, Telnet, SSH connections, and SNMP requests.

### SSH server

In OS10, the secure shell server allows an SSH client to access an OS10 switch through a secure, encrypted connection. The SSH server authenticates remote clients using RADIUS challenge/response, a trusted host file, locally stored passwords, and public keys.

> **NOTE:** Only the SSH v2 protocol is supported; SSH v1 is not supported.

### Configure SSH server

- The SSH server is enabled by default. You can disable the SSH server using the `no ip ssh server enable` command.
- Challenge response authentication is disabled by default. To enable, use the `ip ssh server challenge-response-authentication` command.
- Host-based authentication is disabled by default. To enable, use the `ip ssh server hostbased-authentication` command.
- Password authentication is enabled by default. To disable, use the `no ip ssh server password-authentication` command.
- Public key authentication is enabled by default. To disable, use the `no ip ssh server pubkey-authentication` command.
- Password-less login is disabled by default. To enable, use the `username sshkey` or `username sshkey filename` commands.
- Configure the list of cipher algorithms using the `ip ssh server cipher cipher-list` command.
- Configure key exchange algorithms using the `ip ssh server kex key-exchange-algorithm` command.
- Configure hash message authentication code (HMAC) algorithms using the `ip ssh server mac hmac-algorithm` command.
- Configure the SSH server listening port using the `ip ssh server port port-number` command.
- Configure the SSH server to be reachable on the management VRF using the `ip ssh server vrf` command.
- Configure the SSH login timeout using the `ip ssh server login-grace-time seconds` command, from 0 to 300; default 60. To reset the default SSH prompt timer, use the `no ip ssh server login-grace-time` command.
- Configure the maximum number of authentication attempts using the `ip ssh server max-auth-tries number` command, from 0 to 10; default 6. To reset the default, use the `no ip ssh server max-auth-tries` command. The max-auth-tries value includes all authentication attempts, including public-key and password. If you enable both public-key based authentication and password authentication, the public-key authentication is the default and is tried first. If it fails, the number of max-auth-tries is reduced by one. In this case, if you configured `ip ssh server max-auth-tries 1`, the password prompt does not display.

### Regenerate public keys

When enabled, the SSH server generates public keys by default and uses them for client authentication:

- A Rivest, Shamir, and Adelman (RSA) key using 3072 bits.
- An Elliptic Curve Digital Signature Algorithm (ECDSA) key using 256 bits
- An Ed25519 key using 256 bits

> **NOTE:** RSA1 and DSA keys are not supported on the OS10 SSH server.

An SSH client must exchange the same public key to establish a secure SSH connection to the OS10 switch. If necessary, you can regenerate the keys that are used by the SSH server with a customized bit size. You cannot change the default size of the Ed25519 key. The `crypto key generate` command is available only to the sysadmin and secadmin roles.

1. Regenerate keys for the SSH server in EXEC mode.

   ```
   crypto ssh-key generate {rsa {2048|3072|4096} | ecdsa {256|384|521} | ed25519}
   ```

2. Enter `yes` at the prompt to overwrite an existing key.

   ```
   Host key already exists. Overwrite [confirm yes/no]:yes
   Generated 2048-bit RSA key
   ```

3. Display the SSH public keys in EXEC mode.

   ```
   show crypto ssh-key
   ```

After you regenerate SSH public keys, disable and re-enable the SSH server to use the new public keys. Restarting the SSH server does not impact current OS10 sessions.

### Configure Host-Based SSH Authentication

Authenticate a particular host. This method uses SSH version 2.

This example explains how to configure host-based SSH authentication without using password.

#### Configuration on the Linux client

1. Install OpenSSH server on the Linux client. The following command is on Ubuntu; the command changes depending on the Linux platform.

   ```
   apt-get install openssh-server
   ```

2. Create users (for example, test2, test3) using the following command with required default options:

   ```
   root@linux_client:/home# adduser test2
   root@linux_client:/home# adduser test3
   ```

3. Populate the Linux client with the public keys of the server.

   ```
   root@linux_client:/etc/ssh# ssh-keyscan 100.10.10.10 | tee -a /etc/ssh/ssh_known_hosts
   100.10.10.10 ecdsa-sha2-nistp256 AAAAE2VjZHNhLXNoYYAAAAIbmlzdHAyNTYAAABBBJXPCX4Sr/TM+D+lRn7GRmn9lSIPnx/aJTOd9v7LZ9OeoyAs8agQedTmJiHVsuQqKVRWSj0jk4b+A0s0=
   100.10.10.10 ssh-rsa AAAAB3NzaC1yc2EAAAA7GzWn0DyavqrxtnRhuvaOrhKBW/r+X+g7hbx36VqrLIesvuaXBm69gU526HcPKmPMeBV8yZqviPoHMAodZE23m3EZe+Sx2l5PSphpIt4V5kfV6PjXYkxP/9T78iyTLdI4/VZR/z2uEK5m61q8tlMAfP2qMlDCQL3rQf+aYaZmorr8BsK2dJ8RmiDC1o0xvk4PyT0lcQtu0K3H5y93ddZgOVTxnerpVD6QmBSXJ/VztW3FYWGITUbQ6K1iUTg3G71/pPNE+Td+n4i+6rkSZOcKn+LCPDPiR+gkxF9uF1Jh/Npx1jh9fdEZzrvD4UL9Qd0o5o8SM9hc8wivbHuB/xtpBX5Nj3DHN0K3u7dXGHy4KX+Z3CaKFP+PkxImcEEWEhQbNsWgptj1gODGj0BOOnNQ03iD+Uts/FyS+oLOjYzpP1PH4fTRbmjATCS0YY3jCuqFqqb+CFpRl14ZiPSMKdEdbK+bHE7IHkH7Kl2dBv0coaM5hUaW8=
   100.10.10.10 ssh-ed25519 AAAAC3NzaC1lZDI1fUYVViGl4bjwf3qUqBqj/+QDJZsjicC3jr75ymvuo
   ```

4. Perform the following system-wide client configuration: Add below configurations in `/etc/ssh/ssh_config`.

   ```
   HostbasedAuthentication yes
   EnableSSHKeysign yes
   ```

#### Configuration on the OS10 switch

1. Perform the following steps on the OS10 switch.

   a. Enter configuration mode.

   ```
   OS10# configure terminal
   ```

   b. Configure a username on the switch.

   ```
   OS10(config)# username test2 password testpassword2 role sysadmin priv-lvl 15
   OS10(config)# username test3 password testpassword3 role sysadmin priv-lvl 15
   ```

   c. Enable host-based authentication on the switch.

   ```
   OS10(config)# ip ssh server hostbased-authentication
   ```

   d. If you do not want to perform password authentication, run the following command.

   ```
   OS10(config)# no ip ssh server password-authentication
   ```

2. Register the allowed client systems with the server.

   ```
   root@OS10:/etc/ssh# vi shosts.equiv
   100.10.10.13
   root@OS10:/etc/ssh# cat shosts.equiv
   100.10.10.13
   ```

3. Populate the server with the public keys of the client.

   ```
   ssh-keyscan 100.10.10.13 | tee -a /etc/ssh/ssh_known_hosts
   ```

4. The users test2 and test3 must be able to log in without password. Log in to the Linux client with the credentials of the test2 user, which was created in the OS10 device.

   ```
   bash-3.2$ ssh test2@100.10.10.13
   ```

   Now, log in to OS10 device with the management IP address.

   ```
   test2@linux_client:~$ ssh 100.10.10.10
   ```

When you replace the switch, you need to perform this procedure again.

### RESTCONF API

RESTCONF API allows to configure and monitor an OS10 switch using HTTP with the Transport Layer Security (TLS) protocol. For more information about RESTCONF API, see RESTCONF API.

### Restrict SNMP access

To filter SNMP requests on the switch, assign access lists to an SNMP community. Both IPv4 and IPv6 access lists are supported.

These points are applicable when you assign an ACL to an SNMP community:

- By default, SNMP requests from all hosts are allowed.
- You can only apply permit ACL rules to an SNMP community. deny ACL rules do not take effect if you apply them.
- To permit SNMP requests for multiple hosts, apply individual permit ACL rules for hosts or prefixes.
- Applying ACL rules for an SNMP community in a nondefault VRF is not supported.

> **NOTE:** OS10 supports SNMP ACL filter configuration using source IP addresses. However, it does not support filtering based on other fields such as destination addresses, IP type, IP protocol, and port numbers of packets.

1. Create access lists with permit filters; for example:

   ```
   OS10(config)# ip access-list snmp-read-only-acl
   OS10(config-ipv4-acl)# permit ip 172.16.0.0 255.255.0.0 any
   OS10(config-ipv4-acl)# exit
   OS10(config)#
   ```

2. Apply ACLs to an SNMP community in CONFIGURATION mode.

   ```
   OS10(config)# snmp-server community public ro acl snmp-read-only-acl
   ```

### View SNMP ACL configuration

```
OS10# show snmp community
Community : public
Access : read-only
ACL : snmp-read-only-acl
```

### Limit concurrent login sessions

To avoid an unlimited number of active sessions on a switch for the same user ID, limit the number of console and remote connections. Log in from a console connection by cabling a terminal emulator to the console serial port on the switch. Log in to the switch remotely through a virtual terminal line, such as Telnet and SSH.

- Configure the maximum number of concurrent login sessions in CONFIGURATION mode.

  ```
  OS10(config)# login concurrent-session limit number
  ```

  - `limit number` — Sets the maximum number of concurrent login sessions allowed for a user ID, from 1 to 12; default 10.

When you configure the maximum number of allowed concurrent login sessions, take into account that:

- Each remote VTY connection counts as one login session.
- All login sessions from a terminal emulator on an attached console count as one session.

### Configure concurrent login sessions

```
OS10(config)# login concurrent-session limit 4
```

If you log in to the switch after the maximum number of concurrent sessions are active, an error message displays. To log in to the system, close one of your existing sessions.

```
OS10(config)# login concurrent-session limit 4
Too many logins for 'admin'.
Last login: Wed Jan 31 20:37:34 2018 from 10.14.1.213
Connection to 10.11.178.26 closed.
Current sessions for user admin:
Line              Location
2  vty 0          10.14.1.97
3  vty 1          10.14.1.97
4  vty 2          10.14.1.97
5  vty 3          10.14.1.97
```

### Virtual terminal line ACLs

To limit Telnet and SSH connections to the switch, apply access lists on a virtual terminal line (VTY).

There is no implicit deny rule. If none of the configured conditions match, the default behavior is to permit. If you need to deny traffic that does not match any of the configured conditions, explicitly configure a deny statement.

> **NOTE:** VTY ACLs are used only to block the source IP hosts which connect through SSH or telnet to the device management IP. You cannot use these ACLs with any other qualifiers such as UDP or TCP port, destination IP, ICMP, and so on.

1. Create IPv4 or IPv6 access lists with permit or deny filters; for example:

   ```
   OS10(config)# ip access-list permit10
   OS10(config-ipv4-acl)# permit ip 172.16.0.0 255.255.0.0 any
   OS10(config-ipv4-acl)# exit
   OS10(config)#
   ```

2. Enter VTY mode using the `line vty` command in CONFIGURATION mode.

   ```
   OS10(config)# line vty
   OS10(config-line-vty)#
   ```

3. Apply the access lists to the VTY line with the `{ip | ipv6} access-class access-list-name` command in LINE-VTY mode.

   ```
   OS10(config-line-vty)# ip access-class permit10
   ```

### View VTY ACL configuration

```
OS10(config-line-vty)# show configuration
!
line vty
 ip access-class permit10
 ipv6 access-class deny10
OS10(config-line-vty)#
```

### Initiate an SSH session with another switch

To initiate an SSH session to another switch:

1. Enter configuration mode.

   ```
   OS10# configure terminal
   ```

2. Enable SSH client cli command.

   ```
   OS10(config)#ip ssh client cli enable
   ```

   By default, the SSH Client CLI command is disabled. The user cannot access the ssh command. This command must be run to enable the SSH CLI. You must run the `no ip ssh client enable` command to disable the SSH command.

3. Initiate an SSH session.

   ```
   OS10# ssh 9.1.1.2
   ```

   Connect remote switch whose IP address is as specified with port-id 22 (default port-id) and current session username (default username).

## Switch management access commands

#### ip ssh client cli enable

Enables or disables the SSH command.

**Syntax**

`ip ssh client cli enable`

**Parameters**

None.

**Default**

Not configured

**Command Mode**

CONFIGURATION

**Usage Information**

The SSH command is disabled by default, and it has to be explicitly enabled.

> **NOTE:** Only the system administrator (sysadmin) and secadmin roles are allowed to manage this configuration.

**Example**

```
OS10-Switch(config)# ip ssh client cli enable
```

**Supported Releases**

10.5.2.1 or later

#### ip ssh server enable

Enables the SSH server.

**Syntax**

`ip ssh server enable`

**Parameters**

None

**Default**

Enabled

**Command Mode**

CONFIGURATION

**Usage Information**

The no version of this command disables the SSH server.

**Example**

```
OS10(config)# ip ssh server enable
```

**Supported Releases**

10.3.0E or later

#### ip ssh server challenge-response-authentication

Enables challenge response authentication in the SSH server.

**Syntax**

`ip ssh server challenge-response-authentication`

**Parameters**

None

**Default**

Disabled

**Command Mode**

CONFIGURATION

**Usage Information**

The no version of this command disables the challenge response authentication.

**Example**

```
OS10(config)# ip ssh server challenge-response-authentication
```

**Supported Releases**

10.3.0E or later

#### ip ssh server cipher

Configures the list of cipher algorithms in the SSH server.

**Syntax**

`ip ssh server cipher cipher-list`

**Parameters**

`cipher-list` — Enter a list of cipher algorithms. Separate entries with a blank space. SSH server supports the following cipher algorithms:

**Table 104. Cipher algorithms**

| Release 10.5.6.3 and earlier | Release 10.5.6.4 and later |
|------------------------------|----------------------------|
| 3des-cbc | aes128-ctr |
| aes128-cbc | aes192-ctr |
| aes192-cbc | aes256-ctr |
| aes256-cbc | aes128-gcm@openssh.com |
| aes128-ctr | aes256-gcm@openssh.com |
| aes192-ctr | chacha20-poly1305@openssh.com |
| aes256-ctr | |
| aes128-gcm@openssh.com | |
| aes256-gcm@openssh.com | |
| blowfish-cbc | |
| cast128-cbc | |
| chacha20-poly1305@opens | |

**Default**

**Table 105. Default cipher algorithms**

| Release 10.5.6.3 and earlier | Release 10.5.6.4 and later |
|------------------------------|----------------------------|
| aes128-ctr | aes256-ctr |
| aes192-ctr | aes256-gcm@openssh.com |
| aes256-ctr | |
| aes128-gcm@openssh.com | |
| aes256-gcm@openssh.com | |
| chacha20-poly1305@opens | |

**Command Mode**

CONFIGURATION

**Usage Information**

When configuring `aes128-gcm@openssh.com` or `aes256-gcm@openssh.com` in the cipher list, you must configure any of the following cipher algorithms in addition to the AES-GCM cipher for SSH to work correctly (for example: `ip ssh server cipher aes128-gcm@openssh.com`):

- aes128-ctr
- aes192-ctr
- aes256-ctr

The no version of this command removes the configuration.

> **NOTE:** Starting from Release 10.6.0.5, in FIPS mode, if you attempt to configure any disallowed ciphers, MACs, or key exchange (KEX) algorithms, the corresponding `ip ssh server cipher`, `ip ssh server mac`, or `ip ssh server kex` command returns an error. Only FIPS-compliant algorithms are permitted in this mode.

**Example**

```
OS10(config)# ip ssh server aes128-ctr aes128-gcm@openssh.com
```

**Supported Releases**

10.3.0E or later

#### ip ssh server hostbased-authentication

Enables host-based authentication in an SSH server.

**Syntax**

`ip ssh server hostbased-authentication`

**Parameters**

None

**Default**

Disabled

**Command Mode**

CONFIGURATION

**Usage Information**

The no version of this command disables the host-based authentication.

**Example**

```
OS10(config)# ip ssh server hostbased-authentication
```

**Supported Releases**

10.3.0E or later

#### ip ssh server kex

Configures the key exchange algorithms that are used in the SSH server.

**Syntax**

`ip ssh server kex key-exchange-algorithm`

**Parameters**

`key-exchange-algorithm` — Enter the supported key exchange algorithms separated by a blank space. The SSH server supports these key exchange algorithms:

**Table 106. Key exchange algorithms**

| Release 10.5.6.3 and earlier | Release 10.5.6.4 and later | Release 10.6.0.1 and later |
|------------------------------|----------------------------|----------------------------|
| curve25519-sha256 | curve25519-sha256 | curve25519-sha256 |
| curve25519-sha256@libssh.org | curve25519-sha256@libssh.org | curve25519-sha256@libssh.org |
| diffie-hellman-group1-sha1 | ecdh-sha2-nistp256 | ecdh-sha2-nistp256 |
| diffie-hellman-group14-sha1 | ecdh-sha2-nistp384 | ecdh-sha2-nistp384 |
| diffie-hellman-group16-sha512 | ecdh-sha2-nistp521 | ecdh-sha2-nistp521 |
| diffie-hellman-group-exchange-sha1 | diffie-hellman-group-exchange-sha256 | |
| diffie-hellman-group-exchange-sha256 | diffie-hellman-group14-sha256 | |
| ecdh-sha2-nistp256 | diffie-hellman-group16-sha512 | |
| ecdh-sha2-nistp384 | diffie-hellman-group18-sha512 | |
| ecdh-sha2-nistp521 | | |

**Default**

**Table 107. Default key exchange algorithms**

| Release 10.5.6.3 and earlier | Release 10.5.6.4 and later |
|------------------------------|----------------------------|
| curve25519-sha256 | curve25519-sha256 |
| diffie-hellman-group14-sha1 | curve25519-sha256@libssh.org |
| diffie-hellman-group-exchange-sha256 | ecdh-sha2-nistp384 |
| ecdh-sha2-nistp256 | |
| ecdh-sha2-nistp384 | |
| ecdh-sha2-nistp521 | |

**Command Mode**

CONFIGURATION

**Usage Information**

The no version of this command removes the configuration.

> **NOTE:** Starting from Release 10.6.0.5, in FIPS mode, if you attempt to configure any disallowed ciphers, MACs, or key exchange (KEX) algorithms, the corresponding `ip ssh server cipher`, `ip ssh server mac`, or `ip ssh server kex` command returns an error. Only FIPS-compliant algorithms are permitted in this mode.

**Example**

```
OS10(config)# ip ssh server kex curve25519-sha256 ecdh-sha2-nistp256
```

**Supported Releases**

10.3.0E or later

#### ip ssh server mac

Configures the hash message authentication code (HMAC) algorithms that are used in the SSH server.

**Syntax**

`ip ssh server mac hmac-algorithm`

**Parameters**

`hmac-algorithm` — Enter the supported HMAC algorithms separated by a blank space. The SSH server supports these HMAC algorithms:

**Table 108. HMAC algorithms**

| Release 10.5.6.3 and earlier | Release 10.5.6.4 and later | Release 10.6.0.5 and later |
|------------------------------|----------------------------|----------------------------|
| hmac-md5 | hmac-sha2-256 | hmac-sha2-256 |
| hmac-md5-96 | hmac-sha2-512 | hmac-sha2-512 |
| hmac-ripemd160 | umac-128@openssh.com | umac-128@openssh.com |
| hmac-sha1 | hmac-sha1-etm@openssh.com | hmac-sha2-256-etm@openssh.com |
| hmac-sha1-96 | hmac-sha2-256-etm@openssh.com | hmac-sha2-512-etm@openssh.com |
| hmac-sha2-256 | hmac-sha2-512-etm@openssh.com | umac-128-etm@openssh.com |
| hmac-sha2-512 | umac-128-etm@openssh.com | |
| umac-64@openssh.com | | |
| umac-128@openssh.com | | |
| hmac-md5-etm@openssh.com | | |
| hmac-md5-96-etm@openssh.com | | |
| hmac-ripemd160-etm@openssh.com | | |
| hmac-sha1-etm@openssh.com | | |
| hmac-sha1-96-etm@openssh.com | | |
| hmac-sha2-256-etm@openssh.com | | |
| hmac-sha2-512-etm@openssh.com | | |
| umac-64-etm@openssh.com | | |
| umac-128-etm@openssh.com | | |

**Default**

**Table 109. Default HMAC algorithms**

| Release 10.5.6.3 and earlier | Release 10.5.6.4 and later |
|------------------------------|----------------------------|
| hmac-sha1 | hmac-sha2-256 |
| hmac-sha2-256 | hmac-sha2-512 |
| hmac-sha2-512 | |
| umac-64@openssh.com | |
| umac-128@openssh.com | |
| hmac-sha1-etm@openssh.com | |
| hmac-sha2-256-etm@openssh.com | |
| hmac-sha2-512-etm@openssh.com | |
| umac-64-etm@openssh.com | |
| umac-128-etm@openssh.com | |

**Command Mode**

CONFIGURATION

**Usage Information**

The no version of this command removes the configuration.

> **NOTE:** Starting from Release 10.6.0.5, in FIPS mode, if you attempt to configure any disallowed ciphers, MACs, or key exchange (KEX) algorithms, the corresponding `ip ssh server cipher`, `ip ssh server mac`, or `ip ssh server kex` command returns an error. Only FIPS-compliant algorithms are permitted in this mode.

**Example**

```
OS10(config)# ip ssh server mac hmac-sha2-256 hmac-sha2-256-etm@openssh.com
```

**Supported Releases**

10.3.0E or later

#### ip ssh server password-authentication

Enables password authentication in the SSH server.

**Syntax**

`ip ssh server password-authentication`

**Parameters**

None

**Default**

Enabled

**Command Mode**

CONFIGURATION

**Usage Information**

The no version of this command disables the password authentication.

**Example**

```
OS10(config)# ip ssh server password-authentication
```

**Supported Releases**

10.3.0E or later

#### ip ssh server port

Configures the SSH server listening port.

**Syntax**

`ip ssh server port port-number`

**Parameters**

`port-number` — Enter the listening port number, from 1 to 65535.

**Default**

22

**Command Mode**

CONFIGURATION

**Usage Information**

The no version of this command removes the configuration.

**Example**

```
OS10(config)# ip ssh server port 255
```

**Supported Releases**

10.3.0E or later

#### ip ssh server pubkey-authentication

Enables public key authentication for the SSH server.

**Syntax**

`ip ssh server pubkey-authentication`

**Parameters**

None

**Default**

Enabled

**Command Mode**

CONFIGURATION

**Usage Information**

The no version of this command disables the public key authentication.

**Example**

```
OS10(config)# ip ssh server pubkey-authentication
```

**Supported Releases**

10.3.0E or later

#### ip ssh server vrf

Configures an SSH server for the management or non-default VRF instance.

**Syntax**

`ip ssh server vrf {management | vrf-name}`

**Parameters**

- `management` — Configures the management VRF instance to reach the SSH server.
- `vrf-name` — Enter the VRF instance used to reach the SSH server.

**Default**

Not configured

**Command Mode**

CONFIGURATION

**Usage Information**

The SSH server uses the management VRF.

**Example**

```
OS10(config)# ip ssh server vrf management
OS10(config)# ip ssh server vrf vrf-blue
```

**Supported Releases**

10.4.0E(R1) or later

#### show ip ssh

Displays the SSH server information.

**Syntax**

`show ip ssh`

**Parameters**

None

**Default**

Not configured

**Command Mode**

EXEC

**Usage Information**

Use this command to view information about the established SSH sessions.

**Example**

```
OS10# show ip ssh
SSH Server:                   Enabled
--------------------------------------------------
SSH Server Ciphers:           chacha20-poly1305@openssh.com,aes128-ctr,
                              aes192-ctr,aes256-ctr,
                              aes128-gcm@openssh.com,aes256-gcm@openssh.com
SSH Server MACs:              umac-64-etm@openssh.com,umac-128-etm@openssh.com,
                              hmac-sha2-256-etm@openssh.com,
                              hmac-sha2-512-etm@openssh.com,
                              hmac-sha1-etm@openssh.com,umac-64@openssh.com,
                              umac-128@openssh.com,hmac-sha2-256,
                              hmac-sha2-512,hmac-sha1
SSH Server KEX algorithms:    curve25519-sha256@libssh.org,ecdh-sha2-nistp256,
                              ecdh-sha2-nistp384,ecdh-sha2-nistp521
Password Authentication:      Enabled
Host-Based Authentication:    Disabled
RSA Authentication:           Enabled
Challenge Response Auth:      Disabled
```

**Supported Releases**

10.3.0E or later

#### ssh

Starts an SSH client session.

**Syntax**

`ssh [vrf {management | vrf-name} {-b source-ip-address] [-B source-interface] [-c encryption-cypher] [-l username] [-m HMAC-algorithm] [-p port-number] [-h] destination`

**Parameters**

- `vrf management` — (Optional) SSH to an IP address in a management VRF instance.
- `vrf vrf-name` — (Optional) SSH to an IP address to a specified VRF instance.
- `-b source-ip-address` — (Optional) Enter the source IPv4 or IPv6 address. If not mentioned, this option chooses the source address corresponding to the destination address from the route table.
- `-B source-intherface` — (Optional) Enter the source interface name without spaces. If not mentioned, this option chooses the source address corresponding to the destination interface from the route table.
  - For a physical Ethernet interface, enter `ethernet<node/slot/port>`; for example, ethernet1/1/1.
  - For a VLAN interface, enter `vlan<vlan-id;>` for example, vlan10.
  - For a Loopback interface, enter `loopback<id>`; for example, loopback1.
  - For Virtual-Network, enter `virtual-network<vn-id>`; for example, virtual-network20.
  - For a LAG interface, enter `port-channel<channel-id>`; for example, port-channel11.
- `-c encryption-cypher` — (Optional) Enter the supported encryption ciphers. You can issue multi-encryption ciphers. Following is the default list of Cipher algorithms that are used by SSH Client for establishing the session when cipher algorithm is not explicitly mentioned by user, the first cipher algorithm matching the SSH server's list is used for encryption.
  - chacha20-poly1305@openssh.com
  - aes128-ctr
  - aes192-ctr
  - aes256-ctr
  - aes128-gcm@openssh.com
  - aes256-gcm@openssh.com

  Following is the list of additional Ciphers supported in OS10 SSH Client CLI:
  - 3des-cbc
  - aes128-cbc
  - aes192-cbc
  - aes256-cbc
- `-l username` — (Optional) Enter the session username. If username is not specified, the current session username from which SSH client command is invoked is used to initiate an SSH session.
- `-m HMAC-algorithm` — (Optional) Enter the supported Host Message Authentication Code algorithm. You can issue multiple HMAC algorithms. Following is the default list of Message Authentication code that is used by SSH Client for establishing the session when HMAC is not explicitly mentioned by user, the first HMAC matching the SSH server list is used for authentication.
  - umac-64-etm@openssh.com
  - umac-128-etm@openssh.com
  - hmac-sha2-256-etm@openssh.com
  - hmac-sha2-512-etm@openssh.com
  - hmac-sha1-etm@openssh.com
  - umac-64@openssh.com
  - umac-128@openssh.com
  - hmac-sha2-256
  - hmac-sha2-512
  - hmac-sha1

  Following is the list of additional HMACs supported in OS10 SSH Client CLI:
  - hmac-md5
  - hmac-md5-96
  - hmac-sha1-96
  - hmac-md5-etm@openssh.com
  - hmac-md5-96-etm@openssh.com
  - hmac-sha1-96-etm@openssh.com
- `-p port-number` — (Optional) Enter the SSH server port number. The default port number is 22.
- `-h` — Displays help for this command.
- `destination` — Enter the IP address or name of the remote SSH server. The name of the SSH server can contain symbols such as os10-dell.com.

**Default**

Following are the default values for the options listed:

- `vrf` — management.
- `-c` — `chacha20-poly1305@openssh.com,aes128-ctr,aes192-ctr,aes256-ctr,aes128-gcm@openssh.com,aes256-gcm@openssh.com`
- `-l` — Current session username.
- `-m` — `umac-64-etm@openssh.com,umac-128-etm@openssh.com,hmac-sha2-256-etm@openssh.com,hmac-sha2-512-etm@openssh.com,hmac-sha1-etm@openssh.com,umac-64@openssh.com,umac-128@openssh.com,hmac-sha2-256,hmac-sha2-512,hmac-sha1`
- `-p` — 22
- `-b` and `-B` — The default values depend on the source IP/Interface from the routing table for that specific destination.

**Command Mode**

EXEC

**Usage Information**

SSH is a command for logging into a remote machine and for running commands on a remote machine. This provides a secure encrypted communication between two untrusted hosts over an insecure network.

> **NOTE:** OS10 considers `-B {Source interface}` as egress interface.

This command is available for all user-roles, but it has to be enabled using the `ip ssh client cli enable` command which is accessible only for sysadmin and secadmin user roles. If you try to invoke the SSH command when the SSH command is disabled, an Unrecognized command error appears.

**Example**

```
OS10_Switch_1# ssh 9.1.1.2
The authenticity of host '9.1.1.2 (9.1.1.2)' can't be established.
ECDSA key fingerprint is SHA256:43XxebRXcDxO8XBWFHcitZOFv/h43VkRwSyczGWS4Og.
Are you sure you want to continue connecting (yes/no/[fingerprint])? yes
Warning: Permanently added '9.1.1.2' (ECDSA) to the list of known hosts.
Debian GNU/Linux 9
Dell SmartFabric Operating System (OS10)
admin@9.1.1.2's password:
OS10_Switch_2#
OS10_Switch_1# ssh -h
usage: [-b source_ip_address] [-B source_interface] [-c encryption_cipher] [-l username] [-m HMAC_algorithm] [-p port-number] [-h] Hostname
Linux options supported for SSH.
optional arguments:
-h, --help show this help message and exit
SSH Options:
-b [Source IP Address]      Source Address of the connection
-B [Source Interface]       Source Interface of the connection
-c [Encryption Cipher]      Encryption cipher to use
-l [Username]               User name option
-m [HMAC Algorithm]         HMAC algorithm to use
-p [Port Number]            SSH server port option (default 22)
Hostname                    IP address or hostname of a remote system
```

**Supported Releases**

10.5.2.1 or Later

#### show crypto ssh-key

Displays the current host public keys that are used in SSH authentication.

**Syntax**

`show crypto ssh-key {rsa | ecdsa | ed25119}`

**Parameters**

- `rsa` — Displays the RSA public key.
- `ecdsa` — Displays the ECDSA public key.
- `ed25519` — Displays the Ed25519 key.

**Default**

Not configured

**Command Mode**

EXEC

**Usage Information**

After you regenerate an SSH server key with a customized bit size, disable and re-enable the SSH server to use the new public keys. To verify the changes, use the `show crypto` command. If a remote SSH client uses strict host-key checking, copy a newly generated host key to the list of known hosts on the client device.

**Example**

```
OS10# show crypto ssh-key rsa
ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABAQCogJtArA0fHJkFpioGaAcp+vrDQFC3l3XFHtd41wXY9kM0Ar+37yRsDul8vKodqSDiGLRuPjFTcVjvDdSKWblJRsybkmA6nuHJIyPOScDepLlicMIOxDhXEE92VRAmGuLI2AoeVYcH+IneWXhwQOkOFLtpxfnsiQY65CfS4aGoHOHWSfX3wI7boEDRDuvZ8gzRxTuM16Qr+RxBLJ7/OzkjNIN1/8Ok+8aJtCoJKbcYaduMjmhVNrNUW5TUXoCnp1XNRpkJzgS7Lt47yi86rqrTCAQW4eSYJIJs4+4ql9b4MF2D3499Ofn8uS82Mjtj0Nl01lbTbP3gsF4YYdBWaFqp root@OS10
```

**Supported Releases**

10.4.1.0 or later

#### username sshkey

Enables SSH password-less login using the public key of a remote client. The remote client is not prompted to enter a password.

**Syntax**

`username username sshkey sshkey-string`

**Parameters**

- `username` — Enter the username. This value is the username that is configured with the `username password role` command.
- `sshkey-string` — Enter the public key of the remote client device, as the text string. If sshkey-string contains a blank space, enclose the string in double quotes (").

**Default**

The default SSH public keys are an RSA key generated using 3072 bits, an ECDSA key with 256 bits, and an Ed2559 key with 256 bits.

**Command Mode**

CONFIGURATION

**Usage Information**

To configure multiple public keys for SSH password-less login of a specific user, use the `username username sshkey filename` command. The no form of the command removes the public key configuration of a specified user. A remote client system stores the public key of a user in the `~/.ssh/id_rsa.pub` file. Use the public key as the `sshkey-string` parameter.

> **NOTE:** While running with FIPS mode enabled, SmartFabric OS10 accepts only RSA and ECDSA user keys. If the keys are installed before entering the FIPS mode, such keys are not affected.

**Example**

```
OS10(config)# username test sshkey "ssh-rsa AAAAB3NzaC1yc2EAAAABJQAAAQBqJaDwgBgQX1PPPSEyx+F5DVG2RpBH4Zm1YQApE5YJsKlt6RpeOIT1wnJP/o54p1nCeMu38i7/zCLwuWt3XDVVMoSCb9Za89hebQ+f6XyNs4aMpyUk5RmuZTXqwnebUUuP3nPw/Y4lKkZJafWx125Ma7IbwfUM5wGdBu76j8mvwsWvNxrnkOsweo7Anp67p8Lsg+KBUsx3q8Fpc986qQfdrcEFOO1WraJR8wzY1mbQw/C+Hm5Ap6Nr6DoXMWqKdKUr7jfte8ThARYZD8dvZeyzhk3nykYRQ39mqjXnOyEOiDl1e21QUvI1cjcQPDXgFJUrKcc1yPiGUOH5"
```

**Supported Releases**

10.4.1.0 or later

#### username sshkey filename

Enables SSH password-less login for remote clients using multiple public keys. A remote client is not prompted to enter a password.

**Syntax**

`username username sshkey filename filepath`

**Parameters**

- `username` — Enter an OS10 username who logs in on a remote client. This value is the username that is configured using the `username password role` command.
- `filepath` — Enter the absolute path name of the local file containing the public keys used by remote devices to log in to the OS10 switch.

**Default**

The default SSH public keys are an RSA key generated using 3072 bits, an ECDSA key with 256 bits, and an Ed2559 key with 256 bits.

**Command Mode**

CONFIGURATION

**Usage Information**

Before you use the command, locate the public keys on a remote client in the `~/.ssh/id_rsa.pub` file. Create a text file and copy the SSH public keys on the remote client into the file. Enter each public key on a separate line. Download the file to your home OS10 directory. Entering the command when an SSH key file is not present has no effect and results in a silent failure. SSH password-less login is not enabled. The no version of the command removes the SSH password-less configuration for the specified username.

> **NOTE:** While running with FIPS mode enabled, SmartFabric OS10 accepts only RSA and ECDSA user keys. If the keys are installed before entering the FIPS mode, such keys are not affected.

**Example**

```
OS10(config)# username user10 sshkey filename /test_file.txt
```

**Supported Releases**

10.4.1.0 or later

#### crypto ssh-key generate

Regenerates the public keys that are used in SSH authentication.

**Syntax**

`crypto ssh-key generate {rsa bits | ecdsa bits | ed25519}`

**Parameters**

- `rsa bits` — Regenerates the RSA key with the specified bit size: 2048, 3072, or 4096; default 2048.
- `ecdsa bits` — Regenerates the ECDSA key with the specified bit size: 256, 384, or 521; default 256.
- `ed25519` — Regenerates the Ed25519 key with the default bit size.

**Default**

The SSH server uses default public key lengths for client authentication:

- RSA key: 2048 bits
- ECDSA key: 256 bits
- Ed25519 key: 256 bits

**Command Mode**

EXEC

**Usage Information**

If necessary, you can regenerate the public keys that are used by the SSH server with a customized bit size. You cannot change the default size of the Ed25519 key. The `crypto ssh-key generate` command is available only to the sysadmin and secadmin roles.

**Example**

```
OS10# crypto ssh-key generate rsa 4096
Host key already exists. Overwrite [confirm yes/no]:yes
Generated 4096-bit RSA key
OS10#
```

**Supported Releases**

10.4.1.0 or later

#### login concurrent-session limit

Configures the maximum number of concurrent login sessions that are allowed for a user ID.

**Syntax**

`login concurrent-session limit number`

**Parameters**

`limit number` — Enter the limit of concurrent login sessions, from 1 to 12.

**Default**

10 concurrent login sessions

**Command Mode**

CONFIGURATION

**Usage Information**

The total number of concurrent login sessions for the same user ID includes all console and remote connections, where:

- Each remote VTY connection counts as one login session.
- All login sessions from a terminal emulator on an attached console count as one session.

The no version of the command disables the configured number of allowed login sessions.

**Example**

```
OS10(config)# login concurrent-session limit 7
```

**Supported Releases**

10.4.1.0 or later

#### line vty

Enters virtual terminal line mode to access the virtual terminal (VTY).

**Syntax**

`line vty`

**Parameters**

None

**Default**

Not configured

**Command Mode**

CONFIGURATION

**Usage Information**

None

**Example**

```
OS10(config)# line vty
OS10(config-line-vty)#
```

**Supported Releases**

10.4.0E(R1) or later

#### ipv6 access-class

Filters connections in a virtual terminal line using an IPv6 access list.

**Syntax**

`ipv6 access-class access-list-name`

**Parameters**

`access-list-name` — Enter the access list name.

**Default**

Not configured

**Command Mode**

LINE VTY CONFIGURATION

**Usage Information**

The no version of this command removes the filter.

**Example**

```
OS10(config)# line vty
OS10(config-line-vty)# ipv6 access-class permit10
```

**Supported Releases**

10.4.0E(R1) or later

#### ip access-class

Filters connections in a virtual terminal line using an IPv4 access list.

**Syntax**

`ip access-class access-list-name`

**Parameters**

`access-list-name` — Enter the access list name.

**Default**

Not configured

**Command Mode**

LINE VTY CONFIGURATION

**Usage Information**

The no version of this command removes the filter.

**Example**

```
OS10(config)# line vty
OS10(config-line-vty)# ip access-class deny10
```

**Supported Releases**

10.4.0E(R1) or later

## Switch management statistics

OS10 monitors user and system activities and provides output-related user login statistics.

### Enable login statistics

To monitor system security, allow users to view their own login statistics when they sign in to the system. A large number of login failures or an unusual login location may indicate a system hacker. Enable the display of login information after a user successfully logs in; for example:

```
OS10 login: admin
Password:
Last login: Thu Nov  2 16:02:44 UTC 2017 on ttyS1
Linux OS10 3.16.43 #2 SMP Debian 3.16.43-2+deb8u5 x86_64
...
Time-frame for statistics     : 25 days
Role changed since last login : false
Failures since last login     : 0
Failures in time period       : 1
Successes in time period      : 14
OS10#
```

This feature is available only for the sysadmin and secadmin roles.

- Enable the display of login information in CONFIGURATION mode.

  `login-statistics enable`

To display information about user logins, use the `show login-statistics` command.

Enable login statistics:

```
OS10(config)# login-statistics enable
```

To disable login statistics, use the `no login-statistics enable` command.

### Audit log

To monitor user activity and configuration changes on the switch, enable the audit log. Only the sysadmin and secadmin roles can enable, view, and clear the audit log.

The audit log records configuration and security events, including:

- User logins and logouts on the switch, failed logins, and concurrent login attempts by a user
- User-based configuration changes recorded with the user ID, date, and time of the change. The specific parameter changes are not logged.
- Establishment of secure traffic flows, such as SSH, and violations on secure flows
- Certificate issues, including user access and changes made to certificate installation using crypto commands
- Adding and deleting users

Audit log entries are saved locally and sent to configured Syslog servers. To set up a Syslog server, see System logging.

### Enable audit log

- Enable configuration and security event recording in the audit log on Syslog servers in CONFIGURATION mode.

  `logging audit enable`

To disable audit logging, use the `no logging audit enable` command.

### View audit log

- Display audit log entries in EXEC mode. By default, 24 entries are displayed, starting with the oldest event. Enter `reverse` to display entries starting with the most recent events. You can change the number of entries that display.

  `show logging audit [reverse] [number]`

### Clear audit log

- Clear all events in the audit log in CONFIGURATION mode.

  `clear logging audit`

**Example**

```
OS10(config)# logging audit enable
OS10(config)# exit
OS10# show logging audit 4
<14>1 2019-02-14T13:15:06.283337+00:00 OS10 audispd - - - Node.1-Unit.1:PRI [audit], Dell (OS10)  node=OS10 type=USER_END msg=audit(1550150106.277:597): pid=7908 uid=0 auid=4294967295 ses=4294967295 msg='op=PAM:session_close acct="admin" exe="/bin/su" hostname=? addr=? terminal=??? res=success'
<110>1 2019-02-14T13:15:16.331515+00:00 OS10 .clish 7412 - -  Node.1-Unit.1:PRI [audit], User admin on console used cmd: 'crypto security-profile mltestprofile' - success
<110>1 2019-02-14T13:15:21.794529+00:00 OS10 .clish 7412 - -  Node.1-Unit.1:PRI [audit], User admin on console used cmd: 'exit' - success
<110>1 2019-02-14T13:16:05.882555+00:00 OS10 .clish 7412 - -  Node.1-Unit.1:PRI [audit], User admin on console used cmd: 'exit' - success
```

## Switch management statistics commands

#### login-statistics enable

Enables the display of login statistics to users.

**Syntax**

`login-statistics enable`

**Parameters**

None

**Default**

Disabled

**Command Mode**

CONFIGURATION

**Usage Information**

Only the sysadmin and secadmin roles have access to this command. When enabled, user login information, including the number of successful and failed logins, role changes, and the last time a user logged in, displays after a successful login. The `no login-statistics enable` command disables login statistics.

**Example**

```
OS10(config)# login-statistics enable
```

**Supported Releases**

10.4.0E(R1) or later

#### show login-statistics

Displays statistics on user logins to the system.

**Syntax**

`show login-statistics {user user-id | all}`

**Parameters**

- `user user-id` — Enter an OS10 username.
- `all` — Displays login statistics for all system users.

**Default**

Not configured

**Command Mode**

EXEC

**Usage Information**

Only the sysadmin and secadmin roles can access this command. The show output displays login information for system users, including the number of successful and failed logins, role changes, and the last time a user logged in.

**Example**

```
OS10# show login-statistics all
Display statistics upon user login: Enabled
Time-frame in days: 25
               #Fail
               since During
        Role   last  Timeframe                 Last Login
User    Change Login #Fail #Success  Date/Time             Location
-------- ----- ----- --------------  ------------------    ----------
admin    False  0     1    13        2017-11-02T16:02:44Z  in
netadmin False  0     0     5        2017-11-02T15:59:04Z  (00:00)
mltest   False  0     0     1        2017-11-01T15:42:07Z  1001:10:16:210::4001
OS10# show login-statistics user mltest
User                          : mltest
Role changed since last login : False
Failures since last login     : 0
Time-frame in days            : 25
Failures in time period       : 0
Successes in time period      : 1
Last Login Time               : 2017-11-01T15:42:07Z
Last Login Location           : 1001:10:16:210::4001
```

**Supported Releases**

10.4.0E(R1) or later

#### clear logging audit

Deletes all events in the audit log.

**Syntax**

`clear logging audit`

**Parameters**

None

**Defaults**

Not configured

**Command Mode**

EXEC

**Usage Information**

To display the contents of the audit log, use the `show logging audit` command.

**Example**

```
OS10# clear logging audit
Proceed to clear all audit log messages [confirm yes/no(default)]:yes
```

**Supported Releases**

10.4.3.0 or later

#### show logging audit

Displays audit log entries.

**Syntax**

`show logging audit [reverse] [number]`

**Parameters**

- `reverse` — Display entries starting with the most recent events.
- `number` — Display the specified number of audit log entries users, from 1 to 65535.

**Default**

Display 24 entries starting with the oldest events.

**Command Mode**

EXEC

**Usage Information**

Only the sysadmin and secadmin roles can display the audit log. Enter `reverse` to display entries starting with the most recent events. You can change the number of entries displayed. Audit log records do not display on the console as they occur. They are saved in the audit log and forwarded to any configured Syslog servers.

**Example**

```
OS10# show logging audit 4
<14>1 2019-02-14T13:15:06.283337+00:00 OS10 audispd - - - Node.1-Unit.1:PRI [audit], Dell (OS10)  node=OS10 type=USER_END msg=audit(1550150106.277:597): pid=7908 uid=0 auid=4294967295 ses=4294967295 msg='op=PAM:session_close acct="admin" exe="/bin/su" hostname=? addr=? terminal=??? res=success'
```

**Supported Releases**

10.4.3.0 or later

#### logging audit enable

Enables recording of configuration and security events in the audit log.

**Syntax**

`logging audit enable`

**Parameters**

None

**Defaults**

Not configured

**Command Mode**

CONFIGURATION

**Usage Information**

Audit log entries are saved locally and sent to configured Syslog servers. Only the sysadmin and secadmin roles can enable the audit log. The no version of the command disables audit log recording.

**Example**

```
OS10(conf)# logging audit enable
```

**Supported Releases**

10.4.3.0 or later
