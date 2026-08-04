"""Canonical LRUCache suite — the objective scorer for the multi-turn coding eval.
Grouped by the turn that introduced each feature, so partial completion is visible.
Runner copies each model's final solution to solution.py, then runs pytest.
"""
from solution import LRUCache


# ---- Turn 1: core LRU (get / put / eviction / recency / edge cases) ----
def test_t1_basic():
    c = LRUCache(2); c.put(1, 1); c.put(2, 2)
    assert c.get(1) == 1 and c.get(2) == 2

def test_t1_missing():
    assert LRUCache(2).get(99) == -1

def test_t1_eviction():
    c = LRUCache(2); c.put(1, 1); c.put(2, 2); c.put(3, 3)
    assert c.get(1) == -1 and c.get(2) == 2 and c.get(3) == 3

def test_t1_get_refreshes():
    c = LRUCache(2); c.put(1, 1); c.put(2, 2); c.get(1); c.put(3, 3)
    assert c.get(1) == 1 and c.get(2) == -1

def test_t1_update_no_evict():
    c = LRUCache(2); c.put(1, 1); c.put(2, 2); c.put(1, 10)
    assert c.get(1) == 10 and c.get(2) == 2

def test_t1_capacity_zero():
    c = LRUCache(0); c.put(1, 1)
    assert c.get(1) == -1


# ---- Turn 2: peek (value without touching recency) ----
def test_t2_peek_value():
    c = LRUCache(2); c.put(1, 1)
    assert c.peek(1) == 1 and c.peek(99) == -1

def test_t2_peek_no_recency_change():
    c = LRUCache(2); c.put(1, 1); c.put(2, 2); c.peek(1); c.put(3, 3)  # 1 still LRU -> evicted
    assert c.get(1) == -1 and c.get(2) == 2 and c.get(3) == 3


# ---- Turn 3: __len__ and clear ----
def test_t3_len():
    c = LRUCache(3); c.put(1, 1); c.put(2, 2)
    assert len(c) == 2

def test_t3_clear():
    c = LRUCache(3); c.put(1, 1); c.put(2, 2); c.clear()
    assert len(c) == 0 and c.get(1) == -1


# ---- Turn 4: hit/miss stats (peek excluded, clear does not reset) ----
def test_t4_stats_counts():
    c = LRUCache(2); c.put(1, 1)
    c.get(1); c.get(1); c.get(99)            # 2 hits, 1 miss
    assert c.stats() == {"hits": 2, "misses": 1}

def test_t4_peek_excluded_clear_keeps():
    c = LRUCache(2); c.put(1, 1)
    c.peek(1); c.get(1); c.get(2)            # peek excluded -> 1 hit, 1 miss
    c.clear()
    assert c.stats() == {"hits": 1, "misses": 1}
