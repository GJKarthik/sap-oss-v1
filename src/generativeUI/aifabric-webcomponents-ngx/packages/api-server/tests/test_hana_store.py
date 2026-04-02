from __future__ import annotations

from collections import defaultdict
import re

from src.store import HanaAppStore


class FakeHanaEnvironment:
    def __init__(self) -> None:
        self.schemas: dict[str, dict[str, dict]] = defaultdict(lambda: {"tables": {}})

    def connect(self) -> "FakeHanaConnection":
        return FakeHanaConnection(self)


class FakeHanaConnection:
    def __init__(self, env: FakeHanaEnvironment) -> None:
        self.env = env
        self.current_schema = "DEFAULT"

    def cursor(self) -> "FakeHanaCursor":
        return FakeHanaCursor(self)

    def commit(self) -> None:
        return None

    def rollback(self) -> None:
        return None

    def close(self) -> None:
        return None


class FakeHanaCursor:
    _IDENTIFIER_RE = re.compile(r'"([^"]+)"(?:\."([^"]+)")?')

    def __init__(self, connection: FakeHanaConnection) -> None:
        self.connection = connection
        self._results: list[tuple] = []
        self.rowcount = -1

    def close(self) -> None:
        return None

    def execute(self, sql: str, params: tuple | None = None) -> None:
        params = params or ()
        normalized = " ".join(sql.strip().split())

        if normalized.startswith("SET SCHEMA "):
            self.connection.current_schema = self._parse_last_identifier(normalized)[0]
            self._results = []
            return

        if "FROM SYS.TABLES" in normalized:
            schema = self.connection.current_schema
            existing = self.connection.env.schemas[schema]["tables"]
            self._results = [(table_name,) for table_name in params if table_name in existing]
            return

        if normalized.startswith("CREATE ROW TABLE "):
            schema, table_name = self._parse_first_table_identifier(normalized, keyword="TABLE")
            self.connection.env.schemas[schema]["tables"].setdefault(table_name, self._empty_table(table_name))
            self._results = []
            return

        schema, table_name = self._parse_first_table_identifier(normalized)
        table = self.connection.env.schemas[schema]["tables"].setdefault(table_name, self._empty_table(table_name))

        if normalized.startswith("SELECT "):
            self._handle_select(normalized, table_name, table, params)
            return

        if normalized.startswith("UPSERT "):
            self._handle_upsert(table_name, table, params)
            return

        if normalized.startswith("DELETE FROM "):
            self._handle_delete(normalized, table_name, table, params)
            return

        raise AssertionError(f"Unsupported SQL in fake HANA cursor: {normalized}")

    def fetchone(self):
        if not self._results:
            return None
        return self._results.pop(0)

    def fetchall(self):
        results = list(self._results)
        self._results.clear()
        return results

    def _handle_select(self, sql: str, table_name: str, table: dict, params: tuple) -> None:
        self.rowcount = -1
        if table_name.endswith("APP_RECORDS"):
            collection = params[0]
            if 'COUNT(*)' in sql:
                count = sum(1 for (record_collection, _record_key) in table if record_collection == collection)
                self._results = [(count,)]
                return

            if '"RECORD_KEY", "PAYLOAD"' in sql:
                self._results = [
                    (record_key, payload)
                    for (record_collection, record_key), payload in table.items()
                    if record_collection == collection
                ]
                return

            if '"PAYLOAD"' in sql and '"RECORD_KEY" = ?' in sql:
                payload = table.get((collection, params[1]))
                self._results = [(payload,)] if payload is not None else []
                return

            if 'SELECT 1' in sql:
                exists = (collection, params[1]) in table
                self._results = [(1,)] if exists else []
                return

            self._results = [
                (payload,)
                for (record_collection, _record_key), payload in table.items()
                if record_collection == collection
            ]
            return

        if table_name.endswith("REVOKED_TOKENS"):
            if '"JTI" FROM' in sql:
                self._results = [(jti,) for jti in table]
                return
            exists = params[0] in table
            self._results = [(1,)] if exists else []
            return

        if table_name.endswith("RATE_LIMIT_BUCKETS"):
            bucket = params[0]
            row = table.get(bucket)
            self._results = [(row["REQUEST_COUNT"], row["RESET_AT"])] if row is not None else []
            return

        raise AssertionError(f"Unsupported SELECT table in fake HANA cursor: {table_name}")

    def _handle_upsert(self, table_name: str, table: dict, params: tuple) -> None:
        self.rowcount = 1
        self._results = []
        if table_name.endswith("APP_RECORDS"):
            table[(params[0], params[1])] = params[2]
            return
        if table_name.endswith("REVOKED_TOKENS"):
            table[params[0]] = params[1]
            return
        if table_name.endswith("RATE_LIMIT_BUCKETS"):
            table[params[0]] = {
                "REQUEST_COUNT": params[1],
                "RESET_AT": params[2],
            }
            return
        raise AssertionError(f"Unsupported UPSERT table in fake HANA cursor: {table_name}")

    def _handle_delete(self, sql: str, table_name: str, table: dict, params: tuple) -> None:
        if not params:
            deleted = len(table)
            table.clear()
            self.rowcount = deleted
            self._results = []
            return

        if table_name.endswith("APP_RECORDS"):
            if '"RECORD_KEY" = ?' in sql:
                deleted = 1 if table.pop((params[0], params[1]), None) is not None else 0
                self.rowcount = deleted
                self._results = []
                return
            doomed = [key for key in table if key[0] == params[0]]
            for key in doomed:
                table.pop(key, None)
            self.rowcount = len(doomed)
            self._results = []
            return

        if table_name.endswith("REVOKED_TOKENS"):
            doomed = [jti for jti, expires_at in table.items() if expires_at <= params[0]]
            for jti in doomed:
                table.pop(jti, None)
            self.rowcount = len(doomed)
            self._results = []
            return

        if table_name.endswith("RATE_LIMIT_BUCKETS"):
            doomed = [bucket for bucket, row in table.items() if row["RESET_AT"] <= params[0]]
            for bucket in doomed:
                table.pop(bucket, None)
            self.rowcount = len(doomed)
            self._results = []
            return

        raise AssertionError(f"Unsupported DELETE table in fake HANA cursor: {table_name}")

    def _parse_first_table_identifier(self, sql: str, keyword: str | None = None) -> tuple[str, str]:
        if keyword is not None:
            match = re.search(rf'{keyword}\s+("([^"]+)"(?:\."([^"]+)")?)', sql)
        else:
            match = re.search(r'(?:FROM|UPSERT)\s+("([^"]+)"(?:\."([^"]+)")?)', sql)
        if match is None:
            raise AssertionError(f"Unable to parse table identifier from SQL: {sql}")
        return self._identifier_to_schema_and_table(match.group(1))

    def _parse_last_identifier(self, sql: str) -> tuple[str, str]:
        identifiers = self._IDENTIFIER_RE.findall(sql)
        if not identifiers:
            raise AssertionError(f"Unable to parse identifier from SQL: {sql}")
        first, second = identifiers[-1]
        if second:
            return first, second
        return first, first

    def _identifier_to_schema_and_table(self, identifier: str) -> tuple[str, str]:
        parts = self._IDENTIFIER_RE.findall(identifier)
        if len(parts) == 2:
            return parts[0][0], parts[1][0]
        if len(parts) == 1:
            first, second = parts[0]
            if second:
                return first, second
            return self.connection.current_schema, first
        raise AssertionError(f"Unable to parse HANA identifier: {identifier}")

    @staticmethod
    def _empty_table(table_name: str):
        if table_name.endswith("APP_RECORDS"):
            return {}
        if table_name.endswith("REVOKED_TOKENS"):
            return {}
        if table_name.endswith("RATE_LIMIT_BUCKETS"):
            return {}
        raise AssertionError(f"Unknown fake HANA table type: {table_name}")


