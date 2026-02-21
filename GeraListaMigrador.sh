#!/usr/bin/env bash
# NOTA: Se você editar este arquivo no Windows, converta para LF:
# sudo apt-get install -y dos2unix && dos2unix GeraListaMigrador.sh

set -euo pipefail

VERSION="1.0.0-20260206"

# ===================== Configuração & Modos =====================
# Modos de operação:
#   default      -> saída completa (8 campos, separados por espaço); em falha de API imprime "<nam_login> -"
#   --REDIS      -> imprime "<nam_login> <enabled>"; em falha de API imprime "<nam_login> -"
#   --A          -> imprime "<nam_login> <des_path_folder> <IP|apelido|NODATA|NXDOMAIN|->"
#   --SUMMARY    -> (somente com --A) ao final imprime sumário por categoria (apelido/IP/NODATA/NXDOMAIN/-)
#   --HOSTHEADER -> imprime "<nam_login> <dominio_real_ou_main>"
#   --PROVEDOR   -> imprime "<nam_login> <des_path_folder> <UOLHOST|outros|none>"
#   --SOA        -> imprime "user,dominio,soa"
#   --HELP       -> imprime apenas as sintaxes e sai
MODE="default"
SUMMARY=0

print_help() {
  cat <<EOF
GeraListaMigrador.sh ${VERSION}
Sintaxes:
  ./GeraListaMigrador.sh
  ./GeraListaMigrador.sh <arquivo>
  ./GeraListaMigrador.sh --REDIS
  ./GeraListaMigrador.sh --REDIS <arquivo>
  ./GeraListaMigrador.sh --A
  ./GeraListaMigrador.sh --A <arquivo>
  ./GeraListaMigrador.sh --A --SUMMARY
  ./GeraListaMigrador.sh --SUMMARY --A <arquivo>
  ./GeraListaMigrador.sh --HOSTHEADER
  ./GeraListaMigrador.sh --HOSTHEADER <arquivo>
  ./GeraListaMigrador.sh --PROVEDOR
  ./GeraListaMigrador.sh --PROVEDOR <arquivo>
  ./GeraListaMigrador.sh --SOA
  ./GeraListaMigrador.sh --SOA <arquivo>
  ./GeraListaMigrador.sh --HELP
EOF
}

# ------------- Processamento de argumentos (aceita flags em qualquer ordem) -------------
USERS_FILE="lista.txt"
if [[ $# -gt 0 ]]; then
  while [[ $# -gt 0 ]]; do
    case "${1:-}" in
      --HELP)        print_help; exit 0 ;;
      --REDIS)       MODE="redis"; shift ;;
      --A)           MODE="a"; shift ;;
      --SUMMARY)     SUMMARY=1; shift ;;
      --HOSTHEADER)  MODE="hostheader"; shift ;;
      --PROVEDOR)    MODE="provedor"; shift ;;
      --SOA)         MODE="soa"; shift ;;
      *)             USERS_FILE="$1"; shift ;;
    esac
  done
fi

# --SUMMARY só é válido com --A
if [[ "$SUMMARY" -eq 1 && "$MODE" != "a" ]]; then
  echo "USO INVÁLIDO: --SUMMARY só pode ser utilizado junto com --A" >&2
  exit 2
fi

# Endpoints
API_BASE="http://ws.novahospedagem.intranet/v1/redis/getalluserinfo"
UHN_BASE="http://ws.uhn.intranet/users"

# Intervalo entre chamadas
SLEEP_SECS="${SLEEP_SECS:-5}"

# DEBUG=1 para mostrar traces e respostas das APIs em stderr
DEBUG="${DEBUG:-0}"
if [[ "$DEBUG" == "1" ]]; then set -x; fi

# ===================== PATH & Binários =====================
if [[ -z "${PATH:-}" || "${#PATH}" -lt 8 ]]; then
  export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
fi

CURL_BIN="$(command -v curl || true)"
JQ_BIN="$(command -v jq || true)"
SLEEP_BIN="$(command -v sleep || true)"
DIG_BIN=""
HOST_BIN="$(command -v host || true)"
WHOIS_BIN=""

if [[ -z "$CURL_BIN" ]]; then
  echo "Erro: 'curl' não encontrado no PATH atual ($PATH)." >&2
  exit 1
fi
if [[ -z "$JQ_BIN" ]]; then
  echo "Erro: 'jq' não encontrado. Instale com: sudo apt-get install -y jq" >&2
  exit 1
