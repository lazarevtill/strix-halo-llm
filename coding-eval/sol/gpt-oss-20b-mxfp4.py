from collections import OrderedDict

class LRUCache:
    def __init__(self, capacity: int):
        if capacity < 0:
            raise ValueError("capacity must be non‑negative")
        self.capacity = capacity
        self.cache = OrderedDict()
        self.hits = 0
        self.misses = 0

    def get(self, key: int) -> int:
        if key not in self.cache:
            self.misses += 1
            return -1
        self.hits += 1
        self.cache.move_to_end(key, last=True)
        return self.cache[key]

    def peek(self, key: int) -> int:
        """Return the value for key without affecting recency or stats."""
        return self.cache.get(key, -1)

    def put(self, key: int, value: int) -> None:
        if self.capacity == 0:
            return
        if key in self.cache:
            self.cache[key] = value
            self.cache.move_to_end(key, last=True)
        else:
            if len(self.cache) == self.capacity:
                self.cache.popitem(last=False)
            self.cache[key] = value

    def __len__(self) -> int:
        return len(self.cache)

    def clear(self) -> None:
        self.cache.clear()

    def stats(self) -> dict:
        return {'hits': self.hits, 'misses': self.misses}