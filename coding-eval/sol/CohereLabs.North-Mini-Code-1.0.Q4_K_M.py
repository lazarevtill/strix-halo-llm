from collections import OrderedDict

class LRUCache:
    def __init__(self, capacity: int):
        """
        Initialize the LRUCache with a given capacity.
        """
        self.capacity = capacity
        self.cache = OrderedDict()
        self.hits = 0
        self.misses = 0

    def get(self, key: int) -> int:
        """
        Retrieve the value associated with key if it exists, otherwise return -1.
        Accessing the key marks it as most-recently-used.
        Increments the hit counter if the key is present, otherwise increments the miss counter.
        """
        if key not in self.cache:
            self.misses += 1
            return -1
        self.cache.move_to_end(key)   # Mark as most-recently-used
        self.hits += 1
        return self.cache[key]

    def put(self, key: int, value: int) -> None:
        """
        Insert or update the key-value pair.
        If the key already exists, update its value and mark as most-recently-used.
        If the cache is at capacity and the key is new, evict the least-recently-used item.
        A capacity of 0 stores nothing.
        """
        if self.capacity == 0:
            return
        if key in self.cache:
            self.cache.move_to_end(key)   # Mark as most-recently-used
            self.cache[key] = value       # Update value
        else:
            if len(self.cache) >= self.capacity:
                self.cache.popitem(last=False)   # Evict least-recently-used
            self.cache[key] = value

    def peek(self, key: int) -> int:
        """
        Return the value for key without affecting its recency order.
        Returns -1 if the key is not present. Does not modify hit/miss counters.
        """
        return self.cache.get(key, -1)

    def __len__(self) -> int:
        """
        Return the current number of cached items.
        """
        return len(self.cache)

    def clear(self) -> None:
        """
        Remove all items from the cache. Does not reset hit/miss counters.
        """
        self.cache.clear()

    def stats(self) -> dict:
        """
        Return a dictionary with the current hit and miss counts.
        """
        return {'hits': self.hits, 'misses': self.misses}