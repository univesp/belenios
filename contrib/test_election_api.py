#!/usr/bin/env python3
"""Script para criar e gerenciar uma eleição de teste via API pública do Belenios."""

import argparse
import json
import re
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from http.cookiejar import CookieJar
from typing import Any

DEFAULT_URL = "https://homolog.votacao.univesp.br/"
FALLBACK_TOKEN = "nxhVMYKvFpWo98e36JaHf4"


class ApiError(RuntimeError):
    pass


class SessionClient:
    """Cliente HTTP com cookies para tentar autenticação web e obter /api-token."""

    def __init__(self, base_url: str, timeout: int = 30):
        self.base_url = base_url.rstrip("/") + "/"
        self.timeout = timeout
        self.jar = CookieJar()
        self.opener = urllib.request.build_opener(urllib.request.HTTPCookieProcessor(self.jar))

    def request(self, method: str, path_or_url: str, form: dict[str, str] | None = None) -> str:
        url = (
            path_or_url
            if path_or_url.startswith("http://") or path_or_url.startswith("https://")
            else urllib.parse.urljoin(self.base_url, path_or_url)
        )
        data = None
        headers = {"Accept": "text/html,application/json;q=0.9,*/*;q=0.8"}
        if form is not None:
            data = urllib.parse.urlencode(form).encode("utf-8")
            headers["Content-Type"] = "application/x-www-form-urlencoded"
        req = urllib.request.Request(url, data=data, headers=headers, method=method)
        with self.opener.open(req, timeout=self.timeout) as resp:
            return resp.read().decode("utf-8", errors="replace")


class BeleniosApi:
    def __init__(self, base_url: str, token: str, timeout: int = 30):
        self.api_root = urllib.parse.urljoin(base_url.rstrip("/") + "/", "api/")
        self.token = token
        self.timeout = timeout

    def _request(self, method: str, path: str, payload: Any | None = None) -> Any:
        url = urllib.parse.urljoin(self.api_root, path)
        data = None
        headers = {
            "Authorization": f"Bearer {self.token}",
            "Accept": "application/json",
        }

        if payload is not None:
            data = json.dumps(payload).encode("utf-8")
            headers["Content-Type"] = "application/json"

        req = urllib.request.Request(url, data=data, headers=headers, method=method)
        try:
            with urllib.request.urlopen(req, timeout=self.timeout) as resp:
                body = resp.read().decode("utf-8")
                if not body:
                    return None
                return json.loads(body)
        except urllib.error.HTTPError as exc:
            detail = exc.read().decode("utf-8", errors="replace")
            raise ApiError(f"HTTP {exc.code} em {method} {path}: {detail}") from exc
        except urllib.error.URLError as exc:
            raise ApiError(f"Falha de conexão em {method} {path}: {exc}") from exc

    def get(self, path: str) -> Any:
        return self._request("GET", path)

    def post(self, path: str, payload: Any) -> Any:
        return self._request("POST", path, payload)

    def put(self, path: str, payload: Any) -> Any:
        return self._request("PUT", path, payload)

    def delete(self, path: str) -> Any:
        return self._request("DELETE", path)


def try_get_api_token(base_url: str, username: str, password: str, timeout: int) -> str | None:
    """Tenta login web (serviço password) e depois lê /api-token."""
    c = SessionClient(base_url, timeout=timeout)
    try:
        login_html = c.request("GET", "login?service=password")
    except Exception:
        return None

    state_match = re.search(r'name="state"\s+value="([^"]+)"', login_html)
    if not state_match:
        return None
    state = state_match.group(1)

    # Formulário password usa campos state/login/password (veja pages_common.ml)
    try:
        c.request(
            "POST",
            "login?service=password",
            form={"state": state, "login": username, "password": password},
        )
        token = c.request("GET", "api-token").strip()
    except Exception:
        return None

    if token and token.lower() != "forbidden" and "<" not in token:
        return token
    return None


