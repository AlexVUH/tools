
# GeraListaMigrador — Guia de Uso

> Última atualização: 2026-02-06

Este documento descreve as **funções ativas** do script `GeraListaMigrador.sh`, seus parâmetros, formato de entrada/saída, dependências e exemplos.

---

## Sumário
- [Formato de entrada](#formato-de-entrada)
- [Dependências](#dependências)
- [Variáveis de ambiente úteis](#variáveis-de-ambiente-úteis)
- [Funções / Modos](#funções--modos)
  - [Padrão (sem flags)](#padrão-sem-flags)
  - [--REDIS](#--redis)
  - [--A](#--a)
  - [--SUMMARY (somente com --A)](#--summary-somente-com---a)
  - [--HOSTHEADER](#--hostheader)
  - [--PROVEDOR](#--provedor)
  - [--SOA](#--soa)
  - [--HELP](#--help)
- [Mapeamento de IP → apelido](#mapeamento-de-ip--apelido)
- [Erros e comportamento silencioso](#erros-e-comportamento-silencioso)
- [Exemplos rápidos](#exemplos-rápidos)

---

## Formato de entrada
O script lê, por padrão, o arquivo **`lista.txt`** (ou um arquivo informado como argumento). As colunas são separadas por **espaço/brancos**:

1. `IDTPerson`
2. `idt_inscription`
3. `IDTPlano`
4. `nam_login` (**usado como usuário**)
5. `des_path_folder` (**usado como domínio**)
6. extras (ignorados)

Linhas em branco e cabeçalhos são ignorados.

---

## Dependências
- `bash`
- `curl` e `jq` (APIs internas / parsing de JSON)
- `dig` (DNS; obrigatório em `--A` e `--SOA`)
- `host` (fallback DNS opcional)
- `whois` (obrigatório em `--PROVEDOR`)

> **Dica**: em Debian/Ubuntu: `sudo apt-get install -y jq dnsutils whois`  
> Em RHEL/CentOS/Fedora: `sudo dnf install -y jq bind-utils jwhois`

---

## Variáveis de ambiente úteis
- `SLEEP_SECS` — pausa entre iterações (padrão: `5`).
- `DEBUG=1` — liga o modo verboso (traços no `stderr`).
- `NO_COLOR=1` — desativa cores (aplicável ao `--A` e ao sumário).

---

## Funções / Modos

### Padrão (sem flags)
**Sintaxe**
```bash
./GeraListaMigrador.sh [arquivo]
```
**Saída** (8 campos separados por espaço):
```
IDTPerson idt_inscription IDTPlano nam_login /mnt/<server>/<pool>-<filesystem>/<userpath> <domínio> idt_domain phpNN
```
- `phpNN` extraído de `application` (suporta `php-version=XX[.Y]`, `template=phpXX[.Y]` e fallback `phpXX[.Y]`).
- Se ocorrer falha/404 da API → imprime `"<user> -"`.

---

### --REDIS
**Sintaxe**
```bash
./GeraListaMigrador.sh --REDIS [arquivo]
```
**Saída**
```
<nam_login> <enabled>
```
- `<enabled>` em minúsculas (`on`/`off`), ou `-` quando ausente/falha.
- Em 404/vazio → `"<user> -"`.

---

### --A
**Sintaxe**
```bash
./GeraListaMigrador.sh --A [arquivo]
```
**Saída**
```
<nam_login> <des_path_folder> <IP|apelido|NODATA|NXDOMAIN|->
```
**Regras DNS**
- **IP**: retorna **um único** IPv4 (primeiro A encontrado).
- **NODATA**: `status=NOERROR` e **nenhum registro A** na ANSWER (mesmo que haja CNAME/AAAA).
- **NXDOMAIN**: nome inexistente ou erro DNS (`SERVFAIL`, `REFUSED`, `FORMERR`, etc.).
- `-`: fallback atípico.

**Cores (opcional)**
- IPs em **amarelo**, apelidos (ex.: `asgard3`, `HK`, `DUDA`) em **ciano**; marcadores `NODATA/NXDOMAIN/-` **sem cor**.
- Desabilite com `NO_COLOR=1`.

---

### --SUMMARY (somente com --A)
**Sintaxe**
```bash
./GeraListaMigrador.sh --A --SUMMARY [arquivo]
```
Após listar todas as linhas, imprime um **SUMÁRIO**:
```
# TOTAL:
<apelido/IP/NODATA/NXDOMAIN/-> - <contagem> dominios
...
```
- Ordenado por contagem decrescente.
- Respeita as mesmas cores do `--A`.

---

### --HOSTHEADER
**Sintaxe**
```bash
./GeraListaMigrador.sh --HOSTHEADER [arquivo]
```
**Objetivo**: escolher o domínio "real" a partir de `domains_and_hostheaders`.

**Regra de seleção**
1. Obtém a primeira chave (o **main**) e sua lista de hostheaders.
2. **Filtra fora**:
   - domínios que terminem com `.dominiotemporario.com`;
   - domínios que terminem com `.sslblindado.com`;
   - domínios que **comecem** com `www.` (case-insensitive).
3. Entre os restantes:
   - se existir **algum** que **não** seja `mps[13 dígitos].com`, escolhe o **primeiro** desses;
   - caso **só sobrem** `mps[13].com`, escolhe o **primeiro** `mps…`;
   - se **nada sobrar**, retorna o **main**.

**Saída**
```
<nam_login> <dominio_escolhido>
```

---

### --PROVEDOR
**Sintaxe**
```bash
./GeraListaMigrador.sh --PROVEDOR [arquivo]
```
Executa `whois <domínio>` e classifica o **provedor de registro**:
- Se encontrar `provider: UOLHOST` **ou** `Reseller: UOL Host` → **`UOLHOST`**
- Se **nenhum** dos campos (`provider:`/`reseller:`) existir → **`none`**
- Se existir `provider`/`reseller`, **mas não** for UOL → **`outros`**

**Saída**
```
<nam_login> <des_path_folder> <UOLHOST|outros|none>
```

---

### --SOA
**Sintaxe**
```bash
./GeraListaMigrador.sh --SOA [arquivo]
```
Busca o **SOA** do domínio, com tolerância a NXDOMAIN (usa SOA da **AUTHORITY** quando necessário). Ordem de tentativa:
1. `dig <domínio> SOA +short +time=3 +tries=1`
2. `dig <domínio> SOA +noall +answer` (RDATA SOA)
3. `dig <domínio> SOA +noall +authority` (RDATA SOA — útil para NXDOMAIN)
4. Se todas as tentativas falharem, verifica `status:`; quando `NXDOMAIN` → imprime `NXDOMAIN`; caso contrário, `-`.

> Se houver múltiplas linhas, são **juntadas por `; `**.

**Saída (CSV sem aspas)**
```
user,dominio,soa
```
Ex.: `gonzatto1,gonzatto.com.br,ns1.exemplo.com. hostmaster.exemplo.com. 2026020601 7200 3600 1209600 3600`

---

### --HELP
**Sintaxe**
```bash
./GeraListaMigrador.sh --HELP
```
Imprime **apenas as sintaxes** listadas acima.

---

## Mapeamento de IP → apelido
O modo `--A` suporta mapeamento de IP para apelido (ex.: `186.234.81.10 → asgard3`).
- Mapa interno no script (`declare -A IP_MAP`).
- Arquivo opcional de legenda: `./ip_legend.txt` **ou** `/etc/gera_migrador/ip_legend.txt`  
  Formato por linha:
  ```
  <IP> <apelido>
  ```
  Ex.: `186.234.81.10 asgard3`

---

## Erros e comportamento silencioso
Para não poluir a saída:
- Em falhas/404 das APIs internas (modes **padrão** e **`--REDIS`**) → `"<user> -"`.
- Em `--A`, as classificações seguem as regras IP/NODATA/NXDOMAIN/-.
- Em `--HOSTHEADER`, se nada atender ao critério → retorna o **main**; se JSON vazio → `-`.
- Em `--PROVEDOR`, se `whois` não tiver `provider`/`reseller` → `none`.
- Em `--SOA`, se tudo falhar → `NXDOMAIN` (quando aplicável) ou `-`.

---

## Exemplos rápidos

```bash
# Padrão (8 colunas)
./GeraListaMigrador.sh

# REDIS (enabled)
./GeraListaMigrador.sh --REDIS

# DNS A (com mapeamento/cores)
./GeraListaMigrador.sh --A

# DNS A + SUMÁRIO
./GeraListaMigrador.sh --A --SUMMARY

# Hostheader real
./GeraListaMigrador.sh --HOSTHEADER

# Provedor de registro
./GeraListaMigrador.sh --PROVEDOR

# SOA em CSV (sem aspas)
./GeraListaMigrador.sh --SOA

# Ajuda
./GeraListaMigrador.sh --HELP
```

---

**Contato/Notas**
- Ajustes finos podem requerer depurações pontuais. Ative `DEBUG=1` para investigar comportamentos específicos.
- Caso apareçam variações de saída de DNS/WHOIS em seu ambiente, envie um exemplo para que o parser seja ajustado.
