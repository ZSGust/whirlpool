const std = @import("std");
pub const WorkFn = *const fn (data: []const u8, result: []u8) void;

pub const WorkItem = struct {
    func: WorkFn,
    data: []const u8,
    result_buffer: []u8,
};

pub const Mailbox = struct {
    capacity: usize,
    items: []WorkItem,
    head: usize,
    tail: usize,
    count: usize,
    mutex: std.Thread.Mutex,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, capacity: usize) !Mailbox {
        const items = try allocator.alloc(WorkItem, capacity);

        return Mailbox{
            .capacity = capacity,
            .items = items,
            .head = 0,
            .tail = 0,
            .count = 0,
            .mutex = .{},
            .allocator = allocator,
        };
    }
    pub fn push(self: *Mailbox, item: WorkItem) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.count >= self.capacity) {
            return error.MailboxFull;
        }

        self.items[self.tail] = item;
        self.tail = (self.tail + 1) % self.capacity;
        self.count += 1;
    }

    pub fn pop(self: *Mailbox) ?WorkItem {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.count == 0) {
            return null;
        }

        const item = self.items[self.head];
        self.head = (self.head + 1) % self.capacity;
        self.count -= 1;
        return item;
    }

    pub fn deinit(self: *Mailbox) void {
        self.allocator.free(self.items);
    }
};

pub const Actor = struct {
    pid: u64,
    memory: []u8,
    fixed_buffer: std.heap.FixedBufferAllocator,
    arena: std.heap.ArenaAllocator,
    allocator: std.mem.Allocator,
    is_alive: std.atomic.Value(bool),
    thread: ?std.Thread,
    mailbox: Mailbox,

    pub fn init(pid: u64, parent_allocator: std.mem.Allocator, memory_size: usize, mailbox_capacity: usize) !Actor {
        const memory = try parent_allocator.alloc(u8, memory_size);
        var fixed_buffer = std.heap.FixedBufferAllocator.init(memory);
        var arena = std.heap.ArenaAllocator.init(fixed_buffer.allocator());
        const mailbox = try Mailbox.init(parent_allocator, mailbox_capacity);

        return Actor{
            .pid = pid,
            .memory = memory,
            .fixed_buffer = fixed_buffer,
            .arena = arena,
            .allocator = arena.allocator(),
            .is_alive = std.atomic.Value(bool).init(true),
            .thread = null,
            .mailbox = mailbox,
        };
    }

    fn run(self: *Actor) !void {
        while (self.is_alive.load(.acquire)) {
            if (self.mailbox.pop()) |work_item| {
                work_item.func(work_item.data, work_item.result_buffer);
                //TODO: setup logging and time tracking debugging
                std.debug.print("Actor {d} completed work. Result: {s}\n", .{ self.pid, work_item.result_buffer });
            } else {
                // No work, sleep briefly to avoid spinning
                std.time.sleep(std.time.ns_per_ms * 1);
            }
        }
    }

    // Deliberately crash this actor (for testing) DO NOT USE IN PRODUCTION!
    pub fn crash(self: *Actor) void {
        self.is_alive.store(false, .release);
    }

    pub fn deinit(self: *Actor, parent_allocator: std.mem.Allocator) void {
        if (self.thread) |thread| {
            self.is_alive.store(false, .release);
            thread.join();
        }

        self.mailbox.deinit();

        self.arena.deinit();
        parent_allocator.free(self.memory);
    }
};

