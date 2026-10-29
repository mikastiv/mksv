const std = @import("std");
const assert = std.debug.assert;

const Gltf = @This();

const log = std.log.scoped(.gltf);

const magic = struct {
    const glb = std.mem.readInt(u32, &[4]u8{ 'g', 'l', 'T', 'F' }, .little);
    const json = std.mem.readInt(u32, &[4]u8{ 'J', 'S', 'O', 'N' }, .little);
    const bin = std.mem.readInt(u32, &[4]u8{ 'B', 'I', 'N', 0 }, .little);
};

test "magic" {
    try std.testing.expect(magic.glb == 0x46546c67);
    try std.testing.expect(magic.json == 0x4e4f534a);
    try std.testing.expect(magic.bin == 0x004e4942);
}

pub const Integer = u32;
pub const Number = f32;
pub const Vec3 = [3]Number;
pub const Vec4 = [4]Number;
pub const Mat4 = [16]Number;

accessors: ?[]Accessor = null,
animations: ?[]Animation = null,
asset: Asset,
buffers: ?[]Buffer = null,
bufferViews: ?[]BufferView = null,
cameras: ?[]Camera = null,
images: ?[]Image = null,
materials: ?[]Material = null,
meshes: ?[]Mesh = null,
nodes: ?[]Node = null,
samplers: ?[]Sampler = null,
scene: ?Integer = null,
scenes: ?[]Scene = null,
skins: ?[]Skin = null,
textures: ?[]Texture = null,
extensions: ?Extensions = null,
extensionsUsed: ?[]const []const u8 = null,
extensionsRequired: ?[]const []const u8 = null,
extras: ?Extras = null,
binary: ?[]const u8 = null,

pub const Extensions = std.json.ArrayHashMap(std.json.Value);

pub const Extras = std.json.Value;

pub const Asset = struct {
    copyright: ?[]const u8 = null,
    generator: ?[]const u8 = null,
    version: []const u8,
    minVersion: ?[]const u8 = null,
    extensions: ?Extensions = null,
    extras: ?Extras = null,
};

pub const Accessor = struct {
    pub const Sparse = struct {
        pub const Indices = struct {
            bufferView: Integer,
            byteOffset: Integer = 0,
            componentType: ComponentType,
            extensions: ?Extensions = null,
            extras: ?Extras = null,
        };

        pub const Values = struct {
            bufferView: Integer,
            byteOffset: Integer = 0,
            extensions: ?Extensions = null,
            extras: ?Extras = null,
        };

        count: Integer,
        indices: Indices,
        values: Values,
        extensions: ?Extensions = null,
        extras: ?Extras = null,
    };

    pub const ComponentType = enum(Integer) {
        byte = 5120,
        unsigned_byte = 5121,
        short = 5122,
        unsigned_short = 5123,
        unsigned_int = 5125,
        float = 5126,

        pub fn size(self: ComponentType) Integer {
            return switch (self) {
                .byte => @sizeOf(i8),
                .unsigned_byte => @sizeOf(u8),
                .short => @sizeOf(i16),
                .unsigned_short => @sizeOf(u16),
                .unsigned_int => @sizeOf(u32),
                .float => @sizeOf(f32),
            };
        }
    };

    pub const Type = enum {
        SCALAR,
        VEC2,
        VEC3,
        VEC4,
        MAT2,
        MAT3,
        MAT4,

        pub fn componentCount(self: Type) Integer {
            return switch (self) {
                .SCALAR => 1,
                .VEC2 => 2,
                .VEC3 => 3,
                .VEC4, .MAT2 => 4,
                .MAT3 => 9,
                .MAT4 => 16,
            };
        }
    };

    pub fn Iterator(comptime T: type) type {
        return struct {
            buffer: []const u8,
            stride: Integer,
            count: Integer,
            index: u32,

            pub fn next(self: *@This()) ?T {
                if (self.index >= self.count) return null;

                const offset = @as(usize, self.index) * self.stride;
                const bytes = self.buffer[offset .. offset + @sizeOf(T)];
                const value = std.mem.bytesToValue(T, bytes);

                self.index += 1;

                return value;
            }

            pub fn peek(self: *const @This()) ?T {
                var copy = self.*;
                return copy.next();
            }

            pub fn reset(self: *@This()) void {
                self.index = 0;
            }
        };
    }

    bufferView: ?Integer = null,
    byteOffset: Integer = 0,
    componentType: ComponentType,
    normalized: bool = false,
    count: Integer,
    type: Type,
    max: ?[]Number = null,
    min: ?[]Number = null,
    sparse: ?Sparse = null,
    name: ?[]const u8 = null,
    extensions: ?Extensions = null,
    extras: ?Extras = null,

    pub fn elementSize(self: *const Accessor) Integer {
        const component_size = self.componentType.size();
        const columns: Integer = switch (self.type) {
            .MAT2 => 2,
            .MAT3 => 3,
            .MAT4 => 4,
            else => return component_size * self.type.componentCount(),
        };
        return columns * std.mem.alignForward(Integer, columns * component_size, 4);
    }

    pub fn iterator(self: *const Accessor, comptime T: type, gltf: *const Gltf, binary: []const u8) Iterator(T) {
        // TODO: support multiple binary data blob
        // TODO: support data URIs

        assert(self.sparse == null); // not supported
        assert(self.count > 0); // required by spec

        const packed_size = self.componentType.size() * self.type.componentCount();
        assert(packed_size == @sizeOf(T));
        const element_size = self.elementSize();
        assert(element_size == packed_size); // TODO: decode padded matrix columns.

        const buffer_view = &gltf.bufferViews.?[self.bufferView.?];

        const stride = if (buffer_view.byteStride) |stride| stride else element_size;
        const start = @as(usize, self.byteOffset) + buffer_view.byteOffset;
        const end = start + @as(usize, self.count - 1) * stride + element_size;

        return .{
            .buffer = binary[start..end],
            .stride = stride,
            .count = self.count,
            .index = 0,
        };
    }
};

pub const Buffer = struct {
    uri: ?[]const u8 = null,
    byteLength: Integer,
    name: ?[]const u8 = null,
    extensions: ?Extensions = null,
    extras: ?Extras = null,
};

