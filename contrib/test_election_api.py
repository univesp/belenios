#!/usr/bin/env python3
"""Script para criar e gerenciar uma eleição de teste via API pública do Belenios.

Fluxo principal (`bootstrap`):
1. Cria um rascunho de eleição.
2. Cadastra eleitores.
3. Gera senhas para os eleitores (quando `--auth password`).
4. Solicita geração de credenciais públicas no servidor.
5. Aguarda o rascunho ficar pronto e valida a eleição.
6. Opcionalmente abre a eleição.

Também inclui subcomandos para listar eleições, consultar status e executar ações
administrativas (abrir, fechar, arquivar e excluir).
"""

import argparse
import json
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from typing import Any


class ApiError(RuntimeError):
    pass


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
    voters = []
    for idx in range(1, count + 1):
        voters.append({"address": f"eleitor{idx:0{width}}@{domain}"})
    return voters


def wait_until_ready(
    api: BeleniosApi, uuid: str, timeout_s: int, interval_s: int
) -> dict[str, Any]:
    deadline = time.time() + timeout_s
    while time.time() < deadline:
        status = api.get(f"elections/{uuid}/draft/status")
        if status.get("credentials_ready") and status.get("trustees_ready"):
            return status
        time.sleep(interval_s)
    raise ApiError(
        "Tempo esgotado aguardando credenciais/trustees prontos. "
        "Verifique em /api/elections/<UUID>/draft/status"
    )


def bootstrap(args: argparse.Namespace) -> None:
    api = BeleniosApi(args.url, args.token, timeout=args.timeout)

    draft = make_draft(args.admin_id, args.group, args.auth)
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
    print(
        "[ok] Draft pronto: "
        f"credentials_ready={status.get('credentials_ready')}, "
        f"trustees_ready={status.get('trustees_ready')}"
    )

    api.post(f"elections/{uuid}/draft", "ValidateElection")
    print("[ok] Eleição validada")

    if args.open:
        api.post(f"elections/{uuid}", "Open")
        print("[ok] Eleição aberta")

    print("\nResumo:")
    print(json.dumps({"uuid": uuid, "draft_status": status}, ensure_ascii=False, indent=2))


def list_elections(args: argparse.Namespace) -> None:
    api = BeleniosApi(args.url, args.token, timeout=args.timeout)
    data = api.get("elections")
    print(json.dumps(data, ensure_ascii=False, indent=2))


def election_status(args: argparse.Namespace) -> None:
    api = BeleniosApi(args.url, args.token, timeout=args.timeout)
    data = api.get(f"elections/{args.uuid}")
    print(json.dumps(data, ensure_ascii=False, indent=2))


def admin_action(args: argparse.Namespace) -> None:
    api = BeleniosApi(args.url, args.token, timeout=args.timeout)
    api.post(f"elections/{args.uuid}", args.action)
    print(f"[ok] Ação {args.action} executada para {args.uuid}")


def delete_election(args: argparse.Namespace) -> None:
    api = BeleniosApi(args.url, args.token, timeout=args.timeout)
    api.delete(f"elections/{args.uuid}")
    print(f"[ok] Eleição {args.uuid} removida")


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description="Criar e gerenciar eleição de teste via API do Belenios",
        epilog=(
            "Exemplo rápido:\n"
            "  python3 contrib/test_election_api.py --url http://localhost:8001/ "
            "--token <TOKEN> bootstrap --admin-id 1 --voters 5 --open\n\n"
            "Para um passo a passo completo (subir servidor, obter token e rodar o script), "
            "veja: contrib/test_election_api.md"
        ),
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    parser.add_argument("--url", required=True, help="URL base, ex.: https://vote.exemplo.org/")
    parser.add_argument("--token", required=True, help="Token administrativo da API")
    parser.add_argument("--timeout", type=int, default=30, help="Timeout HTTP em segundos")

    sub = parser.add_subparsers(dest="command", required=True)

    p_bootstrap = sub.add_parser("bootstrap", help="Cria e prepara uma eleição de teste")
    p_bootstrap.add_argument("--admin-id", type=int, required=True, help="ID numérico da conta admin")
    p_bootstrap.add_argument("--voters", type=int, default=5, help="Quantidade de eleitores")
    p_bootstrap.add_argument("--domain", default="example.org", help="Domínio de e-mail dos eleitores")
    p_bootstrap.add_argument("--group", default="Ed25519", help="Grupo criptográfico")
    p_bootstrap.add_argument(
        "--auth",
        choices=["password", "demo"],
        default="password",
        help="Modo de autenticação da eleição",
    )
    p_bootstrap.add_argument("--open", action="store_true", help="Abre a eleição após validar")
    p_bootstrap.add_argument("--ready-timeout", type=int, default=120, help="Tempo máx. de espera (s)")
    p_bootstrap.add_argument("--poll-interval", type=int, default=3, help="Intervalo de polling (s)")
    p_bootstrap.set_defaults(func=bootstrap)

    p_list = sub.add_parser("list", help="Lista eleições do administrador")
    p_list.set_defaults(func=list_elections)

    p_status = sub.add_parser("status", help="Mostra status de uma eleição")
    p_status.add_argument("uuid", help="UUID da eleição")
    p_status.set_defaults(func=election_status)

    p_action = sub.add_parser("action", help="Executa ação administrativa em uma eleição")
    p_action.add_argument("uuid", help="UUID da eleição")
    p_action.add_argument(
        "action",
        choices=["Open", "Close", "ComputeEncryptedTally", "ReleaseTally", "Archive"],
        help="Ação administrativa",
    )
    p_action.set_defaults(func=admin_action)

    p_delete = sub.add_parser("delete", help="Remove uma eleição")
    p_delete.add_argument("uuid", help="UUID da eleição")
    p_delete.set_defaults(func=delete_election)

    return parser


def main() -> int:
    parser = build_parser()
    args = parser.parse_args()

    try:
        args.func(args)
        return 0
    except ApiError as exc:
        print(f"[erro] {exc}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
