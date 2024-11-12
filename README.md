# ansible_scripts Repository

This GitHub repository, **ansible_scripts**, serves as a centralized location for storing and managing all my Ansible scripts. 
Ansible is a powerful automation tool used for configuration management, application deployment, and task automation.

This repository contains Ansible playbooks organized using the [Alternative Directory Layout](https://docs.ansible.com/ansible/latest/user_guide/playbooks_best_practices.html#alternative-directory-layout). Each inventory file, along with its associated `group_vars` and `host_vars`, is stored in a separate directory, allowing for better separation of configuration and management tasks.

Feel free to explore the contents of this repository, use the provided Ansible scripts, and adapt them to your specific infrastructure and automation needs.

## Repository Structure

The repository includes two main directories:

1. **client**: Contains playbooks for creating new machines.
2. **update**: Contains playbooks for updating and installing software on existing systems.

### Client Directory

The `client` directory includes a playbook called `new.yml`, which is used to create new users and configure a remote machine with essential tools and services.

#### Playbook: `new.yml`

This playbook prompts for a new username and password, then performs the following tasks:

- Ensures passwords match and meet security standards.
- Installs required packages.
- Creates the default user.
- Prepares SSH access.
- Installs Docker.
- Cleans up temporary files.

##### Example Command

To execute this playbook:

```bash
ansible-playbook client/new.yml --vault-password-file /path/to/pass.file
```

### Update Directory

The `update` directory includes three playbooks designed for updating or installing various services on different systems:

1. **`nas.yml`**: Updates the NAS server with various roles such as file-sharing services, media applications, and monitoring tools.
2. **`server.yml`**: Updates general-purpose servers, including security, cloud services, and personal management applications.
3. **`monitor.yml`**: Updates monitoring systems, installing and configuring various monitoring and alerting tools.

#### Playbook: `nas.yml`

Used for updating the NAS server, applying roles such as:

- `authelia`, `traefik`, `crowdsec` for security and reverse-proxy setup
- Media applications like `prowlarr`, `radarr`, `sonarr`, `plex`, and others

#### Playbook: `server.yml`

Updates general-purpose servers and installs:

- Security and reverse-proxy tools (`authelia`, `traefik`, `crowdsec`)
- Monitoring tools (`node_exporter`, `public_ip_updater`)
- Cloud services (`nextcloud`)
- Personal applications (e.g., `ghost`, `kavita`)

#### Playbook: `monitor.yml`

Used for updating monitoring machines with roles such as:

- Security and reverse-proxy (`authelia`, `traefik`, `crowdsec`)
- Monitoring and alerting tools (`influxdb`, `prometheus`, `grafana`, `homeassistant`)

##### Example Commands

Run `nas.yml`:

```bash
ansible-playbook update/nas.yml --vault-password-file /path/to/pass.file
```

Run `server.yml`:

```bash
ansible-playbook update/server.yml --vault-password-file /path/to/pass.file
```

Run `monitor.yml`:

```bash
ansible-playbook update/monitor.yml --vault-password-file /path/to/pass.file
```

## Requirements

- **Ansible**: Ensure Ansible is installed on your system.
- **Ansible Vault**: Sensitive data is encrypted using Ansible Vault. Use the `--vault-password-file` option to specify the vault password file path.

## Inventory and Variable Layout

This repository uses the **Alternative Directory Layout** to organize inventories and variables for each environment:

- Each playbook has its own inventory file and associated `group_vars`/`host_vars` directories to manage configuration for specific groups or hosts.

## Usage

To execute any of the playbooks, use the `ansible-playbook` command with the `--vault-password-file` option. This allows Ansible to decrypt any sensitive variables or credentials stored with Ansible Vault.

---

This layout provides an organized structure to manage and execute Ansible playbooks across different environments, simplifying user management and system updates across multiple server types.

### Key Features

- **Automation**: Ansible enables automation of repetitive tasks, ensuring consistency and reducing manual effort.
- **Modularity**: Organized into playbooks and roles for easy customization and reuse.
- **Documentation**: Includes READMEs and comments to explain how to use each script effectively.
- **Version Control**: Utilizes Git for version control, making it easy to track changes and collaborate with others.

**Happy automating!** 🚀
