"""Domain-rule reads and the DNS render revision counter (quota/db.py).

Two things are pinned here because a 300k-domain ad-block preset made them
matter on a 128 MB router:

* ``list_domain_rules`` reads in id-bounded pages, so one result set is never
  bigger than ``_DOMAIN_RULE_CHUNK`` rows (one unpaged fetch was ~150 MB and
  the aiosqlite worker kept it alive after the rows were copied out).
* every write to the rule set / presets bumps ``dns_rules_rev``, which is what
  lets the maintenance tick skip the read (and the 14.8 MB render) entirely.
"""

from __future__ import annotations

import asyncio

from quota import db as _db


def _run(coro):
    loop = asyncio.new_event_loop()
    try:
        return loop.run_until_complete(coro)
    finally:
        loop.close()


async def _open(path) -> _db.Database:
    database = _db.Database(path)
    await database.connect()
    return database


def test_list_domain_rules_pages_through_every_row(tmp_path, monkeypatch):
    monkeypatch.setattr(_db, "_DOMAIN_RULE_CHUNK", 100)

    async def main():
        database = await _open(tmp_path / "paged.db")
        try:
            domains = [f"host{i}.example.com" for i in range(250)]
            await database.create_domain_rules_bulk(
                _db.DNS_SCOPE_GLOBAL, "block", domains, source="test")
            rules = await database.list_domain_rules()
            assert len(rules) == len(domains)
            # A page boundary must not drop, duplicate or reorder rows.
            assert [r.domain for r in rules] == domains
            assert [r.id for r in rules] == sorted(r.id for r in rules)
            enabled = await database.list_domain_rules(enabled_only=True)
            assert len(enabled) == len(domains)
        finally:
            await database.close()

    _run(main())


def test_domain_rule_writes_bump_the_render_revision(tmp_path):
    async def main():
        database = await _open(tmp_path / "rev.db")
        try:
            start = await database.dns_revision()
            rule = await database.create_domain_rule(
                _db.DNS_SCOPE_GLOBAL, "block", "ads.example.com")
            first = await database.dns_revision()
            assert first == start + 1

            await database.update_domain_rule(rule.id, enabled=False)
            assert await database.dns_revision() == first + 1

            await database.delete_domain_rule(rule.id)
            assert await database.dns_revision() == first + 2

            await database.create_domain_rules_bulk(
                _db.DNS_SCOPE_GLOBAL, "block", ["a.example", "b.example"])
            after_bulk = await database.dns_revision()
            assert after_bulk == first + 3

            await database.delete_domain_rules_by_source("manual")
            assert await database.dns_revision() == after_bulk + 1

            await database.set_preset_state("porn", True, _db.DNS_SCOPE_GLOBAL,
                                            None, 10)
            assert await database.dns_revision() == after_bulk + 2
        finally:
            await database.close()

    _run(main())


def test_applied_signature_survives_a_reconnect(tmp_path):
    """The tick stores what it rendered (revision + per-client DNS servers);
    a restart reads it back so an unchanged 300k rule set is not re-rendered
    just to find the file identical."""
    path = tmp_path / "applied.db"
    servers = [["device", 7, "9.9.9.9"]]

    async def first():
        database = await _open(path)
        try:
            assert await database.dns_applied_sig() is None
            await database.set_dns_applied_sig(7, servers)
        finally:
            await database.close()

    async def second():
        database = await _open(path)
        try:
            assert await database.dns_applied_sig() == (7, servers)
        finally:
            await database.close()

    _run(first())
    _run(second())
