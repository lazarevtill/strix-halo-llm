class LRUCache:
    class _Node:
        __slots__ = ('key', 'value', 'prev', 'next')
        def __init__(self, key=None, value=None):
            self.key = key
            self.value = value
            self.prev = None
            self.next = None

    def __init__(self, capacity: int):
        if capacity < 0:
            raise ValueError("capacity must be non-negative")
        self.capacity = capacity
        self.cache = {}                     # key -> node
        self.head = self._Node()            # dummy head
        self.tail = self._Node()            # dummy tail
        self.head.next = self.tail
        self.tail.prev = self.head
        self.hits = 0
        self.misses = 0

    def _remove(self, node: _Node) -> None:
        """Remove node from linked list."""
        prev_node = node.prev
        next_node = node.next
        prev_node.next = next_node
        next_node.prev = prev_node

    def _add_to_head(self, node: _Node) -> None:
        """Insert node right after head."""
        node.prev = self.head
        node.next = self.head.next
        self.head.next.prev = node
        self.head.next = node

    def _move_to_head(self, node: _Node) -> None:
        self._remove(node)
        self._add_to_head(node)

    def _pop_tail(self) -> _Node:
        """Remove and return the node before tail (least recently used)."""
        lru_node = self.tail.prev
        self._remove(lru_node)
        return lru_node

    def get(self, key: int) -> int:
        if self.capacity == 0:
            return -1
        if key in self.cache:
            self.hits += 1
            node = self.cache[key]
            self._move_to_head(node)
            return node.value
        self.misses += 1
        return -1

    def put(self, key: int, value: int) -> None:
        if self.capacity == 0:
            return
        if key in self.cache:
            node = self.cache[key]
            node.value = value
            self._move_to_head(node)
        else:
            new_node = self._Node(key, value)
            self.cache[key] = new_node
            self._add_to_head(new_node)
            if len(self.cache) > self.capacity:
                lru_node = self._pop_tail()
                del self.cache[lru_node.key]

    def peek(self, key: int) -> int:
        if self.capacity == 0:
            return -1
        if key in self.cache:
            return self.cache[key].value
        return -1

    def clear(self) -> None:
        self.cache.clear()
        self.head.next = self.tail
        self.tail.prev = self.head

    def __len__(self) -> int:
        return len(self.cache)

    def stats(self) -> dict:
        return {'hits': self.hits, 'misses': self.misses}