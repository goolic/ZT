const std = @import("std");
const math = @import("imgui").zlm;

inline fn fabs(v: anytype) @TypeOf(v) {
    return if (v < 0) -v else v; // TODO: only way to support zig11 vs nightly @fabs vs fabs(v)
}

// @TODO: More settings to streamline spatial hash usage for other purposes. Maybe even
// make it so you can provide your own coordinate type and functions?
pub const SpatialHashSettings = struct {
    /// The height and width of each bucket inside the hash.
    bucketSize: f32 = 256,
};
pub fn Generate(comptime T: type, comptime spatialSettings: SpatialHashSettings) type {
    // const VisType: type = if (spatialSettings.visualizable) SpatialVisualization else void;
    return struct {
        const context = struct {
            pub fn hash(self: @This(), value: math.Vec2) u64 {
                _ = self;
                return std.hash.Wyhash.hash(438193475, &std.mem.toBytes(value));
            }
            pub fn eql(self: @This(), lhs: math.Vec2, rhs: math.Vec2) bool {
                _ = self;
                return lhs.x == rhs.x and lhs.y == rhs.y;
            }
        };
        const Self = @This();
        /// Some basic settings about the spatial hash, as given at type generation.
        pub const settings = spatialSettings;
        /// This is the inverse of the bucket size, the formula <floor(n*cellInverse)/cellInverse> will
        /// result in the 'hash' that locates the buckets in this spatial hash.
        pub const cellInverse: f32 = 1.0 / spatialSettings.bucketSize;
        /// A Bucket contains all the targets inside of an imaginary cell generated by the spatial hash.
        pub const Bucket = std.AutoArrayHashMap(T, void);
        /// The HashType defines what
        pub const HashType = std.HashMap(math.Vec2, Bucket, context, 80);

        allocator: std.mem.Allocator,
        /// A HashMap of (Vec2 -> Bucket) to contain all the buckets as new ones appear.
        hashBins: HashType,
        /// This is a temporary holding bucket of every target inside of a query. This is used for each query
        /// and as such modifying the spatial hash, or starting a new query will change this bucket.
        holding: Bucket,

        /// Creates a spatial hash instance and allocates memory for the bucket structures.
        pub fn init(allocator: std.mem.Allocator) Self {
            return .{
                .allocator = allocator,
                .hashBins = HashType.init(allocator),
                .holding = Bucket.init(allocator),
                // .visualization = if (spatialSettings.visualizable) .{} else {},
            };
        }
        /// Deallocates all the memory associated with this spatial hash. Note if T is not a pointer,
        /// then this will result in the loss of data.
        pub fn deinit(self: *Self) void {
            var iterator = self.hashBins.iterator();
            while (iterator.next()) |bin| {
                bin.value_ptr.deinit();
            }
            self.holding.deinit();
            self.hashBins.deinit();
        }

        // === ADDS ===

        /// Adds the target to the spatial hash, into every bucket that it spans.
        pub fn addAABB(self: *Self, target: T, position: math.Vec2, size: math.Vec2) void {
            const start = vecToIndex(position).add(.{ .x = settings.bucketSize * 0.5, .y = settings.bucketSize * 0.5 });
            const stop = vecToIndex(position.add(size)).add(.{ .x = settings.bucketSize * 0.5, .y = settings.bucketSize * 0.5 });
            var current = start;

            while (current.x <= stop.x) {
                while (current.y <= stop.y) {
                    var bin = self.getBin(current);
                    bin.put(target, {}) catch unreachable;
                    current.y += settings.bucketSize;
                }
                current.y = start.y;
                current.x += settings.bucketSize;
            }
        }
        /// Adds the target to the spatial hash, into one single bucket.
        pub fn addPoint(self: *Self, target: T, position: math.Vec2) void {
            var result = self.getBin(position);
            result.put(target, {}) catch unreachable;
        }

        // === REMOVALS ===

        /// Removes the target from the spatial hash buckets that it spans. Make sure to provide
        /// the same coordinates that it was added with.
        pub fn removeAABB(self: *Self, target: T, position: math.Vec2, size: math.Vec2) void {
            const stop = position.add(size);
            var current = position;

            while (current.x <= stop.x) : (current.x += settings.bucketSize) {
                while (current.y <= stop.y) : (current.y += settings.bucketSize) {
                    var bin = self.getBin(current);
                    _ = bin.swapRemove(target);
                }
            }
        }
        /// Removes the target from the spatial hash's singular bucket. Make sure to provide
        /// the same coordinate that it was added with.
        pub fn removePoint(self: *Self, target: T, position: math.Vec2) void {
            const result = self.getBin(position);
            _ = result.swapRemove(target);
        }

        // === QUERIES ===

        /// Returns an array of each T inside of the given rectangle.
        /// Note that broad phase physics like this is not accurate, instead this opts to return in general
        /// what *could* be a possible collision.
        pub fn queryAABB(self: *Self, position: math.Vec2, size: math.Vec2) []T {
            self.holding.unmanaged.clearRetainingCapacity();
            const start = vecToIndex(position).add(.{ .x = settings.bucketSize * 0.5, .y = settings.bucketSize * 0.5 });
            const stop = vecToIndex(position.add(size)).add(.{ .x = settings.bucketSize * 0.5, .y = settings.bucketSize * 0.5 });
            var current = start;

            while (current.x <= stop.x) {
                while (current.y <= stop.y) {
                    var bin = self.getBin(current);
                    for (bin.keys()) |value| {
                        self.holding.put(value, {}) catch unreachable;
                    }
                    current.y += settings.bucketSize;
                }
                current.y = start.y;
                current.x += settings.bucketSize;
            }
            return self.holding.keys();
        }
        /// Returns an array of each T inside of the given point's bucket.
        /// Note that broad phase physics like this is not accurate, instead this opts to return in general
        /// what *could* be a possible collision.
        pub fn queryPoint(self: *Self, point: math.Vec2) []T {
            self.holding.unmanaged.clearRetainingCapacity();
            const bin = self.getBin(point);
            for (bin.keys()) |value| {
                self.holding.put(value, {}) catch unreachable;
            }
            return self.holding.keys();
        }

        inline fn queryLineLow(self: *Self, queryStart: math.Vec2, queryEnd: math.Vec2) void {
            var delta = queryEnd.sub(queryStart);
            var yi = settings.bucketSize;
            var current = queryStart;

            if (delta.y < 0) {
                yi = -settings.bucketSize;
                delta.y = -delta.y;
            }

            var D = (2 * delta.y) - delta.x;

            while (current.x < queryEnd.x) {
                // Plot:
                var bin = self.getBin(current);
                for (bin.keys()) |value| {
                    self.holding.put(value, {}) catch unreachable;
                }

                if (D > 0) {
                    current.y = current.y + yi;
                    D = D + (2 * (delta.y - delta.x));
                } else {
                    D = D + 2 * delta.y;
                }

                current.x += settings.bucketSize;
            }
        }
        inline fn queryLineHigh(self: *Self, queryStart: math.Vec2, queryEnd: math.Vec2) void {
            var delta = queryEnd.sub(queryStart);
            var xi = settings.bucketSize;
            var current = queryStart;

            if (delta.x < 0) {
                xi = -settings.bucketSize;
                delta.x = -delta.x;
            }

            var D = (2 * delta.x) - delta.y;

            while (current.y < queryEnd.y) {
                // Plot:
                var bin = self.getBin(current);
                for (bin.keys()) |value| {
                    self.holding.put(value, {}) catch unreachable;
                }

                if (D > 0) {
                    current.x = current.x + xi;
                    D = D + (2 * (delta.x - delta.y));
                } else {
                    D = D + 2 * delta.x;
                }

                current.y += settings.bucketSize;
            }
        }
        /// Returns an array of each T inside every bucket along this line's path.
        /// Note that broad phase physics like this is not accurate, instead this opts to return in general
        /// what *could* be a possible collision.
        pub fn queryLine(self: *Self, queryStart: math.Vec2, queryEnd: math.Vec2) []T {
            self.holding.unmanaged.clearRetainingCapacity();

            // Had some edge issues with some quadrants not including start/end.
            {
                const bin = self.getBin(queryStart);
                for (bin.keys()) |value| {
                    self.holding.put(value, {}) catch unreachable;
                }
            }
            {
                const bin = self.getBin(queryEnd);
                for (bin.keys()) |value| {
                    self.holding.put(value, {}) catch unreachable;
                }
            }

            if (fabs(queryEnd.y - queryStart.y) < fabs(queryEnd.x - queryStart.x)) {
                if (queryStart.x > queryEnd.x) {
                    self.queryLineLow(queryEnd, queryStart);
                } else {
                    self.queryLineLow(queryStart, queryEnd);
                }
            } else {
                if (queryStart.y > queryEnd.y) {
                    self.queryLineHigh(queryEnd, queryStart);
                } else {
                    self.queryLineHigh(queryStart, queryEnd);
                }
            }

            return self.holding.keys();
        }

        inline fn getBin(self: *Self, position: math.Vec2) *Bucket {
            const hash = vecToIndex(position);
            const result = self.hashBins.getOrPut(hash) catch unreachable;
            if (!result.found_existing) {
                result.value_ptr.* = Bucket.init(self.allocator);
            }
            return result.value_ptr;
        }
        inline fn vecToIndex(vec: math.Vec2) math.Vec2 {
            return .{ .x = floatToIndex(vec.x), .y = floatToIndex(vec.y) };
        }
        inline fn floatToIndex(float: f32) f32 {
            return (@floor(float * cellInverse)) / cellInverse;
        }
    };
}

