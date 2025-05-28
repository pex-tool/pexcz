# PexCZ

A native runtime bootstrap for PEXes.

> [!WARNING]  
> This set of tools is very alpha and definitely not intended for production use yet!

PEXes must meet a few basic criteria to meet the historic Pex design goals:
+ Support both CPython 2.7 and PyPy 2.7 as well as 3.5 and up for both implementations.
+ Support multi-platform PEXes that include platform-specific wheels for each targeted platform.
+ Provide a hermetic runtime environment by default. You can only import the project packages your
  PEX ships with no matter the vagaries of the machines the PEX lands on.

PexCZ provides a `pexcz` binary that can take an existing zipapp PEX and replace its runtime
`.bootstrap/` with a native code bootstrap that meets all the design goals above while also
producing smaller PEXes (CZEXes [^1]) that are faster to execute in both cold and warm cache
scenarios across the full range of PEX sizes.

For example:
```console
# Given both a traditional zipapp PEX and a venv PEX:
:; pex cowsay -c cowsay -o cowsay.zipapp.pex 
:; pex cowsay -c cowsay --venv -o cowsay.venv.pex

# Create CZEXes from them:
:; time zig-out/bin/native/pexcz inject cowsay.zipapp.pex 
Injected pexcz runtime for cowsay.zipapp.pex in cowsay.zipapp.czex

real	0m0.090s
user	0m0.087s
sys	0m0.003s
 
:; zig-out/bin/native/pexcz inject cowsay.venv.pex 
Injected pexcz runtime for cowsay.venv.pex in cowsay.venv.czex

# Compare PEX and CZEX sizes:
:; ls -1sh cowsay.zipapp.* cowsay.venv.*
400K cowsay.venv.czex
952K cowsay.venv.pex
400K cowsay.zipapp.czex
932K cowsay.zipapp.pex

# Compare cold cache speed: 
:; hyperfine -w2 \
-p 'rm -rf ~/.cache/pex' 'python cowsay.zipapp.pex -t Moo!' \
-p 'rm -rf ~/.cache/pex' 'python cowsay.venv.pex -t Moo!' \
-p 'rm -rf ~/.cache/pexcz/' 'python cowsay.zipapp.czex -t -t Moo!' \
-p 'rm -rf ~/.cache/pexcz/' 'python cowsay.venv.czex -t -t Moo!'
Benchmark 1: python cowsay.zipapp.pex -t Moo!
  Time (mean ± σ):     675.0 ms ±   5.7 ms    [User: 602.1 ms, System: 73.5 ms]
  Range (min … max):   665.4 ms … 683.3 ms    10 runs
 
Benchmark 2: python cowsay.venv.pex -t Moo!
  Time (mean ± σ):     806.3 ms ±  22.3 ms    [User: 714.7 ms, System: 87.5 ms]
  Range (min … max):   789.0 ms … 865.5 ms    10 runs
 
Benchmark 3: python cowsay.zipapp.czex -t -t Moo!
  Time (mean ± σ):     106.1 ms ±   0.9 ms    [User: 78.8 ms, System: 34.4 ms]
  Range (min … max):   104.6 ms … 108.1 ms    27 runs
 
Benchmark 4: python cowsay.venv.czex -t -t Moo!
  Time (mean ± σ):     105.8 ms ±   0.7 ms    [User: 77.2 ms, System: 36.0 ms]
  Range (min … max):   104.4 ms … 107.0 ms    27 runs
 
Summary
  python cowsay.venv.czex -t -t Moo! ran
    1.00 ± 0.01 times faster than python cowsay.zipapp.czex -t -t Moo!
    6.38 ± 0.07 times faster than python cowsay.zipapp.pex -t Moo!
    7.62 ± 0.22 times faster than python cowsay.venv.pex -t Moo!

# Compare warm cache speed: 
:; hyperfine -w2 \
'python cowsay.zipapp.pex -t Moo!' \
'python cowsay.venv.pex -t Moo!' \
'python cowsay.zipapp.czex -t -t Moo!' \
'python cowsay.venv.czex -t -t Moo!'
Benchmark 1: python cowsay.zipapp.pex -t Moo!
  Time (mean ± σ):     315.1 ms ±   2.9 ms    [User: 272.6 ms, System: 43.5 ms]
  Range (min … max):   309.5 ms … 318.2 ms    10 runs
 
Benchmark 2: python cowsay.venv.pex -t Moo!
  Time (mean ± σ):     118.5 ms ±   1.3 ms    [User: 92.5 ms, System: 27.2 ms]
  Range (min … max):   117.1 ms … 122.8 ms    24 runs
 
Benchmark 3: python cowsay.zipapp.czex -t -t Moo!
  Time (mean ± σ):      72.3 ms ±   0.9 ms    [User: 50.3 ms, System: 23.2 ms]
  Range (min … max):    70.9 ms …  75.5 ms    41 runs
 
Benchmark 4: python cowsay.venv.czex -t -t Moo!
  Time (mean ± σ):      73.4 ms ±   8.4 ms    [User: 49.4 ms, System: 23.8 ms]
  Range (min … max):    71.3 ms … 125.8 ms    41 runs
 
Summary
  python cowsay.zipapp.czex -t -t Moo! ran
    1.01 ± 0.12 times faster than python cowsay.venv.czex -t -t Moo!
    1.64 ± 0.03 times faster than python cowsay.venv.pex -t Moo!
    4.36 ± 0.07 times faster than python cowsay.zipapp.pex -t Moo!
```

