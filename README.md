# Bloody Server Manager

A lightweight Bash CLI for managing a Docker-based **Palworld dedicated server** on Linux.

Bloody Server Manager grew from a real home-server management workflow and was cleaned up for public use. It keeps common operations in one terminal menu without requiring a web dashboard.

## Features

- Start, stop, and restart the Docker Compose server
- Live Docker logs
- Safe save-game backups before updates
- Palworld configuration editing with automatic config backup
- Connected-player list through RCON
- CPU, RAM, disk, uptime, game version, and server status overview
- Docker image update workflow with a backup first
- Optional Discord webhook notifications
- Local configuration file so personal paths, IPs, and webhook URLs stay out of Git

## Requirements

- Linux
- Bash
- Docker + Docker Compose plugin
- A working Palworld dedicated-server container
- `rcon-cli` available inside the Palworld container for player-list support
- `python3` and `curl` only if Discord notifications are used
- `nano` for the built-in configuration editor

## Installation

```bash
git clone https://github.com/bloodymir1992/Bloody-Server-Manager.git
cd Bloody-Server-Manager
cp bloodyserver.conf.example bloodyserver.conf
nano bloodyserver.conf
chmod +x bloodyserver-manager.sh
./bloodyserver-manager.sh
```

The script expects to be run from the same directory as your `docker-compose.yml` / `compose.yml`, or from a directory where Docker Compose can resolve your server project.

## Configuration

Copy `bloodyserver.conf.example` to `bloodyserver.conf` and set:

- `SERVER_NAME`: Docker container name
- `SERVER_LABEL`: friendly server name shown in the UI and Discord
- `LOCAL_IP`, `PORT`, `QUERY_PORT`: local network information
- `PALWORLD_ROOT`: root directory of your Palworld server installation
- `SAVE_DIR`: save-game directory on the host
- `LOCAL_CONFIG`: host copy of `PalWorldSettings.ini`
- `CONTAINER_CONFIG`: config path inside the container

`bloodyserver.conf` is ignored by Git so your private configuration is not published.

## Discord notifications

Discord is optional. Put your webhook URL in the file configured by `DISCORD_WEBHOOK_FILE`, for example:

```bash
mkdir -p "$HOME/PalworldServer"
printf '%s\n' 'YOUR_DISCORD_WEBHOOK_URL' > "$HOME/PalworldServer/.discord-webhook"
chmod 600 "$HOME/PalworldServer/.discord-webhook"
```

Never commit a real webhook URL to GitHub.

## Backup behavior

Before a manual Docker-image update, Bloody Server Manager stops the server, copies the save directory into a timestamped backup directory, starts the server again, and only then continues the update if the backup succeeded.

## Scope

Version 1.0.0 is focused on Palworld + Docker Compose. The project name is intentionally broader so support for additional dedicated game servers can be added later.

## License

MIT License. See [LICENSE](LICENSE).
