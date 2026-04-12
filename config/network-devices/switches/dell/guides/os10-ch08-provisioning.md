# Dell SmartFabric OS10 provisioning

OS10 supports automated switch provisioning--configuration and monitoring--using:

- **RESTCONF API** -- REST-like protocol that uses HTTPS connections. Use the OS10 RESTCONF API to set up the configuration parameters on OS10 switches with JavaScript Object Notation (JSON)-structured messages. You can use any programming language to create and send JSON messages; see RESTCONF API.
- **Linux DevOps ecosystem** -- OS10 provides access to an unmodified Linux (Debian) operating system that allows you to benefit from the Linux DevOps ecosystem. Programmers can write applications in Python or C/C++ to execute on an OS10 switch.
- **Ansible** -- Third-party DevOps tool. Ansible is a powerful, open-source IT automation engine that provides a simple way to automate application software and IT infrastructure. Ansible allows you to remove complexity from these environments and accelerate DevOps initiatives; see [Using Ansible](#using-ansible) and [Example: Configure OS10 switch using Ansible](#example-configure-an-os10-switch-using-ansible).

## Using Ansible

Ansible works by connecting to your nodes using SSH and pushing out small programs, called Ansible modules, to them. Ansible includes hundreds of network modules to support a wide variety of network device vendors. Ansible uses a simple, powerful, and agentless automation framework. For more information, go to Network Automation with Ansible.

### Dell Networking Ansible solutions

Dell Networking Ansible solutions are based on an open ecosystem that allows organizations to choose from industry-standard network applications, network operating systems, and network hardware. Use Ansible to provision and manage Dell switches for rapid new device deployment and network configuration changes. Ansible also allows you to track running network device configurations against a known baseline for both Dell Technologies and third-party operating systems.

The Ansible modules for Dell Networking solutions allow organizations to reduce the time and effort that is required to design, provision, and manage networks by providing these benefits:

- **Agentless** -- No new software is required to install on switches.
- **Powerful** -- End-to-end automation of the configuration of bare metal switches using the Dell Open Automation framework.
- **Easy-to-use** -- Dell Networking modules ship with the Ansible distribution. There is nothing extra to install.
- **Best practice** -- Uses CLI user authentication to centralize and monitor session management.

### Dell Networking Ansible modules

Ansible ships with several modules that can be run directly on remote hosts or through playbooks. The collection of modules is called the module library. Modules are discrete units of code that are used from the command line or in a playbook task. You can also write your own modules.

Starting with Ansible 2.2, the Ansible core supports Dell Networking modules. Use these modules to manage and automate Dell switches running OS6, OS9, and OS10. Dell Networking modules are run in local connection mode using CLI and SSH transport. The following OS10 modules are integrated into the Ansible core:

- **dellos10_command** -- Runs show commands or EXEC mode commands through Ansible. For example, `show version` command output displays the current OS version running on a switch.
- **dellos10_config** -- Runs OS10 configuration commands through Ansible.
- **dellos10_facts** -- Retrieves the running configuration from an OS10 switch.

### Dell Networking Ansible roles

Ansible roles allow you to automatically load variable files (`vars_files`) and tasks based on a known file structure. Grouping content by roles allows the roles to be easily shared with other users. These roles are abstracted for OS6, OS9, and OS10. Download Dell Ansible Networking roles from the Ansible Galaxy website.

For information and examples about how to use the Ansible roles, see Dell Networking Repositories.

### Ansible inventory file

The inventory file contains the list of hosts on which you want to run commands. Ansible can run tasks on multiple hosts simultaneously.

Ansible playbooks use `/etc/ansible/hosts` as the default inventory file. To specify a different inventory file, use the `-i filepath` command as an option when you run an Ansible playbook.

### Ansible playbook file

Using playbooks, Ansible can configure multiple devices. Playbooks are human-readable scripts that are expressed in YAML format. An Ansible playbook takes inventory and playbook files as arguments and maps the group of hosts in the inventory files to the tasks listed in the playbook file.

### Ansible variables

In Ansible, variables define switch configurations. Many Dell switches have common configurations. Common configuration variables are stored in the `vars/main.yaml` file; for example, `dns_server` and `ntp_server`. All host-specific configurations are stored in the `host_vars/host_name.yaml` configuration file; for example, the hostname of a switch. Variables are also used as part of playbook definitions, command-line arguments, and inventory definitions.

## Example: Configure an OS10 switch using Ansible

OS10 supports Ansible integration to automate switch configuration. For detailed information about how to use Ansible scripts and create Ansible playbooks, go to:

- Dell Ansible Documentation
- Dell Networking Guides and search for Ansible

You can download autogenerated Ansible configuration files for the network design you provide from the Dell Fabric Design Center.

### Before you start

Before you configure an OS10 switch using Ansible, configure basic network settings on your switch, such as assigning an IP address and default gateway to the management interface:

1. Connect a terminal emulator to the console serial port on the switch using a serial cable. The serial port settings are 115200, 8 data bits, and no parity.

2. Configure the management interface; for example:

```
OS10(config)# interface mgmt 1/1/1
OS10(conf-if-ma-1/1/1)# no ip address dhcp
OS10(conf-if-ma-1/1/1)# ip address 10.1.1.10/24
OS10(conf-if-ma-1/1/1)# no shutdown
OS10(conf-if-ma-1/1/1)# exit
OS10(config)# management route 10.10.20.0/24 10.1.1.1
OS10(config)# end
```

### Ansible configuration example

In this example, the configuration uses Ansible roles to configure an OS10 switch from an Ansible controller node with:

- User name and password
- NTP server
- Syslog server

1. Install Ansible on a controller node. You can find the latest version of Ansible on the Ansible Installation Guide page. You can run Ansible from any device with Python 2 (version 2.7) or Python 3 (version 3.5 or higher) installed, including Red Hat, Debian, Ubuntu, CentOS, operating system X, any of the BSDs and so on. In this example, Ansible 2.7.12 is installed on an Ubuntu 16.04 virtual machine. To configure the Personal Package Archives (PPA) repository on the controller node and install Ansible, run these commands:

   ```bash
   sudo apt-get update
   sudo apt-get install software-properties-common
   sudo apt-add-repository --yes --update ppa:ansible/ansible
   sudo apt-get install ansible
   ```

   After you install Ansible, verify the version by entering:

   ```bash
   $ ansible --version
   ```

2. Download and install Dell Networking Ansible roles from the Ansible Galaxy web page; for example:

   ```bash
   $ ansible-galaxy install dell-networking.dellos-users
   $ ansible-galaxy install dell-networking.dellos-logging
   $ ansible-galaxy install dell-networking.dellos-ntp
   ```

3. Create a directory to store inventory and playbook files; for example:

   ```bash
   $ mkdir AnsibleOS10
   ```

4. Navigate to the directory and create an inventory file.

   ```bash
   $ cd AnsibleOS10/
   $ vim inventory.yaml
   ```

5. Add the IP address and operating system for each switch in the `inventory.yaml` file. Enter the command for each switch on one command line.

   ```
   OS10switch-1 ansible_host=192.168.1.203 ansible_network_os=dellos10
   OS10switch-2 ansible_host=192.168.1.204 ansible_network_os=dellos10
   ```

6. Create a `host_vars` directory to use for switch-specific variable files.

   ```bash
   $ mkdir host_vars
   ```

7. Create a host variable file; for example, `host_vars/OS10switch-1.yaml`. Then define the hostname and login credentials:

   ```bash
   $ vim host_vars/OS10switch-1.yaml
   ```

   ```yaml
   hostname: OS10switch-1
   dellos_cfg_generate: True
   build_dir: /home/user/config
   ansible_ssh_user: admin
   ansible_ssh_pass: admin
   dellos_logging:
     logging:
     - ip: 192.0.2.1
       state: present
   dellos_users:
     - username: u1
       password: test@2468
       role: sysadmin
       privilege: 0
       state: present
   dellos_ntp:
     server:
     - ip: 192.0.2.2
   ```

   ```bash
   $ vim host_vars/OS10switch-2.yaml
   ```

   ```yaml
   hostname: OS10switch-2
   dellos_cfg_generate: True
   build_dir: /home/user/config
   ansible_ssh_user: admin
   ansible_ssh_pass: admin
   dellos_logging:
     logging:
     - ip: 192.0.2.1
       state: present
   dellos_users:
     - username: u1
       password: Test@1347
       role: sysadmin
       privilege: 0
       state: present
   dellos_ntp:
     server:
     - ip: 192.0.2.2
   ```

   The `dellos_cfg_generate` parameter creates a local copy of the configuration commands that are applied to the remote switch on the Ansible controller node, and saves the commands in the directory that is defined in the `build_dir` path.

8. Create a playbook file.

   ```bash
   $ vim playbook.yaml
   ```

   ```yaml
   - hosts: OS10switch-1 OS10switch-2
     connection: network_cli
     roles:
       - dell-networking.dellos-logging
       - dell-networking.dellos-users
       - dell-networking.dellos-ntp
   ```

   To check the syntax of a playbook, use the `ansible-playbook` command with the `--syntax-check` flag. This command runs the playbook file through the parser to ensure that its included files, roles, and other parameters have no syntax problems.

9. Run the playbook file. In the `ansible-playbook` command, the inventory and playbook files are mandatory entries. The play recap displays the results of the provisioning session; for example:

   ```bash
   $ ansible-playbook -i inventory.yaml playbook.yaml
   ...
   ...
   ...
   PLAY RECAP
   ***************************************************************
   OS10switch-1: ok=7    changed=6    unreachable=0    failed=0
   OS10switch-2: ok=7    changed=6    unreachable=0    failed=0
   ```
