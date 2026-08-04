"""Extract the LRUCache Python solution from a model's raw generation."""
import sys, re

raw = open(sys.argv[1], encoding="utf-8", errors="replace").read()

# 1) prefer a fenced code block that defines the class
blocks = re.findall(r"```(?:python|py)?\s*\n(.*?)```", raw, re.S)
code = ""
for b in blocks:
    if "class LRUCache" in b:
        code = b
        break
if not code and blocks:                       # any fenced block, longest
    code = max(blocks, key=len)
if not code:                                  # no fences: from 'class LRUCache' onward
    m = re.search(r"(class\s+LRUCache\b.*)", raw, re.S)
    code = m.group(1) if m else raw

# strip llama-cli simple-io footer + EOT markers + trailing prose
code = re.split(r"\n\[\s*Prompt:", code)[0]
for junk in ("[end of text]", "</s>", "<|im_end|>", "<|endoftext|>", "<|return|>"):
    code = code.replace(junk, "")
print(code.rstrip())
