# Rodar API/script na homolog da UNIVESP

Script configurado para usar por padrão:

- `https://homolog.votacao.univesp.br/`

## 1) Descobrir token e admin-id

### Tentativa automática de token (usuário `admin`)

```bash
python3 contrib/test_election_api.py --password '<SENHA_ADMIN>' whoami
```

O script tenta:
1. login web em `/login?service=password`;
2. leitura de `/api-token` com a sessão;
3. se falhar, usa fallback: `nxhVMYKvFpWo98e36JaHf4`.

### Usar token explícito

```bash
python3 contrib/test_election_api.py --token 'SEU_TOKEN' whoami
```

O comando `whoami` chama `/api/account` e retorna o `id` (admin-id).

## 2) Criar eleição de teste completa

Com admin-id automático:

```bash
python3 contrib/test_election_api.py --password '<SENHA_ADMIN>' bootstrap --voters 5 --open
```

Com admin-id explícito:

```bash
python3 contrib/test_election_api.py --token 'SEU_TOKEN' bootstrap --admin-id 1 --voters 5 --open
```

## 3) Operações úteis

```bash
python3 contrib/test_election_api.py list
python3 contrib/test_election_api.py status <UUID>
python3 contrib/test_election_api.py action <UUID> Close
python3 contrib/test_election_api.py delete <UUID>
```

## Observações

- Se não passar `--token`, o script tenta token automático (quando houver `--password`) e depois fallback.
- Você pode sobrescrever o host com `--url`.
