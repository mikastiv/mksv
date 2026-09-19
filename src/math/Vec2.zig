const std = @import("std");
const assert = std.debug.assert;

const Vec2 = @This();

x: f32,
y: f32,

pub inline fn add(a: Vec2, b: Vec2) Vec2 {
    return .{ .x = a.x + b.x, .y = a.y + b.y };
}

pub inline fn sub(a: Vec2, b: Vec2) Vec2 {
    return .{ .x = a.x - b.x, .y = a.y - b.y };
}

pub inline fn mul(a: Vec2, b: f32) Vec2 {
    return .{ .x = a.x * b, .y = a.y * b };
}

pub inline fn div(a: Vec2, b: f32) Vec2 {
    return a.mul(1.0 / b);
}

pub inline fn dot(a: Vec2, b: Vec2) f32 {
    return a.x * b.x + a.y * b.y;
}

pub inline fn lengthSq(v: Vec2) f32 {
    return dot(v, v);
}

pub inline fn length(v: Vec2) f32 {
    return @sqrt(lengthSq(v));
}

pub fn normalized(v: Vec2) Vec2 {
    const len = v.length();
    return v.div(len);
}
