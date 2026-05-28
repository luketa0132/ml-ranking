#!/usr/bin/env bash
#
# install.sh — Instalação automática da ML Ranking API
# Rode DENTRO da VM Ubuntu Server.
#
# Uso:
#   chmod +x install.sh
#   ./install.sh
#
# O que faz:
#   1. Instala Python, venv e dependências de sistema
#   2. Cria a pasta do projeto e baixa/copia os arquivos da API
#   3. Cria o ambiente virtual e instala FastAPI + Playwright
#   4. Baixa o Chromium headless + libs de sistema
#   5. Gera uma API key forte automaticamente
#   6. Cria e inicia um serviço systemd (sobe sozinho no boot)
#
set -euo pipefail

# ---------- Configuração ----------
APP_DIR="${HOME}/ml-ranking-api"
SERVICE_NAME="ml-ranking"
PORT="8000"
# ----------------------------------

log()  { printf "\n\033[1;32m[+] %s\033[0m\n" "$*"; }
warn() { printf "\n\033[1;33m[!] %s\033[0m\n" "$*"; }
err()  { printf "\n\033[1;31m[x] %s\033[0m\n" "$*" >&2; }

if [[ "$(uname -s)" != "Linux" ]]; then
    err "Este script é para Linux (Ubuntu Server, dentro da VM). Saindo."
    exit 1
fi

# ---------- 1. Dependências de sistema ----------
log "Atualizando pacotes e instalando Python..."
sudo apt-get update -y
sudo apt-get install -y python3 python3-venv python3-pip curl

# ---------- 2. Pasta do projeto + arquivos ----------
log "Preparando pasta do projeto em ${APP_DIR}..."
mkdir -p "${APP_DIR}"
cd "${APP_DIR}"

# Se os arquivos da API NÃO estiverem na pasta, este script os cria.
# (Se você já copiou scraper.py / main.py / requirements.txt pra cá, eles serão mantidos.)

if [[ ! -f "${APP_DIR}/requirements.txt" ]]; then
    log "Criando requirements.txt..."
    cat > "${APP_DIR}/requirements.txt" <<'EOF'
fastapi==0.115.0
uvicorn[standard]==0.30.6
playwright==1.47.0
EOF
fi

if [[ ! -f "${APP_DIR}/scraper.py" ]]; then
    log "Criando scraper.py..."
    cat > "${APP_DIR}/scraper.py" <<'EOF'
"""
Scraper da busca pública do Mercado Livre usando Playwright (browser real headless).
"""
import asyncio
from urllib.parse import quote_plus

from playwright.async_api import async_playwright

MAX_PAGES = 4
DELAY_BETWEEN_PAGES = 2.5


def _build_url(query: str, offset: int) -> str:
    q = quote_plus(query.strip())
    if offset <= 1:
        return f"https://lista.mercadolivre.com.br/{q}"
    return f"https://lista.mercadolivre.com.br/{q}_Desde_{offset}"


async def _extract_items_from_page(page):
    return await page.evaluate(
        """
        () => {
            const cards = document.querySelectorAll('li.ui-search-layout__item, div.ui-search-result__wrapper');
            const out = [];
            cards.forEach((card) => {
                const linkEl = card.querySelector('a.ui-search-link, a.poly-component__title, a[href*="/MLB-"], a[href*="produto.mercadolivre"]');
                const titleEl = card.querySelector('.ui-search-item__title, .poly-component__title, h2, h3');
                const priceEl = card.querySelector('.andes-money-amount__fraction');
                const sellerEl = card.querySelector('.ui-search-official-store-label, .poly-component__seller');
                const href = linkEl ? linkEl.href : null;
                let itemId = null;
                if (href) {
                    const m = href.match(/MLB-?(\\d+)/);
                    if (m) itemId = 'MLB' + m[1];
                }
                out.push({
                    title: titleEl ? titleEl.innerText.trim() : (linkEl ? linkEl.innerText.trim() : null),
                    url: href,
                    item_id: itemId,
                    price: priceEl ? priceEl.innerText.trim() : null,
                    seller: sellerEl ? sellerEl.innerText.trim() : null,
                });
            });
            return out;
        }
        """
    )


async def search(query: str, max_pages: int = MAX_PAGES):
    results = []
    seen = set()
    async with async_playwright() as p:
        browser = await p.chromium.launch(
            headless=True,
            args=[
                "--no-sandbox",
                "--disable-blink-features=AutomationControlled",
                "--disable-dev-shm-usage",
            ],
        )
        context = await browser.new_context(
            user_agent=(
                "Mozilla/5.0 (Windows NT 10.0; Win64; x64) "
                "AppleWebKit/537.36 (KHTML, like Gecko) "
                "Chrome/124.0.0.0 Safari/537.36"
            ),
            locale="pt-BR",
            viewport={"width": 1366, "height": 768},
        )
        await context.add_init_script(
            "Object.defineProperty(navigator, 'webdriver', {get: () => undefined});"
        )
        page = await context.new_page()

        offset = 1
        for _ in range(max_pages):
            url = _build_url(query, offset)
            try:
                await page.goto(url, wait_until="domcontentloaded", timeout=30000)
                await page.wait_for_timeout(1500)
            except Exception as e:
                print(f"[scraper] erro ao carregar {url}: {e}")
                break

            items = await _extract_items_from_page(page)
            if not items:
                break

            for it in items:
                key = it.get("item_id") or it.get("url")
                if not key or key in seen:
                    continue
                seen.add(key)
                results.append(it)

            offset += 50
            await asyncio.sleep(DELAY_BETWEEN_PAGES)

        await browser.close()

    for i, it in enumerate(results, start=1):
        it["position"] = i
    return results