pub const BufferView = struct {
    pub const Target = enum(Integer) {
        array_buffer = 34962,
        element_array_buffer = 34963,
    };

    buffer: Integer,
    byteOffset: Integer = 0,
    byteLength: Integer,
    byteStride: ?Integer = null,
    target: ?Target = null,
    name: ?[]const u8 = null,
    extensions: ?Extensions = null,
    extras: ?Extras = null,
};

pub const Scene = struct {
    nodes: ?[]Integer = null,
    name: ?[]const u8 = null,
    extensions: ?Extensions = null,
    extras: ?Extras = null,
};

pub const Node = struct {
    camera: ?Integer = null,
    children: ?[]Integer = null,
    skin: ?Integer = null,
    matrix: ?Mat4 = null,
    mesh: ?Integer = null,
    rotation: Vec4 = .{ 0.0, 0.0, 0.0, 1.0 },
    scale: Vec3 = .{ 1.0, 1.0, 1.0 },
    translation: Vec3 = .{ 0.0, 0.0, 0.0 },
    weights: ?[]Number = null,
    name: ?[]const u8 = null,
    extensions: ?Extensions = null,
    extras: ?Extras = null,
};

pub const Mesh = struct {
    pub const Mode = enum(Integer) {
        points = 0,
        lines = 1,
        line_loop = 2,
        line_strip = 3,
        triangles = 4,
        triangle_strip = 5,
        triangle_fan = 6,
    };

    pub const Attributes = std.json.ArrayHashMap(Integer);

    pub const Primitive = struct {
        attributes: Attributes,
        indices: ?Integer = null,
        mode: Mode = .triangles,
        material: ?Integer = null,
        targets: ?[]Attributes = null,
    };

    primitives: []Primitive,
    weights: ?[]Number = null,
    name: ?[]const u8 = null,
    extensions: ?Extensions = null,
    extras: ?Extras = null,
};

pub const Camera = struct {
    pub const Type = enum {
        perspective,
        orthographic,
    };

    pub const Orthographic = struct {
        xmag: Number,
        ymag: Number,
        zfar: Number,
        znear: Number,
    };

    pub const Perspective = struct {
        aspectRatio: ?Number = null,
        yfov: Number,
        zfar: ?Number = null,
        znear: Number,
    };

    orthographic: ?Orthographic = null,
    perspective: ?Perspective = null,
    type: Type,
    name: ?[]const u8 = null,
    extensions: ?Extensions = null,
    extras: ?Extras = null,
};

pub const Skin = struct {
    inverseBindMatrices: ?Integer = null,
    skeleton: ?Integer = null,
    joints: []Integer,
    name: ?[]const u8 = null,
    extensions: ?Extensions = null,
    extras: ?Extras = null,
};

pub const Animation = struct {
    pub const Channel = struct {
        pub const Target = struct {
            pub const Path = enum {
                translation,
                rotation,
                scale,
                weights,
            };

            node: ?Integer = null,
            path: Path,
            extensions: ?Extensions = null,
            extras: ?Extras = null,
        };

        sampler: Integer,
        target: Target,
        extensions: ?Extensions = null,
        extras: ?Extras = null,
    };

    pub const Sampler = struct {
        pub const Interpolation = enum {
            LINEAR,
            STEP,
            CUBICSPLINE,
        };

        input: Integer,
        interpolation: Interpolation = .LINEAR,
        output: Integer,
        extensions: ?Extensions = null,
        extras: ?Extras = null,
    };

    channels: []Animation.Channel,
    samplers: []Animation.Sampler,
    name: ?[]const u8 = null,
    extensions: ?Extensions = null,
    extras: ?Extras = null,
};

pub const TextureInfo = struct {
    index: Integer,
    texCoord: Integer = 0,
    extensions: ?Extensions = null,
    extras: ?Extras = null,
};

pub const Material = struct {
    pub const PbrMetallicRoughness = struct {
        baseColorFactor: Vec4 = .{ 1.0, 1.0, 1.0, 1.0 },
        baseColorTexture: ?TextureInfo = null,
        metallicFactor: Number = 1.0,
        roughnessFactor: Number = 1.0,
        metallicRoughnessTexture: ?TextureInfo = null,
        extensions: ?Extensions = null,
        extras: ?Extras = null,
    };

    pub const NormalTextureInfo = struct {
        index: Integer,
        texCoord: Integer = 0,
        scale: Number = 1.0,
        extensions: ?Extensions = null,
        extras: ?Extras = null,
    };

    pub const OcclusionTextureInfo = struct {
        index: Integer,
        texCoord: Integer = 0,
        strength: Number = 1.0,
        extensions: ?Extensions = null,
        extras: ?Extras = null,
    };

    pub const AlphaMode = enum {
        OPAQUE,
        MASK,
        BLEND,
    };

    name: ?[]const u8 = null,
    extensions: ?Extensions = null,
    extras: ?Extras = null,
    pbrMetallicRoughness: ?PbrMetallicRoughness = null,
    normalTexture: ?NormalTextureInfo = null,
    occlusionTexture: ?OcclusionTextureInfo = null,
    emissiveTexture: ?TextureInfo = null,
    emissiveFactor: Vec3 = .{ 0.0, 0.0, 0.0 },
    alphaMode: AlphaMode = .OPAQUE,
    alphaCutoff: Number = 0.5,
    doubleSided: bool = false,
};

pub const Texture = struct {
    sampler: ?Integer = null,
    source: ?Integer = null,
    name: ?[]const u8 = null,
    extensions: ?Extensions = null,
    extras: ?Extras = null,
};

pub const Image = struct {
    pub const MimeType = enum {
        @"image/jpeg",
        @"image/png",
    };

    uri: ?[]const u8 = null,
    mimeType: ?MimeType = null,
    bufferView: ?Integer = null,
    name: ?[]const u8 = null,
    extensions: ?Extensions = null,
    extras: ?Extras = null,
};

pub const Sampler = struct {
    pub const Filter = enum(Integer) {
        nearest = 9728,
        linear = 9729,
        nearest_mipmap_nearest = 9984,
        linear_mipmap_nearest = 9985,
        nearest_mipmap_linear = 9986,
        linear_mipmap_linear = 9987,
    };

    pub const Wrap = enum(Integer) {
        clamp_to_edge = 33071,
        mirrored_repeat = 33648,
        repeat = 10497,
    };

    magFilter: ?Filter = null,
    minFilter: ?Filter = null,
    wrapS: Wrap = .repeat,
    wrapT: Wrap = .repeat,
    name: ?[]const u8 = null,
    extensions: ?Extensions = null,
    extras: ?Extras = null,
};

