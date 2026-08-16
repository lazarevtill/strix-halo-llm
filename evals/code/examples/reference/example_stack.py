"""Reference solution for the public example task, satisfying all three turns.

Written as a WHOLE FILE, which is what the harness requires of a model reply too -- it overwrites
solution.py wholesale, so a reply containing only the new method loses everything from the earlier
turns and fails on import. calibrate() scores this file at every turn to derive the authoritative
per-turn test counts; if it ever stops passing 100%, a turn prompt has become unsatisfiable and
every model score on that turn is noise (bug 7 in evals/README.md).
"""


class Stack:
    def __init__(self, capacity=None):
        self._items = []
        # Parallel stack of running minima. Holding one entry per push -- rather than pushing only
        # on a new minimum -- is what makes duplicate minima survive a pop, which is the bug the
        # turn-3 prompt describes.
        self._mins = []
        self._capacity = capacity

    def push(self, item):
        if self._capacity is not None and len(self._items) >= self._capacity:
            raise OverflowError("stack is full")
        self._items.append(item)
        if self._mins and self._mins[-1] <= item:
            self._mins.append(self._mins[-1])
        else:
            self._mins.append(item)

    def pop(self):
        if not self._items:
            raise IndexError("pop from empty stack")
        self._mins.pop()
        return self._items.pop()

    def peek(self):
        if not self._items:
            raise IndexError("peek from empty stack")
        return self._items[-1]

    def min(self):
        if not self._mins:
            raise IndexError("min of empty stack")
        return self._mins[-1]

    def __len__(self):
        return len(self._items)
