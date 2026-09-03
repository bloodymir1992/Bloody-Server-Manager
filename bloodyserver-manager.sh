#!/bin/bash
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR" || exit 1

VERSION="1.0.0"
CONFIG_FILE="${BLOODY_SERVER_CONFIG:-$SCRIPT_DIR/bloodyserver.conf}"

if [ -f "$CONFIG_FILE" ]; then
  # shellcheck source=/dev/null
  source "$CONFIG_FILE"
fi

SERVER_NAME="${SERVER_NAME:-palworld-server}"
SERVER_LABEL="${SERVER_LABEL:-My Palworld Server}"
LOCAL_IP="${LOCAL_IP:-127.0.0.1}"
PORT="${PORT:-8211}"
QUERY_PORT="${QUERY_PORT:-27015}"

PALWORLD_ROOT="${PALWORLD_ROOT:-$HOME/PalworldServer}"
SAVE_DIR="${SAVE_DIR:-$PALWORLD_ROOT/palworld/Pal/Saved/SaveGames/0}"
CONTAINER_CONFIG="${CONTAINER_CONFIG:-/palworld/Pal/Saved/Config/LinuxServer/PalWorldSettings.ini}"
LOCAL_CONFIG="${LOCAL_CONFIG:-$PALWORLD_ROOT/palworld/Pal/Saved/Config/LinuxServer/PalWorldSettings.ini}"
BACKUP_DIR="${BACKUP_DIR:-$PALWORLD_ROOT/backups}"
CONFIG_BACKUP_DIR="${CONFIG_BACKUP_DIR:-$PALWORLD_ROOT/config-backups}"
DISCORD_WEBHOOK_FILE="${DISCORD_WEBHOOK_FILE:-$PALWORLD_ROOT/.discord-webhook}"

check_dependencies() {
  local missing=0

  for cmd in docker awk grep sed cut wc df nproc find sort head cp; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
      echo "Falta dependencia requerida: $cmd" >&2
      missing=1
    fi
  done

  if ! docker compose version >/dev/null 2>&1; then
    echo "Docker Compose plugin no está disponible." >&2
    missing=1
  fi

  if [ "$missing" -ne 0 ]; then
    exit 1
  fi
}

check_dependencies

if [ ! -f "$CONFIG_FILE" ]; then
  echo "Aviso: no se encontró $CONFIG_FILE"
  echo "Usando valores predeterminados. Copia bloodyserver.conf.example a bloodyserver.conf para configurar tu servidor."
  echo
fi

GREEN="\e[32m"
RED="\e[31m"
YELLOW="\e[33m"
CYAN="\e[36m"
BOLD="\e[1m"
RESET="\e[0m"

pause() {
  echo
  read -rp "Presiona ENTER para continuar..."
}

is_online() {
  docker ps --format '{{.Names}}' 2>/dev/null |
    grep -qx "$SERVER_NAME"
}

container_exists() {
  docker ps -a --format '{{.Names}}' 2>/dev/null |
    grep -qx "$SERVER_NAME"
}

status_icon() {
  if is_online; then
    echo -e "${GREEN}🟢 ONLINE${RESET}"
  else
    echo -e "${RED}🔴 OFFLINE${RESET}"
  fi
}

uptime_info() {
  if is_online; then
    docker ps \
      --filter "name=^/${SERVER_NAME}$" \
      --format "{{.Status}}" 2>/dev/null
  else
    echo "N/A"
  fi
}

cpu_info() {
  local raw_cpu
  local cpu_number
  local total_cpus
  local normalized
  local used_cores

  if ! is_online; then
    echo "N/A"
    return
  fi

  raw_cpu=$(
    docker stats \
      --no-stream \
      --format "{{.CPUPerc}}" \
      "$SERVER_NAME" 2>/dev/null
  )

  if [ -z "$raw_cpu" ]; then
    echo "N/A"
    return
  fi

  cpu_number=${raw_cpu%\%}
  total_cpus=$(nproc 2>/dev/null || echo 1)

  normalized=$(
    awk -v cpu="$cpu_number" -v cores="$total_cpus" \
      'BEGIN {
        if (cores < 1) cores = 1
        printf "%.1f", cpu / cores
      }'
  )

  used_cores=$(
    awk -v cpu="$cpu_number" \
      'BEGIN { printf "%.2f", cpu / 100 }'
  )

  echo "${normalized}% total (${used_cores} núcleos)"
}