const Glb = struct {
    json: []const u8,
    binary: ?[]const u8,
};

pub fn parse(allocator: std.mem.Allocator, data: []align(4) const u8, enable_log: bool) !Gltf {
    if (data.len < 4) return error.InvalidGltfFile;

    const is_glb = std.mem.readInt(u32, data[0..4], .little) == magic.glb;
    const gltf = blk: switch (is_glb) {
        true => {
            const glb = try parseGlb(data);
            var json = try std.json.parseFromSliceLeaky(Gltf, allocator, glb.json, .{});
            json.binary = glb.binary;
            break :blk json;
        },
        false => try std.json.parseFromSliceLeaky(Gltf, allocator, data, .{}),
    };

    var diagnostics: ?[]const u8 = null;
    validate(&gltf, allocator, &diagnostics) catch |err| {
        if (diagnostics) |message| {
            defer allocator.free(message);
            if (enable_log) log.err("{s}", .{message});
        }

        return err;
    };

    return gltf;
}

pub fn loadBinaryData(self: *const Gltf, allocator: std.mem.Allocator, io: std.Io, dirpath: []const u8) !?[]u8 {
    if (self.buffers) |buffers| {
        const dir = try std.Io.Dir.cwd().openDir(io, dirpath, .{});
        defer dir.close(io);

        for (buffers) |buffer| {
            if (buffer.uri) |uri| {
                return try dir.readFileAlloc(io, uri, allocator, .limited(std.math.maxInt(u32)));
            }
        }
    }

    return null;
}

