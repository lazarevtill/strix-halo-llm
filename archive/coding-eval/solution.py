class Node:
    def __init__(self, key, value):
        self.key = key
        self.value = value
        self.prev = None
        self.next = None

class LRUCache:
    def __init__(self, capacity: int):
        self.capacity = capacity
        self.cache = {}
        self.head = Node(0, 0)
        self.tail = Node(0, 0)
        self.head.next = self.tail
        self.tail.prev = self.head
        self.hits = 0
        self.misses = 0

    def _add_node(self, node):
        node.prev = self.head
        node.next = self.head.next
        self.head.next.prev = node
        self.head.next = node

    def _remove_node(self, node):
        prev = node.prev
        nxt = node.next
        prev.next = nxt
        nxt.prev = prev

    def _move_to_end(self, node):
        self._remove_node(node)
        self._add_node(node)

    def _pop_left(self):
        node = self.head.next
        self._remove_node(node)
        return node

    def get(self, key: int) -> int:
        if key in self.cache:
            self.hits += 1
            node = self.cache[key]
            self._move_to_end(node)
            return node.value
        self.misses += 1
        return -1

    def put(self, key: int, value: int) -> None:
        if key in self.cache:
            node = self.cache[key]
            node.value = value
            self._move_to_end(node)
        else:
            if self.capacity > 0:
                if len(self.cache) == self.capacity:
                    lru = self._pop_left()
                    del self.cache[lru.key]
                new_node = Node(key, value)
                self._add_node(new_node)
                self.cache[key] = new_node

    def peek(self, key: int) -> int:
        if key in self.cache:
            return self.cache[key].value
        return -1

    def __len__(self):
        return len(self.cache)

    def clear(self):
        self.cache.clear()
        self.head.next = self.tail
        self.tail.prev = self.head

    def stats(self):
        return {'hits': self.hits, 'misses': self.misses}