ram_info() {
  if is_online; then
    docker stats \
      --no-stream \
      --format "{{.MemUsage}}" \
      "$SERVER_NAME" 2>/dev/null || echo "N/A"
  else
    echo "N/A"
  fi
}

disk_info() {
  df -h "$HOME" |
    awk 'NR==2 {print $4 " libres de " $2}'
}

discord_notify() {
  local message="$1"
  local webhook_file="$DISCORD_WEBHOOK_FILE"
  local webhook_url
  local payload

  if [ ! -s "$webhook_file" ]; then
    return 0
  fi

  webhook_url=$(tr -d '\r\n' < "$webhook_file")

  payload=$(
    python3 -c 'import json,sys; print(json.dumps({"content": sys.argv[1]}))' "$message"
  )

  curl -fsS \
    --max-time 10 \
    -H "Content-Type: application/json" \
    --data "$payload" \
    "$webhook_url" \
    >/dev/null 2>&1 || true
}

last_backup() {
  local backup

  backup=$(
    find "$BACKUP_DIR" \
      -maxdepth 1 \
      -type d \
      -name 'savegames-*' \
      -printf '%T@ %f\n' 2>/dev/null |
      sort -nr |
      head -n 1 |
      cut -d' ' -f2-
  )

  if [ -n "$backup" ]; then
    echo "$backup"
  else
    echo "Ninguno"
  fi
}

server_version() {
  local version

  if ! container_exists; then
    echo "N/A"
    return
  fi

  version=$(
    docker logs "$SERVER_NAME" 2>/dev/null |
      grep -i "Game version" |
      tail -n 1
  )

  if [ -n "$version" ]; then
    echo "$version"
  else
    echo "N/A"
  fi
}

query_players() {
  local result=""

  if ! is_online; then
    return 1
  fi

  result=$(
    docker exec "$SERVER_NAME" \
      rcon-cli ShowPlayers 2>/dev/null
  )

  if [ -z "$result" ]; then
    result=$(
      echo "ShowPlayers" |
        docker exec -i "$SERVER_NAME" \
          rcon-cli 2>/dev/null
    )
  fi

  if [ -z "$result" ]; then
    return 1
  fi

  printf '%s\n' "$result"
}

max_players() {
  local maximum

  if ! container_exists; then
    echo "?"
    return
  fi

  maximum=$(
    docker exec "$SERVER_NAME" \
      grep -o 'ServerPlayerMaxNum=[0-9]*' \
      "$CONTAINER_CONFIG" 2>/dev/null |
      tail -n 1 |
      cut -d= -f2
  )

  if [ -n "$maximum" ]; then
    echo "$maximum"
  else
    echo "?"
  fi
}

players_count() {
  local result
  local count
  local maximum

  if ! is_online; then
    echo "Servidor apagado"
    return
  fi

  result=$(query_players)
  maximum=$(max_players)

  if [ -z "$result" ]; then
    echo "? / $maximum (RCON no disponible)"
    return
  fi

  count=$(
    printf '%s\n' "$result" |
      sed '/^[[:space:]]*$/d' |
      grep -v -Ei \
        '^(name,playeruid,steamid|connected players|showplayers|response|success)' |
      wc -l
  )

  echo "$count / $maximum conectados"
}