def resolve_token(args: argparse.Namespace) -> str:
    if args.token:
        return args.token

    if args.password:
        print(f"[info] Tentando obter token automaticamente para usuário {args.username}...")
        token = try_get_api_token(args.url, args.username, args.password, args.timeout)
        if token:
            print("[ok] Token obtido via /api-token")
            return token
        print("[warn] Não foi possível obter token automaticamente.")

    print("[info] Usando token fallback informado.")
    return FALLBACK_TOKEN


def discover_admin_id(api: BeleniosApi) -> int:
    account = api.get("account")
    admin_id = account.get("id")
    if not isinstance(admin_id, int):
        raise ApiError(f"Não foi possível descobrir admin-id em /api/account: {account!r}")
    return admin_id


def make_draft(admin_id: int, group: str, auth_mode: str) -> dict[str, Any]:
    auth_value: Any
    if auth_mode == "password":
        auth_value = "Password"
    elif auth_mode == "demo":
        auth_value = ["Configured", "demo"]
    else:
        raise ValueError("auth_mode deve ser 'password' ou 'demo'")

    return {
        "version": 1,
        "owners": [admin_id],
        "questions": {
            "description": "Eleição de teste criada automaticamente via API.",
            "name": "Eleição de Teste (API)",
            "questions": [
                {
                    "question": "Qual opção você prefere?",
                    "answers": ["Opção A", "Opção B", "Opção C"],
                    "min": 1,
                    "max": 1,
                }
            ],
            "administrator": "Administrador API",
            "credential_authority": "server",
        },
        "languages": ["pt", "en"],
        "contact": "Administrador API <admin@example.org>",
        "booth": 2,
        "authentication": auth_value,
        "group": group,
        "cred_authority_info": None,
    }


def voter_list(count: int, domain: str) -> list[dict[str, str]]:
    width = len(str(count))
    return [{"address": f"eleitor{idx:0{width}}@{domain}"} for idx in range(1, count + 1)]


def wait_until_ready(api: BeleniosApi, uuid: str, timeout_s: int, interval_s: int) -> dict[str, Any]:
    deadline = time.time() + timeout_s
    while time.time() < deadline:
        status = api.get(f"elections/{uuid}/draft/status")
        if status.get("credentials_ready") and status.get("trustees_ready"):
            return status
        time.sleep(interval_s)
    raise ApiError("Tempo esgotado aguardando credenciais/trustees prontos")


def bootstrap(args: argparse.Namespace) -> None:
    token = resolve_token(args)
    api = BeleniosApi(args.url, token, timeout=args.timeout)

    admin_id = args.admin_id if args.admin_id is not None else discover_admin_id(api)
    print(f"[ok] admin-id: {admin_id}")

    draft = make_draft(admin_id, args.group, args.auth)
    uuid = api.post("elections", draft)
    if not isinstance(uuid, str):
        raise ApiError(f"Resposta inesperada ao criar eleição: {uuid!r}")
    print(f"[ok] Draft criado: {uuid}")

    voters = voter_list(args.voters, args.domain)
    api.put(f"elections/{uuid}/draft/voters", voters)
    print(f"[ok] {len(voters)} eleitores cadastrados")

    if args.auth == "password":
        api.post(f"elections/{uuid}/draft/passwords", voters)
        print("[ok] Senhas geradas para os eleitores")

    api.post(f"elections/{uuid}/draft/credentials/public", [])
    print("[ok] Geração de credenciais públicas solicitada")

    status = wait_until_ready(api, uuid, args.ready_timeout, args.poll_interval)
    print("[ok] Draft pronto")

    api.post(f"elections/{uuid}/draft", "ValidateElection")
    print("[ok] Eleição validada")

    if args.open:
        api.post(f"elections/{uuid}", "Open")
        print("[ok] Eleição aberta")

    print(json.dumps({"uuid": uuid, "admin_id": admin_id, "draft_status": status}, ensure_ascii=False, indent=2))


def list_elections(args: argparse.Namespace) -> None:
    token = resolve_token(args)
    api = BeleniosApi(args.url, token, timeout=args.timeout)
    print(json.dumps(api.get("elections"), ensure_ascii=False, indent=2))