fn validate(self: *const Gltf, allocator: std.mem.Allocator, diagnostics: *?[]const u8) !void {
    if (!std.mem.eql(u8, self.asset.version, "2.0")) {
        diagnostics.* = try allocator.print("unsupported gltf version: {s}", .{self.asset.version});
        return error.UnsupportedGltfVersion;
    }

    if (self.accessors) |accessors| {
        for (accessors, 0..) |accessor, i| {
            if (accessor.bufferView) |bufferView| {
                if (!validIndex(bufferView, self.bufferViews)) {
                    diagnostics.* = try allocator.print("accessors[{d}].bufferView refers to a bufferView ({d}) that doesn't exist", .{ i, bufferView });
                    return error.InvalidGltf;
                }
            }

            const component_size = accessor.componentType.size();
            if (accessor.byteOffset % component_size != 0) {
                diagnostics.* = try allocator.print("accessors[{d}].byteOffset % componentType's size ({d}) != 0", .{ i, component_size });
                return error.InvalidGltf;
            }

            if (accessor.componentType == .unsigned_int) {
                if (self.meshes) |meshes| {
                    loop: for (meshes) |mesh| {
                        for (mesh.primitives) |primitive| {
                            if (primitive.indices) |indices| {
                                if (indices == i) break :loop;
                            }
                        }
                    } else {
                        diagnostics.* = try allocator.print("accessors[{d}].componentType is unsigned_int but is not refered by any mesh.primitive.indices", .{i});
                        return error.InvalidGltf;
                    }
                } else {
                    diagnostics.* = try allocator.print("accessors[{d}].componentType is unsigned_int but is not refered by any mesh.primitive.indices", .{i});
                    return error.InvalidGltf;
                }

                if (accessor.type != .SCALAR) {
                    diagnostics.* = try allocator.print("accessors[{d}].type is not SCALAR but is refered by a mesh.primitive.indices", .{i});
                    return error.InvalidGltf;
                }
            }

            if (accessor.normalized and (accessor.componentType == .float or accessor.componentType == .unsigned_int)) {
                diagnostics.* = try allocator.print("accessors[{d}].normalized is true but accessor[{d}].componentType is {t}", .{ i, i, accessor.componentType });
                return error.InvalidGltf;
            }

            if (accessor.count < 1) {
                diagnostics.* = try allocator.print("accessors[{d}].count < 1", .{i});
                return error.InvalidGltf;
            }

            if (accessor.bufferView) |bufferView| {
                const view = &self.bufferViews.?[bufferView];
                if (view.byteOffset % component_size != 0) {
                    diagnostics.* = try allocator.print("accessors[{d}].bufferView.byteOffset % componentType's size ({d}) != 0", .{ i, component_size });
                    return error.InvalidGltf;
                }

                const element_size = accessor.elementSize();
                const stride = view.byteStride orelse element_size;
                if (stride < element_size) {
                    diagnostics.* = try allocator.print("accessors[{d}].bufferView.byteStride < element size ({d})", .{ i, element_size });
                    return error.InvalidGltf;
                }
                if (stride % component_size != 0) {
                    diagnostics.* = try allocator.print("accessors[{d}].bufferView.byteStride % componentType's size ({d}) != 0", .{ i, component_size });
                    return error.InvalidGltf;
                }

                // Widen before arithmetic: offset, count, and stride are all u32.
                const end = @as(u64, accessor.byteOffset) + @as(u64, accessor.count - 1) * stride + element_size;
                if (end > view.byteLength) {
                    diagnostics.* = try allocator.print("accessors[{d}] exceeds its bufferView's byteLength", .{i});
                    return error.InvalidGltf;
                }
            } else if (accessor.byteOffset != 0) {
                diagnostics.* = try allocator.print("accessors[{d}].byteOffset != 0 but accessors[{d}].bufferView == null", .{ i, i });
                return error.InvalidGltf;
            }

            const component_count = accessor.type.componentCount();
            if (accessor.max) |max| {
                if (max.len != component_count) {
                    diagnostics.* = try allocator.print("accessors[{d}].max != type's component count ({d})", .{ i, component_count });
                    return error.InvalidGltf;
                }
            }

            if (accessor.min) |min| {
                if (min.len != component_count) {
                    diagnostics.* = try allocator.print("accessors[{d}].min != type's component count ({d})", .{ i, component_count });
                    return error.InvalidGltf;
                }
            }

            if (accessor.sparse) |_| {
                // TODO
            }
        }
    }

    if (self.animations) |animations| {
        for (animations, 0..) |animation, i| {
            for (animation.channels, 0..) |channel, j| {
                if (!validIndex(channel.sampler, animation.samplers)) {
                    diagnostics.* = try allocator.print("animations[{d}].channels[{d}].sampler refers to a sampler ({d}) that doesn't exist", .{ i, j, channel.sampler });
                    return error.InvalidGltf;
                }

                if (channel.target.node) |node| {
                    if (!validIndex(node, self.nodes)) {
                        diagnostics.* = try allocator.print("animations[{d}].channels[{d}].target.node refers to a node ({d}) that doesn't exist", .{ i, j, node });
                        return error.InvalidGltf;
                    }
                }
            }

            for (animation.samplers, 0..) |sampler, j| {
                if (!validIndex(sampler.input, self.accessors)) {
                    diagnostics.* = try allocator.print("animations[{d}].samplers[{d}].input refers to an accessor ({d}) that doesn't exist", .{ i, j, sampler.input });
                    return error.InvalidGltf;
                }

                if (!validIndex(sampler.output, self.accessors)) {
                    diagnostics.* = try allocator.print("animations[{d}].samplers[{d}].output refers to an accessor ({d}) that doesn't exist", .{ i, j, sampler.output });
                    return error.InvalidGltf;
                }
            }
        }
    }

    if (self.buffers) |buffers| {
        for (buffers, 0..) |buffer, i| {
            if (buffer.byteLength < 1) {
                diagnostics.* = try allocator.print("buffers[{d}].byteLength < 1", .{i});
                return error.InvalidGltf;
            }
        }
    }

    if (self.bufferViews) |bufferViews| {
        for (bufferViews, 0..) |bufferView, i| {
            if (!validIndex(bufferView.buffer, self.buffers)) {
                diagnostics.* = try allocator.print("bufferViews[{d}].buffer refers to a buffer ({d}) that doesn't exist", .{ i, bufferView.buffer });
                return error.InvalidGltf;
            }

            if (bufferView.byteLength < 1) {
                diagnostics.* = try allocator.print("bufferViews[{d}].byteLength < 1", .{i});
                return error.InvalidGltf;
            }

            if (@as(u64, bufferView.byteOffset) + bufferView.byteLength > self.buffers.?[bufferView.buffer].byteLength) {
                diagnostics.* = try allocator.print("bufferViews[{d}] exceeds its buffer's byteLength", .{i});
                return error.InvalidGltf;
            }

            if (bufferView.byteStride) |byteStride| {
                if (byteStride % 4 != 0) {
                    diagnostics.* = try allocator.print("bufferViews[{d}].byteStride is not a multiple of 4", .{i});
                    return error.InvalidGltf;
                }
                if (byteStride < 4) {
                    diagnostics.* = try allocator.print("bufferViews[{d}].byteStride < 4", .{i});
                    return error.InvalidGltf;
                }

                if (byteStride > 252) {
                    diagnostics.* = try allocator.print("bufferViews[{d}].byteStride > 252", .{i});
                    return error.InvalidGltf;
                }
            }
        }
    }

    if (self.cameras) |cameras| {
        for (cameras, 0..) |camera, i| {
            switch (camera.type) {
                .orthographic => {
                    if (camera.orthographic == null) {
                        diagnostics.* = try allocator.print("cameras[{d}].orthographic == null but cameras[{d}].type is \"orthographic\"", .{ i, i });
                        return error.InvalidGltf;
                    }

                    if (camera.perspective != null) {
                        diagnostics.* = try allocator.print("cameras[{d}].perspective != null but cameras[{d}].type is \"orthographic\"", .{ i, i });
                        return error.InvalidGltf;
                    }

                    if (camera.orthographic.?.zfar <= 0) {
                        diagnostics.* = try allocator.print("cameras[{d}].orthographic.zfar <= 0", .{i});
                        return error.InvalidGltf;
                    }

                    if (camera.orthographic.?.znear < 0) {
                        diagnostics.* = try allocator.print("cameras[{d}].orthographic.znear < 0", .{i});
                        return error.InvalidGltf;
                    }
                },
                .perspective => {
                    if (camera.perspective == null) {
                        diagnostics.* = try allocator.print("cameras[{d}].perspective == null but cameras[{d}].type is \"perspective\"", .{ i, i });
                        return error.InvalidGltf;
                    }

                    if (camera.orthographic != null) {
                        diagnostics.* = try allocator.print("cameras[{d}].orthographic != null but cameras[{d}].type is \"perspective\"", .{ i, i });
                        return error.InvalidGltf;
                    }

                    if (camera.perspective.?.aspectRatio) |aspectRatio| {
                        if (aspectRatio <= 0) {
                            diagnostics.* = try allocator.print("cameras[{d}].orthographic.aspectRatio <= 0", .{i});
                            return error.InvalidGltf;
                        }
                    }

                    if (camera.perspective.?.yfov <= 0) {
                        diagnostics.* = try allocator.print("cameras[{d}].orthographic.yfov <= 0", .{i});
                        return error.InvalidGltf;
                    }

                    if (camera.perspective.?.zfar) |zfar| {
                        if (zfar <= 0) {
                            diagnostics.* = try allocator.print("cameras[{d}].orthographic.zfar <= 0", .{i});
                            return error.InvalidGltf;
                        }
                    }

                    if (camera.perspective.?.znear <= 0) {
                        diagnostics.* = try allocator.print("cameras[{d}].orthographic.znear <= 0", .{i});
                        return error.InvalidGltf;
                    }
                },
            }
        }
    }

    if (self.images) |images| {
        for (images, 0..) |image, i| {
            if (image.bufferView) |bufferView| {
                if (!validIndex(bufferView, self.bufferViews)) {
                    diagnostics.* = try allocator.print("images[{d}].bufferViews refers to a bufferView ({d}) that doesn't exist", .{ i, bufferView });
                    return error.InvalidGltf;
                }
            }

            if (image.bufferView != null and image.uri != null) {
                diagnostics.* = try allocator.print("images[{d}].uri != null and image[{d}].bufferView != null", .{ i, i });
                return error.InvalidGltf;
            }

            if (image.bufferView == null and image.uri == null) {
                diagnostics.* = try allocator.print("images[{d}].uri == null and image[{d}].bufferView == null", .{ i, i });
                return error.InvalidGltf;
            }

            if (image.bufferView != null and image.mimeType == null) {
                diagnostics.* = try allocator.print("images[{d}].bufferView != null but images[{d}].mimeType == null", .{ i, i });
                return error.InvalidGltf;
            }
        }
    }

    if (self.materials) |materials| {
        for (materials, 0..) |material, i| {
            if (material.pbrMetallicRoughness) |metallic| {
                if (metallic.baseColorTexture) |texture| {
                    if (!validIndex(texture.index, self.textures)) {
                        diagnostics.* = try allocator.print("materials[{d}].pbrMetallicRoughness.baseColorTexture.index refers to a texture ({d}) that doesn't exist", .{ i, texture.index });
                        return error.InvalidGltf;
                    }
                }

                if (metallic.metallicRoughnessTexture) |texture| {
                    if (!validIndex(texture.index, self.textures)) {
                        diagnostics.* = try allocator.print("materials[{d}].pbrMetallicRoughness.metallicRoughnessTexture.index refers to a texture ({d}) that doesn't exist", .{ i, texture.index });
                        return error.InvalidGltf;
                    }
                }

                for (metallic.baseColorFactor, 0..) |factor, j| {
                    if (factor < 0) {
                        diagnostics.* = try allocator.print("materials[{d}].pbrMetallicRoughness.baseColorFactor[{d}] < 0", .{ i, j });
                        return error.InvalidGltf;
                    }

                    if (factor > 1) {
                        diagnostics.* = try allocator.print("materials[{d}].pbrMetallicRoughness.baseColorFactor[{d}] > 1", .{ i, j });
                        return error.InvalidGltf;
                    }
                }

                if (metallic.metallicFactor < 0) {
                    diagnostics.* = try allocator.print("materials[{d}].pbrMetallicRoughness.metallicFactor < 0", .{i});
                    return error.InvalidGltf;
                }

                if (metallic.metallicFactor > 1) {
                    diagnostics.* = try allocator.print("materials[{d}].pbrMetallicRoughness.metallicFactor > 1", .{i});
                    return error.InvalidGltf;
                }

                if (metallic.roughnessFactor < 0) {
                    diagnostics.* = try allocator.print("materials[{d}].pbrMetallicRoughness.roughnessFactor < 0", .{i});
                    return error.InvalidGltf;
                }

                if (metallic.roughnessFactor > 1) {
                    diagnostics.* = try allocator.print("materials[{d}].pbrMetallicRoughness.roughnessFactor > 1", .{i});
                    return error.InvalidGltf;
                }
            }

            if (material.normalTexture) |normal| {
                if (!validIndex(normal.index, self.textures)) {
                    diagnostics.* = try allocator.print("materials[{d}].normalTexture.index refers to a texture ({d}) that doesn't exist", .{ i, normal.index });
                    return error.InvalidGltf;
                }

                // TODO: verify normal.texCoord value is present in a mesh.primitives.attributes (eg. TEXCOORD_0 for 0)
            }

            if (material.occlusionTexture) |occlusion| {
                if (!validIndex(occlusion.index, self.textures)) {
                    diagnostics.* = try allocator.print("materials[{d}].occlusionTexture.index refers to a texture ({d}) that doesn't exist", .{ i, occlusion.index });
                    return error.InvalidGltf;
                }

                // TODO: verify occlusion.texCoord value is present in a mesh.primitives.attributes (eg. TEXCOORD_0 for 0)

                if (occlusion.strength < 0) {
                    diagnostics.* = try allocator.print("materials[{d}].occlusionTextureInfo.strength < 0", .{i});
                    return error.InvalidGltf;
                }

                if (occlusion.strength > 1) {
                    diagnostics.* = try allocator.print("materials[{d}].occlusionTextureInfo.strength > 1", .{i});
                    return error.InvalidGltf;
                }
            }

            if (material.emissiveTexture) |emissive| {
                if (!validIndex(emissive.index, self.textures)) {
                    diagnostics.* = try allocator.print("materials[{d}].emissiveTexture.index refers to a texture ({d}) that doesn't exist", .{ i, emissive.index });
                    return error.InvalidGltf;
                }

                // TODO: verify emissive.texCoord value is present in a mesh.primitives.attributes (eg. TEXCOORD_0 for 0)
            }

            for (material.emissiveFactor, 0..) |factor, j| {
                if (factor < 0) {
                    diagnostics.* = try allocator.print("materials[{d}].emissiveFactor[{d}] < 0", .{ i, j });
                    return error.InvalidGltf;
                }

                if (factor > 1) {
                    diagnostics.* = try allocator.print("materials[{d}].emissiveFactor[{d}] > 1", .{ i, j });
                    return error.InvalidGltf;
                }
            }
        }
    }

    if (self.meshes) |meshes| {
        for (meshes, 0..) |mesh, i| {
            if (mesh.primitives.len == 0) {
                diagnostics.* = try allocator.print("meshes[{d}].primitives.len == 0", .{i});
                return error.InvalidGltf;
            }

            var target_count: ?usize = null;
            for (mesh.primitives, 0..) |primitive, j| {
                if (primitive.attributes.map.count() == 0) {
                    diagnostics.* = try allocator.print("meshes[{d}].primitives[{d}].attributes.count == 0", .{ i, j });
                    return error.InvalidGltf;
                }

                var vertex_count: ?Integer = null;
                for (primitive.attributes.map.keys(), primitive.attributes.map.values()) |semantic, index| {
                    const indexed = indexedAttribute(semantic) catch {
                        diagnostics.* = try allocator.print("meshes[{d}].primitives[{d}].attributes.{s} has an invalid semantic index", .{ i, j, semantic });
                        return error.InvalidGltf;
                    };

                    if (indexed) |attribute| {
                        var name_buffer: [32]u8 = undefined;
                        if (attribute.index > 0) {
                            const previous = try std.fmt.bufPrint(&name_buffer, "{s}{d}", .{ attribute.prefix, attribute.index - 1 });
                            if (!primitive.attributes.map.contains(previous)) {
                                diagnostics.* = try allocator.print("meshes[{d}].primitives[{d}].attributes.{s} is defined but attributes.{s} is not", .{ i, j, semantic, previous });
                                return error.InvalidGltf;
                            }
                        }

                        const partner_prefix: ?[]const u8 = if (std.mem.eql(u8, attribute.prefix, "JOINTS_")) "WEIGHTS_" else if (std.mem.eql(u8, attribute.prefix, "WEIGHTS_")) "JOINTS_" else null;
                        if (partner_prefix) |prefix| {
                            const partner = try std.fmt.bufPrint(&name_buffer, "{s}{d}", .{ prefix, attribute.index });
                            if (!primitive.attributes.map.contains(partner)) {
                                diagnostics.* = try allocator.print("meshes[{d}].primitives[{d}].attributes.{s} is defined but attributes.{s} is not", .{ i, j, semantic, partner });
                                return error.InvalidGltf;
                            }
                        }
                    }

                    if (!validIndex(index, self.accessors)) {
                        diagnostics.* = try allocator.print("meshes[{d}].primitives[{d}].attributes.{s} refers to an accessor ({d}) that doesn't exist", .{ i, j, semantic, index });
                        return error.InvalidGltf;
                    }

                    const accessor = &self.accessors.?[index];
                    if (!validAttributeLayout(semantic, accessor, false)) {
                        diagnostics.* = try allocator.print("meshes[{d}].primitives[{d}].attributes.{s} refers to an accessor ({d}) with an invalid type or componentType", .{ i, j, semantic, index });
                        return error.InvalidGltf;
                    }

                    if (accessor.bufferView) |view_index| {
                        if (accessor.byteOffset % 4 != 0) {
                            diagnostics.* = try allocator.print("meshes[{d}].primitives[{d}].attributes.{s} accessor's byteOffset % 4 != 0", .{ i, j, semantic });
                            return error.InvalidGltf;
                        }

                        if (accessor.componentType.size() % 4 != 0 and self.bufferViews.?[view_index].byteStride == null) {
                            diagnostics.* = try allocator.print("meshes[{d}].primitives[{d}].attributes.{s} accessor's componentType size % 4 != 0 but bufferView.byteStride == null", .{ i, j, semantic });
                            return error.InvalidGltf;
                        }
                    }

                    if (vertex_count) |count| {
                        if (accessor.count != count) {
                            diagnostics.* = try allocator.print("meshes[{d}].primitives[{d}].attributes.{s} accessor's count != other attribute accessors' count ({d})", .{ i, j, semantic, count });
                            return error.InvalidGltf;
                        }
                    } else {
                        vertex_count = accessor.count;
                    }

                    if (std.mem.eql(u8, semantic, "POSITION") and (accessor.min == null or accessor.max == null)) {
                        diagnostics.* = try allocator.print("meshes[{d}].primitives[{d}].attributes.POSITION accessor's min or max == null", .{ i, j });
                        return error.InvalidGltf;
                    }
                }

                if (primitive.targets) |targets| {
                    if (targets.len == 0) {
                        diagnostics.* = try allocator.print("meshes[{d}].primitives[{d}].targets.len == 0", .{ i, j });
                        return error.InvalidGltf;
                    }

                    if (target_count) |count| {
                        if (targets.len != count) {
                            diagnostics.* = try allocator.print("meshes[{d}].primitives[{d}].targets.len != other primitives' targets.len ({d})", .{ i, j, count });
                            return error.InvalidGltf;
                        }
                    } else {
                        target_count = targets.len;
                    }

                    for (targets, 0..) |target, k| {
                        for (target.map.keys(), target.map.values()) |semantic, index| {
                            if (!validIndex(index, self.accessors)) {
                                diagnostics.* = try allocator.print("meshes[{d}].primitives[{d}].targets[{d}].{s} refers to an accessor ({d}) that doesn't exist", .{ i, j, k, semantic, index });
                                return error.InvalidGltf;
                            }

                            if (!primitive.attributes.map.contains(semantic)) {
                                diagnostics.* = try allocator.print("meshes[{d}].primitives[{d}].targets[{d}].{s} is not present in primitives[{d}].attributes", .{ i, j, k, semantic, j });
                                return error.InvalidGltf;
                            }

                            const accessor = &self.accessors.?[index];
                            if (!validAttributeLayout(semantic, accessor, true)) {
                                diagnostics.* = try allocator.print("meshes[{d}].primitives[{d}].targets[{d}].{s} refers to an accessor ({d}) with an invalid type or componentType", .{ i, j, k, semantic, index });
                                return error.InvalidGltf;
                            }

                            if (accessor.bufferView) |view_index| {
                                if (accessor.byteOffset % 4 != 0) {
                                    diagnostics.* = try allocator.print("meshes[{d}].primitives[{d}].targets[{d}].{s} accessor's byteOffset % 4 != 0", .{ i, j, k, semantic });
                                    return error.InvalidGltf;
                                }

                                if (accessor.componentType.size() % 4 != 0 and self.bufferViews.?[view_index].byteStride == null) {
                                    diagnostics.* = try allocator.print("meshes[{d}].primitives[{d}].targets[{d}].{s} accessor's componentType size % 4 != 0 but bufferView.byteStride == null", .{ i, j, k, semantic });
                                    return error.InvalidGltf;
                                }
                            }

                            if (accessor.count != vertex_count.?) {
                                diagnostics.* = try allocator.print("meshes[{d}].primitives[{d}].targets[{d}].{s} accessor's count != attribute accessors' count ({d})", .{ i, j, k, semantic, vertex_count.? });
                                return error.InvalidGltf;
                            }

                            if (std.mem.eql(u8, semantic, "POSITION") and (accessor.min == null or accessor.max == null)) {
                                diagnostics.* = try allocator.print("meshes[{d}].primitives[{d}].targets[{d}].POSITION accessor's min or max == null", .{ i, j, k });
                                return error.InvalidGltf;
                            }
                        }
                    }
                }

                if (mesh.weights) |weights| {
                    if (primitive.targets) |targets| {
                        if (weights.len != targets.len) {
                            diagnostics.* = try allocator.print("meshes[{d}].weights.len != primitives[{d}].targets.len", .{ i, j });
                            return error.InvalidGltf;
                        }
                    }
                }

                if (primitive.indices) |indices| {
                    if (!validIndex(indices, self.accessors)) {
                        diagnostics.* = try allocator.print("meshes[{d}].primitives[{d}].indices refers to an accessor ({d}) that doesn't exist", .{ i, j, indices });
                        return error.InvalidGltf;
                    }

                    const accessor = &self.accessors.?[indices];
                    if (accessor.normalized) {
                        diagnostics.* = try allocator.print("meshes[{d}].primitives[{d}].indices refers to an accessor ({d}) which's normalized is true", .{ i, j, indices });
                        return error.InvalidGltf;
                    }

                    if (accessor.componentType != .unsigned_byte and accessor.componentType != .unsigned_short and accessor.componentType != .unsigned_int) {
                        diagnostics.* = try allocator.print("meshes[{d}].primitives[{d}].indices refers to an accessor ({d}) which's componentType is not an unsigned integer", .{ i, j, indices });
                        return error.InvalidGltf;
                    }

                    if (accessor.type != .SCALAR) {
                        diagnostics.* = try allocator.print("meshes[{d}].primitives[{d}].indices refers to an accessor ({d}) which's type is not SCALAR", .{ i, j, indices });
                        return error.InvalidGltf;
                    }
                }

                if (primitive.material) |material| {
                    if (!validIndex(material, self.materials)) {
                        diagnostics.* = try allocator.print("meshes[{d}].primitives[{d}].material refers to a material ({d}) that doesn't exist", .{ i, j, material });
                        return error.InvalidGltf;
                    }
                }
            }
            if (mesh.weights) |weights| {
                if (target_count == null) {
                    diagnostics.* = try allocator.print("meshes[{d}].weights is defined but no primitives have targets", .{i});
                    return error.InvalidGltf;
                }

                if (weights.len == 0) {
                    diagnostics.* = try allocator.print("meshes[{d}].weights.len == 0", .{i});
                    return error.InvalidGltf;
                }
            }
        }
    }

    if (self.nodes) |nodes| {
        for (nodes, 0..) |node, i| {
            if (node.camera) |camera| {
                if (!validIndex(camera, self.cameras)) {
                    diagnostics.* = try allocator.print("nodes[{d}].camera refers to a camera ({d}) that doesn't exist", .{ i, camera });
                    return error.InvalidGltf;
                }
            }

            if (node.children) |children| {
                var uniques: std.AutoHashMap(Integer, void) = .init(allocator);
                defer uniques.deinit();
                for (children, 0..) |child, j| {
                    if (!validIndex(child, self.nodes)) {
                        diagnostics.* = try allocator.print("nodes[{d}].children[{d}] refers to a node ({d}) that doesn't exist", .{ i, j, child });
                        return error.InvalidGltf;
                    }

                    const entry = try uniques.getOrPut(child);
                    if (entry.found_existing) {
                        diagnostics.* = try allocator.print("nodes[{d}].children[{d}] is not unique ({d})", .{ i, j, child });
                        return error.InvalidGltf;
                    }
                }
            }

            if (node.skin) |skin| {
                if (!validIndex(skin, self.skins)) {
                    diagnostics.* = try allocator.print("nodes[{d}].skin refers to a skin ({d}) that doesn't exist", .{ i, skin });
                    return error.InvalidGltf;
                }

                if (node.mesh == null) {
                    diagnostics.* = try allocator.print("nodes[{d}].skin is defined but not nodes[{d}].mesh", .{ i, i });
                    return error.InvalidGltf;
                }

                // TODO: all skin joints must be in the same scene
            }

            if (node.mesh) |mesh| {
                if (!validIndex(mesh, self.meshes)) {
                    diagnostics.* = try allocator.print("nodes[{d}].mesh refers to a mesh ({d}) that doesn't exist", .{ i, mesh });
                    return error.InvalidGltf;
                }
            }

            for (node.rotation, 0..) |value, j| {
                if (value < -1) {
                    diagnostics.* = try allocator.print("nodes[{d}].rotation[{d}] < -1", .{ i, j });
                    return error.InvalidGltf;
                }

                if (value > 1) {
                    diagnostics.* = try allocator.print("nodes[{d}].rotation[{d}] > 1", .{ i, j });
                    return error.InvalidGltf;
                }
            }

            if (node.weights) |weights| {
                if (node.mesh == null) {
                    diagnostics.* = try allocator.print("nodes[{d}].weights is defined but not nodes[{d}].mesh", .{ i, i });
                    return error.InvalidGltf;
                }

                _ = weights;
                // TODO: must match morph targets count of mesh
            }
        }
    }

    if (self.scene) |scene| {
        if (!validIndex(scene, self.scenes)) {
            diagnostics.* = try allocator.print("scene refers to a scene ({d}) that doesn't exist", .{scene});
            return error.InvalidGltf;
        }
    }

    if (self.scenes) |scenes| {
        for (scenes, 0..) |scene, i| {
            if (scene.nodes) |nodes| {
                var uniques: std.AutoHashMap(Integer, void) = .init(allocator);
                defer uniques.deinit();
                for (nodes, 0..) |node, j| {
                    if (!validIndex(node, self.nodes)) {
                        diagnostics.* = try allocator.print("scenes[{d}].nodes[{d}] refers to a node ({d}) that doesn't exist", .{ i, j, node });
                        return error.InvalidGltf;
                    }

                    const entry = try uniques.getOrPut(node);
                    if (entry.found_existing) {
                        diagnostics.* = try allocator.print("scenes[{d}].nodes[{d}] is not unique ({d})", .{ i, j, node });
                        return error.InvalidGltf;
                    }
                }
            }
        }
    }

    if (self.skins) |skins| {
        for (skins, 0..) |skin, i| {
            if (skin.joints.len == 0) {
                diagnostics.* = try allocator.print("skins[{d}].joints.len == 0", .{i});
                return error.InvalidGltf;
            }

            if (skin.skeleton) |skeleton| {
                if (!validIndex(skeleton, self.nodes)) {
                    diagnostics.* = try allocator.print("skins[{d}].skeleton refers to a node ({d}) that doesn't exist", .{ i, skeleton });
                    return error.InvalidGltf;
                }
            }

            if (skin.inverseBindMatrices) |matrices| {
                if (!validIndex(matrices, self.accessors)) {
                    diagnostics.* = try allocator.print("skins[{d}].inverseBindMatrices refers to an accessor ({d}) that doesn't exist", .{ i, matrices });
                    return error.InvalidGltf;
                }

                const accessor = &self.accessors.?[matrices];
                if (accessor.componentType != .float) {
                    diagnostics.* = try allocator.print("skins[{d}].inverseBindMatrices refers to an accessor ({d}) which's componentType is not float", .{ i, matrices });
                    return error.InvalidGltf;
                }

                if (accessor.type != .MAT4) {
                    diagnostics.* = try allocator.print("skins[{d}].inverseBindMatrices refers to an accessor ({d}) which's type is not MAT4", .{ i, matrices });
                    return error.InvalidGltf;
                }

                if (accessor.count < skin.joints.len) {
                    diagnostics.* = try allocator.print("skins[{d}].inverseBindMatrices refers to an accessor ({d}) which's count is < skin.joints.len", .{ i, matrices });
                    return error.InvalidGltf;
                }
            }

            var uniques: std.AutoHashMap(Integer, void) = .init(allocator);
            defer uniques.deinit();
            for (skin.joints, 0..) |joint, j| {
                if (!validIndex(joint, self.nodes)) {
                    diagnostics.* = try allocator.print("skins[{d}].joints[{d}] refers to a node ({d}) that doesn't exist", .{ i, j, joint });
                    return error.InvalidGltf;
                }

                const entry = try uniques.getOrPut(joint);
                if (entry.found_existing) {
                    diagnostics.* = try allocator.print("skins[{d}].joints[{d}] is not unique ({d})", .{ i, j, joint });
                    return error.InvalidGltf;
                }
            }
        }
    }

    if (self.textures) |textures| {
        for (textures, 0..) |texture, i| {
            if (texture.sampler) |sampler| {
                if (!validIndex(sampler, self.samplers)) {
                    if (!validIndex(sampler, self.samplers)) {
                        diagnostics.* = try allocator.print("textures[{d}].sampler refers to a sampler ({d}) that doesn't exist", .{ i, sampler });
                        return error.InvalidGltf;
                    }
                }
            }

            if (texture.source) |source| {
                if (!validIndex(source, self.images)) {
                    diagnostics.* = try allocator.print("textures[{d}].source refers to a sampler ({d}) that doesn't exist", .{ i, source });
                    return error.InvalidGltf;
                }
            }
        }
    }
}