pub const WhirlPool = struct {
    actors: []Actor,
    allocator: std.mem.Allocator,
    supervisor_thread: ?std.Thread,
    running: std.atomic.Value(bool),
    next_actor_pidx: std.atomic.Value(usize),

    pub fn init(allocator: std.mem.Allocator, actors_requested: usize, memory_per_actor: usize, mailbox_capacity: usize) !WhirlPool {
        const actors = try allocator.alloc(Actor, actors_requested);

        var pool = WhirlPool{
            .actors = actors,
            .allocator = allocator,
            .supervisor_thread = null,
            .running = std.atomic.Value(bool).init(true),
            .next_actor_pidx = std.atomic.Value(usize).init(0),
        };

        for (actors, 0..) |*actor, i| {
            actor.* = try Actor.init(@intCast(i), allocator, memory_per_actor, mailbox_capacity);

            actor.thread = try std.Thread.spawn(.{}, Actor.run, .{actor});
        }
        //TODO: Pin threads to different cpu cores to maximize cache hits.
        pool.supervisor_thread = try std.Thread.spawn(.{}, WhirlPool.superviseThread, .{&pool});

        return pool;
    }
    //TODO: This method is mostly here for testing,
    //as whirlpool's goal is to be actorlite, and be as gentle
    //on cache as possible, I want to keep the abstraction of the actors
    //from spiraling into a VM.
    pub fn getActorByPid(self: *WhirlPool, pid: u64) !*Actor {
        if (pid >= self.actors.len) {
            return error.InvalidActorPid;
        }

        var actor = &self.actors[pid];

        // Check if the actor is alive
        if (!actor.is_alive.load(.acquire)) {
            return error.ActorNotAlive;
        }

        return actor;
    }
    fn superviseThread(self: *WhirlPool) !void {
        while (self.running.load(.acquire)) {
            for (self.actors) |*actor| {
                if (!actor.is_alive.load(.acquire)) {
                    try self.recoverActor(actor.pid);
                }
            }

            // TODO: play with sleep time to avoid burning cycles idling
            std.time.sleep(std.time.ns_per_ms * 10);
        }
    }

    fn getNextActor(self: *WhirlPool) !*Actor {
        const current = self.next_actor_pidx.load(.acquire);
        const next = (current + 1) % self.actors.len;
        self.next_actor_pidx.store(next, .release);

        if (self.actors[current].is_alive.load(.acquire)) {
            return &self.actors[current];
        }

        for (self.actors) |*actor| {
            if (actor.is_alive.load(.acquire)) {
                return actor;
            }
        }

        return error.NoHealthyActorsAvailable;
    }

    pub fn pushWork(self: *WhirlPool, func: WorkFn, data: []const u8, result_buffer: []u8) !void {
        var actor = try self.getNextActor();

        const work_item = WorkItem{
            .func = func,
            .data = data,
            .result_buffer = result_buffer,
        };

        try actor.mailbox.push(work_item);
    }

    pub fn recoverActor(self: *WhirlPool, actor_pid: u64) !void {
        std.debug.print("Attempting to recover actor {d}\n", .{actor_pid});

        if (actor_pid >= self.actors.len) {
            return error.InvalidActorPid;
        }

        var actor = &self.actors[actor_pid];

        if (actor.thread) |thread| {
            thread.join();
            actor.thread = null;
        }

        actor.arena.deinit();

        actor.fixed_buffer = std.heap.FixedBufferAllocator.init(actor.memory);
        actor.arena = std.heap.ArenaAllocator.init(actor.fixed_buffer.allocator());
        actor.allocator = actor.arena.allocator();

        actor.is_alive.store(true, .release);

        actor.thread = try std.Thread.spawn(.{}, Actor.run, .{actor});

        std.debug.print("Actor {d} recovered successfully\n", .{actor_pid});
    }

    pub fn deinit(self: *WhirlPool) void {
        self.running.store(false, .release);

        for (self.actors) |*actor| {
            actor.is_alive.store(false, .release);
        }

        if (self.supervisor_thread) |thread| {
            thread.join();
        }

        for (self.actors) |*actor| {
            actor.deinit(self.allocator);
        }

        self.allocator.free(self.actors);
    }
};

fn addNumbers(data: []const u8, result: []u8) void {
    const a = data[0];
    const b = data[1];
    const sum = a + b;

    _ = std.fmt.bufPrint(result, "Sum is {d}", .{sum}) catch |err| {
        _ = std.fmt.bufPrint(result, "Error: {}", .{err}) catch unreachable;
    };
}

fn multiplyNumbers(data: []const u8, result: []u8) void {
    const a = data[0];
    const b = data[1];
    const product = a * b;

    _ = std.fmt.bufPrint(result, "Product is {d}", .{product}) catch |err| {
        _ = std.fmt.bufPrint(result, "Error: {}", .{err}) catch unreachable;
    };
}

test "Work distribution and fault tolerance" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    const allocator = gpa.allocator();

    // Create a small pool with 4 actors, 1MB each, and mailboxes with capacity 10
    var pool = try WhirlPool.init(allocator, 4, 1024 * 1024, 10);
    defer pool.deinit();

    const data = [_]u8{ 10, 20 };
    var result_buffer = [_]u8{0} ** 32;

    try pool.pushWork(addNumbers, &data, &result_buffer);
    std.debug.print("Pushed addition work\n", .{});

    const data2 = [_]u8{ 5, 7 };
    var result_buffer2 = [_]u8{0} ** 32;
    try pool.pushWork(multiplyNumbers, &data2, &result_buffer2);
    std.debug.print("Pushed multiplication work\n", .{});

    std.time.sleep(std.time.ns_per_ms * 10);

    // Push work to a specific actor, then crash it
    var actor = try pool.getNextActor();
    const data3 = [_]u8{ 30, 40 };
    var result_buffer3 = [_]u8{0} ** 32;

    try actor.mailbox.push(WorkItem{
        .func = addNumbers,
        .data = &data3,
        .result_buffer = &result_buffer3,
    });

    std.debug.print("About to crash actor {d}\n", .{actor.pid});
    actor.crash();

    std.time.sleep(std.time.ns_per_ms * 30);

    // Push more work to see if the system still functions
    const data4 = [_]u8{ 8, 9 };
    var result_buffer4 = [_]u8{0} ** 32;
    try pool.pushWork(multiplyNumbers, &data4, &result_buffer4);
    std.debug.print("Pushed work after crash\n", .{});

    // Wait for final work to complete
    std.time.sleep(std.time.ns_per_ms * 100);
}