On the huge PEX side of the spectrum, some extra tricks come to the fore. Namely, CZEXes use zstd
compression for all files except `__main__.py` and `PEX-INFO` and zip extraction is further
parallelized across all available cores.

Using the torch case:
```console
# Given a traditional zipapp torch PEX:
:; pex torch -o torch.pex 

# Create a CZEX from it:
:; time zig-out/bin/native/pexcz inject torch.pex 
Injected pexcz runtime for torch.pex in torch.czex

real	0m41.022s
user	0m38.733s
sys	0m2.208s

# That took a little bit! But a pretty big space savings is a result:
:; ls -1sh torch.pex torch.czex 
2.3G torch.czex
2.9G torch.pex

# Cold cache perf is improved:
:; hyperfine -w1 -r3 \
-p 'rm -rf ~/.cache/pexcz' 'python3.13 torch.czex -c -c "import torch; print(torch.__file__)"' \
-p 'rm -rf ~/.cache/pex' 'python3.13 torch.pex -c "import torch; print(torch.__file__)"'
Benchmark 1: python3.13 torch.czex -c -c "import torch; print(torch.__file__)"
  Time (mean ± σ):      4.604 s ±  0.114 s    [User: 12.974 s, System: 3.992 s]
  Range (min … max):    4.481 s …  4.705 s    3 runs
 
Benchmark 2: python3.13 torch.pex -c "import torch; print(torch.__file__)"
  Time (mean ± σ):     25.812 s ±  0.441 s    [User: 23.585 s, System: 1.983 s]
  Range (min … max):   25.459 s … 26.306 s    3 runs
 
Summary
  python3.13 torch.czex -c -c "import torch; print(torch.__file__)" ran
    5.61 ± 0.17 times faster than python3.13 torch.pex -c "import torch; print(torch.__file__)"

# As is warm cache perf:
:; hyperfine -w1 -r3 \
'python3.13 torch.czex -c -c "import torch; print(torch.__file__)"' \
'python3.13 torch.pex -c "import torch; print(torch.__file__)"'
Benchmark 1: python3.13 torch.czex -c -c "import torch; print(torch.__file__)"
  Time (mean ± σ):      1.146 s ±  0.003 s    [User: 1.015 s, System: 0.131 s]
  Range (min … max):    1.142 s …  1.148 s    3 runs
 
Benchmark 2: python3.13 torch.pex -c "import torch; print(torch.__file__)"
  Time (mean ± σ):      2.150 s ±  0.006 s    [User: 1.962 s, System: 0.189 s]
  Range (min … max):    2.143 s …  2.156 s    3 runs
 
Summary
  python3.13 torch.czex -c -c "import torch; print(torch.__file__)" ran
    1.88 ± 0.01 times faster than python3.13 torch.pex -c "import torch; print(torch.__file__)"
```

N.B,.: The ideas developed in this repo, once proved out, will likely move into the main Pex repo or at
least used by the Pex CLI tool to replace the current pure-Python PEX bootstrap runtime.

[^1]: Pexcz is powered via `__main__.py` using ctypes to hand off boot duties to a native library
written in Zig; thus the `cz`. Since cz brings to mind Czechia (their TLD is .cz), in english at
least, CZEX is pronounced "chex" as in Chex mix. Mix a little CZEX into your PEX and profit.
