# usage: select.sh <file> <case>... -> writes tests/<name>.nmsel.test.sh
f=$1; shift
first=$(grep -nE '^test_[a-z_0-9]+$' "$f" | head -1 | cut -d: -f1)
out="${f%.test.sh}.nmsel.test.sh"
head -n $((first-1)) "$f" > "$out"
for c in "$@"; do echo "$c" >> "$out"; done
chmod +x "$out"; echo "$out"
