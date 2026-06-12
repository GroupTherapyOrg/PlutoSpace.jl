### A Pluto.jl notebook ###
# v1.0.2

using Markdown
using InteractiveUtils

# ╔═╡ 51e1557e-6631-11f1-adf6-415311d2aa63
md"""
# 🪐 Greetings from Pluto

> *"Still a planet in our hearts."*

You are looking at a **reactive** notebook — change a cell, and everything that depends on it re-runs instantly.

| Fact | Value |
|------|-------|
| Distance from the Sun | ~5.9 billion km |
| One year on Pluto | 248 Earth years |
| Demoted | 2006 😢 |

```julia
while true
    println("hi, but cooler")
end
```
"""

# ╔═╡ e4e42592-b517-4308-85be-cd5ff9ccdca4
let
	rows, cols = 17, 64
	orbit(c) = round(Int, (rows + 1) / 2 + (rows - 1) / 2 * sin(2π * c / cols))
	Text(join((join(orbit(c) == r ? "●" : "⋅" for c in 1:cols) for r in 1:rows), "\n"))
end

# ╔═╡ 235126e7-6103-496f-b255-a842ff092cdf
fib = let
	f = [1, 1]
	while length(f) < 15
		push!(f, f[end] + f[end-1])
	end
	f
end

# ╔═╡ cbd184bf-6ee0-48f4-b502-b0eb8fc1a328
join(Char(0x1F311 + i) for i in 0:7)

# ╔═╡ fc5adb28-f983-4293-aa04-55634cd59db6
almost_e = sum(1 / factorial(n) for n in 0:12)

# ╔═╡ 00000000-0000-0000-0000-000000000001
PLUTO_PROJECT_TOML_CONTENTS = """
[deps]
"""

# ╔═╡ 00000000-0000-0000-0000-000000000002
PLUTO_MANIFEST_TOML_CONTENTS = """
# This file is machine-generated - editing it directly is not advised

julia_version = "1.12.6"
manifest_format = "2.0"
project_hash = "71853c6197a6a7f222db0f1978c7cb232b87c5ee"

[deps]
"""

# ╔═╡ Cell order:
# ╟─51e1557e-6631-11f1-adf6-415311d2aa63
# ╠═e4e42592-b517-4308-85be-cd5ff9ccdca4
# ╠═235126e7-6103-496f-b255-a842ff092cdf
# ╠═cbd184bf-6ee0-48f4-b502-b0eb8fc1a328
# ╠═fc5adb28-f983-4293-aa04-55634cd59db6
# ╟─00000000-0000-0000-0000-000000000001
# ╟─00000000-0000-0000-0000-000000000002
