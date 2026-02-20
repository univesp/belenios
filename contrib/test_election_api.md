# Rodar a API do Belenios do zero (local) + script de eleição de teste

Este guia mostra um fluxo mínimo para:
1. compilar o servidor,
2. subir uma instância local,
3. obter token de API admin,
4. executar `contrib/test_election_api.py`.

## 1) Preparar dependências e compilar

No Debian/Ubuntu, instale as dependências base (resumo):

```bash
sudo apt install bubblewrap build-essential libgmp-dev libsodium-dev pkg-config m4 libssl-dev libsqlite3-dev wget ca-certificates zip unzip libncurses-dev zlib1g-dev libgd-securityimage-perl cracklib-runtime jq npm
```

Depois, no repositório:

```bash
./opam-bootstrap.sh
source env.sh
make build-release-server
```

> Se você já tem ambiente OCaml/OPAM pronto, pode pular o bootstrap e apenas garantir as dependências + `make build-release-server`.

## 2) Subir o servidor local

Ainda na raiz do repositório:

```bash
demo/run-server.sh
```

Por padrão, no modo demo ele sobe em `http://localhost:8001/`.

## 3) Fazer login como admin e obter token

1. Abra `http://localhost:8001/` no navegador.
2. Faça login como administrador (modo demo).
3. Acesse a página `http://localhost:8001/api-token` e copie o token.

## 4) Descobrir o `admin-id`

Com o token em mãos:

```bash
curl -sS \
  -H "Authorization: Bearer $TOKEN" \
  http://localhost:8001/api/account | jq
```

Use o campo `id` retornado como `--admin-id`.

## 5) Criar e preparar uma eleição de teste (fluxo completo)

```bash
python3 contrib/test_election_api.py \
  --url http://localhost:8001/ \
  --token "$TOKEN" \
  bootstrap --admin-id 1 --voters 5 --open
```

Isso faz:
- cria draft,
- cadastra eleitores,
- gera senhas (modo padrão `password`),
- solicita credenciais públicas,
- espera `draft/status` ficar pronto,
- valida a eleição,
- abre (se `--open`).

## 6) Comandos úteis do script

Listar eleições:

```bash
python3 contrib/test_election_api.py --url http://localhost:8001/ --token "$TOKEN" list
```

Status de uma eleição:

```bash
python3 contrib/test_election_api.py --url http://localhost:8001/ --token "$TOKEN" status <UUID>
```

Ação administrativa:

```bash
python3 contrib/test_election_api.py --url http://localhost:8001/ --token "$TOKEN" action <UUID> Close
```

Remover eleição de teste:

```bash
python3 contrib/test_election_api.py --url http://localhost:8001/ --token "$TOKEN" delete <UUID>
```

## Observações

- Se você usar `--auth demo`, o fluxo não gera senhas de eleitores.
- Em ambientes reais, prefira HTTPS e dados reais de contato/autenticação.
