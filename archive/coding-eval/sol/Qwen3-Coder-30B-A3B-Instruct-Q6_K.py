class LRUCache:
    def __init__(self, capacity):
        self.capacity = capacity
        self.cache = {}
        self.order = []
        self.hits = 0
        self.misses = 0
    
    def get(self, key):
        if key not in self.cache:
            self.misses += 1
            return -1
        # Move to end (most recently used)
        self.order.remove(key)
        self.order.append(key)
        self.hits += 1
        return self.cache[key]
    
    def put(self, key, value):
        if self.capacity == 0:
            return
        
        if key in self.cache:
            # Update existing key
            self.cache[key] = value
            self.order.remove(key)
            self.order.append(key)
        else:
            # New key
            if len(self.cache) >= self.capacity:
                # Remove least recently used
                lru_key = self.order.pop(0)
                del self.cache[lru_key]
            self.cache[key] = value
            self.order.append(key)
    
    def peek(self, key):
        if key not in self.cache:
            return -1
        return self.cache[key]
    
    def __len__(self):
        return len(self.cache)
    
    def clear(self):
        self.cache.clear()
        self.order.clear()
    
    def stats(self):
        return {'hits': self.hits, 'misses': self.misses}