test "speed testing spatial hash" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    std.debug.print("\n> Spatial hash Speedtest with GPA Allocator:\n", .{});

    var hash = Generate(usize, .{ .bucketSize = 50 }).init(&gpa.allocator);
    defer hash.deinit();

    var rand = std.rand.DefaultPrng.init(3741837483).random;
    var clock = std.time.Timer.start() catch unreachable;
    _ = clock.lap();
    var i: usize = 0;
    while (i < 10000) : (i += 1) {
        const randX = rand.float(f32) * 200;
        const randY = rand.float(f32) * 200;
        hash.addPoint(i, math.vec2(randX, randY));
    }
    var time = clock.lap();
    std.debug.print(">> Took {d:.2}ms to create 10,000 points on a hash of usize.\n", .{@as(f64, @floatFromInt(time)) / 1000000.0});

    while (i < 20000) : (i += 1) {
        const randX = rand.float(f32) * 200;
        const randY = rand.float(f32) * 200;
        hash.addPoint(i, math.vec2(randX, randY));
    }
    time = clock.lap();
    std.debug.print(">> Took {d:.2}ms to create 10,000 more points on a hash of usize.\n", .{@as(f64, @floatFromInt(time)) / 1000000.0});

    i = 0;
    var visited: i32 = 0;
    while (i < 200) : (i += 1) {
        for (hash.queryPoint(.{ .x = rand.float(f32) * 200, .y = rand.float(f32) * 200 })) |_| {
            visited += 1;
        }
    }
    time = clock.lap();
    std.debug.print(">> Took {d:.2}ms to point iterate over a bucket 200 times, and visited {any} items.\n", .{ @as(f64, @floatFromInt(time)) / 1000000.0, visited });
}

