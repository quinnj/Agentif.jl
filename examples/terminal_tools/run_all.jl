#!/usr/bin/env julia

"""
Run all terminal_tools examples as smoke tests.

This script runs each example in sequence and reports results.
Useful for quickly verifying that all examples work correctly.
"""

using Agentif, LLMTools
println("="^80)
println("Running all terminal_tools examples")
println("="^80)
println()

# Get all example files
examples_dir = @__DIR__
example_files = filter(f -> endswith(f, ".jl") && f != "run_all.jl", readdir(examples_dir))
sort!(example_files)

results = Dict{String, Bool}()
timings = Dict{String, Float64}()

for example_file in example_files
    println("\n" * "="^80)
    println("Running: $example_file")
    println("="^80)

    example_path = joinpath(examples_dir, example_file)
    start_time = time()

    try
        # Run the example in a separate process to isolate it
        cmd = `julia --project -e "include(\"$example_path\")"`
        run(cmd)

        elapsed = time() - start_time
        results[example_file] = true
        timings[example_file] = elapsed

        println("\n✅ $example_file completed successfully in $(round(elapsed, digits = 2))s")
    catch e
        elapsed = time() - start_time
        results[example_file] = false
        timings[example_file] = elapsed

        println("\n❌ $example_file failed after $(round(elapsed, digits = 2))s")
        println("Error: $e")
    end
end

# Print summary
println("\n" * "="^80)
println("Summary")
println("="^80)

passed = count(values(results))
total = length(results)

for (file, success) in sort(collect(results), by = x -> x[1])
    status = success ? "✅ PASS" : "❌ FAIL"
    time_str = @sprintf("%.2fs", timings[file])
    println("$status - $file ($time_str)")
end

println("\n" * "="^80)
println("Results: $passed/$total passed")
println("Total time: $(round(sum(values(timings)), digits = 2))s")
println("="^80)

if passed == total
    println("\n🎉 All examples passed!")
    exit(0)
else
    println("\n⚠️  Some examples failed")
    exit(1)
end