header() {
  clear

  echo -e "${CYAN}${BOLD}"
  echo "╔════════════════════════════════════════════════════╗"
  printf "║          BLOODY SERVER MANAGER v%-18s║\n" "$VERSION"
  echo "╚════════════════════════════════════════════════════╝"
  echo -e "${RESET}"

  echo -e "Servidor:        $(status_icon)"
  echo -e "Uptime:          $(uptime_info)"
  echo -e "CPU:             $(cpu_info)"
  echo -e "RAM:             $(ram_info)"
  echo -e "Jugadores:       $(players_count)"
  echo -e "Disco:           $(disk_info)"
  echo -e "Nombre:          $SERVER_LABEL"
  echo -e "IP local:        $LOCAL_IP:$PORT"
  echo -e "Último backup:   $(last_backup)"
  echo -e "Versión:         $(server_version)"

  echo
  echo "══════════════════════════════════════════════════════"
}

create_backup() {
  local date
  local source
  local destination

  date=$(date +%F-%H%M%S)
  source="$SAVE_DIR"
  destination="$BACKUP_DIR/savegames-$date"

  mkdir -p "$BACKUP_DIR"

  if [ ! -d "$source" ]; then
    echo -e "${RED}No se encontró la carpeta de partidas:${RESET}"
    echo "$source"
    return 1
  fi

  echo "Deteniendo servidor..."
  docker compose stop

  echo
  echo "Creando backup en:"
  echo "$destination"

  if cp -a "$source" "$destination"; then
    echo -e "${GREEN}Backup creado correctamente.${RESET}"
  else
    echo -e "${RED}No se pudo crear el backup.${RESET}"
    docker compose start
    return 1
  fi

  echo
  echo "Encendiendo servidor..."

  if docker compose start; then
    echo -e "${GREEN}Backup completado.${RESET}"
    discord_notify "💾 Backup de $SERVER_LABEL completado correctamente.
📁 $(basename "$destination")
🟢 El servidor volvió a encenderse."
  else
    echo -e "${RED}El backup se creó, pero el servidor no pudo encenderse.${RESET}"
    discord_notify "⚠️ El backup de $SERVER_LABEL fue creado, pero el servidor no pudo volver a encenderse."
    return 1
  fi
}

edit_config() {
  local date
  local temp_config
  local backup_config
  local was_online=0

  date=$(date +%F-%H%M%S)
  temp_config="/tmp/PalWorldSettings-$date.ini"
  backup_config="$CONFIG_BACKUP_DIR/PalWorldSettings-$date.ini"

  mkdir -p "$CONFIG_BACKUP_DIR"

  if ! container_exists; then
    echo -e "${RED}El contenedor $SERVER_NAME no existe.${RESET}"
    echo "Inicia el servidor al menos una vez antes de editar."
    pause
    return
  fi

  if is_online; then
    was_online=1
    echo -e "${YELLOW}Deteniendo el servidor para editar con seguridad...${RESET}"

    if ! docker compose stop; then
      echo -e "${RED}No se pudo detener el servidor.${RESET}"
      pause
      return
    fi
  fi

  echo
  echo "Extrayendo configuración desde el contenedor..."

  if ! docker cp \
    "$SERVER_NAME:$CONTAINER_CONFIG" \
    "$temp_config"; then

    echo -e "${RED}No se pudo extraer PalWorldSettings.ini.${RESET}"

    if [ "$was_online" -eq 1 ]; then
      docker compose start
    fi

    rm -f "$temp_config"
    pause
    return
  fi

  cp -a "$temp_config" "$backup_config"

  echo -e "${GREEN}Respaldo creado:${RESET}"
  echo "$backup_config"

  echo
  echo "Abriendo configuración en Nano..."
  echo "Guarda con Ctrl+O, ENTER y sal con Ctrl+X."
  sleep 2

  nano "$temp_config"

  echo
  read -rp "¿Aplicar esta configuración al contenedor? [s/N]: " answer

  case "$answer" in
    s|S|si|SI|sí|Sí)
      if docker cp \
        "$temp_config" \
        "$SERVER_NAME:$CONTAINER_CONFIG"; then

        echo -e "${GREEN}Configuración copiada al contenedor.${RESET}"

        if docker exec "$SERVER_NAME" \
          test -s "$CONTAINER_CONFIG"; then

          echo -e "${GREEN}Archivo verificado correctamente.${RESET}"
        else
          echo -e "${RED}Advertencia: no se pudo verificar el archivo.${RESET}"
        fi

        cp -a "$temp_config" "$LOCAL_CONFIG" 2>/dev/null
      else
        echo -e "${RED}No se pudo copiar la configuración al contenedor.${RESET}"
      fi
      ;;

    *)
      echo -e "${YELLOW}Cambios cancelados.${RESET}"
      echo "El respaldo original permanece guardado."
      ;;
  esac

  rm -f "$temp_config"

  echo
  read -rp "¿Encender el servidor ahora? [S/n]: " start_answer

  case "$start_answer" in
    n|N|no|NO)
      echo -e "${YELLOW}El servidor permanecerá detenido.${RESET}"
      ;;

    *)
      echo "Encendiendo servidor..."
      docker compose start

      if ! is_online; then
        docker compose up -d
      fi

      echo -e "${GREEN}Servidor iniciado.${RESET}"
      ;;
  esac

  pause
}

