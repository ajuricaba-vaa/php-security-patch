#!/usr/bin/env bash
# =============================================================================
#  php-security-patch.sh  v2.0
#
#  Atualização de segurança do PHP (>= 8.x) com três caminhos à escolha do usuário:
#
#   1) PATCH DA DISTRO     – mantém o branch e aplica o que o repositório atual
#                            oferece (backports de segurança da distro). Menor risco.
#   2) RELEASE OFICIAL     – mantém o branch e instala exatamente o último release
#                            publicado em php.net (adiciona ondrej/sury/Remi).
#   3) MIGRAR DE BRANCH    – instala um branch superior (ex.: 8.3 -> 8.4).
#                            Debian/Ubuntu: lado a lado, testa o código antes de
#                            trocar e mantém o PHP antigo instalado para rollback.
#
#  Repositórios com os releases oficiais do php.net:
#    Ubuntu .................. PPA ondrej/php
#    Debian .................. packages.sury.org/php
#    RHEL/Oracle/Rocky/Alma .. Remi (rpms.remirepo.net) + EPEL + CRB
#    Fedora .................. Remi
#
#  Toda execução gera backup em /var/backups/php-patch/<data-hora> e permite
#  rollback automático (se a validação falhar) ou manual (--rollback DIR).
#
#  Autor:    José Ajuricaba Brito da Costa e Silva — @ajuricabacosta · ajuricaba.net
#  Licença:  MIT (ver LICENSE)
#
#  AVISO: este script é fornecido "COMO ESTÁ", sem garantias de qualquer tipo.
#  O uso é de inteira responsabilidade de quem o executa. O autor não se
#  responsabiliza por falhas, perda de dados ou indisponibilidade de serviços.
#  Antes de rodar: faça backup das configurações, dos sites e dos bancos de
#  dados, e teste primeiro em um servidor de homologação.
# =============================================================================
set -o pipefail

SCRIPT_VERSION="2.1"
TS="$(date +%Y%m%d-%H%M%S)"
BACKUP_ROOT="/var/backups/php-patch"
BACKUP_DIR="$BACKUP_ROOT/$TS"
LOG="/var/log/php-security-patch-$TS.log"

DRY_RUN=0
ASSUME_YES=0
MODE=""            # distro | official | upgrade
TARGET=""          # branch de destino no modo upgrade (ex.: 8.4)
HEALTH_URL=""
APP_DIR=""
PROBE_BASE=""
PROBE_HOST=""
MANUAL_ROLLBACK_DIR=""
UPGRADE_STARTED=0

declare -A UPSTREAM=()
declare -A PKG_VER=()
PKGS=()
SERVICES=()

# Diretivas de php.ini levadas do branch antigo para o novo na migração
INI_DIRECTIVES=(memory_limit upload_max_filesize post_max_size max_execution_time
  max_input_time max_input_vars max_file_uploads date.timezone display_errors
  display_startup_errors log_errors error_log error_reporting short_open_tag
  expose_php allow_url_fopen disable_functions session.gc_maxlifetime
  session.save_path session.cookie_secure session.cookie_httponly
  realpath_cache_size opcache.enable opcache.enable_cli opcache.memory_consumption
  opcache.interned_strings_buffer opcache.max_accelerated_files
  opcache.validate_timestamps opcache.revalidate_freq)

# -----------------------------------------------------------------------------
# Saída / interação
# -----------------------------------------------------------------------------
if [ -t 1 ]; then
  C_R=$'\e[31m'; C_G=$'\e[32m'; C_Y=$'\e[33m'; C_B=$'\e[36m'; C_0=$'\e[0m'; C_BOLD=$'\e[1m'
else
  C_R=""; C_G=""; C_Y=""; C_B=""; C_0=""; C_BOLD=""
fi

log()   { echo -e "$*" | tee -a "$LOG"; }
info()  { log "${C_B}[INFO]${C_0} $*"; }
ok()    { log "${C_G}[ OK ]${C_0} $*"; }
warn()  { log "${C_Y}[AVISO]${C_0} $*"; }
err()   { log "${C_R}[ERRO]${C_0} $*"; }
die()   { err "$*"; exit 1; }
title() { log "\n${C_BOLD}==== $* ====${C_0}"; }

# Executa comando registrando no log
run() { echo "+ $*" >>"$LOG"; "$@" >>"$LOG" 2>&1; }

# ask "pergunta" [S|N] -> 0 = sim
ask() {
  local q="$1" def="${2:-N}" ans hint
  [ "$def" = "S" ] && hint="[S/n]" || hint="[s/N]"
  if [ "$ASSUME_YES" -eq 1 ]; then
    log "${C_Y}?${C_0} $q $hint -> S (--yes)"; return 0
  fi
  read -r -p "$(echo -e "${C_Y}?${C_0} $q $hint ") " ans </dev/tty
  ans="${ans:-$def}"
  echo "  resposta: $ans" >>"$LOG"
  [[ "$ans" =~ ^[sSyY] ]]
}

# prompt "texto" VAR  (não pergunta em --yes)
prompt() {
  local __v
  [ "$ASSUME_YES" -eq 1 ] && return 0
  read -r -p "$1" __v </dev/tty
  echo "  resposta: $__v" >>"$LOG"
  printf -v "$2" '%s' "$__v"
}

usage() {
  cat <<EOF
php-security-patch.sh v$SCRIPT_VERSION

Uso: sudo $0 [opções]

  --mode MODO          distro | official | upgrade  (sem isso, mostra o menu)
  --target X.Y         Branch de destino no modo upgrade (ex.: 8.4)
  --app-dir DIR        Diretório da aplicação (raiz do site). Usado para checar a
                       sintaxe do código no PHP novo e para o teste de versão web
  --probe-url URL      URL que aponta para --app-dir (ex.: http://localhost/).
                       O script cria um arquivo temporário e confere qual versão
                       do PHP o servidor web está usando de fato
  --url URL            URL de health check (espera HTTP 2xx/3xx)
  --dry-run            Mostra o plano, sem alterar nada
  -y, --yes            Responde "sim" a tudo (automação)
  --rollback DIR       Reverte a partir de um backup anterior
  -h, --help           Esta ajuda

Backups: $BACKUP_ROOT/<data-hora>   Logs: /var/log/php-security-patch-*.log
EOF
}

# -----------------------------------------------------------------------------
# Utilitários
# -----------------------------------------------------------------------------
version_lt() {
  [ "$1" != "$2" ] && [ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | head -n1)" = "$1" ]
}

# 2:8.3.12-1+ubuntu24.04.1+deb.sury.org+1 -> 8.3.12
upstream_of() {
  echo "$1" | sed -E 's/^[0-9]+://; s/[-+~].*$//'
}

# Avalia código PHP com $j = JSON lido do stdin (usa qualquer PHP disponível)
php_eval() {
  "${PHP_ANY:-php}" -r '$j=json_decode(stream_get_contents(STDIN),true); if(!is_array($j)){exit(1);} '"$1" 2>/dev/null
}

aptq() {
  DEBIAN_FRONTEND=noninteractive apt-get -y \
    -o Dpkg::Options::=--force-confold -o Dpkg::Options::=--force-confdef "$@"
}

apt_candidate() { apt-cache policy "$1" 2>/dev/null | awk '/Candidate:/{print $2; exit}'; }
apt_installed() { dpkg-query -W -f='${Status}' "$1" 2>/dev/null | grep -q "install ok installed"; }

rpm_candidate() {
  $PM -q repoquery --latest-limit 1 --qf '%{version}-%{release}\n' "$1" 2>/dev/null \
    | grep -E '^[0-9]' | tail -n1
}
rpm_current_stream() {
  $PM -q module list --enabled php 2>/dev/null | awk '$1=="php"{print $2; exit}'
}
rpm_stream_exists() {
  $PM -q module list php 2>/dev/null | awk '$1=="php"{print $2}' | grep -qx "$1"
}

refresh_repos() {
  if [ "$PM" = "apt" ]; then
    run apt-get update || warn "apt-get update retornou erro (ver log)."
  else
    run $PM -q makecache || warn "makecache retornou erro (ver log)."
  fi
}

meta() { echo "$1" >>"$BACKUP_DIR/meta.env"; }

on_interrupt() {
  echo
  err "Execução interrompida."
  if [ "$UPGRADE_STARTED" -eq 1 ]; then
    warn "A alteração pode ter ficado incompleta."
    warn "Para reverter: sudo $0 --rollback $BACKUP_DIR"
  fi
  exit 130
}
trap on_interrupt INT TERM

# -----------------------------------------------------------------------------
# Detecção do sistema e do PHP
# -----------------------------------------------------------------------------
require_root() { [ "$(id -u)" -eq 0 ] || { echo "Execute como root (sudo)."; exit 1; }; }

detect_os() {
  [ -r /etc/os-release ] || die "/etc/os-release ausente — sistema não identificado."
  # shellcheck disable=SC1091
  . /etc/os-release
  OS_NAME="${PRETTY_NAME:-$ID}"
  OS_ID="$ID"
  OS_VER="${VERSION_ID:-}"
  EL_MAJOR="${OS_VER%%.*}"
  OS_CODENAME="${UBUNTU_CODENAME:-${VERSION_CODENAME:-}}"

  case "$ID" in
    ubuntu) DISTRO=ubuntu ;;
    debian) DISTRO=debian ;;
    fedora) DISTRO=fedora ;;
    rhel|ol|rocky|almalinux|centos) DISTRO=el ;;
    *)
      case " $ID_LIKE " in
        *" ubuntu "*) DISTRO=ubuntu ;;
        *" debian "*) DISTRO=debian ;;
        *" rhel "*|*" centos "*|*" fedora "*) DISTRO=el ;;
        *) die "Distribuição não suportada: $OS_NAME" ;;
      esac ;;
  esac

  if [ "$DISTRO" = "ubuntu" ] || [ "$DISTRO" = "debian" ]; then
    PM=apt
  elif command -v dnf >/dev/null 2>&1; then
    PM=dnf
  else
    PM=yum
  fi
  ok "Sistema: $OS_NAME (gerenciador: $PM)"
}