fi
if [[ -z "$SLEEP_BIN" ]]; then
  if [[ -x "/bin/sleep" ]]; then
    SLEEP_BIN="/bin/sleep"
  elif [[ -x "/usr/bin/sleep" ]]; then
    SLEEP_BIN="/usr/bin/sleep"
  else
    SLEEP_BIN=":"  # no-op
  fi
fi

# 'dig' é necessário nos modos --A e --SOA
if [[ "$MODE" == "a" || "$MODE" == "soa" ]]; then
  DIG_BIN="$(command -v dig || true)"
  if [[ -z "$DIG_BIN" ]]; then
    echo "Erro: 'dig' não encontrado. Instale 'dnsutils' (Debian/Ubuntu) ou 'bind-utils' (RHEL/CentOS/Fedora)." >&2
    exit 1
  fi
fi

# 'whois' é necessário apenas no modo --PROVEDOR
if [[ "$MODE" == "provedor" ]]; then
  WHOIS_BIN="$(command -v whois || true)"
  if [[ -z "$WHOIS_BIN" ]]; then
    echo "Erro: 'whois' não encontrado. Instale 'whois' (Debian/Ubuntu) ou 'jwhois' (RHEL/CentOS/Fedora)." >&2
    exit 1
  fi
fi

# ===================== Legenda de IPs (mapa IP -> apelido) =====================
declare -A IP_MAP=(
  [187.17.111.35]="HK"
  [187.17.111.118]="DUDA"
  [187.17.111.119]="Loja"
  [186.234.81.8]="asgard1"
  [186.234.81.9]="asgard2"
  [186.234.81.10]="asgard3"
  [186.234.81.11]="asgard4"
  [186.234.81.12]="asgard5"
  [186.234.81.13]="asgard6"
  [186.234.81.24]="asgard7"
  [186.234.81.25]="a16-asgard8"
)