test "spatial point insertion/remove/query" {
    const assert = @import("std").debug.assert;

    const hash = Generate(i32, .{ .bucketSize = 64 }).init(std.testing.allocator);
    defer hash.deinit();

    hash.addPoint(40, .{ .x = 20, .y = 20 });
    hash.addPoint(80, .{ .x = 100, .y = 100 });

    {
        const data = hash.queryPoint(.{ .x = 10, .y = 10 });
        assert(data.len == 1);
        assert(data[0] == 40);
    }
    {
        hash.addPoint(100, .{ .x = 40, .y = 40 });
        const data = hash.queryPoint(.{ .x = 10, .y = 10 });
        assert(data[0] == 40);
        assert(data[1] == 100);
        assert(data.len == 2);
    }
    {
        hash.removePoint(100, .{ .x = 40, .y = 40 });
        const data = hash.queryPoint(.{ .x = 10, .y = 10 });
        assert(data[0] == 40);
        assert(data.len == 1);
    }
}

test "spatial rect insertion/remove/query" {
    const assert = @import("std").debug.assert;
    const hash = Generate(i32, .{ .bucketSize = 100 }).init(std.testing.allocator);
    defer hash.deinit();

    hash.addAABB(1, math.vec2(50, 50), math.vec2(100, 100));
    {
        const data = hash.queryAABB(math.vec2(0, 0), math.vec2(150, 150));
        assert(data.len == 1);
    }

    hash.addAABB(2, math.vec2(150, 150), math.vec2(100, 100));
    {
        const data = hash.queryAABB(math.vec2(0, 0), math.vec2(100, 100));
        assert(data.len == 2);
    }

    hash.removeAABB(2, math.vec2(150, 150), math.vec2(100, 100));
    {
        const data = hash.queryAABB(math.vec2(0, 0), math.vec2(100, 100));
        assert(data.len == 1);
    }
}
test "spatial line query" {
    const assert = @import("std").debug.assert;
    var hash = Generate(i32, .{ .bucketSize = 100 }).init(std.testing.allocator);
    defer hash.deinit();

    // formation like
    // *     *                     *
    //
    //
    // *     *
    //
    //
    //
    //
    //
    //
    // *

    hash.addPoint(1, math.vec2(20, 20));
    hash.addPoint(2, math.vec2(350, 350));
    hash.addPoint(3, math.vec2(350, 20));
    hash.addPoint(4, math.vec2(20, 350));
    hash.addPoint(5, math.vec2(20, 3500));
    hash.addPoint(6, math.vec2(3500, 20));
    {
        // horizontal, should have 2.
        var data = hash.queryLine(math.vec2(20, 20), math.vec2(520, 20));
        assert(data.len == 2);
        // diagonal, should have 2.
        data = hash.queryLine(math.vec2(0, 0), math.vec2(400, 400));
        assert(data.len == 2);
        // Reverse diagonal, should have 2.
        data = hash.queryLine(math.vec2(400, 400), math.vec2(0, 0));
        assert(data.len == 2);
        // vertical, also 2.
        data = hash.queryLine(math.vec2(20, 20), math.vec2(20, 520));
        assert(data.len == 2);
    }
}
