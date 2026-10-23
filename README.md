# php-security-patch

Script Bash interativo para aplicar a correção de segurança do PHP, ou migrar para um branch superior, com **backup automático, validação e rollback**.

> **UPDATE NOW — PHP2Shell (CVE-2026-109618 e CVE-2026-109619)**
> Em 21/10/2026 o PHP publicou correções emergenciais para duas falhas críticas (CVSS 9.2) no núcleo da linguagem. Elas permitem **execução remota de código sem autenticação** e afetam praticamente toda instalação que serve páginas web: PHP-FPM, Apache mod_php, php-cgi, FrankenPHP e LiteSpeed. Já existem tentativas de exploração registradas.

| Branch | Versão corrigida |
|---|---|
| 8.5 | **8.5.12** |
| 8.4 | **8.4.27** |
| 8.3 | **8.3.36** |
| 8.2 | **8.2.35** |
| 8.1 ou anterior | sem correção oficial: migre de branch |

Se o seu servidor ficou exposto, investigue os logs a partir de **17/10/2026**: a primeira tentativa de ataque foi vista quatro dias antes da divulgação.

---

## ⚠️ Aviso de responsabilidade

Este script é fornecido **"como está"**, sem garantias de qualquer tipo. O uso é de inteira responsabilidade de quem o executa. O autor **não se responsabiliza** por falhas, perda de dados ou indisponibilidade decorrentes do seu uso.

**Antes de rodar:**

- Faça **backup das configurações, dos sites e dos bancos de dados** (snapshot da VM, se possível).
- Rode **primeiro em um servidor de homologação**, depois em produção.
- Comece com `--dry-run` para ver o plano sem alterar nada.
- Migre **um branch por vez**: 8.3 → 8.4, valide a aplicação, e só então 8.4 → 8.5. Saltos maiores acumulam mudanças de compatibilidade e dificultam encontrar a causa de um problema.

---

## Como funciona

1. Detecta a distribuição e as versões de PHP 8.x instaladas (o script não atua em PHP 7 ou anterior, nem em PHP compilado da fonte).
2. Consulta o php.net para saber qual é o release corrigido do seu branch e até quando ele tem suporte.
3. Mostra os CVEs que a sua distro já corrigiu por backport.
4. Você escolhe o caminho:

| Opção | O que faz | Risco |
|---|---|---|
| **1. Patch da distro** | Mantém a versão e usa só o repositório oficial do sistema | Baixo |
| **2. Release oficial** | Mantém o branch e instala o último release do php.net (adiciona o repositório abaixo) | Médio |
| **3. Migrar de branch** | Instala um branch superior. No Debian/Ubuntu, lado a lado, com teste de sintaxe do seu código antes da troca | Maior |

5. Faz backup de pacotes e configurações antes de qualquer alteração.
6. Valida CLI, módulos, Apache/Nginx/PHP-FPM e health check, e confere qual versão o servidor web está executando de fato.
7. Se algo falhar, oferece **rollback automático** (ou manual, com `--rollback`).

### Repositórios usados para os releases oficiais

| Distribuição | Repositório |
|---|---|
| Ubuntu | PPA `ondrej/php` |
| Debian | `packages.sury.org/php` |
| RHEL, Oracle Linux, Rocky, Alma | Remi (`rpms.remirepo.net`) + EPEL + CodeReady Builder |
| Fedora | Remi |

São repositórios de terceiros. O php.net informa que os binários do Ondřej Surý contêm patches próprios do mantenedor; revise antes de usar em produção.

---

## Testado em

**Ubuntu 24.04.4 LTS** com Apache + mod_php, nesta sequência:

```
8.3.6 → 8.3.36 → 8.4.27 → 8.5.12
```

A aplicação seguiu funcionando em todas as etapas. O suporte a Debian, RHEL, Oracle Linux, Rocky, Alma e Fedora está implementado, mas ainda **não foi testado** pelo autor nessas distros. Relatos de teste são bem-vindos nas Issues.

---

## Uso

```bash
wget https://raw.githubusercontent.com/ajuricabacosta/php-security-patch/main/php-security-patch.sh

# 1) Ver o plano sem alterar nada
sudo bash php-security-patch.sh --dry-run

# 2) Execução interativa (menu), com teste da aplicação
sudo bash php-security-patch.sh --app-dir /var/www/seusite --probe-url http://localhost/

# 3) Migrar direto para um branch
sudo bash php-security-patch.sh --mode upgrade --target 8.4 --app-dir /var/www/seusite
```

### Opções

| Opção | Descrição |
|---|---|
| `--mode MODO` | `distro`, `official` ou `upgrade` (sem isso, mostra o menu) |
| `--target X.Y` | Branch de destino no modo `upgrade` (ex.: `8.4`) |
| `--app-dir DIR` | Raiz do site, usada no teste de sintaxe e no teste de versão web |
| `--probe-url URL` | URL que serve o `--app-dir`; confere qual PHP o servidor executa |
| `--url URL` | Health check da aplicação (espera HTTP 2xx/3xx) |
| `--dry-run` | Mostra o plano, sem alterar nada |
| `-y`, `--yes` | Responde "sim" a tudo (automação) |
| `--rollback DIR` | Reverte a partir de um backup anterior |

### Backup e rollback

Cada execução grava em `/var/backups/php-patch/<data-hora>` os pacotes atuais (`.deb`/`.rpm`), as configurações do PHP e do servidor web e a lista de módulos. O log fica em `/var/log/php-security-patch-<data-hora>.log`.

```bash
sudo bash php-security-patch.sh --rollback /var/backups/php-patch/20261023-140517
```

Na migração lado a lado (Debian/Ubuntu) o PHP antigo continua instalado; voltar é desfazer a troca. No RHEL/Oracle Linux a troca é feita no lugar, e o rollback restaura o stream de módulo e os RPMs salvos.

---

## Não dá para atualizar hoje?

Paliativos indicados pelo PHP (reduzem a exposição, **não corrigem**):

```ini
; CVE-2026-109618
memory_limit = -1
post_max_size = (o menor possível para a aplicação)

; CVE-2026-109619
session.upload_progress.enabled = 0
fatal_error_backtraces = 0   ; só PHP 8.5
```

Complemente com limite de memória por container/cgroup, limite de tamanho de requisição no proxy, WAF ou isolamento das aplicações expostas, e reinicie todos os workers. Só atualizar resolve.

---

## Referências

- [CERT-EU — Security Advisory 2026-018](https://cert.europa.eu/publications/security-advisories/2026-018/)
- [Tenable — PHP2Shell FAQ](https://www.tenable.com/blog/php2shell-cve-2026-109618-cve-2026-109619-frequently-asked-questions-about-critical-php-remote)
- [The Hacker News — PHP2Shell](https://thehackernews.com/2026/10/php-issues-emergency-patches-for-two.html)
- [php.net — Releases](https://www.php.net/releases/)

## Licença

[MIT](LICENSE) © José Ajuricaba Brito da Costa e Silva — [@ajuricabacosta](https://www.linkedin.com/in/ajuricabacosta) · [ajuricaba.net](https://ajuricaba.net)

Sugestões, correções e relatos de teste são bem-vindos via Issues e Pull Requests.