detect_php() {
  local bins=() b v choice i
  for b in /usr/bin/php[0-9].[0-9] /usr/bin/php; do [ -x "$b" ] && bins+=("$b"); done
  [ ${#bins[@]} -gt 0 ] || die "Nenhum binário PHP encontrado."

  declare -gA BRANCH_BIN=()
  for b in "${bins[@]}"; do
    v="$("$b" -r 'echo PHP_MAJOR_VERSION.".".PHP_MINOR_VERSION;' 2>/dev/null)" || continue
    [ -n "$v" ] || continue
    if [ "${v%%.*}" -lt 8 ] 2>/dev/null; then
      warn "PHP $v em $b ignorado (script atua apenas em PHP >= 8)."; continue
    fi
    [ -z "${BRANCH_BIN[$v]}" ] && BRANCH_BIN[$v]="$b"
  done
  [ ${#BRANCH_BIN[@]} -gt 0 ] || die "Nenhum PHP 8.x ou superior encontrado."

  local branches=()
  mapfile -t branches < <(printf '%s\n' "${!BRANCH_BIN[@]}" | sort -V)
  if [ ${#branches[@]} -eq 1 ] || [ "$ASSUME_YES" -eq 1 ]; then
    BRANCH="${branches[-1]}"
  else
    log "\nInstalações de PHP encontradas:"
    for i in "${!branches[@]}"; do log "  $((i+1))) PHP ${branches[$i]}  (${BRANCH_BIN[${branches[$i]}]})"; done
    read -r -p "Qual branch deseja tratar? [1-${#branches[@]}] " choice </dev/tty
    [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -le ${#branches[@]} ] || die "Opção inválida."
    BRANCH="${branches[$((choice-1))]}"
  fi

  PHP_BIN="${BRANCH_BIN[$BRANCH]}"
  PHP_ANY="$PHP_BIN"
  PHP_VER="$("$PHP_BIN" -r 'echo PHP_VERSION;')"
  ok "PHP selecionado: $PHP_VER ($PHP_BIN)"

  local real; real="$(readlink -f "$PHP_BIN")"
  if [ "$PM" = "apt" ]; then
    dpkg -S "$real" >/dev/null 2>&1 || die "$real não pertence a nenhum pacote (compilado da fonte?)."
  else
    rpm -qf "$real" >/dev/null 2>&1 || die "$real não pertence a nenhum pacote (compilado da fonte?)."
  fi
}

# -----------------------------------------------------------------------------
# php.net
# -----------------------------------------------------------------------------
upstream_latest() {
  local b="$1" json
  if [ -z "${UPSTREAM[$b]+x}" ]; then
    json="$(curl -fsS --max-time 20 "https://www.php.net/releases/index.php?json&version=$b" 2>>"$LOG")"
    UPSTREAM[$b]="$(echo "$json" | php_eval 'echo $j["version"] ?? "";')"
  fi
  echo "${UPSTREAM[$b]}"
}

load_states() {
  STATES_JSON="$(curl -fsS --max-time 20 "https://www.php.net/releases/states.php" 2>>"$LOG")"
}

# Imprime: branch estado fim_seguranca   (todos os branches suportados)
supported_branches() {
  echo "$STATES_JSON" | php_eval 'foreach($j as $maj=>$bs){ foreach($bs as $b=>$i){ echo $b," ",$i["state"]??"?"," ",substr($i["security_support_end"]??"",0,10),"\n"; } }' | sort -V
}

branch_state() {
  supported_branches | awk -v b="$1" '$1==b{print $2" "$3; f=1} END{if(!f) print "eol -"}'
}

check_upstream() {
  title "Consultando php.net"
  command -v curl >/dev/null 2>&1 || die "curl não instalado."
  load_states
  UPSTREAM_LATEST="$(upstream_latest "$BRANCH")"
  if [ -n "$UPSTREAM_LATEST" ]; then
    ok "Último release oficial do branch $BRANCH: $UPSTREAM_LATEST"
  else
    warn "Não foi possível consultar o php.net."
  fi
  if [ -n "$STATES_JSON" ]; then
    read -r BRANCH_STATE BRANCH_SECEND <<<"$(branch_state "$BRANCH")"
    case "$BRANCH_STATE" in
      stable)   ok "Branch $BRANCH com suporte ativo (segurança até $BRANCH_SECEND)." ;;
      security) warn "Branch $BRANCH só recebe correções de segurança (até $BRANCH_SECEND)." ;;
      *)        warn "Branch $BRANCH em FIM DE VIDA: o PHP não publica mais correções. Recomenda-se migrar (opção 3)." ;;
    esac
  fi
}

# -----------------------------------------------------------------------------
# Pacotes
# -----------------------------------------------------------------------------
collect_packages() {
  title "Pacotes PHP instalados"
  PKGS=(); PKG_VER=()
  local name ver
  if [ "$PM" = "apt" ]; then
    while IFS=$'\t' read -r name ver; do PKGS+=("$name"); PKG_VER[$name]="$ver"; done < <(
      dpkg-query -W -f='${db:Status-Abbrev}\t${binary:Package}\t${Version}\n' 2>/dev/null \
      | awk -F'\t' -v b="$BRANCH" '$1 ~ /^ii/ && ($2 ~ "^php"b"(-|:|$)" || $2 ~ "^libapache2-mod-php"b"(:|$)") {print $2"\t"$3}')
    MAIN_PKG="php${BRANCH}-cli"
  else
    while IFS=$'\t' read -r name ver; do PKGS+=("$name"); PKG_VER[$name]="$ver"; done < <(
      rpm -qa --qf '%{NAME}\t%{VERSION}-%{RELEASE}\n' 2>/dev/null | awk -F'\t' '$1=="php" || $1 ~ /^php-/' | sort -u)
    MAIN_PKG="php-cli"
  fi
  [ ${#PKGS[@]} -gt 0 ] || die "Nenhum pacote PHP $BRANCH encontrado."
  [ -n "${PKG_VER[$MAIN_PKG]}" ] || MAIN_PKG="${PKGS[0]}"
  for name in "${PKGS[@]}"; do log "  - $name  ${PKG_VER[$name]}"; done
  info "Total: ${#PKGS[@]} pacotes"
}

show_distro_cves() {
  local cves
  if [ "$PM" = "apt" ]; then
    cves="$(timeout 30 apt-get changelog "${MAIN_PKG%%:*}" 2>/dev/null | grep -oE 'CVE-[0-9]{4}-[0-9]+' | sort -u)"
  else
    cves="$(rpm -q --changelog "$MAIN_PKG" 2>/dev/null | grep -oE 'CVE-[0-9]{4}-[0-9]+' | sort -u)"
  fi
  if [ -n "$cves" ]; then
    info "O pacote da distro registra $(echo "$cves" | wc -l) CVEs corrigidas por backport. Mais recentes:"
    log "    $(echo "$cves" | sort -t- -k2,2n -k3,3n | tail -n 8 | tr '\n' ' ')"
  fi
}

detect_services() {
  SERVICES=()
  mapfile -t SERVICES < <(systemctl list-units --type=service --state=running --no-legend --plain 2>/dev/null \
    | awk '{print $1}' | grep -E '^(php.*fpm|apache2|httpd|nginx|lsws|lshttpd)\.service$')
  if [ ${#SERVICES[@]} -gt 0 ]; then info "Serviços ativos: ${SERVICES[*]}"
  else warn "Nenhum serviço PHP-FPM/Apache/Nginx em execução detectado."; fi
}

restart_services() {
  local s rc=0
  for s in "${SERVICES[@]}"; do
    [ -n "$s" ] || continue
    if systemctl restart "$s" >>"$LOG" 2>&1 && systemctl is-active --quiet "$s"; then
      ok "Serviço $s reiniciado e ativo."
    else
      err "Serviço $s falhou ao reiniciar."; rc=1
    fi
  done
  return $rc
}

# -----------------------------------------------------------------------------
# Verificações de segurança antes de qualquer mudança
# -----------------------------------------------------------------------------
preflight() {
  title "Verificações de segurança"
  local free held
  free="$(df -Pm /var | awk 'NR==2{print $4}')"
  if [ "${free:-0}" -ge 1024 ]; then ok "Espaço livre em /var: ${free} MB"
  else warn "Pouco espaço em /var (${free} MB). Recomendado >= 1024 MB."; ask "Continuar?" || exit 1; fi

  if [ "$PM" = "apt" ]; then
    [ -z "$(dpkg --audit 2>/dev/null)" ] || die "dpkg com pacotes inconsistentes. Rode 'dpkg --configure -a' / 'apt -f install' antes."
    held="$(apt-mark showhold 2>/dev/null | grep -E '^(php|libapache2-mod-php)')"
    [ -z "$held" ] || warn "Pacotes PHP marcados como 'hold' (não serão atualizados): $(echo "$held" | tr '\n' ' ')"
  fi

  if ! ask "Existe snapshot/backup recente desta máquina (recomendado)?" S; then
    warn "Sem snapshot, o rollback depende só do backup de pacotes deste script."
    ask "Prosseguir mesmo assim?" || exit 1
  fi
}

init_backup_dir() {
  mkdir -p "$BACKUP_DIR" && chmod 700 "$BACKUP_ROOT" "$BACKUP_DIR"
  {
    echo "PM=$PM"; echo "DISTRO=$DISTRO"; echo "MODE=$MODE"
    echo "OLD_BRANCH=$BRANCH"; echo "PHP_BIN=$PHP_BIN"; echo "PHP_VER=$PHP_VER"
  } >"$BACKUP_DIR/meta.env"
  [ "$PM" = "apt" ] && ls -1 /etc/apt/sources.list.d >"$BACKUP_DIR/sources.before" 2>/dev/null
  if [ "$PM" != "apt" ]; then meta "OLD_STREAM=$(rpm_current_stream)"; fi
}

# -----------------------------------------------------------------------------
# Repositórios com os releases oficiais do php.net
# -----------------------------------------------------------------------------
official_repo_name() {
  case "$DISTRO" in
    ubuntu) echo "PPA ondrej/php" ;;
    debian) echo "packages.sury.org/php" ;;
    *)      echo "Remi (rpms.remirepo.net)" ;;
  esac
}

official_repo_present() {
  case "$DISTRO" in
    ubuntu) grep -rqsE 'ondrej/php' /etc/apt/sources.list /etc/apt/sources.list.d ;;
    debian) grep -rqs 'packages.sury.org/php' /etc/apt/sources.list /etc/apt/sources.list.d ;;
    *)      rpm -q remi-release >/dev/null 2>&1 ;;
  esac
}

add_official_repo() {
  title "Repositório de releases oficiais: $(official_repo_name)"
  if official_repo_present; then ok "Já configurado."; return 0; fi

  warn "É um repositório de terceiros, mantido fora da sua distro."
  if [ "$PM" = "apt" ]; then
    warn "O php.net informa que esses binários contêm patches próprios do mantenedor,"
    warn "fora do controle do projeto PHP. Revise antes de usar em produção."
  else
    warn "Serão habilitados também EPEL e CodeReady Builder (dependências do Remi)."
  fi
  ask "Adicionar o repositório agora?" S || return 1
  if [ "$DRY_RUN" -eq 1 ]; then info "(dry-run) repositório não adicionado."; return 0; fi

  UPGRADE_STARTED=1
  case "$DISTRO" in
    ubuntu)
      run aptq install software-properties-common ca-certificates curl gnupg || return 1
      LC_ALL=C.UTF-8 run add-apt-repository -y ppa:ondrej/php || return 1
      ;;
    debian)
      run aptq install lsb-release ca-certificates curl || return 1
      run curl -fsSLo "$BACKUP_DIR/debsuryorg-archive-keyring.deb" https://packages.sury.org/debsuryorg-archive-keyring.deb || return 1
      run dpkg -i "$BACKUP_DIR/debsuryorg-archive-keyring.deb" || return 1
      cat >/etc/apt/sources.list.d/php.sources <<EOF
Types: deb
URIs: https://packages.sury.org/php/
Suites: $OS_CODENAME
Components: main
Signed-By: /usr/share/keyrings/debsuryorg-archive-keyring.gpg
EOF
      meta "SURY_KEYRING_ADDED=1"
      ;;
    el)
      run $PM install -y dnf-plugins-core || true
      if ! rpm -q epel-release >/dev/null 2>&1 && ! rpm -q "oracle-epel-release-el$EL_MAJOR" >/dev/null 2>&1; then
        case "$OS_ID" in
          ol)   run $PM install -y "oracle-epel-release-el$EL_MAJOR" ;;
          rhel) run $PM install -y "https://dl.fedoraproject.org/pub/epel/epel-release-latest-$EL_MAJOR.noarch.rpm" ;;
          *)    run $PM install -y epel-release ;;
        esac || return 1
      fi
      case "$OS_ID" in
        ol)   run $PM config-manager --set-enabled "ol${EL_MAJOR}_codeready_builder" ;;
        rhel) run subscription-manager repos --enable "codeready-builder-for-rhel-${EL_MAJOR}-$(arch)-rpms" ;;
        *)    if [ "$EL_MAJOR" = "8" ]; then run $PM config-manager --set-enabled powertools
              else run $PM config-manager --set-enabled crb; fi ;;
      esac || warn "Não foi possível habilitar o CodeReady Builder (algumas extensões podem faltar)."
      run $PM install -y "https://rpms.remirepo.net/enterprise/remi-release-${EL_MAJOR}.rpm" || return 1
      meta "REMI_ADDED=1"
      ;;
    fedora)
      run dnf install -y "https://rpms.remirepo.net/fedora/remi-release-$(rpm -E %fedora).rpm" || return 1
      meta "REMI_ADDED=1"
      ;;
  esac
  meta "OFFICIAL_REPO_ADDED=1"
  [ "$PM" = "apt" ] && ls -1 /etc/apt/sources.list.d >"$BACKUP_DIR/sources.after" 2>/dev/null
  refresh_repos
  ok "Repositório $(official_repo_name) adicionado."
}