load_ip_legend_file() {
  local file=""
  if [[ -f "./ip_legend.txt" ]]; then
    file="./ip_legend.txt"
  elif [[ -f "/etc/gera_migrador/ip_legend.txt" ]]; then
    file="/etc/gera_migrador/ip_legend.txt"
  fi
  [[ -z "$file" ]] && return 0

  while IFS= read -r line; do
    [[ -z "$line" || "$line" =~ ^# ]] && continue
    local ip nick
    ip="$(printf '%s' "$line" | awk '{print $1}')"
    nick="$(printf '%s' "$line" | cut -d' ' -f2-)"
    [[ -z "$ip" || -z "$nick" ]] && continue
    IP_MAP["$ip"]="$nick"
  done < "$file"
}
map_ip_label() {
  local value="$1"
  if [[ "$value" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
    if [[ -n "${IP_MAP[$value]:-}" ]]; then printf '%s' "${IP_MAP[$value]}"; else printf '%s' "$value"; fi
  else
    printf '%s' "$value"
  fi
}
load_ip_legend_file

# ===================== Cores (apenas para --A e resumo) =====================
USE_COLOR=0
if [[ -t 1 && "${NO_COLOR:-0}" != "1" ]]; then USE_COLOR=1; fi
YELLOW="\033[33m"; CYAN="\033[36m"; RESET="\033[0m"
color_label() {
  local val="$1"
  if [[ "$USE_COLOR" -ne 1 ]]; then printf '%s' "$val"; return 0; fi
  if [[ "$val" == "NODATA" || "$val" == "NXDOMAIN" || "$val" == "-" ]]; then printf '%s' "$val"; return 0; fi
  if [[ "$val" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then printf '%b%s%b' "$YELLOW" "$val" "$RESET"; else printf '%b%s%b' "$CYAN" "$val" "$RESET"; fi
}

# ===================== Utilitários =====================
trim() { local s="$1"; s="${s#"${s%%[![:space:]]*}"}"; s="${s%"${s##*[![:space:]]}"}"; printf '%s' "$s"; }

get_idt_domain() {
  local idt_person="$1" des_path_folder="$2"
  local resp id
  resp="$("$CURL_BIN" -fs --location "$UHN_BASE/$idt_person/domains" 2>/dev/null || true)"
  if [[ -z "$resp" ]]; then printf '%s' ""; return 0; fi
  id="$(printf '%s' "$resp" | "$JQ_BIN" -r --arg name "$des_path_folder" '.domains[]? | select(.name == $name) | .id' 2>/dev/null | head -n1 || true)"
  printf '%s' "$id"
}

resolve_ipv4() {
  local domain="$1" qdomain="${domain%.}" ip status a_count
  ip="$("$DIG_BIN" +short "$qdomain" A 2>/dev/null | awk '/^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/ {print; exit}' || true)"
  if [[ -n "$ip" ]]; then printf '%s' "$ip"; return 0; fi
  status="$("$DIG_BIN" "$qdomain" A +noall +comments 2>/dev/null | tr -d '\r' | sed -n 's/.*status:[[:space:]]*\([A-Z][A-Z0-9]*\).*/\1/p' | head -n1 || true)"
  if [[ -z "$status" ]]; then
    status="$("$DIG_BIN" "$qdomain" A +cmd +noquestion +nocomments +nostats 2>/dev/null | tr -d '\r' | sed -n 's/.*status:[[:space:]]*\([A-Z][A-Z0-9]*\).*/\1/p' | head -n1 || true)"
  fi
  if [[ "$status" == "NXDOMAIN" ]]; then printf '%s' "NXDOMAIN"; return 0; fi
  if [[ "$status" == "NOERROR" ]]; then
    a_count="$("$DIG_BIN" "$qdomain" A +noall +answer 2>/dev/null | awk '$4=="A"{c++} END{print c+0}' || true)"
    if [[ "${a_count:-0}" -eq 0 ]]; then printf '%s' "NODATA"; return 0; else
      ip="$("$DIG_BIN" "$qdomain" A +noall +answer 2>/dev/null | awk '$4=="A"{print $5; exit}' || true)"
      if [[ -n "$ip" ]]; then printf '%s' "$ip"; return 0; fi
    fi
  fi
  if [[ "$status" == "SERVFAIL" || "$status" == "REFUSED" || "$status" == "FORMERR" || "$status" == "NOTAUTH" || "$status" == "NOTIMP" || "$status" == "YXDOMAIN" ]]; then
    printf '%s' "NXDOMAIN"; return 0
  fi
  if [[ -n "$HOST_BIN" ]]; then
    local h; h="$("$HOST_BIN" -t A "$qdomain" 2>/dev/null || true)"
    if echo "$h" | grep -qi 'not found: 3(NXDOMAIN)'; then printf '%s' "NXDOMAIN"; return 0; fi
    ip="$(echo "$h" | awk '/has address/ {print $NF; exit}' || true)"
    if [[ -n "$ip" ]]; then printf '%s' "$ip"; return 0; fi
    if echo "$h" | grep -qi 'has no A record'; then printf '%s' "NODATA"; return 0; fi
  fi
  printf '%s' "-"
}

# ===================== Verificações =====================
if [[ ! -f "$USERS_FILE" ]]; then
  echo "Erro: arquivo '$USERS_FILE' não encontrado." >&2; exit 1
fi

# ===================== Loop principal =====================
lineno=0
declare -A SUMMARY_MAP

while IFS= read -r LINE || [[ -n "$LINE" ]]; do
  lineno=$((lineno+1))
  LINE="$(trim "$LINE")"
  [[ -z "$LINE" || "$LINE" =~ ^# ]] && continue
  if [[ "$LINE" =~ (^|[[:space:]])IDTPerson([[:space:]]|$) ]] && [[ "$LINE" =~ (^|[[:space:]])nam_login([[:space:]]|$) ]]; then continue; fi

  # Colunas esperadas:
  # 1: IDTPerson  2: idt_inscription  3: IDTPlano  4: nam_login  5: des_path_folder (domínio)
  IDTPerson="" idt_inscription="" IDTPlano="" USER="" DOMAIN=""
  read -r IDTPerson idt_inscription IDTPlano USER DOMAIN _extra <<<"$LINE"
  [[ -z "${USER:-}" || -z "${DOMAIN:-}" ]] && continue

  # ------ MODO --A ------
  if [[ "$MODE" == "a" ]]; then
    RAW_RESULT="$(resolve_ipv4 "$DOMAIN")"
    MAPPED="$(map_ip_label "$RAW_RESULT")"
    COLORED_THIRD="$(color_label "$MAPPED")"
    printf "%s %s %s\n" "$USER" "$DOMAIN" "$COLORED_THIRD"
    if [[ "$SUMMARY" -eq 1 ]]; then SUMMARY_MAP["$MAPPED"]=$(( ${SUMMARY_MAP["$MAPPED"]:-0} + 1 )); fi
    "$SLEEP_BIN" "$SLEEP_SECS"; continue
  fi

  # ------ MODO --REDIS ------
  if [[ "$MODE" == "redis" ]]; then
    RESP="$("$CURL_BIN" -fs "$API_BASE/$USER" || true)"
    if [[ -z "$RESP" ]]; then printf "%s -\n" "$USER"; "$SLEEP_BIN" "$SLEEP_SECS"; continue; fi
    STATUS="$(printf '%s' "$RESP" | "$JQ_BIN" -er --arg u "$USER" '(.[$u].enabled // empty) | ascii_downcase' 2>/dev/null || true)"
    [[ -z "$STATUS" ]] && STATUS="-"
    printf "%s %s\n" "$USER" "$STATUS"
    "$SLEEP_BIN" "$SLEEP_SECS"; continue
  fi

  # ------ MODO --HOSTHEADER ------
  if [[ "$MODE" == "hostheader" ]]; then
    RESP="$("$CURL_BIN" -fs "$API_BASE/$USER" || true)"
    if [[ -z "$RESP" ]]; then printf "%s -\n" "$USER"; "$SLEEP_BIN" "$SLEEP_SECS"; continue; fi

    HOSTHDR="$(printf '%s' "$RESP" | "$JQ_BIN" -er '
      (.domains_and_hostheaders // {}) as $dh
      | if ($dh|type) == "object" and ($dh|length) > 0 then
          ($dh | to_entries | .[0]) as $e
          | ($e.key) as $main
          | ($e.value // []) as $hosts
          | (
              $hosts
              | map({orig: ., lc: (ascii_downcase)})
              | map(select(
                  (.lc | endswith(".dominiotemporario.com") | not)
                  and (.lc | endswith(".sslblindado.com") | not)
                  and (.lc | startswith("www.") | not)
              ))
          ) as $filtered
          | if ($filtered|length) == 0 then
              $main
            else
              (
                [ $filtered[] | select(.lc | test("^mps[0-9]{13}\\.com$") | not) ][0]?.orig
              ) as $nonmps_first
              | if $nonmps_first != null and $nonmps_first != "" then
                  $nonmps_first
                else
                  $filtered[0].orig
                end
            end
        else
          "-"
        end
    ' 2>/dev/null || true)"
    [[ -z "$HOSTHDR" ]] && HOSTHDR="-"
    printf "%s %s\n" "$USER" "$HOSTHDR"
    "$SLEEP_BIN" "$SLEEP_SECS"; continue
  fi

  # ------ MODO --PROVEDOR ------
  if [[ "$MODE" == "provedor" ]]; then
    WHOIS_OUT="$("$WHOIS_BIN" "$DOMAIN" 2>/dev/null || true)"
    PROVIDER="$(printf '%s' "$WHOIS_OUT" | grep -iE '^[[:space:]]*provider[[:space:]]*:' | head -n1 | cut -d':' -f2- | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//' || true)"
    RESELLER="$(printf '%s' "$WHOIS_OUT" | grep -iE '^[[:space:]]*reseller[[:space:]]*:' | head -n1 | cut -d':' -f2- | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//' || true)"
    CLASSIF=""
    if echo "$PROVIDER" | grep -iq 'uolhost'; then
      CLASSIF="UOLHOST"
    elif echo "$RESELLER" | grep -iq '^uol[[:space:]]*host$'; then
      CLASSIF="UOLHOST"
    else
      if [[ -z "$PROVIDER" && -z "$RESELLER" ]]; then CLASSIF="none"; else CLASSIF="outros"; fi
    fi
    printf "%s %s %s\n" "$USER" "$DOMAIN" "$CLASSIF"
    "$SLEEP_BIN" "$SLEEP_SECS"; continue
  fi

# ------ MODO --SOA ------
if [[ "$MODE" == "soa" ]]; then
  # 1) Tenta +short (uma linha)
  SOA_OUT="$("$DIG_BIN" "$DOMAIN" SOA +short +time=3 +tries=1 2>/dev/null || true)"

  # 2) Se vazio, tenta ANSWER (RDATA SOA)
  if [[ -z "$SOA_OUT" ]]; then
    SOA_OUT="$("$DIG_BIN" "$DOMAIN" SOA +noall +answer +time=3 +tries=1 2>/dev/null \
      | awk '$4=="SOA"{for (i=5;i<=NF;i++) printf ((i>5?" ":"") $i); print ""}' || true)"
  fi

  # 3) Se ainda vazio, tenta AUTHORITY (útil para NXDOMAIN -> SOA da zona pai)
  if [[ -z "$SOA_OUT" ]]; then
    SOA_OUT="$("$DIG_BIN" "$DOMAIN" SOA +noall +authority +time=3 +tries=1 2>/dev/null \
      | awk '$4=="SOA"{for (i=5;i<=NF;i++) printf ((i>5?" ":"") $i); print ""}' || true)"
  fi

  # 4) Se ainda vazio, classifica pelo status do cabeçalho
  if [[ -z "$SOA_OUT" ]]; then
    STATUS="$("$DIG_BIN" "$DOMAIN" SOA +noall +comments 2>/dev/null \
      | sed -n 's/.*status:[[:space:]]*\\([A-Z][A-Z0-9]*\\).*/\\1/p' | head -n1 || true)"

    case "$STATUS" in
      NXDOMAIN)
        SOA_OUT="NXDOMAIN"
        ;;
      SERVFAIL|REFUSED|FORMERR|NOTAUTH|NOTIMP|YXDOMAIN)
        # >>> Sai com o status literal (ex.: REFUSED), em vez de '-'
        SOA_OUT="$STATUS"
        ;;
      *)
        SOA_OUT="-"
        ;;
    esac
  fi

  # 5) Junta múltiplas linhas (se houver) e imprime CSV sem aspas
  SOA_JOINED="$(printf '%s' "$SOA_OUT" | paste -sd '; ' -)"
  printf "%s,%s,%s\n" "$USER" "$DOMAIN" "$SOA_JOINED"

  "$SLEEP_BIN" "$SLEEP_SECS"
  continue
fi


  # ------ MODO padrão (8 campos) ------
  IDT_DOMAIN="$(get_idt_domain "$IDTPerson" "$DOMAIN")"; [[ -z "$IDT_DOMAIN" ]] && IDT_DOMAIN="0"
  RESP="$("$CURL_BIN" -fs "$API_BASE/$USER" || true)"
  if [[ -z "$RESP" ]]; then printf "%s -\n" "$USER"; "$SLEEP_BIN" "$SLEEP_SECS"; continue; fi

  OUTPUT="$(printf '%s' "$RESP" | "$JQ_BIN" -er \
    --arg u "$USER" --arg d "$DOMAIN" --arg iddom "$IDT_DOMAIN" \
    --arg idtp "$IDTPerson" --arg idti "$idt_inscription" --arg idtpl "$IDTPlano" '
      .[$u] as $obj
      | ($obj.server // empty) as $server
      | ($obj.pool // empty) as $pool
      | ($obj.filesystem // empty) as $fs
      | ($obj.userpath // empty) as $up
      | ($obj.application // "") as $app
      | (
          (try ($app | capture("php-version=(?<v>[0-9.]+)")) catch null) //
          (try ($app | capture("template=php(?<v>[0-9.]+)")) catch null) //
          (try ($app | capture("php(?<v>[0-9.]+)")) catch null)
        ) as $m
      | ($m.v // "") as $pv_raw
      | ($pv_raw | gsub("\\."; "")) as $pv_norm
      | select($server != null and $pool != null and $fs != null and $up != null)
      | [
          $idtp, $idti, $idtpl, $u,
          ("/mnt/" + $server + "/" + $pool + "-" + $fs + "/" + $up),
          $d, $iddom, ("php" + $pv_norm)
        ]
      | map(tostring) | join(" ")
    ' 2>/dev/null || true)"
  if [[ -n "$OUTPUT" ]]; then printf "%s\n" "$OUTPUT"; else printf "%s -\n" "$USER"; fi

  "$SLEEP_BIN" "$SLEEP_SECS"
done < "$USERS_FILE"

# ===================== RESUMO (somente se --A --SUMMARY) =====================
if [[ "$MODE" == "a" && "$SUMMARY" -eq 1 ]]; then
  if [[ "${#SUMMARY_MAP[@]}" -gt 0 ]]; then
    printf "\n# TOTAL:\n"
    {
      for key in "${!SUMMARY_MAP[@]}"; do
        printf "%s\t%s\n" "${SUMMARY_MAP[$key]}" "$key"
      done
    } | sort -nr -k1,1 -k2,2 | while IFS=$'\t' read -r count key; do
      if [[ "$USE_COLOR" -eq 1 ]]; then colored_key="$(color_label "$key")"; else colored_key="$key"; fi
      printf "%s - %s dominios\n" "$colored_key" "$count"
    done
  fi
fi
