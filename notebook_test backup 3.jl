### A Pluto.jl notebook ###
# v1.0.2

using Markdown
using InteractiveUtils

# ╔═╡ 0fdad812-65af-11f1-9244-e5793823958b
x = 7

# ╔═╡ 14b53018-660b-4a50-8444-ae036e98f3ef
y = x * 3

# ╔═╡ a1b2c3d4-0000-4000-8000-123456789abc
z = y + x

# ╔═╡ b2c3d4e5-0000-4000-8000-abcdef012345
message = "AGENT WAS HERE: z=$z, x=$x — but nothing ran yet"

# ╔═╡ c1000001-0000-4000-8000-000000000001
# slow + unpredictable: nobody can know this value without running it
r1 = begin
	sleep(8)
	rand(1:1000)
end

# ╔═╡ c1000002-0000-4000-8000-000000000002
# also slow, also unpredictable
r2 = begin
	sleep(6)
	round(randn() * 500; digits=2)
end

# ╔═╡ c1000003-0000-4000-8000-000000000003
total = r1 * 2 + x^2

# ╔═╡ c1000004-0000-4000-8000-000000000004
verdict = r2 > 0 ? "POSITIVE ✔" : "NEGATIVE ✘"

# ╔═╡ c1000005-0000-4000-8000-000000000005
summary = uppercase("totals: $total // r2 came out $verdict ($r2)")

# ╔═╡ d4000001-0000-4000-8000-00000000000d
report = "x is now $x · total=$total · message says: $message"

# ╔═╡ Cell order:
# ╠═0fdad812-65af-11f1-9244-e5793823958b
# ╠═14b53018-660b-4a50-8444-ae036e98f3ef
# ╠═a1b2c3d4-0000-4000-8000-123456789abc
# ╠═b2c3d4e5-0000-4000-8000-abcdef012345
# ╠═c1000001-0000-4000-8000-000000000001
# ╠═c1000002-0000-4000-8000-000000000002
# ╠═c1000003-0000-4000-8000-000000000003
# ╠═c1000004-0000-4000-8000-000000000004
# ╠═c1000005-0000-4000-8000-000000000005
# ╠═d4000001-0000-4000-8000-00000000000d