remove_official_repo() {
  local dir="$1" f
  [ "${OFFICIAL_REPO_ADDED:-0}" = "1" ] || return 0
  ask "Remover também o repositório $(official_repo_name) adicionado por este script?" S || return 0
  if [ "$PM" = "apt" ]; then
    if [ -f "$dir/sources.before" ] && [ -f "$dir/sources.after" ]; then
      comm -13 <(sort "$dir/sources.before") <(sort "$dir/sources.after") | while read -r f; do
        [ -n "$f" ] && run rm -f "/etc/apt/sources.list.d/$f"
      done
    fi
    [ "${SURY_KEYRING_ADDED:-0}" = "1" ] && run dpkg -r debsuryorg-archive-keyring
    run apt-get update
  else
    [ "${REMI_ADDED:-0}" = "1" ] && run $PM remove -y remi-release
    info "EPEL/CRB foram mantidos (podem ser usados por outros pacotes)."
  fi
  ok "Repositório removido."
}

# -----------------------------------------------------------------------------
# Backup
# -----------------------------------------------------------------------------
do_backup() {
  title "Backup"
  local p v f got=0 cfg=() c
  for p in "${PKGS[@]}"; do printf '%s\t%s\n' "$p" "${PKG_VER[$p]}"; done >"$BACKUP_DIR/packages.before.tsv"
  printf '%s\n' "${SERVICES[@]}" >"$BACKUP_DIR/services.txt"
  "$PHP_BIN" -v >"$BACKUP_DIR/php-v.before.txt" 2>&1
  "$PHP_BIN" -m 2>/dev/null | grep -v '^\[' | sed '/^$/d' | sort -u >"$BACKUP_DIR/modules.before.txt"

  if [ "$PM" = "apt" ]; then
    [ -d /etc/php ] && cfg+=(/etc/php)
  else
    for c in /etc/php.ini /etc/php.d /etc/php-fpm.conf /etc/php-fpm.d /etc/httpd/conf.d/php.conf; do
      [ -e "$c" ] && cfg+=("$c")
    done
  fi
  for c in /etc/apache2 /etc/httpd /etc/nginx; do [ -d "$c" ] && cfg+=("$c"); done
  if [ ${#cfg[@]} -gt 0 ]; then
    tar -czpf "$BACKUP_DIR/config.tar.gz" "${cfg[@]}" 2>>"$LOG" && ok "Configurações salvas: ${cfg[*]}"
  fi

  if [ "$PM" = "apt" ]; then
    mkdir -p "$BACKUP_DIR/debs"
    for p in "${PKGS[@]}"; do
      v="${PKG_VER[$p]}"
      if (cd "$BACKUP_DIR/debs" && apt-get download "${p%%:*}=$v" >>"$LOG" 2>&1); then got=$((got+1)); continue; fi
      f="$(find /var/cache/apt/archives -maxdepth 1 -name "${p%%:*}_${v//:/%3a}_*.deb" 2>/dev/null | head -n1)"
      if [ -n "$f" ]; then cp -p "$f" "$BACKUP_DIR/debs/" && got=$((got+1)); continue; fi
      if command -v dpkg-repack >/dev/null 2>&1 && (cd "$BACKUP_DIR/debs" && dpkg-repack "${p%%:*}" >>"$LOG" 2>&1); then
        got=$((got+1)); continue
      fi
      warn "Não foi possível guardar o .deb de $p $v"
    done
  else
    mkdir -p "$BACKUP_DIR/rpms"
    local nevra=()
    for p in "${PKGS[@]}"; do nevra+=("$p-${PKG_VER[$p]}"); done
    if [ "$PM" = "dnf" ]; then
      run dnf download --destdir "$BACKUP_DIR/rpms" "${nevra[@]}"
    elif command -v yumdownloader >/dev/null 2>&1; then
      run yumdownloader --destdir "$BACKUP_DIR/rpms" "${nevra[@]}"
    fi
    got="$(find "$BACKUP_DIR/rpms" -name '*.rpm' | wc -l)"
  fi

  if [ "$got" -ge ${#PKGS[@]} ]; then
    ok "Pacotes atuais salvos ($got/${#PKGS[@]}) — rollback offline garantido."
  else
    warn "Apenas $got de ${#PKGS[@]} pacotes atuais foram salvos; o restante depende do repositório."
    ask "Continuar mesmo assim?" || exit 1
  fi
  ok "Backup em: $BACKUP_DIR"
}

# -----------------------------------------------------------------------------
# Testes
# -----------------------------------------------------------------------------
# Verifica sintaxe dos .php do APP_DIR com um binário. Grava a lista de arquivos com erro.
lint_files() {
  local bin="$1" out="$2"
  find "$APP_DIR" -type f -name '*.php' -not -path '*/node_modules/*' -print0 2>/dev/null \
    | xargs -0 -r -n 1 -P "$(nproc 2>/dev/null || echo 2)" "$bin" -d display_errors=1 -l 2>&1 \
    | grep -E '^(Errors parsing|PHP Deprecated|Deprecated)' >"$out"
}

# lint_compare OLD_BIN NEW_BIN  -> 0 sem regressões
lint_compare() {
  local old_bin="$1" new_bin="$2" total regress deps
  [ -n "$APP_DIR" ] && [ -d "$APP_DIR" ] || return 0
  title "Teste de compatibilidade do código ($APP_DIR)"
  total="$(find "$APP_DIR" -type f -name '*.php' -not -path '*/node_modules/*' 2>/dev/null | wc -l)"
  info "Verificando $total arquivos .php (pode levar alguns minutos)..."
  lint_files "$new_bin" "$BACKUP_DIR/lint.new.txt"
  if [ -n "$old_bin" ]; then
    lint_files "$old_bin" "$BACKUP_DIR/lint.old.txt"
  else
    : >"$BACKUP_DIR/lint.old.txt"
  fi
  regress="$(comm -13 <(grep '^Errors parsing' "$BACKUP_DIR/lint.old.txt" | sort -u) \
                      <(grep '^Errors parsing' "$BACKUP_DIR/lint.new.txt" | sort -u))"
  deps="$(grep -ciE 'deprecated' "$BACKUP_DIR/lint.new.txt")"
  [ "$deps" -gt 0 ] && warn "$deps avisos de 'Deprecated' no PHP novo (ver $BACKUP_DIR/lint.new.txt)."
  if [ -n "$regress" ]; then
    err "$(echo "$regress" | wc -l) arquivos passam a ter ERRO DE SINTAXE no PHP novo:"
    echo "$regress" | head -n 15 | sed 's/^Errors parsing /    /' | tee -a "$LOG"
    return 1
  fi
  ok "Nenhuma regressão de sintaxe encontrada."
  warn "O teste cobre sintaxe; comportamento em tempo de execução deve ser testado na aplicação."
  return 0
}

# Confere qual versão do PHP o servidor web realmente executa.
# probe_web BRANCH [quiet]  -> 0 versão certa | 1 versão errada | 2 inconclusivo
probe_web() {
  local expect="$1" quiet="${2:-}" name f out got code hdr=()
  [ -n "$APP_DIR" ] && [ -n "$PROBE_BASE" ] || return 0
  name=".php-patch-probe-$RANDOM$RANDOM.php"
  f="${APP_DIR%/}/$name"
  if ! echo '<?php echo PHP_VERSION;' >"$f" 2>/dev/null; then
    [ -n "$quiet" ] || warn "Não foi possível criar o arquivo de teste em $APP_DIR."
    return 2
  fi
  chmod 644 "$f"; chown --reference="$APP_DIR" "$f" 2>/dev/null
  [ -n "$PROBE_HOST" ] && hdr=(-H "Host: $PROBE_HOST")
  out="$(curl -ksS --max-time 15 "${hdr[@]}" -w '\n%{http_code}' "${PROBE_BASE%/}/$name" 2>>"$LOG")"
  rm -f "$f"
  code="${out##*$'\n'}"; got="${out%$'\n'*}"
  echo "probe: url=${PROBE_BASE%/}/$name host=${PROBE_HOST:-} http=$code body=${got:0:80}" >>"$LOG"

  if [ "$code" != "200" ] || ! [[ "$got" =~ ^[0-9]+\.[0-9]+\.[0-9]+ ]]; then
    [ -n "$quiet" ] || warn "Teste de versão web inconclusivo (HTTP ${code:-sem resposta}): a URL não executou o arquivo de teste."
    return 2
  fi
  if [[ "$got" == "$expect".* ]]; then
    [ -n "$quiet" ] || ok "O servidor web está executando PHP $got"
    return 0
  fi
  [ -n "$quiet" ] || err "O servidor web está executando PHP $got (esperado $expect.x)."
  return 1
}

# Procura o VirtualHost (Apache/Nginx) que serve APP_DIR. Imprime "host|caminho".
detect_vhost() {
  local dir="${APP_DIR%/}" f d host best_len=0 best=""
  for f in /etc/apache2/sites-enabled/* /etc/httpd/conf.d/*.conf /etc/nginx/sites-enabled/* /etc/nginx/conf.d/*.conf; do
    [ -f "$f" ] || continue
    while read -r d; do
      d="${d%/}"
      [ -n "$d" ] || continue
      if [ "$dir" = "$d" ] || [[ "$dir" == "$d"/* ]]; then
        if [ ${#d} -gt "$best_len" ]; then
          host="$(grep -iE '^[[:space:]]*(ServerName|server_name)[[:space:]]' "$f" | head -n1 | awk '{print $2}' | tr -d ';')"
          best_len=${#d}; best="${host:-localhost}|${dir#"$d"}"
        fi
      fi
    done < <(grep -iE '^[[:space:]]*(DocumentRoot|root)[[:space:]]' "$f" | awk '{print $2}' | tr -d '";')
  done
  [ -n "$best" ] && echo "$best"
}

# Valida o teste de versão web ANTES de qualquer alteração
precheck_probe() {
  local rc vh host path
  [ -n "$APP_DIR" ] && [ -n "$PROBE_BASE" ] || return 0
  info "Conferindo se $PROBE_BASE serve $APP_DIR..."
  probe_web "$BRANCH" quiet; rc=$?
  if [ $rc -eq 2 ]; then
    vh="$(detect_vhost)"
    if [ -n "$vh" ]; then
      IFS='|' read -r host path <<<"$vh"
      PROBE_HOST="$host"; PROBE_BASE="http://127.0.0.1${path}"
      info "Tentando pelo VirtualHost '$host' (http://$host${path}/)..."
      probe_web "$BRANCH" quiet; rc=$?
    fi
  fi
  case $rc in
    0) ok "Teste de versão web funcionando (servidor executa PHP $BRANCH)." ;;
    1) warn "O servidor web NÃO está usando o PHP $BRANCH para $APP_DIR — confira a configuração antes de continuar."
       ask "Continuar mesmo assim?" || exit 0 ;;
    *) warn "A URL $PROBE_BASE não serve o diretório $APP_DIR. Teste de versão web desativado."
       warn "Informe em --probe-url a URL do site que corresponde ao --app-dir."
       PROBE_BASE=""; PROBE_HOST="" ;;
  esac
}

# validate BRANCH_ESPERADO
validate() {
  local expect="$1" fail=0 new_ver missing fpm code
  title "Validação"
  if new_ver="$("$PHP_BIN" -r 'echo PHP_VERSION;' 2>>"$LOG")" && [[ "$new_ver" == "$expect".* ]]; then
    ok "PHP CLI executa: $new_ver (antes: $PHP_VER)"
  else
    err "PHP CLI não executa ou versão inesperada (${new_ver:-falhou}, esperado $expect.x)."; return 1
  fi

  "$PHP_BIN" -m 2>/dev/null | grep -v '^\[' | sed '/^$/d' | sort -u >"$BACKUP_DIR/modules.after.txt"
  missing="$(comm -23 "$BACKUP_DIR/modules.before.txt" "$BACKUP_DIR/modules.after.txt")"
  if [ -n "$missing" ]; then err "Módulos ausentes agora: $(echo "$missing" | tr '\n' ' ')"; fail=1
  else ok "Todos os módulos anteriores estão carregados."; fi

  if "$PHP_BIN" -r 'exit(0);' 2>&1 | grep -qiE 'warning|error'; then
    err "PHP emite avisos/erros ao iniciar (rode: $PHP_BIN -r 'exit(0);')."; fail=1
  fi

  for fpm in "php-fpm$expect" php-fpm; do
    if command -v "$fpm" >/dev/null 2>&1; then
      if run "$fpm" -t; then ok "Configuração do $fpm válida."
      else err "Teste do $fpm falhou."; fail=1; fi
      break
    fi
  done
  if command -v apachectl >/dev/null 2>&1 && printf '%s\n' "${SERVICES[@]}" | grep -qE '^(apache2|httpd)'; then
    if run apachectl configtest; then ok "Configuração do Apache válida."
    else err "apachectl configtest falhou."; fail=1; fi
  fi
  if command -v nginx >/dev/null 2>&1 && printf '%s\n' "${SERVICES[@]}" | grep -q '^nginx'; then
    if run nginx -t; then ok "Configuração do Nginx válida."
    else err "nginx -t falhou."; fail=1; fi
  fi

  restart_services || fail=1
  sleep 2

  if [ -n "$HEALTH_URL" ]; then
    code="$(curl -ksS -o /dev/null -w '%{http_code}' --max-time 20 "$HEALTH_URL" 2>>"$LOG")"
    if [[ "$code" =~ ^[23] ]]; then ok "Health check $HEALTH_URL -> HTTP $code"
    else err "Health check $HEALTH_URL -> HTTP ${code:-sem resposta}"; fail=1; fi
  fi
  probe_web "$expect"; [ $? -eq 1 ] && fail=1
  return $fail
}

# -----------------------------------------------------------------------------
# Migração de configurações (Debian/Ubuntu, lado a lado)
# -----------------------------------------------------------------------------
ini_get() {
  local ke="${2//./\\.}"
  grep -E "^[[:space:]]*${ke}[[:space:]]*=" "$1" 2>/dev/null | tail -n1 \
    | sed -E 's/^[^=]*=[[:space:]]*//; s/[[:space:]]*$//'
}

ini_set() {
  local f="$1" k="$2" v="$3" ke="${2//./\\.}" ve
  ve="$(printf '%s' "$v" | sed 's/[&|\\]/\\&/g')"
  if grep -qE "^[[:space:]]*${ke}[[:space:]]*=" "$f"; then
    sed -i -E "s|^[[:space:]]*${ke}[[:space:]]*=.*|${k} = ${ve}|" "$f"
  elif grep -qE "^[[:space:]]*;[[:space:]]*${ke}[[:space:]]*=" "$f"; then
    sed -i -E "0,/^[[:space:]]*;[[:space:]]*${ke}[[:space:]]*=/s|^[[:space:]]*;[[:space:]]*${ke}[[:space:]]*=.*|${k} = ${ve}|" "$f"
  else
    printf '%s = %s\n' "$k" "$v" >>"$f"
  fi
}

migrate_configs_apt() {
  local o="$1" n="$2" sapi oi ni k ov nv f dest changes="$BACKUP_DIR/ini-changes.txt" oe="${1//./\\.}"
  title "Levando configurações do PHP $o para o $n"
  : >"$changes"
  for sapi in cli fpm apache2 cgi; do
    oi="/etc/php/$o/$sapi/php.ini"; ni="/etc/php/$n/$sapi/php.ini"
    [ -f "$oi" ] && [ -f "$ni" ] || continue
    for k in "${INI_DIRECTIVES[@]}"; do
      ov="$(ini_get "$oi" "$k")"; nv="$(ini_get "$ni" "$k")"
      [ -n "$ov" ] && [ "$ov" != "$nv" ] && printf '%s\t%s\t%s\t%s\n' "$sapi" "$k" "${nv:-(padrão)}" "$ov" >>"$changes"
    done
  done
  if [ -s "$changes" ]; then
    log "  Diretivas personalizadas encontradas (SAPI | diretiva | padrão novo -> valor atual):"
    awk -F'\t' '{printf "    %-8s %-32s %s -> %s\n",$1,$2,$3,$4}' "$changes" | tee -a "$LOG"
    if ask "Aplicar esses valores no php.ini do PHP $n?" S; then
      while IFS=$'\t' read -r sapi k nv ov; do ini_set "/etc/php/$n/$sapi/php.ini" "$k" "$ov"; done <"$changes"
      ok "php.ini do PHP $n ajustado."
    fi
  else
    ok "Nenhuma diretiva personalizada relevante no php.ini."
  fi

  # Arquivos .ini próprios em conf.d (que não vieram de pacote)
  for sapi in cli fpm apache2 cgi; do
    for f in /etc/php/"$o"/"$sapi"/conf.d/*; do
      [ -f "$f" ] && [ ! -L "$f" ] || continue
      dpkg -S "$f" >/dev/null 2>&1 && continue
      dest="/etc/php/$n/$sapi/conf.d/$(basename "$f")"
      [ -d "/etc/php/$n/$sapi/conf.d" ] && [ ! -e "$dest" ] && cp -p "$f" "$dest" && ok "Copiado $f -> $dest"
    done
  done

  # Pools do PHP-FPM
  if [ -d "/etc/php/$o/fpm/pool.d" ] && [ -d "/etc/php/$n/fpm/pool.d" ]; then
    for f in /etc/php/"$o"/fpm/pool.d/*.conf; do
      [ -f "$f" ] || continue
      dest="/etc/php/$n/fpm/pool.d/$(basename "$f")"
      [ -f "$dest" ] && cp -p "$dest" "$dest.dist-$TS"
      sed "s/php${oe}/php${n}/g" "$f" >"$dest"
      ok "Pool FPM $(basename "$f") replicado (caminhos php$o -> php$n)."
    done
  fi
}

# Troca Apache/Nginx/CLI para o branch novo e registra o que foi feito
switch_apt() {
  local o="$1" n="$2" alt files oe="${1//./\\.}"
  title "Trocando para PHP $n"
  UPGRADE_STARTED=1
  if command -v a2query >/dev/null 2>&1; then
    if a2query -m "php$o" >/dev/null 2>&1; then
      run a2dismod "php$o" && run a2enmod "php$n" && meta "SWITCH_MODPHP=1" && ok "Apache mod_php: php$o -> php$n"
    fi
    if a2query -c "php$o-fpm" >/dev/null 2>&1; then
      run a2disconf "php$o-fpm" && run a2enconf "php$n-fpm" && meta "SWITCH_FPMCONF=1" && ok "Apache PHP-FPM: php$o-fpm -> php$n-fpm"
    fi
  fi

  if apt_installed "php$n-fpm"; then
    run systemctl enable --now "php$n-fpm"
    files="$(grep -rlE "php${oe}-fpm\.sock" /etc/nginx /etc/apache2 2>/dev/null | grep -vE '/conf-available/php[0-9.]+-fpm\.conf$')"
    if [ -n "$files" ]; then
      log "  Arquivos que apontam para o socket php$o-fpm.sock:"
      echo "$files" | sed 's/^/    /' | tee -a "$LOG"
      if ask "Atualizar esses arquivos para php$n-fpm.sock?" S; then
        echo "$files" >"$BACKUP_DIR/webconf.list"
        echo "$files" | xargs -r sed -i "s/php${oe}-fpm\.sock/php${n}-fpm.sock/g"
        ok "Referências ao socket atualizadas."
      fi
    fi
  fi

  for alt in php phar phar.phar phpize php-config php-cgi; do
    [ -x "/usr/bin/$alt$n" ] && update-alternatives --query "$alt" >/dev/null 2>&1 \
      && run update-alternatives --set "$alt" "/usr/bin/$alt$n"
  done
  ok "Comando 'php' agora aponta para PHP $n."
}

# -----------------------------------------------------------------------------
# Rollback
# -----------------------------------------------------------------------------
rollback_packages() {
  local dir="$1" rc=0 p v args=()
  if [ "$PM" = "apt" ]; then
    if compgen -G "$dir/debs/*.deb" >/dev/null; then
      info "Reinstalando pacotes salvos..."
      run dpkg -i --force-confold "$dir"/debs/*.deb || rc=1
    fi
    while IFS=$'\t' read -r p v; do args+=("${p%%:*}=$v"); done <"$dir/packages.before.tsv"
    if run aptq install --allow-downgrades "${args[@]}"; then rc=0; else rc=1; fi
  else
    if [ "${STREAM_CHANGED:-0}" = "1" ]; then
      info "Restaurando stream de módulo PHP (${OLD_STREAM:-padrão da distro})..."
      run $PM -y module reset php
      [ -n "$OLD_STREAM" ] && run $PM -y module enable "php:$OLD_STREAM"
    fi
    if compgen -G "$dir/rpms/*.rpm" >/dev/null; then
      info "Reinstalando RPMs salvos..."
      run $PM -y downgrade "$dir"/rpms/*.rpm || run rpm -Uvh --oldpackage --replacepkgs "$dir"/rpms/*.rpm || rc=1
    else
      rc=1
    fi
    if [ $rc -ne 0 ] && [ -n "$HIST_AFTER" ] && [ "$HIST_AFTER" != "$HIST_BEFORE" ]; then
      info "Tentando '$PM history undo $HIST_AFTER'..."
      run $PM -y history undo "$HIST_AFTER" && rc=0
    fi
  fi
  if [ -f "$dir/config.tar.gz" ]; then
    if run tar -xzpf "$dir/config.tar.gz" -C /; then ok "Configurações restauradas."
    else err "Falha ao restaurar configurações."; rc=1; fi
  fi
  return $rc
}

rollback_migrate_apt() {
  local dir="$1" o="$OLD_BRANCH" n="$NEW_BRANCH" alt f rc=0
  info "Voltando Apache/Nginx/CLI para PHP $o..."
  for alt in php phar phar.phar phpize php-config php-cgi; do
    [ -x "/usr/bin/$alt$o" ] && update-alternatives --query "$alt" >/dev/null 2>&1 \
      && run update-alternatives --set "$alt" "/usr/bin/$alt$o"
  done
  if [ "${SWITCH_MODPHP:-0}" = "1" ]; then run a2dismod "php$n"; run a2enmod "php$o" || rc=1; fi
  if [ "${SWITCH_FPMCONF:-0}" = "1" ]; then run a2disconf "php$n-fpm"; run a2enconf "php$o-fpm" || rc=1; fi
  if [ -f "$dir/webconf.list" ] && [ -f "$dir/config.tar.gz" ]; then
    while read -r f; do
      [ -n "$f" ] && run tar -xzpf "$dir/config.tar.gz" -C / "${f#/}"
    done <"$dir/webconf.list"
    ok "Arquivos do servidor web restaurados."
  fi
  if apt_installed "php$o-fpm"; then run systemctl enable --now "php$o-fpm"; fi
  if apt_installed "php$n-fpm"; then run systemctl disable --now "php$n-fpm"; fi
  if [ -s "$dir/new_packages.txt" ] && ask "Remover os pacotes do PHP $n instalados pela migração?" S; then
    # shellcheck disable=SC2046
    run aptq purge $(cat "$dir/new_packages.txt") && ok "Pacotes PHP $n removidos."
  fi
  return $rc
}

do_rollback() {
  local dir="$1" rc=0 now expect
  title "ROLLBACK a partir de $dir"
  [ -f "$dir/meta.env" ] || die "Backup inválido: $dir/meta.env não encontrado."
  # shellcheck disable=SC1090,SC1091
  . "$dir/meta.env"
  mapfile -t SERVICES <"$dir/services.txt" 2>/dev/null
  [ "${SERVICES[0]:-}" = "" ] && SERVICES=()

  if [ "$MODE" = "upgrade" ] && [ "$PM" = "apt" ]; then
    rollback_migrate_apt "$dir" || rc=1
  else
    rollback_packages "$dir" || rc=1
  fi
  remove_official_repo "$dir"
  restart_services || rc=1

  expect="$OLD_BRANCH"
  now="$("$PHP_BIN" -r 'echo PHP_VERSION;' 2>/dev/null)"
  if [ $rc -eq 0 ] && [ "$now" = "$PHP_VER" ]; then
    ok "Rollback concluído. PHP de volta à versão $now."
  else
    err "Rollback com problemas (atual: ${now:-indefinida}, esperada: $PHP_VER). Veja $LOG"
  fi
  probe_web "$expect" || true
  return $rc
}

# Pergunta rollback após falha. $1 = código de saída
offer_rollback() {
  if ask "Executar ROLLBACK para o PHP $PHP_VER agora?" S; then
    do_rollback "$BACKUP_DIR"; exit "$1"
  fi
  warn "Rollback não executado. Para reverter depois: sudo $0 --rollback $BACKUP_DIR"
  exit "$1"
}

# -----------------------------------------------------------------------------
# Menu de decisão
# -----------------------------------------------------------------------------
choose_mode() {
  local installed="${PKG_VER[$MAIN_PKG]}" cand choice cand_txt
  title "Situação atual"
  if [ "$PM" = "apt" ]; then
    ask "Executar 'apt-get update' para consultar o repositório atual?" S && refresh_repos
    cand="$(apt_candidate "$MAIN_PKG")"
  else
    refresh_repos
    cand="$(rpm_candidate "$MAIN_PKG")"
  fi
  DISTRO_CANDIDATE="$cand"
  log "  PHP instalado ............ $PHP_VER  (pacote $installed)"
  log "  Repositório atual oferece  ${cand:-?}"
  log "  Release oficial php.net .. ${UPSTREAM_LATEST:-?}  (branch $BRANCH: ${BRANCH_STATE:-?})"
  show_distro_cves

  if [ -n "$cand" ] && [ "$cand" != "$installed" ] && [ "$cand" != "(none)" ]; then
    cand_txt="atualização disponível: $cand"; DISTRO_HAS_UPDATE=1
  else
    cand_txt="nenhuma atualização disponível agora"; DISTRO_HAS_UPDATE=0
  fi

  if [ -n "$MODE" ]; then return 0; fi
  if [ "$ASSUME_YES" -eq 1 ]; then MODE=distro; return 0; fi

  log "
${C_BOLD}Escolha o procedimento:${C_0}

  1) Manter o PHP $BRANCH e aplicar o patch da distro           [risco: baixo]
     ($cand_txt)
     Usa só o repositório oficial do sistema. As correções vêm por backport,
     por isso a versão pode continuar \"$(upstream_of "$installed")\".

  2) Manter o PHP $BRANCH e instalar o release oficial ${UPSTREAM_LATEST:-do php.net}   [risco: médio]
     Adiciona o repositório $(official_repo_name) e atualiza dentro do mesmo branch.
     Mesma linha de versão; correções exatamente como publicadas pelo PHP.

  3) Migrar para um branch superior do PHP                       [risco: maior]
     Instala a versão nova$( [ "$PM" = "apt" ] && echo " LADO A LADO, testa o código antes de trocar e" )
     mantém backup para voltar. Exige testar a aplicação.

  4) Sair sem alterar nada
"
  while :; do
    read -r -p "Opção [1-4]: " choice </dev/tty
    echo "  opção: $choice" >>"$LOG"
    case "$choice" in
      1) if [ "$DISTRO_HAS_UPDATE" -eq 1 ]; then MODE=distro; break; fi
         warn "O repositório atual não tem atualização para o PHP $BRANCH. Escolha 2, 3 ou 4." ;;
      2) MODE=official; break ;;
      3) MODE=upgrade; break ;;
      4) log "Nada foi alterado."; exit 0 ;;
      *) warn "Opção inválida." ;;
    esac
  done
}

ask_app_checks() {
  [ "$ASSUME_YES" -eq 1 ] && return 0
  if [ -z "$APP_DIR" ]; then
    prompt "Diretório da aplicação para testes (ex.: /var/www/html; Enter pula): " APP_DIR
    [ -z "$APP_DIR" ] || [ -d "$APP_DIR" ] || { warn "Diretório $APP_DIR não existe; teste ignorado."; APP_DIR=""; }
  fi
  if [ -n "$APP_DIR" ] && [ -z "$PROBE_BASE" ]; then
    prompt "URL que serve esse diretório, para conferir a versão no servidor web (ex.: http://localhost/; Enter pula): " PROBE_BASE
  fi
  [ -n "$HEALTH_URL" ] || prompt "URL de health check da aplicação (Enter pula): " HEALTH_URL
  precheck_probe
}

# -----------------------------------------------------------------------------
# Fluxo: patch no mesmo branch (distro ou oficial)
# -----------------------------------------------------------------------------
flow_patch() {
  local cand installed="${PKG_VER[$MAIN_PKG]}"
  if [ "$MODE" = "distro" ] && [ "${DISTRO_HAS_UPDATE:-0}" -eq 0 ]; then
    ok "O repositório da distro não tem atualização para o PHP $BRANCH. Nada a fazer."
    log "Para o release oficial use --mode official; para migrar, --mode upgrade."
    exit 0
  fi
  if [ "$MODE" = "official" ]; then
    add_official_repo || die "Repositório não adicionado. Nada foi alterado."
  fi

  if [ "$PM" = "apt" ]; then
    cand="$(apt_candidate "$MAIN_PKG")"
  elif [ "$MODE" = "official" ]; then
    rpm_stream_exists "remi-$BRANCH" || [ "$DRY_RUN" -eq 1 ] || die "Stream php:remi-$BRANCH não encontrado no Remi."
    cand="stream php:remi-$BRANCH (${UPSTREAM_LATEST:-último release})"
  else
    cand="$DISTRO_CANDIDATE"
  fi

  if [ "$PM" = "apt" ] && [ "$cand" = "$installed" ] && [ "$DRY_RUN" -eq 0 ]; then
    warn "O repositório não oferece versão mais nova de $MAIN_PKG ($installed)."
    [ "$MODE" = "official" ] && warn "O $(official_repo_name) pode não ter pacotes para $OS_NAME."
    . "$BACKUP_DIR/meta.env"; remove_official_repo "$BACKUP_DIR"
    exit 0
  fi

  ask_app_checks
  title "Plano"
  log "  Procedimento : $( [ "$MODE" = distro ] && echo "patch da distro" || echo "release oficial ($(official_repo_name))" )"
  log "  De           : $installed"
  log "  Para         : ${cand:-?}"
  log "  Pacotes      : ${#PKGS[@]}"
  log "  Serviços     : ${SERVICES[*]:-nenhum} (serão reiniciados)"
  log "  Testes       : health=${HEALTH_URL:-não}  app=${APP_DIR:-não}  probe=${PROBE_BASE:-não}"
  if [ "$DRY_RUN" -eq 1 ]; then
    [ "$PM" = "apt" ] && aptq -s install --only-upgrade "${PKGS[@]}" 2>&1 | grep -E '^(Inst|Remv)' | tee -a "$LOG"
    log "\n--dry-run: nada foi alterado."; exit 0
  fi
  ask "Iniciar backup e atualização?" || { log "Cancelado."; . "$BACKUP_DIR/meta.env"; remove_official_repo "$BACKUP_DIR"; exit 0; }

  do_backup
  title "Aplicando atualização"
  UPGRADE_STARTED=1
  local rc
  if [ "$PM" = "apt" ]; then
    aptq install --only-upgrade "${PKGS[@]}" 2>&1 | tee -a "$LOG"; rc=${PIPESTATUS[0]}
  else
    HIST_BEFORE="$($PM history list 2>/dev/null | awk '$1 ~ /^[0-9]+$/ {print $1; exit}')"; meta "HIST_BEFORE=$HIST_BEFORE"
    if [ "$MODE" = "official" ]; then
      meta "STREAM_CHANGED=1"
      run $PM -y module reset php && run $PM -y module enable "php:remi-$BRANCH"
      $PM -y distro-sync "${PKGS[@]}" 2>&1 | tee -a "$LOG"; rc=${PIPESTATUS[0]}
    else
      $PM -y upgrade "${PKGS[@]}" 2>&1 | tee -a "$LOG"; rc=${PIPESTATUS[0]}
    fi
    HIST_AFTER="$($PM history list 2>/dev/null | awk '$1 ~ /^[0-9]+$/ {print $1; exit}')"; meta "HIST_AFTER=$HIST_AFTER"
  fi
  [ "$rc" -eq 0 ] || { err "O gerenciador de pacotes retornou erro."; offer_rollback 2; }

  if validate "$BRANCH"; then
    title "Concluído"
    ok "PHP atualizado: $PHP_VER -> $("$PHP_BIN" -r 'echo PHP_VERSION;')"
    log "Backup: $BACKUP_DIR"
    log "Para reverter: sudo $0 --rollback $BACKUP_DIR"
    exit 0
  fi
  err "A validação falhou."
  offer_rollback 3
}

# -----------------------------------------------------------------------------
# Fluxo: migrar para branch superior
# -----------------------------------------------------------------------------
choose_target() {
  local list=() b st se lat i choice avail
  title "Branches superiores disponíveis"
  while read -r b st se; do
    [ -n "$b" ] || continue
    version_lt "$BRANCH" "$b" || continue
    if [ "$PM" = "apt" ]; then
      avail="$(apt_candidate "php$b-cli")"; [ -n "$avail" ] && [ "$avail" != "(none)" ] || continue
    else
      rpm_stream_exists "remi-$b" || continue
    fi
    list+=("$b|$st|$se")
  done < <(supported_branches)

  [ ${#list[@]} -gt 0 ] || die "Nenhum branch superior com suporte foi encontrado no repositório."

  if [ -n "$TARGET" ]; then
    printf '%s\n' "${list[@]}" | grep -q "^$TARGET|" || die "Branch $TARGET indisponível."
    NEW_BRANCH="$TARGET"; return 0
  fi
  for i in "${!list[@]}"; do
    IFS='|' read -r b st se <<<"${list[$i]}"
    lat="$(upstream_latest "$b")"
    log "  $((i+1))) PHP $b  (release ${lat:-?}, $( [ "$st" = stable ] && echo "suporte ativo" || echo "só segurança" ), segurança até $se)"
  done
  if [ "$ASSUME_YES" -eq 1 ]; then
    IFS='|' read -r NEW_BRANCH _ _ <<<"${list[0]}"; return 0
  fi
  warn "Dica: migrar um branch por vez (ex.: 8.3 -> 8.4) reduz o risco de incompatibilidade."
  read -r -p "Branch de destino [1-${#list[@]}]: " choice </dev/tty
  [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -le ${#list[@]} ] || die "Opção inválida."
  IFS='|' read -r NEW_BRANCH _ _ <<<"${list[$((choice-1))]}"
}

flow_upgrade() {
  add_official_repo || die "Repositório não adicionado. Nada foi alterado."
  [ "$DRY_RUN" -eq 1 ] && ! official_repo_present && { log "\n--dry-run: adicione o repositório para listar os branches."; exit 0; }
  choose_target
  meta "NEW_BRANCH=$NEW_BRANCH"
  ok "Destino: PHP $NEW_BRANCH"

  if [ "$PM" = "apt" ]; then flow_upgrade_apt; else flow_upgrade_rpm; fi
}

flow_upgrade_apt() {
  local o="$BRANCH" n="$NEW_BRANCH" p m c newly=() missing=() newpkgs=()
  for p in "${PKGS[@]}"; do
    m="${p%%:*}"; m="${m/php$o/php$n}"
    c="$(apt_candidate "$m")"
    if [ -n "$c" ] && [ "$c" != "(none)" ]; then newpkgs+=("$m"); else missing+=("$m"); fi
  done
  for p in "php$n-cli" "php$n-common"; do
    printf '%s\n' "${newpkgs[@]}" | grep -qx "$p" || die "Pacote essencial $p indisponível."
  done
  if [ ${#missing[@]} -gt 0 ]; then
    warn "Sem equivalente no PHP $n: ${missing[*]}"
    printf '%s\n' "${missing[@]}" | grep -qE "^(libapache2-mod-php$n|php$n-fpm)$" && die "Pacote de integração web indisponível; migração abortada."
    ask "Continuar sem esses pacotes?" || exit 0
  fi

  ask_app_checks
  title "Plano de migração (lado a lado)"
  log "  1. Instalar ${#newpkgs[@]} pacotes do PHP $n junto ao PHP $o (produção não muda)"
  log "  2. Testar o código da aplicação no PHP $n ${APP_DIR:+($APP_DIR)}"
  log "  3. Levar configurações (php.ini, conf.d, pools FPM)"
  log "  4. Trocar Apache/Nginx/CLI para PHP $n e validar"
  log "  5. Se falhar: voltar ao PHP $o (que continua instalado)"
  log "  Pacotes: ${newpkgs[*]}"
  if [ "$DRY_RUN" -eq 1 ]; then
    aptq -s install "${newpkgs[@]}" 2>&1 | grep -E '^(Inst|Remv)' | tee -a "$LOG"
    log "\n--dry-run: nada foi alterado."; exit 0
  fi
  ask "Iniciar backup e instalação do PHP $n?" || { log "Cancelado."; . "$BACKUP_DIR/meta.env"; remove_official_repo "$BACKUP_DIR"; exit 0; }

  do_backup
  for p in "${newpkgs[@]}"; do apt_installed "$p" || newly+=("$p"); done
  printf '%s\n' "${newly[@]}" >"$BACKUP_DIR/new_packages.txt"

  title "Instalando PHP $n lado a lado"
  UPGRADE_STARTED=1
  aptq install "${newpkgs[@]}" 2>&1 | tee -a "$LOG"
  if [ "${PIPESTATUS[0]}" -ne 0 ]; then
    err "Falha na instalação do PHP $n. O PHP $o em produção não foi alterado."
    offer_rollback 2
  fi
  ok "PHP $("/usr/bin/php$n" -r 'echo PHP_VERSION;') instalado. Produção continua no PHP $o."

  if ! lint_compare "$PHP_BIN" "/usr/bin/php$n"; then
    warn "Recomendação: corrigir o código antes de trocar. A produção ainda está no PHP $o."
    ask "Trocar para PHP $n mesmo assim?" || offer_rollback 4
  fi

  migrate_configs_apt "$o" "$n"
  if ! run "php-fpm$n" -t 2>/dev/null && apt_installed "php$n-fpm"; then
    err "Configuração do php-fpm$n inválida após replicar os pools (ver log)."
    offer_rollback 4
  fi

  ask "Trocar a produção para PHP $n agora? (serviços serão reiniciados)" S || {
    log "Troca não realizada. PHP $n fica instalado e inativo."
    log "Para remover: sudo $0 --rollback $BACKUP_DIR"; exit 0; }

  switch_apt "$o" "$n"
  local s new_services=()
  for s in "${SERVICES[@]}"; do [[ "$s" == php"$o"-fpm.service ]] || new_services+=("$s"); done
  apt_installed "php$n-fpm" && new_services+=("php$n-fpm.service")
  SERVICES=("${new_services[@]}")
  PHP_BIN="/usr/bin/php$n"

  if validate "$n"; then
    title "Migração concluída"
    ok "Produção agora em PHP $("$PHP_BIN" -r 'echo PHP_VERSION;')"
    if apt_installed "php$o-fpm" && ask "Parar e desativar o php$o-fpm (continua instalado para rollback)?" S; then
      run systemctl disable --now "php$o-fpm" && ok "php$o-fpm desativado."
    fi
    log "O PHP $o continua instalado. Depois de alguns dias estável, remova com:"
    log "    sudo apt purge 'php$o-*' libapache2-mod-php$o"
    log "Para reverter: sudo $0 --rollback $BACKUP_DIR"
    exit 0
  fi
  err "A validação no PHP $n falhou."
  PHP_BIN="/usr/bin/php$o"
  offer_rollback 3
}

flow_upgrade_rpm() {
  local n="$NEW_BRANCH" rc
  warn "Em RHEL/Oracle Linux o PHP é trocado NO LUGAR (não há instalação lado a lado)."
  warn "O teste de código é feito logo após a troca; se falhar, o rollback restaura o $BRANCH."
  ask_app_checks
  title "Plano de migração"
  log "  1. Backup dos RPMs e configurações atuais"
  log "  2. Ativar stream php:remi-$n e sincronizar ${#PKGS[@]} pacotes"
  log "  3. Testar código ${APP_DIR:+($APP_DIR)} e validar serviços"
  log "  4. Se falhar: voltar ao stream ${OLD_STREAM:-anterior} e RPMs salvos"
  if [ "$DRY_RUN" -eq 1 ]; then log "\n--dry-run: nada foi alterado."; exit 0; fi
  ask "Iniciar backup e migração para PHP $n?" || { log "Cancelado."; . "$BACKUP_DIR/meta.env"; remove_official_repo "$BACKUP_DIR"; exit 0; }

  do_backup
  title "Migrando para PHP $n"
  UPGRADE_STARTED=1
  HIST_BEFORE="$($PM history list 2>/dev/null | awk '$1 ~ /^[0-9]+$/ {print $1; exit}')"; meta "HIST_BEFORE=$HIST_BEFORE"
  meta "STREAM_CHANGED=1"
  run $PM -y module reset php && run $PM -y module enable "php:remi-$n"
  $PM -y distro-sync "${PKGS[@]}" 2>&1 | tee -a "$LOG"; rc=${PIPESTATUS[0]}
  HIST_AFTER="$($PM history list 2>/dev/null | awk '$1 ~ /^[0-9]+$/ {print $1; exit}')"; meta "HIST_AFTER=$HIST_AFTER"
  [ "$rc" -eq 0 ] || { err "Falha na troca de versão."; offer_rollback 2; }

  if ! lint_compare "" "$PHP_BIN"; then
    ask "Há erros de sintaxe no PHP $n. Manter a migração mesmo assim?" || offer_rollback 4
  fi
  if validate "$n"; then
    title "Migração concluída"
    ok "PHP agora em $("$PHP_BIN" -r 'echo PHP_VERSION;')"
    log "Para reverter: sudo $0 --rollback $BACKUP_DIR"
    exit 0
  fi
  err "A validação no PHP $n falhou."
  offer_rollback 3
}

# -----------------------------------------------------------------------------
# Main
# -----------------------------------------------------------------------------
main() {
  while [ $# -gt 0 ]; do
    case "$1" in
      --dry-run) DRY_RUN=1 ;;
      -y|--yes) ASSUME_YES=1 ;;
      --mode) MODE="$2"; shift ;;
      --target) TARGET="$2"; shift ;;
      --url) HEALTH_URL="$2"; shift ;;
      --app-dir) APP_DIR="$2"; shift ;;
      --probe-url) PROBE_BASE="$2"; shift ;;
      --rollback) MANUAL_ROLLBACK_DIR="$2"; shift ;;
      -h|--help) usage; exit 0 ;;
      *) echo "Opção desconhecida: $1"; usage; exit 1 ;;
    esac
    shift
  done
  case "$MODE" in ""|distro|official|upgrade) ;; *) die "--mode deve ser distro, official ou upgrade." ;; esac
  [ -n "$TARGET" ] && [ -z "$MODE" ] && MODE=upgrade

  require_root
  touch "$LOG" && chmod 600 "$LOG"
  log "${C_BOLD}php-security-patch v$SCRIPT_VERSION — $(date)${C_0}"
  log "Log: $LOG"
  detect_os

  if [ -n "$MANUAL_ROLLBACK_DIR" ]; then
    BACKUP_DIR="$MANUAL_ROLLBACK_DIR"
    ask "Reverter o PHP para o estado salvo em $MANUAL_ROLLBACK_DIR?" || exit 0
    do_rollback "$MANUAL_ROLLBACK_DIR"; exit $?
  fi

  detect_php
  check_upstream
  collect_packages
  detect_services
  choose_mode
  [ "$DRY_RUN" -eq 1 ] || preflight
  init_backup_dir

  case "$MODE" in
    distro|official) flow_patch ;;
    upgrade)         flow_upgrade ;;
  esac
}

main "$@"