fn indexedAttribute(semantic: []const u8) !?struct { prefix: []const u8, index: u32 } {
    const prefixes = [_][]const u8{ "TEXCOORD_", "COLOR_", "JOINTS_", "WEIGHTS_" };
    for (prefixes) |prefix| {
        if (!std.mem.startsWith(u8, semantic, prefix)) continue;

        const suffix = semantic[prefix.len..];
        if (suffix.len == 0 or suffix.len > 9 or (suffix.len > 1 and suffix[0] == '0')) {
            return error.InvalidAttributeSemantic;
        }

        for (suffix) |char| {
            if (char < '0' or char > '9') return error.InvalidAttributeSemantic;
        }

        return .{
            .prefix = prefix,
            .index = try std.fmt.parseInt(u32, suffix, 10),
        };
    }

    return null;
}

fn validAttributeLayout(semantic: []const u8, accessor: *const Accessor, morph: bool) bool {
    const float = accessor.componentType == .float;
    const unsigned = accessor.componentType == .unsigned_byte or accessor.componentType == .unsigned_short;
    const signed = accessor.componentType == .byte or accessor.componentType == .short;
    const unorm = unsigned and accessor.normalized;
    const snorm = signed and accessor.normalized;
    if (std.mem.eql(u8, semantic, "POSITION")) {
        return accessor.type == .VEC3 and float;
    }
    if (std.mem.eql(u8, semantic, "NORMAL")) {
        return accessor.type == .VEC3 and float;
    }
    if (std.mem.eql(u8, semantic, "TANGENT")) {
        return accessor.type == (if (morph) Accessor.Type.VEC3 else Accessor.Type.VEC4) and float;
    }
    if (std.mem.startsWith(u8, semantic, "TEXCOORD_")) {
        return accessor.type == .VEC2 and (float or unorm or (morph and snorm));
    }
    if (std.mem.startsWith(u8, semantic, "COLOR_")) {
        return (accessor.type == .VEC3 or accessor.type == .VEC4) and (float or unorm or (morph and snorm));
    }
    if (std.mem.startsWith(u8, semantic, "JOINTS_")) {
        return !morph and accessor.type == .VEC4 and unsigned and !accessor.normalized;
    }
    if (std.mem.startsWith(u8, semantic, "WEIGHTS_")) {
        return !morph and accessor.type == .VEC4 and (float or unorm);
    }
    // Extension-defined and application-specific attributes have their own layouts.
    return true;
}

