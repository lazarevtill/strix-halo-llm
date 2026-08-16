"""Hidden tests for the PUBLIC EXAMPLE task. Structure mirrors the real suites exactly.

Sections are delimited by `# ---- turn N additions ----`. run-code-eval.py parses those markers to
deselect tests for features the prompt has not asked for yet -- without that, turn 1 is graded on
turn-3 behaviour and every model scores exactly the turn-1 test count, which measures the test file
rather than the model (bug 6 in evals/README.md).
"""
import pytest

from solution import Stack


# ---- turn 1 additions ----

def test_push_then_pop_is_lifo():
    s = Stack()
    s.push(1)
    s.push(2)
    assert s.pop() == 2
    assert s.pop() == 1


def test_peek_does_not_remove():
    s = Stack()
    s.push("a")
    assert s.peek() == "a"
    assert s.peek() == "a"
    assert len(s) == 1


def test_len_tracks_contents():
    s = Stack()
    assert len(s) == 0
    for i in range(5):
        s.push(i)
    assert len(s) == 5
    s.pop()
    assert len(s) == 4


@pytest.mark.parametrize("method", ["pop", "peek"])
def test_empty_raises_index_error(method):
    s = Stack()
    with pytest.raises(IndexError):
        getattr(s, method)()


# ---- turn 2 additions ----

def test_min_returns_smallest():
    s = Stack()
    for v in (5, 2, 9):
        s.push(v)
    assert s.min() == 2


def test_min_empty_raises_index_error():
    s = Stack()
    with pytest.raises(IndexError):
        s.min()


def test_min_is_constant_time():
    """O(1) means the work per call must not grow with depth.

    Asserting on wall-clock would be flaky in a 1-CPU container, so this counts comparisons on the
    stored items instead: a scanning implementation compares O(n) times per call, a correct one
    does not compare at all.
    """
    class Counting(int):
        comparisons = 0

        def __lt__(self, other):
            type(self).comparisons += 1
            return int(self) < int(other)

        def __gt__(self, other):
            type(self).comparisons += 1
            return int(self) > int(other)

        def __le__(self, other):
            type(self).comparisons += 1
            return int(self) <= int(other)

    s = Stack()
    for v in range(200):
        s.push(Counting(v))
    Counting.comparisons = 0
    s.min()
    assert Counting.comparisons < 200


# ---- turn 3 additions ----

def test_min_recovers_after_popping_a_duplicate():
    """The bug named in the turn-3 prompt: duplicate minima must be tracked, not deduplicated."""
    s = Stack()
    for v in (5, 3, 5):
        s.push(v)
    s.pop()
    assert s.min() == 3


def test_min_after_popping_the_minimum():
    s = Stack()
    for v in (4, 1, 7):
        s.push(v)
    assert s.min() == 1
    s.pop()          # 7
    assert s.min() == 1
    s.pop()          # 1
    assert s.min() == 4


def test_capacity_defaults_to_unbounded():
    s = Stack()
    for i in range(1000):
        s.push(i)
    assert len(s) == 1000


def test_push_past_capacity_raises_overflow():
    s = Stack(capacity=2)
    s.push(1)
    s.push(2)
    with pytest.raises(OverflowError):
        s.push(3)
    assert len(s) == 2


def test_capacity_frees_up_after_pop():
    s = Stack(capacity=1)
    s.push("x")
    s.pop()
    s.push("y")
    assert s.peek() == "y"
