Implement a class `LRUCache` in Python with O(1) average-time `get` and `put`.

Requirements (the task list — satisfy every item):
1. `LRUCache(capacity: int)` creates a cache holding at most `capacity` items. `capacity` is >= 0.
2. `get(key: int) -> int` returns the value for `key`, or `-1` if absent. A successful `get` marks `key` as the most-recently-used.
3. `put(key: int, value: int) -> None` inserts or updates. If inserting a new key would exceed `capacity`, evict the least-recently-used key first.
4. Updating an existing key refreshes its recency and must never trigger an eviction.
5. A cache with `capacity == 0` stores nothing: `get` always returns `-1`.

Return ONLY one Python code block containing the complete `LRUCache` class. No explanation, no example usage, no tests.