fn validIndex(index: u32, array: anytype) bool {
    const info = @typeInfo(@TypeOf(array));

    switch (info) {
        .optional => if (array) |a| {
            return index < a.len;
        },
        .pointer => {
            return index < array.len;
        },
        else => @compileError("not supported"),
    }

    return false;
}

fn parseGlb(raw: []align(4) const u8) !Glb {
    const header_size = 12;

    if (raw.len < header_size) return error.MissingGltfHeader;

    const glb_magic = std.mem.readInt(u32, raw[0..4], .little);
    assert(glb_magic == magic.glb);

    const version = std.mem.readInt(u32, raw[4..8], .little);
    if (version != 2) return error.UnsupportedGltfVersion;

    const len = std.mem.readInt(u32, raw[8..12], .little);
    if (len < header_size or raw.len != len) return error.InvalidGltfHeader;

    const data = raw[0..len];
    var offset: usize = header_size;

    const json = try getChunk(data[offset..], magic.json);
    offset += json.len + 8;

    var binary: ?[]const u8 = null;
    if (offset < data.len) {
        binary = try getChunk(data[offset..], magic.bin);
        offset += binary.?.len + 8;
    }

    return .{
        .json = json,
        .binary = binary,
    };
}

fn getChunk(data: []const u8, chunk_type: u32) ![]const u8 {
    if (data.len < 8) return error.MissingChunk;

    const len = std.mem.readInt(u32, data[0..4], .little);
    if (len > data.len - 8 or len % 4 != 0) return error.InvalidChunkLength;

    const ty = std.mem.readInt(u32, data[4..8], .little);
    if (ty != chunk_type) return error.InvalidChunkType;

    return data[8..][0..len];
}