def election_status(args: argparse.Namespace) -> None:
    token = resolve_token(args)
    api = BeleniosApi(args.url, token, timeout=args.timeout)
    print(json.dumps(api.get(f"elections/{args.uuid}"), ensure_ascii=False, indent=2))


def admin_action(args: argparse.Namespace) -> None:
    token = resolve_token(args)
    api = BeleniosApi(args.url, token, timeout=args.timeout)
    api.post(f"elections/{args.uuid}", args.action)
    print(f"[ok] Ação {args.action} executada para {args.uuid}")


def delete_election(args: argparse.Namespace) -> None:
    token = resolve_token(args)
    api = BeleniosApi(args.url, token, timeout=args.timeout)
    api.delete(f"elections/{args.uuid}")
    print(f"[ok] Eleição {args.uuid} removida")


def whoami(args: argparse.Namespace) -> None:
    token = resolve_token(args)
    api = BeleniosApi(args.url, token, timeout=args.timeout)
    account = api.get("account")
    print(json.dumps(account, ensure_ascii=False, indent=2))


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description="Criar e gerenciar eleição de teste via API do Belenios",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog=(
            "Host default: https://homolog.votacao.univesp.br/\n"
            "Tentativa de token: informe --password para usuário admin (ou --username).\n"
            f"Fallback automático: {FALLBACK_TOKEN}"
        ),
    )
    parser.add_argument("--url", default=DEFAULT_URL, help="URL base da instância")
    parser.add_argument("--token", help="Token administrativo da API (se omitido, tenta auto-login e fallback)")
    parser.add_argument("--username", default="admin", help="Usuário para tentativa de login web")
    parser.add_argument("--password", help="Senha para tentativa de login web e obtenção do /api-token")
    parser.add_argument("--timeout", type=int, default=30, help="Timeout HTTP em segundos")

    sub = parser.add_subparsers(dest="command", required=True)

    p_bootstrap = sub.add_parser("bootstrap", help="Cria e prepara uma eleição de teste")
    p_bootstrap.add_argument("--admin-id", type=int, help="ID numérico da conta admin (auto se omitido)")
    p_bootstrap.add_argument("--voters", type=int, default=5, help="Quantidade de eleitores")
    p_bootstrap.add_argument("--domain", default="example.org", help="Domínio de e-mail dos eleitores")
    p_bootstrap.add_argument("--group", default="Ed25519", help="Grupo criptográfico")
    p_bootstrap.add_argument("--auth", choices=["password", "demo"], default="password")
    p_bootstrap.add_argument("--open", action="store_true", help="Abre a eleição após validar")
    p_bootstrap.add_argument("--ready-timeout", type=int, default=120)
    p_bootstrap.add_argument("--poll-interval", type=int, default=3)
    p_bootstrap.set_defaults(func=bootstrap)

    p_list = sub.add_parser("list", help="Lista eleições do administrador")
    p_list.set_defaults(func=list_elections)

    p_status = sub.add_parser("status", help="Mostra status de uma eleição")
    p_status.add_argument("uuid")
    p_status.set_defaults(func=election_status)

    p_action = sub.add_parser("action", help="Executa ação administrativa em uma eleição")
    p_action.add_argument("uuid")
    p_action.add_argument("action", choices=["Open", "Close", "ComputeEncryptedTally", "ReleaseTally", "Archive"])
    p_action.set_defaults(func=admin_action)

    p_delete = sub.add_parser("delete", help="Remove uma eleição")
    p_delete.add_argument("uuid")
    p_delete.set_defaults(func=delete_election)

    p_whoami = sub.add_parser("whoami", help="Descobre conta atual (inclui admin-id)")
    p_whoami.set_defaults(func=whoami)

    return parser


def main() -> int:
    args = build_parser().parse_args()
    try:
        args.func(args)
        return 0
    except ApiError as exc:
        print(f"[erro] {exc}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