def find_my_ranking(items, *, my_item_id=None, my_seller=None):
    matches = []
    for it in items:
        hit = False
        if my_item_id and it.get("item_id"):
            if it["item_id"].upper() == my_item_id.upper():
                hit = True
        if my_seller and it.get("seller"):
            if my_seller.lower() in it["seller"].lower():
                hit = True
        if hit:
            matches.append(it)
    return matches
EOF
fi

if [[ ! -f "${APP_DIR}/main.py" ]]; then
    log "Criando main.py..."
    cat > "${APP_DIR}/main.py" <<'EOF'
"""
API REST para consultar o ranking de produtos no Mercado Livre.
Escuta apenas em 127.0.0.1 e exige header X-API-Key.
"""
import os

from fastapi import FastAPI, Header, HTTPException, Query
from fastapi.responses import JSONResponse

import scraper

API_KEY = os.environ.get("ML_API_KEY", "")

app = FastAPI(title="ML Ranking API", version="1.0")


def _check_key(x_api_key):
    if not API_KEY:
        raise HTTPException(status_code=500, detail="ML_API_KEY não configurada.")
    if x_api_key != API_KEY:
        raise HTTPException(status_code=401, detail="API key inválida.")


@app.get("/health")
async def health():
    return {"status": "ok"}


@app.get("/buscar")
async def buscar(
    q: str = Query(..., min_length=2),
    paginas: int = Query(scraper.MAX_PAGES, ge=1, le=10),
    x_api_key: str | None = Header(default=None, alias="X-API-Key"),
):
    _check_key(x_api_key)
    items = await scraper.search(q, max_pages=paginas)
    return JSONResponse({"query": q, "total": len(items), "items": items})


@app.get("/ranking")
async def ranking(
    q: str = Query(..., min_length=2),
    item_id: str | None = Query(default=None),
    seller: str | None = Query(default=None),
    paginas: int = Query(scraper.MAX_PAGES, ge=1, le=10),
    x_api_key: str | None = Header(default=None, alias="X-API-Key"),
):
    _check_key(x_api_key)
    if not item_id and not seller:
        raise HTTPException(status_code=400, detail="Informe item_id ou seller.")
    items = await scraper.search(q, max_pages=paginas)
    matches = scraper.find_my_ranking(items, my_item_id=item_id, my_seller=seller)
    return JSONResponse(
        {
            "query": q,
            "total_anuncios_varridos": len(items),
            "encontrado": len(matches) > 0,
            "minhas_posicoes": [
                {
                    "position": m["position"],
                    "title": m["title"],
                    "url": m["url"],
                    "item_id": m["item_id"],
                    "price": m["price"],
                }
                for m in matches
            ],
        }
    )
EOF
fi

# ---------- 3. venv + dependências Python ----------
log "Criando ambiente virtual e instalando dependências Python..."
python3 -m venv venv
# shellcheck disable=SC1091
source venv/bin/activate
pip install --upgrade pip
pip install -r requirements.txt

# ---------- 4. Chromium + libs de sistema ----------
log "Baixando Chromium headless e dependências de sistema (pode demorar)..."
python -m playwright install chromium
python -m playwright install-deps chromium

# ---------- 5. Gerar API key ----------
log "Gerando API key..."
ML_API_KEY="$(python -c 'import secrets; print(secrets.token_urlsafe(32))')"
echo "${ML_API_KEY}" > "${APP_DIR}/.api_key"
chmod 600 "${APP_DIR}/.api_key"

# ---------- 6. Serviço systemd ----------
log "Criando serviço systemd..."
CURRENT_USER="$(whoami)"
SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}.service"

sudo tee "${SERVICE_FILE}" > /dev/null <<EOF
[Unit]
Description=ML Ranking API
After=network.target

[Service]
User=${CURRENT_USER}
WorkingDirectory=${APP_DIR}
Environment=ML_API_KEY=${ML_API_KEY}
ExecStart=${APP_DIR}/venv/bin/uvicorn main:app --host 127.0.0.1 --port ${PORT}
Restart=always

[Install]
WantedBy=multi-user.target
EOF

sudo systemctl daemon-reload
sudo systemctl enable "${SERVICE_NAME}"
sudo systemctl restart "${SERVICE_NAME}"

sleep 3

# ---------- Verificação final ----------
log "Verificando se a API respondeu..."
if curl -fs -H "X-API-Key: ${ML_API_KEY}" "http://127.0.0.1:${PORT}/health" > /dev/null; then
    log "API NO AR! 🎉"
else
    warn "A API ainda não respondeu. Veja os logs com: sudo journalctl -u ${SERVICE_NAME} -e"
fi

# ---------- Resumo ----------
cat <<EOF

============================================================
  INSTALAÇÃO CONCLUÍDA
============================================================
  Pasta:        ${APP_DIR}
  Serviço:      ${SERVICE_NAME} (systemd, sobe no boot)
  Endereço:     http://127.0.0.1:${PORT}  (só dentro da VM)

  SUA API KEY (guarde!):
    ${ML_API_KEY}
  (também salva em ${APP_DIR}/.api_key)

  TESTES:
    KEY=\$(cat ${APP_DIR}/.api_key)

    curl -H "X-API-Key: \$KEY" http://127.0.0.1:${PORT}/health

    curl -H "X-API-Key: \$KEY" \\
      "http://127.0.0.1:${PORT}/buscar?q=selante+dw240"

    curl -H "X-API-Key: \$KEY" \\
      "http://127.0.0.1:${PORT}/ranking?q=selante+dw240&item_id=MLB1234567890"

  COMANDOS ÚTEIS:
    sudo systemctl status ${SERVICE_NAME}
    sudo systemctl restart ${SERVICE_NAME}
    sudo journalctl -u ${SERVICE_NAME} -e
============================================================
EOF
