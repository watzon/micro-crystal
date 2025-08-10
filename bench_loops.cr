require "benchmark"

# Determine number of iterations (N) from ENV or ARGV, default 1_000_000
DEFAULT_N = 1_000_000
n = (ENV["N"]? || ARGV[0]? || DEFAULT_N.to_s).to_i

puts "Benchmarking with N=#{n}"

# Small helper to consume a value to avoid over-optimization
@[NoInline]
def consume(x : Int64)
  x & 0xFFFFFFFF
end

Benchmark.ips do |x|
  x.report("range each (0...n)") do
    sum = 0_i64
    (0...n).each do |i|
      sum += i
    end
    consume(sum)
  end

  x.report("upto (0.upto(n-1))") do
    sum = 0_i64
    0.upto(n - 1) do |i|
      sum += i
    end
    consume(sum)
  end
end

# Benchmarking with N=1000000
# range each (0...n)   3.11k (321.20µs) (± 0.38%)  0.0B/op        fastest
# upto (0.upto(n-1))   1.55k (646.87µs) (± 0.56%)  0.0B/op   2.01× slower
