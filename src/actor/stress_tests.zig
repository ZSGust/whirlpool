const std = @import("std");
const whirlpool = @import("./actor.zig");

const Actor = whirlpool.Actor;
const WhirlPool = whirlpool.WhirlPool;
const WorkItem = whirlpool.WorkItem;
const WorkFn = whirlpool.WorkFn;

fn computeIntensive(data: []const u8, result: []u8) void {
    const iterations = std.mem.readInt(u32, data[0..4], .little);
    var primes_found: u32 = 0;
    var num: u32 = 2;

    while (primes_found < iterations) {
        var is_prime = true;
        var i: u32 = 2;
        while (i * i <= num) : (i += 1) {
            if (num % i == 0) {
                is_prime = false;
                break;
            }
        }

        if (is_prime) {
            primes_found += 1;
        }

        num += 1;
    }

    _ = std.fmt.bufPrint(result, "Found {d} primes, last was {d}", .{ iterations, num - 1 }) catch |err| {
        _ = std.fmt.bufPrint(result, "Error: {}", .{err}) catch unreachable;
    };
}

fn bufferOverflow(data: []const u8, result: []u8) void {
    const size_to_write = std.mem.readInt(u32, data[0..4], .little);

    var i: usize = 0;
    while (i < size_to_write and i < 1000) : (i += 1) {
        if (i < result.len) {
            result[i] = @truncate(i % 256);
        } else {
            _ = std.fmt.bufPrint(result, "Would have overflowed at index {d}", .{i}) catch unreachable;
            return;
        }
    }

    _ = std.fmt.bufPrint(result, "Wrote {d} bytes", .{i}) catch unreachable;
}

fn memoryExhaustion(data: []const u8, result: []u8) void {
    const alloc_size = std.mem.readInt(u64, data[0..8], .little);

    _ = std.fmt.bufPrint(result, "Would attempt to allocate {d} bytes", .{alloc_size}) catch unreachable;
}
//TODO: As the goal is not to make a full on VM, this will obviously panic and crash the system.
//I provide minimal isolation in this library, but I would like to skirt the lines of isolation vs performance.
fn intentionalPanic(data: []const u8, result: []u8) void {
    _ = std.fmt.bufPrint(result, "Division started...", .{}) catch unreachable;

    const divisor = data[0];

    const result_value = 100 / divisor;

    _ = std.fmt.bufPrint(result, "100 / {d} = {d}", .{ divisor, result_value }) catch unreachable;
}

fn addNumbers(data: []const u8, result: []u8) void {
    const a = data[0];
    const b = data[1];
    const sum = a + b;

    _ = std.fmt.bufPrint(result, "Sum is {d}", .{sum}) catch |err| {
        _ = std.fmt.bufPrint(result, "Error: {}", .{err}) catch unreachable;
    };
}

test "Intensive CPU and memory boundary tests" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var pool = try WhirlPool.init(allocator, 4, 1024 * 1024, 10);
    defer pool.deinit();

    std.debug.print("\n=== Starting intensive CPU test ===\n", .{});

    var iterations_bytes = [_]u8{0} ** 4;
    std.mem.writeInt(u32, &iterations_bytes, 2000, .little); // Find 2000 primes
    var cpu_result = [_]u8{0} ** 64;

    var actor0 = try pool.getActorByPid(0);
    try actor0.mailbox.push(WorkItem{
        .func = computeIntensive,
        .data = &iterations_bytes,
        .result_buffer = &cpu_result,
    });

    std.debug.print("Pushed intensive CPU work to actor {d}\n", .{actor0.pid});

    std.time.sleep(std.time.ns_per_ms * 100);

    std.debug.print("\n=== Starting memory boundary tests ===\n", .{});

    // Test 2: Buffer overflow test
    var overflow_size_bytes = [_]u8{0} ** 4;
    std.mem.writeInt(u32, &overflow_size_bytes, 128, .little);
    var overflow_result = [_]u8{0} ** 64; // Only 64 bytes buffer

    // Push to second actor
    var actor1 = try pool.getActorByPid(1);
    try actor1.mailbox.push(WorkItem{
        .func = bufferOverflow,
        .data = &overflow_size_bytes,
        .result_buffer = &overflow_result,
    });

    std.debug.print("Pushed buffer overflow test to actor {d}\n", .{actor1.pid});

    // Sleep to allow overflow test to complete
    std.time.sleep(std.time.ns_per_ms * 100);

    // Test 3: Memory exhaustion test
    // Get third actor for memory exhaustion
    var target_actor = try pool.getActorByPid(2);

    var exhaustion_params = [_]u8{0} ** 16;
    std.mem.writeInt(u64, exhaustion_params[0..8], 2 * 1024 * 1024, .little); // Try to allocate 2MB (more than actor has)
    std.mem.copyForwards(u8, exhaustion_params[8..16], std.mem.asBytes(&target_actor));
    var exhaustion_result = [_]u8{0} ** 64;
    try target_actor.mailbox.push(WorkItem{
        .func = memoryExhaustion,
        .data = &exhaustion_params,
        .result_buffer = &exhaustion_result,
    });

    std.debug.print("Pushed memory exhaustion test to actor {d}\n", .{target_actor.pid});

    std.time.sleep(std.time.ns_per_ms * 100);
    //TODO: This is temporarily commented out while I decide the true scope of the project.
    //The goal is to provide a better means of concurrency with minimal overhead of thrashing the cache.
    //Panics will, without isolation, bubble up and crash the system.
    // Test 4: Intentional panic with divide by zero
    //var panic_data = [_]u8{0}; // Divisor of 0 will cause panic
    //var panic_result = [_]u8{0} ** 32;

    // Get fourth actor for panic test
    //var panic_actor = try pool.getActorByPid(3);

    //std.debug.print("About to crash actor {d} with divide-by-zero\n", .{panic_actor.pid});

    //try panic_actor.mailbox.push(WorkItem{
    //    .func = intentionalPanic,
    //    .data = &panic_data,
    //    .result_buffer = &panic_result,
    //});
    //
    //std.time.sleep(std.time.ns_per_ms * 500);

    // Test 5: Verify recovery works by pushing work to previously crashed actor
    const data = [_]u8{ 30, 40 };
    var result_buffer = [_]u8{0} ** 32;

    var panic_actor = try pool.getActorByPid(3);
    try panic_actor.mailbox.push(WorkItem{
        .func = addNumbers,
        .data = &data,
        .result_buffer = &result_buffer,
    });

    std.debug.print("Pushed verification work to recovered actor {d}\n", .{panic_actor.pid});

    std.time.sleep(std.time.ns_per_ms * 100);

    std.debug.print("\n=== System state after tests ===\n", .{});
    for (pool.actors) |*actor| {
        std.debug.print("Actor {d} is {s}\n", .{ actor.pid, if (actor.is_alive.load(.acquire)) "alive" else "dead" });
    }
}