def test_hana_store_persists_records_across_instances() -> None:
    env = FakeHanaEnvironment()
    first_store = HanaAppStore(
        host="hana.example.test",
        user="system",
        password="secret",
        schema="AIFABRIC",
        table_prefix="sap-ai-fabric",
        connection_factory=env.connect,
    )
    first_store.initialise()
    first_store.set_record("models", "persisted-model", {"id": "persisted-model", "name": "Persisted"})
    first_store.revoke_jti("persisted-jti", 60)
    first_store.consume_rate_limit("auth:127.0.0.1", 1, 60)

    second_store = HanaAppStore(
        host="hana.example.test",
        user="system",
        password="secret",
        schema="AIFABRIC",
        table_prefix="sap-ai-fabric",
        connection_factory=env.connect,
    )
    second_store.initialise()

    assert second_store.connection_target == "hana://hana.example.test:443/AIFABRIC#SAP_AI_FABRIC"
    assert second_store.get_record("models", "persisted-model") == {
        "id": "persisted-model",
        "name": "Persisted",
    }
    assert second_store.is_jti_revoked("persisted-jti") is True

    denied = second_store.consume_rate_limit("auth:127.0.0.1", 1, 60)
    assert denied["allowed"] is False
    assert denied["remaining"] == 0


def test_hana_store_mutate_and_clear() -> None:
    env = FakeHanaEnvironment()
    store = HanaAppStore(
        host="hana.example.test",
        user="system",
        password="secret",
        schema="AIFABRIC",
        table_prefix="sap-ai-fabric",
        connection_factory=env.connect,
    )
    store.initialise()
    store.set_record("users", "alice", {"username": "alice", "role": "viewer", "active": True})

    updated = store.mutate_record(
        "users",
        "alice",
        lambda user: {**user, "role": "admin", "active": False},
    )

    assert updated == {"username": "alice", "role": "admin", "active": False}
    assert store.snapshot("users")["alice"]["role"] == "admin"
    assert store.count("users") == 1

    store.clear()

    assert store.count("users") == 0
    assert store.revoked_jtis == set()
