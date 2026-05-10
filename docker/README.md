# Docker Container Management Guide

## 🚀 Recommendations

### System Setup
- **Operating System**: 
  - ✅ Preferred: Native Linux
  - Windows: Use WSL2 (Windows Subsystem for Linux)
  - Alternative: VirtualBox VM

### Storage Configuration
- **Performance**: 
  - 🚀 Always run containers on SSD
  - 💾 Reduces HDD wear and improves performance

### Backup Strategy
- **3-2-1 Backup Rule**:
  1. Primary: Active `docker` folder on SSD
  2. Secondary: Backup to HDD (same machine)
  3. Tertiary: Backup to external drive/NAS

## 🔄 Backup Commands

### Rsync Options
# Safe sync (preserves destination files)
```bash
rsync -avh --progress /ssd/docker/ /hdd/docker_backup/
```

# Mirror sync (exact copy with deletion)
```bash
rsync -avh --progress --delete --info=progress2 /ssd/docker/ /hdd/docker_backup/
```

## 🐳 Docker Files

| File                        | Purpose                          |
|-----------------------------|----------------------------------|
| `docker-compose_example.yml`| Template (requires editing)      |
| `docker-compose.yml`        | Production-ready (plug & play)   |

## 🛠️ Container Management

### Basic Commands
# Start container
```bash
docker compose up -d
```

# Stop specific container
```bash
docker stop <container_name>
```

# Stop container (from compose dir)
```bash
docker compose down
```

## Container Monitoring

# View running containers
```bash
docker ps
```

# View all containers (including stopped)
```bash
docker ps -a
```

# View container logs
```bash
docker logs <container_name>
```

## 🔧 Maintenance Commands

# Update container images
```bash
docker compose pull
```

## Volume Management

# List volumes
```bash
docker volume ls
```

# Inspect volume
```bash
docker volume inspect <volume_name>
```

# Remove unused volumes (CAUTION!)
```bash
docker volume prune
```

## Cleanup

# Remove specific container
```bash
docker rm <container_name>
```

❓ Troubleshooting

- Always check container names in `docker-compose.yml`

- For volume operations, verify no containers are using them first

- When in doubt: `docker logs <container_name>`

🍀 Good Luck!
Remember:

Regular backups prevent headaches

SSD extends hardware life

Proper shutdown prevents corruption