show_players() {
  local maximum
  local names
  local count

  clear
  echo -e "${CYAN}${BOLD}👥 JUGADORES CONECTADOS${RESET}"
  echo "══════════════════════════════════════════════════════"

  if ! is_online; then
    echo -e "${RED}El servidor está apagado.${RESET}"
    pause
    return
  fi

  maximum=$(max_players)

  names=$(
    docker exec "$SERVER_NAME" rcon-cli ShowPlayers 2>/dev/null |
      tail -n +2 |
      cut -d',' -f1 |
      sed '/^[[:space:]]*$/d'
  )

  if [ -z "$names" ]; then
    echo
    echo -e "${YELLOW}No hay jugadores conectados.${RESET}"
    echo
    echo "Jugadores: 0 / $maximum"
  else
    count=$(printf '%s\n' "$names" | wc -l)

    echo
    echo -e "${GREEN}Jugadores: $count / $maximum${RESET}"
    echo

    while IFS= read -r player; do
      printf '  • %s\n' "$player"
    done <<< "$names"
  fi

  echo
  echo "══════════════════════════════════════════════════════"
  pause
}

while true; do
  header

  echo "1) Iniciar servidor"
  echo "2) Detener servidor"
  echo "3) Reiniciar servidor"
  echo "4) Crear backup"
  echo "5) Ver logs en vivo"
  echo "6) Editar configuración"
  echo "7) Ver jugadores conectados"
  echo "8) Actualizar imagen Docker"
  echo "0) Salir"

  echo
  read -rp "Selecciona una opción: " op

  case "$op" in
    1)
      if docker compose up -d; then
        discord_notify "🟢 $SERVER_LABEL está en línea.
🎮 Servidor: $SERVER_LABEL
👥 Capacidad: $(max_players) jugadores"
      else
        discord_notify "❌ No se pudo iniciar el servidor $SERVER_LABEL."
      fi
      pause
      ;;

    2)
      if docker compose stop; then
        discord_notify "🔴 El servidor $SERVER_LABEL fue detenido."
      else
        discord_notify "❌ No se pudo detener el servidor $SERVER_LABEL."
      fi
      pause
      ;;

    3)
      if docker compose restart; then
        discord_notify "🔄 El servidor $SERVER_LABEL fue reiniciado.
🎮 Servidor: $SERVER_LABEL"
      else
        discord_notify "❌ No se pudo reiniciar el servidor $SERVER_LABEL."
      fi
      pause
      ;;

    4)
      create_backup
      pause
      ;;

    5)
      docker logs -f "$SERVER_NAME"
      ;;

    6)
      edit_config
      ;;

    7)
      show_players
      ;;

    8)
      echo "Creando backup antes de actualizar..."

      if create_backup; then
        echo
        echo "Descargando imagen nueva..."
        docker compose pull

        echo
        echo "Recreando contenedor..."
        docker compose up -d
      else
        echo -e "${RED}Actualización cancelada porque falló el backup.${RESET}"
      fi

      pause
      ;;

    0)
      clear
      echo "Saliendo de Bloody Server Manager v$VERSION..."
      exit 0
      ;;

    *)
      echo "Opción inválida."
      pause
      ;;
  esac
done
